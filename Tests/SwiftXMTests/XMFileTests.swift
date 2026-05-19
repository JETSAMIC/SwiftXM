import Testing
import Foundation
@testable import SwiftXM

/// Tests for the parser entry points. We don't ship a binary
/// fixture; each test composes a synthetic byte stream that
/// matches the spec, which keeps the suite hermetic and lets
/// reviewers see exactly what's being asserted.
@Suite("XMFile parser")
struct XMFileTests {

    @Test("Rejects input shorter than the fixed header")
    func tooShort() throws {
        let data = Data([0x00, 0x01, 0x02])
        #expect(throws: XMError.tooShort) {
            _ = try XMFile(data: data)
        }
    }

    @Test("Rejects input missing the 'Extended Module: ' signature")
    func badSignature() throws {
        var data = Data(repeating: 0, count: 80)
        for (i, b) in "ABCDEFGHIJKLMNOPQ".utf8.enumerated() { data[i] = b }
        #expect(throws: XMError.badSignature) {
            _ = try XMFile(data: data)
        }
    }

    @Test("Parses a minimal valid header")
    func minimalHeader() throws {
        let data = makeMinimalModule(name: "TESTMOD", channels: 4, tempo: 6, bpm: 125)
        let file = try XMFile(data: data)
        #expect(file.moduleName == "TESTMOD")
        #expect(file.channelCount == 4)
        #expect(file.patternCount == 0)
        #expect(file.instrumentCount == 0)
        #expect(file.defaultTempo == 6)
        #expect(file.defaultBPM == 125)
        #expect(file.frequencyTable == .linear)
        #expect(file.order.count == 256)
    }

    @Test("Honors the frequency-table flag")
    func amigaFrequencyTable() throws {
        // Build a minimal module then flip the flags bit 0 to 0.
        var data = makeMinimalModule(name: "AMIGA", channels: 4, tempo: 6, bpm: 125)
        data[74] = 0x00  // bit 0 clear -> Amiga
        data[75] = 0x00
        let file = try XMFile(data: data)
        #expect(file.frequencyTable == .amiga)
    }

    @Test("Honors the requested channel count")
    func multiChannel() throws {
        let data = makeMinimalModule(name: "WIDE", channels: 16, tempo: 6, bpm: 125)
        let file = try XMFile(data: data)
        #expect(file.channelCount == 16)
    }
}

/// Compose a syntactically valid (musically empty) XM file with
/// the given header fields. No patterns and no instruments, so the
/// body cursor lands right at end-of-file after the header.
private func makeMinimalModule(
    name: String, channels: Int, tempo: Int, bpm: Int
) -> Data {
    // 60-byte ID block + 4-byte header-size + 20-byte header-tail
    // + 256-byte order table = 340 bytes total.
    let headerTailLen = 4 + 20 + 256  // includes the header-size field itself
    var data = Data(repeating: 0, count: 60 + headerTailLen)

    // ID
    let id = "Extended Module: "
    for (i, b) in id.utf8.enumerated() { data[i] = b }
    // Module name (17..36)
    let nameBytes = Array(name.utf8).prefix(20)
    for (i, b) in nameBytes.enumerated() { data[17 + i] = b }
    data[37] = 0x1A
    // Tracker name (38..57) — leave empty
    // Version (58..59) — 0x0104
    data[58] = 0x04
    data[59] = 0x01
    // Header size at offset 60 (calculated from offset 60)
    let headerSize: UInt32 = UInt32(headerTailLen)
    data[60] = UInt8(truncatingIfNeeded: headerSize)
    data[61] = UInt8(truncatingIfNeeded: headerSize >> 8)
    data[62] = UInt8(truncatingIfNeeded: headerSize >> 16)
    data[63] = UInt8(truncatingIfNeeded: headerSize >> 24)
    // songLength = 0
    // restartPosition = 0
    // channels
    data[68] = UInt8(channels & 0xFF)
    data[69] = UInt8((channels >> 8) & 0xFF)
    // patternCount = 0, instrumentCount = 0
    // flags (bit 0 = linear)
    data[74] = 0x01
    // tempo
    data[76] = UInt8(tempo & 0xFF)
    data[77] = UInt8((tempo >> 8) & 0xFF)
    // BPM
    data[78] = UInt8(bpm & 0xFF)
    data[79] = UInt8((bpm >> 8) & 0xFF)
    return data
}
