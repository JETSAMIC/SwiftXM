import Testing
import Foundation
@testable import SwiftXM

// At 1000 Hz and 125 BPM one tick is 20 frames; one row (speed 6) is
// 120 frames.
private let rate = 1000.0
private let tickFrames = 20
private let rowFrames = 120
private let c4: UInt8 = 49

private func makeMixer(_ b: XMBuilder) throws -> XMMixer {
    try XMMixer(file: XMFile(data: b.build()), sampleRate: rate)
}

/// Render so the mixer has just processed tick `tick` of row `row`.
private func seek(_ m: XMMixer, row: Int = 0, tick: Int) {
    let frames = row * rowFrames + tick * tickFrames + ((row > 0 || tick > 0) ? 1 : 0)
    if frames > 0 { advance(m, frames: frames) }
}

private func song(_ entries: [XMBuilder.Entry], instruments: [XMBuilder.Instrument] = [XMBuilder.Instrument()],
                  configure: (inout XMBuilder) -> Void = { _ in }) -> XMBuilder {
    var b = XMBuilder()
    b.instruments = instruments
    b.patterns = [XMBuilder.Pattern(rows: 64, entries: entries)]
    configure(&b)
    return b
}

private func noteOn(_ row: Int = 0, _ channel: Int = 0, note: UInt8 = c4, volume: UInt8 = 0,
                    effect: UInt8 = 0, param: UInt8 = 0, instrument: UInt8 = 1) -> XMBuilder.Entry {
    .init(row: row, channel: channel, note: note, instrument: instrument, volume: volume, effect: effect, param: param)
}

private func fx(_ row: Int, _ effect: UInt8, _ param: UInt8, channel: Int = 0, volume: UInt8 = 0) -> XMBuilder.Entry {
    .init(row: row, channel: channel, volume: volume, effect: effect, param: param)
}

@Suite("XMMixer pitch and effects")
struct XMEffectTests {

    @Test("Rejects invalid sample rates")
    func invalidSampleRate() throws {
        let file = try XMFile(data: XMBuilder().build())
        for r in [0, -5, .nan, .infinity, 5_000_000] as [Double] {
            #expect(throws: XMError.invalidSampleRate) { _ = try XMMixer(file: file, sampleRate: r) }
        }
    }

    @Test("Linear table: C-4 (note 49) is period 4608 = 8363 Hz; relative note and finetune apply")
    func linearPitch() throws {
        var ins = XMBuilder.Instrument()
        var up = XMBuilder.Sample.looped()
        up.relativeNote = 12
        up.finetune = 64
        ins.samples = [.looped(), up]
        ins.sampleMap = Array(repeating: 0, count: 48) + Array(repeating: 1, count: 48)
        let m = try makeMixer(song([
            noteOn(0, 0, note: 48),     // B-3 → sample 0
            noteOn(0, 1, note: c4),     // C-4 → sample 1 (+12, +64 finetune)
            noteOn(0, 2, note: 1),
        ], instruments: [ins]))
        #expect(m.snapshot(channel: 0).period == 4608 + 64)
        #expect(m.snapshot(channel: 1).period == 4608 - 768 - 32)
        #expect(m.snapshot(channel: 2).period == 7680)
        let plain = try makeMixer(song([noteOn()]))
        #expect(abs(plain.snapshot(channel: 0).step - 8363 / rate) < 1e-9)
    }

    @Test("Amiga table: C-4 is period 1712 = 8363 Hz; finetune interpolates the FT2 table")
    func amigaPitch() throws {
        func period(note: UInt8 = c4, finetune: Int8) throws -> XMMixer.VoiceSnapshot {
            var ins = XMBuilder.Instrument()
            var s = XMBuilder.Sample.looped()
            s.finetune = finetune
            ins.samples = [s]
            return try makeMixer(song([noteOn(note: note)], instruments: [ins]) { $0.linear = false })
                .snapshot(channel: 0)
        }
        let c = try period(finetune: 0)
        #expect(c.period == 1712)
        #expect(abs(c.step - 8363 / rate) < 1e-9)
        #expect(try period(note: 61, finetune: 0).period == 856)
        #expect(try period(note: 60, finetune: 0).period == 907)      // B-4 wraps the table
        #expect(try period(finetune: -128).period == 907 * 2)
        #expect(try period(finetune: 8).period == (856 + 850) / 2 * 2)
    }

