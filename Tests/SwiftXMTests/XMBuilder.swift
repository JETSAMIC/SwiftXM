import Foundation
import SwiftXM

/// Builds XM modules byte-by-byte from the layout in
/// Reference/xm-form.txt so tests can target exact spec fields.
struct XMBuilder {

    struct Sample {
        /// Absolute sample values; delta-encoded on write.
        var values: [Int] = Array(repeating: 64, count: 64)
        var bits16 = false
        var loopStart = 0          // frames
        var loopLength = 0         // frames
        var loopType: UInt8 = 0    // 0 none, 1 forward, 2 ping-pong
        var volume: UInt8 = 64
        var finetune: Int8 = 0
        var panning: UInt8 = 128
        var relativeNote: Int8 = 0
        var reserved: UInt8 = 0
        var name = ""
        /// Raw body override (written verbatim instead of `values`).
        var rawBody: [UInt8]?
        /// Stored length override in bytes.
        var storedLength: UInt32?

        static func looped(_ count: Int = 64) -> Sample {
            var s = Sample()
            s.values = (0..<count).map { $0 % 16 < 8 ? 100 : -100 }
            s.loopType = 1
            s.loopLength = count
            return s
        }
    }

    struct Envelope {
        var points: [(UInt16, UInt16)] = []
        var sustain: UInt8 = 0
        var loopStart: UInt8 = 0
        var loopEnd: UInt8 = 0
        var flags: UInt8 = 0
    }

    struct Instrument {
        var name = ""
        var samples: [Sample] = [.looped()]
        var sampleMap: [UInt8] = Array(repeating: 0, count: 96)
        var volumeEnvelope = Envelope()
        var panningEnvelope = Envelope()
        var vibratoType: UInt8 = 0
        var vibratoSweep: UInt8 = 0
        var vibratoDepth: UInt8 = 0
        var vibratoRate: UInt8 = 0
        var fadeout: UInt16 = 0
        /// Instrument header size field; nil = 263 (FT2).
        var headerSize: UInt32?
        /// Sample header size field; nil = 40.
        var sampleHeaderSize: UInt32?
    }

    struct Entry {
        var row: Int
        var channel: Int
        var note: UInt8 = 0
        var instrument: UInt8 = 0
        var volume: UInt8 = 0
        var effect: UInt8 = 0
        var param: UInt8 = 0
    }

    struct Pattern {
        var rows = 64
        var entries: [Entry] = []
        var headerLength: UInt32?
    }

    var name = "TEST"
    var tracker = "FastTracker v2.00"
    var version: UInt16 = 0x0104
    var channels = 4
    var linear = true
    var speed = 6
    var bpm = 125
    var order: [UInt8] = [0]
    var songLength: Int?
    var restart = 0
    var patterns: [Pattern] = [Pattern()]
    var instruments: [Instrument] = []
    /// Header size field; nil = 20 + 256.
    var headerSize: UInt32?

    /// Pattern note byte: octave 0... and semitone 0...11 (C-0 = 1).
    static func note(_ octave: Int, _ semitone: Int) -> UInt8 {
        UInt8(octave * 12 + semitone + 1)
    }

    static func packPattern(_ pattern: Pattern, channels: Int) -> [UInt8] {
        var out: [UInt8] = []
        for row in 0..<pattern.rows {
            for ch in 0..<channels {
                guard let e = pattern.entries.last(where: { $0.row == row && $0.channel == ch }) else {
                    out.append(0x80)
                    continue
                }
                var flags: UInt8 = 0x80
                if e.note != 0 { flags |= 0x01 }
                if e.instrument != 0 { flags |= 0x02 }
                if e.volume != 0 { flags |= 0x04 }
                if e.effect != 0 { flags |= 0x08 }
                if e.param != 0 { flags |= 0x10 }
                out.append(flags)
                if e.note != 0 { out.append(e.note) }
                if e.instrument != 0 { out.append(e.instrument) }
                if e.volume != 0 { out.append(e.volume) }
                if e.effect != 0 { out.append(e.effect) }
                if e.param != 0 { out.append(e.param) }
            }
        }
        return out
    }

    func build() -> Data {
        var d: [UInt8] = Array("Extended Module: ".utf8)
        d += padded(name, 20)
        d.append(0x1A)
        d += padded(tracker, 20)
        d += le16(version)
        let hs = headerSize ?? 276
        d += le32(hs)
        d += le16(UInt16(songLength ?? order.count))
        d += le16(UInt16(restart))
        d += le16(UInt16(channels))
        d += le16(UInt16(patterns.count))
        d += le16(UInt16(instruments.count))
        d += le16(linear ? 1 : 0)
        d += le16(UInt16(speed))
        d += le16(UInt16(bpm))
        var table = order + Array(repeating: 0, count: max(0, 256 - order.count))
        table = Array(table.prefix(256))
        let tableBytes = Int(hs) - 20
        if tableBytes <= 256 {
            d += table.prefix(max(0, tableBytes))
        } else {
            d += table + Array(repeating: 0xEE, count: tableBytes - 256)
        }

        if version >= 0x0104 {
            d += patternBytes()
            for ins in instruments {
                d += instrumentHeader(ins)
                d += ins.samples.flatMap(sampleBody)
            }
        } else {
            for ins in instruments { d += instrumentHeader(ins) }
            d += patternBytes()
            for ins in instruments { d += ins.samples.flatMap(sampleBody) }
        }
        return Data(d)
    }

