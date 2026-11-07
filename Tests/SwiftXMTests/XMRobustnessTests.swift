import Testing
import Foundation
@testable import SwiftXM

/// A module touching every parser path: two patterns, envelopes,
/// auto-vibrato, 8/16-bit, forward and ping-pong loops, and effects.
func richFixture() -> Data {
    var b = XMBuilder()
    b.order = [0, 1, 0]
    var lead = XMBuilder.Instrument(name: "LEAD")
    var s16 = XMBuilder.Sample()
    s16.bits16 = true
    s16.values = (0..<48).map { ($0 % 12 - 6) * 3000 }
    s16.loopType = 2
    s16.loopStart = 8
    s16.loopLength = 24
    lead.samples = [.looped(), s16]
    lead.sampleMap = Array(repeating: 0, count: 48) + Array(repeating: 1, count: 48)
    lead.volumeEnvelope = .init(points: [(0, 64), (4, 32), (8, 48)], sustain: 1, loopStart: 1, loopEnd: 2, flags: 7)
    lead.panningEnvelope = .init(points: [(0, 0), (6, 64)], flags: 1)
    lead.vibratoDepth = 4
    lead.vibratoRate = 8
    lead.vibratoSweep = 3
    lead.fadeout = 0x400
    // The empty instrument comes first so truncating inside the last
    // sample body still parses (clipped sample).
    b.instruments = [XMBuilder.Instrument(name: "EMPTY", samples: []), lead]
    b.patterns = [
        XMBuilder.Pattern(rows: 16, entries: [
            .init(row: 0, channel: 0, note: 49, instrument: 2, volume: 0x40, effect: 0x04, param: 0x46),
            .init(row: 0, channel: 1, note: 62, instrument: 2, effect: 0x00, param: 0x37),
            .init(row: 2, channel: 2, note: 30, instrument: 2, volume: 0xF4, effect: 0x09, param: 1),
            .init(row: 4, channel: 0, note: 97),
            .init(row: 5, channel: 3, effect: 0x0E, param: 0xE1),
            .init(row: 6, channel: 1, effect: 0x1B, param: 0x32),
            .init(row: 8, channel: 2, effect: 0x14, param: 2),
            .init(row: 9, channel: 0, note: 55, instrument: 1),
        ]),
        XMBuilder.Pattern(rows: 8, entries: [
            .init(row: 0, channel: 0, note: 49, instrument: 2, effect: 0x0E, param: 0x60),
            .init(row: 1, channel: 0, effect: 0x0E, param: 0x61),
            .init(row: 2, channel: 1, effect: 0x15, param: 3),
            .init(row: 3, channel: 2, effect: 0x0D, param: 0x02),
        ]),
    ]
    return b.build()
}

@discardableResult
private func exercise(_ data: Data, frames: Int = 2048, sampleRate: Double = 8000) -> Bool {
    guard let file = try? XMFile(data: data),
          let mixer = try? XMMixer(file: file, sampleRate: sampleRate) else { return false }
    let out = renderAll(mixer, limit: frames, chunk: 512).samples
    #expect(out.allSatisfy { $0.isFinite })
    return true
}

@Suite("XM robustness")
struct XMRobustnessTests {

    @Test("The rich fixture parses and plays to the end")
    func richFixturePlays() throws {
        let mixer = try XMMixer(file: XMFile(data: richFixture()), sampleRate: 8000)
        let out = renderAll(mixer, limit: 10_000_000, chunk: 4096)
        #expect(mixer.finished)
        #expect(out.samples.contains { $0 != 0 })
        #expect(out.samples.allSatisfy { $0.isFinite })
    }

    @Test("Truncation at every byte offset throws or parses, never traps")
    func truncation() {
        let data = richFixture()
        var parsed = 0
        for n in 0..<data.count where exercise(data.prefix(n), frames: 300, sampleRate: 250) {
            parsed += 1
        }
        #expect(!exercise(data.prefix(63)))
        #expect(parsed > 0)
    }

    @Test("Seeded random mutation fuzzing never traps or hangs")
    func mutationFuzz() {
        var rng = SplitMix64(seed: 0x584D_2104)
        let base = [UInt8](richFixture())
        for _ in 0..<3000 {
            var bytes = base
            let edits = 1 + Int(rng.next() % 8)
            for _ in 0..<edits {
                let i = Int(rng.next() % UInt64(bytes.count))
                switch rng.next() % 4 {
                case 0: bytes[i] = UInt8(truncatingIfNeeded: rng.next())
                case 1: bytes[i] ^= UInt8(1 << (rng.next() % 8))
                case 2: bytes[i] = [0x00, 0xFF, 0x7F, 0x80][Int(rng.next() % 4)]
                default:
                    // Header fields that drive sizes and counts.
                    let field = [60, 61, 64, 68, 70, 72, 76, 78, 80][Int(rng.next() % 9)]
                    bytes[field] = UInt8(truncatingIfNeeded: rng.next())
                }
            }
            // 5 frames per tick: many rows through the effect engine.
            exercise(Data(bytes), frames: 300, sampleRate: 250)
        }
    }

    @Test("Random garbage after a valid signature never traps")
    func garbage() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<300 {
            var bytes = (0..<Int(64 + rng.next() % 3000)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            bytes.replaceSubrange(0..<17, with: Array("Extended Module: ".utf8))
            bytes[58] = 0x04
            bytes[59] = 0x01
            exercise(Data(bytes), frames: 300, sampleRate: 250)
        }
    }
}
