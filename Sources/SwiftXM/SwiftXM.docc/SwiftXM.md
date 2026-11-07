# ``SwiftXM``

Decode FastTracker II (`.xm`) modules and render them to PCM.

## Overview

SwiftXM is a dependency-free parser and software mixer for the
FastTracker II Extended Module format. ``XMFile`` validates and
decodes the binary layout; ``XMMixer`` plays it back with FT2's
replayer semantics as interleaved stereo `Float32` frames that you can
feed to `AVAudioSourceNode` or any other audio host.

Parsing treats every size and offset in the file as untrusted: a
malformed file throws an ``XMError`` and never traps. Playback always
terminates: the mixer stops at the end of the order list or when the
song jumps back to a row it has already played.

```swift
let file = try XMFile(data: data)
let mixer = try XMMixer(file: file, sampleRate: 44_100)
mixer.render(into: buffer, frames: 1024)
```

## Topics

### Essentials

- <doc:GettingStarted>

### Parsing

- ``XMFile``
- ``XMFile/FrequencyTable``
- ``XMFile/WritingTracker``
- ``XMPattern``
- ``XMPattern/Cell``
- ``XMVolumeCommand``
- ``XMInstrument``
- ``XMInstrument/Envelope``
- ``XMInstrument/Envelope/Point``
- ``XMInstrument/AutoVibrato``
- ``XMSample``
- ``XMSample/LoopMode``

### Playback

- ``XMMixer``

### Errors

- ``XMError``
