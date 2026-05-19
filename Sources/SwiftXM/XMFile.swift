/// XMFile.swift
///
/// Parser for FastTracker II (.xm) "Extended Module" files. Follows
/// the canonical spec mirrored under `Reference/xm-form.txt` (the
/// "Complete XM module format specification v0.81" by ccr/TNSP,
/// itself built on Mr.H/Triton's 1994 original).
///
/// XM is materially more elaborate than its S3M predecessor:
///
/// - Variable channel count (2..32) declared in the header
/// - Variable pattern row count (1..256) per pattern
/// - Up to 256 patterns referenced through an order table
/// - Instruments wrap up to 16 PCM samples plus volume + panning
///   envelopes, auto-vibrato, and a fade-out parameter; each note
///   has a per-instrument sample assignment
/// - Sample data is delta-encoded (each byte/word is a difference
///   from the previous) and may be 8-bit or 16-bit signed
/// - Patterns are packed: each row is a sequence of `(flags, ...)`
///   tuples where the MSB of the first byte signals which of
///   note / instrument / volume / effect / param fields follow
///
/// The parser walks every section of the file, decodes delta
/// samples up front (so the mixer never has to), and returns a
/// fully-realized `XMFile` that the mixer can iterate without
/// re-reading the source bytes.

import Foundation

// MARK: - Errors

public enum XMError: Error, LocalizedError, Sendable, Equatable {
    case tooShort
    case badSignature
    case unsupportedVersion(UInt16)
    case truncatedSection(String)

    public var errorDescription: String? {
        switch self {
        case .tooShort:
            return "XM file too short to contain a valid header."
        case .badSignature:
            return "XM signature ('Extended Module: ') not found."
        case .unsupportedVersion(let v):
            return String(format: "Unsupported XM version 0x%04X.", v)
        case .truncatedSection(let s):
            return "XM file truncated mid-\(s)."
        }
    }
}

// MARK: - File

public struct XMFile: Sendable {

    /// Frequency-table selector. Most modern XMs use `.linear`;
    /// the Amiga table exists for round-tripping classic .mod
    /// material.
    public enum FrequencyTable: Sendable, Hashable {
        case amiga
        case linear
    }

    /// Which tracker wrote this file. Detected from `trackerName`
    /// at parse time so the mixer can apply small format quirks
    /// matching the writer's playback semantics.
    public enum WritingTracker: Sendable, Hashable {
        case fastTracker2
        case openMPT
        case milkyTracker
        case digiBooster
        case schism
        case other
    }

    // Header
    public let moduleName: String
    public let trackerName: String
    public let writingTracker: WritingTracker
    public let version: UInt16
    public let songLength: Int
    public let restartPosition: Int
    public let channelCount: Int
    public let patternCount: Int
    public let instrumentCount: Int
    public let frequencyTable: FrequencyTable
    public let defaultTempo: Int   // ticks per row
    public let defaultBPM: Int     // tempo (BPM-ish)

    /// 256-entry pattern order table. Only the first `songLength`
    /// entries are read by the player. Values `>= patternCount`
    /// reference an implicit "empty" pattern (FT2 quirk).
    public let order: [UInt8]

    // Body
    public let patterns: [XMPattern]
    public let instruments: [XMInstrument]

    // MARK: - Init

