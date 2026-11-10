# The frame descriptor ("bookend") - `SVLVideoFrameDescriptor_t`

Message kind 5, type 2 (`SVST_VIDEO_TRANSPORT_DESCRIPTION`), host -> client.
`SVLVideoFrameDescriptor_t` is the whole message *including* the 8-byte
`dataset` header: the client passes the `dataset*` directly as the descriptor
pointer and reads descriptor fields at offsets >= 8 (**static**:
`SVLFEC::AcceptVideoPacket` +0x160684 passes `dataset+0x10` as the frame size
and `SVLFECRXFrame::Initialize` +0x15f6f4 reads `desc+0x28`).

It is called a bookend because one is sent before the frame's packets and one
after every group of 64; the client logs `"CN Got Bookend%d"` and the sender
`"SN SendBookend%d"` (0..8 and `N`).

## Layout

Offsets from the start of the message. "TX" is what
`SVLFECRAID6TXFrame::InitializeAndSend` (+0x1617a4) writes - **inferred** to be
what the host writes. "RX" is what this client reads - **static**.

| Off | Type | Name | TX writes | RX use |
|---|---|---|---|---|
| 0x00 | u8 | kind | 5 | |
| 0x01 | u8 | type | 2 | |
| 0x02 | u16 | `frame_id` | frame number | slot select `& 0xf` |
| 0x04 | u16 | `len` | 0x3f8 (see note) | only for byte accounting |
| 0x06 | u16 | `group` | 0 for the first bookend, then `g+1` after group `g` | `SVLFECRXFrame::AcceptVFD` +0x15f164: if greater than any group seen, `CheckRetry(group)` |
| 0x08 | u32 | `tx_time` | sender `GetCurrentTimestamp()` (us, 32-bit) when the frame started sending | `SVLRoot::SymmetricTimingUpdate(tx_time, now)` in `SVLDataLink::ReceivedData` +0x15a9b8 |
| 0x0c | u32 | `peer_clock` | sender's `SVLRoot+0xc7c` | stored to `SVLRoot+0xc84`; used with `+0xc7c` to convert host timestamps to local (docs/svl-timing/) |
| 0x10 | u32 | `frame_size` | encoded frame size in bytes | `SVLFECRXFrame::Initialize(frame_id, frame_size, desc)`; must be <= 0x400000 |
| 0x14 | u8 | `flag` | the `bool` argument of `SVLFEC::SendData(data, size, metadata, bool)` | not read by this client |
| 0x15 | u8 | `fec_mode` | `SVLFEC+0xc20`, constructed as 0x20 | compared with `SVLDataLink+0x18`; a difference logs `"SVLDataLink::HandleFECChange( %d )"` and stores it. Nothing else changes: only one FEC exists in this build |
| 0x16 | u16 | - | not written | not read |
| 0x18 | u32 | - | 0xffffffff | not read |
| 0x1c | u8 | `bookend_index` | 0 for the first, +1 per bookend sent for this frame (resends included). **captured**: equal to `group` on all 8,631 descriptors of `vr3`, where nothing was resent | timing event `0x43 + min(index, 8)` |
| 0x1d | u8 | - | 0 | not read |
| 0x1e | u16 | `metadata_size` | 0x154 if `metadata.info >= 0x10` (metadata +0xe5), else 0xf0 | `GetEndOfPacketFromVideoDescriptor` +0x155c14: 0 means 0xf0; > 0x17c means "no trailer" |
| 0x20 | u32 | `version` | 9 | stored to `QSVLClient+0xba8`; gates behavior, see below |
| 0x24 | u32 | - | 0 | not read |
| 0x28 | 0x154 bytes | `TransportFrameMetadata_t` | the frame's metadata | copied whole (always 0x154 bytes, even when `metadata_size` says 0xf0) - see [frame-metadata.md](frame-metadata.md) |
| 0x28 + metadata_size | 16 bytes + variable | trailer | filled by `SVLRoot::FillInBookend` on the sender | `QSVLClient::ReceivedBookend` +0xf6cf8 |

Notes:

- `len`: the TX code initializes it to 0x3f8 and calls the virtual
  `FillInBookend(desc)` before each send. The client-side
  `SVLRoot::FillInBookend` (+0x165988) only *returns*
  `0x28 + metadata_size + 0x10` (the size with an empty trailer); it does not
  store it. **captured** (see below): the host leaves `len` at 0x3f8 too, so
  the message is always 1024 bytes. The part after the trailer is not
  reliably zero - see "Unused tail" below.
