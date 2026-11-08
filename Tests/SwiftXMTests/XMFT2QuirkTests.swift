import Testing
import Foundation
@testable import SwiftXM

// Spec-derived tests for the FT2 behaviours in Reference/XM-Format.md
// §5-§6. Each test names the OpenMPT test case that documents the rule.
//
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
private func seek(_ m: XMMixer, row: Int = 0, tick: Int, rowLength: Int = rowFrames) {
    let frames = row * rowLength + tick * tickFrames + 1
    advance(m, frames: frames)
}

private func song(_ entries: [XMBuilder.Entry], instruments: [XMBuilder.Instrument] = [XMBuilder.Instrument()],
                  channels: Int = 4, configure: (inout XMBuilder) -> Void = { _ in }) -> XMBuilder {
    var b = XMBuilder()
    b.channels = channels
    b.instruments = instruments
    b.patterns = [XMBuilder.Pattern(rows: 64, entries: entries)]
    configure(&b)
    return b
}

private func cell(_ row: Int, _ channel: Int = 0, note: UInt8 = 0, instrument: UInt8 = 0, volume: UInt8 = 0,
                  effect: UInt8 = 0, param: UInt8 = 0) -> XMBuilder.Entry {
    .init(row: row, channel: channel, note: note, instrument: instrument, volume: volume, effect: effect, param: param)
}

private func instrument(volume: UInt8 = 64, panning: UInt8 = 128, finetune: Int8 = 0, frames: Int = 64,
                        configure: (inout XMBuilder.Instrument) -> Void = { _ in }) -> XMBuilder.Instrument {
    var ins = XMBuilder.Instrument()
    var s = XMBuilder.Sample.looped(frames)
    s.volume = volume
    s.panning = panning
    s.finetune = finetune
    ins.samples = [s]
    configure(&ins)
    return ins
}

private func linearPeriod(_ note0: Int, finetune: Int = 0) -> Double {
    7680 - Double(note0 * 64) - Double((finetune >> 3) << 3) / 2
}

@Suite("FT2 playback quirks (XM-Format.md §5-§6)")
struct XMFT2QuirkTests {

    // MARK: Key-off and fade-out (§5.6, §6.3)

    @Test("Key-off with an instrument restores the sample volume and fades out (keyoff+instr.xm)")
    func keyOffWithInstrument() throws {
        let ins = instrument(volume: 48) { $0.fadeout = 0x0800 }
        let m = try makeMixer(song([cell(0, note: c4, instrument: 1), cell(1, note: 97, instrument: 1)],
                                   instruments: [ins]))
        seek(m, row: 1, tick: 0)
        #expect(m.snapshot(channel: 0).keyOff)
        #expect(m.snapshot(channel: 0).volume == 48)
        advance(m, frames: 2 * tickFrames)
        #expect(m.snapshot(channel: 0).fadeout < 32768)
        #expect(m.snapshot(channel: 0).finalVolume > 0)
    }

    @Test("K00 replaces the cell's note with a key-off (key_off.xm, KeyOff2.xm)")
    func k00IgnoresNote() throws {
        let m = try makeMixer(song([cell(0, note: c4, instrument: 1), cell(1, note: c4 + 12, effect: 0x14, param: 0)]))
        seek(m, row: 1, tick: 0)
        #expect(m.snapshot(channel: 0).keyOff)
        #expect(m.snapshot(channel: 0).period == linearPeriod(48))
    }

    @Test("Fade-out runs without a volume envelope once a volume command revives the note (NoteOffFadeNoEnv.xm)")
    func fadeoutWithoutEnvelope() throws {
        let ins = instrument { $0.fadeout = 0x1000 }
        let m = try makeMixer(song([cell(0, note: c4, instrument: 1), cell(1, note: 97, volume: 0x50)],
                                   instruments: [ins]))
        seek(m, row: 1, tick: 0)
        #expect(m.snapshot(channel: 0).volume == 64)
        advance(m, frames: tickFrames)
        #expect(m.snapshot(channel: 0).fadeout == 32768 - 2 * 0x1000)
    }

