# XM (FastTracker II Extended Module) Format

This is SwiftXM's authoritative description of the XM module format and of
the playback behaviour of FastTracker II, the program that defines it. It
supersedes the archival text in [`xm-form.txt`](xm-form.txt), which is kept
verbatim; every error found in that text is listed in [§8 Errata](#8-errata)
with its correction.

Contents

1. [Overview](#1-overview)
2. [Conventions](#2-conventions)
3. [Byte-level layout](#3-byte-level-layout)
4. [Enumerations and flags](#4-enumerations-and-flags)
5. [Algorithms](#5-algorithms)
6. [Playback semantics and FT2 behaviour](#6-playback-semantics-and-ft2-behaviour)
7. [Robustness guidance for readers](#7-robustness-guidance-for-readers)
8. [Errata](#8-errata)
9. [Implementation status in SwiftXM](#9-implementation-status-in-swiftxm)
10. [References and provenance](#10-references-and-provenance)

---

## 1. Overview

XM ("Extended Module") is the native song format of **FastTracker II**
(FT2), a DOS tracker written by Fredrik "Mr.H" Huss and Magnus "Vogue"
Högdahl of the Swedish demo group Triton, first released in 1994. The last
releases were 2.08 and 2.09 (late 1990s). An XM file holds a complete piece
of music: an order list, patterns of note events, and instruments that
bundle up to 16 PCM samples with envelopes, auto-vibrato and fade-out.

XM extended the Amiga MOD model with: multi-sample instruments and a
note-to-sample map; volume and panning envelopes with sustain and loop
points; key-off with fade-out; a per-cell *volume column* in addition to
the effect column; 16-bit samples; ping-pong loops; up to 32 channels; and a
choice between Amiga (period-based) and linear frequency tables.

### 1.1 Writers

Many programs write XM. They differ in how faithfully they follow FT2, and
some write fields FT2 never uses. The tracker-name field (offset 38) is the
usual hint, but it is not reliable: several tools copy FT2's string.

| Writer | Tracker name field (typical) | Notes |
|---|---|---|
| FastTracker II 2.0x | `FastTracker v2.00   ` | Reference behaviour. Same string for every 2.0x release. |
| ft2-clone (Olav Sørensen) | FT2's string | Cross-platform recreation of FT2 2.08/2.09. |
| MilkyTracker | `MilkyTracker ` + version | FT2-compatible tracker. |
| OpenMPT / ModPlug Tracker | `OpenMPT x.yy` / `ModPlug Tracker` (older versions copied FT2's string) | May add extension effects and trailing chunks (§3.8). |
| SoundTracker (Michael Krause, Unix) | `rst's SoundTracker  ` | Adds Q/Z filter effects. |
| DigiTrakker | composer's name | Misuses the field. |
| IT2XM, other converters | FT2's string | Converted data; IT semantics may not survive. |
| Schism Tracker, MadTracker, Skale Tracker, others | their own names | |

### 1.2 Versions

The 16-bit version field at offset 58 is `0x0104` for every FT2 2.0x
release. Earlier pre-release builds wrote `0x0102` and `0x0103`; such files
are rare. The versions differ in layout:

| Version | Order of sections | Pattern header |
|---|---|---|
| `0x0104` | header, all patterns, then each instrument followed immediately by its sample headers and its sample data | 9 bytes; 16-bit row count |
| `0x0103` | header, all instruments (with their sample headers, no sample data), all patterns, then the sample data of every instrument in instrument order | 9 bytes; 16-bit row count |
| `0x0102` | as `0x0103` | 8 bytes; 8-bit row count stored as *rows − 1* |

FT2 rejects any other version. OpenMPT loads other values with the `0x0104`
layout.

### 1.3 Identification

- Signature: bytes 0–16 are the ASCII text `Extended Module: ` (17 bytes,
  final space).
- Byte 37 is `0x1A` in FT2 files (a DOS end-of-file marker so that `TYPE`
  stops after the name). Some writers store other values; it should not be
  used to reject a file.
- File extension: `.xm` (case-insensitive on DOS).
- MIME type: `audio/x-xm` (freedesktop shared-mime-info). No system UTI is
  registered on Apple platforms.

---

## 2. Conventions

- **Byte order**: little-endian for all multi-byte integers.
- **Types** used in the tables: `u8`, `s8`, `u16`, `u32` (unsigned/signed,
  little-endian). There are no floating-point or fixed-point fields in the
  file.
- **Strings**: fixed-length, code page 437, padded with `0x00` (FT2) or
  spaces (some writers); not necessarily NUL-terminated. Readers should
  stop at the first `0x00` and may trim trailing spaces.
- **Alignment**: none. Structures are packed byte-for-byte.
- **Offsets** marked `+n` are relative to the start of the enclosing
  structure. Header fields after offset 60 are relative to the file start
  in this document, but are logically part of the block whose size is
  stored at offset 60.
- **Terminology**
  - *tick*: one step of the replayer; FT2 calls ticks "frames" in places.
    Effects, envelopes, fade-out and auto-vibrato all advance once per
    tick.
  - *speed*: ticks per row (FT2's UI calls it "tempo"); set by `Fxx` with
    `xx < 0x20`.
  - *BPM*: sets the tick duration, `2.5 / BPM` seconds (§5.8).
  - *row*: one line of a pattern; *order* (song position): one entry of
    the order table.
  - *note numbers*: pattern notes are 1-based, `1 = C-0` … `96 = B-7`,
    `97 = key-off`. Internally this document uses the 0-based *real note*
    `n = pattern note − 1 + relative note`, so `C-4 = 48`.
  - *period*: FT2's pitch unit. Larger periods mean lower pitch, in both
    frequency modes.
  - *finetune*: signed 8-bit, units of 1/128 semitone.

---

## 3. Byte-level layout

### 3.1 File structure

```
offset 0     fixed header (60 bytes)
offset 60    header block, length = HeaderSize (u32 at offset 60), counted from offset 60
             → first pattern header at 60 + HeaderSize

version 0x0104:
    pattern 0 header + packed data
    ...
    pattern P-1
    instrument 0 header [+ sample headers 0..S-1] [+ sample data 0..S-1]
    ...
    instrument I-1
    [optional OpenMPT extension chunks, §3.8]

versions 0x0102 / 0x0103:
    instrument 0 header [+ sample headers]   (no sample data here)
    ...
    pattern 0 ... pattern P-1
    sample data of instrument 0 (all its samples), instrument 1, ...
```

Nothing in the file points to a structure; every structure is found by
adding the sizes of the ones before it. A reader must therefore honour each
size field exactly (§7).

### 3.2 Module header

| Offset | Size | Type | Name | Meaning / valid range | Notes |
|---|---|---|---|---|---|
| 0 | 17 | char | ID | `Extended Module: ` | Exact match required. |
| 17 | 20 | char | Module name | CP437 | |
| 37 | 1 | u8 | `0x1A` | | Ignore on read. |
| 38 | 20 | char | Tracker name | CP437 | §1.1 |
| 58 | 2 | u16 | Version | `0x0102`–`0x0104` | high byte major, low byte minor |
| 60 | 4 | u32 | HeaderSize | FT2 writes 276 (20 + 256) | Counted from offset 60, so the header block ends at `60 + HeaderSize`. |
| 64 | 2 | u16 | Song length | 1–256 | Number of order-table entries played. |
| 66 | 2 | u16 | Restart position | 0 – song length − 1 | Order index played after the last order (§6.10). |
| 68 | 2 | u16 | Channels | FT2: 2–32 (UI allows even values only) | Other writers store odd values and more than 32. |
| 70 | 2 | u16 | Patterns | 0–256 | Count of pattern blocks that follow. |
| 72 | 2 | u16 | Instruments | 0–128 | Count of instrument blocks. |
| 74 | 2 | u16 | Flags | bit 0 = linear frequency table | Other bits unused (§4.1). |
| 76 | 2 | u16 | Default speed | 1–31 | Ticks per row. FT2's UI calls this "tempo". |
| 78 | 2 | u16 | Default BPM | 32–255 | |
| 80 | 256 | u8[] | Order table | pattern numbers | Only the first *song length* entries are meaningful. |

The 256-byte order table is the remainder of the header block only when
`HeaderSize = 276`. A smaller HeaderSize truncates the table (missing
entries read as 0); a larger one leaves extra bytes that must be skipped.
FT2 and OpenMPT both seek to `60 + HeaderSize` before reading the first
pattern.

### 3.3 Pattern

| Offset | Size | Type | Name | Meaning / valid range | Notes |
|---|---|---|---|---|---|
| +0 | 4 | u32 | Header length | 9 (8 for `0x0102`) | Includes this field. Skip to `start + header length` before the packed data, whatever its value (OpenMPT test case `pathead.xm`). |
| +4 | 1 | u8 | Packing type | 0 | Ignored. |
| +5 | 2 | u16 | Rows | FT2: 1–256 | Version `0x0102`: a single `u8` holding *rows − 1*. |
| +7 | 2 | u16 | Packed data size | bytes | (`+6` in version `0x0102`.) 0 = pattern is completely empty and no data follows. |
| +len | n | u8[] | Packed data | §5.1 | Exactly *packed data size* bytes. |

A stored row count of 0 (in the 16-bit field) is loaded as 64 rows by
OpenMPT. FT2 never writes it.

The packed data decodes to `rows × channels` cells in row-major order
(row 0 channel 0, row 0 channel 1, …). Each cell has five components:

| Component | Range | Meaning |
|---|---|---|
| Note | 0 = none, 1–96 = C-0…B-7, 97 = key-off | 98–255 are invalid; treat as none. |
| Instrument | 0 = none, 1–128 | Values above the instrument count select an empty instrument (§6.2). |
| Volume column | `0x00`–`0xFF` | §4.4 |
| Effect | 0–35 | §4.5 |
| Parameter | `0x00`–`0xFF` | |

FT2 does not store trailing patterns that are empty; order entries may name
patterns that are not in the file (§6.10).

### 3.4 Instrument header

| Offset | Size | Type | Name | Meaning / valid range | Notes |
|---|---|---|---|---|---|
| +0 | 4 | u32 | Instrument header size | FT2: 263 | Size of this header including this field and the extended part below, but **not** the sample headers. The first sample header starts at `start + size`. |
| +4 | 22 | char | Name | CP437 | |
| +26 | 1 | u8 | Type | should be 0 | Arbitrary in practice; ignore. |
| +27 | 2 | u16 | Number of samples | 0–16 | If 0, the instrument ends at `start + size` and nothing else follows. |

If *number of samples* > 0 the header continues:

| Offset | Size | Type | Name | Meaning / valid range | Notes |
|---|---|---|---|---|---|
| +29 | 4 | u32 | Sample header size | 40 | Size of each sample header (§3.5). Some writers store 0 or garbage. |
| +33 | 96 | u8[96] | Sample map | 0–15 | Sample index for each of the 96 notes (index 0 = C-0). |
| +129 | 48 | 12 × (u16, u16) | Volume envelope points | x = tick, y = 0–64 | §3.6 |
| +177 | 48 | 12 × (u16, u16) | Panning envelope points | x = tick, y = 0–64 (32 = centre) | |
| +225 | 1 | u8 | Volume points | 0–12 | |
| +226 | 1 | u8 | Panning points | 0–12 | |
| +227 | 1 | u8 | Volume sustain point | point index | |
| +228 | 1 | u8 | Volume loop start | point index | |
| +229 | 1 | u8 | Volume loop end | point index | |
| +230 | 1 | u8 | Panning sustain point | point index | |
| +231 | 1 | u8 | Panning loop start | point index | |
| +232 | 1 | u8 | Panning loop end | point index | |
| +233 | 1 | u8 | Volume type | §4.2 | |
| +234 | 1 | u8 | Panning type | §4.2 | |
| +235 | 1 | u8 | Auto-vibrato type | 0–3 | §4.3 |
| +236 | 1 | u8 | Auto-vibrato sweep | 0–255 | Ticks to reach full depth; 0 = immediately. |
| +237 | 1 | u8 | Auto-vibrato depth | 0–15 | |
| +238 | 1 | u8 | Auto-vibrato rate | 0–63 | Position step per tick (256 = one cycle). |
| +239 | 2 | u16 | Volume fade-out | 0–4095 | Subtracted from a 32768-based level each tick after key-off (§5.6). |
| +241 | 22 | u8[22] | Reserved | | FT2 keeps its per-instrument MIDI-output settings (MIDI enable, channel, program, pitch-bend range) and a mute flag here, followed by unused bytes. Not needed for playback; ignore. |

**Size quirks.** The documented fields end at +241 (243 bytes with the
2-byte "reserved" word of the older documents); FT2 writes 263. Other
writers use other values, including sizes smaller than 243. Correct
handling (OpenMPT, ft2-clone behaviour):

- Read the fixed 29 bytes regardless of the size field.
- If the size field is smaller than a field's end offset, that field is
  absent and reads as 0.
- Always continue at `start + size` (but at least `start + 29`) for the
  first sample header; never assume 243 or 263.
- Instruments without samples are often written with size 29 or 263 and
  no extended part.

### 3.5 Sample header

*Number of samples* headers follow the instrument header back to back.
Each occupies *sample header size* bytes (FT2: 40); the layout of the first
40 bytes is:

| Offset | Size | Type | Name | Meaning / valid range | Notes |
|---|---|---|---|---|---|
| +0 | 4 | u32 | Length | **bytes** of sample data | For 16-bit samples, 2 bytes per frame; for stereo (§3.7.3), both channels. For ADPCM (§3.7.2), the frame count. |
| +4 | 4 | u32 | Loop start | bytes | Divide by bytes per frame. |
| +8 | 4 | u32 | Loop length | bytes | 0 = no loop regardless of type. |
| +12 | 1 | u8 | Volume | 0–64 | Default volume. |
| +13 | 1 | s8 | Finetune | −128…+127 | 1/128 semitone. FT2 uses only the top 5 bits (§5.7). |
| +14 | 1 | u8 | Type | §4.6 | Loop type, 16-bit, stereo. |
| +15 | 1 | u8 | Panning | 0–255 | 0 = left, 128 = centre, 255 = right (FT2 cannot reach full right, §5.9). |
| +16 | 1 | s8 | Relative note | −96…+95 | Semitones added to the pattern note. 0 means C-4 plays at 8363 Hz. |
| +17 | 1 | u8 | Reserved | 0 | `0xAD` = ModPlug 4-bit ADPCM sample data (§3.7.2). |
| +18 | 22 | char | Name | CP437 | |

All sample headers of an instrument precede all of its sample data. The
sample data of sample *k* follows that of sample *k − 1* with no padding.

### 3.6 Envelope points

Each envelope is a fixed array of 12 points of 4 bytes:

| Offset | Size | Type | Name | Meaning |
|---|---|---|---|---|
| +0 | 2 | u16 | x | Tick position. FT2's editor limits it to 0–324; the file field holds 0–65535. |
| +2 | 2 | u16 | y | Value 0–64. Volume: 64 = full. Panning: 0 = left, 32 = centre, 64 = right. |

Only the first *points* entries are used. FT2 writes the first point at
x = 0 and strictly increasing x afterwards; files from other writers may
violate both (§7). SoundTracker writes x values above 255, which FT2's UI
cannot create; their presence suggests a non-FT2 writer.

### 3.7 Sample data

#### 3.7.1 Delta coding (all ordinary samples)

Samples are signed two's-complement PCM stored as differences between
successive values (this made archives compress better). 8-bit samples use
8-bit deltas, 16-bit samples 16-bit little-endian deltas. Decoding is
running summation with wrap-around in the sample width:

```
acc = 0                                  // s8 or s16
for i in 0 ..< frameCount:
    acc = (acc + delta[i]) wrapping in the sample width
    out[i] = acc
```

16-bit samples have `frameCount = length / 2`; an odd trailing byte is
ignored. The check value: deltas `01 01 FE` decode to `1 2 0`.

#### 3.7.2 ModPlug ADPCM (reserved byte `0xAD`)

ModPlug Tracker (and OpenMPT) can store 8-bit mono samples as 4-bit ADPCM.
The variant is signalled by the sample header's reserved byte being `0xAD`;
it is never used with the 16-bit or stereo flags. In this mode the
*length* field is the number of frames, and the data is:

| Offset | Size | Meaning |
|---|---|---|
| +0 | 16 | Delta table: 16 signed bytes |
| +16 | ⌈length / 2⌉ | Packed nibbles, two frames per byte, **low nibble first** |

```
acc = 0                                  // s8, wrapping
for i in 0 ..< length:
    byte   = data[16 + i / 2]
    nibble = (i even) ? byte & 0x0F : byte >> 4
    acc    = acc + table[nibble]          // wrapping
    out[i] = acc
```

Loop start and loop length are also in frames for ADPCM samples.

#### 3.7.3 Stereo samples (OpenMPT extension, type bit 5)

OpenMPT writes stereo samples by setting bit 5 of the type byte. The data
holds the whole left channel followed by the whole right channel, each
delta-coded independently from 0. *Length*, *loop start* and *loop length*
cover both channels, so the frame count is
`length / (bytesPerSample × 2)` and loop points are divided likewise. FT2
does not know this flag and plays such data as one mono sample twice as
long.

### 3.8 OpenMPT trailing chunks

After the last sample of the last instrument, OpenMPT and some ModPlug
versions append optional chunks, each a 4-byte ASCII ID and (for most) a
`u32` length:

| ID | Content |
|---|---|
| `text` | Song message, CR line endings. |
| `MIDI` | MIDI macro configuration (as in IT, used by `Zxx` / `\xx`). |
| `PNAM` | Pattern names, 32 bytes each. |
| `CNAM` | Channel names, 20 bytes each. |
| `CHFX`, `FX00`… | Channel plugin assignment and mix-plugin data. |
| `XTPM` | Extended instrument properties (OpenMPT-specific fields). |
| `STPM` | Extended song properties (tempo mode, mix levels, and so on). |

FT2 ignores everything after the last sample. Readers that do not support
these chunks must ignore trailing data rather than reject the file.

---

## 4. Enumerations and flags

### 4.1 Header flags (offset 74)

| Bit | Meaning |
|---|---|
| 0 | 0 = Amiga frequency table, 1 = linear frequency table |
| 1–15 | Unused by FT2; ignore. (Some OpenMPT versions set bits for their own purposes.) |

### 4.2 Envelope type (instrument +233, +234)

| Bit | Meaning |
|---|---|
| 0 | Envelope on |
| 1 | Sustain point active |
| 2 | Loop active |
| 3–7 | Unused; ignore |

### 4.3 Auto-vibrato type (instrument +235)

| Value | Waveform | Value of `w(pos)` for `pos` = 0…255 |
|---|---|---|
| 0 | Sine | `−64 · sin(2π · pos / 256)` (FT2's table starts negative) |
| 1 | Square | `pos < 128 ? −64 : +64` |
| 2 | Ramp up | `((pos >> 1) + 64) & 127) − 64` |
| 3 | Ramp down | `((−(pos >> 1)) + 64) & 127) − 64` |
| 4–255 | Undefined; treat as sine | |

### 4.4 Volume column

| Byte | Command (FT2 display) | Tick | Memory | Meaning |
|---|---|---|---|---|
| `0x00`–`0x0F` | — | | | Nothing. |
| `0x10`–`0x50` | set volume | 0 | | Volume = byte − `0x10` (0–64). |
| `0x51`–`0x5F` | — | | | Nothing (undefined). |
| `0x60`–`0x6F` | `-x` volume slide down | > 0 | none | Volume −= x per tick. |
| `0x70`–`0x7F` | `+x` volume slide up | > 0 | none | Volume += x per tick. |
| `0x80`–`0x8F` | `Dx` fine volume down | 0 | none | Volume −= x once. |
| `0x90`–`0x9F` | `Ux` fine volume up | 0 | none | Volume += x once. |
| `0xA0`–`0xAF` | `Sx` set vibrato speed | 0 | shared with `4xy` | If x > 0, vibrato speed = x. Does not vibrate by itself. |
| `0xB0`–`0xBF` | `Vx` vibrato | 0 / > 0 | shared with `4xy` | If x > 0, vibrato depth = x (tick 0); vibrato runs on ticks > 0. |
| `0xC0`–`0xCF` | `Px` set panning | 0 | | Panning = x × 16 (so `PF` = `0xF0`, not `0xFF`). |
| `0xD0`–`0xDF` | `Lx` panning slide left | > 0 | none | Panning −= x per tick. **x = 0 sets panning to 0** (FT2 bug, §6.6). |
| `0xE0`–`0xEF` | `Rx` panning slide right | > 0 | none | Panning += x per tick. x = 0 does nothing. |
| `0xF0`–`0xFF` | `Mx` tone portamento | > 0 | shared with `3xx` | If x > 0, porta speed = x × 16 (`M1` ≡ `310`). |

The volume column is processed before the effect column on every tick.

### 4.5 Effect numbers

The effect byte stores a letter: `0`–`9` → 0–9, `A`–`Z` → 10–35.

| Byte | Letter | FT2 effect | Byte | Letter | FT2 effect |
|---|---|---|---|---|---|
| 0 | `0` | Arpeggio | 18 | `I` | — |
| 1 | `1` | Portamento up | 19 | `J` | — |
| 2 | `2` | Portamento down | 20 (`0x14`) | `K` | Key-off |
| 3 | `3` | Tone portamento | 21 (`0x15`) | `L` | Set envelope position |
| 4 | `4` | Vibrato | 22–24 | `M N O` | — |
| 5 | `5` | Tone porta + volume slide | 25 (`0x19`) | `P` | Panning slide |
| 6 | `6` | Vibrato + volume slide | 26 | `Q` | — (SoundTracker: filter resonance) |
| 7 | `7` | Tremolo | 27 (`0x1B`) | `R` | Multi retrig |
| 8 | `8` | Set panning | 28 | `S` | — |
| 9 | `9` | Sample offset | 29 (`0x1D`) | `T` | Tremor |
| 10 | `A` | Volume slide | 30–32 | `U V W` | — |
| 11 | `B` | Position jump | 33 (`0x21`) | `X` | `X1x`/`X2x` extra-fine porta |
| 12 | `C` | Set volume | 34 (`0x22`) | `Y` | — (OpenMPT: panbrello) |
| 13 | `D` | Pattern break | 35 (`0x23`) | `Z` | — (OpenMPT: MIDI macro; SoundTracker: filter cutoff) |
| 14 | `E` | Extended (§4.5.1) | 36+ | | — (OpenMPT uses one value above `Z` for its smooth macro `\xx`) |
| 15 | `F` | Set speed / BPM | | | |
| 16 (`0x10`) | `G` | Set global volume | | | |
| 17 (`0x11`) | `H` | Global volume slide | | | |

FT2's loader clears effects it does not know. Readers should treat
unassigned numbers as "no effect" but keep the parameter for display.

#### 4.5.1 `E` sub-commands (high nibble of the parameter)

| Sub | Name | FT2 |
|---|---|---|
| `E0x` | Amiga filter | No effect. |
| `E1x` | Fine porta up | Tick 0. Own memory. |
| `E2x` | Fine porta down | Tick 0. Own memory. |
| `E3x` | Glissando control | 0 off, 1 on. |
| `E4x` | Vibrato waveform | §4.7 |
| `E5x` | Set finetune | With a note only. |
| `E6x` | Pattern loop | 0 = set start, x = loop x times. |
| `E7x` | Tremolo waveform | §4.7 |
| `E8x` | — | No effect in FT2 (some players: coarse panning). |
| `E9x` | Retrigger note | Every x ticks. |
| `EAx` | Fine volume up | Tick 0. Own memory. |
| `EBx` | Fine volume down | Tick 0. Own memory. |
| `ECx` | Note cut | Volume 0 on tick x. |
| `EDx` | Note delay | Cell takes effect on tick x. |
| `EEx` | Pattern delay | Repeat row x times. |
| `EFx` | — | No effect in FT2 (OpenMPT: select active macro). |

#### 4.5.2 `X` sub-commands

| Sub | Name | Writer |
|---|---|---|
| `X1x` | Extra-fine porta up (tick 0, period −x, own memory) | FT2 |
| `X2x` | Extra-fine porta down (tick 0, period +x, own memory) | FT2 |
| `X5x` | Panbrello waveform | OpenMPT extension |
| `X6x` | Fine pattern delay (add x ticks; multiple values sum) | OpenMPT extension |
| `X9x` | Sound control (surround, reverb, …) | OpenMPT extension |
| `XAx` | High sample offset (adds x × 65536 to later `9xx`) | OpenMPT extension |
| others | none | |

### 4.6 Sample type byte (sample header +14)

| Bits | Meaning |
|---|---|
| 0–1 | Loop: 0 = none, 1 = forward, 2 = ping-pong, 3 = treated as ping-pong |
| 2–3 | Unused (0) |
| 4 | 16-bit sample data |
| 5 | Stereo sample data (OpenMPT extension, §3.7.3) |
| 6–7 | Unused (0) |

### 4.7 Vibrato / tremolo waveform (`E4x`, `E7x`)

| x & 3 | Waveform |
|---|---|
| 0 | Sine (ProTracker half-sine table, §5.4) |
| 1 | Ramp down |
| 2 | Square |
| 3 | "Random" — FT2 plays it as square |
| bit 2 (x & 4) | Do **not** reset the waveform position on a new note |

---

## 5. Algorithms

### 5.1 Pattern unpacking

```
p = start of packed data; end = p + packedSize
for row in 0 ..< rows:
    for ch in 0 ..< channels:
        cell = empty
        if p < end:
            b = data[p]; p += 1
            if b & 0x80:                       // packed cell
                if b & 0x01: cell.note       = data[p]; p += 1
                if b & 0x02: cell.instrument = data[p]; p += 1
                if b & 0x04: cell.volume     = data[p]; p += 1
                if b & 0x08: cell.effect     = data[p]; p += 1
                if b & 0x10: cell.param      = data[p]; p += 1
            else:                              // unpacked cell
                cell.note = b
                cell.instrument, cell.volume, cell.effect, cell.param = data[p ..< p+4]; p += 4
        grid[row][ch] = cell
```

Each byte with bit 7 set, or each unpacked 5-byte group, fills exactly one
channel; the row advances after *channels* cells. Bits 5 and 6 of a packing
byte are unused. A packing byte of `0x80` is an empty cell. Bytes left over
after `rows × channels` cells are ignored; if the data ends early the
remaining cells are empty. Every read must also stop at `end`.

### 5.2 Linear frequency table (flag bit 0 = 1)

```
period    = 7680 − n·64 − ft/2                 // n = 0-based real note, ft = finetune (−128…127)
frequency = 8363 · 2^((4608 − period) / 768)   // Hz
```

With FT2's finetune quantisation (§5.7) the period is
`7680 − n·64 − 4·(ft >> 3)` (arithmetic shift). Check values: C-4 (n = 48,
ft = 0) → period 4608 → 8363 Hz; A-4 (n = 57) → period 4032 → 14064.8 Hz;
C-0 → period 7680 → 522.7 Hz. One semitone is 64 period units, so
portamento by 4 units is 1/16 semitone. FT2 evaluates the exponential from a
768-entry table; the formula gives the same values to within rounding.

### 5.3 Amiga frequency table (flag bit 0 = 0)

FT2's base table holds 12 notes × 8 finetune steps, starting one semitone
below C (index 8 = C at finetune 0 = 856):

```
907 900 894 887 881 875 868 862  856 850 844 838 832 826 820 814
808 802 796 791 785 779 774 768  762 757 752 746 741 736 730 725
720 715 709 704 699 694 689 684  678 675 670 665 660 655 651 646
640 636 632 628 623 619 614 610  604 601 597 592 588 584 580 575
570 567 563 559 555 551 547 543  538 535 532 528 524 520 516 513
508 505 502 498 494 491 487 484  480 477 474 470 467 463 460 457
```

```
ftq    = 8 · (ft >> 3)                                  // §5.7 quantisation
pos    = 8 + (n mod 12)·8 + ftq/16                      // ftq/16 ∈ {−8, −7.5, … , 7.5}
T(i)   = i < 96 ? table[i] : table[i − 96] / 2          // past B: next octave
base   = T(⌊pos⌋) + (T(⌊pos⌋ + 1) − T(⌊pos⌋)) · frac(pos)
period = base · 32 / 2^(n div 12)
frequency = 8363 · 1712 / period
```

FT2 itself expands the base table to 16 steps per semitone by averaging
neighbours and indexes it directly; the interpolation above produces the
same periods (half-steps are the average of two table entries). Check
values: C-4 → 1712 → 8363 Hz; C-0 → 27392; B-3 → 1814.

### 5.4 Vibrato and tremolo (effect column, FT2)

Position `pos` is an 8-bit counter (0–255, one cycle = 256). The speed
`s` (1–15) is stored as `4·s`; the depth `d` is 0–15.

```
sineTable[32] = 0 24 49 74 97 120 141 161 180 197 212 224 235 244 250 253
                255 253 250 244 235 224 212 197 180 161 141 120 97 74 49 24

vibrato (ticks > 0):
    i = (pos >> 2) & 31
    amp = waveform 0: sineTable[i]
          waveform 1: i·8, and if pos ≥ 128: 255 − i·8          // ramp
          waveform 2/3: 255                                     // square
    delta = (amp · d) >> 5
    outPeriod = period + delta   if pos < 128
                period − delta   otherwise
    pos = (pos + 4·s) & 255

tremolo (ticks > 0):  same, with
    ramp waveform testing the *vibrato* position (FT2 bug, OpenMPT TremoloVibrato.xm)
    delta = (amp · d) >> 6
    outVolume = clamp(volume ± delta, 0, 64)
```

### 5.5 Auto-vibrato (instrument)

Runs every tick on every playing voice, whether or not envelopes are
enabled, and is added on top of all other pitch changes.

```
on instrument trigger:
    pos = 0
    if sweep > 0: amp = 0;          sweepStep = (depth << 8) / sweep
    else:         amp = depth << 8; sweepStep = 0

each tick (depth > 0):
    if sweepStep > 0:
        if not keyOff:
            amp += sweepStep
            if (amp >> 8) > depth: amp = depth << 8; sweepStep = 0
            useAmp = amp
        else:
            useAmp = sweepStep          // FT2: sweep released mid-way → depth/sweep
    else:
        useAmp = amp
    pos = (pos + rate) & 255
    outPeriod += (w(pos) · useAmp) >> 14          // w from §4.3, range ±64
```

The key-off rule reproduces OpenMPT test case `AutoVibratoSweepKeyOff.xm`:
a note released before its sweep has completed continues with the depth of
a single sweep step.

### 5.6 Volume, fade-out and panning

```
fadeout   = 32768 on instrument trigger; after key-off: fadeout = max(0, fadeout − instrumentFadeout) each tick
finalVol  = (volume/64) · (envVol/64) · (fadeout/32768) · (globalVolume/64)
            (envVol = 64 when the volume envelope is off)
finalPan  = pan + (envPan − 32) · (128 − |pan − 128|) / 32
            (envPan = 32 when the panning envelope is off; pan, finalPan in 0…255)
```

Fade-out runs whenever the key is released, even if the volume envelope is
off (OpenMPT `NoteOffFadeNoEnv.xm`); in that case key-off also sets the
volume to 0, so the fade is audible only if a later command restores the
volume. A fade-out of 0 holds the level. A voice whose fade-out reached 0
is silent but still "playing": tone portamento can pick it up again
(`FadeoutPickup.xm`).

### 5.7 Finetune precision

FT2 keeps finetune at full 8-bit precision but computes periods from its
top five bits: `ft >> 3` (−16…15, an arithmetic shift, so −1 becomes −16/128
of a semitone, not 0). Two samples whose finetunes differ only in the low
three bits play at the same pitch (OpenMPT `Finetune-Precision.xm`). `E5x`
sets `ft = x·16 − 128`, i.e. `E50` = −128 (lowest), `E58` = 0, `E5F` = +112.

### 5.8 Timing

```
tickSeconds   = 2.5 / BPM            // 20 ms at 125 BPM
framesPerTick = sampleRate · 2.5 / BPM
rowSeconds    = speed · tickSeconds
```

Carry the fractional part of `framesPerTick` from tick to tick so long
renders do not drift.

### 5.9 Panning law (FT2 mixer)

FT2 uses a square-root (constant-power) law (OpenMPT `FT2PanLaw.xm`):

```
gainLeft  = sqrt((256 − finalPan) / 256)
gainRight = sqrt(finalPan / 256)            // finalPan 0…255
```

Panning 255 is not hard right; centre (128) is −3 dB per side.

### 5.10 Envelope evaluation

```
on instrument trigger: frame = 0; released = false
on key-off: released = true

each tick, if the envelope is on and has at least one point:
    value = interpolate(frame)
    if sustainOn and not released and frame == x[sustain]:
        hold                                   // do not advance
    else:
        frame += 1
        if loopOn and frame == x[loopEnd]:
            if not (released and sustainOn and sustain == loopEnd):
                frame = x[loopStart]

interpolate(f):
    if f ≤ x[0] or only one point: return y[0]
    find the first i ≥ 1 with f < x[i]; if none, return y[last]
    return y[i−1] + (y[i] − y[i−1]) · (f − x[i−1]) / (x[i] − x[i−1])
```

The value used for a tick is evaluated before the frame advances, so a
freshly triggered envelope outputs point 0 on its first tick (OpenMPT
`EnvOff.xm`). OpenMPT's `EnvLoops.xm` suggests that FT2 increments before
evaluating in some loop cases; OpenMPT itself currently keeps the
evaluate-then-advance order, and so does SwiftXM.

Panning-envelope sustain has an extra FT2 rule (§6.7).

---

## 6. Playback semantics and FT2 behaviour

Behaviour below is that of FT2 2.08/2.09 unless attributed otherwise.
Quirks are named after the OpenMPT test case that demonstrates them.

### 6.1 Tick processing order

```
tick 0 of a row (not a pattern-delay repeat):
    for each channel, left to right:
        read the cell
        if effect is EDx with x > 0: defer the whole cell to tick x (§6.4.13); continue
        note / instrument handling (§6.2)
        volume-column tick-0 commands
        effect-column tick-0 commands
ticks 1 … speed−1 (and every tick of a pattern-delay repeat):
    for each channel, left to right:
        volume-column per-tick commands
        effect-column per-tick commands (including EDx triggers, ECx, E9x, Kxx)
every tick, after the above, for each channel:
    envelopes, fade-out, auto-vibrato → final volume, panning and pitch
end of the last tick: pattern delay, then row advance (§6.9)
```

`Gxx` is applied while the row is parsed, so channels to the left of the
command only hear the new global volume from the next tick
(`GlobalVolume.xm`).

### 6.2 Notes and instruments

Each channel remembers: current instrument number, current sample, the last
real note, the playing sample's default volume and panning ("old volume"
and "old panning"), and per-effect memories.

| Cell content | FT2 action |
|---|---|
| Note, no instrument | Trigger the sample that the *current* instrument maps the note to. Volume and panning are unchanged; envelopes are not retriggered. |
| Note + instrument | The instrument becomes current; trigger the mapped sample; volume and panning reset to the sample's defaults; envelopes, fade-out and auto-vibrato restart. |
| Instrument only | Volume and panning reset to the *playing sample's* defaults (not the new instrument's); envelopes, fade-out and auto-vibrato restart; key-off is cleared (`NoteOffInstrChange.xm`). The sample is not restarted. |
| Key-off (97) | §6.3. |
| Key-off + instrument | Key-off, then volume and panning reset to the playing sample's defaults; envelopes are not retriggered, so the note fades out (`keyoff+instr.xm`, `RetrigFade.xm`). |
| Note + tone portamento (`3xx`, `5xx`, `Mx`) | The note sets the porta target; the sample is not retriggered. An instrument number next to it behaves as "instrument only" for the playing sample (`3xxins.xm`, `Porta-Pickup.xm`). Key-off and fade-out state is untouched without an instrument (`Off-Porta.xm`). |
| Instrument number > instrument count, or an instrument without samples, with a note | The note is cut (silence). |

Additional rules:

- The real note `n = note − 1 + relativeNote` must be in 0…118. Otherwise
  the note is ignored and not remembered, although the instrument number
  is (`NoteLimit.xm`); the check uses the transpose of the instrument named
  in the same cell (`NoteLimit2.xm`).
- A note triggers playback from position 0 (or the `9xx` offset). Unless
  bit 2 of the respective waveform control is set, the vibrato and tremolo
  positions reset; the multi-retrig and tremor counters reset.
- The sample's finetune is used unless `E5x` is in the same cell (§5.7).
- An instrument number alone does not change the porta target
  (`Porta-Pickup.xm`).
- A note that stopped (end of a non-looping sample, or an offset beyond
  the end) cannot be resumed by portamento (`3xx-no-old-samp.xm`,
  `PortaJustStoppedNote.xm`).

### 6.3 Key-off

Key-off (note 97, `Kxx`) releases the voice:

- with the volume envelope on: sustain is released and fade-out starts;
- with the volume envelope off: volume is set to 0 immediately and the
  fade-out also starts (`NoteOffFadeNoEnv.xm`); the sample keeps running
  muted (`NoteOff.xm`), so a volume command in either column in the same
  cell, or later, makes it audible again (`NoteOffVolume.xm`).

### 6.4 Effect column

"Memory" means a zero parameter recalls the last non-zero value of the
named memory. FT2 does not clear memories when playback starts (xm-form.txt);
a player should start from zero.

| Effect | Tick 0 | Ticks > 0 | Memory |
|---|---|---|---|
| `0xy` arpeggio | — | §6.4.1 | none (`000` = no effect) |
| `1xx` porta up | store | period −= 4·xx, min 1 | own |
| `2xx` porta down | store | period += 4·xx, max 31999 | own |
| `3xx` tone porta | store speed 4·xx | §6.4.3 | shared with `Mx` |
| `4xy` vibrato | store x, y separately | §5.4 | shared with `Sx`/`Vx` |
| `5xy` | store `A` memory | tone porta + volume slide | `A` memory |
| `6xy` | store `A` memory | vibrato + volume slide | `A` memory |
| `7xy` tremolo | store x, y separately | §5.4 | own |
| `8xx` panning | pan = xx | — | — |
| `9xx` offset | with a note: start at xx·256 frames | — | own; only updated next to a note (§6.4.6) |
| `Axy` volume slide | store | x > 0: vol += x, else vol −= y | shared with `5`, `6` |
| `Bxx` position jump | §6.9 | — | — |
| `Cxx` volume | vol = min(xx, 64) | — | — |
| `Dxy` pattern break | §6.9 | — | — |
| `E1x` / `E2x` | period ∓= 4·x | — | own, separate |
| `E3x` | glissando on/off | — | — |
| `E4x` / `E7x` | waveform | — | — |
| `E5x` | finetune (with note) | — | — |
| `E6x` | §6.9 | — | — |
| `E9x` | `E90` retriggers | every x ticks | none |
| `EAx` / `EBx` | vol ±= x | — | own, separate (`FineVol-LinkMem.xm`) |
| `ECx` | `EC0`: vol = 0 | vol = 0 on tick x | none |
| `EDx` | §6.4.13 | | none |
| `EEx` | §6.9 | | none |
| `Fxx` | §6.4.15 | — | — |
| `Gxx` | global = min(xx, 64) | — | — |
| `Hxy` | store | global ±, like `Axy` | own |
| `Kxx` | `K00`: §6.4.17 | key-off on tick xx | — |
| `Lxx` | §6.4.18 | — | — |
| `Pxy` | store | x > 0: pan += x, else pan −= y (0…255) | own (`PanSlideMem.xm`) |
| `Rxy` | §6.4.20 | §6.4.20 | x and y separately |
| `Txy` | store | §6.4.21 | own |
| `X1x` / `X2x` | period ∓= x | — | own, separate |

All six portamento memories (`1`, `2`, `E1`, `E2`, `X1`, `X2`) are
independent (`Porta-LinkMem.xm`).

#### 6.4.1 `0xy` Arpeggio

On ticks > 0 the pitch alternates between the base note, +x and +y
semitones. FT2 selects the step from its tick counter, which counts *down*
from the speed: with `t` = ticks elapsed in the row and `k = speed − t`,

```
k < 16:  step = k mod 3          (0 = base, 1 = +x, 2 = +y)
k = 16:  step = 0
k > 16:  step = 2                // FT2 reads past its 16-entry table (Arpeggio.xm)
```

so at speed 6 the order is +y, +x, base, +y, +x after the unchanged tick 0.
The offset is applied to the current (possibly slid) period, first rounded
to the nearest semitone in the channel's finetune (`ArpSlide.xm`); a
result above note 95 (B-7) is clamped to B-7 at finetune 0
(`ArpeggioClamp.xm`). The arpeggio changes only the output period; the
next row starts from the unmodified period.

#### 6.4.2 `1xx`, `2xx` Portamento

Periods are clamped to 1…31999 by the slides. FT2's period-to-frequency
lookup wraps for extremely low frequencies (`FreqWraparound.xm`); players
generally do not reproduce that.

#### 6.4.3 `3xx` Tone portamento

The target is set by a note in the same cell (computed with that note and
the playing sample's relative note and finetune); the sample is not
retriggered. On ticks > 0 the period moves toward the target by the speed
and stops on it. FT2 stores a direction when the target is set (towards
the target, or none if already there) and, once the target is reached from
either side, leaves the direction at "increasing period" (downward in
pitch). A later tone portamento towards the same target therefore jumps
straight to it if a `2xx` has meanwhile moved the pitch below the target
(`PortaResetDirection.xm`):

```
on note with tone portamento:
    target = period(note); direction = target > period ? up : (target < period ? down : none)
each tick > 0:
    down (period decreasing): period −= speed; if period ≤ target: period = target; direction = up
    up   (period increasing): period += speed; if period ≥ target: period = target
    none: nothing
``` With glissando on (`E31`), the output period
is rounded to the nearest semitone while the real period slides smoothly
(`Glissando.xm`). With both `Mx` and `3xx` in a cell, the porta runs twice
per tick at the `Mx` speed and `3xx`'s parameter is ignored
(`TonePortamentoMemory.xm`). A tone portamento next to `9xx` makes the
offset ignored and not memorised (`porta-offset.xm`).

#### 6.4.4 `4xy` Vibrato, 6.4.7 `7xy` Tremolo

See §5.4. `Vx` in the volume column with `4xy`/`6xy` in the effect column
advances the waveform twice per tick; the effect column's depth wins if
non-zero (`VibratoDouble.xm`). After an effect-column vibrato ends, the next
row restores the unmodified period. FT2 does *not* restore it after a
volume-column vibrato, which leaves the pitch detuned
(`VibratoCombinations.xm`; OpenMPT does not reproduce this either).

#### 6.4.5 `8xx` Set panning

Panning = xx (0–255). An instrument number later resets it.

#### 6.4.6 `9xx` Sample offset

Only next to a note (not a key-off, not with tone portamento): start at
`xx × 256` frames (bytes for 8-bit, 16-bit words for 16-bit). The memory is
updated only in that case (`OffsetWithoutNote.xm`). An offset at or beyond
the sample length stops the voice (`3xx-no-old-samp.xm`,
`OffsetRange.xm`).

#### 6.4.8 `Axy` Volume slide

If x > 0, slide up by x per tick, otherwise down by y. Memory is shared with
`5xy` and `6xy` but not with the volume column.

#### 6.4.9 `Cxx`, `Gxx`

Values above `0x40` clamp to `0x40`.

#### 6.4.10 `E3x`, `E4x`, `E7x`, `E5x`

As in §4.5.1, §4.7 and §5.7. `E5x` is effective only when a real note is in
the same cell (`finetune.xm`) and remains in force for later portamento
targets.

#### 6.4.11 `E9x` Retrigger

On ticks > 0 where `t mod x = 0` the sample restarts from 0 and the
envelopes restart. `E90` retriggers on tick 0 and has no memory
(`E90.xm`).

#### 6.4.12 `ECx` Note cut

Sets the volume to 0 on tick x (the sample keeps running). `EC0` cuts on
tick 0. If x ≥ speed nothing happens.

#### 6.4.13 `EDx` Note delay

If x = 0, `ED0` is ignored and the cell plays normally (`delay3.xm`). If
x ≥ speed (current speed only; pattern delays do not count), the whole
cell is ignored (`DelayCombination.xm`). Otherwise nothing in the cell
happens on tick 0 — neither the note, the instrument nor the volume column —
and on tick x, after that tick's volume-column slides:

- a note, or **if the cell has no note, the channel's last note**
  (`delay2.xm`), is triggered as in §6.2 without tone portamento; an
  instrument number resets volume and panning, a missing one does not
  (`DelayVolume.xm`);
- the envelopes, fade-out and auto-vibrato restart even without an
  instrument number (`envretrig.xm`);
- of the volume column only "set volume" and "set panning" are applied;
- a delayed key-off only restarts the envelopes: it neither releases the
  note nor applies volume-column panning (`OffDelay.xm`, `PanOff.xm`);
- a volume-column tone portamento in the same cell is ignored
  (`porta-delay.xm`, `PortaDelay.xm`).

Because the deferred cell is evaluated by tick number, a note delay inside a
row repeated by `EEx` fires again on every repetition
(`PatternDelay-NoteDelay.xm`).

#### 6.4.14 `EEx` Pattern delay

See §6.9. The tick-0 work of the row happens once; every repetition runs
only the per-tick commands, so fine slides (`E1x`, `EAx`, `X1x`) are not
repeated (`PatternDelaysRetrig.xm`; ccr's FT2 2.04–2.08 tests).

#### 6.4.15 `Fxx` Speed / BPM

`01`–`1F` set the speed, `20`–`FF` the BPM. `F00` sets speed 0, which FT2's
down-counting tick counter treats as 65536 ticks: the song appears to
stop on that row (OpenMPT documents F00 as speed 65535). Writers should not
use it.

#### 6.4.16 `Hxy` Global volume slide

Like `Axy` on the global volume (0–64), with its own memory.

#### 6.4.17 `Kxx` Key-off

Releases the note (§6.3) on tick xx; xx ≥ speed never fires. `K00` acts on
tick 0 and replaces the cell's note: a note next to `K00` is ignored and not
remembered (`key_off.xm`, `KeyOff2.xm`). An instrument next to `K00`
therefore behaves as "key-off + instrument" (the note fades out instead of
being cut when there is no volume envelope).

#### 6.4.18 `Lxx` Set envelope position

Sets the volume envelope frame to xx (if the volume envelope is on) and —
FT2 bug — sets the panning envelope frame only if the volume envelope's
*sustain* flag is set (`SetEnvPos.xm`). The note is not retriggered.

#### 6.4.19 `Pxy` Panning slide

On ticks > 0: if x > 0, pan += x, else pan −= y, clamped to 0…255. Own
memory, not shared with the volume column.

#### 6.4.20 `Rxy` Multi retrig

x selects a volume change, y the interval in ticks; each nibble has its own
memory (0 keeps the previous value). FT2 runs the retrig counter on every
tick of the row, **including tick 0 when the volume column of the cell is
empty** (`retrig.xm`). Each call:

```
count += 1
if count < y: return
count = 0
volume = table[x](volume), clamped to 0…64
restart the sample at 0
```

| x | change | x | change |
|---|---|---|---|
| 0 | none | 8 | none |
| 1 | −1 | 9 | +1 |
| 2 | −2 | A | +2 |
| 3 | −4 | B | +4 |
| 4 | −8 | C | +8 |
| 5 | −16 | D | +16 |
| 6 | × 2/3 | E | × 3/2 |
| 7 | × 1/2 | F | × 2 |

The counter resets when a note is triggered or an instrument number
appears.

#### 6.4.21 `Txy` Tremor

On for x + 1 ticks, off for y + 1 ticks. The counter is not touched on tick
0 and carries across rows; it resets only on a phase switch or an
instrument number (`Tremor.xm`, `TremorInstr.xm`). `T00` recalls the
memory.

```
each tick > 0:
    c = counter − 1
    if c < 0: phase = !phase; c = phase == on ? x : y
    counter = c
    outVolume = phase == on ? volume : 0
```

FT2 also lets a volume command on a later row lift a tremor mute
(`TremorRecover.xm`).

#### 6.4.22 `X1x`, `X2x`

Tick 0, period ∓ x (1/64 semitone in linear mode), own memories.

### 6.5 Volume column details

- Slides and fine slides have no memory; `-0`/`+0` do nothing.
- `Sx` and `Vx` share speed and depth with `4xy`, so `Sx` followed by `Vy`
  equals `4xy`.
- `Mx` shares the porta speed with `3xx`; the speed is `x × 16`.
- With `EDx` in the cell, volume-column tick-0 commands do not run on tick 0;
  per-tick slides do run, but an instrument number that the delayed tick
  applies afterwards overrides them on that tick (`VolColDelay.xm`).

### 6.6 Panning slide quirk

Volume-column `Lx` with x = 0 sets the panning to 0 (hard left) on every
tick after the first; `R0` does nothing (`PanSlideZero.xm`). FT2 implements
the left slide by adding `(256 − x) mod 256` with an unsigned-overflow test,
and for x = 0 the test sees no overflow.

### 6.7 Envelopes

Envelopes are restarted by: a note with an instrument number, an
instrument number alone, `E9x`, a note delay (§6.4.13) and `Lxx` (position
only). They advance one frame per tick (§5.10), held at the sustain point
until key-off. After the last point the last value is held; a volume
envelope ending at 0 does not stop the voice.

Panning-envelope sustain: once the panning envelope has been held at its
sustain point, it stays held even after key-off, unless the key-off and the
arrival at the sustain point happen on the same tick
(`PanSustainRelease.xm`).

### 6.8 Fade-out and auto-vibrato

See §5.5 and §5.6. Auto-vibrato restarts with the envelopes.

### 6.9 Row and order flow

```
on Bxx:  jumpOrder = xx; breakRow = 0; positionJump = true
on Dxy:  breakRow = x·10 + y; if breakRow > 63: breakRow = 0; positionJump = true
on E60:  channel.loopRow = row
on E6x (x > 0), per channel:
    if channel.loopCount == 0: channel.loopCount = x; breakRow = loopRow; loopJump = true
    else: channel.loopCount −= 1; if channel.loopCount > 0: breakRow = loopRow; loopJump = true
on EEx:  patternDelay = x          // the rightmost channel's EEx wins, even EE0 (PatternDelays.xm)

end of row:
    if patternDelay > 0: patternDelay −= 1; repeat the row (per-tick commands only)
    next = row + 1
    if loopJump: loopJump = false; next = breakRow            // stay in this pattern
    if next ≥ rows or positionJump:
        order = positionJump via Bxx ? jumpOrder : order + 1
        next = breakRow; breakRow = 0; positionJump = false
        if order ≥ songLength: order = restartPosition (or 0 if invalid)
        if next ≥ rows of the new pattern: undefined; FT2 jumps to the non-existent
            row and wraps; OpenMPT and SwiftXM use 0 (PatLoop-Overflow.xm)
    row = next
```

Consequences:

- `Dxy` reads its parameter as two decimal digits but accepts any nibble
  value (`D0A` = row 10). Rows above 63 become 0.
- `Bxx` and `Dxy` on the same row combine into "order xx, row x·10 + y"
  when the `Bxx` is to the left of the `Dxy`; a `Bxx` to the right resets
  the break row to 0, because channels are processed left to right.
- **E60 next-pattern quirk**: the break row of a completed `E6x` loop is not
  cleared, so the next pattern starts at the loop-start row unless a `Bxx`
  or `Dxy` has reset it (xm-form.txt, FT2 2.04–2.08; MOD files in FT2 too).
- Loop rows and counters are per channel and survive pattern changes and
  position jumps (`PatLoop-Break.xm`, `PatLoop-Jumps.xm`). Several
  simultaneous `E6x` on one row lead to results FT2 does not reproduce
  consistently (`PatLoop-Nested.xm`).

### 6.10 Song length, order table and restart

- Order entries name patterns 0–255. An entry naming a pattern beyond the
  stored pattern count plays an empty 64-row pattern.
- After the last order (or a `Bxx` beyond it) FT2 continues at the restart
  position; a restart position ≥ song length is treated as 0.

### 6.11 Other known FT2 behaviours

- Effect memories are not cleared when playback starts (xm-form.txt);
  results of a zero parameter before any non-zero one depend on what played
  before. Players start from zero.
- Two or more `E6x` loops on the same row behave inconsistently in FT2
  2.06/2.08 (xm-form.txt). Avoid them.
- `SampleChange.xm`: a note without an instrument number may switch to a
  sample of the current instrument while keeping the previous sample's
  settings, including the old instrument's fade-out.
- `lowest.xm`: a real note below 0 makes FT2 play the sample extremely slowly.

---

## 7. Robustness guidance for readers

Every field is untrusted. Recommended handling (what SwiftXM does):

| Situation | Handling |
|---|---|
| File shorter than 64 bytes, wrong signature | Reject. |
| Version outside `0x0102`–`0x0104` | Reject (FT2) or try the `0x0104` layout (OpenMPT). |
| HeaderSize < 20 or past end of file | Reject. HeaderSize < 276: missing order entries are 0. |
| Song length > 256 | Clamp to 256. 0: nothing to play. |
| Channels 0 | Reject. More than 32: FT2 rejects; other players accept (SwiftXM: up to 128). |
| Patterns > 256, instruments > 128 | FT2 rejects. Every structure costs at least a few bytes, so counts are bounded by the file size; check each structure against the remaining data. |
| Pattern header length < 8/9 | Reject; larger values are skipped. |
| Pattern rows 0 | 64. Rows > 256: OpenMPT caps at 1024. |
| Packed data size runs past end | Reject (or truncate). Allocate cells lazily: a header can claim 1024 rows × 128 channels of empty pattern. |
| Packed data shorter than the grid | Remaining cells empty. Longer: ignore the rest. Never read past `end`. |
| Note 98–255 | No note. Instrument 0 or > count: §6.2. Unknown effect number: no effect. |
| Instrument header size < 29 | Treat as 29. Smaller than 243 with samples: missing fields read as 0. |
| Sample header size 0 or implausible | Use 40. |
| Number of samples > 16 | FT2 limit; allow, but bound by remaining data (each sample header needs its declared size). |
| Sample map entry ≥ number of samples | The note plays nothing. |
| Envelope points > 12 | Clamp to 12. Sustain/loop indices ≥ points: disable that feature. Loop start > loop end: disable the loop. |
| Envelope x not increasing | Avoid division by zero; use the later point's value. |
| Envelope y > 64 | Clamp to 64. |
| Sample volume > 64 | Clamp to 64. |
| Sample length past end of file | Clip to the available data (FT2 and OpenMPT load partial samples). |
| Loop start ≥ length, loop end > length, loop length 0 | Clamp the loop end to the length; an empty loop is no loop. |
| 16-bit length odd | Ignore the last byte. |
| ADPCM length past end | Decode as many nibbles as present. |
| Huge lengths in a short file | Size allocations from the data actually present, never from header values. |
| Pattern loops, `Bxx` back-jumps, `F00` | Bound playback: a loop detector or row budget prevents an endless render. |
| Trailing data after the last sample | Ignore (§3.8). |

---

## 8. Errata

### 8.1 Errors in `xm-form.txt` (v0.81, ccr/TNSP)

| # | Section of xm-form.txt | Says | Correct | Evidence |
|---|---|---|---|---|
| 1 | Sample headers, finetune | "signed byte −16..+15" | −128…+127, 1/128 semitone; FT2 uses the top 5 bits | Same document, "Periods and frequencies" (−128…+127); FT2 editor range; `Finetune-Precision.xm` |
| 2 | Sample headers, type | "11 = 2 dec = Ping-pong loop" | Ping-pong is binary 10 (= 2); 3 is also treated as ping-pong | FT2-written files; FT2-compatible players |
| 3 | Pattern format, pseudocode | `else { c_note = dbyt; current_row++; }` | An unpacked cell is the note followed by instrument, volume, effect and parameter; every cell (packed or not) fills one channel; the row advances after *channels* cells | FT2-written files; §5.1 |
| 4 | Patterns | Fixed fields; rows is a word | Version `0x0102` uses a byte holding rows − 1 (8-byte header); the header-length field must be honoured for every version | `pathead.xm`; OpenMPT loader |
| 5 | Standard effects table | P = 24, R = 26, T = 28, X = 31 | P = 25 (`0x19`), R = 27 (`0x1B`), T = 29 (`0x1D`), X = 33 (`0x21`); letters map to 10 + (letter − `A`) | The table's own G = 16, K = 20, L = 21; FT2-written files |
| 6 | Fadeout | "FadeOutVol is originally 65536" and the volume formula divides by 65536 | FT2 starts at 32768 and divides by 32768, so a fade lasts `32768 / fadeout` ticks | FT2 output; ft2-clone |
| 7 | Fadeout | "Fadeout is not processed if Volume Envelope is DISABLED" | Fade-out runs after any key-off; without a volume envelope key-off also sets the volume to 0 | `NoteOffFadeNoEnv.xm`, `NoteOffVolume.xm` |
| 8 | Kxx | "The parameter of this effect does not have any meaning" | Key-off happens on tick xx; `K00` acts on tick 0 and suppresses the cell's note | `key_off.xm`, `KeyOff2.xm`; OpenMPT effect reference |
| 9 | 9xx, NOTICE#2 | "If there is no instrument set on the same row, this effect is ignored" | It needs a **note** (the example rows lack a note too); the memory is updated only next to a note; ignored with tone portamento | `OffsetWithoutNote.xm`, `porta-offset.xm` |
| 10 | Envelope format | point fields "Length 1, (word)" | Each field is 2 bytes | Struct in the same section; 48 bytes / 12 points |
| 11 | Envelope format | value range "00..3Fh (0..64 dec)" | 0…64 (`0x00`–`0x40`) | FT2 editor; file data |
| 12 | Envelope pseudocode | first point always at frame 0; point search with `<`/`>` and an undefined `current_frame` | Not guaranteed by other writers; use §5.10 (values at a point's frame are that point's value) | Robust loaders |
| 13 | Instruments, value ranges | "Instrument volume 00..3F" | There is no instrument volume in XM; sample volume is 0…64 (`0x40`) | §3.5 |
| 14 | Linear frequency table | Uses "Note" 1-based (1…119) and a NOTICE with finetune +128 | The formula needs the 0-based note (C-0 = 0, so C-4 = 48 → 4608 → 8363 Hz); finetune cannot be +128; FT2 accepts real notes 0…118 only | Arithmetic; `NoteLimit.xm` |
| 15 | Amiga frequency table | `… * 16 / 2^(Note DIV 12)` | With the 1-based note the factor is 32 (C-4: 856 · 32 / 16 = 1712 → 8363 Hz); plus Sahara Surfers' notes: no interpolation and a negative index for negative finetunes. Use §5.3 | Arithmetic |
| 16 | Standard effects table | 9xx not marked as remembering; 5xx/6xx memory ambiguous | `9xx` has memory (as the text says); `5xx`/`6xx` use and set the `Axy` memory | §6.4 |
| 17 | Volume column, note 3 | "Mx is equal to normal effect 30x" | `Mx` equals `3(x·16)`, e.g. `M1` = `310` | `TonePortamentoMemory.xm`; OpenMPT effect reference |
| 18 | Volume column table | `$10-$50` then ":" | `0x51`–`0x5F` do nothing; `Px` sets x · 16; `Lx` with x = 0 resets panning to 0 | `FT2PanLaw.xm`, `PanSlideZero.xm` |
| 19 | Fxx | "a zero parameter should be ignored" | FT2 sets speed 0, which stalls the row for 65536 ticks | OpenMPT effect reference |
| 20 | Lxx | "re-triggers the ENVELOPES … both" | Sets the volume envelope position; the panning one only when the volume sustain flag is set; nothing is re-triggered | `SetEnvPos.xm` |
| 21 | EEx | FT2 "forgets to play/update other effects on the row" | Tick-0 commands run once; per-tick commands continue during the repeats; the rightmost `EEx` decides the count | `PatternDelays.xm`, `PatternDelaysRetrig.xm` |
| 22 | Autovibrato | Unfinished formula; sweep "stays on the value it had when KeyOff was received" | §5.5; after key-off during the sweep the depth is one sweep step | `AutoVibratoSweepKeyOff.xm` |
| 23 | Player processing table | Four columns covering all cases | Incomplete: instrument-only rows use the playing sample, key-off + instrument resets volume, `K00`, note delays and portamento have the rules of §6.2–§6.4 | Test cases cited there |
| 24 | Header | "Number of channels (2, 4, 6, 8, 10, ..., 32)" | Odd counts and counts above 32 occur in files from other writers | OpenMPT, MilkyTracker files |
| 25 | Sample data pseudocode | `for i = 0 to data_len` | `0 ..< data_len` (one past the end otherwise) | Arithmetic |
| 26 | Sample data | "16-bit sample: int in C" | 16-bit little-endian (`int16_t`); a C `int` is wider on most compilers | |
| 27 | Header, instrument "Reserved" (+241) | 2 bytes | FT2's header is 263 bytes; bytes 241–262 hold MIDI-output settings and padding | FT2-written files |

### 8.2 Errors in previously circulating documents

| Document | Error | Correction |
|---|---|---|
| Mr.H's original XM description (1994) | Says `9xx` has no memory | It has (xm-form.txt, `OffsetRange.xm`) |
| Annotations formerly added in place to SwiftXM's copy of `xm-form.txt` | "In version $0102 the rows field is a single byte holding rows−1 … A stored 0 is treated as 64 rows" | The 0 → 64 rule applies to the 16-bit field of `0x0103`/`0x0104` (OpenMPT). In `0x0102` the stored byte is rows − 1, so 0 means one row. |
| Same | Kxx "the key off happens on tick xx of the row (K00 = immediately)" | Correct as far as it goes, but `K00` also suppresses the note in the cell (`KeyOff2.xm`) |
| Various player docs | Linear pan law | FT2 uses a square-root law (§5.9) |

---

## 9. Implementation status in SwiftXM

| Spec section / feature | Status | Notes |
|---|---|---|
| §3.2 Header, HeaderSize honoured, short order table | Supported | |
| §1.2 Versions `0x0102`, `0x0103`, `0x0104` and their layouts | Supported | Other versions rejected. |
| §3.3 Patterns: header length honoured, packed/unpacked cells, empty, rows 0 → 64, up to 1024 rows | Supported | Sparse storage. |
| §3.4 Instrument header size quirks; sample header size 0 | Supported | Bytes after +241 ignored. |
| §3.7.1 8/16-bit delta samples | Supported | 8-bit data is scaled to 16 bits. |
| §3.7.2 ModPlug ADPCM | Supported | |
| §3.7.3 Stereo samples | Partial | Decoded and mixed down to mono. |
| §3.8 OpenMPT trailing chunks | Unsupported | Ignored. |
| §4.6 Forward / ping-pong loops, zero-length loops | Supported | |
| §5.2, §5.3 Linear and Amiga tables, §5.7 finetune precision | Supported | Amiga periods interpolated from the 96-entry table. |
| §5.4 Vibrato, tremolo waveforms incl. tremolo ramp bug | Supported | |
| §5.5 Auto-vibrato incl. key-off during sweep | Supported | |
| §5.6 Volume, fade-out (32768 base, also without envelope), pick-up after fade | Supported | |
| §5.9 Square-root pan law | Supported | |
| §5.10, §6.7 Envelopes, sustain, loops, pan-sustain rule | Supported | Evaluate-then-advance order (as OpenMPT). |
| §6.2 Note / instrument rules, note range check | Supported | `SampleChange.xm` behaviour not reproduced. |
| §6.3 Key-off with and without envelope; key-off + instrument | Supported | |
| §6.4.1 Arpeggio (counter order, >16 overflow, semitone rounding, clamp) | Supported | |
| §6.4.2–6.4.3 Portamentos, memories, direction memory, glissando, `Mx`+`3xx` | Supported | `FreqWraparound.xm` wrap not reproduced. |
| §6.4.4 Vibrato after volume-column vibrato leaves pitch detuned | Unsupported | Pitch is restored every row (as OpenMPT). |
| §6.4.6 Offset memory and porta interaction | Supported | |
| §6.4.11–6.4.14 `E9x` (incl. `E90`), `ECx`, `EDx` quirks, `EEx` rightmost | Supported | |
| §6.4.15 `F00` | Partial | Ignored instead of stalling for 65536 ticks. |
| §6.4.17–6.4.21 `Kxx`/`K00`, `Lxx`, `Pxy`, `Rxy` (incl. tick 0), `Txy` | Supported | `TremorRecover.xm` volume case not reproduced. |
| §6.4.22 `X1x`, `X2x` | Supported | |
| §4.5 OpenMPT extensions (`X5x`, `X6x`, `X9x`, `XAx`, `Y`, `Z`, `\`), SoundTracker `Q`/`Z`, `E0x`/`E8x`/`EFx` | Unsupported | Ignored. |
| §6.5 Volume column incl. `Lx` 0 quirk, delay interaction | Supported | |
| §6.1 Global volume timing for channels left of `Gxx` | Unsupported | Applies from the same tick. |
| §6.9 Row/order flow, `E6x` per channel with next-pattern quirk | Supported | `PatLoop-Overflow.xm`: row 0 instead of FT2's wrap. |
| §6.10 Restart position | Partial | Parsed; playback stops at the end instead of looping. |
| FT2 mixer (volume ramping, exact interpolation) | Unsupported | Linear interpolation without ramping. |

---

## 10. References and provenance

- Fredrik "Mr.H" Huss / Triton, *The XM module format description* (1994,
  public domain) — the original description shipped with FastTracker II.
- Guru and Alfred / Sahara Surfers, enhanced XM description (1995).
- Matti "ccr" Hämäläinen / TNSP, *The "Complete" XM module format
  specification* v0.81 (2000–2001), archived verbatim as
  [`xm-form.txt`](xm-form.txt).
- OpenMPT project, *Development: Test Cases/XM* (wiki) — prose descriptions
  of FT2 behaviour; every test-case name cited above refers to that page.
- OpenMPT project, *Manual: Effect Reference* (wiki) — effect semantics and
  ModPlug/OpenMPT XM extensions.
- Olav "8bitbubsy" Sørensen, ft2-clone — used as a black-box reference for
  FT2 output.
- Claudio Matsuoka and Hipolito Carraro Jr., XMP technical documentation.
- Chipaux Sylvain (Asle / ReDoX), notes on player bugs cited in xm-form.txt.

**Provenance.** This document was written for SwiftXM from the public
documents listed above, the archived xm-form.txt, and black-box observation
of FT2-compatible players. Facts, field layouts and numeric tables are
reproduced; the prose is original. No third-party source code was copied
or consulted for it.
