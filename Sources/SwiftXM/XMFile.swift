/// XMFile.swift
///
/// Parser for FastTracker II (.xm) "Extended Module" files. Follows
/// the spec mirrored under `Reference/xm-form.txt` (the "Complete XM
/// module format specification v0.81" by ccr/TNSP, itself built on
/// Mr.H/Triton's 1994 original) and, where that document is silent or
/// wrong, the de-facto behaviour of FT2 (as reproduced by ft2-clone)
/// and OpenMPT's XM loader.
///
/// Layout handled:
///
/// - Version 0x0104: header, patterns, then each instrument followed
///   by its sample headers and sample data.
/// - Versions 0x0102 / 0x0103: header, all instruments with their
///   sample headers, patterns, then all sample data. Version 0x0102
///   stores the pattern row count as a single byte.
///
/// Every size and offset is validated against the input, so arbitrary
/// data either parses or throws an `XMError`; it never traps.

import Foundation

// MARK: - Errors

/// Errors thrown while parsing an XM module or configuring a mixer.
public enum XMError: Error, LocalizedError, Sendable, Equatable {
    /// The data is shorter than the 64-byte fixed part of the header.
    case tooShort
    /// The `Extended Module: ` signature is missing.
    case badSignature
    /// The format version is not 0x0102, 0x0103 or 0x0104.
    case unsupportedVersion(UInt16)
    /// The header-size field is smaller than the 20 bytes of fixed
    /// fields it must contain.
    case invalidHeaderSize(UInt32)
    /// The channel count is 0 or above 128.
    case invalidChannelCount(Int)
    /// The header (including the order table) runs past the end of the
    /// data.
    case truncatedHeader
    /// The pattern at `index` (0-based) has a header shorter than its
    /// fixed fields.
    case invalidPatternHeader(index: Int)
    /// The pattern at `index` (0-based) runs past the end of the data.
    case truncatedPattern(index: Int)
    /// The instrument at `index` (0-based) or its sample headers run
    /// past the end of the data.
    case truncatedInstrument(index: Int)
    /// The sample rate passed to ``XMMixer/init(file:sampleRate:)`` is
    /// not a finite value in `1...1_000_000`.
    case invalidSampleRate

    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .tooShort:
            return "XM file too short to contain a valid header."
        case .badSignature:
            return "XM signature ('Extended Module: ') not found."
        case .unsupportedVersion(let v):
            return String(format: "Unsupported XM version 0x%04X.", v)
        case .invalidHeaderSize(let size):
            return "XM header size \(size) is too small."
        case .invalidChannelCount(let count):
            return "XM channel count \(count) is outside 1...128."
        case .truncatedHeader:
            return "XM header is truncated."
        case .invalidPatternHeader(let index):
            return "XM pattern \(index) has an invalid header."
        case .truncatedPattern(let index):
            return "XM pattern \(index) is truncated."
        case .truncatedInstrument(let index):
            return "XM instrument \(index + 1) is truncated."
        case .invalidSampleRate:
            return "Sample rate must be a finite value between 1 and 1,000,000 Hz."
        }
    }
}

// MARK: - File

/// A parsed FastTracker II module.
///
/// Header values are exposed as stored (with the documented clamps);
/// the mixer applies FT2's defaults at playback time.
public struct XMFile: Sendable {

    /// Frequency-table selector (header flag bit 0).
    public enum FrequencyTable: Sendable, Hashable {
        /// Amiga (logarithmic) periods, as in ProTracker.
        case amiga
        /// Linear periods: 64 units per semitone (the FT2 default).
        case linear
    }

    /// Which tracker wrote this file, guessed from ``trackerName``.
    /// Informational only: playback always follows FT2 semantics.
    public enum WritingTracker: Sendable, Hashable {
        /// FastTracker II (or a tool that impersonates it).
        case fastTracker2
        /// OpenMPT / ModPlug Tracker.
        case openMPT
        /// MilkyTracker.
        case milkyTracker
        /// DigiBooster.
        case digiBooster
        /// Schism Tracker.
        case schism
        /// Anything else.
        case other
    }