    @Test("A faded-out note can be picked up by portamento with an instrument (FadeoutPickup.xm)")
    func fadeoutPickup() throws {
        let ins = instrument {
            $0.volumeEnvelope = .init(points: [(0, 64), (100, 64)], flags: 1)
            $0.fadeout = 0x4000
        }
        let m = try makeMixer(song([
            cell(0, note: c4, instrument: 1),
            cell(1, note: 97),
            cell(2, note: c4, instrument: 1, effect: 0x03, param: 0x10),
        ], instruments: [ins]))
        seek(m, row: 1, tick: 5)
        #expect(m.snapshot(channel: 0).fadeout == 0)
        #expect(m.snapshot(channel: 0).finalVolume == 0)
        advance(m, frames: tickFrames)
        #expect(m.snapshot(channel: 0).active)
        #expect(m.snapshot(channel: 0).fadeout == 32768)
        #expect(m.snapshot(channel: 0).finalVolume > 0)
    }

    // MARK: Notes and instruments (§6.2)

    @Test("An instrument number alone restores the playing sample's defaults, not the new instrument's")
    func instrumentOnlyUsesPlayingSample() throws {
        let m = try makeMixer(song([
            cell(0, note: c4, instrument: 1),
            cell(1, volume: 0x10),
            cell(2, instrument: 2),
        ], instruments: [instrument(volume: 32), instrument(volume: 64)]))
        seek(m, row: 1, tick: 0)
        #expect(m.snapshot(channel: 0).volume == 0)
        advance(m, frames: rowFrames)
        #expect(m.snapshot(channel: 0).volume == 32)
    }

    @Test("9xx memory changes only next to a note and not with tone portamento (OffsetWithoutNote.xm, porta-offset.xm)")
    func offsetMemory() throws {
        let ins = instrument(frames: 1024)
        let m = try makeMixer(song([
            cell(0, note: c4, instrument: 1, effect: 0x09, param: 0x01),   // offset 256, memory 1
            cell(1, note: 97, effect: 0x09, param: 0x03),                  // key-off: memory unchanged
            cell(2, note: c4, volume: 0xF1, effect: 0x09, param: 0x02),    // porta: ignored
            cell(3, note: c4, instrument: 1, effect: 0x09, param: 0x00),   // recalls 256
        ], instruments: [ins]))
        seek(m, row: 0, tick: 0)
        #expect(m.snapshot(channel: 0).pos >= 256 && m.snapshot(channel: 0).pos < 270)
        advance(m, frames: 3 * rowFrames)
        #expect(m.snapshot(channel: 0).pos >= 256 && m.snapshot(channel: 0).pos < 270)
    }

    // MARK: Pitch (§5.7, §6.4.1, §6.4.3)

    @Test("Finetune uses its top five bits, rounding down (Finetune-Precision.xm)")
    func finetunePrecision() throws {
        for (finetune, expected) in [(7, 4608.0), (8, 4604.0), (-1, 4612.0), (-8, 4612.0), (-9, 4616.0)] {
            let m = try makeMixer(song([cell(0, note: c4, instrument: 1)],
                                       instruments: [instrument(finetune: Int8(finetune))]))
            #expect(m.snapshot(channel: 0).period == expected, "finetune \(finetune)")
        }
    }

    @Test("Arpeggio past FT2's 16-entry table plays the third note (Arpeggio.xm)")
    func arpeggioOverflow() throws {
        let rowLength = 20 * tickFrames
        var periods: [Double] = []
        for t in 1...7 {
            let m = try makeMixer(song([cell(0, note: c4, instrument: 1, effect: 0x00, param: 0x47)]) { $0.speed = 20 })
            seek(m, tick: t, rowLength: rowLength)
            periods.append(m.snapshot(channel: 0).outPeriod)
        }
        // k = 20 - t for t = 1...7: 19, 18, 17 → +7; 16 → base; 15 → base; 14 → +7; 13 → +4.
        let plus7 = Double(4608 - 7 * 64), plus4 = Double(4608 - 4 * 64)
        #expect(periods == [plus7, plus7, plus7, 4608, 4608, plus7, plus4])
    }

