# SwiftXM

A pure-Swift, dependency-free decoder and software mixer for FastTracker II (`.xm`) Extended Modules.

`XMFile` parses and validates the binary format; `XMMixer` renders it to interleaved stereo `Float32` PCM in a caller-provided buffer, so it drops straight into `AVAudioSourceNode` or any other audio host. Sibling package: [SwiftS3M](https://github.com/JETSAMIC/SwiftS3M).

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [AVAudioEngine bridge](#avaudioengine-bridge)
- [Spec coverage](#spec-coverage)
- [Limitations](#limitations)
- [Robustness](#robustness)
- [A short history of FastTracker II](#a-short-history-of-fasttracker-ii)
- [The XM file format](#the-xm-file-format)
- [References and credits](#references-and-credits)
- [License](#license)

## Requirements

- Swift 6.0+ / Xcode 16+ (verified with Xcode 27.3 and the 27.3 SDKs)
- iOS 17+, iPadOS 17+, macOS 14+, tvOS 17+, watchOS 10+, visionOS 1+
- Foundation only, no third-party dependencies

## Installation

Swift Package Manager. Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/JETSAMIC/SwiftXM.git", from: "0.1.0")
]
```

and depend on the product from your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "SwiftXM", package: "SwiftXM")
    ]
)
```

## Quick start

```swift
import Foundation
import SwiftXM

func renderFirstSecond(of url: URL) throws -> [Float] {
    let file = try XMFile(data: Data(contentsOf: url))
    print(file.moduleName, file.channelCount, file.instruments.count)

    let mixer = try XMMixer(file: file, sampleRate: 44_100)
    var buffer = [Float](repeating: 0, count: 44_100 * 2)   // interleaved L R
    let frames = buffer.withUnsafeMutableBufferPointer {
        mixer.render(into: $0.baseAddress!, frames: 44_100)
    }
    if mixer.finished {
        // The song ended (or looped back) inside this buffer.
    }
    return Array(buffer.prefix(frames * 2))
}
```

(This snippet is compiled and run by the test suite.)

`render(into:frames:)` returns the number of frames written. A short return means the song ended mid-buffer; the tail is zero-filled and `finished` is `true`.

Full API documentation is in the DocC catalog (`Sources/SwiftXM/SwiftXM.docc`), built by Swift Package Index.

## AVAudioEngine bridge

```swift
import AVFoundation
import SwiftXM

final class XMPlayer {
    private let engine: AVAudioEngine
    private let sourceNode: AVAudioSourceNode

    init(file: XMFile) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let sampleRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        let mixer = try XMMixer(file: file, sampleRate: sampleRate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 2, interleaved: true)!
        sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let raw = buffers[0].mData else { return noErr }
            mixer.render(into: raw.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    func start() throws { try engine.start() }
    func stop() { engine.stop() }
}
```

(Also compile-checked by the test suite.) `XMMixer` is `@unchecked Sendable` so the render block can capture it, but it has no internal locking: use it from one thread at a time.

## Spec coverage

The authoritative spec is [`Reference/XM-Format.md`](Reference/XM-Format.md): byte layouts of all three format versions, the frequency, envelope and effect algorithms, FT2's replayer quirks (each attributed to the OpenMPT test case that documents it), robustness guidance and errata for the archived [`Reference/xm-form.txt`](Reference/xm-form.txt). This table mirrors its implementation-status section.

| Feature | Status |
|---|---|
| Header, header-size field (honoured, not assumed 276), short order table | Supported |
| Versions 0x0104, 0x0103, 0x0102 (old layout, 1-byte row count) | Supported; others rejected |
| Patterns: header length honoured, packed and unpacked cells, empty patterns, 0 rows = 64, up to 1024 rows | Supported |
| Instrument header size quirks (larger, smaller, < 29), sample-header size 0 | Supported |
| 8-bit / 16-bit delta-encoded samples, ModPlug ADPCM | Supported |
| OpenMPT stereo samples | Partial (mixed down to mono) |
| OpenMPT trailing chunks (`text`, `MIDI`, `PNAM`, `CNAM`, `XTPM`, `STPM`, plugins) | Unsupported (ignored) |
| Forward / ping-pong loops, zero-length loops | Supported |
| Linear and Amiga frequency tables, finetune precision (top five bits) | Supported |
| Volume / panning envelopes (12 points, sustain, loop, panning-sustain rule) | Supported |
| Fade-out (32768 base, also without a volume envelope, pick-up by portamento) | Supported |
| Auto-vibrato (4 waveforms, sweep, key-off during sweep) | Supported |
| Note / instrument rules (Switch, Play, OldVol from the playing sample, Cut, note range) | Supported (`SampleChange.xm` edge case not reproduced) |
| Key-off with and without envelope, key-off + instrument, `K00` | Supported |
| Volume column: set, slides, fine slides, vibrato speed/depth, pan (incl. left-slide-0 quirk), pan slides, tone porta | Supported |
| 0 arpeggio (down-counting table incl. speeds above 16, semitone rounding, B-7 clamp) | Supported |
| 1/2 porta, 3 tone porta (shared with Mx, FT2 direction memory), 4 vibrato, 5, 6, 7 tremolo | Supported |
| Pitch left detuned after a volume-column vibrato (`VibratoCombinations.xm`) | Unsupported (pitch restored each row, as OpenMPT) |
| 8 pan, 9 offset (memory only with a note, ignored with porta), A volume slide, B jump, C volume, D break | Supported |
| E1/E2 fine porta, E3 glissando, E4/E7 waveforms, E5 finetune | Supported |
| E6 pattern loop (per channel, incl. FT2 next-pattern quirk) | Supported |
| E9 retrigger (incl. E90), EA/EB fine volume, EC cut, ED delay (FT2 quirks), EE pattern delay (rightmost wins) | Supported |
| F speed / BPM | Supported; F00 ignored instead of stalling the row |
| G / H global volume | Supported (applies from the same tick for every channel) |
| K key off (tick), L envelope position (FT2 panning bug), P pan slide | Supported |
| R multi-retrig (incl. tick 0), T tremor, X1/X2 extra-fine porta | Supported (`TremorRecover.xm` volume case not reproduced) |
| E0 / E8 / EF, OpenMPT X5/X6/X9/XA, Y, Z, `\`, SoundTracker Q/Z | Ignored |
| Square-root pan law | Supported |
| FT2 volume ramping and exact mixer interpolation | Unsupported (linear interpolation) |
| Restart position / song looping | Parsed; playback stops when the song ends or loops back to a played row |

## Limitations

- Mixing is linear-interpolated without FT2's volume ramping.
- The Amiga table is interpolated from FT2's 96-entry base table rather than read from FT2's expanded lookup table, so pitches can differ by a fraction of a period unit; FT2's period wrap-around at extremely low frequencies is not reproduced.
- `F00` is ignored (FT2 stalls on that row for 65536 ticks).
- Output gain is divided by the channel count, so busy modules are quiet rather than clipped.
- Playback stops instead of looping; recreate the mixer to loop.

## Robustness

All sizes and offsets in the file are treated as untrusted. Truncated or inconsistent headers, patterns and instrument headers throw `XMError`; sample bodies cut off by the end of the file are clipped. Pattern cells are stored sparsely, so a file declaring thousands of huge empty patterns costs almost nothing. Rendering always terminates: songs that jump back stop, and a hard row budget bounds pathological `E6x` loops. The test suite truncates a fixture at every byte offset and runs a seeded mutation fuzz.

## A short history of FastTracker II

[FastTracker II](https://en.wikipedia.org/wiki/FastTracker_2) was released in 1994 by Triton (Magnus "Vogue" Hogdahl and Fredrik "Mr.H" Huss), a Swedish demoscene group. The XM file format premiered with version 2 of the tracker and rapidly became one of the dominant formats on the PC demoscene through the mid-to-late '90s. FT2 ran on DOS, used a 256-color VGA EGA-style UI with two-deck pattern editing, and supported up to 32 channels of PCM at a time. Its replay model was strongly influenced by Karsten Obarski's `Ultimate Soundtracker` lineage (Amiga `.mod` from 1987) and ran alongside the other "big three" PC trackers of the era: Future Crew's `Scream Tracker 3` (`.s3m`, 1994) and Jeffrey Lim's `Impulse Tracker` (`.it`, 1995).

The XM format brought several novel features over the older Amiga/PC `.mod` and `.s3m` formats: multi-sample instruments with note-to-sample mapping, volume and panning envelopes with sustain and loop points, instrument auto-vibrato, key-off with a fade-out parameter, a "volume column" alongside the effect column for compact volume commands, ping-pong loops, both 8-bit and 16-bit samples (delta-encoded for compression), and a choice between linear and Amiga frequency tables. The 60-byte ASCII header begins with the literal string `"Extended Module: "`, and the rest of the file is laid out as a sequence of variable-length sections addressed by the header.

The authoritative reference is [`Reference/XM-Format.md`](Reference/XM-Format.md), written for this package. It builds on the "Complete XM module format specification v0.81" by Matti "ccr" Hamalainen of TNSP (2000-2001), itself based on Mr.H's original 1994 document, which is archived verbatim as [`Reference/xm-form.txt`](Reference/xm-form.txt); its errors are listed in the errata of `XM-Format.md`. Where the old documents are silent or wrong, the spec follows FT2's actual replayer behaviour as documented by OpenMPT's FT2 test cases.

If you watched a demo at [Assembly](https://en.wikipedia.org/wiki/Assembly_(demoparty)) or any of the major European demoparties between 1995 and 1999, there's a strong chance the soundtrack was an XM.

## The XM file format

XM is a binary container: a 60-byte fixed block (`"Extended Module: "`, module name, `0x1A`, tracker name, version), then a header whose size is stored at offset 60 and measured from there (song length, restart position, channels, patterns, instruments, flags, speed, BPM, order table), then the patterns, then the instruments with their sample headers and delta-encoded sample data. Versions before 0x0104 store the instruments first, then the patterns, then all sample data.

Pattern cells hold note (1 = C-0 ... 96 = B-7, 97 = key off), instrument, volume-column byte, effect and parameter. A leading byte with bit 7 set says which of those five follow; otherwise it is the note and the other four follow.

Linear pitch: `period = 7680 - note*64 - finetune/2`, `Hz = 8363 * 2^((4608 - period) / 768)` with `note` 0-based (C-0 = 0) after adding the sample's relative note. Amiga pitch uses FT2's 96-entry period table interpolated by finetune and `Hz = 8363 * 1712 / period`. The tick rate is `bpm * 2 / 5` Hz.

## References and credits

- [`Reference/XM-Format.md`](Reference/XM-Format.md), SwiftXM's comprehensive XM specification, written from the documents below and black-box observation.
- "The Complete XM module format specification v0.81" by Matti "ccr" Hamalainen / TNSP, based on Mr.H / Triton's original (archived verbatim in [`Reference/xm-form.txt`](Reference/xm-form.txt)).
- The OpenMPT wiki's XM test-case descriptions and effect reference, for FT2's replayer quirks.
- ft2-clone by Olav "8bitbubsy" Sorensen, as a black-box reference for FT2 output.

## License

MIT. See [`LICENSE`](LICENSE).
