import Testing
import Foundation
@testable import SwiftXM

/// Spec-driven parser tests built from Reference/xm-form.txt.
@Suite("XMFile spec coverage")
struct XMParserSpecTests {

    @Test("Parses a Data slice whose indices do not start at zero")
    func dataSlice() throws {
        let padded = Data([1, 2, 3]) + XMBuilder().build()
        let file = try XMFile(data: padded[3...])
        #expect(file.moduleName == "TEST")
        #expect(file.writingTracker == .fastTracker2)
    }

    @Test("Only versions 0x0102-0x0104 are accepted")
    func versions() throws {
        var b = XMBuilder()
        b.version = 0x0105
        #expect(throws: XMError.unsupportedVersion(0x0105)) { _ = try XMFile(data: b.build()) }
        b.version = 0x0101
        #expect(throws: XMError.unsupportedVersion(0x0101)) { _ = try XMFile(data: b.build()) }
    }

    @Test("Header size must cover the fixed fields and fit in the data")
    func headerSize() throws {
        var data = XMBuilder().build()
        data[60] = 10; data[61] = 0
        #expect(throws: XMError.invalidHeaderSize(10)) { _ = try XMFile(data: data) }
        data[60] = 0xFF; data[61] = 0xFF; data[62] = 0xFF; data[63] = 0xFF
        #expect(throws: XMError.truncatedHeader) { _ = try XMFile(data: data) }
        // Only 79 bytes: the fixed fields at 64...79 are cut off.
        var short = Data(XMBuilder().build().prefix(79))
        short[60] = 20
        #expect(throws: XMError.truncatedHeader) { _ = try XMFile(data: short) }
    }

    @Test("Header size is honoured: extra bytes are skipped, short tables read as 0")
    func headerSizeHonoured() throws {
        var b = XMBuilder()
        b.order = [1, 0, 1]
        b.patterns = [XMBuilder.Pattern(rows: 2), XMBuilder.Pattern(rows: 3)]
        b.headerSize = 276 + 16
        let big = try XMFile(data: b.build())
        #expect(big.patterns.map(\.rowCount) == [2, 3])
        #expect(Array(big.order.prefix(3)) == [1, 0, 1])

        b.headerSize = 20 + 2   // only two order bytes stored
        let small = try XMFile(data: b.build())
        #expect(Array(small.order.prefix(3)) == [1, 0, 0])
        #expect(small.patterns.map(\.rowCount) == [2, 3])
    }

    @Test("Channel count must be 1...128")
    func channelCount() throws {
        var b = XMBuilder()
        b.channels = 0
        #expect(throws: XMError.invalidChannelCount(0)) { _ = try XMFile(data: b.build()) }
        b.channels = 200
        b.patterns = []
        #expect(throws: XMError.invalidChannelCount(200)) { _ = try XMFile(data: b.build()) }
    }

    @Test("Song length is clamped to the 256-entry order table")
    func songLength() throws {
        var b = XMBuilder()
        b.songLength = 1000
        #expect(try XMFile(data: b.build()).songLength == 256)
    }

    @Test("Packed pattern cells honour each flag bit; unpacked cells read 5 bytes")
    func patternPacking() throws {
        var b = XMBuilder()
        b.channels = 2
        b.patterns = [XMBuilder.Pattern(rows: 2, entries: [
            .init(row: 0, channel: 0, note: 49, instrument: 1, volume: 0x40, effect: 0x0F, param: 3),
            .init(row: 0, channel: 1, volume: 0x20),
            .init(row: 1, channel: 1, effect: 0x0A, param: 0x10),
        ])]
        let p = try XMFile(data: b.build()).patterns[0]
        #expect(p.cell(row: 0, channel: 0).note == 49)
        #expect(p.cell(row: 0, channel: 0).instrument == 1)
        #expect(p.cell(row: 0, channel: 0).volume == 0x40)
        #expect(p.cell(row: 0, channel: 0).effect == 0x0F)
        #expect(p.cell(row: 0, channel: 0).param == 3)
        #expect(p.cell(row: 0, channel: 1).volume == 0x20)
        #expect(p.cell(row: 0, channel: 1).note == 0)
        #expect(p.cell(row: 1, channel: 1).effect == 0x0A)
        #expect(p.cell(row: 1, channel: 0) == XMPattern.Cell())
        #expect(p.cell(row: 5, channel: 9) == XMPattern.Cell())

        // Unpacked form: MSB clear, five raw bytes.
        var data = [UInt8](XMBuilder(channels: 1, patterns: []).build())
        data[70] = 1   // one pattern
        data += le32(9) + [0] + le16(1) + le16(5) + [49, 2, 0x30, 0x0C, 0x20]
        let q = try XMFile(data: Data(data)).patterns[0]
        #expect(q.cell(row: 0, channel: 0).note == 49)
        #expect(q.cell(row: 0, channel: 0).instrument == 2)
        #expect(q.cell(row: 0, channel: 0).volume == 0x30)
        #expect(q.cell(row: 0, channel: 0).effect == 0x0C)
        #expect(q.cell(row: 0, channel: 0).param == 0x20)
    }

