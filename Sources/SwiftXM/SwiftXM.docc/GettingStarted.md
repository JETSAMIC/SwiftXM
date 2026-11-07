# Getting Started

Load an XM module, inspect it, and render it to audio.

## Overview

Playing a module takes two steps: parse the file with ``XMFile``,
then pull audio from an ``XMMixer``.

### Parse a module

```swift
import SwiftXM

let data = try Data(contentsOf: url)
let file = try XMFile(data: data)

print(file.moduleName, file.channelCount, file.frequencyTable)
for instrument in file.instruments {
    print(instrument.name, instrument.samples.map(\.lengthFrames))
}
let firstCell = file.patterns.first?.cell(row: 0, channel: 0)
```

``XMFile/init(data:)`` throws ``XMError`` when the data is not a
supported XM module or its header, patterns or instrument headers are
truncated. Sample data cut short by the end of the file is clipped.

### Render audio

```swift
let mixer = try XMMixer(file: file, sampleRate: 44_100)

var buffer = [Float](repeating: 0, count: 1024 * 2)   // L R L R …
let frames = buffer.withUnsafeMutableBufferPointer {
    mixer.render(into: $0.baseAddress!, frames: 1024)
}
```

``XMMixer/render(into:frames:)`` returns how many frames it produced.
A short count means the song ended and ``XMMixer/finished`` is now
`true`; the rest of the buffer is zero-filled.

### Threading

The mixer is `@unchecked Sendable` so it can be captured by an audio
render block, but it is not internally synchronised: call it from one
thread at a time (normally the audio render thread).

### Limitations

- Playback stops at the first loop back to an already-played row (and
  ignores ``XMFile/restartPosition``); create a new mixer to loop.
- Mixing uses linear interpolation without FT2's volume ramping.
