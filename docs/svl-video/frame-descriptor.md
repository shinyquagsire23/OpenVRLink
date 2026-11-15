# Frame descriptor ("bookend"): `SVLVideoFrameDescriptor_t`

`SVLVideoFrameDescriptor_t` is sent from host to client as message kind 5,
type 2 (`SVST_VIDEO_TRANSPORT_DESCRIPTION`). The struct covers the entire
message *including* the 8-byte `dataset` header: `vrlink` passes the `dataset*`
directly as the descriptor pointer and reads descriptor fields at offsets >= 8
(**static**: `SVLFEC::AcceptVideoPacket` +0x160684 reads the frame size from
`dataset+0x10`, and `SVLFECRXFrame::Initialize` +0x15f6f4 reads metadata from
`desc+0x28`).

`vrlink` calls this message a "bookend" because one is sent before the frame's
data packets and another after every group of 64 data packets; the receive path
logs `"CN Got Bookend%d"` and the transmit path logs `"SN SendBookend%d"`
(`0..8` and `N`).

## Layout

Offsets below are measured from the start of the `dataset` message. "TX writes"
describes what `SVLFECRAID6TXFrame::InitializeAndSend` (+0x1617a4) writes
(**inferred** for the host), and "RX use" describes what `vrlink` reads
(**static**).

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
| 0x14 | u8 | `flag` | the `bool` argument of `SVLFEC::SendData(data, size, metadata, bool)` | not read by `vrlink` |
| 0x15 | u8 | `fec_mode` | `SVLFEC+0xc20`, constructed as 0x20 | compared with `SVLDataLink+0x18`; a difference logs `"SVLDataLink::HandleFECChange( %d )"` and stores it. No behavior changes, since only one FEC mode exists in this build |
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

- For `len`, the TX code initializes the field to `0x3f8` and calls the virtual
  `FillInBookend(desc)` before each send. On the client side,
  `SVLRoot::FillInBookend` (+0x165988) returns `0x28 + metadata_size + 0x10`
  (the size with an empty trailer) without writing it back to `len`.
  **captured** (see below): the host also leaves `len` at `0x3f8`, making every
  descriptor a fixed 1024-byte message. Bytes past the trailer are not zeroed;
  see "Unused tail" below.
- `flag` at `0x14` is the only per-frame boolean passed down from the encoder.
  Its meaning is unknown; in `vr3` (**captured**) it is `1` on every frame, so
  it does not mark keyframes.
- The `version` field gates three client behaviors (all **static**):
  - `< 5`: legacy haptics are read from the trailer (below).
  - `> 5`: the renderer reports `FrameHasBeenSubmittedForDisplay` and replaces
    the predicted display time with the frame's own (`QSVLRendererXR::FlipFrame` +0x10ae78).
  - `>= 9`: frames are selected by display time (`ServeBestHardwareBuffer`)
    rather than FIFO order (`ServeNextHardwareBuffer`).

## Client descriptor handling

`SVLFEC::AcceptVideoPacket` and `SVLFECRXFrame::AcceptVFD` process each
arriving descriptor in six steps (**static**):

1. Ignore the descriptor if `frame_id` is already accepted or submitted and the
   slot already has a descriptor.
2. Call `SVLRoot::ReceivedBookend` (virtual, resolving to
   `QSVLClient::ReceivedBookend`) to parse the trailer on every bookend,
   including repeats.
3. If the slot holds a different frame, call `Initialize(frame_id, frame_size,
   desc)` to clear the packet bitmap, acquire a decoder input buffer, and
   invalidate the metadata history entry for this present number.
4. On the first descriptor received for the frame, call
   `SVLRenderer::AcceptFrameMetadata(desc+0x28, 1)`, copy `0x154` metadata
   bytes into the slot, record `present_number & 0x7f -> frame_id`, and set
   `frame_size` from `+0x10`. If the slot has no input buffer or the frame was
   already accepted, log `"[SVLFEC] received late metadata for frame [ %d ]"`
   and continue.
5. If `group` exceeds the highest group seen so far for this frame, call
   `CheckRetry(group)` to request any missing packets from earlier groups
   ([retransmit.md](retransmit.md)).
6. Call `CheckRXComplete()`.

## Trailer

The trailer begins at `E = desc + 0x28 + metadata_size` and is parsed by
`QSVLClient::ReceivedBookend` (+0xf6cf8, **static**).

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

- The two haptic records are read only when `version < 5`. Each is delivered
  through the same virtual (`vtable+0xe0`) that handles kind-3 type-`0x16`
  haptic messages, formatted as `{float freq_hz, float duration_s, float
  amplitude, i32 local_time, u16 0, u8 hand}` with `hand = 0` then `1`. Zero
  frequency or zero amplitude clears the record; zero duration becomes
  frequency `0`, duration `0.004 s`. With `version = 14` (**captured**), this
  legacy path is inactive and haptics arrive as standalone messages
  (`docs/svl-tracking-input/`).
