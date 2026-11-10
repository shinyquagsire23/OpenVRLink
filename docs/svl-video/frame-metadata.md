# `TransportFrameMetadata_t`

0x154 (340) bytes in the client's struct, carried inside every frame
descriptor at message offset 0x28 ([frame-descriptor.md](frame-descriptor.md)).
On the wire the host has only ever sent the first 0xf0 (240) bytes
(**captured**, `vr1` and `vr3`). It tells the client what
pose and projection the host rendered the frame with, how the atlas is laid
out, and when the host intends the frame to be displayed.

Where it goes (**static**):

- `SVLFECRXFrame::AcceptVFD` (+0x15f164) copies it into the receive slot
  (`slot+0x4270`) and into the renderer history
  (`SVLRenderer::AcceptFrameMetadata` +0x1624f0, 16 entries indexed by
  `present_number & 0xf`, which also forces the float at +0x40 to 1.0).
- Readers fetch it with `SVLFEC::GetMetadataForFrameId(frame_id)` (+0x160294),
  which returns the slot copy only if the slot still holds that frame and has
  its descriptor. There are exactly three readers:
  `QSVLCodecNDK::HandleOnImageAvailable`, `QSVLFrameServer::ServeBestHardwareBuffer`
  and `QSVLRendererXR::FlipFrame`. (`SVLRenderer::GetFrameMetadataFromCursor`
  has no caller in this binary.) So the table below is the complete set of
  fields this client consumes; everything marked "not read" is unknown.

## Layout

| Off | Type | Name | Use (static) |
|---|---|---|---|
| 0x00 | u32 | `present_number` | The host's frame counter (the client logs it as `m_iPresentNumber`). Key for `FrameHasBeenDecoded` / `FrameHasBeenSubmittedForDisplay`, mapped back to the 16-bit frame id through a 128-entry table |
| 0x04 | float[12] | `pose` 3x4, row-major | Rows at +0x04, +0x14, +0x24; each row is 3 rotation terms then the translation (+0x10, +0x20, +0x30). Converted to quaternion + position (`FUN_0020bab0`, +0x10bab0) and written as the `XrPosef` of all four projection views |
| 0x34 | float[4] | 4th row of the pose matrix | not read; +0x40 is overwritten with 1.0 on receipt, which makes +0x04..+0x43 a 4x4 with `m33 = 1` |
| 0x44 | float[16] | `eye[0].projection` 4x4 | Left eye. Read transposed, inverted, and reduced to an `XrFovf` (`FUN_0020be00`, +0x10be00) |
| 0x84 | float[16] | `eye[1].projection` 4x4 | Right eye, same |
| 0xc4 | 4 bytes | - | not read |
| 0xc8 | i16 | `eye[0].inset_x` | Foveal inset rectangle, see [frame-layout.md](frame-layout.md) |
| 0xca | i16 | `eye[0].inset_y` | |
| 0xcc | i16 | `eye[0].virt_w` | |
| 0xce | i16 | `eye[0].virt_h` | |
| 0xd0 | i16[4] | `eye[1].inset_x, inset_y, virt_w, virt_h` | |
| 0xd8 | 8 bytes | - | not read |
| 0xe0 | u32 | `display_time` | Host clock, us, 32-bit. The time the host wants this frame on the display. Used to pick the frame and to set the submitted display time |
| 0xe4 | u8 | - | not read |
| 0xe5 | u8 | `info` | bit 0 = valid (`GetFrameMetadataFromCursor`, logged as `md->info`). The TX code sends the short 0xf0 form unless `info >= 0x10` |
| 0xe6 | u16 | `atlas_w` | Encoded picture width |
| 0xe8 | u16 | `atlas_h` | Encoded picture height |
| 0xea | u16 | `tile_w` | Width of one eye tile = swapchain width |
| 0xec | u16 | `tile_h` | Height of one eye tile = swapchain height |
| 0xee | 2 bytes | - | not read |
| 0xf0 | 0x64 bytes | extension | not read by this client; present on the wire when `metadata_size == 0x154` |

The names of 0xe6..0xec follow from how they are used (the atlas mode is chosen
from `atlas_h / tile_h` and `atlas_w / tile_w`, and `(tile_w, tile_h)` are
passed to `SetupSwapchains`) and are **captured**: they read 1536, 6144, 1536,
1536 against a 1536 x 6144 SPS.

## Pose

**static**: the 3x4 at +0x04 is converted with the standard
rotation-matrix-to-quaternion branches and written to
`XrCompositionLayerProjectionView.pose` (orientation x,y,z,w then position) for
the left base, left fovea, right base and right fovea views alike.

- **inferred**: it is the HMD pose (head in tracking/stage space, meters,
  OpenVR `HmdMatrix34_t` convention: right-handed, +y up, -z forward) that the
  host rendered this frame with, i.e. the pose the client itself sent earlier,
  echoed back so the compositor can reproject from it.