    private func patternBytes() -> [UInt8] {
        var d: [UInt8] = []
        for p in patterns {
            let packed = Self.packPattern(p, channels: channels)
            let empty = packed.allSatisfy { $0 == 0x80 }
            let body = empty ? [] : packed
            if version == 0x0102 {
                d += le32(p.headerLength ?? 8)
                d.append(0)
                d.append(UInt8((p.rows - 1) & 0xFF))
                d += le16(UInt16(body.count))
                d += Array(repeating: 0, count: Int(p.headerLength ?? 8) - 8)
            } else {
                d += le32(p.headerLength ?? 9)
                d.append(0)
                d += le16(UInt16(p.rows))
                d += le16(UInt16(body.count))
                d += Array(repeating: 0, count: max(0, Int(p.headerLength ?? 9) - 9))
            }
            d += body
        }
        return d
    }

    private func instrumentHeader(_ ins: Instrument) -> [UInt8] {
        let size = Int(ins.headerSize ?? (ins.samples.isEmpty ? 29 : 263))
        var h: [UInt8] = le32(UInt32(size)) + padded(ins.name, 22) + [0] + le16(UInt16(ins.samples.count))
        if !ins.samples.isEmpty {
            h += le32(ins.sampleHeaderSize ?? 40)
            h += ins.sampleMap
            for env in [ins.volumeEnvelope, ins.panningEnvelope] {
                for i in 0..<12 {
                    let p = i < env.points.count ? env.points[i] : (0, 0)
                    h += le16(p.0) + le16(p.1)
                }
            }
            h += [UInt8(ins.volumeEnvelope.points.count), UInt8(ins.panningEnvelope.points.count),
                  ins.volumeEnvelope.sustain, ins.volumeEnvelope.loopStart, ins.volumeEnvelope.loopEnd,
                  ins.panningEnvelope.sustain, ins.panningEnvelope.loopStart, ins.panningEnvelope.loopEnd,
                  ins.volumeEnvelope.flags, ins.panningEnvelope.flags,
                  ins.vibratoType, ins.vibratoSweep, ins.vibratoDepth, ins.vibratoRate]
            h += le16(ins.fadeout) + [0, 0]
        }
        // Pad or cut to the declared size (FT2 readers consume at least
        // the 29 fixed bytes even when the field says less).
        let written = max(29, size)
        if h.count < written { h += Array(repeating: 0, count: written - h.count) } else { h = Array(h.prefix(written)) }
        for s in ins.samples {
            var sh: [UInt8] = []
            let width = s.bits16 ? 2 : 1
            let length = s.storedLength ?? UInt32(s.rawBody?.count ?? s.values.count * width)
            sh += le32(length)
            sh += le32(UInt32(s.loopStart * width))
            sh += le32(UInt32(s.loopLength * width))
            sh += [s.volume, UInt8(bitPattern: s.finetune), s.loopType | (s.bits16 ? 0x10 : 0),
                   s.panning, UInt8(bitPattern: s.relativeNote), s.reserved]
            sh += padded(s.name, 22)
            let shs = Int(ins.sampleHeaderSize ?? 40)
            if shs > 40 { sh += Array(repeating: 0, count: shs - 40) }
            h += sh
        }
        return h
    }

    private func sampleBody(_ s: Sample) -> [UInt8] {
        if let raw = s.rawBody { return raw }
        var out: [UInt8] = []
        var previous = 0
        for v in s.values {
            let delta = v - previous
            previous = v
            if s.bits16 {
                let d16 = UInt16(truncatingIfNeeded: delta)
                out += [UInt8(d16 & 0xFF), UInt8(d16 >> 8)]
            } else {
                out.append(UInt8(truncatingIfNeeded: delta))
            }
        }
        return out
    }

    private func padded(_ s: String, _ n: Int) -> [UInt8] {
        let b = Array(s.utf8.prefix(n))
        return b + Array(repeating: 0, count: n - b.count)
    }
}

func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

/// Render up to `limit` frames, returning interleaved samples and the
/// number of frames written.
func renderAll(_ mixer: XMMixer, limit: Int, chunk: Int = 1024) -> (samples: [Float], frames: Int) {
    var out: [Float] = []
    var total = 0
    var buffer = [Float](repeating: 0, count: chunk * 2)
    while total < limit && !mixer.finished {
        let n = buffer.withUnsafeMutableBufferPointer {
            mixer.render(into: $0.baseAddress!, frames: min(chunk, limit - total))
        }
        out += buffer.prefix(n * 2)
        total += n
        if n == 0 { break }
    }
    return (out, total)
}

/// Advance a mixer by exactly `frames` frames.
func advance(_ mixer: XMMixer, frames: Int) {
    var buffer = [Float](repeating: 0, count: max(1, frames) * 2)
    buffer.withUnsafeMutableBufferPointer {
        _ = mixer.render(into: $0.baseAddress!, frames: frames)
    }
}

/// Deterministic PRNG for fuzzing (SplitMix64).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
