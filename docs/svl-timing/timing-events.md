# Timing events (`timingevent`)

Sources: `GetTimingEventString(timingevent)` +0x156890 and its table
`timingevent_strings` (data, vaddr 0x21f1b0, 108 pointers),
`SVLRoot::ReportTimingEvent(timingevent, int, int)` +0x164f84,
`QSVLClient::ReportTimingEventWithTimestamp(timingevent, int, int, int)`
+0xf7378, `QSVLClient::ReceivedBookend(SVLVideoFrameDescriptor_t*)` +0xf6cf8.
All **static** unless marked.

Timing events are a shared host/client vocabulary of "this happened at time
t" marks. The prefix of each name says who raises it: `SC` server compositor
(custom), `SR` server render, `SE` server encode, `SN` server network, `CN`
client network, `CR` client render.

## How they travel

- **Client-raised events stay on the client.** `ReportTimingEvent` (only when
  the debug flag `SVLRoot+0xc69` is set) stamps the event with the local
  timestamp and calls `ReportTimingEventWithTimestamp`, which stores
  `{u8 event, u8 arg, i32 time}` in a 512-entry ring for the debug overlay and
  formats a log line `"<name> # dtime=%d"`. No client→host timing-event
  message was found, and **captured** (`vr3`): the client sent only four
  kinds of element in 40 s (pose, key/value, frame report, class 3 type
  0x11), none of them a timing-event carrier. What the client does send per frame is the fixed report
  in [frame-reports.md](frame-reports.md).
- **Host-raised events arrive in the tail of the video frame descriptor
  ("bookend")**, below.

## Host events in the bookend tail

`GetEndOfPacketFromVideoDescriptor(desc)` returns a pointer `T` to a
variable-length tail (how `T` is located inside `SVLVideoFrameDescriptor_t` is
in docs/svl-video/). `QSVLClient::ReceivedBookend` parses it as:

| off from T | type | field |
|---|---|---|
| 0x00 | 6 bytes | haptic record, hand 0 (only used when host version < 5): `u8 ?, u8 amplitude(/255), u16 frequency(×0.5 Hz), u16 duration(/10000 s)` |
| 0x06 | 6 bytes | haptic record, hand 1 (same layout) |
| 0x0c | u8 | tail version; the rest is parsed only when this is **3** |
| 0x0d | u8 | `nValues`: number of 32-byte `TransportValue_t` records (the SVLRoot key/value channel, docs/svl-values/) |
| 0x0e | u8 | `nEvents`: number of 8-byte timing-event records |
| 0x0f | u8 | `nVteBytes`: length of an embedded ValueTransportSystem message |
| 0x10 | 32 × nValues | `TransportValue_t[]` → `SVLRoot::ParsePeerValueSettings` |
| … | 8 × nEvents | timing-event records (below); only read when the debug flag `SVLRoot+0xc69` is set |
| … | nVteBytes | → `ValueTransportSystem::RXMessage` |

`SVLRoot::FillInBookend` +0x165988 (the sender-side counterpart in this
binary) returns `T − desc + 0x10`, i.e. a descriptor with an empty tail is
`T + 16` bytes long.

Timing-event record (8 bytes):

| off | type | field |
|---|---|---|
| 0 | u8 | `timingevent` id |
| 1 | u8 | argument 1 (frame id low byte, by the format strings — **inferred**) |
| 2 | u16 | argument 2 |
| 4 | i32 | host timestamp (µs, host clock) |

The client converts the timestamp to its own clock
(`ts + off − (off + peer_off)/2`, see [clock-sync.md](clock-sync.md)) and feeds
the record to `ReportTimingEventWithTimestamp`. One event has a side effect:
id **0x24** (`SE Encode Data Wait Complete`) increments the "host generated a
frame" counter for the display slot the converted time falls in
(the same bookkeeping as `GotNoteFromServerThatFrameWasGenerated` +0xf6fd4).

## The enum