- **captured** (`vr3`), as far as a motionless head allows: all 17,423 pose
  packets the client sent carry position (0, 1.6, 0) and the identity
  quaternion, and 4,257 of 4,260 frames come back with exactly that pose. So
  the metadata pose equals the pose sent, but nothing moved, so which sent
  pose a frame echoes (how old, extrapolated or not) cannot be told. The
  first three frames (ids 0..2) carry y = 0 although the client had been
  sending y = 1.6 for 0.93 s before the first descriptor arrived; those are
  the flat-fill frames before the second IDR
  ([frame-layout.md](frame-layout.md)), so the host had not started rendering
  from client poses yet.
- **Open**: `FlipFrame` gives *both eyes the same pose* - no per-eye offset is
  added there, and `GetProjectionLayers` (+0x10a570) only returns the two
  prebuilt layers. **captured** (`vr3`): the wire agrees that there is only
  one pose per frame and nothing per-eye besides the two projections and the
  two inset records; the two projections are identical. Yet the picture has
  real stereo disparity (0 px for the far backdrop, 47 px for the dashboard
  panel, 111 px for the controllers between the two base tiles), consistent
  with the 63 mm eye separation the client published in `VTE_EYE_TO_HEAD`. So
  the host renders each eye from its own position and the metadata does not
  say so; either the compositor is meant to get the head pose for both views
  (a position error of half the IPD per eye, in reprojection only), or the
  offset is folded in somewhere not found. A new client should start by
  reproducing exactly this (head pose for both views) and compare.

## Projection -> field of view

