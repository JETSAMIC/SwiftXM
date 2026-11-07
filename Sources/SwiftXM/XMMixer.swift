/// XMMixer.swift
///
/// Software mixer for an `XMFile`. Iterates the order table, applies
/// the XM effect set (`0`-`F`, `E` subcommands, `G H K L P R T X` and
/// the volume column), runs volume / panning envelopes, fade-out and
/// auto-vibrato, and writes interleaved stereo `Float32` PCM into a
/// caller-provided buffer.
///
/// Playback follows FastTracker II's replayer (as documented in
/// `Reference/xm-form.txt` and reproduced by ft2-clone): per-effect
/// memories, FT2's flow state (`pBreakPos`, position-jump flag,
/// per-channel `E6x` loops including the "next pattern starts at the
/// loop row" quirk), `EEx` repeats that only run per-tick effects, the
/// tick-counter-based arpeggio order, and FT2's vibrato / tremolo /
/// tremor / multi-retrig arithmetic.
///
/// ## Timing model
/// `speed` (effect `Fxx` < 0x20) is ticks per row; `bpm` (`Fxx` >=
/// 0x20) drives the tick rate: `tickRateHz = bpm * 2 / 5`.
///
/// ## Frequency tables
/// - Linear: `period = 7680 - note*64 - finetune/2`,
///   `Hz = 8363 * 2^((4608 - period) / 768)`.
/// - Amiga: FT2's 96-entry period table, interpolated for finetune,
///   `Hz = 8363 * 1712 / period`.
/// `note` is 0-based here (C-0 = 0), i.e. pattern note - 1 + the
/// sample's relative note.

import Foundation

/// Renders an ``XMFile`` to interleaved stereo `Float32` PCM.
///
/// The mixer is a single-threaded state machine: each call to
/// ``render(into:frames:)`` advances playback. It is marked
/// `@unchecked Sendable` so it can be handed to an audio render
/// callback, but it has no internal locking: confine all calls to one
/// thread (or one serial context) at a time.
///
/// Playback stops (``finished`` becomes `true`) at the end of the
/// order list or when the song loops back to a row it already played,
/// so rendering always terminates.
public final class XMMixer: @unchecked Sendable {

    // MARK: - Configuration

    /// Output sample rate, in Hz.
    public let sampleRate: Double

    // MARK: - Public playback state

    /// `true` once playback has ended: the order list was exhausted
    /// or the song looped back to an already-played row.
    public private(set) var finished: Bool = false

    /// Index into ``XMFile/order`` of the row being played.
    public var currentOrder: Int { songPos }

    /// Row within the current pattern.
    public var currentRow: Int { row }

    // MARK: - Module state

    private let file: XMFile
    private let linear: Bool
    private let mixScale: Float
    private var songPos = 0
    private var row = 0
    private var tick = 0
    private var speed: Int
    private var bpm: Int
    private var globalVolume = 64
    private var pattern: XMPattern

    // FT2 flow state.
    private var breakPos = 0
    private var breakFlag = false
    private var posJumpFlag = false
    private var jumpTarget: Int?
    private var patternDelay = 0
    private var inRowRepeat = false

    // Loop detection.
    private var visitedRows: Set<Int> = []
    private var rowBudget: Int

    private var framesRemainingInTick = 0
    private var tickFrameFraction = 0.0
    private var voices: [Voice]

    // MARK: - Voice state

    private struct Voice {
        // Sample playback.
        var pcm: [Int16] = []
        var loopStart = 0
        var loopEnd = 0
        var loopMode: XMSample.LoopMode = .none
        var pos: Double = 0
        var forward = true
        var active = false
        var step: Double = 0

        var instrument = 0          // 1-based, 0 = none
        var sampleIndex = -1
        var note = 0                // last pattern note 1...96
        var relativeNote = 0
        var finetune = 0

        // Pitch (FT2 realPeriod / outPeriod).
        var period: Double = 0
        var outPeriod: Double = 0
        var targetPeriod: Double = 0
        var portaSpeed = 0          // 3xx / Mx memory, already * 4

        // Volume / panning.
        var volume = 0
        var outVolume = 0
        var panning = 128
        var finalVolume: Float = 0
        var finalPan: Float = 0

        // Instrument state.
        var keyOff = false
        var fadeout = 32768
        var volEnvFrame = 0
        var panEnvFrame = 0
        var autoVibPos = 0
        var autoVibAmp = 0
        var autoVibSweep = 0

        // Effect memories (FT2 keeps one per effect).
        var memPortaUp: UInt8 = 0
        var memPortaDown: UInt8 = 0
        var memFinePortaUp: UInt8 = 0
        var memFinePortaDown: UInt8 = 0
        var memExtraFineUp: UInt8 = 0
        var memExtraFineDown: UInt8 = 0
        var memVolSlide: UInt8 = 0
        var memFineVolUp: UInt8 = 0
        var memFineVolDown: UInt8 = 0
        var memGlobalSlide: UInt8 = 0
        var memPanSlide: UInt8 = 0
        var memOffset: UInt8 = 0
        var memTremor: UInt8 = 0

