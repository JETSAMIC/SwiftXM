# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - Unreleased (proposed initial release)

### Added
- `XMFile`: XM parser for versions 0x0102-0x0104 exposing the header,
  order table, patterns (`XMPattern.cell(row:channel:)`), instruments,
  envelopes, auto-vibrato and decoded samples (incl. ModPlug ADPCM).
- `XMMixer`: interleaved stereo `Float32` renderer following FT2's
  replayer semantics, with `currentOrder` / `currentRow`.
- Typed `XMError` cases for every rejected input.
- DocC catalog, Swift Package Index configuration, CI workflow.
- `Reference/XM-Format.md`, the comprehensive format specification with
  errata for the archived `Reference/xm-form.txt` (restored verbatim).
- OpenMPT stereo samples are decoded and mixed down to mono.

### Changed
- `XMMixer.init(file:sampleRate:)` now throws `XMError.invalidSampleRate`.
- `XMPattern.rows` was replaced by `cell(row:channel:)` (sparse storage).
- `XMError.truncatedSection(String)` was replaced by specific cases.
- Public model properties are now read-only.
- Playback stops when the song loops back to an already-played row.

### Fixed
- Crashes on truncated / hostile files (header fields beyond a short
  header-size, `Data` slices, envelope frames out of order, ping-pong
  loops at high pitch, 32-bit overflow) and memory exhaustion from huge
  declared empty patterns.
- Every note played one semitone sharp; the Amiga table lookup.
- `EEx` re-armed itself forever; `Bxx`/`Dxx`/`E6x` flow.
- Vibrato and tremolo were far shallower than FT2's; auto-vibrato
  waveform types were mapped to the wrong shapes.
- Forward loops wrapped at the sample end instead of the loop end.
- FT2 replayer quirks from the spec: fade-out without a volume envelope
  and pick-up after a fade, key-off + instrument, `K00`, instrument-only
  rows using the playing sample's defaults, `9xx` memory, tone-porta
  direction, finetune precision, the arpeggio table, auto-vibrato
  key-off, `EDx`, `EEx`, `Rxy` and `E90` timing, tremor reset, the
  volume-column pan-slide quirk, panning-envelope sustain and FT2's
  square-root pan law.