    /// Module name (20 characters max, code page 437).
    public let moduleName: String
    /// Tracker name field (20 characters max).
    public let trackerName: String
    /// Writer guessed from ``trackerName``.
    public let writingTracker: WritingTracker
    /// Format version, e.g. `0x0104`.
    public let version: UInt16
    /// Number of entries of ``order`` that make up the song (0...256).
    public let songLength: Int
    /// Order index FT2 jumps to after the last order. The mixer stops
    /// at the end of the song instead of looping, so this is
    /// informational.
    public let restartPosition: Int
    /// Number of channels (1...128).
    public let channelCount: Int
    /// Number of patterns stored in the file.
    public let patternCount: Int
    /// Number of instruments stored in the file.
    public let instrumentCount: Int
    /// Frequency table used for pitch calculation.
    public let frequencyTable: FrequencyTable
    /// Initial speed (ticks per row) as stored; FT2 calls this "tempo".
    public let defaultTempo: Int
    /// Initial BPM as stored; the tick rate is `bpm * 2 / 5` Hz.
    public let defaultBPM: Int

    /// The 256-entry pattern order table. Only the first
    /// ``songLength`` entries are played. Entries that name a pattern
    /// not stored in the file play as an empty 64-row pattern (FT2
    /// behaviour). Bytes missing from a short header read as 0.
    public let order: [UInt8]

    /// Patterns in file order.
    public let patterns: [XMPattern]
    /// Instruments in file order; pattern cells reference them 1-based.
    public let instruments: [XMInstrument]

    // MARK: - Init

    /// Parses an XM module.
    ///
    /// - Parameter data: The complete contents of an `.xm` file.
    /// - Throws: ``XMError`` if the data is not a supported XM module,
    ///   or if its header, patterns or instrument headers are
    ///   truncated or inconsistent. Sample data cut off by the end of
    ///   the file is clipped rather than rejected.
    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 64 else { throw XMError.tooShort }
        guard Array(bytes[0..<17]) == Array("Extended Module: ".utf8) else {
            throw XMError.badSignature
        }
        moduleName = decodeCP437(bytes[17..<37])
        trackerName = decodeCP437(bytes[38..<58])
        writingTracker = Self.detectWritingTracker(name: trackerName)
        version = bytes.u16(at: 58)
        guard (0x0102...0x0104).contains(version) else {
            throw XMError.unsupportedVersion(version)
        }

        // The header size is counted from offset 60. It must cover the
        // 20 bytes of fixed fields; the order table fills the rest (up
        // to 256 entries). Anything beyond that is skipped.
        let headerSize = bytes.u32(at: 60)
        guard headerSize >= 20 else { throw XMError.invalidHeaderSize(headerSize) }
        guard UInt64(headerSize) <= UInt64(bytes.count - 60) else { throw XMError.truncatedHeader }
        let headerEnd = 60 + Int(headerSize)

        songLength = min(256, Int(bytes.u16(at: 64)))
        restartPosition = Int(bytes.u16(at: 66))
        channelCount = Int(bytes.u16(at: 68))
        patternCount = Int(bytes.u16(at: 70))
        instrumentCount = Int(bytes.u16(at: 72))
        frequencyTable = bytes.u16(at: 74) & 0x01 != 0 ? .linear : .amiga
        defaultTempo = Int(bytes.u16(at: 76))
        defaultBPM = Int(bytes.u16(at: 78))
        guard (1...128).contains(channelCount) else {
            throw XMError.invalidChannelCount(channelCount)
        }

        var orderBytes = [UInt8](repeating: 0, count: 256)
        for i in 0..<min(256, headerEnd - 80) {
            orderBytes[i] = bytes[80 + i]
        }
        order = orderBytes