        var vibratoPos = 0          // 0...255
        var vibratoSpeed = 0        // already * 4
        var vibratoDepth = 0
        var tremoloPos = 0
        var tremoloSpeed = 0
        var tremoloDepth = 0
        var waveControl = 0         // E4x low nibble, E7x high nibble
        var glissando = false
        var retrigVolume = 0
        var retrigSpeed = 0
        var retrigCount = 0
        var tremorPos: UInt8 = 0

        // Per-channel E6x loop (FT2).
        var loopRow = 0
        var loopCount = 0

        // The row's cell and EDx state.
        var cell = XMPattern.Cell()
        var delayedCell: XMPattern.Cell?
        var delayTick = -1
    }

    // MARK: - Tables

    /// FT2 / ProTracker vibrato half-sine (32 entries, peak 255).
    private static let vibratoTable: [Int] = [
        0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
        255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24
    ]

    /// FT2 auto-vibrato sine (256 entries, ±64, negative first).
    private static let autoVibratoSine: [Int] = (0..<256).map {
        -Int((64 * sin(Double($0) * 2 * .pi / 256)).rounded())
    }

    /// FT2 Amiga period table: 12 notes × 8 finetune steps, starting a
    /// semitone below C (see Reference/xm-form.txt).
    private static let amigaPeriods: [Double] = [
        907, 900, 894, 887, 881, 875, 868, 862, 856, 850, 844, 838, 832, 826, 820, 814,
        808, 802, 796, 791, 785, 779, 774, 768, 762, 757, 752, 746, 741, 736, 730, 725,
        720, 715, 709, 704, 699, 694, 689, 684, 678, 675, 670, 665, 660, 655, 651, 646,
        640, 636, 632, 628, 623, 619, 614, 610, 604, 601, 597, 592, 588, 584, 580, 575,
        570, 567, 563, 559, 555, 551, 547, 543, 538, 535, 532, 528, 524, 520, 516, 513,
        508, 505, 502, 498, 494, 491, 487, 484, 480, 477, 474, 470, 467, 463, 460, 457
    ]

    private static let periodRange: ClosedRange<Double> = 1...31999

    // MARK: - Init

    /// Creates a mixer positioned at the start of the song.
    ///
    /// - Parameters:
    ///   - file: The parsed module to play.
    ///   - sampleRate: Output sample rate in hertz, for example
    ///     `44_100` or `48_000`.
    /// - Throws: ``XMError/invalidSampleRate`` if `sampleRate` is not
    ///   finite or not in `1...1_000_000`.
    public init(file: XMFile, sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= 1_000_000 else {
            throw XMError.invalidSampleRate
        }
        self.file = file
        self.sampleRate = sampleRate
        self.linear = file.frequencyTable == .linear
        self.speed = file.defaultTempo == 0 ? 6 : min(31, file.defaultTempo)
        self.bpm = file.defaultBPM == 0 ? 125 : max(32, min(255, file.defaultBPM))
        self.mixScale = 1 / Float(max(1, min(32, file.channelCount)))
        self.voices = Array(repeating: Voice(), count: file.channelCount)
        self.pattern = XMPattern.empty(channels: file.channelCount)

        var totalRows = 0
        for i in 0..<file.songLength {
            let p = Int(file.order[i])
            totalRows += p < file.patterns.count ? file.patterns[p].rowCount : 64
        }
        self.rowBudget = totalRows * 32 + 1024

        if file.songLength > 0 {
            loadPattern()
            enterRow()
        } else {
            finished = true
        }
        framesRemainingInTick = nextTickFrameCount()
    }

    // MARK: - Render entry point