    @Test("Arpeggio rounds the slid period to a semitone and clamps at B-7 (ArpSlide.xm, ArpeggioClamp.xm)")
    func arpeggioRoundingAndClamp() throws {
        let slid = try makeMixer(song([
            cell(0, note: c4, instrument: 1, effect: 0x0E, param: 0x17),   // period 4608 - 28 = 4580
            cell(1, effect: 0x00, param: 0xC0),
        ]))
        seek(slid, row: 1, tick: 1)                       // k = 5 → +y (0): rounded base
        #expect(slid.snapshot(channel: 0).outPeriod == 4608)
        advance(slid, frames: tickFrames)                 // k = 4 → +x (12)
        #expect(slid.snapshot(channel: 0).outPeriod == 4608 - 768)

        let high = try makeMixer(song([cell(0, note: 96, instrument: 1, effect: 0x00, param: 0xC0)],
                                      instruments: [instrument(finetune: 64)]))
        seek(high, tick: 2)
        #expect(high.snapshot(channel: 0).outPeriod == 7680 - 95 * 64)
    }

    @Test("Tone portamento keeps FT2's direction after reaching its target (PortaResetDirection.xm)")
    func portaDirection() throws {
        let m = try makeMixer(song([
            cell(0, note: c4, instrument: 1),
            cell(1, note: c4 + 1, effect: 0x03, param: 0xFF),   // reaches C#4 on tick 1
            cell(2, effect: 0x02, param: 0x10),                 // pitch down: period + 64 per tick
            cell(3, effect: 0x03, param: 0x01),                 // snaps back instead of sliding
        ]))
        seek(m, row: 1, tick: 1)
        #expect(m.snapshot(channel: 0).period == linearPeriod(49))
        advance(m, frames: 5 * tickFrames + rowFrames)   // row 3, tick 0
        #expect(m.snapshot(channel: 0).period == linearPeriod(49) + 5 * 64)
        advance(m, frames: tickFrames)
        #expect(m.snapshot(channel: 0).period == linearPeriod(49))
    }

    @Test("Auto-vibrato released mid-sweep uses one sweep step as depth (AutoVibratoSweepKeyOff.xm)")
    func autoVibratoKeyOff() throws {
        let ins = instrument {
            $0.vibratoType = 1        // square; rate 0 keeps the position at 0 → -64
            $0.vibratoDepth = 15
            $0.vibratoSweep = 4       // step (15 << 8) / 4 = 960
            $0.vibratoRate = 0
        }
        let m = try makeMixer(song([cell(0, note: c4, instrument: 1, effect: 0x14, param: 3)], instruments: [ins]))
        seek(m, tick: 3)
        #expect(m.snapshot(channel: 0).keyOff)
        // (-64 * 960) >> 14 = -4 period units → 4604.
        let expected = 8363 * pow(2, (4608 - 4604) / 768) / rate
        #expect(abs(m.snapshot(channel: 0).step - expected) < 1e-9)
    }

    // MARK: Note delay (§6.4.13)

    @Test("EDx without a note retriggers the last note and its envelopes (delay2.xm, envretrig.xm)")
    func delayRetriggersLastNote() throws {
        let ins = instrument(frames: 1024) { $0.volumeEnvelope = .init(points: [(0, 64), (12, 0)], flags: 1) }
        let m = try makeMixer(song([cell(0, note: c4, instrument: 1), cell(1, effect: 0x0E, param: 0xD3)],
                                   instruments: [ins]))
        seek(m, row: 1, tick: 2)
        #expect(m.snapshot(channel: 0).pos > 100)
        #expect(m.snapshot(channel: 0).finalVolume < 0.5)
        advance(m, frames: tickFrames)
        #expect(m.snapshot(channel: 0).pos < 20)
        #expect(m.snapshot(channel: 0).finalVolume == 1)
    }

