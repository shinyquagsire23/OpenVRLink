# The pose packet (`QSVLClient::SendPoses`)

Client → host, message type `0x01`, unreliable. Built entirely in
`QSVLClient::SendPoses(int nSub, int nFrameID)` (0xf4d34). Everything in the
layout table is **static** from that function unless marked.

## When it is sent

- **static**: `QSVLClient::HandleEvent` (0xf4bec), event type 0:
  `SVLRoot::SendValues(3)` then `SendPoses(arg & 0xf, arg >> 4)`. So the event
  argument packs `frame_id << 4 | sub_index`.
- **static**: log strings — sub index 0 logs
  `[SVLC] SendPoses: lnFrameID=%d(%d) (mod64=%d) (mod256=%d) rst=%d toff=%d`,
  non-zero logs `[SVLC] SendPoses lnFrameID=%d(%d)`.
- **static**: after sending it reports timing event `0x40` (sub index 0) or
  `0x41` (sub index ≠ 0) with the frame id (`SVLRoot::ReportTimingEvent`).
- **captured** (`vr3`): four packets per frame id, sub index 0, 1, 2, 3 in
  that order, a quarter of the frame time apart; see "Capture check". Who
  posts event 0 belongs to docs/svl-timing/ (event-schedule.md).

Order of work inside one call (**static**, vtable of `QSVLClientXR` read at
0x210660):

1. `ReadyForInputSync()` (slot 0x160 → 0xfb868) = `xrSyncActions`.
2. Zero a 0x2e4-byte buffer; write header and timestamps.
3. `GetHmdPose()` (slot 0x140) into the HMD pose block.
4. Unless the "no input" flag `this+0x3eb8` is set: `GetHmdInput()` (slot
   0x148), then `GetInput()->GetControllerStates(states, version)` and pack
   both hands. With the flag set, both controller blocks and both controller
   poses stay zero.
5. `ValueTransportSystem::TickUpdate(buf + 0x170, 0x174)` appends pending VTE
   chunks/acks; its return value is the VTE byte count.
6. `SVLDataLink::SendLastRXID()`, then `SubmitMessage(msg, false, true)`.
7. If `SVLRoot::BIsConnectionActive()`: `HandleEyeInput()` (slot 0x150) and
   `HandleHandTracking()` (slot 0xe8) send their own messages
   ([eye-face.md](eye-face.md), [skeleton.md](skeleton.md)).

## Layout

Offsets from the start of the `dataset` (payload begins at 0x08). Total size
= 0x170 + VTE bytes (max 0x170 + 0x174 = 740).