    /// Renders up to `frames` interleaved stereo frames (`L R L R …`)
    /// into `buffer`, which must have room for `frames * 2` floats.
    ///
    /// - Parameters:
    ///   - buffer: Destination for `frames * 2` interleaved samples,
    ///     nominally in -1...1 (not clipped).
    ///   - frames: Number of stereo frames requested. Values <= 0
    ///     render nothing.
    /// - Returns: The number of frames rendered. Less than `frames`
    ///   means the song ended; the unwritten tail is zero-filled.
    @discardableResult
    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        var written = 0
        while written < frames && !finished {
            if framesRemainingInTick == 0 {
                advanceTick()
                framesRemainingInTick = nextTickFrameCount()
                continue
            }
            let toWrite = min(frames - written, framesRemainingInTick)
            renderChunk(into: buffer.advanced(by: written * 2), frames: toWrite)
            written += toWrite
            framesRemainingInTick -= toWrite
        }
        if written < frames {
            buffer.advanced(by: written * 2).update(repeating: 0, count: (frames - written) * 2)
        }
        return written
    }

    // MARK: - Chunk rendering

    private func renderChunk(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        buffer.update(repeating: 0, count: frames * 2)
        for v in 0..<voices.count where voices[v].active {
            mixVoice(into: buffer, frames: frames, voice: v)
        }
    }

    private func mixVoice(into buffer: UnsafeMutablePointer<Float>, frames: Int, voice v: Int) {
        let amp = voices[v].finalVolume * mixScale
        let pan = voices[v].finalPan
        let ampL = amp * (1 - pan) * 0.5
        let ampR = amp * (1 + pan) * 0.5
        let pcm = voices[v].pcm
        let mode = voices[v].loopMode
        let loopStart = voices[v].loopStart
        let loopEnd = voices[v].loopEnd
        let end = mode == .none ? pcm.count : loopEnd
        let loopLength = Double(loopEnd - loopStart)
        let step = voices[v].step
        var pos = voices[v].pos
        var forward = voices[v].forward

        for i in 0..<frames {
            let index = min(Int(pos), end - 1)
            let s0 = Float(pcm[index])
            let next: Int
            if forward {
                next = index + 1 < end ? index + 1 : (mode == .forward ? loopStart : index)
            } else {
                next = index > loopStart ? index - 1 : index
            }
            let frac = Float(pos - Double(Int(pos)))
            let s = (s0 + (Float(pcm[next]) - s0) * frac) / 32768
            buffer[i * 2] += s * ampL
            buffer[i * 2 + 1] += s * ampR

            switch mode {
            case .none:
                pos += step
                if pos >= Double(end) {
                    voices[v].active = false
                    voices[v].pos = pos
                    return
                }
            case .forward:
                pos += step
                if pos >= Double(loopEnd) {
                    pos = Double(loopStart) + (pos - Double(loopStart)).truncatingRemainder(dividingBy: loopLength)
                }
            case .pingPong:
                // Unfold the bounce into a phase u in [0, 2L): u < L
                // runs forward from loopStart, u >= L runs backward.
                var u: Double
                if forward && pos < Double(loopStart) {
                    pos += step
                    if pos < Double(loopStart) { continue }
                    u = pos - Double(loopStart)
                } else {
                    u = (forward ? pos - Double(loopStart) : 2 * loopLength - (pos - Double(loopStart))) + step
                }
                u = u.truncatingRemainder(dividingBy: 2 * loopLength)
                if u < loopLength {
                    pos = Double(loopStart) + u
                    forward = true
                } else {
                    pos = Double(loopStart) + (2 * loopLength - u)
                    forward = false
                }
            }
        }
        voices[v].pos = pos
        voices[v].forward = forward
    }

    // MARK: - Song navigation

    private func loadPattern() {
        let index = Int(file.order[songPos])
        pattern = index < file.patterns.count ? file.patterns[index] : .empty(channels: file.channelCount)
    }

    private func enterRow() {
        rowBudget -= 1
        let key = songPos << 16 | row
        if rowBudget < 0 || visitedRows.contains(key) {
            finished = true
            return
        }
        visitedRows.insert(key)
        inRowRepeat = false
        processTick0()
        updateOutputs()
    }

    /// End of a row: run `EEx` repeats, then FT2's position logic.
    private func finishRow() {
        if patternDelay > 0 {
            patternDelay -= 1
            inRowRepeat = true
            // FT2 does not re-read the row; the first tick of each
            // repeat runs the per-tick effects instead.
            processTickN()
            updateOutputs()
            return
        }

        let previousRow = row
        var next = row + 1
        var loopJump = false
        if breakFlag {
            breakFlag = false
            next = breakPos
            loopJump = true
        }
        if next >= pattern.rowCount || posJumpFlag {
            next = breakPos
            breakPos = 0
            posJumpFlag = false
            loopJump = false
            songPos = jumpTarget ?? songPos + 1
            jumpTarget = nil
            guard songPos >= 0, songPos < file.songLength else {
                finished = true
                return
            }
            loadPattern()
            if next >= pattern.rowCount { next = 0 }
        }
        row = next
        if loopJump {
            for r in min(row, previousRow)...max(row, previousRow) {
                visitedRows.remove(songPos << 16 | r)
            }
        }
        enterRow()
    }

    private func advanceTick() {
        guard !finished else { return }
        tick += 1
        if tick >= speed {
            tick = 0
            finishRow()
        } else {
            processTickN()
            updateOutputs()
        }
    }

    // MARK: - Tick 0

    private func processTick0() {
        for c in 0..<voices.count {
            let cell = pattern.cell(row: row, channel: c)
            voices[c].cell = cell
            voices[c].delayedCell = nil
            voices[c].delayTick = -1
            if cell.effect == 0x0E && cell.param >> 4 == 0xD && cell.param & 0x0F != 0 {
                // EDx: the whole cell (note, instrument, volume column)
                // plays on tick x.
                voices[c].delayedCell = cell
                voices[c].delayTick = Int(cell.param & 0x0F)
                continue
            }
            triggerCell(channel: c, cell: cell)
            effectTick0(channel: c, cell: cell)
        }
    }

    /// Instrument, note and tick-0 volume-column handling (FT2's
    /// "Play / Switch / OldVol / Cut" table).
    private func triggerCell(channel c: Int, cell: XMPattern.Cell) {
        let porta = cell.effect == 0x03 || cell.effect == 0x05 || cell.volume >= 0xF0
        // Porta speed and offset memories are needed before the note.
        if cell.effect == 0x03 && cell.param != 0 { voices[c].portaSpeed = Int(cell.param) * 4 }
        if cell.volume >= 0xF0 && cell.volume & 0x0F != 0 { voices[c].portaSpeed = Int(cell.volume & 0x0F) * 64 }
        if cell.effect == 0x09 && cell.param != 0 { voices[c].memOffset = cell.param }

        var instrumentValid = true
        if cell.instrument > 0 {
            if Int(cell.instrument) <= file.instruments.count {
                voices[c].instrument = Int(cell.instrument)
            } else {
                instrumentValid = false
            }
        }

        let note = Int(cell.note)
        if note == 97 {
            keyOff(channel: c)
        } else if (1...96).contains(note) {
            if porta && voices[c].period > 0 {
                if voices[c].portaSpeed > 0 {
                    voices[c].targetPeriod = periodFor(note: note - 1 + voices[c].relativeNote,
                                                       finetune: voices[c].finetune)
                }
                if cell.instrument > 0 && instrumentValid { resetToSampleDefaults(channel: c) }
            } else if !instrumentValid {
                voices[c].active = false
            } else {
                playNote(channel: c, note: note, cell: cell)
            }
        } else if cell.instrument > 0 && instrumentValid {
            resetToSampleDefaults(channel: c)
        }

        switch XMVolumeCommand(byte: cell.volume) {
        case .setVolume(let v): voices[c].volume = Int(v)
        case .fineSlideDown(let v): voices[c].volume = max(0, voices[c].volume - Int(v))
        case .fineSlideUp(let v): voices[c].volume = min(64, voices[c].volume + Int(v))
        case .setVibratoSpeed(let v): if v != 0 { voices[c].vibratoSpeed = Int(v) * 4 }
        case .vibrato(let v): if v != 0 { voices[c].vibratoDepth = Int(v) }
        case .setPanning(let v): voices[c].panning = Int(v)
        default: break
        }
    }

    private func playNote(channel c: Int, note: Int, cell: XMPattern.Cell) {
        guard voices[c].instrument > 0 else { return }
        let ins = file.instruments[voices[c].instrument - 1]
        let si = Int(ins.sampleMap[note - 1])
        guard si < ins.samples.count, !ins.samples[si].pcm.isEmpty else {
            voices[c].active = false
            return
        }
        let smp = ins.samples[si]
        var finetune = Int(smp.finetune)
        if cell.effect == 0x0E && cell.param >> 4 == 0x5 {
            finetune = Int(cell.param & 0x0F) * 16 - 128
        }
        let realNote = note - 1 + Int(smp.relativeNote)
        guard (0...118).contains(realNote) else { return }

        voices[c].note = note
        voices[c].sampleIndex = si
        voices[c].pcm = smp.pcm
        voices[c].loopStart = smp.loopBegin
        voices[c].loopEnd = smp.loopEnd
        voices[c].loopMode = smp.loopMode
        voices[c].relativeNote = Int(smp.relativeNote)
        voices[c].finetune = finetune
        let period = periodFor(note: realNote, finetune: finetune)
        voices[c].period = period
        voices[c].outPeriod = period
        voices[c].targetPeriod = period
        voices[c].pos = 0
        voices[c].forward = true
        voices[c].active = true
        if voices[c].waveControl & 0x04 == 0 { voices[c].vibratoPos = 0 }
        if voices[c].waveControl & 0x40 == 0 { voices[c].tremoloPos = 0 }
        voices[c].retrigCount = 0
        voices[c].tremorPos = 0

        if cell.effect == 0x09 {
            let offset = Int(voices[c].memOffset) * 256
            if offset >= smp.pcm.count {
                voices[c].active = false
            } else {
                voices[c].pos = Double(offset)
            }
        }
        if cell.instrument > 0 {
            voices[c].volume = Int(smp.volume)
            voices[c].panning = Int(smp.panning)
            triggerInstrument(channel: c)
        }
    }

    /// "OldVol": reset volume and panning to the current sample's
    /// defaults and retrigger the envelopes, without restarting the
    /// sample.
    private func resetToSampleDefaults(channel c: Int) {
        guard voices[c].instrument > 0 else { return }
        let ins = file.instruments[voices[c].instrument - 1]
        let mapped = voices[c].note > 0 ? Int(ins.sampleMap[voices[c].note - 1]) : voices[c].sampleIndex
        if mapped >= 0 && mapped < ins.samples.count {
            voices[c].volume = Int(ins.samples[mapped].volume)
            voices[c].panning = Int(ins.samples[mapped].panning)
        }
        triggerInstrument(channel: c)
    }

    /// Envelope / fade-out / auto-vibrato reset.
    private func triggerInstrument(channel c: Int) {
        voices[c].keyOff = false
        voices[c].fadeout = 32768
        voices[c].volEnvFrame = 0
        voices[c].panEnvFrame = 0
        voices[c].autoVibPos = 0
        guard voices[c].instrument > 0 else { return }
        let av = file.instruments[voices[c].instrument - 1].autoVibrato
        if av.sweep > 0 {
            voices[c].autoVibAmp = 0
            voices[c].autoVibSweep = (Int(av.depth) << 8) / Int(av.sweep)
        } else {
            voices[c].autoVibAmp = Int(av.depth) << 8
            voices[c].autoVibSweep = 0
        }
    }

    private func keyOff(channel c: Int) {
        voices[c].keyOff = true
        if let ins = currentInstrument(c), !ins.volumeEnvelope.enabled {
            voices[c].volume = 0
        }
    }

    private func currentInstrument(_ c: Int) -> XMInstrument? {
        let i = voices[c].instrument
        return i > 0 && i <= file.instruments.count ? file.instruments[i - 1] : nil
    }

    private func effectTick0(channel c: Int, cell: XMPattern.Cell) {
        let p = cell.param
        let hi = p >> 4
        let lo = p & 0x0F
        switch cell.effect {
        case 0x01: if p != 0 { voices[c].memPortaUp = p }
        case 0x02: if p != 0 { voices[c].memPortaDown = p }
        case 0x04:
            if hi != 0 { voices[c].vibratoSpeed = Int(hi) * 4 }
            if lo != 0 { voices[c].vibratoDepth = Int(lo) }
        case 0x05, 0x06, 0x0A:
            if p != 0 { voices[c].memVolSlide = p }
        case 0x07:
            if hi != 0 { voices[c].tremoloSpeed = Int(hi) * 4 }
            if lo != 0 { voices[c].tremoloDepth = Int(lo) }
        case 0x08:
            voices[c].panning = Int(p)
        case 0x0B:
            jumpTarget = Int(p)
            breakPos = 0
            posJumpFlag = true
        case 0x0C:
            voices[c].volume = min(64, Int(p))
        case 0x0D:
            let target = Int(hi) * 10 + Int(lo)
            breakPos = target <= 63 ? target : 0
            posJumpFlag = true
        case 0x0E:
            extendedTick0(channel: c, sub: hi, value: lo)
        case 0x0F:
            if p == 0 { break }
            if p < 0x20 { speed = Int(p) } else { bpm = Int(p) }
        case 0x10:
            globalVolume = min(64, Int(p))
        case 0x11:
            if p != 0 { voices[c].memGlobalSlide = p }
        case 0x14:
            if p == 0 { keyOff(channel: c) }
        case 0x15:
            setEnvelopePosition(channel: c, frame: Int(p))
        case 0x19:
            if p != 0 { voices[c].memPanSlide = p }
        case 0x1B:
            if hi != 0 { voices[c].retrigVolume = Int(hi) }
            if lo != 0 { voices[c].retrigSpeed = Int(lo) }
        case 0x1D:
            if p != 0 { voices[c].memTremor = p }
        case 0x21:
            if hi == 1 {
                if lo != 0 { voices[c].memExtraFineUp = lo }
                slide(channel: c, by: -Double(voices[c].memExtraFineUp))
            } else if hi == 2 {
                if lo != 0 { voices[c].memExtraFineDown = lo }
                slide(channel: c, by: Double(voices[c].memExtraFineDown))
            }
        default:
            // 0 arpeggio, 3 tone porta and 9 offset work elsewhere.
            break
        }
    }

    private func extendedTick0(channel c: Int, sub: UInt8, value v: UInt8) {
        switch sub {
        case 0x1:
            if v != 0 { voices[c].memFinePortaUp = v }
            slide(channel: c, by: -Double(Int(voices[c].memFinePortaUp) * 4))
        case 0x2:
            if v != 0 { voices[c].memFinePortaDown = v }
            slide(channel: c, by: Double(Int(voices[c].memFinePortaDown) * 4))
        case 0x3:
            voices[c].glissando = v != 0
        case 0x4:
            voices[c].waveControl = (voices[c].waveControl & 0xF0) | Int(v)
        case 0x6:
            patternLoop(channel: c, value: Int(v))
        case 0x7:
            voices[c].waveControl = (voices[c].waveControl & 0x0F) | Int(v) << 4
        case 0xA:
            if v != 0 { voices[c].memFineVolUp = v }
            voices[c].volume = min(64, voices[c].volume + Int(voices[c].memFineVolUp))
        case 0xB:
            if v != 0 { voices[c].memFineVolDown = v }
            voices[c].volume = max(0, voices[c].volume - Int(voices[c].memFineVolDown))
        case 0xC:
            if v == 0 { voices[c].volume = 0 }
        case 0xE:
            if patternDelay == 0 { patternDelay = Int(v) }
        default:
            // E0x (filter) and E8x are unused in FT2; E5x applies with
            // the note; E9x, ECx (x > 0) and EDx run on later ticks.
            break
        }
    }

    private func patternLoop(channel c: Int, value: Int) {
        if value == 0 {
            voices[c].loopRow = row
        } else if voices[c].loopCount == 0 {
            voices[c].loopCount = value
            breakPos = voices[c].loopRow
            breakFlag = true
        } else {
            voices[c].loopCount -= 1
            if voices[c].loopCount > 0 {
                breakPos = voices[c].loopRow
                breakFlag = true
            }
        }
    }

    private func setEnvelopePosition(channel c: Int, frame: Int) {
        guard let ins = currentInstrument(c) else { return }
        if ins.volumeEnvelope.enabled { voices[c].volEnvFrame = frame }
        // FT2 bug: the panning envelope position is only set when the
        // volume envelope has its sustain flag.
        if ins.volumeEnvelope.sustainEnabled { voices[c].panEnvFrame = frame }
    }

    // MARK: - Ticks > 0

    private func processTickN() {
        for c in 0..<voices.count {
            if voices[c].delayTick == tick, let cell = voices[c].delayedCell {
                voices[c].delayedCell = nil
                voices[c].delayTick = -1
                triggerCell(channel: c, cell: cell)
            }
            let cell = voices[c].cell
            let volumeCommand = XMVolumeCommand(byte: cell.volume)
            let p = cell.param

            // 1. Changes to the underlying period / volume / panning
            //    (volume column first, as in FT2).
            var portaActive = false
            switch volumeCommand {
            case .slideDown(let v): voices[c].volume = max(0, voices[c].volume - Int(v))
            case .slideUp(let v): voices[c].volume = min(64, voices[c].volume + Int(v))
            case .panSlideLeft(let v): voices[c].panning = max(0, voices[c].panning - Int(v))
            case .panSlideRight(let v): voices[c].panning = min(255, voices[c].panning + Int(v))
            case .tonePorta:
                tonePorta(channel: c)
                portaActive = true
            default: break
            }
            switch cell.effect {
            case 0x01: slide(channel: c, by: -Double(Int(voices[c].memPortaUp) * 4))
            case 0x02: slide(channel: c, by: Double(Int(voices[c].memPortaDown) * 4))
            case 0x03:
                tonePorta(channel: c)
                portaActive = true
            case 0x05:
                tonePorta(channel: c)
                portaActive = true
                volumeSlide(channel: c)
            case 0x06, 0x0A: volumeSlide(channel: c)
            case 0x0E: extendedTickN(channel: c, sub: p >> 4, value: Int(p & 0x0F))
            case 0x11:
                let m = voices[c].memGlobalSlide
                if m >> 4 == 0 { globalVolume = max(0, globalVolume - Int(m & 0x0F)) }
                else { globalVolume = min(64, globalVolume + Int(m >> 4)) }
            case 0x14:
                if Int(p) == tick { keyOff(channel: c) }
            case 0x19:
                let m = voices[c].memPanSlide
                if m >> 4 == 0 { voices[c].panning = max(0, voices[c].panning - Int(m & 0x0F)) }
                else { voices[c].panning = min(255, voices[c].panning + Int(m >> 4)) }
            case 0x1B: multiRetrig(channel: c)
            default: break
            }

            // 2. Outputs start from the underlying values.
            voices[c].outPeriod = portaActive && voices[c].glissando && voices[c].period > 0
                ? snapToSemitone(voices[c].period, channel: c) : voices[c].period
            voices[c].outVolume = voices[c].volume

            // 3. Overlays.
            if case .vibrato = volumeCommand { vibrato(channel: c) }
            switch cell.effect {
            case 0x00 where p != 0: arpeggio(channel: c, param: p)
            case 0x04, 0x06: vibrato(channel: c)
            case 0x07: tremolo(channel: c)
            case 0x1D: tremor(channel: c)
            default: break
            }
        }
    }

    private func extendedTickN(channel c: Int, sub: UInt8, value: Int) {
        switch sub {
        case 0x9:
            if value > 0 && tick % value == 0 {
                voices[c].pos = 0
                voices[c].forward = true
                voices[c].active = !voices[c].pcm.isEmpty
                triggerInstrument(channel: c)
            }
        case 0xC:
            if value == tick { voices[c].volume = 0 }
        default:
            break
        }
    }

    private func slide(channel c: Int, by delta: Double) {
        guard voices[c].period > 0 else { return }
        voices[c].period = min(Self.periodRange.upperBound,
                               max(Self.periodRange.lowerBound, voices[c].period + delta))
    }

    private func volumeSlide(channel c: Int) {
        let m = voices[c].memVolSlide
        if m >> 4 == 0 {
            voices[c].volume = max(0, voices[c].volume - Int(m & 0x0F))
        } else {
            voices[c].volume = min(64, voices[c].volume + Int(m >> 4))
        }
    }

    private func tonePorta(channel c: Int) {
        let target = voices[c].targetPeriod
        let speed = Double(voices[c].portaSpeed)
        guard voices[c].period > 0, target > 0, speed > 0 else { return }
        if voices[c].period > target {
            voices[c].period = max(target, voices[c].period - speed)
        } else if voices[c].period < target {
            voices[c].period = min(target, voices[c].period + speed)
        }
    }

    /// FT2 `vibrato2`: 8-bit position, 32-step half table, depth >> 5.
    private func vibrato(channel c: Int) {
        let pos = voices[c].vibratoPos
        var amount = (pos >> 2) & 0x1F
        switch voices[c].waveControl & 0x03 {
        case 0: amount = Self.vibratoTable[amount]
        case 1:
            amount <<= 3
            if pos >= 128 { amount = 255 - amount }
        default: amount = 255
        }
        let delta = Double((amount * voices[c].vibratoDepth) >> 5)
        voices[c].outPeriod = pos < 128 ? voices[c].outPeriod + delta : voices[c].outPeriod - delta
        voices[c].vibratoPos = (pos + voices[c].vibratoSpeed) & 0xFF
    }

    /// FT2 tremolo (the ramp waveform reads the vibrato position, an
    /// FT2 bug reproduced on purpose).
    private func tremolo(channel c: Int) {
        let pos = voices[c].tremoloPos
        var amount = (pos >> 2) & 0x1F
        switch (voices[c].waveControl >> 4) & 0x03 {
        case 0: amount = Self.vibratoTable[amount]
        case 1:
            amount <<= 3
            if voices[c].vibratoPos >= 128 { amount = 255 - amount }
        default: amount = 255
        }
        let delta = (amount * voices[c].tremoloDepth) >> 6
        voices[c].outVolume = pos < 128 ? min(64, voices[c].volume + delta)
                                        : max(0, voices[c].volume - delta)
        voices[c].tremoloPos = (pos + voices[c].tremoloSpeed) & 0xFF
    }

    /// FT2 tremor: x+1 ticks on, y+1 ticks off, state kept across rows.
    private func tremor(channel c: Int) {
        let param = voices[c].memTremor
        var sign = voices[c].tremorPos & 0x80
        var data = Int(voices[c].tremorPos & 0x7F) - 1
        if data < 0 {
            if sign == 0x80 {
                sign = 0
                data = Int(param & 0x0F)
            } else {
                sign = 0x80
                data = Int(param >> 4)
            }
        }
        voices[c].tremorPos = sign | UInt8(data & 0x7F)
        voices[c].outVolume = sign == 0x80 ? voices[c].volume : 0
    }

    private func multiRetrig(channel c: Int) {
        let count = voices[c].retrigCount + 1
        if count < voices[c].retrigSpeed {
            voices[c].retrigCount = count
            return
        }
        voices[c].retrigCount = 0
        var vol = voices[c].volume
        switch voices[c].retrigVolume {
        case 0x1: vol -= 1
        case 0x2: vol -= 2
        case 0x3: vol -= 4
        case 0x4: vol -= 8
        case 0x5: vol -= 16
        case 0x6: vol = vol * 2 / 3
        case 0x7: vol >>= 1
        case 0x9: vol += 1
        case 0xA: vol += 2
        case 0xB: vol += 4
        case 0xC: vol += 8
        case 0xD: vol += 16
        case 0xE: vol = vol * 3 / 2
        case 0xF: vol <<= 1
        default: break
        }
        voices[c].volume = max(0, min(64, vol))
        voices[c].pos = 0
        voices[c].forward = true
        voices[c].active = !voices[c].pcm.isEmpty
    }

    /// FT2 arpeggio: the step comes from the tick counter, which
    /// counts down from `speed`, so the order is (speed - tick) % 3.
    private func arpeggio(channel c: Int, param: UInt8) {
        let semis: Int
        switch (speed - tick) % 3 {
        case 1: semis = Int(param >> 4)
        case 2: semis = Int(param & 0x0F)
        default: semis = 0
        }
        guard semis > 0 else { return }
        if linear {
            voices[c].outPeriod = max(1, voices[c].period - Double(semis * 64))
        } else {
            voices[c].outPeriod = voices[c].period / pow(2, Double(semis) / 12)
        }
    }

    // MARK: - Outputs (envelopes, fade-out, auto-vibrato)

    private func updateOutputs() {
        for c in 0..<voices.count {
            if tick == 0 && !inRowRepeat {
                voices[c].outPeriod = voices[c].period
                voices[c].outVolume = voices[c].volume
            }
            guard voices[c].active, let ins = currentInstrument(c) else {
                voices[c].finalVolume = 0
                continue
            }

            var envVolume = 1.0
            if ins.volumeEnvelope.enabled {
                envVolume = envelopeStep(ins.volumeEnvelope, frame: &voices[c].volEnvFrame,
                                         keyOff: voices[c].keyOff) / 64
            }
            var envPan = 32.0
            if ins.panningEnvelope.enabled {
                envPan = envelopeStep(ins.panningEnvelope, frame: &voices[c].panEnvFrame,
                                      keyOff: voices[c].keyOff)
            }
            if voices[c].keyOff && ins.volumeEnvelope.enabled {
                voices[c].fadeout = max(0, voices[c].fadeout - Int(ins.volumeFadeout))
                if voices[c].fadeout == 0 { voices[c].active = false }
            }

            var period = voices[c].outPeriod
            let av = ins.autoVibrato
            if av.depth > 0 {
                if voices[c].autoVibSweep > 0 && !voices[c].keyOff {
                    voices[c].autoVibAmp += voices[c].autoVibSweep
                    if voices[c].autoVibAmp >> 8 > Int(av.depth) {
                        voices[c].autoVibAmp = Int(av.depth) << 8
                        voices[c].autoVibSweep = 0
                    }
                }
                voices[c].autoVibPos = (voices[c].autoVibPos + Int(av.rate)) & 0xFF
                let pos = voices[c].autoVibPos
                let wave: Int
                switch av.type {
                case 1: wave = pos > 127 ? 64 : -64
                case 2: wave = (((pos >> 1) + 64) & 127) - 64
                case 3: wave = (((-(pos >> 1)) + 64) & 127) - 64
                default: wave = Self.autoVibratoSine[pos]
                }
                period += Double((wave * voices[c].autoVibAmp) >> 14)
            }
            period = min(Self.periodRange.upperBound, max(Self.periodRange.lowerBound, period))
            voices[c].step = frequency(forPeriod: period) / sampleRate

            let volume = Double(voices[c].outVolume) / 64 * envVolume
                * Double(voices[c].fadeout) / 32768 * Double(globalVolume) / 64
            voices[c].finalVolume = Float(max(0, min(1, volume)))

            let pan = Double(voices[c].panning)
            let finalPan = pan + (envPan - 32) * (128 - abs(pan - 128)) / 32
            voices[c].finalPan = Float(max(-1, min(1, (finalPan - 128) / 128)))
        }
    }

    /// Value of `envelope` at `frame`, then advance the frame with
    /// sustain and loop handling.
    private func envelopeStep(_ env: XMInstrument.Envelope, frame: inout Int, keyOff: Bool) -> Double {
        let points = env.points
        guard !points.isEmpty else { return 64 }
        let value = envelopeValue(points, at: frame)

        let count = points.count
        if env.sustainEnabled, env.sustainPoint < count, !keyOff,
           frame == Int(points[env.sustainPoint].frame) {
            return value
        }
        frame += 1
        if env.loopEnabled, env.loopStart <= env.loopEnd, env.loopEnd < count,
           frame == Int(points[env.loopEnd].frame) {
            let releasedAtSustain = keyOff && env.sustainEnabled && env.loopEnd == env.sustainPoint
            if !releasedAtSustain {
                frame = Int(points[env.loopStart].frame)
            }
        }
        frame = min(frame, 0xFFFF)
        return value
    }

    private func envelopeValue(_ points: [XMInstrument.Envelope.Point], at frame: Int) -> Double {
        if frame <= Int(points[0].frame) || points.count == 1 {
            return Double(points[0].value)
        }
        for i in 1..<points.count {
            let b = points[i]
            guard frame < Int(b.frame) else { continue }
            let a = points[i - 1]
            let span = Int(b.frame) - Int(a.frame)
            guard span > 0 else { return Double(b.value) }
            let t = Double(frame - Int(a.frame)) / Double(span)
            return Double(a.value) + (Double(b.value) - Double(a.value)) * min(1, max(0, t))
        }
        return Double(points[points.count - 1].value)
    }

    // MARK: - Frequency math

    /// Period for a 0-based note (C-0 = 0) and finetune (-128...127).
    private func periodFor(note: Int, finetune: Int) -> Double {
        if linear {
            return 7680 - Double(note * 64) - Double(finetune) / 2
        }
        let n = max(0, min(119, note))
        let position = Double(n % 12 * 8 + 8) + Double(finetune) / 16
        let i0 = Int(position.rounded(.down))
        let frac = position - Double(i0)
        func entry(_ i: Int) -> Double {
            i < 96 ? Self.amigaPeriods[max(0, i)] : Self.amigaPeriods[i - 96] / 2
        }
        let base = entry(i0) + (entry(i0 + 1) - entry(i0)) * frac
        return base * 32 / Double(1 << (n / 12))
    }

    private func frequency(forPeriod period: Double) -> Double {
        if linear {
            return 8363 * pow(2, (4608 - period) / 768)
        }
        return 8363 * 1712 / period
    }

    private func snapToSemitone(_ period: Double, channel c: Int) -> Double {
        let finetune = voices[c].finetune
        if linear {
            let note = ((7680 - period - Double(finetune) / 2) / 64).rounded()
            return periodFor(note: Int(note), finetune: finetune)
        }
        var best = period
        var bestDistance = Double.infinity
        for n in 0..<120 {
            let candidate = periodFor(note: n, finetune: finetune)
            let d = abs(candidate - period)
            if d < bestDistance {
                bestDistance = d
                best = candidate
            }
        }
        return best
    }

    // MARK: - Test support

    /// Snapshot of one channel's playback state, for unit tests.
    struct VoiceSnapshot {
        var period: Double
        var outPeriod: Double
        var volume: Int
        var outVolume: Int
        var panning: Int
        var active: Bool
        var pos: Double
        var keyOff: Bool
        var fadeout: Int
        var finalVolume: Float
        var finalPan: Float
        var step: Double
    }

    /// Internal: state of channel `c` (tests only).
    func snapshot(channel c: Int) -> VoiceSnapshot {
        let v = voices[c]
        return VoiceSnapshot(period: v.period, outPeriod: v.outPeriod, volume: v.volume,
                             outVolume: v.outVolume, panning: v.panning, active: v.active,
                             pos: v.pos, keyOff: v.keyOff, fadeout: v.fadeout,
                             finalVolume: v.finalVolume, finalPan: v.finalPan, step: v.step)
    }

    /// Internal: current speed, BPM and global volume (tests only).
    var timing: (speed: Int, bpm: Int, globalVolume: Int) { (speed, bpm, globalVolume) }

    // MARK: - Timing

    /// Frames in the next tick, carrying the fractional remainder so
    /// long renders do not drift.
    private func nextTickFrameCount() -> Int {
        tickFrameFraction += sampleRate / (Double(bpm) * 2 / 5)
        let whole = Int(tickFrameFraction)
        tickFrameFraction -= Double(whole)
        return whole
    }
}