    @Test("1xx / 2xx slide by xx*4 per tick with separate memories")
    func portamento() throws {
        let m = try makeMixer(song([
            noteOn(effect: 0x01, param: 2),
            fx(1, 0x02, 3),
            fx(2, 0x01, 0),
        ]))
        seek(m, tick: 5)
        #expect(m.snapshot(channel: 0).period == 4608 - 40)
        advance(m, frames: rowFrames)
        #expect(m.snapshot(channel: 0).period == 4608 - 40 + 60)
        advance(m, frames: rowFrames)
        #expect(m.snapshot(channel: 0).period == 4608 - 40 + 60 - 40)
    }

    @Test("E1x/E2x fine and X1x/X2x extra-fine slides apply once with their own memories")
    func finePortamento() throws {
        let m = try makeMixer(song([
            noteOn(effect: 0x0E, param: 0x13),
            fx(1, 0x0E, 0x10),
            fx(2, 0x21, 0x15),
            fx(3, 0x21, 0x10),
            fx(4, 0x0E, 0x22),
            fx(5, 0x21, 0x21),
        ]))
        #expect(m.snapshot(channel: 0).period == 4608 - 12)
        seek(m, row: 1, tick: 5)
        #expect(m.snapshot(channel: 0).period == 4608 - 24)
        advance(m, frames: 2 * rowFrames)
        #expect(m.snapshot(channel: 0).period == 4608 - 24 - 10)
        advance(m, frames: 2 * rowFrames)
        #expect(m.snapshot(channel: 0).period == 4608 - 34 + 8 + 1)
    }

    @Test("3xx and the volume column Mx share the porta speed; zero speed ignores the note")
    func tonePorta() throws {
        let m = try makeMixer(song([
            noteOn(),
            noteOn(1, note: 61, effect: 0x03, param: 0x10, instrument: 0),
            noteOn(2, note: 61, volume: 0xF0, instrument: 0),
        ]))
        seek(m, row: 1, tick: 0)
        #expect(m.snapshot(channel: 0).period == 4608)
        advance(m, frames: 5 * tickFrames)
        #expect(m.snapshot(channel: 0).period == 4608 - 5 * 64)
        advance(m, frames: rowFrames)
        #expect(m.snapshot(channel: 0).period == 4608 - 10 * 64)

        let ignored = try makeMixer(song([
            noteOn(),
            noteOn(1, note: 61, effect: 0x03, param: 0, instrument: 0),
        ]))
        seek(ignored, row: 1, tick: 5)
        #expect(ignored.snapshot(channel: 0).period == 4608)
    }

    @Test("4xy vibrato uses FT2's table and depth >> 5 on ticks after the first")
    func vibrato() throws {
        let m = try makeMixer(song([noteOn(effect: 0x04, param: 0x48)]))
        #expect(m.snapshot(channel: 0).outPeriod == 4608)
        seek(m, tick: 1)
        #expect(m.snapshot(channel: 0).outPeriod == 4608)        // position 0
        advance(m, frames: tickFrames)
        #expect(m.snapshot(channel: 0).outPeriod == 4608 + 24.0)
        #expect(m.snapshot(channel: 0).period == 4608)
    }

    @Test("Volume-column Sx/Vx vibrato shares the effect 4 memory")
    func volumeColumnVibrato() throws {
        let m = try makeMixer(song([
            noteOn(volume: 0xA4),
            fx(1, 0, 0, volume: 0xB8),
        ]))
        seek(m, row: 1, tick: 2)
        #expect(m.snapshot(channel: 0).outPeriod == 4608 + 24.0)
    }

    @Test("0xy arpeggio follows FT2's tick-counter order: (speed - tick) % 3")
    func arpeggio() throws {
        let m = try makeMixer(song([noteOn(effect: 0x00, param: 0x47)]))
        seek(m, tick: 1)   // (6-1) % 3 = 2 → y
        #expect(m.snapshot(channel: 0).outPeriod == 4608 - 7 * 64)
        advance(m, frames: tickFrames)   // (6-2) % 3 = 1 → x
        #expect(m.snapshot(channel: 0).outPeriod == 4608 - 4 * 64)
        advance(m, frames: tickFrames)   // 0 → base
        #expect(m.snapshot(channel: 0).outPeriod == 4608)
    }

    @Test("Axy: up has priority, memory is shared with 5xx and 6xx")
    func volumeSlide() throws {
        let m = try makeMixer(song([
            noteOn(volume: 0x30, effect: 0x0A, param: 0x23),
            fx(1, 0x06, 0),
        ]))
        seek(m, tick: 5)
        #expect(m.snapshot(channel: 0).volume == 32 + 10)
        advance(m, frames: rowFrames)
        #expect(m.snapshot(channel: 0).volume == 52)
    }