- `flag` at 0x14: the only per-frame boolean the encoder passes down. It is
  **not** a keyframe marker (captured: constant 1); meaning unknown.
- `version` gates (all **static**):
  - `< 5`: legacy haptics are read from the trailer (below).
  - `> 5`: the renderer reports `FrameHasBeenSubmittedForDisplay` and replaces
    the predicted display time with the frame's own (`QSVLRendererXR::FlipFrame` +0x10ae78).
  - `>= 9`: frames are chosen by display time (`ServeBestHardwareBuffer`)
    instead of FIFO (`ServeNextHardwareBuffer`).

## What the client does with a descriptor

**static** - `SVLFEC::AcceptVideoPacket` then `SVLFECRXFrame::AcceptVFD`:

1. Ignore it if the frame id is already accepted or submitted and the slot has
   a descriptor.
2. `SVLRoot::ReceivedBookend` (virtual, = `QSVLClient::ReceivedBookend`) parses
   the trailer (every bookend, including repeats).
3. If the slot holds a different frame, `Initialize(frame_id, frame_size, desc)`:
   clears the bitmap, acquires a decoder input buffer, invalidates the metadata
   history entry for this present number.
4. First descriptor for the frame only: `SVLRenderer::AcceptFrameMetadata(desc+0x28, 1)`,
   copy the 0x154 metadata bytes into the slot, record
   `present_number & 0x7f -> frame_id`, set `frame_size` from +0x10.
   If the slot has no buffer or the frame was already accepted it logs
   `"[SVLFEC] received late metadata for frame [ %d ]"` and carries on.
5. If `group` is a new maximum, `CheckRetry(group)` - request everything missing
   below that group ([retransmit.md](retransmit.md)).
6. `CheckRXComplete()`.

## Trailer

`E = desc + 0x28 + metadata_size`. **static** - `QSVLClient::ReceivedBookend` (+0xf6cf8).

| Off from E | Type | Name | Notes |
|---|---|---|---|
| 0x00 | u8 | - | not read |
| 0x01 | u8 | haptic[0].amplitude | / 255 |
| 0x02 | u16 | haptic[0].frequency | * 0.5 Hz |
| 0x04 | u16 | haptic[0].duration | / 10000 s (units of 100 us) |
| 0x06 | u8 | - | not read |
| 0x07 | u8 | haptic[1].amplitude | |
| 0x08 | u16 | haptic[1].frequency | |
| 0x0a | u16 | haptic[1].duration | |
| 0x0c | u8 | `trailer_version` | piggy-back section is parsed only when this is 3 |
| 0x0d | u8 | `n_values` | count of `TransportValue_t` (32 bytes each) |
| 0x0e | u8 | `n_timing` | count of timing-event records (8 bytes each) |
| 0x0f | u8 | `n_vte_bytes` | length of a ValueTransportSystem message |
| 0x10 | 32 * n_values | values | `SVLRoot::ParsePeerValueSettings` - the SVLRoot key/value channel (docs/svl-values/) |
| ... | 8 * n_timing | timing events | below |
| ... | n_vte_bytes | VTE bytes | `ValueTransportSystem::RXMessage` (docs/svl-values/) |

- The two haptic records are only used when `version < 5`. Each is delivered
  through the same virtual (`vtable+0xe0`) that handles the kind-3 type-0x16
  haptic message, as `{float freq_hz, float duration_s, float amplitude, i32
  local_time, u16 0, u8 hand}` with `hand` = 0 then 1. Zero frequency or zero
  amplitude clears the record; zero duration becomes "frequency 0, duration
  0.004 s". With the captured `version` of 14 this path is dead and haptics arrive as
  their own messages (docs/svl-tracking-input/).
- Timing-event record: `{u8 event, u8 arg, u16 id, i32 host_time}`. Parsed only
  when `QSVLClient+0xc69` is set; each is converted to local time and passed to
  `ReportTimingEventWithTimestamp`. Event 0x24 additionally feeds a 512-bin
  phase histogram. Owned by docs/svl-timing/.
- So the bookend is also a carrier: the host can deliver SVLRoot values and
  ValueTransportSystem chunks inside it, at frame rate, without separate
  datagrams. A client must feed the VTE bytes to the same parser as kind-3
  type-0x0d messages or it will miss value updates and never ack them.

## Captured