        var cursor = headerEnd
        if version >= 0x0104 {
            patterns = try Self.parsePatterns(bytes, &cursor, count: patternCount,
                                              channels: channelCount, version: version)
            var insts: [XMInstrument] = []
            for i in 0..<instrumentCount {
                var pending = try XMInstrument.parseHeader(bytes, &cursor, index: i)
                pending.loadSampleData(bytes, &cursor)
                insts.append(pending.instrument)
            }
            instruments = insts
        } else {
            var pending: [XMInstrument.Pending] = []
            for i in 0..<instrumentCount {
                pending.append(try XMInstrument.parseHeader(bytes, &cursor, index: i))
            }
            patterns = try Self.parsePatterns(bytes, &cursor, count: patternCount,
                                              channels: channelCount, version: version)
            for i in pending.indices {
                pending[i].loadSampleData(bytes, &cursor)
            }
            instruments = pending.map(\.instrument)
        }
    }

    private static func parsePatterns(_ bytes: [UInt8], _ cursor: inout Int, count: Int,
                                      channels: Int, version: UInt16) throws -> [XMPattern] {
        var parsed: [XMPattern] = []
        parsed.reserveCapacity(min(count, 256))
        for i in 0..<count {
            parsed.append(try XMPattern.parse(bytes, &cursor, channels: channels,
                                              version: version, index: i))
        }
        return parsed
    }

    // MARK: - Helpers

    /// Map the `trackerName` field to a writer identity.
    private static func detectWritingTracker(name: String) -> WritingTracker {
        let lower = name.lowercased()
        if lower.contains("openmpt") || lower.contains("modplug") { return .openMPT }
        if lower.contains("milkytracker") { return .milkyTracker }
        if lower.contains("digibooster") { return .digiBooster }
        if lower.contains("schism") { return .schism }
        if lower.contains("fasttracker") || lower.contains("ft2") {
            return .fastTracker2
        }
        return .other
    }
}

// MARK: - Pattern

/// One pattern: a grid of ``rowCount`` rows by ``channelCount``
/// channels.
public struct XMPattern: Sendable {

    /// One cell in the channel grid.
    public struct Cell: Sendable, Hashable {
        /// 1...96 = note (1 = C-0), 97 = key off, 0 = no note. Bytes
        /// above 97 are invalid and decode as 0.
        public internal(set) var note: UInt8 = 0
        /// Instrument number 1...128, 0 = none.
        public internal(set) var instrument: UInt8 = 0
        /// Raw volume-column byte (see ``XMVolumeCommand``).
        public internal(set) var volume: UInt8 = 0
        /// Effect number: 0...0x0F for `0`-`F`, 0x10 = `G` ... 0x21 = `X`.
        public internal(set) var effect: UInt8 = 0
        /// Effect parameter.
        public internal(set) var param: UInt8 = 0

        /// An empty cell.
        public init() {}
    }

    /// Number of rows (1...1024; a stored 0 means 64, as in OpenMPT).
    public let rowCount: Int
    /// Number of channels (the module's channel count).
    public let channelCount: Int

    /// Decoded cells in row-major order. Only the prefix actually
    /// present in the file is stored; every cell after it is empty.
    /// This keeps memory proportional to the file size even when a
    /// header declares a huge empty pattern.
    let cells: [Cell]

    /// Maximum rows per pattern (OpenMPT's limit; FT2 stops at 256).
    static let maxRows = 1024

    /// The cell at `row`, `channel`, or an empty cell if either index
    /// is out of range.
    public func cell(row: Int, channel: Int) -> Cell {
        guard row >= 0, row < rowCount, channel >= 0, channel < channelCount else { return Cell() }
        let i = row * channelCount + channel
        return i < cells.count ? cells[i] : Cell()
    }

    /// An empty 64-row pattern, used for order entries that reference
    /// a pattern missing from the file.
    static func empty(channels: Int) -> XMPattern {
        XMPattern(rowCount: 64, channelCount: channels, cells: [])
    }