- Each timing-event record has layout `{u8 event, u8 arg, u16 id, i32
  host_time}`. `vrlink` parses these only when `QSVLClient+0xc69` is set,
  converting each timestamp to local time and passing it to
  `ReportTimingEventWithTimestamp` (event `0x24` also updates a 512-bin phase
  histogram; see `docs/svl-timing/`).
- In addition to describing the video frame, bookends piggyback `SVLRoot`
  values and `ValueTransportSystem` chunks at frame rate without separate
  datagrams. A client must feed trailer VTE bytes into the same parser used for
  kind-3 type-`0x0d` messages so it does not miss value updates or fail to
  acknowledge them.

## Captured

`vr3` (not in the repo) contains **8,631 intact descriptors** covering 4,260
frames. Everything in this section is **captured**. (The earlier `vr1` capture
had 78 intact descriptors and agrees with `vr3` except where noted.)

### Descriptor count and placement

- The host sends `1 + n_group` descriptors per frame: bookend 0 before the
  first data packet, and bookend `g+1` after the parity packets of group `g`
  (see [packets.md](packets.md) for the full send order). Counts by group
  number across `vr3` are `0` x4260, `1` x4259, `2` x68, `3` x42, `4` x1, and
  `5` x1—totaling 8,631 out of 8,632 expected descriptors, with frame 8's
  closing bookend lost on the wire.
- **No bookend is repeated**: no `(frame, group)` pair appears twice, and the
  single lost closing bookend was not resent. Because `vrlink` sent no
  retransmit requests in `vr3`, a descriptor resent in response to a `0xffff`
  request was not observed here.
- Within a frame, all bookends carry identical `tx_time`, `peer_clock`,
  `frame_size`, and `0xf0`-byte metadata fields (all 4,371 subsequent bookends
  match bookend 0 across all four regions). Only the trailer differs on each
  bookend, carrying the next four value records.

### Header fields across all 8,631 descriptors

| Off | Captured |
|---|---|
| 0x04 `len` | **0x3f8 on all**. Every descriptor is a fixed 1024-byte message; parsers must use the item counts in the trailer rather than `len` to find the end of valid data |
| 0x06 `group` / 0x1c `bookend_index` | equal on all 8,631; values 0..5 |
| 0x08 `tx_time` | host clock, microseconds. Same on every bookend of a frame, so it is stamped once per frame. Frame-to-frame difference: median 9.20 ms (distribution in [packets.md](packets.md)); the span over the run (39.327167 s) matches the span of arrival times on the client clock (39.327784 s) to 0.6 ms. It is 1.7 .. 53 ms earlier than the metadata `display_time` of the same frame (1 % 20.0, median 26.3, 99 % 52.5 ms) |
| 0x0c `peer_clock` | 1,034 distinct values over 4,260 frames, all within a 1.18 ms range, drifting slowly; constant within a frame |
| 0x10 `frame_size` | equals the reassembled frame and the decoder access-unit size on all 4,260 frames |
| 0x14 `flag` | **1 on all 8,631**, including both IDR frames (0 and 4), the 9 single-packet frames, and the 284 kB frame. It does not indicate keyframes or frame size classes; meaning remains unknown |
| 0x15 `fec_mode` | 0x20 on all |
| 0x16 | 0 on all |
| 0x18 | 0xffffffff on all |
| 0x1d | 0 on all |
| 0x1e `metadata_size` | **0xf0 on all** - the short form. The trailer therefore starts at message offset **0x118** |
| 0x20 `version` | **0x0e (14) on all**, compared to 9 in `vrlink`'s shared TX code. All three version checks (`< 5`, `> 5`, `>= 9`) take the newer branch: trailer haptics are off and display-time selection is enabled |
| 0x24 | 0 on all |

Because `metadata_size` is `0xf0` while `vrlink` unconditionally copies `0x154`
bytes into its metadata struct, the last `0x64` bytes of `vrlink`'s copy come
from the start of the trailer. `vrlink` never reads past `+0xee`, so those
extra bytes are harmless, though a new implementation should copy only `0xf0`
bytes (or `metadata_size`).

### Trailer, at message offset 0x118 (payload offset 0x110)

| Off from E | Captured, over all 8,631 |
|---|---|
| 0x00..0x0b (haptics) | all zero on all |
| 0x0c `trailer_version` | 3 on all |
| 0x0d `n_values` | 4 on all |
| 0x0e `n_timing` | **0 on all** - no timing-event record in 8,631 bookends of a 40 s session |
| 0x0f `n_vte_bytes` | 0 on 8,602; non-zero on 29: 252 (x16), 244 (x1), 224 (x12) |
| 0x10 | `n_values` x 32-byte value records, immediately followed by `n_vte_bytes` of ValueTransportSystem data. The VTE bytes parse to `n_vte_bytes` on all 29 |