    @Test("A delayed note applies only set-volume from the volume column and ignores Mx (DelayVolume.xm, porta-delay.xm)")
    func delayedVolumeColumn() throws {
        let fine = try makeMixer(song([
            cell(0, note: c4, instrument: 1),
            cell(1, note: c4, volume: 0x85, effect: 0x0E, param: 0xD2),   // fine slide down: not applied
            cell(2, note: c4, volume: 0x20, effect: 0x0E, param: 0xD2),   // set volume 16 on tick 2
        ]))
        seek(fine, row: 1, tick: 2)
        #expect(fine.snapshot(channel: 0).volume == 64)
        advance(fine, frames: rowFrames)
        #expect(fine.snapshot(channel: 0).volume == 16)

        let porta = try makeMixer(song([
            cell(0, note: c4, instrument: 1),
            cell(1, note: c4 + 12, volume: 0xFF, effect: 0x0E, param: 0xD2),
        ]))
        seek(porta, row: 1, tick: 1)
        #expect(porta.snapshot(channel: 0).period == linearPeriod(48))
        advance(porta, frames: tickFrames)
        #expect(porta.snapshot(channel: 0).period == linearPeriod(60))
    }

    @Test("A delayed key-off only restarts the envelopes (OffDelay.xm)")
    func delayedKeyOff() throws {
        let ins = instrument {
            $0.volumeEnvelope = .init(points: [(0, 64), (4, 32), (8, 0)], sustain: 1, flags: 0x03)
        }
        let m = try makeMixer(song([cell(0, note: c4, instrument: 1), cell(1, note: 97, effect: 0x0E, param: 0xD2)],
                                   instruments: [ins]))
        seek(m, row: 1, tick: 1)
        #expect(abs(m.snapshot(channel: 0).finalVolume - 0.5) < 1e-6)
        advance(m, frames: tickFrames)
        #expect(!m.snapshot(channel: 0).keyOff)
        #expect(m.snapshot(channel: 0).finalVolume == 1)
    }

    @Test("A note delay fires again on every EEx repetition (PatternDelay-NoteDelay.xm)")
    func delayRepeatsWithPatternDelay() throws {
        let m = try makeMixer(song([
            cell(0, note: c4, instrument: 1),
            cell(1, 0, note: c4, instrument: 1, effect: 0x0E, param: 0xD2),
            cell(1, 1, effect: 0x0E, param: 0xE1),
        ], instruments: [instrument(frames: 1024)]))
        seek(m, row: 1, tick: 7)          // repeat, tick 1
        #expect(m.snapshot(channel: 0).pos > 40)
        advance(m, frames: tickFrames)    // repeat, tick 2
        #expect(m.snapshot(channel: 0).pos < 20)
    }

    // MARK: Row flow and retriggers (§6.4.11, §6.4.20, §6.9)

    @Test("The rightmost EEx decides the pattern delay, even EE0 (PatternDelays.xm)")
    func rightmostPatternDelay() throws {
        let m = try makeMixer(song([cell(0, 0, effect: 0x0E, param: 0xE2), cell(0, 1, effect: 0x0E, param: 0xE0)]))
        advance(m, frames: rowFrames + 1)
        #expect(m.currentRow == 1)
    }

    @Test("Rxy counts tick 0 unless the volume column is used (retrig.xm)")
    func multiRetrigTickZero() throws {
        let plain = try makeMixer(song([cell(0, note: c4, instrument: 1, effect: 0x1B, param: 0x11)]))
        #expect(plain.snapshot(channel: 0).volume == 63)
        let withVolume = try makeMixer(song([cell(0, note: c4, instrument: 1, volume: 0x50, effect: 0x1B, param: 0x11)]))
        #expect(withVolume.snapshot(channel: 0).volume == 64)
    }