    static func parse(_ bytes: [UInt8], _ cursor: inout Int, channels: Int,
                      version: UInt16, index: Int) throws -> XMPattern {
        let start = cursor
        let fixed = version == 0x0102 ? 8 : 9
        guard bytes.count - start >= fixed else { throw XMError.truncatedPattern(index: index) }
        let headerLength = bytes.u32(at: start)
        guard headerLength >= UInt32(fixed) else { throw XMError.invalidPatternHeader(index: index) }
        // bytes[start + 4] is the packing type (always 0).
        var rows: Int
        let packedSize: Int
        if version == 0x0102 {
            rows = Int(bytes[start + 5]) + 1
            packedSize = Int(bytes.u16(at: start + 6))
        } else {
            rows = Int(bytes.u16(at: start + 5))
            packedSize = Int(bytes.u16(at: start + 7))
        }
        if rows == 0 { rows = 64 }
        rows = min(rows, maxRows)

        guard UInt64(headerLength) + UInt64(packedSize) <= UInt64(bytes.count - start) else {
            throw XMError.truncatedPattern(index: index)
        }
        let dataStart = start + Int(headerLength)
        let end = dataStart + packedSize
        cursor = end

        let total = rows * channels
        var cells: [Cell] = []
        cells.reserveCapacity(min(total, packedSize))
        var p = dataStart
        while p < end && cells.count < total {
            let b = bytes[p]
            p += 1
            var cell = Cell()
            if b & 0x80 != 0 {
                if b & 0x01 != 0, p < end { cell.note = bytes[p]; p += 1 }
                if b & 0x02 != 0, p < end { cell.instrument = bytes[p]; p += 1 }
                if b & 0x04 != 0, p < end { cell.volume = bytes[p]; p += 1 }
                if b & 0x08 != 0, p < end { cell.effect = bytes[p]; p += 1 }
                if b & 0x10 != 0, p < end { cell.param = bytes[p]; p += 1 }
            } else {
                // Unpacked cell: note followed by the other four bytes.
                cell.note = b
                if p + 4 <= end {
                    cell.instrument = bytes[p]
                    cell.volume = bytes[p + 1]
                    cell.effect = bytes[p + 2]
                    cell.param = bytes[p + 3]
                    p += 4
                } else {
                    p = end
                }
            }
            if cell.note > 97 { cell.note = 0 }
            cells.append(cell)
        }
        // Drop trailing empty cells so empty patterns cost nothing.
        while let last = cells.last, last == Cell() { cells.removeLast() }
        return XMPattern(rowCount: rows, channelCount: channels, cells: cells)
    }
}

// MARK: - Instrument

/// An instrument: up to 16 samples plus envelopes, auto-vibrato and
/// fade-out.
public struct XMInstrument: Sendable {

    /// A volume or panning envelope (up to 12 points).
    public struct Envelope: Sendable, Hashable {
        /// One envelope point.
        public struct Point: Sendable, Hashable {
            /// X coordinate in ticks.
            public let frame: UInt16
            /// Y coordinate, 0...64 (clamped).
            public let value: UInt16
        }
        /// Points in file order (at most 12).
        public let points: [Point]
        /// Index of the sustain point.
        public let sustainPoint: Int
        /// Index of the loop start point.
        public let loopStart: Int
        /// Index of the loop end point.
        public let loopEnd: Int
        /// Type bit 0: the envelope is on.
        public let enabled: Bool
        /// Type bit 1: hold at the sustain point until key off.
        public let sustainEnabled: Bool
        /// Type bit 2: loop between the loop points.
        public let loopEnabled: Bool

        static let off = Envelope(points: [], sustainPoint: 0, loopStart: 0, loopEnd: 0,
                                  enabled: false, sustainEnabled: false, loopEnabled: false)
    }