Capture `vr3` (not in the repo): **8,631 descriptors**, all intact, covering
4,260 frames. Everything in this section is **captured**. (`vr1`, the earlier
capture, had 78 intact descriptors; nothing below contradicts it except where
noted.)

### How many, and when

- Exactly `1 + n_group` descriptors per frame: bookend 0 before the first
  data packet, bookend `g+1` after the parity of group `g`
  ([packets.md](packets.md) has the order end to end). By group number:
  0 x4260, 1 x4259, 2 x68, 3 x42, 4 x1, 5 x1. That is 8,632 minus one
  closing bookend that was lost on the wire (frame 8).
- **No bookend is repeated**: no (frame, group) pair occurs twice, and the
  lost one was not resent. The client never asked for one (no retransmit
  request at all in this capture), so "a descriptor resent in answer to a
  0xffff request" is still unseen.
- Within a frame, all bookends carry the same `tx_time`, `peer_clock`,
  `frame_size` and the same 0xf0 metadata bytes (4,371 of 4,371 later
  bookends equal the frame's first in all four). The trailer differs on
  every one of them: each bookend carries the next four value records.

### Header, over all 8,631

| Off | Captured |
|---|---|
| 0x04 `len` | **0x3f8 on all**. The descriptor is a fixed 1024-byte message. So the "host sets the real length" guess above is wrong: parse by the counts in the trailer, not by `len` |
| 0x06 `group` / 0x1c `bookend_index` | equal on all 8,631; values 0..5 |
| 0x08 `tx_time` | host clock, microseconds. Same on every bookend of a frame, so it is stamped once per frame. Frame-to-frame difference: median 9.20 ms (distribution in [packets.md](packets.md)); the span over the run (39.327167 s) matches the span of arrival times on the client clock (39.327784 s) to 0.6 ms. It is 1.7 .. 53 ms earlier than the metadata `display_time` of the same frame (1 % 20.0, median 26.3, 99 % 52.5 ms) |
| 0x0c `peer_clock` | 1,034 distinct values over 4,260 frames, all within a 1.18 ms range, drifting slowly; constant within a frame |
| 0x10 `frame_size` | equals the reassembled frame and the decoder access-unit size on all 4,260 frames |
| 0x14 `flag` | **1 on all 8,631**, including both IDR frames (0 and 4), the 9 single-packet frames and the 284 kB frame. So it is not a keyframe marker and not a size class. Meaning still unknown |
| 0x15 `fec_mode` | 0x20 on all |
| 0x16 | 0 on all |
| 0x18 | 0xffffffff on all |
| 0x1d | 0 on all |
| 0x1e `metadata_size` | **0xf0 on all** - the short form. The trailer therefore starts at message offset **0x118** |
| 0x20 `version` | **0x0e (14) on all**, not the 9 this client's own TX code writes. All three gates (`< 5`, `> 5`, `>= 9`) fall on the modern side: no trailer haptics, display-time selection on |
| 0x24 | 0 on all |

Because `metadata_size` is 0xf0 while the client copies 0x154 bytes of
metadata regardless, the last 0x64 bytes of the client's metadata copy are
really the start of the trailer. The client never reads them, so it is
harmless, but a reimplementation should take 0xf0 bytes.

### Trailer, at message offset 0x118 (payload offset 0x110)

| Off from E | Captured, over all 8,631 |
|---|---|
| 0x00..0x0b (haptics) | all zero on all |
| 0x0c `trailer_version` | 3 on all |
| 0x0d `n_values` | 4 on all |
| 0x0e `n_timing` | **0 on all** - no timing-event record in 8,631 bookends of a real 40 s session |
| 0x0f `n_vte_bytes` | 0 on 8,602; non-zero on 29: 252 (x16), 244 (x1), 224 (x12) |
| 0x10 | `n_values` x 32-byte value records, immediately followed by `n_vte_bytes` of ValueTransportSystem data. The VTE bytes parse to exactly `n_vte_bytes` on all 29 |

- Value records: each 32 bytes = name, NUL-padded to 20 bytes; `double` at
  +20; `u32` timestamp at +28, on the same host clock as `tx_time` (median
  4.6 ms older than the bookend's `tx_time`). Four per bookend. **51 distinct
  names** over the run, in three groups: the client's own `c*` keys echoed
  back (19, e.g. `cRXpass`, `cPingMS`, `cFramePhase`, `cAudBufAvg`), host
  keys (`d*`, `s*`, `dbg*`, `enc*`, `n*`, `tsLastWGP`, `txTimeMS`) and two
  unprefixed timers (`GetData`, `StartNvEnc`). They are not sent equally
  often: nine keys that change every frame fill most slots (`dCurBW` 4,425
  records, `dEstLinkBW` 4,423, `GetData` 4,406, `StartNvEnc` 4,227,
  `dHitchMaxBW` 3,690, `dProblemBW` 3,203, `dFrmsEarly` 1,261, `dFrmsLate`
  682, `dRunStart` 670), while each of the other 42 appears 168..254 times,
  i.e. is refreshed about once per 35..50 bookends (4 to 6.5 times a
  second) whether it changed or not. 504 bookends carry the same name twice. Record
  format and meanings: docs/svl-values/. Three values that bear on this
  layer: `cRXpass` (echo) and `sRXpass` were 100 in every sample, and
  `encResets` was 3 in every sample (170, the first 0.18 s after the first
  frame), so the two IDRs of the run are not counted by it after that point.
- VTE bytes travel in the trailer **only at stream start**: the 29 bookends
  that have any are those of frames 0..14, the first 143 ms. The other 8,602
  have none, so after start-up the host's value traffic for this session
  went elsewhere or there was none (docs/svl-values/). What the 29 carried:

  | Element | Count | Notes |
  |---|---|---|
  | ack, ids 0x0d / 0x0e / 0x0f | 189 / 264 / 260 | both bookends of frames 0..7: nothing but acks, 63 per trailer (252 bytes), the same ids acked over and over - the host fills the room with acks for the client's values. Bookend 0 of frame 8: 17 more acks, then the first four data values below (244 bytes) |
  | ack, id 0x05 | 104 | same bookends |
  | ack, ids 0x10, 0x11, 0x12, 0x15, 0x18, 0x20, 0x22, 0x23 | 26 each | same bookends |
  | data id 0x06, version 1, 32 bytes | 13 | both bookends of frames 9..14: the same nine data elements in each, 224 bytes, no acks; plus once in frame 8 |
  | data id 0x17, version 1, 104 bytes | 13 | |
  | data id 0x1c, version 1, 4 bytes | 13 | |
  | data id 0x29, version 2, 4 bytes | 13 | |
  | data id 0x35, version 1, 4 bytes | 12 | frames 9..14 only |
  | data id 0x64, 0x65, 0x67, 0x72, version 1, 1 byte | 12 each | |

  Ids 0x35, 0x64, 0x65, 0x67, 0x72 are above this client's 0..0x32 table, yet
  arrive here; a client has to ack them like any other. Ids 0x27 and 0x2b
  were not seen in any trailer (as in vr1).
- So the trailer is a real side channel: the SVLRoot values ride in it for
  the whole session, and the first exchange of VTE acks and host values
  after the stream starts happens here. A client that ignores it misses
  both.

### Unused tail

**vr1 suggested the rest of the message is zero, but vr3 shows it holds data.** After
the value records and VTE bytes there are 348 bytes (less the VTE bytes) up
to the 1024-byte end. They are all zero on only 559 of 8,631 descriptors. On
the other 8,072 they hold bytes that are no part of the protocol: the
content is unrelated to the frame, can repeat unchanged from one bookend to
the next, and looks like leftover host process memory (64-bit pointers, Windows FILETIME values, a
UTF-16 executable name). **inferred**: the host builds the descriptor in an
uninitialized 1024-byte buffer and fills only what it uses. A client must
stop parsing at the end of the counted sections and must not expect padding
to be zero. (Nothing from that tail is reproduced here.)

## Open questions / to confirm on the wire

1. `+0x14`: constant 1 over 8,631 descriptors of a real session - what makes
   it 0 (or 2)?
2. A descriptor resent in answer to a 0xffff request, and whether
   `bookend_index` then runs ahead of `group` (no request and no repeat in
   `vr3`; an unprompted repeat can now be ruled out for a clean link).
3. Timing-event records (`n_timing > 0`) - never seen in either capture;
   which host setting turns them on (`QSVLClient+0xc69` on the client side).
4. A host that sends `metadata_size` 0x154, and what the extra 0x64 bytes hold.
5. `+0x16`, `+0x18`, `+0x24` were constant (0, 0xffffffff, 0); meaning unknown.
6. Where the host's VTE data goes after the first 15 frames, if it has any
   (class 3 type 0x0d carried only 6 elements, all before the video).