    @Test("E90 retriggers on tick 0 (E90.xm)")
    func e90() throws {
        let m = try makeMixer(song([cell(0, note: c4, instrument: 1), cell(1, effect: 0x0E, param: 0x90)],
                                   instruments: [instrument(frames: 1024)]))
        seek(m, row: 0, tick: 5)
        #expect(m.snapshot(channel: 0).pos > 40)
        advance(m, frames: tickFrames)    // row 1, tick 0
        #expect(m.snapshot(channel: 0).pos < 20)
    }

    @Test("An instrument number resets the tremor counter (TremorInstr.xm)")
    func tremorResetByInstrument() throws {
        func volumeAtRow1Tick1(instrumentOnRow1: UInt8) throws -> Int {
            let m = try makeMixer(song([
                cell(0, note: c4, instrument: 1, effect: 0x1D, param: 0x13),   // on 2, off 4
                cell(1, instrument: instrumentOnRow1, effect: 0x1D, param: 0x00),
            ]))
            seek(m, row: 1, tick: 1)
            return m.snapshot(channel: 0).outVolume
        }
        #expect(try volumeAtRow1Tick1(instrumentOnRow1: 0) == 0)
        #expect(try volumeAtRow1Tick1(instrumentOnRow1: 1) == 64)
    }

    // MARK: Panning (§5.9, §6.6, §6.7)

    @Test("Volume-column pan slide left by 0 sets hard left (PanSlideZero.xm)")
    func panSlideLeftZero() throws {
        let m = try makeMixer(song([cell(0, note: c4, instrument: 1), cell(1, volume: 0xD0), cell(2, volume: 0xE0)]))
        seek(m, row: 1, tick: 0)
        #expect(m.snapshot(channel: 0).panning == 128)
        advance(m, frames: tickFrames)
        #expect(m.snapshot(channel: 0).panning == 0)
        advance(m, frames: rowFrames)
        #expect(m.snapshot(channel: 0).panning == 0)
    }

    @Test("A panning envelope held at sustain stays held after key-off (PanSustainRelease.xm)")
    func panSustainSticks() throws {
        let ins = instrument {
            $0.volumeEnvelope = .init(points: [(0, 64)], flags: 1)
            $0.panningEnvelope = .init(points: [(0, 32), (4, 64)], sustain: 0, flags: 0x03)
        }
        let m = try makeMixer(song([cell(0, note: c4, instrument: 1), cell(1, note: 97)], instruments: [ins]))
        seek(m, row: 1, tick: 4)
        #expect(m.snapshot(channel: 0).keyOff)
        #expect(m.snapshot(channel: 0).finalPan == 128)
    }

    @Test("FT2's square-root pan law (FT2PanLaw.xm)")
    func squareRootPanLaw() throws {
        func firstFrame(panning: UInt8) throws -> (Float, Float) {
            var ins = XMBuilder.Instrument()
            var s = XMBuilder.Sample()
            s.panning = panning
            ins.samples = [s]
            let m = try makeMixer(song([cell(0, note: c4, instrument: 1)], instruments: [ins]))
            var buffer = [Float](repeating: 0, count: 2)
            buffer.withUnsafeMutableBufferPointer { _ = m.render(into: $0.baseAddress!, frames: 1) }
            return (buffer[0], buffer[1])
        }
        let full: Float = 0.5 / 4                       // sample 64 << 8 = 0.5, four channels
        let centre = try firstFrame(panning: 128)
        #expect(abs(centre.0 - full * Float(0.5).squareRoot()) < 1e-6)
        #expect(abs(centre.1 - centre.0) < 1e-6)
        let left = try firstFrame(panning: 0)
        #expect(abs(left.0 - full) < 1e-6)
        #expect(left.1 == 0)
        let right = try firstFrame(panning: 255)
        #expect(right.0 > 0)
        #expect(abs(right.1 - full * Float(255.0 / 256).squareRoot()) < 1e-6)
    }
}