    /// Instrument auto-vibrato settings.
    public struct AutoVibrato: Sendable, Hashable {
        /// Waveform: 0 = sine, 1 = square, 2 = ramp up, 3 = ramp down.
        public let type: UInt8
        /// Ticks until full depth is reached (0 = immediately).
        public let sweep: UInt8
        /// Depth, 0...15.
        public let depth: UInt8
        /// Rate, 0...63 (position step per tick out of 256).
        public let rate: UInt8
    }

    /// Instrument name (22 characters max).
    public let name: String
    /// Sample number (0-based into ``samples``) for each of the 96
    /// notes.
    public let sampleMap: [UInt8]
    /// The instrument's samples.
    public let samples: [XMSample]
    /// Volume envelope.
    public let volumeEnvelope: Envelope
    /// Panning envelope.
    public let panningEnvelope: Envelope
    /// Auto-vibrato settings.
    public let autoVibrato: AutoVibrato
    /// Fade-out speed applied each tick after key off (0...0xFFF).
    public let volumeFadeout: UInt16

    /// An instrument with no samples.
    public static let empty = XMInstrument(
        name: "",
        sampleMap: [UInt8](repeating: 0, count: 96),
        samples: [],
        volumeEnvelope: .off,
        panningEnvelope: .off,
        autoVibrato: AutoVibrato(type: 0, sweep: 0, depth: 0, rate: 0),
        volumeFadeout: 0
    )

    /// Header parsed, sample data not yet loaded.
    struct Pending {
        var instrument: XMInstrument
        var headers: [XMSample.Header]

        mutating func loadSampleData(_ bytes: [UInt8], _ cursor: inout Int) {
            var samples: [XMSample] = []
            for header in headers {
                samples.append(XMSample(header: header, bytes: bytes, cursor: &cursor))
            }
            instrument = XMInstrument(
                name: instrument.name, sampleMap: instrument.sampleMap, samples: samples,
                volumeEnvelope: instrument.volumeEnvelope, panningEnvelope: instrument.panningEnvelope,
                autoVibrato: instrument.autoVibrato, volumeFadeout: instrument.volumeFadeout
            )
        }
    }

    /// Size of the full FT2 instrument header (29 + 214 bytes + pad).
    private static let fullHeaderSize = 243

