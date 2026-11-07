import Testing
import Foundation
@testable import SwiftXM

// 1000 Hz, 125 BPM, speed 6 → 120 frames per row.
private let rowFrames = 120

private func framesPlayed(_ b: XMBuilder, limit: Int = 20_000_000) throws -> Int {
    let m = try XMMixer(file: XMFile(data: b.build()), sampleRate: 1000)
    let n = renderAll(m, limit: limit, chunk: 8192).frames
    #expect(m.finished)
    return n
}

private func fx(_ row: Int, _ effect: UInt8, _ param: UInt8, channel: Int = 0) -> XMBuilder.Entry {
    .init(row: row, channel: channel, effect: effect, param: param)
}

private func patterns(_ count: Int, _ entries: [Int: [XMBuilder.Entry]] = [:]) -> [XMBuilder.Pattern] {
    (0..<count).map { XMBuilder.Pattern(rows: 64, entries: entries[$0] ?? []) }
}

@Suite("XMMixer song flow and termination")
struct XMFlowTests {

    @Test("A plain pattern plays its rows then ends")
    func plain() throws {
        #expect(try framesPlayed(XMBuilder()) == 64 * rowFrames)
        var b = XMBuilder()
        b.patterns = [XMBuilder.Pattern(rows: 17)]
        #expect(try framesPlayed(b) == 17 * rowFrames)
    }

    @Test("Song length 0 plays nothing; missing patterns play as empty 64-row patterns")
    func orderEdges() throws {
        var b = XMBuilder()
        b.order = []
        #expect(try framesPlayed(b) == 0)
        b.order = [5, 0]
        b.patterns = [XMBuilder.Pattern(rows: 8)]
        #expect(try framesPlayed(b) == (64 + 8) * rowFrames)
    }

    @Test("Bxx back to an earlier order ends the song after one pass")
    func positionJumpLoop() throws {
        var b = XMBuilder()
        b.order = [0, 1]
        b.patterns = patterns(2, [1: [fx(1, 0x0B, 0)]])
        #expect(try framesPlayed(b) == (64 + 2) * rowFrames)
    }

    @Test("Bxx into a partly played order still terminates")
    func positionJumpPartial() throws {
        var b = XMBuilder()
        b.patterns = patterns(1, [0: [fx(32, 0x0B, 0)]])
        #expect(try framesPlayed(b) == 33 * rowFrames)
    }

    @Test("Bxx past the song length ends the song")
    func positionJumpPastEnd() throws {
        var b = XMBuilder()
        b.patterns = patterns(1, [0: [fx(3, 0x0B, 9)]])
        #expect(try framesPlayed(b) == 4 * rowFrames)
    }

    @Test("Dxx breaks to a BCD row; > 63 or past the next pattern's end becomes 0")
    func patternBreak() throws {
        var b = XMBuilder()
        b.order = [0, 1]
        b.patterns = patterns(2, [0: [fx(0, 0x0D, 0x12)]])
        #expect(try framesPlayed(b) == (1 + 52) * rowFrames)
        b.patterns[0].entries = [fx(0, 0x0D, 0x70)]
        #expect(try framesPlayed(b) == (1 + 64) * rowFrames)
        b.patterns[1].rows = 8
        b.patterns[0].entries = [fx(0, 0x0D, 0x20)]
        #expect(try framesPlayed(b) == (1 + 8) * rowFrames)
    }

    @Test("Bxx then Dxx (channel order) jumps to that order and row; Dxx then Bxx resets the row, as in FT2")
    func jumpAndBreak() throws {
        var b = XMBuilder()
        b.order = [0, 1, 2]
        b.patterns = patterns(3, [0: [fx(0, 0x0B, 2, channel: 0), fx(0, 0x0D, 0x05, channel: 1)]])
        #expect(try framesPlayed(b) == (1 + 59) * rowFrames)
        b.patterns[0].entries = [fx(0, 0x0D, 0x05, channel: 0), fx(0, 0x0B, 2, channel: 1)]
        #expect(try framesPlayed(b) == (1 + 64) * rowFrames)
    }

    @Test("E6x loops per channel")
    func patternLoop() throws {
        var b = XMBuilder()
        b.patterns = patterns(1, [0: [fx(0, 0x0E, 0x60), fx(1, 0x0E, 0x62)]])
        #expect(try framesPlayed(b) == (64 + 4) * rowFrames)
    }

    @Test("After an E6x loop the next pattern starts at the loop row (FT2 quirk)")
    func patternLoopQuirk() throws {
        var b = XMBuilder()
        b.order = [0, 1]
        b.patterns = patterns(2, [0: [fx(10, 0x0E, 0x60), fx(11, 0x0E, 0x61)]])
        #expect(try framesPlayed(b) == (64 + 2 + 54) * rowFrames)
    }

    @Test("EEx repeats the row without hanging; repeats run per-tick effects only")
    func patternDelay() throws {
        var b = XMBuilder()
        b.patterns = patterns(1, [0: [fx(0, 0x0E, 0xE2)]])
        #expect(try framesPlayed(b) == (64 + 2) * rowFrames)

        var v = XMBuilder()
        v.instruments = [XMBuilder.Instrument()]
        v.patterns = [XMBuilder.Pattern(rows: 2, entries: [
            .init(row: 0, channel: 0, note: 49, instrument: 1, volume: 0x30, effect: 0x0A, param: 0x01),
            fx(0, 0x0E, 0xE1, channel: 1),
        ])]
        let m = try XMMixer(file: XMFile(data: v.build()), sampleRate: 1000)
        advance(m, frames: 2 * rowFrames)   // both passes of row 0
        #expect(m.currentRow == 0)
        #expect(m.snapshot(channel: 0).volume == 32 - 11)
    }

    @Test("Pathological E6x combinations still terminate")
    func pathologicalLoops() throws {
        var b = XMBuilder()
        b.patterns = patterns(1, [0: [
            fx(0, 0x0E, 0x61, channel: 0), fx(0, 0x0E, 0x61, channel: 1),
            fx(5, 0x0E, 0x6F, channel: 2), fx(6, 0x0E, 0x6F, channel: 3),
        ]])
        #expect(try framesPlayed(b) > 0)
    }

    @Test("Long tick sequences keep fractional timing")
    func fractionalTiming() throws {
        var b = XMBuilder()
        b.speed = 1
        b.bpm = 33
        let m = try XMMixer(file: XMFile(data: b.build()), sampleRate: 44_100)
        let n = renderAll(m, limit: 1_000_000, chunk: 4096).frames
        #expect(abs(Double(n) - 64 * 44_100 / 13.2) <= 1)
    }

    @Test("Rendering zero or negative frames is a no-op")
    func zeroFrames() throws {
        let m = try XMMixer(file: XMFile(data: XMBuilder().build()), sampleRate: 1000)
        var x: Float = 5
        #expect(m.render(into: &x, frames: 0) == 0)
        #expect(m.render(into: &x, frames: -1) == 0)
        #expect(x == 5)
        #expect(m.currentOrder == 0 && m.currentRow == 0)
    }
}