    @Test("EAx / EBx fine volume slides remember their parameters")
    func fineVolume() throws {
        let m = try makeMixer(song([
            noteOn(volume: 0x30, effect: 0x0E, param: 0xA4),
            fx(1, 0x0E, 0xA0),
            fx(2, 0x0E, 0xB3),
            fx(3, 0x0E, 0xB0),
        ]))
        #expect(m.snapshot(channel: 0).volume == 36)
        seek(m, row: 3, tick: 0)
        #expect(m.snapshot(channel: 0).volume == 40 - 6)
    }

    @Test("Volume column: set, slides, fine slides, panning and pan slides")
    func volumeColumn() throws {
        let m = try makeMixer(song([
            noteOn(volume: 0x30),
            fx(1, 0, 0, volume: 0x62),
            fx(2, 0, 0, volume: 0x93),
            fx(3, 0, 0, volume: 0xC4),
            fx(4, 0, 0, volume: 0xE2),
        ]))
        #expect(m.snapshot(channel: 0).volume == 32)
        seek(m, row: 1, tick: 5)
        #expect(m.snapshot(channel: 0).volume == 22)
        advance(m, frames: rowFrames)
        #expect(m.snapshot(channel: 0).volume == 25)
        advance(m, frames: rowFrames)
        #expect(m.snapshot(channel: 0).panning == 0x40)
        advance(m, frames: rowFrames)
        #expect(m.snapshot(channel: 0).panning == 0x40 + 10)
    }

    @Test("Cxx sets volume (clamped); 8xx and Pxy pan; Gxx / Hxy global volume")
    func setters() throws {
        let m = try makeMixer(song([
            noteOn(effect: 0x0C, param: 0x50),
            fx(0, 0x10, 0x20, channel: 1),
            fx(1, 0x08, 0x10),
            fx(1, 0x11, 0x02, channel: 1),
            fx(2, 0x19, 0x30),
        ]))
        #expect(m.snapshot(channel: 0).volume == 64)
        #expect(m.timing.globalVolume == 32)
        seek(m, row: 1, tick: 5)
        #expect(m.snapshot(channel: 0).panning == 0x10)
        #expect(m.timing.globalVolume == 32 - 10)
        advance(m, frames: rowFrames)
        #expect(m.snapshot(channel: 0).panning == 0x10 + 15)
    }

    @Test("7xy tremolo uses depth >> 6 on ticks after the first")
    func tremolo() throws {
        let m = try makeMixer(song([noteOn(volume: 0x30, effect: 0x07, param: 0x48)]))
        seek(m, tick: 2)
        #expect(m.snapshot(channel: 0).outVolume == 32 + 12)
        #expect(m.snapshot(channel: 0).volume == 32)
    }

    @Test("Txy tremor: x+1 ticks on, y+1 ticks off")
    func tremor() throws {
        let m = try makeMixer(song([noteOn(effect: 0x1D, param: 0x11)]))
        seek(m, tick: 1)
        #expect(m.snapshot(channel: 0).outVolume == 64)
        advance(m, frames: tickFrames)
        #expect(m.snapshot(channel: 0).outVolume == 64)
        advance(m, frames: tickFrames)
        #expect(m.snapshot(channel: 0).outVolume == 0)
    }

    @Test("9xx offsets only with a note, remembers its parameter, stops past the end")
    func sampleOffset() throws {
        var ins = XMBuilder.Instrument()
        var s = XMBuilder.Sample()
        s.values = Array(repeating: 10, count: 1000)
        ins.samples = [s]
        let m = try makeMixer(song([
            noteOn(effect: 0x09, param: 2),
            noteOn(0, 1, effect: 0x09, param: 9),
            noteOn(1, 2, effect: 0x09, param: 0),
            fx(1, 0x09, 1),
        ], instruments: [ins]))
        #expect(m.snapshot(channel: 0).pos == 512)
        #expect(!m.snapshot(channel: 1).active)
        let before = m.snapshot(channel: 0).pos
        seek(m, row: 1, tick: 0)
        #expect(m.snapshot(channel: 0).pos > before)
        #expect(m.snapshot(channel: 2).pos < 10)    // own (empty) offset memory
    }