    @Test("Note bytes above 97 decode as no note")
    func invalidNote() throws {
        var b = XMBuilder()
        b.patterns = [XMBuilder.Pattern(rows: 1, entries: [.init(row: 0, channel: 0, note: 120)])]
        #expect(try XMFile(data: b.build()).patterns[0].cell(row: 0, channel: 0).note == 0)
    }

    @Test("Zero-length (packed size 0) patterns are empty; 0 rows means 64")
    func emptyPatterns() throws {
        var b = XMBuilder()
        b.patterns = [XMBuilder.Pattern(rows: 32), XMBuilder.Pattern(rows: 0)]
        let file = try XMFile(data: b.build())
        #expect(file.patterns[0].rowCount == 32)
        #expect(file.patterns[0].cells.isEmpty)
        #expect(file.patterns[1].rowCount == 64)
    }

    @Test("Pattern header length is honoured and validated")
    func patternHeaderLength() throws {
        var b = XMBuilder()
        b.patterns = [XMBuilder.Pattern(rows: 1, entries: [.init(row: 0, channel: 0, note: 49)], headerLength: 13)]
        #expect(try XMFile(data: b.build()).patterns[0].cell(row: 0, channel: 0).note == 49)

        var data = XMBuilder().build()
        let p = 60 + 276
        data[p] = 4; data[p + 1] = 0; data[p + 2] = 0; data[p + 3] = 0
        #expect(throws: XMError.invalidPatternHeader(index: 0)) { _ = try XMFile(data: data) }
    }

    @Test("A pattern running past the end of the data throws")
    func truncatedPattern() throws {
        var b = XMBuilder()
        b.patterns = [XMBuilder.Pattern(rows: 4, entries: [.init(row: 3, channel: 0, note: 49)])]
        let data = b.build()
        #expect(throws: XMError.truncatedPattern(index: 0)) { _ = try XMFile(data: data.prefix(data.count - 1)) }
    }

    @Test("Many huge empty patterns cost no memory")
    func hugeEmptyPatterns() throws {
        var data = [UInt8](XMBuilder(channels: 128, patterns: []).build())
        data[70] = 0xFF; data[71] = 0xFF
        for _ in 0..<0xFFFF { data += le32(9) + [0] + le16(256) + le16(0) }
        let file = try XMFile(data: Data(data))
        #expect(file.patterns.count == 0xFFFF)
        #expect(file.patterns.allSatisfy { $0.cells.isEmpty && $0.rowCount == 256 })
    }

    @Test("8-bit and 16-bit samples are delta-decoded")
    func deltaDecoding() throws {
        var b = XMBuilder()
        var s8 = XMBuilder.Sample()
        s8.values = [0, 10, -5, 127, -128]
        var s16 = XMBuilder.Sample()
        s16.bits16 = true
        s16.values = [0, 1000, -32768, 32767, 5]
        b.instruments = [XMBuilder.Instrument(samples: [s8, s16])]
        let ins = try XMFile(data: b.build()).instruments[0]
        #expect(ins.samples[0].pcm == [0, 10 << 8, -5 << 8, 127 << 8, -128 << 8])
        #expect(ins.samples[1].pcm == [0, 1000, -32768, 32767, 5])
        #expect(ins.samples[1].lengthFrames == 5)
        #expect(ins.samples[1].bits16)
    }

    @Test("Delta decoding wraps like FT2")
    func deltaWrap() throws {
        var b = XMBuilder()
        var s = XMBuilder.Sample()
        s.rawBody = [100, 100]   // 100 + 100 wraps to -56
        b.instruments = [XMBuilder.Instrument(samples: [s])]
        #expect(try XMFile(data: b.build()).instruments[0].samples[0].pcm == [100 << 8, -56 << 8])
    }