    public init(data: Data) throws {
        guard data.count >= 64 else { throw XMError.tooShort }

        // ID + module name + tracker name occupy the first 60
        // bytes; the spec mandates the literal "Extended Module: "
        // ASCII string (17 bytes including trailing space).
        let id = data.subdata(in: 0..<17)
        let expected = Array("Extended Module: ".utf8)
        guard Array(id) == expected else {
            throw XMError.badSignature
        }
        self.moduleName  = Self.readString(data, range: 17..<37)
        // data[37] is the 0x1A DOS EOF byte.
        self.trackerName = Self.readString(data, range: 38..<58)
        self.writingTracker = Self.detectWritingTracker(name: self.trackerName)
        self.version     = data.readUInt16LE(at: 58)

        // The "header size" field at offset 60 is calculated from
        // offset 60 (not 0), and the remaining header fields are
        // counted relative to it.
        let headerSize = Int(data.readUInt32LE(at: 60))
        guard data.count >= 60 + headerSize else {
            throw XMError.truncatedSection("header")
        }

        self.songLength      = Int(data.readUInt16LE(at: 64))
        self.restartPosition = Int(data.readUInt16LE(at: 66))
        self.channelCount    = Int(data.readUInt16LE(at: 68))
        self.patternCount    = Int(data.readUInt16LE(at: 70))
        self.instrumentCount = Int(data.readUInt16LE(at: 72))
        let flags            = data.readUInt16LE(at: 74)
        self.frequencyTable  = (flags & 0x01) != 0 ? .linear : .amiga
        self.defaultTempo    = Int(data.readUInt16LE(at: 76))
        self.defaultBPM      = Int(data.readUInt16LE(at: 78))

        var orderBytes = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 where 80 + i < data.count {
            orderBytes[i] = data[80 + i]
        }
        self.order = orderBytes

        // Patterns + instruments live after the variable-length
        // header. We walk them sequentially, advancing a cursor.
        var cursor = 60 + headerSize

        var parsed: [XMPattern] = []
        parsed.reserveCapacity(patternCount)
        for _ in 0..<patternCount {
            let pattern = try XMPattern.parse(
                data: data, at: &cursor, channels: channelCount
            )
            parsed.append(pattern)
        }
        self.patterns = parsed

        var insts: [XMInstrument] = []
        insts.reserveCapacity(instrumentCount)
        for _ in 0..<instrumentCount {
            let ins = try XMInstrument.parse(data: data, at: &cursor)
            insts.append(ins)
        }
        self.instruments = insts
    }

    // MARK: - Helpers

    /// Map the ASCII `trackerName` field to a writer identity. We
    /// match case-insensitive substrings against the well-known
    /// headers shipping XM files in the wild. Unmatched headers
    /// (including FT2 clones with patched signatures) fall through
    /// to `.other` — the mixer treats those as FT2-compatible by
    /// default, which is the conservative choice for unknown files.
    private static func detectWritingTracker(name: String) -> WritingTracker {
        let lower = name.lowercased()
        if lower.contains("openmpt") { return .openMPT }
        if lower.contains("milkytracker") { return .milkyTracker }
        if lower.contains("digibooster") { return .digiBooster }
        if lower.contains("schism") { return .schism }
        if lower.contains("fasttracker") || lower.contains("ft2") {
            return .fastTracker2
        }
        return .other
    }

    private static func readString(_ data: Data, range: Range<Int>) -> String {
        let bytes = data.subdata(in: range)
        var end = bytes.startIndex
        while end < bytes.endIndex && bytes[end] != 0 { end = bytes.index(after: end) }
        return String(data: bytes[bytes.startIndex..<end], encoding: .ascii) ?? ""
    }
}

// MARK: - Pattern

public struct XMPattern: Sendable {

    /// One cell in the channel grid.
    public struct Cell: Sendable, Hashable {
        /// 1..96 = real note, 97 = key-off, 0 = no note.
        public var note: UInt8 = 0
        /// 1..128, 0 = no instrument.
        public var instrument: UInt8 = 0
        /// Volume column byte (see `XMVolumeCommand` for decoding).
        public var volume: UInt8 = 0
        public var effect: UInt8 = 0
        public var param: UInt8 = 0
    }

    public let rowCount: Int
    public let channelCount: Int
    /// `rows[row][channel]`.
    public let rows: [[Cell]]

    static func parse(data: Data, at cursor: inout Int, channels: Int) throws -> XMPattern {
        guard cursor + 9 <= data.count else {
            throw XMError.truncatedSection("pattern header")
        }
        let headerLength = Int(data.readUInt32LE(at: cursor))
        // data[cursor+4] is packing type (always 0).
        let rowCount = Int(data.readUInt16LE(at: cursor + 5))
        let packedSize = Int(data.readUInt16LE(at: cursor + 7))
        cursor += headerLength

        var rows = Array(
            repeating: Array(repeating: Cell(), count: channels),
            count: rowCount
        )

        // Empty patterns have packedSize == 0 and no following data.
        if packedSize > 0 {
            guard cursor + packedSize <= data.count else {
                throw XMError.truncatedSection("pattern data")
            }
            var p = cursor
            let end = cursor + packedSize
            for row in 0..<rowCount {
                for ch in 0..<channels {
                    guard p < end else { break }
                    let b = data[p]
                    p += 1
                    var cell = Cell()
                    if b & 0x80 != 0 {
                        if b & 0x01 != 0, p < end { cell.note       = data[p]; p += 1 }
                        if b & 0x02 != 0, p < end { cell.instrument = data[p]; p += 1 }
                        if b & 0x04 != 0, p < end { cell.volume     = data[p]; p += 1 }
                        if b & 0x08 != 0, p < end { cell.effect     = data[p]; p += 1 }
                        if b & 0x10 != 0, p < end { cell.param      = data[p]; p += 1 }
                    } else {
                        // The compressor packs the most common
                        // case (only a note) as a single byte
                        // with the MSB clear.
                        cell.note = b
                        if p + 3 < end {
                            cell.instrument = data[p];     p += 1
                            cell.volume     = data[p];     p += 1
                            cell.effect     = data[p];     p += 1
                            cell.param      = data[p];     p += 1
                        }
                    }
                    rows[row][ch] = cell
                }
            }
            cursor += packedSize
        }

        return XMPattern(rowCount: rowCount, channelCount: channels, rows: rows)
    }
}