    @Test("ECx cuts on tick x; EDx delays the whole cell; ED0 plays at once")
    func cutAndDelay() throws {
        let m = try makeMixer(song([
            noteOn(effect: 0x0E, param: 0xC2),
            noteOn(0, 1, volume: 0x20, effect: 0x0E, param: 0xD2),
            noteOn(0, 2, effect: 0x0E, param: 0xD0),
        ]))
        #expect(!m.snapshot(channel: 1).active)
        #expect(m.snapshot(channel: 2).active)
        seek(m, tick: 1)
        #expect(m.snapshot(channel: 0).volume == 64)
        advance(m, frames: tickFrames)
        #expect(m.snapshot(channel: 0).volume == 0)
        #expect(m.snapshot(channel: 1).active)
        #expect(m.snapshot(channel: 1).volume == 16)
    }

    @Test("E9x retriggers every x ticks")
    func retrig() throws {
        var ins = XMBuilder.Instrument()
        var s = XMBuilder.Sample()
        s.values = Array(repeating: 10, count: 5000)
        ins.samples = [s]
        let m = try makeMixer(song([noteOn(effect: 0x0E, param: 0x93)], instruments: [ins]))
        seek(m, tick: 2)
        #expect(m.snapshot(channel: 0).pos > 100)
        advance(m, frames: tickFrames)       // tick 3: retriggered
        #expect(m.snapshot(channel: 0).pos < 10)
    }

    @Test("Rxy multi-retrig applies the volume table every y ticks")
    func multiRetrig() throws {
        let m = try makeMixer(song([noteOn(volume: 0x40, effect: 0x1B, param: 0x22)]))
        seek(m, tick: 5)
        #expect(m.snapshot(channel: 0).volume == 48 - 4)
    }

    @Test("Fxx sets speed below 0x20 and BPM from 0x20; F00 is ignored")
    func speedTempo() throws {
        let m = try makeMixer(song([
            fx(0, 0x0F, 3),
            fx(0, 0x0F, 150, channel: 1),
            fx(1, 0x0F, 0),
        ]))
        #expect(m.timing.speed == 3)
        #expect(m.timing.bpm == 150)
        advance(m, frames: 51)
        #expect(m.currentRow == 1)
        #expect(m.timing.speed == 3)
    }

    @Test("Key off without a volume envelope silences; with one, fade-out runs from 32768")
    func keyOffAndFadeout() throws {
        let plain = try makeMixer(song([noteOn(), .init(row: 1, channel: 0, note: 97)]))
        seek(plain, row: 1, tick: 0)
        #expect(plain.snapshot(channel: 0).volume == 0)
        #expect(plain.snapshot(channel: 0).keyOff)

        var ins = XMBuilder.Instrument()
        ins.volumeEnvelope = .init(points: [(0, 64), (100, 64)], flags: 1)
        ins.fadeout = 0x1000
        let env = try makeMixer(song([noteOn(), fx(1, 0x14, 2)], instruments: [ins]))
        seek(env, row: 1, tick: 1)
        #expect(!env.snapshot(channel: 0).keyOff)
        advance(env, frames: tickFrames)
        #expect(env.snapshot(channel: 0).keyOff)
        #expect(env.snapshot(channel: 0).fadeout == 32768 - 0x1000)
        #expect(env.snapshot(channel: 0).volume == 64)
        advance(env, frames: 8 * tickFrames)
        #expect(!env.snapshot(channel: 0).active)
    }

    @Test("Volume envelope interpolates, holds at sustain and releases on key off")
    func volumeEnvelope() throws {
        var ins = XMBuilder.Instrument()
        ins.volumeEnvelope = .init(points: [(0, 0), (4, 64), (8, 32)], sustain: 1, flags: 0x03)
        let m = try makeMixer(song([noteOn(), .init(row: 1, channel: 0, note: 97)], instruments: [ins]))
        #expect(m.snapshot(channel: 0).finalVolume == 0)
        seek(m, tick: 2)
        #expect(abs(m.snapshot(channel: 0).finalVolume - 0.5) < 1e-6)
        advance(m, frames: 3 * tickFrames)   // tick 5: held at sustain (frame 4)
        #expect(m.snapshot(channel: 0).finalVolume == 1)
        advance(m, frames: tickFrames)       // row 1 tick 0: key off, still at sustain
        advance(m, frames: 4 * tickFrames)
        #expect(m.snapshot(channel: 0).finalVolume < 1)
    }