    @Test("Loop points convert bytes to frames; type 3 is ping-pong; empty loops are off")
    func loops() throws {
        var b = XMBuilder()
        var s16 = XMBuilder.Sample()
        s16.bits16 = true
        s16.values = Array(repeating: 0, count: 100)
        s16.loopStart = 10
        s16.loopLength = 20
        s16.loopType = 3
        var empty = XMBuilder.Sample()
        empty.loopType = 1
        empty.loopLength = 0
        var long = XMBuilder.Sample()
        long.values = Array(repeating: 0, count: 50)
        long.loopType = 1
        long.loopStart = 40
        long.loopLength = 100
        b.instruments = [XMBuilder.Instrument(samples: [s16, empty, long])]
        let smp = try XMFile(data: b.build()).instruments[0].samples
        #expect(smp[0].loopBegin == 10)
        #expect(smp[0].loopEnd == 30)
        #expect(smp[0].loopMode == .pingPong)
        #expect(smp[1].loopMode == .none)
        #expect(smp[2].loopMode == .forward)
        #expect(smp[2].loopEnd == 50)
    }

    @Test("Sample data cut off by the end of the file is clipped")
    func clippedSample() throws {
        var b = XMBuilder()
        var s = XMBuilder.Sample()
        s.values = Array(repeating: 1, count: 100)
        b.instruments = [XMBuilder.Instrument(samples: [s])]
        let data = b.build()
        let file = try XMFile(data: data.prefix(data.count - 40))
        #expect(file.instruments[0].samples[0].lengthFrames == 60)
    }

    @Test("Instrument header size: larger is skipped, smaller zero-fills, tiny reads 29")
    func instrumentHeaderSize() throws {
        var b = XMBuilder()
        var big = XMBuilder.Instrument()
        big.headerSize = 300
        big.fadeout = 0x123
        var small = XMBuilder.Instrument()
        small.headerSize = 33 + 96    // sample map only, no envelopes
        small.sampleMap[48] = 1
        small.samples = [.looped(), .looped(16)]
        var empty = XMBuilder.Instrument(name: "EMPTY", samples: [])
        empty.headerSize = 0
        b.instruments = [big, small, empty]
        let file = try XMFile(data: b.build())
        #expect(file.instruments[0].volumeFadeout == 0x123)
        #expect(file.instruments[0].samples.count == 1)
        #expect(file.instruments[1].sampleMap[48] == 1)
        #expect(file.instruments[1].volumeFadeout == 0)
        #expect(file.instruments[1].samples.map(\.lengthFrames) == [64, 16])
        #expect(file.instruments[2].name == "EMPTY")
        #expect(file.instruments[2].samples.isEmpty)
    }

    @Test("A zero sample-header size falls back to FT2's 40 bytes")
    func sampleHeaderSize() throws {
        var b = XMBuilder()
        var ins = XMBuilder.Instrument()
        ins.sampleHeaderSize = 0
        b.instruments = [ins]
        // The builder wrote 40-byte headers, so the file stays valid.
        let file = try XMFile(data: b.build())
        #expect(file.instruments[0].samples[0].lengthFrames == 64)
    }

    @Test("Instrument headers or sample headers past the end throw")
    func truncatedInstrument() throws {
        var b = XMBuilder()
        b.instruments = [XMBuilder.Instrument()]
        let data = b.build()
        let headerEnd = 60 + 276 + 9
        #expect(throws: XMError.truncatedInstrument(index: 0)) { _ = try XMFile(data: data.prefix(headerEnd + 100)) }
        #expect(throws: XMError.truncatedInstrument(index: 0)) { _ = try XMFile(data: data.prefix(headerEnd + 263 + 20)) }
    }

    @Test("Envelopes keep at most 12 points with values clamped to 64; flags decode")
    func envelopes() throws {
        var b = XMBuilder()
        var ins = XMBuilder.Instrument()
        ins.volumeEnvelope = .init(points: [(0, 64), (10, 200), (20, 0)], sustain: 1, loopStart: 0, loopEnd: 2, flags: 7)
        ins.panningEnvelope = .init(points: [(0, 32)], flags: 1)
        ins.vibratoType = 2; ins.vibratoSweep = 10; ins.vibratoDepth = 8; ins.vibratoRate = 20
        ins.fadeout = 0x200
        b.instruments = [ins]
        var data = b.build()
        let i = try XMFile(data: data).instruments[0]
        #expect(i.volumeEnvelope.points.map(\.value) == [64, 64, 0])
        #expect(i.volumeEnvelope.enabled && i.volumeEnvelope.sustainEnabled && i.volumeEnvelope.loopEnabled)
        #expect(i.volumeEnvelope.sustainPoint == 1)
        #expect(i.volumeEnvelope.loopEnd == 2)
        #expect(i.panningEnvelope.enabled && !i.panningEnvelope.loopEnabled)
        #expect(i.autoVibrato == .init(type: 2, sweep: 10, depth: 8, rate: 20))
        #expect(i.volumeFadeout == 0x200)

        // Point count 200 is clamped to 12.
        let countOffset = 60 + 276 + 9 + 29 + 196
        data[countOffset] = 200
        #expect(try XMFile(data: data).instruments[0].volumeEnvelope.points.count == 12)
    }