- Each 32-byte value record consists of a 20-byte NUL-padded name, a `double`
  at `+20`, and a `u32` timestamp at `+28` on the same host clock as `tx_time`
  (median 4.6 ms older than the bookend's `tx_time`). Every bookend carries
  four records, spanning **51 distinct key names** over the run in three
  groups: 19 client `c*` keys echoed back (such as `cRXpass`, `cPingMS`,
  `cFramePhase`, `cAudBufAvg`), host-prefixed keys (`d*`, `s*`, `dbg*`,
  `enc*`, `n*`, `tsLastWGP`, `txTimeMS`), and two unprefixed timers (`GetData`,
  `StartNvEnc`). Scheduling is uneven: nine per-frame keys fill most slots
  (`dCurBW` 4,425 records, `dEstLinkBW` 4,423, `GetData` 4,406, `StartNvEnc`
  4,227, `dHitchMaxBW` 3,690, `dProblemBW` 3,203, `dFrmsEarly` 1,261,
  `dFrmsLate` 682, `dRunStart` 670), whereas each of the other 42 keys appears
  168..254 times—refreshed roughly once every 35..50 bookends (4 to 6.5 times
  per second) whether it changed or not. In 504 bookends, the same key name
  appears twice. See `docs/svl-values/` for the record format and key
  meanings. Three keys bear directly on the video layer: `cRXpass` (echo) and
  `sRXpass` were `100` in every sample, and `encResets` stayed at `3` across
  all 170 samples (starting 0.18 s after frame 0), so neither IDR in the run
  incremented it after that point.
- VTE bytes appear in the trailer **only at stream startup**: the 29 bookends
  with non-zero `n_vte_bytes` all belong to frames `0..14` (the first 143 ms).
  The remaining 8,602 bookends carry none, so after startup any host VTE
  traffic either used another channel or did not occur (`docs/svl-values/`).
  Those 29 trailers contained the following VTE elements:

  | Element | Count | Notes |
  |---|---|---|
  | ack, ids 0x0d / 0x0e / 0x0f | 189 / 264 / 260 | both bookends of frames 0..7: only acks, 63 per trailer (252 bytes), repeating the same ids as the host fills the remaining space with acks for the client's values. Bookend 0 of frame 8: 17 more acks, then the first four data values below (244 bytes) |
  | ack, id 0x05 | 104 | same bookends |
  | ack, ids 0x10, 0x11, 0x12, 0x15, 0x18, 0x20, 0x22, 0x23 | 26 each | same bookends |
  | data id 0x06, version 1, 32 bytes | 13 | both bookends of frames 9..14: the same nine data elements in each, 224 bytes, no acks; plus once in frame 8 |
  | data id 0x17, version 1, 104 bytes | 13 | |
  | data id 0x1c, version 1, 4 bytes | 13 | |
  | data id 0x29, version 2, 4 bytes | 13 | |
  | data id 0x35, version 1, 4 bytes | 12 | frames 9..14 only |
  | data id 0x64, 0x65, 0x67, 0x72, version 1, 1 byte | 12 each | |

  Ids `0x35`, `0x64`, `0x65`, `0x67`, and `0x72` exceed `vrlink`'s `0..0x32`
  table yet still arrive here; a client must acknowledge them like any other
  VTE id. Ids `0x27` and `0x2b` did not appear in any trailer (matching `vr1`).
- Bookend trailers therefore act as an active control channel: `SVLRoot` values
  are carried in them throughout the session, and the initial VTE
  acknowledgments and host configuration values arrive there right after video
  starts. A client that ignores the trailer misses both.

### Unused tail

**`vr1` suggested the rest of the message was zero, whereas `vr3` shows it
contains uninitialized data.** After the value records and VTE bytes, `348 -
n_vte_bytes` bytes remain up to the end of the 1024-byte message. That tail is
all zero on only 559 of 8,631 descriptors. On the remaining 8,072 descriptors,
it holds bytes that are not part of the protocol: the data is unrelated to the
video frame, can repeat unchanged across consecutive bookends, and resembles
leftover host process memory (64-bit pointers, Windows `FILETIME` values, and a
UTF-16 executable name). **inferred**: the host builds descriptors in an
uninitialized 1024-byte buffer and populates only the active prefix. A client
must stop parsing at the end of the counted sections and must not expect
zero-padded trailing bytes. (None of that tail data is reproduced here.)

## Open questions / to confirm on the wire

1. What causes `flag` at `+0x14` (constant `1` across all 8,631 descriptors in
   `vr3`) to take `0` (or another value)?
2. What a descriptor resent in response to a `0xffff` request looks like, and
   whether `bookend_index` advances ahead of `group` when resent (`vr3` had no
   retransmit requests and no unprompted repeats on a clean link).
3. Which host setting enables timing-event records (`n_timing > 0`, gated by
   `QSVLClient+0xc69` on `vrlink`), since none appeared in either capture.
4. Under what conditions a host sends `metadata_size == 0x154`, and what the
   extra `0x64` bytes contain.
5. What the constant fields at `+0x16` (`0`), `+0x18` (`0xffffffff`), and
   `+0x24` (`0`) represent.
6. Where host VTE updates go after the first 15 frames if values change
   mid-session (kind 3, type `0x0d` carried only 6 elements, all before video
   started).
