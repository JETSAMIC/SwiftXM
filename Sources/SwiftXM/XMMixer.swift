/// XMMixer.swift
///
/// Software mixer for an `XMFile`. Iterates the order table,
/// applies the full XM effect set (standard `0..F`, extended `E`
/// subcommands, plus `G/H/K/L/P/R/T/X` and the volume column),
/// processes volume + panning envelopes and fade-out, and writes
/// interleaved stereo `Float32` PCM into a caller-provided buffer.
///
/// ## Timing model
/// XM uses the same speed/tempo split as S3M: `speed` (effect `Fxx`,
/// 1..31) is ticks per row and `tempo` (`Fxx` >= 32, FT2 calls this
/// "BPM") drives the tick rate, with:
///
/// ```
/// tickRateHz       = tempo * 2 / 5
/// samplesPerTick   = sampleRate / tickRateHz
/// samplesPerRow    = samplesPerTick * speed
/// ```
///
/// Note triggers fire on tick 0; continuous effects (slides,
/// vibrato, tremolo, arpeggio, envelopes, fade-out) advance every
/// tick.
///
/// ## Frequency tables
/// XM ships two: linear and Amiga. This implementation supports
/// both, switching automatically based on `XMFile.frequencyTable`.
/// Most modern XMs use linear (the FT2 default); the Amiga table
/// covers Protracker-imported material.
///
/// ## Threading
/// Single-owner mutable state. The host parks the mixer on one
/// thread (typically `AVAudioSourceNode`'s render thread) and
/// never touches it elsewhere. `XMMixer` is `@unchecked Sendable`
/// for this exact pattern; concurrent renders would corrupt voice
/// state.

import Foundation

public final class XMMixer: @unchecked Sendable {

    // MARK: - Configuration

    public let sampleRate: Double

    // MARK: - Module state

    private let file: XMFile
    private var orderIndex: Int = 0
    private var patternIndex: Int = 0
    private var row: Int = 0
    private var tick: Int = 0
    private var speed: Int
    private var tempo: Int
    private var globalVolume: Int = 64
    private var framesRemainingInTick: Int = 0
    private var voices: [Voice]

    /// Set to `true` once the last order has played to completion.
    public private(set) var finished: Bool = false

    // Pattern loop / pattern delay state.
    private var patternLoopRow: Int = 0
    private var patternLoopCount: Int = 0
    private var pendingRowRepeats: Int = 0
    private var suppressNoteTriggers: Bool = false
    private var rowJumped: Bool = false

    // MARK: - Voice state

    private struct Voice {
        var instrumentIndex: Int = 0
        var sampleIndex: Int = 0
        var sample: [Int16] = []
        var samplePos: Double = 0
        var sampleLoopBegin: Int = 0
        var sampleLoopEnd: Int = 0
        var sampleLoopMode: XMSample.LoopMode = .none
        var samplePingPongForward: Bool = true

        /// Current period (linear or Amiga depending on table).
        var period: Double = 0
        /// Original period set by the last note trigger (vibrato
        /// modulation hangs off this value).
        var basePeriod: Double = 0
        var tonePortaTarget: Double = 0
        /// Frame increment used by the mixer per output sample.
        var effectiveStep: Double = 0

        /// Channel volume 0..64.
        var volume: Int = 64
        /// Envelope+fadeout-adjusted volume the mixer renders with.
        var effectiveVolume: Double = 1.0

        /// Channel panning 0..255. 128 = centre.
        var panning: Int = 128
        var effectivePan: Float = 0

        /// 0..65535. Decrements by instrument.fadeout each tick
        /// after key-off (when the volume envelope is enabled).
        var fadeoutVol: Int = 65_536
        var keyOff: Bool = false

        // Envelope frame counters (advance every tick when enabled).
        var volEnvFrame: Int = 0
        var panEnvFrame: Int = 0
        var volEnvOn: Bool = false
        var panEnvOn: Bool = false

        // Effect memories.
        var lastPortaUp: UInt8 = 0
        var lastPortaDown: UInt8 = 0
        var lastTonePorta: UInt8 = 0
        var lastVibrato: UInt8 = 0
        var lastTremolo: UInt8 = 0
        var lastVolumeSlide: UInt8 = 0
        var lastFineSlideUp: UInt8 = 0
        var lastFineSlideDown: UInt8 = 0
        var lastSampleOffset: UInt8 = 0
        var lastGlobalSlide: UInt8 = 0
        var lastPanSlide: UInt8 = 0
        var lastRetrigger: UInt8 = 0
        var lastExtraFineUp: UInt8 = 0
        var lastExtraFineDown: UInt8 = 0
        var lastTremor: UInt8 = 0

        // Vibrato + tremolo oscillators.
        var vibratoPos: Int = 0
        var vibratoSpeed: Int = 0
        var vibratoDepth: Int = 0
        var vibratoWaveform: UInt8 = 0
        var vibratoActive: Bool = false
        var tremoloPos: Int = 0
        var tremoloSpeed: Int = 0
        var tremoloDepth: Int = 0
        var tremoloWaveform: UInt8 = 0
        var tremoloActive: Bool = false

        // Tremor (Txx).
        var tremorOn: Bool = true
        var tremorCount: Int = 0
        var tremorActive: Bool = false

