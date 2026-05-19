# SwiftXM

A pure-Swift decoder and software mixer for FastTracker II (`.xm`) Extended Module files. No external dependencies. Foundation only. The mixer renders interleaved stereo `Float32` PCM into a caller-provided buffer, so it drops straight into `AVAudioEngine`, `AVAudioSourceNode`, or any other audio host you can hand a pointer to.

```swift
let file = try XMFile(data: data)
let mixer = XMMixer(file: file, sampleRate: 44_100)
```

That's the whole API surface, roughly.

---

## Contents

- [What this is](#what-this-is)
- [A short history of FastTracker II](#a-short-history-of-fasttracker-ii)
- [The XM file format](#the-xm-file-format)
- [Timing model](#timing-model)
- [Effect coverage](#effect-coverage)
- [Installation](#installation)
- [Quick start](#quick-start)
- [AVAudioEngine bridge](#avaudioengine-bridge)
- [Status and roadmap](#status-and-roadmap)
- [Requirements](#requirements)
- [License](#license)

---

## What this is

`SwiftXM` is a from-scratch reader for the FastTracker II module format plus a software mixer that turns the parsed data into PCM. It targets modern Swift (6.0, strict concurrency on) and ships as a single library product. There is no UI, no playback engine, no file-format autodetection. Just `XMFile` (the parser) and `XMMixer` (the renderer). Hook the mixer up to whatever audio host you like.

The design constraint is "give me frames when I ask, don't allocate on the audio thread, don't pretend to be a player." Everything that isn't strictly necessary to produce samples lives outside the library. The same shape as the sibling [SwiftS3M](https://github.com/prestige-exe/SwiftS3M) package for `.s3m` files.

## A short history of FastTracker II

[FastTracker II](https://en.wikipedia.org/wiki/FastTracker_2) was released in 1994 by Triton (Magnus "Vogue" Hogdahl and Fredrik "Mr.H" Huss), a Swedish demoscene group. The XM file format premiered with version 2 of the tracker and rapidly became one of the dominant formats on the PC demoscene through the mid-to-late '90s. FT2 ran on DOS, used a 256-color VGA EGA-style UI with two-deck pattern editing, and supported up to 32 channels of PCM at a time. Its replay model was strongly influenced by Karsten Obarski's `Ultimate Soundtracker` lineage (Amiga `.mod` from 1987) and ran alongside the other "big three" PC trackers of the era: Future Crew's `Scream Tracker 3` (`.s3m`, 1994) and Jeffrey Lim's `Impulse Tracker` (`.it`, 1995).

The XM format brought several novel features over the older Amiga/PC `.mod` and `.s3m` formats: multi-sample instruments with note-to-sample mapping, volume and panning envelopes with sustain and loop points, instrument auto-vibrato, key-off with a fade-out parameter, a "volume column" alongside the effect column for compact volume commands, ping-pong loops, both 8-bit and 16-bit samples (delta-encoded for compression), and a choice between linear and Amiga frequency tables. The 60-byte ASCII header begins with the literal string `"Extended Module: "`, and the rest of the file is laid out as a sequence of variable-length sections addressed by the header.

The canonical reference is [`Reference/xm-form.txt`](Reference/xm-form.txt), the "Complete XM module format specification v0.81" by Matti "ccr" Hamalainen of TNSP (2000-2001), itself built on Mr.H's original 1994 document. This library follows it.

If you watched a demo at [Assembly](https://en.wikipedia.org/wiki/Assembly_(demoparty)) or any of the major European demoparties between 1995 and 1999, there's a strong chance the soundtrack was an XM.

## The XM file format

XM is a binary container with a fixed ASCII signature, variable-length header, and a sequence of pattern + instrument + sample sections walked through size fields.

### Header

| Offset | Length | Field |
|-------:|-------:|-------|
| `0x00` | 17 | `"Extended Module: "` (literal, includes trailing space) |
| `0x11` | 20 | Module name, null-padded |
| `0x25` | 1  | `0x1A` DOS EOF |
| `0x26` | 20 | Tracker name |
| `0x3A` | 2  | Version (current is `0x0104`) |
| `0x3C` | 4  | Header size (measured FROM this offset, not the file start) |
| `+4`   | 2  | Song length (entries in the pattern order table) |
| `+6`   | 2  | Restart position |
| `+8`   | 2  | Channel count (2..32, always even) |
| `+10`  | 2  | Pattern count (max 256) |
| `+12`  | 2  | Instrument count (max 128) |
| `+14`  | 2  | Flags. Bit 0: 0 = Amiga frequency table, 1 = Linear |
| `+16`  | 2  | Default tempo (ticks per row) |
| `+18`  | 2  | Default BPM |
| `+20`  | 256 | Pattern order table |

The remainder of the file is a sequence of:

1. **Patterns** (one block per pattern, in order): 9+-byte header (length, packing type, row count, packed data size) followed by the packed cell data.
2. **Instruments** (one block per instrument, in order): variable-length header, an optional extended header (when the instrument has > 0 samples) holding the sample map, envelopes, auto-vibrato, and fade-out, then per-sample headers, then per-sample data.

### Packed pattern data

Each cell carries five fields: note (1..96 = real note, 97 = key-off, 0 = no note), instrument (1..128, 0 = no instrument), volume column byte, effect command byte, effect parameter byte. The packer flags the most common cases via the MSB of the leading byte:

- Bit 7 set: the remaining low bits indicate which subset of `(note, instrument, volume, effect, param)` follow.
- Bit 7 clear: the byte itself is the note, and all five fields follow.

### Sample data

Samples are stored signed (8-bit or 16-bit) with **delta encoding**. Each on-disk value is a difference from the previous decoded sample; the parser undoes the delta up front and normalizes to `Int16`. Loops come in three flavors: none, forward, ping-pong (bouncing).

For the exhaustive byte-level layout, see [`Reference/xm-form.txt`](Reference/xm-form.txt).

## Timing model

XM uses the same speed/tempo split as S3M:

- **`speed`**: ticks per row, set via `Fxx` for `xx < 0x20`. Default 6.
- **`tempo`** (FT2 calls this "BPM"): tick rate, set via `Fxx` for `xx >= 0x20`. Default 125.

The conversion is:

```
tickRateHz     = tempo * 2 / 5
samplesPerTick = sampleRate / tickRateHz
samplesPerRow  = samplesPerTick * speed
```

So at the defaults (`speed = 6`, `tempo = 125`, `sampleRate = 44100`), you get a 50 Hz tick and 882 samples per tick.

Note triggers fire on tick 0; continuous modulation (slides, vibrato, tremolo, arpeggio, envelopes, fade-out) advances every tick.

### Frequency tables

XM ships two: linear and Amiga. Linear is the FT2 default:

```
Period    = 7680 - Note * 64 - FineTune / 2
Frequency = 8363 * 2^((4608 - Period) / 768)
```

Amiga uses a 96-entry period table interpolated by finetune, paired with the classic Amiga `Frequency = 8363 * 1712 / Period` formula. The mixer picks the right path automatically based on `XMFile.frequencyTable`.

## Effect coverage

Standard effect set (column `0..F`):

- **0** Arpeggio
- **1** Porta up
- **2** Porta down
- **3** Tone porta
- **4** Vibrato
- **5** Tone porta + volume slide
- **6** Vibrato + volume slide
- **7** Tremolo
- **8** Set panning
- **9** Sample offset
- **A** Volume slide
- **B** Position jump
- **C** Set volume
- **D** Pattern break
- **E** Extended `E0..EF` (fine portas, glissando control, vibrato/tremolo waveform, fine volume slides, retrigger, note cut/delay, pattern loop/delay)
- **F** Set speed / tempo

XM-specific extensions:

- **G** Set global volume
- **H** Global volume slide
- **K** Key off (also note 97)
- **L** Set envelope position
- **P** Panning slide
- **R** Multi retrig note
- **T** Tremor
- **X1/X2** Extra-fine porta up/down

Volume column commands (8-bit packed):

- `0x10..0x50` set volume
- `0x60..0x6F` slide down
- `0x70..0x7F` slide up
- `0x80..0x8F` fine slide down
- `0x90..0x9F` fine slide up
- `0xA0..0xAF` set vibrato speed
- `0xB0..0xBF` vibrato
- `0xC0..0xCF` set panning
- `0xD0..0xDF` panning slide left
- `0xE0..0xEF` panning slide right
- `0xF0..0xFF` tone porta

Envelopes (volume + panning, up to 12 points each) interpolate per tick, honor sustain and loop points, and feed into the per-voice gain. Volume fade-out runs after key-off when the volume envelope is enabled (per the FT2 spec).

## Installation

Swift Package Manager. Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/prestige-exe/SwiftXM", from: "0.1.0")
]
```

Then depend on the `SwiftXM` product from your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "SwiftXM", package: "SwiftXM")
    ]
)
```

For local development:

```swift
dependencies: [
    .package(path: "../SwiftXM")
]
```

## Quick start

```swift
import SwiftXM

let data = try Data(contentsOf: url)
let file = try XMFile(data: data)

print(file.moduleName)             // e.g. "AURA"
print(file.channelCount)           // e.g. 16
print(file.frequencyTable)         // .linear

let mixer = XMMixer(file: file, sampleRate: 44_100)

let frames = 1024
var buffer = [Float](repeating: 0, count: frames * 2) // interleaved L R
buffer.withUnsafeMutableBufferPointer { ptr in
    _ = mixer.render(into: ptr.baseAddress!, frames: frames)
}

if mixer.finished {
    // Order table exhausted; the song has ended.
}
```

`render(into:frames:)` returns the number of frames actually written. A short return means the song ended mid-buffer; the unwritten tail is zero-filled.

## AVAudioEngine bridge

Drop the mixer into an `AVAudioSourceNode` to play back on any Apple platform. Note: `AVAudioEngine` rejects an *interleaved* float format on a source node connected into the main mixer (error `-10868`); request `interleaved: false` and deinterleave the mixer's output into the two channel buffers.

```swift
import AVFoundation
import SwiftXM

final class XMPlayer {
    private let engine = AVAudioEngine()
    private let mixer: XMMixer
    private var sourceNode: AVAudioSourceNode!
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity = 8192

    init(file: XMFile) throws {
        let output = engine.outputNode
        let sampleRate = output.inputFormat(forBus: 0).sampleRate
        self.mixer = XMMixer(file: file, sampleRate: sampleRate)
        self.scratch = .allocate(capacity: scratchCapacity * 2)
        self.scratch.initialize(repeating: 0, count: scratchCapacity * 2)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!

        let mixerRef = mixer
        let scratch = self.scratch
        let scratchCapacity = self.scratchCapacity
        self.sourceNode = AVAudioSourceNode(format: format) {
            _, _, frameCount, ablPointer -> OSStatus in
            let n = Int(frameCount)
            let abl = UnsafeMutableAudioBufferListPointer(ablPointer)
            guard abl.count >= 2,
                  let lRaw = abl[0].mData,
                  let rRaw = abl[1].mData,
                  n <= scratchCapacity else { return noErr }
            let l = lRaw.assumingMemoryBound(to: Float.self)
            let r = rRaw.assumingMemoryBound(to: Float.self)
            _ = mixerRef.render(into: scratch, frames: n)
            for i in 0..<n {
                l[i] = scratch[i * 2]
                r[i] = scratch[i * 2 + 1]
            }
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    deinit {
        scratch.deinitialize(count: scratchCapacity * 2)
        scratch.deallocate()
    }

    func start() throws { try engine.start() }
    func stop()        { engine.stop() }
}
```

The render callback runs on the audio thread. `XMMixer` is `@unchecked Sendable` precisely because the host is expected to park it on one thread and never touch it elsewhere. There is no internal locking and concurrent renders will corrupt voice state.

## Status

v1 is feature-complete against the XM specification. The parser handles the full header, all pattern data (packed and unpacked variants), all instruments including the extended header (sample map, volume + panning envelopes, auto-vibrato, fade-out), and both 8-bit and 16-bit delta-encoded sample bodies. The mixer implements:

- Full standard effect set (0..F) plus the extended `E` subcommands
- XM-specific commands `G/H/K/L/P/R/T/X` (set global volume, global volume slide, key-off, set envelope position, panning slide, multi-retrigger with full per-tick volume change table, tremor, set panning)
- Complete volume column (set vol, fine slides, slides, vibrato, panning, tone porta)
- Volume + panning envelopes with sustain and loop
- Fade-out on key-off
- **Auto-vibrato** — instrument-level LFO that ramps in over the configured sweep period; the sweep multiplier freezes at key-off so depth doesn't keep growing through the fade
- **Glissando control** (E3x) — when set, tone-porta snaps the resulting period to the nearest whole-semitone boundary instead of gliding continuously
- **E9x retrigger** timing fixed so the row's own tick-0 trigger doesn't double-fire; restarts auto-vibrato sweep on each retrigger
- **EDx note delay** — the row's pending note actually fires on the requested tick instead of getting lost
- **Rxy retrigger** with the full 16-op volume change table from the XM spec (`x=0..F` driving the linear-delta, ratio, and no-op variants)
- Both linear and Amiga frequency tables

The parser also exposes the writing tracker (`XMFile.writingTracker`) detected from the file's tracker name — FastTracker II, OpenMPT, MilkyTracker, DigiBooster, Schism Tracker, or `.other`. Use it to gate format-specific quirks in your host if you need to; the mixer itself defaults to FT2-compatible semantics across the board, which matches the overwhelming majority of in-the-wild XMs.

Known shape-of-mixing tradeoffs (intentional, not roadmap items):

- The mixer is voice-per-channel (no NNA equivalent). XM doesn't model NNA the way IT does, but a few obscure tracker-quirk modes effectively rely on overlapping voices; those will sound abrupt here.
- Stereo samples are folded to mono on load — XM allows stereo but it's vanishingly rare in real files.

Contributions welcome; see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Requirements

- Swift **6.0** or later
- Xcode **16** or later
- Platforms: **iOS 17+**, **macOS 14+**, **tvOS 17+**, **watchOS 10+**, **visionOS 1+**

No third-party dependencies. Foundation only.

## License

MIT. See [`LICENSE`](LICENSE).
