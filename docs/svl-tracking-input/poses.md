# Pose packet (`QSVLClient::SendPoses`)

The pose packet is an unreliable client-to-host message of type `0x01`, built
entirely in `QSVLClient::SendPoses(int nSub, int nFrameID)` (0xf4d34).
Everything in the layout table below is **static** from that function unless
marked otherwise.

## When it is sent

- In `QSVLClient::HandleEvent` (0xf4bec, **static**), event type 0 calls
  `SVLRoot::SendValues(3)` followed by `SendPoses(arg & 0xf, arg >> 4)`. The
  event argument packs `(frame_id << 4) | sub_index`.
- Sub index 0 logs
  `[SVLC] SendPoses: lnFrameID=%d(%d) (mod64=%d) (mod256=%d) rst=%d toff=%d`,
  while non-zero sub indices log `[SVLC] SendPoses lnFrameID=%d(%d)`
  (**static**).
- After sending, `SendPoses` reports timing event `0x40` (sub index 0) or
  `0x41` (sub index ≠ 0) with the frame id via `SVLRoot::ReportTimingEvent`
  (**static**).
- In `vr3` (**captured**), `vrlink` sends four packets per frame id with sub
  indices 0, 1, 2, 3 in order, spaced a quarter of the frame period apart (see
  "Capture check" below). Event-0 scheduling is documented in
  docs/svl-timing/event-schedule.md.

Sequence of operations inside `SendPoses` (**static**, using the `QSVLClientXR`
vtable at 0x210660):

1. Call `ReadyForInputSync()` (slot 0x160 → 0xfb868), which invokes
   `xrSyncActions`.
2. Zero a 0x2e4-byte buffer and write the dataset header and timestamps.
3. Call `GetHmdPose()` (slot 0x140) to populate the HMD pose block.
4. Unless the "no input" flag at `this+0x3eb8` is set, call `GetHmdInput()`
   (slot 0x148), then call `GetInput()->GetControllerStates(states, version)`
   and pack both hands. When `this+0x3eb8` is set, both controller input blocks
   and both controller poses stay zero.
5. Call `ValueTransportSystem::TickUpdate(buf + 0x170, 0x174)` to append
   pending VTE chunks and acks; its return value is the VTE byte count.
6. Call `SVLDataLink::SendLastRXID()`, then `SubmitMessage(msg, false, true)`.
7. If `SVLRoot::BIsConnectionActive()` is true, call `HandleEyeInput()` (slot
   0x150) and `HandleHandTracking()` (slot 0xe8) to send their own messages
   ([eye-face.md](eye-face.md), [skeleton.md](skeleton.md)).

## Layout