    static func parseHeader(_ bytes: [UInt8], _ cursor: inout Int, index: Int) throws -> Pending {
        let start = cursor
        guard bytes.count - start >= 29 else { throw XMError.truncatedInstrument(index: index) }
        // The size field covers the instrument header and its extended
        // part. Writers disagree on it: larger values are skipped,
        // smaller ones mean the missing fields read as zero (as in
        // OpenMPT), and values below the 29 fixed bytes are treated as
        // 29.
        let rawSize = bytes.u32(at: start)
        guard UInt64(rawSize) <= UInt64(bytes.count - start) || rawSize < 29 else {
            throw XMError.truncatedInstrument(index: index)
        }
        let size = max(29, Int(rawSize))
        let name = decodeCP437(bytes[(start + 4)..<(start + 26)])
        let sampleCount = Int(bytes.u16(at: start + 27))
        cursor = start + size

        guard sampleCount > 0 else {
            return Pending(instrument: XMInstrument(
                name: name, sampleMap: empty.sampleMap, samples: [],
                volumeEnvelope: .off, panningEnvelope: .off,
                autoVibrato: empty.autoVibrato, volumeFadeout: 0
            ), headers: [])
        }

        // Extended header, zero-filled beyond the declared size.
        var ext = [UInt8](repeating: 0, count: fullHeaderSize - 29)
        let available = min(size, fullHeaderSize) - 29
        if available > 0 { ext.replaceSubrange(0..<available, with: bytes[(start + 29)..<(start + 29 + available)]) }

        // FT2 always writes 40-byte sample headers; some writers store
        // 0 or garbage here, so only plausible larger values are used.
        let declaredSampleHeader = Int(ext.u32(at: 0))
        let sampleHeaderSize = (40...256).contains(declaredSampleHeader) ? declaredSampleHeader : 40

        let sampleMap = Array(ext[4..<100])
        func envelope(pointsAt: Int, count: Int, sustain: Int, loopStart: Int, loopEnd: Int,
                      flags: UInt8) -> Envelope {
            let points = (0..<min(12, count)).map { i in
                Envelope.Point(frame: ext.u16(at: pointsAt + i * 4),
                               value: min(64, ext.u16(at: pointsAt + i * 4 + 2)))
            }
            return Envelope(points: points, sustainPoint: sustain, loopStart: loopStart,
                            loopEnd: loopEnd, enabled: flags & 0x01 != 0,
                            sustainEnabled: flags & 0x02 != 0, loopEnabled: flags & 0x04 != 0)
        }
        let volEnv = envelope(pointsAt: 100, count: Int(ext[196]), sustain: Int(ext[198]),
                              loopStart: Int(ext[199]), loopEnd: Int(ext[200]), flags: ext[204])
        let panEnv = envelope(pointsAt: 148, count: Int(ext[197]), sustain: Int(ext[201]),
                              loopStart: Int(ext[202]), loopEnd: Int(ext[203]), flags: ext[205])
        let vibrato = AutoVibrato(type: ext[206] & 0x03, sweep: ext[207],
                                  depth: ext[208] & 0x0F, rate: ext[209] & 0x3F)
        let fadeout = ext.u16(at: 210)

        guard UInt64(sampleCount) * UInt64(sampleHeaderSize) <= UInt64(bytes.count - cursor) else {
            throw XMError.truncatedInstrument(index: index)
        }
        var headers: [XMSample.Header] = []
        headers.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            headers.append(XMSample.Header(bytes: bytes, at: cursor))
            cursor += sampleHeaderSize
        }

        return Pending(instrument: XMInstrument(
            name: name, sampleMap: sampleMap, samples: [],
            volumeEnvelope: volEnv, panningEnvelope: panEnv,
            autoVibrato: vibrato, volumeFadeout: fadeout
        ), headers: headers)
    }

    private init(name: String, sampleMap: [UInt8], samples: [XMSample],
                 volumeEnvelope: Envelope, panningEnvelope: Envelope,
                 autoVibrato: AutoVibrato, volumeFadeout: UInt16) {
        self.name = name
        self.sampleMap = sampleMap
        self.samples = samples
        self.volumeEnvelope = volumeEnvelope
        self.panningEnvelope = panningEnvelope
        self.autoVibrato = autoVibrato
        self.volumeFadeout = volumeFadeout
    }
}

// MARK: - Sample

/// One decoded sample of an instrument.
public struct XMSample: Sendable {

    /// Sample loop mode (type bits 0-1).
    public enum LoopMode: UInt8, Sendable {
        /// No loop.
        case none = 0
        /// Forward loop.
        case forward = 1
        /// Ping-pong (bidirectional) loop. Type value 3 is treated as
        /// ping-pong too.
        case pingPong = 2
    }

    /// Sample name (22 characters max).
    public let name: String
    /// Decoded length in frames (clipped to the data in the file).
    public let lengthFrames: Int
    /// Loop start in frames.
    public let loopBegin: Int
    /// Loop end in frames (exclusive).
    public let loopEnd: Int
    /// Loop mode; `.none` when the clipped loop is empty.
    public let loopMode: LoopMode
    /// `true` for 16-bit sample data.
    public let bits16: Bool
    /// Default volume, 0...64 (clamped).
    public let volume: UInt8
    /// Finetune in 1/128 semitones (-128...127).
    public let finetune: Int8
    /// Default panning, 0 (left) ... 255 (right).
    public let panning: UInt8
    /// Transpose in semitones applied to every note.
    public let relativeNote: Int8
    /// Decoded (delta-undone) PCM; 8-bit data is scaled to 16-bit.
    public let pcm: [Int16]