        // Per-row pending note (only triggered after volume column
        // + effect parse so tone-porta can suppress retrigger).
        var pendingNote: UInt8 = 0
        var pendingInstrument: UInt8 = 0

        // Auto-vibrato state. `autoVibFrame` advances every tick
        // while the note plays. Once key-off fires the sweep
        // multiplier freezes at `frozenAutoVibSweep` so the depth
        // doesn't keep ramping up after release (FT2 quirk).
        var autoVibFrame: Int = 0
        var frozenAutoVibSweep: Double? = nil

        // Glissando: when set, tone-porta snaps the resulting
        // period to the nearest whole semitone instead of sliding
        // continuously (extended effect E3x).
        var glissandoActive: Bool = false

        var active: Bool = false
    }

    // MARK: - Init

    public init(file: XMFile, sampleRate: Double) {
        self.file = file
        self.sampleRate = sampleRate
        self.speed = max(1, file.defaultTempo)
        self.tempo = max(32, file.defaultBPM)
        self.voices = Array(repeating: Voice(), count: file.channelCount)
        // Default per-channel panning: even channels left of
        // centre, odd channels right (classic Amiga LRRL).
        for i in 0..<file.channelCount {
            // FT2 defaults all channels to centre (128).
            voices[i].panning = 128
            voices[i].effectivePan = 0
        }
        self.framesRemainingInTick = framesPerTick()
        beginRow(applyNotes: true)
        recomputeEffectiveState()
    }

    // MARK: - Render entry point