| id | name / format | id | name / format |
|---|---|---|---|
| 0x00–0x0f | `SC Custom 0..3 %d` (pattern repeats four times) | 0x36 | `SN SendBookend3 %d` |
| 0x10 | `SR Release Postpresent %d` | 0x37 | `SN SendBookend4 %d` |
| 0x11 | `SR Submit Layer 0 %d` | 0x38 | `SN SendBookend5 %d` |
| 0x12 | `SR Submit Layer 1 %d` | 0x39 | `SN SendBookend6 %d` |
| 0x13 | `SR Submit Layer 2 %d` | 0x3a | `SN SendBookend7 %d` |
| 0x14 | `SR Submit Layer N %d` | 0x3b | `SN SendBookendN %d` |
| 0x15 | `SR Present %d` | 0x3c | `SN SendProcessRetry nr=%d` |
| 0x16 | `SR Preesnt Done %d` (sic) | 0x3d | `SN SendDone %d` |
| 0x17 | `SR PostPresent %d` | 0x3e | `SN SendAudio %d` |
| 0x18 | `SR PostPresent Hold %d` | 0x3f | `SN Unknown1 %d` |
| 0x19 | `SR WGP Acquired %d` | 0x40 | `CN Send WaitGetPoses0 %d` |
| 0x1a | `SR WGP Failed %d` | 0x41 | `CN Send WaitGetPosesN %d` |
| 0x1b–0x1f | `SR Unknown2..6 %d` | 0x42 | `CN Req Retransmit nr=%d` |
| 0x20 | `SE Start Encode %d` | 0x43–0x4b | `CN Got Bookend0..8 %d` |
| 0x21 | `SE End Encode %d` | 0x4c | `CN Got Complete Frame %d` |
| 0x22 | `SE Perform Encode %d` | 0x4d–0x4f | `CN Unknown0 / Unknown1 / Unknown 2 %d` |
| 0x23 | `SE Wait For Encode Data %d` | 0x50 | `CR WaitGetPoses Up %d` |
| 0x24 | `SE Encode Data Wait Complete %d` | 0x51 | `CR Render VSYNC Done %d` |
| 0x25 | `SE Submit Compressed Data %d` | 0x52 | `CR Render Done %d` |
| 0x26 | `SE Data Copy %d` | 0x53 | `CR Flip Frame Start %d` |
| 0x27 | `SE Data Copy Done %d` | 0x54–0x56 | `CR Render Eye0 Start / Render / Submit %d` |
| 0x28 | `SE Encode %d Time(us)=%d` | 0x57–0x59 | `CR Render Eye1 Start / Render / Submit %d` |
| 0x29 | `SE Throttle Check 3 %d` | 0x5a | `CR Render Debug %d` |
| 0x2a–0x2f | `SE Unknown 4..9 %d` | 0x5b | `CR Got Cursor %d` |
| 0x30 | `SN Got WaitGetPoses0 %d` | 0x5c | `CR Roll Skip %d` |
| 0x31 | `SN Got WaitGetPosesN %d` | 0x5d | `CR Roll Double %d` |
| 0x32 | `SR Start Send Frame Data %d` | 0x5e | `CR Roll Norm %d` |
| 0x33 | `SN SendBookend0 %d` | 0x5f | `CR Rephase %d` |
| 0x34 | `SN SendBookend1 %d` | 0x60–0x63 | `CR Render Custom5..8 %d` |
| 0x35 | `SN SendBookend2 %d` | 0x64–0x6b | `SN Debug Mark A..H %d` |

Ids ≥ 0x6c format as `Unknown Event [id=%d]`.

Events this pass saw the client raise, with their argument:

| id | raised in | argument |
|---|---|---|
| 0x40 / 0x41 | `SendPoses` after submit | frame index |
| 0x50, 0x51 | `OnTopOfFrame` entry / exit | frame index |
| 0x52 | `OnRenderComplete` | frame index |
| 0x5e | `PhaseEventControlLoop`, `AdjustPhaseOffset` | −step (µs) / delta |
| 0x5f | `PhaseEventDecodeComplete` | phase error (µs) |

The names `SN Got WaitGetPoses*` show the host thinks of the client's pose
packet as the client's "WaitGetPoses" call, and `SN SendBookend0..7/N` that a
frame's descriptor is sent several times ("bookends"), matching
`CN Got Bookend0..8` on the client (see docs/svl-video/).

## Confirmed against capture `vr3`

All 8,631 frame descriptors of `vr3` (40 s, real client, SteamVR host
reporting descriptor version 14) were parsed with the layout above. Every
descriptor is a fixed 1,024-byte element (1,016-byte value) with the short
0xf0 metadata, so `T` is at dataset offset 0x28 + 0xf0 = 0x118 and the tail
region is 744 bytes long.

- **captured**: `T+0x0c` (tail version) is 3 in 8,631 of 8,631.
- **captured**: the two haptic records (`T+0x00..0x0b`) are all zero in every
  descriptor, as expected for a host version ≥ 5.
- **captured**: `nValues` is 4 in every descriptor: 34,524 `TransportValue_t`
  records, 51 distinct keys, cycling through the host's table (its per-frame
  keys recur every other frame, an echoed client key about every 0.23 s).
- **captured**: **`nEvents` is 0 in every descriptor.** This production host
  never sent a timing-event record, so the 8-byte record layout and the 0x24
  side effect remain **static** only.
- **captured**: `nVteBytes` is 0 in 8,602 descriptors and 224 (12), 244 (1) or
  252 (16) in the other 29; in all 29 the bytes parse as whole
  ValueTransportSystem records ending exactly at `nVteBytes`.
- **captured**: the three counts account for the *used* part of the tail
  (`0x10 + 32·4 + nVteBytes` = 144…396 bytes) but not for the element's
  length: the remaining 348…600 bytes are not described by anything and are
  **not zero** in 8,072 of 8,631 descriptors — they hold what looks like
  stale host memory, unrelated to the stream. A parser must stop at the
  counts and ignore the rest; the vr1 pass's "zero-padded to the end"
  (docs/svl-video/) does not hold.

## Open questions

- Whether any host build or debug setting produces `nEvents > 0` (none in
  `vr3`). A client must still step over `8·nEvents` bytes to find the
  embedded VTE message.
- Whether the client is expected to send any timing events upstream (none
  found statically, none sent in `vr3`).
- Meaning of byte 0 of each haptic record, and haptic delivery for host
  version ≥ 5 (docs/svl-tracking-input/).