    /// The 40-byte on-disk sample header.
    struct Header {
        var byteLength: UInt32 = 0
        var loopStart: UInt32 = 0
        var loopLength: UInt32 = 0
        var volume: UInt8 = 0
        var finetune: Int8 = 0
        var type: UInt8 = 0
        var panning: UInt8 = 0x80
        var relativeNote: Int8 = 0
        var reserved: UInt8 = 0
        var name = ""

        /// Reads up to 40 bytes at `offset`; bytes past the end of the
        /// data read as zero.
        init(bytes: [UInt8], at offset: Int) {
            var h = [UInt8](repeating: 0, count: 40)
            let n = max(0, min(40, bytes.count - offset))
            if n > 0 { h.replaceSubrange(0..<n, with: bytes[offset..<(offset + n)]) }
            byteLength = h.u32(at: 0)
            loopStart = h.u32(at: 4)
            loopLength = h.u32(at: 8)
            volume = h[12]
            finetune = Int8(bitPattern: h[13])
            type = h[14]
            panning = h[15]
            relativeNote = Int8(bitPattern: h[16])
            reserved = h[17]
            name = decodeCP437(h[18..<40])
        }
    }

    /// Decode a sample body at `cursor`, advancing past it. Data cut
    /// off by the end of the file is clipped.
    init(header: Header, bytes: [UInt8], cursor: inout Int) {
        let bits16 = header.type & 0x10 != 0
        let remaining = max(0, bytes.count - cursor)
        let declared = Int(min(UInt64(header.byteLength), UInt64(remaining)))
        var pcm: [Int16] = []

        if header.reserved == 0xAD && !bits16 {
            // ModPlug 4-bit ADPCM: a 16-byte delta table, then one
            // nibble per frame (low nibble first).
            let frames = Int(min(header.byteLength, 1 << 28))
            let packed = 16 + (frames + 1) / 2
            let used = min(packed, remaining)
            if used >= 16 {
                let table = bytes[cursor..<(cursor + 16)].map { Int8(bitPattern: $0) }
                var running: Int8 = 0
                pcm.reserveCapacity(min(frames, (used - 16) * 2))
                for i in 0..<min(frames, (used - 16) * 2) {
                    let b = bytes[cursor + 16 + i / 2]
                    let nibble = i % 2 == 0 ? b & 0x0F : b >> 4
                    running = running &+ table[Int(nibble)]
                    pcm.append(Int16(running) << 8)
                }
            }
            cursor += used
        } else if bits16 {
            var running: Int16 = 0
            pcm.reserveCapacity(declared / 2)
            var p = cursor
            for _ in 0..<(declared / 2) {
                let delta = Int16(bitPattern: UInt16(bytes[p]) | UInt16(bytes[p + 1]) << 8)
                running = running &+ delta
                pcm.append(running)
                p += 2
            }
            cursor += declared
        } else {
            var running: Int8 = 0
            pcm.reserveCapacity(declared)
            for i in 0..<declared {
                running = running &+ Int8(bitPattern: bytes[cursor + i])
                pcm.append(Int16(running) << 8)
            }
            cursor += declared
        }

        let divisor: UInt32 = bits16 ? 2 : 1
        let length = pcm.count
        let loopStart = Int(min(header.loopStart / divisor, UInt32(length)))
        let loopEndRaw = UInt64(header.loopStart / divisor) + UInt64(header.loopLength / divisor)
        let loopEnd = Int(min(loopEndRaw, UInt64(length)))
        var mode: LoopMode
        switch header.type & 0x03 {
        case 0: mode = .none
        case 1: mode = .forward
        default: mode = .pingPong
        }
        if loopEnd <= loopStart { mode = .none }

        self.name = header.name
        self.lengthFrames = length
        self.loopBegin = mode == .none ? 0 : loopStart
        self.loopEnd = mode == .none ? 0 : loopEnd
        self.loopMode = mode
        self.bits16 = bits16
        self.volume = min(64, header.volume)
        self.finetune = header.finetune
        self.panning = header.panning
        self.relativeNote = header.relativeNote
        self.pcm = pcm
    }
}