// MARK: - Instrument

public struct XMInstrument: Sendable {

    /// 12-point envelope (volume or panning). XM cap is 12 points
    /// regardless of the on-disk frame range.
    public struct Envelope: Sendable, Hashable {
        public struct Point: Sendable, Hashable {
            public let frame: UInt16
            public let value: UInt16
        }
        public let points: [Point]
        public let sustainPoint: Int
        public let loopStart: Int
        public let loopEnd: Int
        public let enabled: Bool
        public let sustainEnabled: Bool
        public let loopEnabled: Bool
    }

    public struct AutoVibrato: Sendable, Hashable {
        public let type: UInt8   // 0=sine,1=square,2=ramp down,3=ramp up
        public let sweep: UInt8
        public let depth: UInt8
        public let rate: UInt8
    }

    public let name: String
    public let sampleMap: [UInt8]              // 96 entries: note -> sample index
    public let samples: [XMSample]
    public let volumeEnvelope: Envelope
    public let panningEnvelope: Envelope
    public let autoVibrato: AutoVibrato
    public let volumeFadeout: UInt16

    /// Empty sentinel for instrument slots with no samples.
    public static let empty = XMInstrument(
        name: "",
        sampleMap: [UInt8](repeating: 0, count: 96),
        samples: [],
        volumeEnvelope: Envelope(points: [], sustainPoint: 0, loopStart: 0, loopEnd: 0,
                                 enabled: false, sustainEnabled: false, loopEnabled: false),
        panningEnvelope: Envelope(points: [], sustainPoint: 0, loopStart: 0, loopEnd: 0,
                                  enabled: false, sustainEnabled: false, loopEnabled: false),
        autoVibrato: AutoVibrato(type: 0, sweep: 0, depth: 0, rate: 0),
        volumeFadeout: 0
    )