    @discardableResult
    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        var written = 0
        while written < frames {
            if finished { break }
            let toWrite = min(frames - written, framesRemainingInTick)
            renderChunk(into: buffer.advanced(by: written * 2), frames: toWrite)
            written += toWrite
            framesRemainingInTick -= toWrite
            if framesRemainingInTick == 0 {
                advanceTick()
                if finished { break }
                framesRemainingInTick = framesPerTick()
            }
        }
        if written < frames {
            let tail = (frames - written) * 2
            buffer.advanced(by: written * 2).update(repeating: 0, count: tail)
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

    private func mixVoice(into buffer: UnsafeMutablePointer<Float>, frames: Int, voice: Int) {
        let amp = Float(voices[voice].effectiveVolume) *
                  Float(globalVolume) / 64.0 /
                  Float(max(1, min(32, file.channelCount)))
        let pan = voices[voice].effectivePan
        let panL = max(0, (1 - pan) * 0.5)
        let panR = max(0, (1 + pan) * 0.5)

        let sample = voices[voice].sample
        let loopBegin = voices[voice].sampleLoopBegin
        let loopEnd = voices[voice].sampleLoopEnd
        let loopMode = voices[voice].sampleLoopMode
        var pos = voices[voice].samplePos
        var forward = voices[voice].samplePingPongForward
        let step = voices[voice].effectiveStep

        guard sample.count > 0 else {
            voices[voice].active = false
            return
        }

        for i in 0..<frames {
            var intPos = Int(pos)
            if intPos >= sample.count {
                // End of sample: handle loop modes.
                switch loopMode {
                case .none:
                    voices[voice].active = false
                    voices[voice].samplePos = pos
                    voices[voice].samplePingPongForward = forward
                    return
                case .forward:
                    if loopEnd > loopBegin {
                        let span = Double(loopEnd - loopBegin)
                        pos = Double(loopBegin) + (pos - Double(loopBegin)).truncatingRemainder(dividingBy: span)
                        intPos = Int(pos)
                    } else {
                        voices[voice].active = false
                        return
                    }
                case .pingPong:
                    if loopEnd > loopBegin {
                        pos = Double(loopEnd) - (pos - Double(loopEnd)) - 1
                        forward = false
                        intPos = Int(pos)
                    } else {
                        voices[voice].active = false
                        return
                    }
                }
            }
            if intPos < 0 {
                if loopMode == .pingPong {
                    pos = Double(loopBegin) + (Double(loopBegin) - pos)
                    forward = true
                    intPos = Int(pos)
                } else {
                    voices[voice].active = false
                    return
                }
            }

            let s0 = Float(sample[intPos]) / 32768.0
            let s1Idx = intPos + 1
            let s1 = s1Idx < sample.count ? Float(sample[s1Idx]) / 32768.0 : s0
            let frac = Float(pos - Double(intPos))
            let s = s0 + (s1 - s0) * frac

            buffer[i * 2]     += s * amp * panL
            buffer[i * 2 + 1] += s * amp * panR

            if forward {
                pos += step
                if loopMode == .pingPong && pos >= Double(loopEnd) {
                    forward = false
                }
            } else {
                pos -= step
                if pos <= Double(loopBegin) {
                    pos = Double(loopBegin) + (Double(loopBegin) - pos)
                    forward = true
                }
            }
        }
        voices[voice].samplePos = pos
        voices[voice].samplePingPongForward = forward
    }

    // MARK: - Tick / row advancement

    private func advanceTick() {
        tick += 1
        if tick >= speed {
            tick = 0
            if pendingRowRepeats > 0 {
                pendingRowRepeats -= 1
                suppressNoteTriggers = true
                beginRow(applyNotes: false)
                suppressNoteTriggers = false
            } else if rowJumped {
                rowJumped = false
                if !nextValidOrder() { finished = true; return }
                beginRow(applyNotes: true)
            } else {
                row += 1
                let pattern = file.patterns[patternIndex]
                if row >= pattern.rowCount {
                    row = 0
                    orderIndex += 1
                    if !nextValidOrder() { finished = true; return }
                }
                beginRow(applyNotes: true)
            }
        } else {
            applyTickEffects()
        }
        advanceEnvelopes()
        recomputeEffectiveState()
    }

    private func nextValidOrder() -> Bool {
        while orderIndex < file.songLength && orderIndex < file.order.count {
            let p = Int(file.order[orderIndex])
            if p < file.patterns.count {
                patternIndex = p
                return true
            }
            orderIndex += 1
        }
        return false
    }

    private func beginRow(applyNotes: Bool) {
        guard patternIndex < file.patterns.count else {
            finished = true; return
        }
        let pattern = file.patterns[patternIndex]
        guard row >= 0 && row < pattern.rowCount else { return }
        let cells = pattern.rows[row]

        // Reset per-row effect overlays.
        for c in 0..<voices.count {
            voices[c].vibratoActive = false
            voices[c].tremoloActive = false
            voices[c].tremorActive = false
        }

        for ch in 0..<min(cells.count, voices.count) {
            let cell = cells[ch]
            applyTriggerCell(channel: ch, cell: cell, applyNotes: applyNotes)
        }
    }

    private func applyTriggerCell(channel: Int, cell: XMPattern.Cell, applyNotes: Bool) {
        let usesTonePorta = cell.effect == 0x03 || cell.effect == 0x05
            || (XMVolumeCommand(byte: cell.volume) as XMVolumeCommand) == .tonePorta(0)

        // Handle note delay (E Dx) before everything else.
        if cell.effect == 0x0E && (cell.param >> 4) == 0xD && applyNotes {
            voices[channel].pendingNote = cell.note
            voices[channel].pendingInstrument = cell.instrument
            // Effects still run on tick 0 in FT2; we no-op the
            // note trigger and let the tick effects fire.
            applyEffectTick0(channel: channel, effect: cell.effect, param: cell.param)
            applyVolumeColumn(channel: channel, byte: cell.volume)
            return
        }

        if applyNotes {
            // Instrument set: load defaults but don't trigger
            // sample yet (sample swap happens with the note).
            if cell.instrument > 0 {
                installInstrumentDefaults(channel: channel, instrument: cell.instrument)
            }
            // Note?
            if cell.note > 0 && cell.note <= 97 {
                if cell.note == 97 {
                    voices[channel].keyOff = true
                } else if usesTonePorta {
                    setTonePortaTarget(channel: channel, note: cell.note)
                } else {
                    triggerNote(channel: channel, note: cell.note, instrument: cell.instrument)
                }
            }
        }

        applyVolumeColumn(channel: channel, byte: cell.volume)
        applyEffectTick0(channel: channel, effect: cell.effect, param: cell.param)
    }

    private func installInstrumentDefaults(channel: Int, instrument: UInt8) {
        let idx = Int(instrument) - 1
        guard idx >= 0, idx < file.instruments.count else { return }
        let ins = file.instruments[idx]
        voices[channel].instrumentIndex = idx
        // FT2 sets the default sample for the current note (or
        // the previous note if no new note this row).
        if let sampleIdx = sampleIndex(for: voices[channel].pendingNote, instrument: ins),
           sampleIdx < ins.samples.count {
            voices[channel].volume  = Int(ins.samples[sampleIdx].volume)
            voices[channel].panning = Int(ins.samples[sampleIdx].panning)
        }
        voices[channel].volEnvOn = ins.volumeEnvelope.enabled
        voices[channel].panEnvOn = ins.panningEnvelope.enabled
        voices[channel].fadeoutVol = 65_536
        voices[channel].keyOff = false
        voices[channel].volEnvFrame = 0
        voices[channel].panEnvFrame = 0
    }

    private func triggerNote(channel: Int, note: UInt8, instrument: UInt8) {
        let insIdx = instrument > 0
            ? Int(instrument) - 1
            : voices[channel].instrumentIndex
        guard insIdx >= 0, insIdx < file.instruments.count else { return }
        let ins = file.instruments[insIdx]
        guard let sampleIdx = sampleIndex(for: note, instrument: ins),
              sampleIdx < ins.samples.count else {
            voices[channel].active = false
            return
        }
        let smp = ins.samples[sampleIdx]
        voices[channel].instrumentIndex = insIdx
        voices[channel].sampleIndex = sampleIdx
        voices[channel].sample = smp.pcm
        voices[channel].sampleLoopBegin = smp.loopBegin
        voices[channel].sampleLoopEnd = smp.loopEnd
        voices[channel].sampleLoopMode = smp.loopMode
        voices[channel].samplePingPongForward = true
        voices[channel].samplePos = 0
        voices[channel].volume = Int(smp.volume)
        voices[channel].panning = Int(smp.panning)
        voices[channel].volEnvOn = ins.volumeEnvelope.enabled
        voices[channel].panEnvOn = ins.panningEnvelope.enabled
        voices[channel].volEnvFrame = 0
        voices[channel].panEnvFrame = 0
        voices[channel].fadeoutVol = 65_536
        voices[channel].keyOff = false
        voices[channel].vibratoPos = 0
        voices[channel].tremoloPos = 0
        voices[channel].autoVibFrame = 0
        voices[channel].active = !smp.pcm.isEmpty
        voices[channel].pendingNote = note

        let realNote = Int(note) + Int(smp.relativeNote)
        let period = computePeriod(note: realNote, finetune: Int(smp.finetune))
        voices[channel].period = period
        voices[channel].basePeriod = period
        voices[channel].tonePortaTarget = period
    }

    private func setTonePortaTarget(channel: Int, note: UInt8) {
        let insIdx = voices[channel].instrumentIndex
        guard insIdx >= 0, insIdx < file.instruments.count else { return }
        let ins = file.instruments[insIdx]
        guard let sampleIdx = sampleIndex(for: note, instrument: ins),
              sampleIdx < ins.samples.count else { return }
        let smp = ins.samples[sampleIdx]
        let realNote = Int(note) + Int(smp.relativeNote)
        voices[channel].tonePortaTarget = computePeriod(note: realNote, finetune: Int(smp.finetune))
        voices[channel].pendingNote = note
    }

    private func sampleIndex(for note: UInt8, instrument: XMInstrument) -> Int? {
        guard note >= 1 && note <= 96 else { return nil }
        return Int(instrument.sampleMap[Int(note) - 1])
    }

    // MARK: - Volume column

    private func applyVolumeColumn(channel: Int, byte: UInt8) {
        let cmd = XMVolumeCommand(byte: byte)
        switch cmd {
        case .none: break
        case .setVolume(let v):
            voices[channel].volume = Int(min(64, v))
        case .slideDown(let v):
            voices[channel].lastVolumeSlide = v
        case .slideUp(let v):
            voices[channel].lastVolumeSlide = v << 4
        case .fineSlideDown(let v):
            voices[channel].volume = max(0, voices[channel].volume - Int(v))
        case .fineSlideUp(let v):
            voices[channel].volume = min(64, voices[channel].volume + Int(v))
        case .setVibratoSpeed(let v):
            if v != 0 { voices[channel].vibratoSpeed = Int(v) }
        case .vibrato(let depth):
            if depth != 0 { voices[channel].vibratoDepth = Int(depth) }
            voices[channel].vibratoActive = true
        case .setPanning(let v):
            voices[channel].panning = Int(v)
        case .panSlideLeft(let v):
            voices[channel].panning = max(0, voices[channel].panning - Int(v))
        case .panSlideRight(let v):
            voices[channel].panning = min(255, voices[channel].panning + Int(v))
        case .tonePorta(let rate):
            if rate != 0 { voices[channel].lastTonePorta = rate }
        }
    }

    // MARK: - Effects (Tick 0)

    private func applyEffectTick0(channel: Int, effect: UInt8, param: UInt8) {
        switch effect {
        case 0x00: // Arpeggio (handled per tick)
            if param != 0 { voices[channel].lastVibrato = param /* repurposed via lastArpeggio elsewhere */ }
        case 0x01: // Porta up
            if param != 0 { voices[channel].lastPortaUp = param }
        case 0x02: // Porta down
            if param != 0 { voices[channel].lastPortaDown = param }
        case 0x03: // Tone porta
            if param != 0 { voices[channel].lastTonePorta = param }
        case 0x04: // Vibrato
            let hi = (param >> 4) & 0x0F
            let lo = param & 0x0F
            if hi != 0 { voices[channel].vibratoSpeed = Int(hi) }
            if lo != 0 { voices[channel].vibratoDepth = Int(lo) }
            voices[channel].vibratoActive = true
        case 0x05: // Tone porta + volume slide
            if param != 0 { voices[channel].lastVolumeSlide = param }
        case 0x06: // Vibrato + volume slide
            if param != 0 { voices[channel].lastVolumeSlide = param }
            voices[channel].vibratoActive = true
        case 0x07: // Tremolo
            let hi = (param >> 4) & 0x0F
            let lo = param & 0x0F
            if hi != 0 { voices[channel].tremoloSpeed = Int(hi) }
            if lo != 0 { voices[channel].tremoloDepth = Int(lo) }
            voices[channel].tremoloActive = true
        case 0x08: // Set panning
            voices[channel].panning = Int(param)
        case 0x09: // Sample offset
            if param != 0 { voices[channel].lastSampleOffset = param }
            voices[channel].samplePos = Double(Int(voices[channel].lastSampleOffset) * 256)
            if Int(voices[channel].samplePos) >= voices[channel].sample.count {
                voices[channel].active = false
            }
        case 0x0A: // Volume slide
            if param != 0 { voices[channel].lastVolumeSlide = param }
        case 0x0B: // Position jump
            orderIndex = Int(param)
            row = 0
            rowJumped = true
        case 0x0C: // Set volume
            voices[channel].volume = Int(min(64, param))
        case 0x0D: // Pattern break
            let target = Int((param >> 4) * 10 + (param & 0x0F))
            orderIndex += 1
            row = max(0, target)
            rowJumped = true
        case 0x0E: // Extended
            handleETick0(channel: channel, param: param)
        case 0x0F: // Set speed / tempo
            if param > 0 {
                if param < 0x20 { speed = Int(param) }
                else            { tempo = Int(param) }
            }
        case 0x10: // G — global volume
            globalVolume = Int(min(64, param))
        case 0x11: // H — global volume slide
            if param != 0 { voices[channel].lastGlobalSlide = param }
        case 0x14: // K — key off
            voices[channel].keyOff = true
        case 0x15: // L — set envelope position
            voices[channel].volEnvFrame = Int(param)
            voices[channel].panEnvFrame = Int(param)
        case 0x19: // P — panning slide
            if param != 0 { voices[channel].lastPanSlide = param }
        case 0x1B: // R — multi retrig
            if param != 0 { voices[channel].lastRetrigger = param }
        case 0x1D: // T — tremor
            if param != 0 { voices[channel].lastTremor = param }
            voices[channel].tremorActive = true
        case 0x21: // X — extra fine porta
            let hi = (param >> 4) & 0x0F
            let lo = param & 0x0F
            if hi == 1 {
                if lo != 0 { voices[channel].lastExtraFineUp = lo }
                voices[channel].period = max(1, voices[channel].period - Double(voices[channel].lastExtraFineUp))
                voices[channel].basePeriod = voices[channel].period
            } else if hi == 2 {
                if lo != 0 { voices[channel].lastExtraFineDown = lo }
                voices[channel].period += Double(voices[channel].lastExtraFineDown)
                voices[channel].basePeriod = voices[channel].period
            }
        default:
            break
        }
    }

    private func handleETick0(channel: Int, param: UInt8) {
        let cmd = (param >> 4) & 0x0F
        let v   = param & 0x0F
        switch cmd {
        case 0x1: // Fine porta up
            if v != 0 { voices[channel].lastFineSlideUp = v }
            voices[channel].period = max(1, voices[channel].period - Double(voices[channel].lastFineSlideUp) * 4)
            voices[channel].basePeriod = voices[channel].period
        case 0x2: // Fine porta down
            if v != 0 { voices[channel].lastFineSlideDown = v }
            voices[channel].period += Double(voices[channel].lastFineSlideDown) * 4
            voices[channel].basePeriod = voices[channel].period
        case 0x3: // Glissando control
            // E30 = off (smooth slide, the default); E31 = on
            // (tone-porta snaps to semitone boundaries). Any non-
            // zero param enables it.
            voices[channel].glissandoActive = (v & 0x0F) != 0
        case 0x4: // Vibrato waveform
            voices[channel].vibratoWaveform = v & 0x03
        case 0x5: // Set finetune (modifies period base, not c2spd)
            break
        case 0x6: // Pattern loop
            handleSBPatternLoop(value: Int(v))
        case 0x7: // Tremolo waveform
            voices[channel].tremoloWaveform = v & 0x03
        case 0x9: // Retrigger
            // E9x retriggers every (v) ticks; handled in applyTickEffects.
            voices[channel].lastRetrigger = v
        case 0xA: // Fine volume slide up
            voices[channel].volume = min(64, voices[channel].volume + Int(v))
        case 0xB: // Fine volume slide down
            voices[channel].volume = max(0, voices[channel].volume - Int(v))
        case 0xC: // Note cut
            if v == 0 { voices[channel].volume = 0 }
        case 0xD: // Note delay (already handled in applyTriggerCell)
            break
        case 0xE: // Pattern delay
            pendingRowRepeats = Int(v)
        default:
            break
        }
    }

    private func handleSBPatternLoop(value: Int) {
        if value == 0 {
            patternLoopRow = row
        } else {
            if patternLoopCount == 0 { patternLoopCount = value }
            else                     { patternLoopCount -= 1 }
            if patternLoopCount > 0 {
                row = max(0, patternLoopRow)
                rowJumped = true
            }
        }
    }

    // MARK: - Effects (tick > 0)

    private func applyTickEffects() {
        guard patternIndex < file.patterns.count else { return }
        let pattern = file.patterns[patternIndex]
        guard row < pattern.rows.count else { return }
        let cells = pattern.rows[row]

        for ch in 0..<min(cells.count, voices.count) {
            let cell = cells[ch]
            // Volume column slide commands fire each tick.
            tickVolumeColumn(channel: ch, byte: cell.volume)

            switch cell.effect {
            case 0x00:
                if cell.param != 0 {
                    applyArpeggio(channel: ch, param: cell.param)
                }
            case 0x01:
                voices[ch].period = max(1, voices[ch].period - Double(voices[ch].lastPortaUp) * 4)
                voices[ch].basePeriod = voices[ch].period
            case 0x02:
                voices[ch].period += Double(voices[ch].lastPortaDown) * 4
                voices[ch].basePeriod = voices[ch].period
            case 0x03:
                applyTonePorta(channel: ch)
            case 0x04:
                if voices[ch].vibratoActive { /* effective state recomputed below */ }
            case 0x05:
                applyTonePorta(channel: ch)
                applyVolumeSlide(channel: ch, info: voices[ch].lastVolumeSlide)
            case 0x06:
                applyVolumeSlide(channel: ch, info: voices[ch].lastVolumeSlide)
            case 0x07:
                break
            case 0x0A:
                applyVolumeSlide(channel: ch, info: voices[ch].lastVolumeSlide)
            case 0x0E:
                let cmd = (cell.param >> 4) & 0x0F
                let v   = cell.param & 0x0F
                // ECx note cut: zero the channel volume on tick v.
                // Conventional FT2 fires the cut on the EXACT tick
                // requested (so EC1 cuts on tick 1, not tick 0 or
                // earlier). EC0 cuts immediately on tick 0.
                if cmd == 0xC && Int(v) == tick {
                    voices[ch].volume = 0
                }
                // E9x retrigger: fire on ticks where
                // `tick % v == 0 && tick > 0` so the note isn't
                // re-triggered on its own row-start tick (the
                // original row trigger has already played it).
                if cmd == 0x9 && v > 0 && tick > 0 && tick % Int(v) == 0 {
                    voices[ch].samplePos = 0
                    voices[ch].active = !voices[ch].sample.isEmpty
                    voices[ch].autoVibFrame = 0
                    voices[ch].frozenAutoVibSweep = nil
                }
                // EDx note delay: trigger the row's pending note
                // when `tick == v`. The row's actual note was
                // queued in `pendingNote` rather than played, so we
                // fire it here. v == 0 falls through (already played
                // on tick 0).
                if cmd == 0xD && Int(v) == tick && v > 0 {
                    if voices[ch].pendingNote != 0 {
                        triggerNote(channel: ch,
                                    note: voices[ch].pendingNote,
                                    instrument: voices[ch].pendingInstrument)
                        voices[ch].pendingNote = 0
                        voices[ch].pendingInstrument = 0
                    }
                }
            case 0x11: // H — global volume slide
                let info = voices[ch].lastGlobalSlide
                let hi = Int((info >> 4) & 0x0F)
                let lo = Int(info & 0x0F)
                if hi != 0 { globalVolume = min(64, globalVolume + hi) }
                else if lo != 0 { globalVolume = max(0, globalVolume - lo) }
            case 0x19: // P — panning slide
                let info = voices[ch].lastPanSlide
                let hi = Int((info >> 4) & 0x0F)
                let lo = Int(info & 0x0F)
                if hi != 0 { voices[ch].panning = min(255, voices[ch].panning + hi) }
                else if lo != 0 { voices[ch].panning = max(0, voices[ch].panning - lo) }
            case 0x1B: // R — multi retrigger
                // Param is `0xXY` — X selects a volume-change op
                // applied each retrigger, Y is the tick interval.
                // The retrigger restarts the sample position and
                // the auto-vibrato sweep counter; the volume change
                // happens on every retrigger after the first.
                let info = voices[ch].lastRetrigger
                let xx = Int((info >> 4) & 0x0F)
                let yy = Int(info & 0x0F)
                if yy > 0 && tick % yy == 0 {
                    voices[ch].samplePos = 0
                    voices[ch].active = !voices[ch].sample.isEmpty
                    voices[ch].autoVibFrame = 0
                    voices[ch].frozenAutoVibSweep = nil
                    if tick > 0 {
                        voices[ch].volume = applyRetriggerVolumeOp(
                            voices[ch].volume,
                            op: xx
                        )
                    }
                }
            case 0x1D: // T — tremor
                advanceTremor(channel: ch)
            default:
                break
            }
        }
    }

    private func tickVolumeColumn(channel: Int, byte: UInt8) {
        let cmd = XMVolumeCommand(byte: byte)
        switch cmd {
        case .slideDown(let v):
            voices[channel].volume = max(0, voices[channel].volume - Int(v))
        case .slideUp(let v):
            voices[channel].volume = min(64, voices[channel].volume + Int(v))
        case .panSlideLeft(let v):
            voices[channel].panning = max(0, voices[channel].panning - Int(v))
        case .panSlideRight(let v):
            voices[channel].panning = min(255, voices[channel].panning + Int(v))
        case .tonePorta:
            applyTonePorta(channel: channel)
        default:
            break
        }
    }

    private func applyArpeggio(channel: Int, param: UInt8) {
        let phase = tick % 3
        let offset: Int
        switch phase {
        case 1: offset = Int(param >> 4)
        case 2: offset = Int(param & 0x0F)
        default: offset = 0
        }
        if offset == 0 {
            voices[channel].period = voices[channel].basePeriod
        } else {
            // Reduce period by `offset` semitones (higher pitch).
            voices[channel].period = voices[channel].basePeriod - Double(offset * 64)
        }
    }

    private func applyVolumeSlide(channel: Int, info: UInt8) {
        let hi = Int((info >> 4) & 0x0F)
        let lo = Int(info & 0x0F)
        if hi != 0 { voices[channel].volume = min(64, voices[channel].volume + hi) }
        else if lo != 0 { voices[channel].volume = max(0, voices[channel].volume - lo) }
    }

    private func applyTonePorta(channel: Int) {
        let rate = Int(voices[channel].lastTonePorta) * 4
        guard rate > 0 else { return }
        let target = voices[channel].tonePortaTarget
        var p = voices[channel].period
        if p < target {
            p = min(target, p + Double(rate))
        } else if p > target {
            p = max(target, p - Double(rate))
        }
        // Glissando control (E3x): snap the sliding period to its
        // nearest whole-semitone period so the slide steps rather
        // than glides. Only affects the active-display period; the
        // tone-porta target still steers the direction.
        if voices[channel].glissandoActive {
            p = snapPeriodToSemitone(p, finetune: 0)
        }
        voices[channel].period = p
        voices[channel].basePeriod = p
    }

    /// Round `period` to the nearest whole-semitone period in the
    /// current frequency table. Used by the E3x glissando-control
    /// flag — when set, tone-porta lands on semitone boundaries
    /// rather than gliding continuously through them.
    private func snapPeriodToSemitone(_ period: Double, finetune: Int) -> Double {
        switch file.frequencyTable {
        case .linear:
            // Linear period = 7680 - note*64 - finetune/2 → invert.
            let approxNote = (7680.0 - period - Double(finetune) / 2.0) / 64.0
            let nearest = Int(approxNote.rounded())
            return computePeriod(note: nearest, finetune: finetune)
        case .amiga:
            // Amiga periods don't share a simple inverse, so walk
            // a handful of candidate notes and pick the closest.
            var bestNote = 0
            var bestDistance = Double.infinity
            for n in 0..<120 {
                let candidate = computePeriod(note: n, finetune: finetune)
                let d = abs(candidate - period)
                if d < bestDistance { bestDistance = d; bestNote = n }
            }
            return computePeriod(note: bestNote, finetune: finetune)
        }
    }

    /// Apply the per-retrigger volume change selected by the high
    /// nibble of an Rxy parameter. Sixteen ops in total — eight
    /// linear deltas, two ratios in each direction, and three
    /// no-ops on the boundary values. Clamps to 0..64.
    private func applyRetriggerVolumeOp(_ volume: Int, op: Int) -> Int {
        switch op {
        case 0, 8: return volume
        case 1: return max(0, volume - 1)
        case 2: return max(0, volume - 2)
        case 3: return max(0, volume - 4)
        case 4: return max(0, volume - 8)
        case 5: return max(0, volume - 16)
        case 6: return max(0, (volume * 2) / 3)
        case 7: return max(0, volume / 2)
        case 9: return min(64, volume + 1)
        case 0xA: return min(64, volume + 2)
        case 0xB: return min(64, volume + 4)
        case 0xC: return min(64, volume + 8)
        case 0xD: return min(64, volume + 16)
        case 0xE: return min(64, (volume * 3) / 2)
        case 0xF: return min(64, volume * 2)
        default: return volume
        }
    }

    private func advanceTremor(channel: Int) {
        let info = voices[channel].lastTremor
        let onTicks = Int(info >> 4) + 1
        let offTicks = Int(info & 0x0F) + 1
        voices[channel].tremorCount += 1
        let cycle = onTicks + offTicks
        let phase = voices[channel].tremorCount % cycle
        voices[channel].tremorOn = phase < onTicks
    }

    // MARK: - Envelopes + fadeout

    private func advanceEnvelopes() {
        for c in 0..<voices.count where voices[c].active {
            let insIdx = voices[c].instrumentIndex
            guard insIdx >= 0, insIdx < file.instruments.count else { continue }
            let ins = file.instruments[insIdx]
            if voices[c].volEnvOn {
                voices[c].volEnvFrame += 1
            }
            if voices[c].panEnvOn {
                voices[c].panEnvFrame += 1
            }
            // Fade-out runs after key-off when the volume envelope
            // is enabled (FT2 behaviour per spec).
            if voices[c].keyOff && voices[c].volEnvOn {
                voices[c].fadeoutVol -= Int(ins.volumeFadeout)
                if voices[c].fadeoutVol <= 0 {
                    voices[c].fadeoutVol = 0
                    voices[c].active = false
                }
            }
        }
    }

    // MARK: - Effective-state recompute

    private func recomputeEffectiveState() {
        for c in 0..<voices.count where voices[c].active {
            // Vibrato modulates period (lowering = higher pitch).
            var period = voices[c].period
            if voices[c].vibratoActive && voices[c].vibratoDepth > 0 {
                let w = waveformSample(pos: voices[c].vibratoPos,
                                       waveform: voices[c].vibratoWaveform)
                period -= Double(w * voices[c].vibratoDepth) / 16.0
                voices[c].vibratoPos = (voices[c].vibratoPos + voices[c].vibratoSpeed) & 0x3F
            }

            // Auto-vibrato — instrument-level LFO that runs the
            // whole time a note is held. The depth ramps up over
            // `autoVibrato.sweep` frames; once the note keys off,
            // we freeze the sweep multiplier so the depth doesn't
            // keep growing through the fade-out (FT2 quirk).
            let avInsIdx = voices[c].instrumentIndex
            if avInsIdx >= 0, avInsIdx < file.instruments.count {
                let ins = file.instruments[avInsIdx]
                let av = ins.autoVibrato
                if av.rate > 0 && av.depth > 0 {
                    let sweep = Int(av.sweep)
                    let frame = voices[c].autoVibFrame
                    let liveMult: Double = sweep > 0
                        ? min(1.0, Double(frame) / Double(sweep))
                        : 1.0
                    let mult: Double
                    if voices[c].keyOff {
                        if voices[c].frozenAutoVibSweep == nil {
                            voices[c].frozenAutoVibSweep = liveMult
                        }
                        mult = voices[c].frozenAutoVibSweep ?? liveMult
                    } else {
                        mult = liveMult
                    }
                    let pos = (frame * Int(av.rate) / 4) & 0x3F
                    let w = waveformSample(pos: pos, waveform: av.type)
                    period -= Double(w) * Double(av.depth) * mult / 64.0
                    voices[c].autoVibFrame &+= 1
                }
            }

            period = max(1, period)
            let freq = frequency(forPeriod: period)
            voices[c].effectiveStep = freq / sampleRate

            let insIdx = voices[c].instrumentIndex
            let ins: XMInstrument? = (insIdx >= 0 && insIdx < file.instruments.count)
                ? file.instruments[insIdx] : nil

            // Volume: channel × envelope × fadeout × tremolo × tremor.
            var vol = Double(voices[c].volume) / 64.0
            if let ins, voices[c].volEnvOn {
                vol *= envelopeValue(envelope: ins.volumeEnvelope, frame: voices[c].volEnvFrame) / 64.0
            }
            if voices[c].keyOff && voices[c].volEnvOn {
                vol *= Double(voices[c].fadeoutVol) / 65536.0
            } else if voices[c].keyOff && !voices[c].volEnvOn {
                vol = 0
                voices[c].active = false
            }
            if voices[c].tremoloActive && voices[c].tremoloDepth > 0 {
                let w = waveformSample(pos: voices[c].tremoloPos,
                                       waveform: voices[c].tremoloWaveform)
                vol += Double(w * voices[c].tremoloDepth) / 64.0 / 64.0
                voices[c].tremoloPos = (voices[c].tremoloPos + voices[c].tremoloSpeed) & 0x3F
            }
            if voices[c].tremorActive && !voices[c].tremorOn {
                vol = 0
            }
            voices[c].effectiveVolume = max(0, min(1, vol))

            // Pan: channel pan tempered by panning envelope.
            var pan = Double(voices[c].panning - 128) / 128.0
            if let ins, voices[c].panEnvOn {
                let env = envelopeValue(envelope: ins.panningEnvelope, frame: voices[c].panEnvFrame)
                // 0..64 envelope value; 32 = centre.
                pan += (env - 32.0) / 32.0 * (1.0 - abs(pan))
            }
            voices[c].effectivePan = Float(max(-1, min(1, pan)))
        }
    }

    private func envelopeValue(envelope: XMInstrument.Envelope, frame: Int) -> Double {
        guard !envelope.points.isEmpty else { return 64.0 }
        let f = frame
        if f <= Int(envelope.points[0].frame) {
            return Double(envelope.points[0].value)
        }
        for i in 0..<(envelope.points.count - 1) {
            let a = envelope.points[i]
            let b = envelope.points[i + 1]
            if f < Int(b.frame) {
                let span = Double(b.frame - a.frame)
                guard span > 0 else { return Double(a.value) }
                let dy = Double(b.value) - Double(a.value)
                let dx = Double(f - Int(a.frame))
                return Double(a.value) + dy * dx / span
            }
        }
        return Double(envelope.points.last!.value)
    }

    // MARK: - Waveform LUTs

    private static let sineTable: [Int] = (0..<64).map {
        Int((sin(Double($0) * .pi / 32.0) * 64.0).rounded())
    }
    private static let rampDownTable: [Int] = (0..<64).map { 64 - $0 * 2 - 1 }
    private static let squareTable: [Int] = (0..<64).map { $0 < 32 ? 64 : -64 }

    private func waveformSample(pos: Int, waveform: UInt8) -> Int {
        let i = pos & 0x3F
        switch waveform & 0x03 {
        case 0: return Self.sineTable[i]
        case 1: return Self.rampDownTable[i]
        case 2: return Self.squareTable[i]
        default: return Self.sineTable[i]
        }
    }

    // MARK: - Frequency math

    /// Compute period from a note (1..96 nominal) and finetune
    /// (-128..+127). Real note may exceed 96 once relative-note
    /// offsets are applied.
    private func computePeriod(note: Int, finetune: Int) -> Double {
        switch file.frequencyTable {
        case .linear:
            return 7680.0 - Double(note) * 64.0 - Double(finetune) / 2.0
        case .amiga:
            let n = max(0, min(95, note))
            let idx = (n % 12) * 8 + Int(Double(finetune) / 16.0).clamped(to: 0...7)
            let octave = n / 12
            let baseIndex = (idx < 0) ? 0 : (idx >= Self.amigaPeriods.count ? Self.amigaPeriods.count - 1 : idx)
            let raw = Double(Self.amigaPeriods[baseIndex])
            return raw * 16.0 / pow(2.0, Double(octave))
        }
    }

    private func frequency(forPeriod period: Double) -> Double {
        switch file.frequencyTable {
        case .linear:
            return 8363.0 * pow(2.0, (4608.0 - period) / 768.0)
        case .amiga:
            return period > 0 ? (8363.0 * 1712.0 / period) : 0
        }
    }

    /// Amiga period table (96 entries, one octave's worth of
    /// finetune-extended values).
    private static let amigaPeriods: [Int] = [
        907, 900, 894, 887, 881, 875, 868, 862,
        856, 850, 844, 838, 832, 826, 820, 814,
        808, 802, 796, 791, 785, 779, 774, 768,
        762, 757, 752, 746, 741, 736, 730, 725,
        720, 715, 709, 704, 699, 694, 689, 684,
        678, 675, 670, 665, 660, 655, 651, 646,
        640, 636, 632, 628, 623, 619, 614, 610,
        604, 601, 597, 592, 588, 584, 580, 575,
        570, 567, 563, 559, 555, 551, 547, 543,
        538, 535, 532, 528, 524, 520, 516, 513,
        508, 505, 502, 498, 494, 491, 487, 484,
        480, 477, 474, 470, 467, 463, 460, 457
    ]

    // MARK: - Timing

    private func framesPerTick() -> Int {
        let tickRate = Double(tempo) * 2.0 / 5.0
        return max(1, Int(sampleRate / tickRate))
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