    @Test("Volume envelope loops between its loop points")
    func envelopeLoop() throws {
        var ins = XMBuilder.Instrument()
        ins.volumeEnvelope = .init(points: [(0, 64), (2, 0), (4, 64)], loopStart: 0, loopEnd: 1, flags: 0x05)
        let m = try makeMixer(song([noteOn()], instruments: [ins]))
        var values: [Float] = [m.snapshot(channel: 0).finalVolume]
        advance(m, frames: tickFrames + 1)
        values.append(m.snapshot(channel: 0).finalVolume)
        for _ in 0..<4 {
            advance(m, frames: tickFrames)
            values.append(m.snapshot(channel: 0).finalVolume)
        }
        // Reaching the loop-end frame jumps back to the loop start, as
        // FT2 does, so the loop-end value itself is never output.
        #expect(values == [1, 0.5, 1, 0.5, 1, 0.5])
    }

    @Test("Lxx sets the envelope position")
    func envelopePosition() throws {
        var ins = XMBuilder.Instrument()
        ins.volumeEnvelope = .init(points: [(0, 64), (10, 0)], flags: 1)
        let m = try makeMixer(song([noteOn(), fx(1, 0x15, 5)], instruments: [ins]))
        seek(m, row: 1, tick: 0)
        #expect(abs(m.snapshot(channel: 0).finalVolume - 0.5) < 1e-6)
    }

    @Test("Panning envelope offsets pan around the channel pan")
    func panningEnvelope() throws {
        var ins = XMBuilder.Instrument()
        ins.panningEnvelope = .init(points: [(0, 64)], flags: 1)
        let m = try makeMixer(song([noteOn()], instruments: [ins]))
        #expect(m.snapshot(channel: 0).finalPan == 1)
    }

    @Test("Auto-vibrato sweeps in and uses FT2's negative-first sine")
    func autoVibrato() throws {
        var ins = XMBuilder.Instrument()
        ins.vibratoDepth = 15
        ins.vibratoRate = 32
        ins.vibratoSweep = 0
        let m = try makeMixer(song([noteOn()], instruments: [ins]))
        // First tick: position 32 → sine -45, amp 15 << 8 → -45*3840 >> 14 = -11.
        let expected = 8363 * pow(2, 11.0 / 768) / rate
        #expect(abs(m.snapshot(channel: 0).step - expected) < 1e-9)

        // With a sweep the depth ramps up from zero.
        ins.vibratoSweep = 10
        let swept = try makeMixer(song([noteOn()], instruments: [ins]))
        #expect(swept.snapshot(channel: 0).step < expected)
        #expect(swept.snapshot(channel: 0).step > 8363 / rate)
    }

    @Test("Note without instrument keeps volume; instrument alone resets it; bad instrument cuts")
    func noteInstrumentTable() throws {
        let m = try makeMixer(song([
            noteOn(volume: 0x20),
            .init(row: 1, channel: 0, note: 50),
            .init(row: 2, channel: 0, instrument: 1),
            .init(row: 3, channel: 0, note: 50, instrument: 9),
        ]))
        seek(m, row: 1, tick: 0)
        #expect(m.snapshot(channel: 0).volume == 16)
        #expect(m.snapshot(channel: 0).period == 4608 - 64)
        advance(m, frames: rowFrames)
        #expect(m.snapshot(channel: 0).volume == 64)
        advance(m, frames: rowFrames)
        #expect(!m.snapshot(channel: 0).active)
    }

    @Test("Forward loops wrap at the loop end, not the sample end")
    func forwardLoop() throws {
        var ins = XMBuilder.Instrument()
        var s = XMBuilder.Sample()
        s.values = Array(repeating: 50, count: 1000)
        s.loopType = 1
        s.loopStart = 0
        s.loopLength = 10
        ins.samples = [s]
        let m = try makeMixer(song([noteOn()], instruments: [ins]))
        advance(m, frames: 100)
        #expect(m.snapshot(channel: 0).pos < 10)
        #expect(m.snapshot(channel: 0).active)
    }

    @Test("Ping-pong loops stay in range even at extreme pitch")
    func pingPongExtreme() throws {
        var ins = XMBuilder.Instrument()
        var s = XMBuilder.Sample()
        s.values = (0..<40).map { $0 * 100 }
        s.loopType = 2
        s.loopStart = 30
        s.loopLength = 3
        ins.samples = [s]
        let m = try makeMixer(song([noteOn(note: 96, effect: 0x01, param: 0xFF)], instruments: [ins]))
        let out = renderAll(m, limit: 2000).samples
        #expect(out.allSatisfy { $0.isFinite })
        let pos = m.snapshot(channel: 0).pos
        #expect(pos >= 30 && pos <= 33)
    }
}