Offsets below are relative to the start of the `dataset` (payload begins at
0x08). Total packet size is `0x170 + vte_len` bytes (up to `0x170 + 0x174 =
740` bytes).

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
| 0x0c | 4 | i32 | `toff` = `this+0xc7c`, `vrlink`'s current clock offset estimate (written only by `SVLRoot::SymmetricTimingUpdate` 0x165a38) | µs; semantics in docs/svl-timing/ |
| 0x10 | 4 | i32 | `GetCurrentTimestamp()` taken *after* VTE packing, i.e. transmit time | µs |
| 0x14 | 4 | i32 | `GetCurrentTimestamp()` taken at the start of the call, before input is sampled | µs |
| 0x18 | 4 | i32 | per-frame target time, read from client state when the packet is built. If host protocol version > 5: `this+0xcbc`, which `QSVLClient::OnTopOfFrame` (0xf6270) sets to `now + its first argument` (µs until the frame's predicted display time). Else `this+0x3e20`, the anchor time of the most recently scheduled pose batch | µs, same clock as 0x10/0x14. One value per frame rather than per sample; see "Target-time field (0x18)" below |
| 0x1c | 4 | i32 | frame id (`nFrameID`) | |
| 0x20 | 2 | u16 | `rst` = low 16 bits of `this+0xe04`, a counter incremented by `QSVLClient::HandleUnrecoverableError` (0xf4bdc) | **inferred**: tells the host the decoder needs a reset / IDR when it changes |
| 0x22 | 14 | `PackedHmdInput_t` | HMD buttons | below |
| 0x30 | 28 | controller input | left hand | [controllers.md](controllers.md) |
| 0x4c | 28 | controller input | right hand | |
| 0x68 | 88 | `PackedPose_t` | HMD | below |
| 0xc0 | 88 | `PackedPose_t` | left controller / hand | copied from `QSVLControllerState[0]+0x20` |
| 0x118 | 88 | `PackedPose_t` | right controller / hand | copied from `QSVLControllerState[1]+0x20` |
| 0x170 | 0..372 | bytes | ValueTransportSystem stream (same encoding as a type-`0x0d` body) | docs/svl-values/ |

`GetCurrentTimestamp()` (0x155cb0, **static**) returns a 32-bit signed
microsecond counter computed via `clock_gettime(4 /* CLOCK_MONOTONIC_RAW */)` as
`(int)tv_sec * 1000000 + tv_nsec / 1000` (the low 32 bits of the monotonic clock
in µs, wrapping every 4295 s or 71.6 min). In `vr3` (**captured**), the 0x10
transmit timestamp tracks the capture's own `CLOCK_MONOTONIC` datagram timestamp
at a fixed offset (`capture_us + 1,455,028`, mod 2^32) within −0.10..+0.24 ms
for 99% of packets (worst case 7.3 ms), drifting +0.2 ms over the 40 s. Every
timestamp field in this packet can therefore be compared directly against
capture timestamps.

The host protocol version is stored as an atomic `int` at `SVLRoot+0xba8`.
`QSVLClient::ReceivedBookend` (0xf6d38, **static**) stores
`*(u32*)(SVLVideoFrameDescriptor_t+0x20)` there, so `vrlink` learns the protocol
version from the first video bookend (it remains 0 until then). It gates the
0x18 field here (`> 5`) and hand-tracking-as-controller (`>= 7`,
[controllers.md](controllers.md)).

### `PackedPose_t` (88 bytes)

Populated by `QSVLDeviceHmd::GetPose` (0x1015e4, **static**) for the HMD, and by
`QSVLXRInput::GetControllerState_Controller` (0x10722c, **static**) or
`GetControllerState_HandTracking` (0x107ca4, **static**) for hands. All floats
are IEEE 754 single-precision using OpenXR conventions (right-handed, −Z
forward, meters, radians/s).

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

- **Sample time** (**static**): Every HMD and controller pose is located at
  `XRQGetTimeNow()` rather than a predicted display time. `vrlink` performs no
  client-side pose prediction for controllers or HMD; it sends current poses,
  velocities, and timestamps so the host can extrapolate. (Hand joints are the
  exception, located at `now + 30 ms` via
  `XRQLocateHandJoints(..., now + 30000000, ...)`.)
- **Angular velocity frame** (**static**): `vrlink` rotates the OpenXR angular
  velocity by the conjugate of the pose orientation (`q⁻¹ · ω · q`), converting
  it from space-frame to body-local coordinates, *except* on specific runtimes:
  this rotation is skipped when `XRQContext+0xa0 == 3 && runtimeVersion >> 49 == 0`,
  and for the HMD also when `XRQContext+0xa0 == 2 && versionWord(+0x1e) < 0x7f`.
  Those runtimes presumably report body-local angular velocity already
  (**inferred**); a custom client should always send body-local angular
  velocity.
- **Offset pose** (**static**): For controllers, the 7 floats at 0x38 come from
  a map keyed by the active interaction-profile `XrPath` (one 28-byte `XrPosef`
  per hand), populated from `poseAction.<profile>.offset` in
  `assets/config/controller_config.json` (position in meters, rotation in
  degrees about x/y/z; e.g. Touch: position `(−0.007, −0.03416, −0.09607)`,
  rotation x = `−20.6°`). On the host, `pose ∘ offset` converts the OpenXR grip
  pose into the SteamVR device pose (**inferred**). X-axis mirroring between
  hands is applied when the map is built in `QSVLXRInput::Init` (0x104280; see
  `vr3` values below).
- When a controller is absent, `vrlink` writes `0x34 = 1` and `0x36 = 0`,
  leaving the rest of the pose zeroed.

### `PackedHmdInput_t` (14 bytes at 0x22)

Initialized in `SendPoses` and populated by `QSVLDeviceHmd::GetInput` (0x1014f4,
**static**):

| off | type | field |
|---|---|---|
| 0x00 | u32 | constant 9 |
| 0x04 | u64 | 0 |
| 0x0c | u8 | flags: bit1 = `DeviceInput::GetInput(0x19)`, bit2 = `DeviceInput::GetInput(0x18)`, bit3 = *no* controller/hand produced a state this frame (`XRQContext+0xfa == 0`, written by `GetControllerStates`) |
| 0x0d | u8 | `0xff` |

Key codes 0x18 and 0x19 match Android `KEYCODE_VOLUME_UP` (24) and
`KEYCODE_VOLUME_DOWN` (25), making bit2 volume-up held and bit1 volume-down held
(**inferred**). Bit0 and the constant `9` are unexplained (**inferred**: `9`
could be a default proximity/"HMD worn" bitmask or a struct version).

## Capture check (`vr3`)

Everything in this section is **captured** unless marked otherwise. `vr3`
records 40.3 s of `vrlink` running under Klepton against a SteamVR host in
desktop view, with a motionless synthetic head, two idle synthetic Touch
controllers, no eye, face, or hand tracking, and a display advertised at 120 Hz
(frame time 8333 µs). In total, 17,423 pose datasets were parsed. Field
semantics that depend on motion or button input remain untested in `vr3`.
Offsets below are dataset offsets matching the layout table.

This section supersedes an earlier check against the torn `vr1` capture (1,637
pose datasets), noting any differences below.

### Counts and framing

- The log records 17,446 pose-sized `sendto` calls on the SVL socket. Because
  the tracer omitted hex dumps for 23 of them, 17,423 datasets are parsed and
  the outbound datagram sequence shows 23 single-packet gaps (a capture artifact
  rather than `vrlink` behavior). In total, `17,446 = 4 × 4361 + 2`: four
  packets for each frame id 1..4361, plus two packets with frame id 0.
- Each packet uses envelope `03 01` with element id 0, index 0, and payload
  length `360 + n` (the fixed pose block is 0x168 = 360 bytes).
- `n = 0` in 17,015 packets. All 408 packets carrying value-transport bytes
  (`n = 36..371`, out of a 372-byte budget) occur within the first 1.07 s:
  packets 0..401 continuously, followed by 456..459 and 461..462 (see "Variable
  packet length (VTE trailer)" below).
- The pose dataset is always the final element of its UDP datagram. Outbound
  datagrams consist of `[3/0x11 eye] [3/0x07 values] [4/0x0f report]
  [3/0x01 pose]` in 17,020 datagrams (537 bytes when `n = 0`), the same sequence
  without the eye element in 401 datagrams, and report + pose only in the first
  2 datagrams. Every outbound SVL datagram in `vr3` ends with a pose dataset.

### Fixed-field values across `vr3`

| off | field | behavior in `vr3` |
|---|---|---|
| 0x08 | `0x0a` | constant in all 17,423 |
| 0x09 | sub index | 0, 1, 2, 3 (4357 / 4355 / 4355 / 4356) |
| 0x0a | `0x20` | constant in all 17,423 |
| 0x0b | holdoff | 0 in all |
| 0x0c | `toff` | 0 in packets 0..401; from packet 402 (0.930 s, right after the first video packet arrives at 0.926 s) a large negative value. 3,148 distinct values spanning 8.1 ms: holds its first value for 0.11 s, falls 7.7 ms between 1.04 and 1.06 s, then climbs back a few µs at a time for the rest of the session, ending 0.4 ms above its initial value. Semantics in docs/svl-timing/clock-sync.md |
| 0x10 | transmit time | strictly increasing; no wrap in this capture |
| 0x14 | sample time | 0x10 − 0x14 is 3..360 µs, median 5 µs, above 99 µs in 3 packets |
| 0x18 | target time | 0 in the two frame-id-0 packets; then one value per frame id (detailed below) |
| 0x1c | frame id | 0, then 1..4361, incrementing by one per frame (108.3 frame ids/s) |
| 0x20 | `rst` | **0 in every packet** |
| 0x22 | `PackedHmdInput_t` | `09 00 00 00`, eight zero bytes, flags, `ff`. Flags = 0x08 in packet 0 only, 0 in the other 17,422 |
| 0x30, 0x4c | controller input | all 28 bytes zero in both hands, every packet |
| 0x68 | HMD pose | identical 88 bytes in every packet: position (0, 1.6, 0), orientation (w,x,y,z) = (1, 0, 0, 0), both velocities zero, tracking result 200, state 2, identity offset pose, trailing u32 0 |
| 0xc0, 0x118 | controller poses | identical 88 bytes per hand in every packet, including packet 0; see [controllers.md](controllers.md) |

Corrections to the earlier `vr1` notes:

- **`rst` stays 0 throughout.** `vr1` showed `rst` climbing from 0 to 18,
  whereas in `vr3` it remains 0 from the first packet to the last (`vrlink` logs
  one `[SVLDecoder] Failed to acquire latest image!` at startup and no
  unrecoverable errors or resets). Because the host still sent
  `[SVLS] ResetVideoStream` once at 0.209 s — 0.72 s before the first video
  packet ([events-prompts.md](events-prompts.md)) — that host debug message is
  unrelated to `rst` changing. How the host reacts when `rst` increments remains
  untested; `vr3` confirms that a healthy session leaves it at 0.
- **No "no input" packets.** `vr1` had 1,020 of 1,637 packets with zeroed
  controller blocks and HMD-input byte 0x0d = 0 (the `this+0x3eb8` path). `vr3`
  has none: the HMD input block always ends in `ff` and both controller poses
  are populated starting from packet 0.
- **HMD-input bit3 lags by one packet.** Packet 0 has flags `0x08` ("no
  controller produced a state") even though it already carries two valid
  controller poses. Because `GetHmdInput()` runs before `GetControllerStates()`
  within `SendPoses` (step 4 above), bit3 reports the *previous* call's result
  and is set on packet 0 before any controller state has been read (**inferred**).
  `vr1` likewise had bit3 set in packet 0 only.
- **Orderly sub indices and frame ids.** `vr1` appeared to show unequal
  sub-index counts, frame-id jumps of 2 or more, and unordered sub indices, all
  of which were caused by torn capture buffers. In `vr3`, no frame id is skipped
  and sub indices within each frame id always ascend `0, 1, 2, 3`.

### Cadence

- Mean packet interval is 2.31 ms (432.8 packets/s captured, or 433.4/s
  including the 23 undumped sends), with median 2.13 ms, p1 1.59 ms, and p99
  3.92 ms. One stall of 68.6 ms without a pose packet occurs at 1.17 s.
- Within a frame (from frame id 102 onward), the sample times of sub 1, 2, 3
  trail sub 0 by a median 2181 / 4265 / 6381 µs (p10..p90: 2076..2392,
  4100..4435, 6161..6524). The schedule in docs/svl-timing/event-schedule.md
  posts them at `ft // 4` steps (2083 / 4166 / 6249 µs for an 8333 µs frame
  time), confirming quarter-frame spacing with ~0.1 ms of scheduling jitter.
- The interval from sub 0 to the next frame's sub 0 averages 9244 µs (median
  9.17 ms, p1 7.4 ms, p99 10.2 ms, with eight intervals exceeding 15 ms) rather
  than the advertised 8333 µs. Because `nFrameID` advances when `vrlink`'s frame
  wait returns — and Klepton's frame loop ran at 108.3 Hz instead of the
  nominal 120 Hz — pose cadence follows `vrlink`'s actual frame loop rather
  than the negotiated frame time.
- When two frame waits return close together (0.1..1.8 ms apart here), their
  batches interleave on the wire (`… 120/0, 121/0, 120/1, 121/1 …`), causing
  the frame id to step backward by one at 10 points across frames 14/15,
  116/117, 120/121, and 126/127. A receiver cannot assume `nFrameID` is strictly
  monotonic from packet to packet.
- Two frame-id-0 packets (both sub 0, 0.2 ms apart, target time 0) open the
  session 4 ms before frame id 1, likely posted once during startup before the
  first top-of-frame (**inferred**; caller not traced).

### Variable packet length (VTE trailer)

Every packet longer than 360 bytes carries value-transport bytes
(docs/svl-values/) starting at 0x170, and all 408 of them parse cleanly as chunk
and ack records using `ovrlink.vts` framing (8-byte chunk header + up to 128
bytes, or a 4-byte ack):

- **Packets 0..15 (first 30 ms)**: `vrlink` sends its initial values once per
  chunk — ids 0x01, 0x04, 0x05, 0x08, 0x0d, 0x0e, 0x0f (1,161 bytes / 10 chunks
  each for the last three), 0x10..0x13, 0x15, 0x18, 0x20, and 0x22 — plus acks
  for the host's first values.
- **Packets 16..32 (32..71 ms)**: Everything except 0x13 is published again
  under version 2, ids 0x0c and 0x23 appear for the first time, and id 0x05
  advances to version 3. `vrlink` logs `Server requested prop refresh` during
  this phase (see docs/svl-values/startup-exchange.md).
- **Packets 33..401 (up to 0.926 s)**: The host's last startup acknowledgment
  arrives at 42 ms, covering version 2 up to chunk 2 of id 0x0d. Everything
  still unacknowledged (id 0x05 version 3, chunks 3..9 of 0x0d, all of 0x0e and
  0x0f, and ids 0x10, 0x11, 0x12, 0x15, 0x18, 0x20, 0x22, 0x23) is then
  repeated round-robin — two 128-byte chunks per packet in the common case
  (length 632 in 255 packets), sending each chunk 27 or 28 times overall. No
  inbound packet acknowledges them during those 0.88 s (all six host→client
  `3/0x0d` messages arrive within the first 42 ms).
- **Packet 402 (first packet after video starts)**: Retransmission stops
  immediately and VTE length drops to 0. Packets 456..462 (1.05..1.07 s) carry
  only acks (36 or 52 bytes) for host values 0x06, 0x17, 0x1c, 0x29, 0x35,
  0x64, 0x65, 0x67, and 0x72, which the host delivers in video frame-descriptor
  trailers (docs/svl-video/).
- **After 1.07 s**: No pose packet carries value bytes for the remaining 39 s.

Once steady streaming begins, the pose packet stays at 360 bytes; longer packets
occur only when startup or mid-stream VTE updates ride along.

### `PackedPose_t`

- 88 bytes; quaternion components are ordered **w, x, y, z** (each pose has unit
  norm only in w, x, y, z order; the Touch offset quaternion reads
  `w = 0.9839, x = −0.1788`, corresponding to −20.6° about x in
  `controller_config.json`).
- HMD has tracking result 200, state 2, identity offset pose
  (0,0,0 / 1,0,0,0), and trailing `u32` 0. Controllers also report 200 / 2.
- Offset position is **mirrored in x for the right hand**: left
  `(−0.007, −0.0342, −0.0961)`, right `(+0.007, −0.0342, −0.0961)`, while offset
  rotation is identical for both hands. The JSON config stores the left-hand
  value.

### Target-time field (0x18)

`SendPoses` copies a precomputed timestamp stored by the frame scheduler when
the frame began (**static**, consistent with both `vr3` and probe tests), so all
sub-packets built between two frame starts carry the same value. Which field
`SendPoses` reads depends on the host protocol version at `SVLRoot+0xba8`, which
remains 0 until the first video bookend arrives.

Before the first video packet arrives (packets 2..401, frame ids 1..100), the
values match the batch anchor `this+0x3e20`, the scheduled send time for sub 0
of that batch (**inferred** link to the version gate, since `SVLRoot+0xba8` is
still 0 before the first bookend):

- Target minus sample time at sub 0 has median −203 µs (range −438..+105 µs).
  Because the anchor is when sub 0 was due, it lies slightly in the past by the
  time the packet is built. Sub 1 has median −2334 µs; sub 2 has median
  −4385 µs.
- Sub 3 usually carries the **next** frame's anchor (+2.3..+3.5 ms ahead): 78 of
  these 100 frame ids show two target values, with the change falling at sub 3
  in 75 of them. In this pre-video mode, the batch is delayed by the standoff
  (`cStandoff = 3500 µs`), placing sub 3 after the next frame wait has returned
  and overwritten the anchor.

After the first video packet arrives (frame id 102 onward, 17,017 packets), the
values match `this+0xcbc` (top-of-frame timestamp plus the microseconds until
that frame's predicted display time):

| sub | target − sample time, µs: min / p10 / median / p90 / max |
|---|---|
| 0 | 6794 / 8185 / 8314 / 8323 / 8330 |
| 1 | 5617 / 5915 / 6111 / 6213 / 8014 |
| 2 | −255 / 3875 / 4038 / 4117 / 7736 |
| 3 | −1490 / 1786 / 1929 / 2027 / 8066 |

- At sub 0, the target time is 8.31 ms ahead of both sample time and transmit
  time — 19 µs short of one 120 Hz period (8333 µs). Klepton's OpenXR runtime
  appears to predict display exactly one period after the frame wait returns,
  with 19 µs elapsed before the packet is built (**inferred**; a physical
  headset's display lead will differ). The lead then shrinks by a quarter period
  per sub index because the target time stays fixed while sample time advances.
- **Constant within a frame id**: 4,253 of 4,260 frame ids carry a single target
  value across all captured sub indices. The 7 exceptions (frame ids 116, 120,
  126, 1264, 2116, 2723, 2926) are frames whose later sub-packets were built
  after the next top-of-frame had already overwritten `this+0xcbc` (overlapping
  batches, or the event thread running 4..6 ms late), causing those late
  sub-packets to pick up the next frame's target.
- **Step between frames** (sub 0 of consecutive frame ids, n = 4,247): mean
  9231 µs, median 9171 µs, standard deviation 1246 µs, p1 7428 µs, p99
  10,190 µs, with eight steps of 15..75 ms. It matches the sub-0 sample-time
  step within ±0.34 ms for 98% of frames, whereas only 295 steps fall within
  0.1 ms of 8333 µs. Rather than stepping along an ideal vsync grid, the target
  time is recomputed each frame as `frame_wait_return + time_to_display` and
  inherits the frame loop's jitter.
- Frame id 101 (packets 402..405) spans the mode transition (scheduled in
  anchor mode, sent in display-time mode), giving a +2.7 ms lead at sub 0.

Note on `vr1`: the earlier `vr1` pass observed `target − sample` between −46 ms
and +8 ms ("one frame id usually maps to one target value, sometimes two") and
mistakenly concluded that 0x18 was not a forward display-time prediction. That
capture mixed pre-video anchor mode with post-bookend display-time mode while
running far slower than real time with a third of its packets torn (**inferred**).
`vr3` confirms the static decompilation: once video is flowing, 0x18 holds the
frame's predicted display time and stays constant across all four sub indices in
99.8% of frames. This also matches the probe results below, where setting 0x18
to either frame start or `frame start + 1 period` (corresponding to `vrlink`'s
two modes) paced the host properly.

### Fields not exercised by `vr3`

Because the synthetic session in `vr3` is completely stationary and idle, `vr3`
does not exercise non-zero velocities, pose changes, button/touch/axis bits,
controller-block byte 0x10 (tracked-hand flag), angular-velocity frame rotation,
holdoff, non-zero `rst`, "no input" mode, absent controllers, or hand tracking.

## Open questions / to confirm on the wire

- Meaning of bytes 0x08 (`0x0a`) and 0x0a (`0x20`): constant across all 17,423
  packets in `vr3`. Probe by changing them and checking whether the host still
  tracks. (**inferred**, weak: 0x20 also appears as the video descriptor's
  `fec_mode` and in `vrlink`'s `HandleFECChange( 32 )` log line; whether that is
  more than coincidence is unchecked.)
- 0x20 `rst`: never changed in `vr3`. Increment it in a probe to see whether the
  host sends an IDR or `[SVLS] ResetVideoStream`.
- Whether the host expects body-local or space-frame angular velocity (rotate
  the head under each convention and check for reprojection judder). `vr3` has
  no motion.
- 0x18: whether the host uses this field for anything beyond frame pacing (see
  "Probe results" and "Client results" below).
- Whether the host requires all four sub-packets per frame or accepts sub 0
  alone.
- What posts the two frame-id-0 packets at session start.
- Why `toff` drops by 7.7 ms at 0.11 s after its initial value
  (docs/svl-timing/).

## Probe results

Probe runs varying the target-time field at dataset offset 0x18 (**captured**):

- The host uses 0x18 as a per-frame pacing reference. When every pose packet of
  a frame carried the same value (the timestamp when that `nFrameID` began), the
  host delivered the negotiated 90.0 frames/s.
- When each pose packet wrote its individual send time into 0x18, the host
  over-delivered at ~115 frames/s (113.4, 90.0, 113.7, 90.0 across an A/B/A/B
  sequence of four sessions).
- Sending a constant 0 in 0x18 also paced at 90.0 frames/s.

A client must keep 0x18 fixed across all sub indices of a `nFrameID` rather than
writing each sample's timestamp. Using frame start versus `frame start + 1
period` made no difference to delivered frame rate (both gave 90.0 frames/s);
effects on pose prediction with a moving head are tested below.

## Client results: host head-pose extrapolation

Rotating the synthetic head at a steady 30 deg/s in place in the OpenVRLink
macOS viewer on a wired LAN (**captured**) with matching angular velocity:

- With a stationary head, the render pose in each video frame's metadata equals
  the sent head pose to the last digit.
- With the head turning at 30 deg/s, the render pose of an arriving frame is
  rotated ~0.15 deg *further along the turn* than the newest pose OpenVRLink had
  sent by that moment (reversing sign when turning the opposite direction),
  whereas an unpredicted render pose would lag by the round-trip time. The host
  therefore extrapolates head orientation using the client's reported velocities
  to a timestamp a few milliseconds past frame arrival on LAN.
- Adding +50 ms to the target-time field (0x18) produced no visible change;
  adding +200 ms shifted lead to 0.6..0.8 deg with instability. What controls
  the host's prediction horizon is covered next.

## Client results: prediction horizon and display-time reports

Turning the synthetic head at a steady 30 deg/s with matching angular velocity
in the macOS viewer (wired LAN, 120 Hz, **captured**) so the render-pose yaw in
each frame's metadata indicates the exact timestamp the host rendered for. In
the table below, "lead" is that rendered timestamp minus the frame's local
arrival time (median of per-second medians over ~25 s):

| what was sent | lead |
|---|---|
| unmodified timestamps (display reported ~12 ms after arrival) | 20 ms |
| frame report's display time (value offset 0x0c) +30 ms | 43..48 ms |
| pose packet's sample time (0x14) −30 ms | 46..50 ms |
| pose packet's target time (0x18) +30 ms | 15..20 ms |

The host extrapolates head pose using its velocities **from the pose packet's
sample time (0x14) to approximately the display time reported in the client's
frame reports**, while the pose packet's target-time field (0x18) does not set
the prediction horizon. Because the host already covers both network round trip
and the client's reported display pipeline latency, a client should send
unpredicted poses sampled at 0x14 with accurate velocities and honest display
timestamps — any client-side prediction would be applied twice. Controller and
hand poses are not echoed in frame metadata and were not measured directly, but
they share the same packet and sample timestamp and are likely extrapolated the
same way (**inferred**).

On a headset whose display pipeline exceeds what the host extrapolates for, the
uncompensated latency appears as controller lag and near-object parallax shift
during head rotation; `client/visionOS` logs that head residual as `drift:`.

## Client results: Vision Pro prediction tuning

Qualitative evaluation on Vision Pro with PS VR2 Sense controllers and the
RealityKit renderer (~34 ms from frame arrival to display; host-side share not
isolated):

| what was sent | head | controllers |
|---|---|---|
| poses at `now`, velocities as tracked (matching `vrlink`) | steady | position accurate, rotation visibly overshoots |
| poses predicted 1 frame (~10 ms) ahead by ARKit, velocities as tracked | steady | same rotational overshoot |
| poses at `now`, all velocities zero | lags when turning | trail the hand, rotation slow |
| poses predicted ~60 ms ahead by ARKit, all velocities zero | slight jitter | unusable: jitter and overshoot when moving, steady at rest |
| poses at `now`, controller angular velocity zero | steady | position accurate, pointer sluggish |
| poses at `now`, controller angular velocity halved | steady | position accurate, pointer acceptable |

Host-side velocity extrapolation works well for controller position, and ARKit
forward prediction with zeroed velocities cannot replace it across the full
streaming delay. However, sending full controller angular velocity causes
rotational overshoot, so OpenVRLink scales sent controller angular velocity by
0.5 (`ControllerState.spinSent`). Head rotation shows no overshoot in either
case because the headset reprojects each video frame using its render pose at
display time, correcting over-predicted head rotation whereas rendered
controllers remain baked into the frame. Whether the host expects controller
angular velocity in body-local or world coordinates was not verified
independently on the headset and still relies on `vrlink`'s static behavior
above.