    static func parse(data: Data, at cursor: inout Int) throws -> XMInstrument {
        guard cursor + 29 <= data.count else {
            throw XMError.truncatedSection("instrument header")
        }
        let headerSize = Int(data.readUInt32LE(at: cursor))
        let name = XMFile.readASCII(data: data, range: (cursor + 4)..<(cursor + 26))
        let sampleCount = Int(data.readUInt16LE(at: cursor + 27))

        if sampleCount == 0 {
            // No samples: skip the entire (possibly-padded)
            // instrument header and return an empty.
            cursor += headerSize
            return XMInstrument(
                name: name,
                sampleMap: [UInt8](repeating: 0, count: 96),
                samples: [],
                volumeEnvelope: empty.volumeEnvelope,
                panningEnvelope: empty.panningEnvelope,
                autoVibrato: AutoVibrato(type: 0, sweep: 0, depth: 0, rate: 0),
                volumeFadeout: 0
            )
        }

        // Extended instrument fields begin at +29.
        let ext = cursor + 29
        guard ext + 214 <= data.count else {
            throw XMError.truncatedSection("instrument extended header")
        }
        let sampleHeaderSize = Int(data.readUInt32LE(at: ext))

        var sampleMap = [UInt8](repeating: 0, count: 96)
        for i in 0..<96 { sampleMap[i] = data[ext + 4 + i] }

        let volPoints = (0..<12).map { i -> Envelope.Point in
            let base = ext + 100 + i * 4
            return Envelope.Point(
                frame: data.readUInt16LE(at: base),
                value: data.readUInt16LE(at: base + 2)
            )
        }
        let panPoints = (0..<12).map { i -> Envelope.Point in
            let base = ext + 148 + i * 4
            return Envelope.Point(
                frame: data.readUInt16LE(at: base),
                value: data.readUInt16LE(at: base + 2)
            )
        }

        let volPointCount    = Int(data[ext + 196])
        let panPointCount    = Int(data[ext + 197])
        let volSustainPoint  = Int(data[ext + 198])
        let volLoopStart     = Int(data[ext + 199])
        let volLoopEnd       = Int(data[ext + 200])
        let panSustainPoint  = Int(data[ext + 201])
        let panLoopStart     = Int(data[ext + 202])
        let panLoopEnd       = Int(data[ext + 203])
        let volType          = data[ext + 204]
        let panType          = data[ext + 205]
        let vibType          = data[ext + 206]
        let vibSweep         = data[ext + 207]
        let vibDepth         = data[ext + 208]
        let vibRate          = data[ext + 209]
        let volumeFadeout    = data.readUInt16LE(at: ext + 210)

        let volEnv = Envelope(
            points: Array(volPoints.prefix(max(0, min(12, volPointCount)))),
            sustainPoint: volSustainPoint,
            loopStart: volLoopStart, loopEnd: volLoopEnd,
            enabled: (volType & 0x01) != 0,
            sustainEnabled: (volType & 0x02) != 0,
            loopEnabled: (volType & 0x04) != 0
        )
        let panEnv = Envelope(
            points: Array(panPoints.prefix(max(0, min(12, panPointCount)))),
            sustainPoint: panSustainPoint,
            loopStart: panLoopStart, loopEnd: panLoopEnd,
            enabled: (panType & 0x01) != 0,
            sustainEnabled: (panType & 0x02) != 0,
            loopEnabled: (panType & 0x04) != 0
        )
        let vibrato = AutoVibrato(type: vibType, sweep: vibSweep,
                                  depth: vibDepth, rate: vibRate)

        // Skip past the instrument header. The spec is explicit
        // that headerSize may be larger than the documented field
        // sequence so we always trust the on-disk size.
        cursor += headerSize

        // Sample headers, then sample data — sized by
        // `sampleHeaderSize` so unknown padding is tolerated.
        var samples: [XMSample] = []
        samples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            guard cursor + sampleHeaderSize <= data.count else {
                throw XMError.truncatedSection("sample header")
            }
            samples.append(try XMSample.parseHeader(
                data: data, at: cursor, headerSize: sampleHeaderSize
            ))
            cursor += sampleHeaderSize
        }
        // Now the sample bodies follow, all in order.
        for i in samples.indices {
            try samples[i].loadBody(data: data, cursor: &cursor)
        }

        return XMInstrument(
            name: name, sampleMap: sampleMap, samples: samples,
            volumeEnvelope: volEnv, panningEnvelope: panEnv,
            autoVibrato: vibrato, volumeFadeout: volumeFadeout
        )
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

public struct XMSample: Sendable {

    public enum LoopMode: UInt8, Sendable {
        case none = 0
        case forward = 1
        case pingPong = 2
    }

    public var name: String
    public var lengthFrames: Int       // number of samples (post-decode)
    public var loopBegin: Int
    public var loopEnd: Int
    public var loopMode: LoopMode
    public var bits16: Bool
    public var volume: UInt8           // 0..64
    public var finetune: Int8          // -128..+127
    public var panning: UInt8          // 0..255
    public var relativeNote: Int8      // -96..+95
    /// Decoded, delta-undone sample data, normalized to Int16.
    public var pcm: [Int16]

    // On-disk-only fields used between header parse and body load.
    private var diskByteLength: Int = 0
    private var diskLoopStartBytes: Int = 0
    private var diskLoopLengthBytes: Int = 0

    static func parseHeader(data: Data, at offset: Int, headerSize: Int) throws -> XMSample {
        guard offset + min(headerSize, 40) <= data.count else {
            throw XMError.truncatedSection("sample header")
        }
        let byteLength      = Int(data.readUInt32LE(at: offset))
        let loopStartBytes  = Int(data.readUInt32LE(at: offset + 4))
        let loopLengthBytes = Int(data.readUInt32LE(at: offset + 8))
        let volume          = data[offset + 12]
        let finetune        = Int8(bitPattern: data[offset + 13])
        let typeByte        = data[offset + 14]
        let panning         = data[offset + 15]
        let relative        = Int8(bitPattern: data[offset + 16])
        let name            = XMFile.readASCII(data: data, range: (offset + 18)..<(offset + 40))

        let bits16 = (typeByte & 0x10) != 0
        let loopRaw = typeByte & 0x03
        let loopMode = LoopMode(rawValue: loopRaw == 3 ? 2 : loopRaw) ?? .none

        var s = XMSample(
            name: name,
            lengthFrames: 0, loopBegin: 0, loopEnd: 0,
            loopMode: loopMode, bits16: bits16,
            volume: volume, finetune: finetune,
            panning: panning, relativeNote: relative,
            pcm: []
        )
        s.diskByteLength = byteLength
        s.diskLoopStartBytes = loopStartBytes
        s.diskLoopLengthBytes = loopLengthBytes
        return s
    }