    @Test("Sample header fields: volume clamp, finetune, panning, relative note, name")
    func sampleHeader() throws {
        var b = XMBuilder()
        var s = XMBuilder.Sample()
        s.volume = 90; s.finetune = -100; s.panning = 7; s.relativeNote = -12; s.name = "KICK"
        b.instruments = [XMBuilder.Instrument(samples: [s])]
        let smp = try XMFile(data: b.build()).instruments[0].samples[0]
        #expect(smp.volume == 64)
        #expect(smp.finetune == -100)
        #expect(smp.panning == 7)
        #expect(smp.relativeNote == -12)
        #expect(smp.name == "KICK")
    }

    @Test("ModPlug ADPCM samples (reserved = 0xAD) decode")
    func adpcm() throws {
        var b = XMBuilder()
        var s = XMBuilder.Sample()
        s.reserved = 0xAD
        s.storedLength = 4
        let table: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8]
        s.rawBody = table + [0x21, 0x83]   // nibbles 1,2,3,8
        b.instruments = [XMBuilder.Instrument(samples: [s])]
        let pcm = try XMFile(data: b.build()).instruments[0].samples[0].pcm
        #expect(pcm == [1 << 8, 3 << 8, 6 << 8, 5 << 8])
    }

    @Test("Versions 0x0103 and 0x0102 store instruments before patterns and samples last")
    func oldVersions() throws {
        for version: UInt16 in [0x0102, 0x0103] {
            var b = XMBuilder()
            b.version = version
            b.patterns = [XMBuilder.Pattern(rows: 16, entries: [.init(row: 15, channel: 3, note: 50)])]
            var s = XMBuilder.Sample()
            s.values = [1, 2, 3]
            b.instruments = [XMBuilder.Instrument(name: "OLD", samples: [s])]
            let file = try XMFile(data: b.build())
            #expect(file.patterns[0].rowCount == 16)
            #expect(file.patterns[0].cell(row: 15, channel: 3).note == 50)
            #expect(file.instruments[0].name == "OLD")
            #expect(file.instruments[0].samples[0].pcm == [1 << 8, 2 << 8, 3 << 8])
        }
    }

    @Test("Names decode as code page 437")
    func cp437() throws {
        var data = XMBuilder().build()
        data[17] = 0x81   // ü
        data[18] = 0xDB   // █
        data[19] = 0
        #expect(try XMFile(data: data).moduleName == "ü█")
    }

    @Test("Volume column bytes decode per the spec table")
    func volumeColumn() {
        #expect(XMVolumeCommand(byte: 0x00) == .none)
        #expect(XMVolumeCommand(byte: 0x10) == .setVolume(0))
        #expect(XMVolumeCommand(byte: 0x50) == .setVolume(64))
        #expect(XMVolumeCommand(byte: 0x51) == .none)
        #expect(XMVolumeCommand(byte: 0x5F) == .none)
        #expect(XMVolumeCommand(byte: 0x63) == .slideDown(3))
        #expect(XMVolumeCommand(byte: 0x74) == .slideUp(4))
        #expect(XMVolumeCommand(byte: 0x85) == .fineSlideDown(5))
        #expect(XMVolumeCommand(byte: 0x96) == .fineSlideUp(6))
        #expect(XMVolumeCommand(byte: 0xA7) == .setVibratoSpeed(7))
        #expect(XMVolumeCommand(byte: 0xB8) == .vibrato(8))
        #expect(XMVolumeCommand(byte: 0xC9) == .setPanning(0x90))
        #expect(XMVolumeCommand(byte: 0xDA) == .panSlideLeft(10))
        #expect(XMVolumeCommand(byte: 0xEB) == .panSlideRight(11))
        #expect(XMVolumeCommand(byte: 0xFC) == .tonePorta(0xC0))
    }
}