**static**: for each eye the client builds `M[r][c] = wire[c*4 + r]` (a
transpose of the 16 floats as stored), inverts it, and takes four arctangents
of ratios of the inverse's entries, producing `{angleLeft, angleRight, angleUp,
angleDown}` in that order (they are stored at `view+0x2c`, the `XrFovf`).
Unprojecting the clip-space corners through the inverse is what that
arithmetic amounts to.

**inferred**: the stored matrix is an OpenVR-style projection
(`IVRSystem::GetProjectionMatrix`, row-major `HmdMatrix44_t`), in which case
the tangents can be read directly without inverting:

```python
m = [wire[4*r:4*r+4] for r in range(4)]        # row-major as stored
tan_left  = (m[0][2] - 1.0) / m[0][0]
tan_right = (m[0][2] + 1.0) / m[0][0]
tan_up    = (m[1][2] + 1.0) / m[1][1]
tan_down  = (m[1][2] - 1.0) / m[1][1]
```

**captured** (`vr3`): the client published `VTE_PROJECTION_RAW_PRAMS` as
(-1, 1, -1, 1) for both eyes and every frame's two matrices give tangents
-1, +1, +1, -1 by these formulas; Klepton's OpenXR layer logged the base
layer as `fov 90x90 deg`. The magnitudes and the row-major reading are
therefore confirmed. A symmetric frustum cannot show a sign or left/right
mix-up, so that part still needs an asymmetric one.

The same per-eye FOV is used for the base view. The foveal view's FOV is
derived from it and the inset rectangle - see [frame-layout.md](frame-layout.md).

## Display time

**static**: host timestamps are converted to the client clock as

```
local = host_time + A - (A + B) / 2          # A = SVLRoot+0xc7c, B = SVLRoot+0xc84
```

where `B` is the `peer_clock` field of the latest descriptor (+0x0c) and `A`
is the client's own offset estimate (docs/svl-timing/ owns the meaning).

- `ServeBestHardwareBuffer` (+0x102830) picks the decoded frame minimizing
  `|local(display_time) - predicted_display_time|`.
- `FlipFrame` (+0x10ae78), when descriptor `version > 5`, rewrites the
  compositor display time it will submit to
  `xr_now + (local(display_time) - now) * 1000` ns.

## Captured

Capture `vr3`: 8,631 descriptors for 4,260 frames (ids 0..4259), none torn.
Every repeat of a frame's descriptor (4,371 of them) carries metadata
byte-identical to the first. The host sent the **0xf0-byte short form** on
all 8,631 (`metadata_size` 0xf0, `info` 0x01), as in `vr1`, so nothing at
+0xf0 and beyond is metadata; the 0x154 form has not been seen.

Over the 4,260 frames only three fields vary at all: `present_number`
(+0x00), the pose's y translation (+0x20, on three frames) and
`display_time` (+0xe0). Every other byte of the 240 is constant.

| Off | Captured (`vr3`) |
|---|---|
| 0x00 `present_number` | `frame_id + 7` on all 4,260 frames (frame 0 -> 7). `vr1` had `frame_id + 6`. The lead is fixed within a session and differs between sessions |
| 0x04 pose | `[1 0 0 0 / 0 1 0 1.6 / 0 0 1 0]` then `[0 0 0 1]` on 4,257 frames: identity rotation, translation (0, 1.6, 0). The 1.6 sits at +0x20, which confirms row-major 3x4 with translation in the 4th column, meters, +y up. Frames 0..2 had y = 0. The 4th row arrives as `0 0 0 1` on the wire |
| 0x44, 0x84 projections | both eyes `[1 0 0 0 / 0 1 0 0 / 0 0 -1.0001 -0.10001 / 0 0 -1 0]` in stored order, constant: a row-major OpenVR-style projection (`m[3][2] = -1`), symmetric, tangents +-1, near plane 0.1 and far plane 1000 by the usual `far/(near-far)` reading of -1.0001 (vr1's "-1, -0.1" was rounded). It echoes the frustum the client published; asymmetric frusta remain to be seen |
| 0xc4 | bytes `02 02 ca 00`, constant in both captures. Unknown |
| 0xc8 inset | left `(889, 1043, 3294, 3294)`, right `(868, 1043, 3294, 3294)`, constant over the run and equal to `vr1`. Checked against the decoded picture to 0.1 pixel in [frame-layout.md](frame-layout.md) |
| 0xd8 | 8 zero bytes |
| 0xe0 `display_time` | see below |
| 0xe4 | 0 |
| 0xe5 `info` | 0x01 |
| 0xe6..0xec | `1536, 6144, 1536, 1536` - equal to the SPS picture size and a quarter of it: **captured** confirmation of the `atlas_w, atlas_h, tile_w, tile_h` naming |
| 0xee | bytes `00 02` (u16 0x0200 = 512), constant in both captures. Unknown |

### `display_time` in `vr3`

All **captured**; times are 32-bit microseconds on the host clock unless
converted.

- Cadence: `display_time` steps by 6.8..10.5 ms from frame to frame on 4,253
  of 4,259 steps (median 9,168 us, mean 9,238 us = 108.2 frames per second;
  the exceptions are three steps of 10.6..11.8 ms and steps of 21, 56 and
  42 ms after frames 0, 14 and 22). It is **not** on a fixed grid:
  the steps spread over the whole 8.0..10.2 ms range, with no single period,
  although the client had asked for 8,333 us (120 Hz). Frame to frame it
  moves with the descriptor's `tx_time` (whose steps have the same median,
  9,203 us, and mean, 9,234 us) and with arrival time at the client (mean
  9,234 us).
- Lead over `tx_time`: `display_time - tx_time` is 1.7 ms on frame 0, climbs
  to 52 ms within the first second, then **falls linearly by about 1.4 ms per
  second** to 20.3 ms at 24 s and stays there (19.2..20.8 ms for the last
  16 s, frame-to-frame scatter about 0.2 ms). So the host stamps each frame
  "send time plus a lead" and trims the lead over the first half minute.
  `vr1`'s "a few ms to ~50 ms" is consistent with the same ramp seen through
  78 samples.
- In client time: converting with the static formula above, using the latest
  `toff` from the client's pose packets as `A` and the descriptor's
  `peer_clock` as `B`, the first descriptor of a frame arrives 0.1..2.9 ms
  after `local(tx_time)` (median 0.29 ms; about 0.2 ms once settled), which
  is a sane network delay and so checks the conversion. `local(display_time)`
  is then about 48 ms after arrival early in the run and about 20.1 ms after
  arrival from 24 s on (minimum 19.0 ms). That is the time the client has to
  receive, decode and queue a frame before its stamped display time.
- **inferred**: the lead is the host's estimate of the pipeline latency
  after transmit, adapted from the client's timing reports
  (docs/svl-timing/); which report drives it was not traced here.

## Open questions / to confirm on the wire

Settled by `vr3`: `display_time` against the frame cadence (above); the
`present_number` lead is constant within a session (7 here, 6 in `vr1`).

1. A session on a real headset: a moving pose, asymmetric per-eye projection
   matrices, and whether the two eyes' matrices or anything else carries the
   eye offset (the both-eyes-one-pose question above). `vr3` again had a
   motionless head and a symmetric frustum.
2. Which of the client's poses a frame's render pose corresponds to (age,
   prediction). Needs a moving head.
3. Whether the inset record changes at run time (Klepton SL-40 reports the
   foveal region moving). It did not in `vr3` (4,260 frames, no eye tracking).
4. +0xc4 (`02 02 ca 00`), +0xee (0x0200): what they are. Constant across two
   sessions; no client code reads them.
5. Why `present_number` leads `frame_id` at all, and what sets the lead (6 in
   one session, 7 in another). **inferred**: the host presents a few frames
   before its first encoded one.
6. A host sending the 0x154 form (`info >= 0x10`) and the 0x64 extra bytes.
7. What drives the `display_time` lead down from 52 ms to 20 ms, and whether
   20 ms is a floor or the settled value for this client's reported latency.