    mutating func loadBody(data: Data, cursor: inout Int) throws {
        let len = diskByteLength
        guard cursor + len <= data.count else {
            throw XMError.truncatedSection("sample body")
        }
        if len == 0 {
            pcm = []
            return
        }
        // XM stores sample data as deltas. Decode in-place to
        // absolute values, then normalize to Int16.
        if bits16 {
            let frames = len / 2
            var out = [Int16](repeating: 0, count: frames)
            var running: Int32 = 0
            var p = cursor
            for i in 0..<frames {
                let lo = UInt16(data[p])
                let hi = UInt16(data[p + 1])
                let delta = Int16(bitPattern: lo | (hi << 8))
                running = Int32(Int16(truncatingIfNeeded: running &+ Int32(delta)))
                out[i] = Int16(truncatingIfNeeded: running)
                p += 2
            }
            pcm = out
            lengthFrames = frames
            loopBegin = diskLoopStartBytes / 2
            loopEnd   = (diskLoopStartBytes + diskLoopLengthBytes) / 2
        } else {
            let frames = len
            var out = [Int16](repeating: 0, count: frames)
            var running: Int8 = 0
            for i in 0..<frames {
                let delta = Int8(bitPattern: data[cursor + i])
                running = Int8(truncatingIfNeeded: Int(running) + Int(delta))
                // 8-bit -> 16-bit by left-shifting 8.
                out[i] = Int16(running) << 8
            }
            pcm = out
            lengthFrames = frames
            loopBegin = diskLoopStartBytes
            loopEnd   = diskLoopStartBytes + diskLoopLengthBytes
        }
        // Clamp loop bounds to the actual sample length.
        loopBegin = max(0, min(loopBegin, lengthFrames))
        loopEnd   = max(loopBegin, min(loopEnd, lengthFrames))
        cursor += len
    }
}

// MARK: - Volume column

/// Decoded XM volume-column byte. The column packs ten different
/// "mini commands" into a single byte; see Section "Effects in
/// volume column" of `Reference/xm-form.txt`.
public enum XMVolumeCommand: Sendable, Hashable {
    case none
    case setVolume(UInt8)        // 0x10..0x50  -> 0..64
    case slideDown(UInt8)        // 0x60..0x6F
    case slideUp(UInt8)          // 0x70..0x7F
    case fineSlideDown(UInt8)    // 0x80..0x8F
    case fineSlideUp(UInt8)      // 0x90..0x9F
    case setVibratoSpeed(UInt8)  // 0xA0..0xAF
    case vibrato(UInt8)          // 0xB0..0xBF (depth)
    case setPanning(UInt8)       // 0xC0..0xCF -> 0..240
    case panSlideLeft(UInt8)     // 0xD0..0xDF
    case panSlideRight(UInt8)    // 0xE0..0xEF
    case tonePorta(UInt8)        // 0xF0..0xFF -> rate

    public init(byte: UInt8) {
        let hi = (byte >> 4) & 0x0F
        let lo = byte & 0x0F
        switch hi {
        case 0x0: self = .none
        case 0x1, 0x2, 0x3, 0x4, 0x5: self = .setVolume(byte - 0x10)
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

extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
    func readUInt32LE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}

extension XMFile {
    static func readASCII(data: Data, range: Range<Int>) -> String {
        let safe = max(0, min(range.lowerBound, data.count))
                   ..< max(0, min(range.upperBound, data.count))
        let bytes = data.subdata(in: safe)
        var end = bytes.startIndex
        while end < bytes.endIndex {
            let b = bytes[end]
            if b == 0 || b == 0x1A { break }
            end = bytes.index(after: end)
        }
        return String(data: bytes[bytes.startIndex..<end], encoding: .ascii) ?? ""
    }
}