| off | size | type | field | notes |
|---|---|---|---|---|
| 0x00 | 1 | u8 | `0x03` | message class |
| 0x01 | 1 | u8 | `0x01` | message type |
| 0x02 | 2 | u16 | 0 | |
| 0x04 | 2 | u16 | payload length = `0x168 + vte_len` | |
| 0x06 | 2 | u16 | 0 | |
| 0x08 | 1 | u8 | constant `0x0a` (10) | **inferred**: pose-packet layout version |
| 0x09 | 1 | u8 | sub index (`nSub`, 0..15) | |
| 0x0a | 1 | u8 | constant `0x20` (32) | **inferred**: unknown; possibly a size or capability byte |
| 0x0b | 1 | u8 | holdoff flag: atomic read of `this+0xf0`; non-zero logs `[SVLClient] Client requested holdoff` | **inferred**: asks the host to hold off rendering/sending (e.g. client not ready) |
| 0x0c | 4 | i32 | `toff` = `this+0xc7c`, the client's current clock offset estimate (written only by `SVLRoot::SymmetricTimingUpdate` 0x165a38) | µs; semantics in docs/svl-timing/ |
| 0x10 | 4 | i32 | `GetCurrentTimestamp()` taken *after* VTE packing, i.e. transmit time | µs |
| 0x14 | 4 | i32 | `GetCurrentTimestamp()` taken at the start of the call, before input is sampled | µs |
| 0x18 | 4 | i32 | per-frame target time, read from client state when the packet is built. If host protocol version > 5: `this+0xcbc`, which `QSVLClient::OnTopOfFrame` (0xf6270) sets to `now + its first argument` (µs until the frame's predicted display time). Else `this+0x3e20`, the anchor time of the most recently scheduled pose batch | µs, same clock as 0x10/0x14. One value per frame, not per sample: see "The target-time field" below |
| 0x1c | 4 | i32 | frame id (`nFrameID`) | |
| 0x20 | 2 | u16 | `rst` = low 16 bits of `this+0xe04`, a counter incremented by `QSVLClient::HandleUnrecoverableError` (0xf4bdc) | **inferred**: tells the host the decoder needs a reset / IDR when it changes |
| 0x22 | 14 | `PackedHmdInput_t` | HMD buttons | below |
| 0x30 | 28 | controller input | left hand | [controllers.md](controllers.md) |
| 0x4c | 28 | controller input | right hand | |
| 0x68 | 88 | `PackedPose_t` | HMD | below |
| 0xc0 | 88 | `PackedPose_t` | left controller / hand | copied from `QSVLControllerState[0]+0x20` |
| 0x118 | 88 | `PackedPose_t` | right controller / hand | copied from `QSVLControllerState[1]+0x20` |
| 0x170 | 0..372 | bytes | ValueTransportSystem stream (same encoding as a type-`0x0d` body) | docs/svl-values/ |

`GetCurrentTimestamp()` (0x155cb0) is a 32-bit signed microsecond counter:
**static**, `clock_gettime(4 /* CLOCK_MONOTONIC_RAW */)` then
`(int)tv_sec * 1000000 + tv_nsec / 1000`, i.e. the low 32 bits of the
monotonic clock in µs. It wraps every 4295 s (71.6 min). **captured** (`vr3`):
the 0x10 transmit time tracks the capture's own `CLOCK_MONOTONIC` datagram
timestamp at a constant offset (capture µs + 1,455,028, mod 2^32) to within
−0.10..+0.24 ms for 99 % of packets (worst 7.3 ms), drifting +0.2 ms over the
40 s. So every time field in this packet can be compared directly with capture
timestamps.

"Host protocol version" is the atomic int at `SVLRoot+0xba8`. **static**:
`QSVLClient::ReceivedBookend` (0xf6d38) stores `*(u32*)(SVLVideoFrameDescriptor_t+0x20)`
there, so the client learns it from the video bookend; it is 0 until the first
bookend. It gates the 0x18 field here (`> 5`) and hand-tracking-as-controller
(`>= 7`, [controllers.md](controllers.md)).

### `PackedPose_t` (88 bytes)

**static**: `QSVLDeviceHmd::GetPose` (0x1015e4) for the HMD,
`QSVLXRInput::GetControllerState_Controller` (0x10722c) and
`GetControllerState_HandTracking` (0x107ca4) for hands. All floats are IEEE
single, OpenXR conventions (right-handed, −Z forward, meters, radians/s).

| off | type | field |
|---|---|---|
| 0x00 | f32×3 | position x, y, z in the play space (reference space index 1 for the HMD — **inferred** LOCAL/STAGE; controllers use `mapReferenceSpaceSpaces[playSpace]`) |
| 0x0c | f32 | orientation **w** |
| 0x10 | f32×3 | orientation x, y, z |
| 0x1c | f32×3 | linear velocity (from `XrSpaceVelocity`, chained to `xrLocateSpace`) |
| 0x28 | f32×3 | angular velocity, see note |
| 0x34 | u16 | tracking result: `200` when orientation and position are both valid (`locationFlags & 3 == 3`), else `1`. HMD always writes 200. **inferred**: OpenVR `ETrackingResult` (`Running_OK` = 200, `Uninitialized` = 1) |
| 0x36 | u8 | state: `0` = pose action inactive / no device, `1` = located but not fully valid, `2` = valid. HMD always 2 |
| 0x37 | u8 | 0 (padding) |
| 0x38 | f32×3 | offset position (identity pose 0,0,0 for the HMD) |
| 0x44 | f32 | offset orientation **w** (1.0 for the HMD) |
| 0x48 | f32×3 | offset orientation x, y, z |
| 0x54 | u32 | 0 |

Notes:

- **Sample time, static**: every pose is located at `XRQGetTimeNow()`, *not*
  at a predicted display time. The client does no prediction for controllers
  or HMD; it ships velocities and timestamps and leaves extrapolation to the
  host. (Hand joints are the exception: located at now + 30 ms,
  `XRQLocateHandJoints(..., now + 30000000, ...)`.)
- **Angular velocity frame, static**: the value from OpenXR is rotated by the
  conjugate of the pose orientation (`q⁻¹ · ω · q`), i.e. converted from
  space-frame to body-local, *except* on specific runtimes: the branch is
  skipped when `XRQContext+0xa0 == 3 && runtimeVersion >> 49 == 0`, and for the
  HMD also when `XRQContext+0xa0 == 2 && versionWord(+0x1e) < 0x7f`.
  **inferred**: those runtimes already report body-local angular velocity; a
  new client should always send body-local.
- **Offset pose, static**: for controllers the 7 floats at 0x38 come from a map
  keyed by the active interaction-profile `XrPath`, one 28-byte `XrPosef` per
  hand; it is filled from `poseAction.<profile>.offset` in
  `assets/config/controller_config.json` (position in meters, rotation in
  degrees about x/y/z; e.g. Touch: position (−0.007, −0.03416, −0.09607),
  rotation x = −20.6°). **inferred**: the host composes `pose ∘ offset` to get
  the SteamVR device pose from the OpenXR grip pose. Whether the left hand's
  offset is mirrored in x is decided where the map is built
  (`QSVLXRInput::Init` 0x104280), not read here.
- When a controller is absent the client writes only `0x34 = 1`, `0x36 = 0`
  and leaves the rest of the pose as it was zeroed.

### `PackedHmdInput_t` (14 bytes at 0x22)

**static**: initialized in `SendPoses`, filled by `QSVLDeviceHmd::GetInput`
(0x1014f4).

| off | type | field |
|---|---|---|
| 0x00 | u32 | constant 9 |
| 0x04 | u64 | 0 |
| 0x0c | u8 | flags: bit1 = `DeviceInput::GetInput(0x19)`, bit2 = `DeviceInput::GetInput(0x18)`, bit3 = *no* controller/hand produced a state this frame (`XRQContext+0xfa == 0`, written by `GetControllerStates`) |
| 0x0d | u8 | `0xff` |

**inferred**: 0x18/0x19 are Android key codes 24/25 (`KEYCODE_VOLUME_UP` /
`KEYCODE_VOLUME_DOWN`), so bit2 = volume-up held, bit1 = volume-down held.
Bit0 and the constant 9 are unexplained (**inferred**: 9 could be a proximity /
"HMD worn" default or a struct version).

## Capture check (`vr3`)

Evidence class **captured** for everything in this section unless marked.
`vr3` is 40.3 s of one session of the real client under Klepton against a
SteamVR host showing the desktop view: a synthetic, motionless head, two
synthetic Touch controllers that never move and never press anything, no eye,
face or hand tracking, and a display advertised as 120 Hz (frame time
8333 µs). 17,423 pose datasets were parsed. Value *semantics* that need motion
or input are therefore still untested. Offsets below are dataset offsets, as
in the layout table.

An earlier check against the torn capture `vr1` (1637 pose datasets) is
superseded by this section; where the two disagree it is said so.

### Counts and framing

- The log records 17,446 pose-sized `sendto` calls on the SVL socket; the
  tracer wrote no hex dump for 23 of them, which is why 17,423 are parsed and
  why the outbound datagram sequence shows 23 gaps of one. These 23 are a
  capture artifact and not client behavior. 17,446 = 4 × 4361 + 2: four packets
  for each frame id 1..4361 plus two packets with frame id 0.
- Envelope `03 01`, element id and index both 0, length `360 + n`. The fixed
  block is exactly 0x168 bytes.
- `n` = 0 in 17,015 packets. The 408 packets with value-transport bytes
  (`n` = 36..371; the budget is 372) are all in the first 1.07 s: packets
  0..401 without a gap, then 456..459 and 461..462. See "Why the length
  varies".
- The pose dataset is the last element of its datagram. Datagram composition:
  `[3/0x11 eye] [3/0x07 values] [4/0x0f report] [3/0x01 pose]` in 17,020
  datagrams (537 bytes when `n` = 0), the same without the eye element in 401,
  and report + pose only in the first 2. No outbound SVL datagram in `vr3`
  lacks a pose dataset.

### Every fixed field over the session

| off | field | behavior in `vr3` |
|---|---|---|
| 0x08 | `0x0a` | constant in all 17,423 |
| 0x09 | sub index | 0, 1, 2, 3 (4357 / 4355 / 4355 / 4356) |
| 0x0a | `0x20` | constant in all 17,423 |
| 0x0b | holdoff | 0 in all |
| 0x0c | `toff` | 0 in packets 0..401; from packet 402 (0.930 s, the same moment the first video packet arrives, 0.926 s) a large negative value. 3,148 distinct values spanning 8.1 ms: it holds its first value for 0.11 s, falls 7.7 ms between 1.04 and 1.06 s, then climbs back a few µs at a time for the rest of the session, ending 0.4 ms above where it started. Semantics in docs/svl-timing/clock-sync.md |
| 0x10 | transmit time | strictly increasing; no wrap in this capture |
| 0x14 | sample time | 0x10 − 0x14 is 3..360 µs, median 5 µs, above 99 µs in 3 packets |
| 0x18 | target time | 0 in the two frame-id-0 packets; then one value per frame id. Detailed below |
| 0x1c | frame id | 0, then 1..4361, incrementing by one per frame: 108.3 frame ids per second |
| 0x20 | `rst` | **0 in every packet** |
| 0x22 | `PackedHmdInput_t` | `09 00 00 00`, eight zero bytes, flags, `ff`. Flags = 0x08 in packet 0 only, 0 in the other 17,422 |
| 0x30, 0x4c | controller input | all 28 bytes zero in both hands, every packet |
| 0x68 | HMD pose | identical 88 bytes in every packet: position (0, 1.6, 0), orientation (w,x,y,z) = (1, 0, 0, 0), both velocities zero, tracking result 200, state 2, identity offset pose, trailing u32 0 |
| 0xc0, 0x118 | controller poses | identical 88 bytes per hand in every packet, including packet 0: see [controllers.md](controllers.md) |

Corrections to the `vr1` reading:

- **`rst` did not move.** `vr1` showed it climbing 0 → 18; in `vr3` it is 0
  from the first packet to the last. (The client log has one
  `[SVLDecoder] Failed to acquire latest image!` at start-up and nothing
  about an unrecoverable error or a reset.)
  The host still sent its `[SVLS] ResetVideoStream` debug text once, 0.209 s
  into the session and 0.72 s before the first video packet
  ([events-prompts.md](events-prompts.md)), so that host message is not a
  reaction to `rst` changing. What a change of `rst` makes the host do is
  still untested; `vr3` only shows that a healthy session never changes it.
- **No "no input" packets.** `vr1` had 1020 of 1637 packets with zeroed
  controller blocks and HMD-input byte 0x0d = 0 (the `this+0x3eb8` path). In
  `vr3` no packet is in that form: the HMD input block ends in `ff` and both
  controller poses are populated from packet 0 on.
- **HMD-input bit3 lags by one packet.** Packet 0 has flags 0x08 ("no
  controller produced a state") yet carries two fully valid controller poses.
  **inferred**: `GetHmdInput()` runs before `GetControllerStates()` in the same
  call (steps 4 above), so the bit reports the *previous* call's result and is
  set once, before any state has been read. `vr1` also had it in exactly one
  packet.
- Sub indices and frame ids are orderly. `vr1` suggested unequal sub-index
  counts, frame-id jumps of 2 and more, and unordered sub indices; all of that
  was tearing. In `vr3` the frame id never skips, and within a frame id the
  sub indices always ascend.

### Cadence

- Mean packet interval 2.31 ms (432.8 packets/s captured, 433.4/s counting
  the 23 undumped sends); median 2.13 ms, p1 1.59 ms, p99 3.92 ms. One stall:
  68.6 ms without a pose packet at 1.17 s.
- Within a frame (frames from id 102 on) the sample times of sub 1, 2, 3 trail
  sub 0 by a median 2181 / 4265 / 6381 µs (p10..p90: 2076..2392, 4100..4435,
  6161..6524). The schedule in docs/svl-timing/event-schedule.md posts them at
  `ft // 4` steps, 2083 / 4166 / 6249 µs for the 8333 µs frame time, so the
  quarter-frame spacing is confirmed, with about 0.1 ms of lateness.
- Sub 0 to the next frame's sub 0 differs from the advertised 8333 µs: mean
  9244 µs, median 9.17 ms, p1 7.4 ms, p99 10.2 ms, eight intervals above
  15 ms. The frame id advances when the client's frame wait returns, and under
  Klepton that loop ran at 108.3 Hz against a nominal 120 Hz. The pose cadence
  follows the client's actual frame loop, not the negotiated frame time.
- When two frame waits return close together (here 0.1..1.8 ms apart) the
  two frames' batches interleave on the wire (`… 120/0, 121/0, 120/1, 121/1 …`): 10
  places where the frame id steps back by one, in frames 14/15, 116/117,
  120/121 and 126/127. A receiver must not assume frame ids are monotonic
  packet to packet.
- The two frame-id-0 packets (both sub 0, 0.2 ms apart, target time 0) open
  the session 4 ms before frame id 1. **inferred**: posted once at start-up
  before the first top-of-frame; the poster was not traced.

### Why the length varies

Every packet longer than 360 bytes carries value-transport bytes (docs/svl-values/)
at 0x170, and all 408 of them parse cleanly as chunk and ack records with the
`ovrlink.vts` framing (8-byte chunk header + up to 128 bytes, or a 4-byte
ack):

- Packets 0..15 (the first 30 ms): the client's values, each chunk sent once:
  ids 0x01, 0x04, 0x05, 0x08, 0x0d, 0x0e, 0x0f (1161 bytes each for the last
  three, ten chunks), 0x10..0x13, 0x15, 0x18, 0x20, 0x22, plus acks for the
  host's first values.
- Packets 16..32 (32..71 ms): everything except 0x13 is published again under
  the next version, id 0x0c and id 0x23 appear for the first time, and id
  0x05 moves on to a third version. The client log has
  `Server requested prop refresh` in this phase; what triggers the
  re-publication belongs to docs/svl-values/startup-exchange.md.
- Packets 33..401 (to 0.926 s): the host's last acknowledgement arrives at
  42 ms (it covers the second version up to chunk 2 of id 0x0d). Everything
  still unacknowledged (id 0x05 version 3, chunks 3..9 of 0x0d, all of 0x0e
  and 0x0f, 0x10, 0x11, 0x12, 0x15, 0x18, 0x20, 0x22, 0x23) is then repeated
  round-robin, two 128-byte chunks per packet in the common case (length
  632, 255 packets), each chunk 27 or 28 times in all. Nothing inbound
  acknowledges them during those 0.88 s: the only host→client `3/0x0d`
  messages are six in the first 42 ms.
- Packet 402, the first after video starts, has no value bytes: the
  repetition stops at once. Packets 456..462 (1.05..1.07 s) carry only acks
  (36 or 52 bytes) for host values 0x06, 0x17, 0x1c, 0x29, 0x35, 0x64, 0x65,
  0x67, 0x72, which the host delivers in video frame-descriptor trailers
  (docs/svl-video/).
- After 1.07 s no pose packet carries value bytes for the remaining 39 s.

So in a steady session the pose packet is always 360 bytes; the long ones are
the start-up value exchange riding along.

### `PackedPose_t`

- 88 bytes; the quaternion is **w first** (each pose is unit-norm only when
  read w,x,y,z; the Touch offset quaternion reads w = 0.9839, x = −0.1788 =
  −20.6° about x, matching `controller_config.json`).
- HMD: tracking result 200, state 2, identity offset pose (0,0,0 / 1,0,0,0),
  trailing u32 0. Controllers: 200 / 2.
- The offset position is **mirrored in x for the right hand**: left
  (−0.007, −0.0342, −0.0961), right (+0.007, −0.0342, −0.0961); the offset
  rotation is identical for both hands. The JSON value is the left hand's.

### The target-time field (0x18)

What the client writes (**static**, and now consistent with every capture and
with the probe): `SendPoses` does not compute this field. It copies a number
that the frame scheduler stored when the frame began, so all packets built
between two frame starts carry the same value. Which number depends on the
host protocol version the client has learned, and that is 0 until the first
video bookend arrives.

Before the first video (packets 2..401, frame ids 1..100): the values fit
the batch anchor `this+0x3e20`, the time at which sub 0 of the batch was
scheduled to be sent. (**inferred** link to the static gate: the host version
is still 0 here because no bookend has arrived.)

- Target − sample time, sub 0: median −203 µs (range −438..+105). The anchor
  is the moment sub 0 was due, so the field is slightly in the past by the
  time the packet is built. Sub 1: median −2334 µs. Sub 2: median −4385 µs.
- Sub 3 usually carries the **next** frame's anchor (+2.3..+3.5 ms ahead):
  78 of these 100 frame ids show two target values, the change falling at
  sub 3 in 75. In this mode the batch is delayed by the stand-off (published
  as `cStandoff` = 3500 µs), which puts sub 3 after the next frame wait has
  returned and overwritten the anchor.

After the first video (frame id 102 on, 17,017 packets): the values fit
`this+0xcbc` = top-of-frame time + the microseconds until that frame's
predicted display time.

| sub | target − sample time, µs: min / p10 / median / p90 / max |
|---|---|
| 0 | 6794 / 8185 / 8314 / 8323 / 8330 |
| 1 | 5617 / 5915 / 6111 / 6213 / 8014 |
| 2 | −255 / 3875 / 4038 / 4117 / 7736 |
| 3 | −1490 / 1786 / 1929 / 2027 / 8066 |

- At sub 0 the target is 8.31 ms ahead of the sample time and 8.31 ms ahead
  of the transmit time: that is 19 µs short of one 120 Hz period (8333 µs).
  **inferred**: Klepton's OpenXR runtime predicts display exactly one period
  after the frame wait returns and the 19 µs is the delay before the packet
  is built; a real headset's lead will differ. The lead then shrinks by a quarter period per
  sub index because the target stays put while the sample time advances.
- **Constant within a frame id**: 4253 of 4260 frame ids carry a single
  target value across all captured sub indices. The 7 exceptions (frame ids
  116, 120, 126, 1264, 2116, 2723, 2926) are frames whose later sub-packets
  were built after the next top-of-frame had already replaced the stored
  value (overlapping batches, or the event thread running 4..6 ms late); the
  late packets then carry the next frame's target.
- **Step between frames** (sub 0 of consecutive frame ids, n = 4247): mean
  9231 µs, median 9171 µs, standard deviation 1246 µs, p1 7428, p99 10,190,
  eight steps of 15..75 ms. It equals the step of the sub-0 sample time to
  within ±0.34 ms for 98 % of frames. Only 295 steps are within 0.1 ms of
  8333 µs. The target is therefore **not** an ideal vsync grid advancing by
  one refresh period; it is re-derived each frame as "frame wait returned +
  time to display" and inherits all of the frame loop's jitter.
- Frame id 101 (packets 402..405) is the hand-over: scheduled in the old mode,
  sent in the new one; its lead is +2.7 ms at sub 0.

Earlier notes: the `vr1` pass reported target − sample
between −46 ms and +8 ms with "one frame id usually maps to one target value,
sometimes two" and concluded the field was "not a consistent forward
prediction". The layout was right and the conclusion was wrong. **inferred**:
that capture mixed the pre-video anchor mode (slightly negative, two values
per frame) with the display-time mode, in a client running far from real
time with a third of its packets torn. `vr3` shows the field doing exactly what the
static reading says: a per-frame reference, the frame's predicted display
time once video is flowing. That is also what the probe found the host to
need (see "Probe results" below): the host treats 0x18 as a per-frame value,
and the real client keeps it fixed across the four sub indices of a frame id
in 99.8 % of frames. The probe's two working choices, frame start and frame
start + one period, correspond to the real client's two modes.

### Not exercised by `vr3`

Velocities (all zero), any pose change, button/touch/axis bits (all zero),
byte 0x10 of the controller blocks (0), the angular-velocity frame, holdoff,
a change of `rst`, "no input" mode, an absent controller, hand tracking.

## Open questions / to confirm on the wire

- Meaning of bytes 0x08 (`0x0a`) and 0x0a (`0x20`): constant over 17,423
  packets in `vr3`. Probe by changing them and watching whether the host
  still tracks. (**inferred**, weak: 0x20 is also the value of the video
  descriptor's `fec_mode` and of the client's `HandleFECChange( 32 )` log
  line; whether that is more than a coincidence is unchecked.)
- 0x20 `rst`: never changed in `vr3`. Bump it in a probe and see whether the
  host sends an IDR or a `ResetVideoStream`.
- Whether the host needs body-local or space-frame angular velocity (rotate the
  head with each convention and look for judder in reprojection). `vr3` has
  no motion at all.
- 0x18: what the host does with the value beyond pacing (pose extrapolation
  to display time?). Needs a moving head; see also "Probe results".
- Whether the host needs all four sub-packets per frame or only sub 0.
- Who sends the two frame-id-0 packets at session start.
- The 7.7 ms fall of `toff` 0.11 s after it first appears (docs/svl-timing/).

## Probe results (2026-11-10)

**Captured by probe**, on the target-time field at dataset offset 0x18:

- The host uses it as a per-frame timing reference. When every pose packet of
  a frame carried the same value (the time the frame id began), the host
  delivered exactly the agreed 90 frames per second.
- When each pose packet carried its own send time there, the host delivered
  about 115 frames per second. A/B/A/B over four sessions: 113.4, 90.0, 113.7,
  90.0.
- A constant 0 behaved like the per-frame value (90.0).

So a client must not treat 0x18 as "time of this sample". Keep it fixed for
all sub-indices of a frame id. Whether it should be the frame's start or its
predicted display time made no difference to the delivered rate (start and
start + one period both gave 90.0); what it does to pose prediction on the
host is untested, since the probe's head does not move.

## Client results (2026-11-10): the host predicts the head

**Captured by client** (`client`, macOS viewer on a wired LAN, the
head turning at a steady 30 deg/s about its own position with that angular
velocity in the pose):

- With the head still, the render pose in each frame's metadata equals the
  head pose sent, to the last digit: the host renders from exactly the head
  it is given.
- With the head turning, the render pose of an arriving frame faces about
  0.15 deg *further along the turn* than the newest pose the client had sent
  by then (the sign flips with the direction of the turn). An unpredicted
  host would be behind by the round trip instead. So the host extrapolates
  the head with the velocities it is sent, to a time a few milliseconds past
  the arrival of the frame on this link.
- Adding 50 ms to the target-time field (0x18) did not visibly change that;
  adding 200 ms moved it to 0.6..0.8 deg but unsteadily. Not resolved: what
  sets the host's prediction horizon (the frame reports are the other
  candidate).

## Client results (2026-11-11): the host predicts to the reported display time

**Captured by client** (macOS viewer, wired LAN, 120 Hz, the head turning at
a steady 30 deg/s with that angular velocity in the pose, so the yaw of the
render pose in a frame's metadata says which moment the host rendered for).
"Lead" is that moment minus the moment the frame arrived, median per second
over about 25 s:

| what was sent | lead |
|---|---|
| everything honest (display reported about 12 ms after arrival) | 20 ms |
| frame report's display time (value offset 0x0c) 30 ms later | 43..48 ms |
| pose packet's sample time (0x14) 30 ms earlier | 46..50 ms |
| pose packet's target time (0x18) 30 ms later | 15..20 ms |

So the host carries the head forward by its velocities **from the pose
packet's sample time to (about) the display time the client's frame reports
give**, and the target-time field does not set the horizon. The whole
round trip and the client's display pipeline are already covered, by the
client's own measurements. Not measured: controllers and hands (their poses
do not come back in the metadata); **inferred** that they are treated alike,
as they travel in the same packet under the same sample time.

A client should therefore send poses as they are at the sample time, with
correct velocities, report display times honestly, and predict nothing
itself: every millisecond it predicts is added twice. On a headset whose display pipeline is
longer than the host assumes, the remainder shows as controllers lagging and
near objects shifting while the head turns; `client/visionOS` prints
that remainder ("drift:") for the head.

## Client results (2026-11-11): what to predict, tried on the headset

Judged by eye on a Vision Pro with PS VR2 Sense controllers, RealityKit
renderer, about 34 ms from a frame's arrival to the display (the host's own
share not measured). All **captured** only in the sense of "seen by the
wearer"; no numbers.

| what was sent | head | controllers |
|---|---|---|
| poses at now, velocities as tracked (the reference client's way) | steady | position right, turning overshoots visibly |
| poses predicted one frame (about 10 ms) ahead by ARKit, velocities as tracked | steady | the same overshoot |
| poses at now, every velocity zero | lags when turning | trail the hand, turning slow |
| poses predicted about 60 ms ahead by ARKit, every velocity zero | slight jitter | unusable: jitter and overshoot whenever they move, steady at rest |
| poses at now, controller angular velocity zero | steady | position right, pointer sluggish |
| poses at now, controller angular velocity halved | steady | position right, pointer acceptable |

So: the host's extrapolation is needed and is right for position; ARKit's own
prediction is no substitute over the whole delay; and a controller's turning
is carried too far by a full angular velocity. The client sends half of it
(`ControllerState.spinSent`). The head shows no overshoot either way, which
fits its picture being shown where it was rendered for: a head pose predicted
too far is corrected on the headset, a controller drawn too far is not.
Whether the host wants angular velocity along the controller's own axes or
the world's is still only known from the reference client (above); it was
not tried the other way.