// MARK: - Volume column

/// Decoded XM volume-column byte. The column packs ten different
/// "mini commands" into a single byte; see "Effects in volume column"
/// in `Reference/xm-form.txt`.
public enum XMVolumeCommand: Sendable, Hashable {
    /// No command (0x00-0x0F and the unused 0x51-0x5F).
    case none
    /// `0x10-0x50`: set volume 0...64.
    case setVolume(UInt8)
    /// `0x60-0x6F`: slide volume down by x each tick after the first.
    case slideDown(UInt8)
    /// `0x70-0x7F`: slide volume up by x each tick after the first.
    case slideUp(UInt8)
    /// `0x80-0x8F`: fine volume slide down by x on the first tick.
    case fineSlideDown(UInt8)
    /// `0x90-0x9F`: fine volume slide up by x on the first tick.
    case fineSlideUp(UInt8)
    /// `0xA0-0xAF`: set vibrato speed (shared with effect 4).
    case setVibratoSpeed(UInt8)
    /// `0xB0-0xBF`: vibrato with depth x (shared with effect 4).
    case vibrato(UInt8)
    /// `0xC0-0xCF`: set panning to x * 16.
    case setPanning(UInt8)
    /// `0xD0-0xDF`: slide panning left by x.
    case panSlideLeft(UInt8)
    /// `0xE0-0xEF`: slide panning right by x.
    case panSlideRight(UInt8)
    /// `0xF0-0xFF`: tone portamento with speed x * 16 (shared with
    /// effect 3).
    case tonePorta(UInt8)

    /// Decodes a raw volume-column byte.
    public init(byte: UInt8) {
        let lo = byte & 0x0F
        switch byte >> 4 {
        case 0x1...0x4: self = .setVolume(byte - 0x10)
        case 0x5: self = byte == 0x50 ? .setVolume(64) : .none
        case 0x6: self = .slideDown(lo)
        case 0x7: self = .slideUp(lo)
        case 0x8: self = .fineSlideDown(lo)
        case 0x9: self = .fineSlideUp(lo)
        case 0xA: self = .setVibratoSpeed(lo)
        case 0xB: self = .vibrato(lo)
        case 0xC: self = .setPanning(lo << 4)
        case 0xD: self = .panSlideLeft(lo)
        case 0xE: self = .panSlideRight(lo)
        case 0xF: self = .tonePorta(lo << 4)
        default:  self = .none
        }
    }
}

// MARK: - Internal helpers

extension Array where Element == UInt8 {
    /// Little-endian UInt16 at `offset`. Callers bounds-check first.
    func u16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    /// Little-endian UInt32 at `offset`. Callers bounds-check first.
    func u32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

/// Decode a DOS (code page 437) string, stopping at the first `0x00`
/// or `0x1A`. Never fails: every byte maps to a Unicode scalar.
func decodeCP437(_ bytes: ArraySlice<UInt8>) -> String {
    var scalars = String.UnicodeScalarView()
    for b in bytes {
        if b == 0x00 || b == 0x1A { break }
        if b < 0x80 {
            scalars.append(Unicode.Scalar(b))
        } else if let s = Unicode.Scalar(cp437High[Int(b) - 0x80]) {
            scalars.append(s)
        }
    }
    return String(scalars)
}

/// Unicode code points for CP437 bytes 0x80...0xFF.
private let cp437High: [UInt32] = [
    0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7,
    0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
    0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
    0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
    0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
    0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
    0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
    0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
    0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
    0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
    0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
    0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
    0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
    0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
    0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
    0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0
]
