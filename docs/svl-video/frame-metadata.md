# `TransportFrameMetadata_t`

`TransportFrameMetadata_t` is a `0x154`-byte (340-byte) struct in `vrlink`,
carried inside every frame descriptor starting at message offset `0x28`
([frame-descriptor.md](frame-descriptor.md)). On the wire, the host has only
been observed sending the short `0xf0`-byte (240-byte) form (**captured** in
`vr1` and `vr3`). It tells the client what pose and per-eye projections the
host rendered the frame with, how the atlas is laid out, and when the host
intends the frame to be displayed.

On the client, metadata flows through two storage locations and three readers
(**static**):

- `SVLFECRXFrame::AcceptVFD` (+0x15f164) copies it into the receive slot
  (`slot+0x4270`) and into the renderer history
  (`SVLRenderer::AcceptFrameMetadata` +0x1624f0, 16 entries indexed by
  `present_number & 0xf`, which also forces the float at `+0x40` to `1.0`).
- Readers fetch it via `SVLFEC::GetMetadataForFrameId(frame_id)` (+0x160294),
  which returns the slot copy only if the slot still holds that frame and has
  received its descriptor. Exactly three functions read it:
  `QSVLCodecNDK::HandleOnImageAvailable`,
  `QSVLFrameServer::ServeBestHardwareBuffer`, and `QSVLRendererXR::FlipFrame`
  (`SVLRenderer::GetFrameMetadataFromCursor` has no callers in this binary).
  The table below therefore covers every field `vrlink` consumes; fields marked
  "not read" have no reader in the binary and their purpose is unknown.

## Layout

| Off | Type | Name | Use (static) |
|---|---|---|---|
| 0x00 | u32 | `present_number` | The host's frame counter (`vrlink` logs it as `m_iPresentNumber`). Key for `FrameHasBeenDecoded` / `FrameHasBeenSubmittedForDisplay`, mapped back to the 16-bit frame id through a 128-entry table |
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
| 0xf0 | 0x64 bytes | extension | not read by `vrlink`; present on the wire when `metadata_size == 0x154` |

Field names at `0xe6..0xec` come from how `vrlink` uses them (atlas mode is
selected from `atlas_h / tile_h` and `atlas_w / tile_w`, while `(tile_w,
tile_h)` are passed to `SetupSwapchains`) and are confirmed in `vr3`
(**captured**): they read `1536, 6144, 1536, 1536` alongside a `1536 x 6144`
SPS.

## Pose

`vrlink` converts the 3x4 matrix at `+0x04` using standard
rotation-matrix-to-quaternion branches (**static**) and writes the resulting
`XrPosef` (orientation `x, y, z, w` followed by position) to
`XrCompositionLayerProjectionView.pose` across all four views: left base, left
fovea, right base, and right fovea.

- **inferred**: This matrix is the HMD render pose (head in tracking/stage
  space, in meters, using OpenVR's right-handed `+y` up, `-z` forward
  `HmdMatrix34_t` convention)—an echo of an earlier client-reported pose so the
  compositor can reproject from it.
- **captured** (`vr3`, with a stationary head): all 17,423 pose packets sent by
  `vrlink` carry position `(0, 1.6, 0)` and the identity quaternion, and 4,257
  of 4,260 frames return that exact pose in metadata. Because nothing moved,
  `vr3` confirms the coordinate convention and echo path, though not which sent
  pose a frame echoes (its age or whether it is extrapolated). Frames `0..2`
  carry `y = 0` even though `vrlink` had been sending `y = 1.6` for 0.93 s
  before the first descriptor arrived; those are the solid-fill startup frames
  before the second IDR ([frame-layout.md](frame-layout.md)), sent before the
  host started rendering from client poses.
- **Open question (single pose for both eyes):** `FlipFrame` assigns *both eyes
  the same pose* without adding a per-eye offset, and `GetProjectionLayers`
  (+0x10a570) returns the two prebuilt layers unchanged. `vr3` (**captured**)
  confirms that the wire metadata contains a single pose per frame, identical
  projection matrices for both eyes, and no per-eye fields beyond the two
  projections and two inset records. Even so, the decoded image exhibits stereo
  disparity (`0 px` on the far backdrop, `47 px` on the dashboard panel, and
  `111 px` on the controllers between the two base tiles), matching the 63 mm
  eye separation `vrlink` published in `VTE_EYE_TO_HEAD`. Thus the host renders
  each eye from its own position even though the metadata carries only the head
  pose; either the OpenXR compositor is expected to receive the head pose for
  both views (introducing a half-IPD position error per eye during
  reprojection) or the offset is folded in somewhere not yet identified. A new
  client should start by passing the head pose to both views to match `vrlink`
  and compare from there.

## Projection matrix and field of view

For each eye (**static**), `vrlink` builds `M[r][c] = wire[c*4 + r]`
(transposing the 16 wire floats), inverts `M`, and takes four arctangents of
ratios of the inverse's entries to produce `{angleLeft, angleRight, angleUp,
angleDown}` at `view+0x2c` (`XrFovf`). Mathematically, this unprojects the
clip-space corners through the inverse projection matrix.

Assuming the wire matrix is a standard row-major OpenVR projection
(`IVRSystem::GetProjectionMatrix`, `HmdMatrix44_t`, **inferred**), the tangents
can be read directly without inverting:

```python
m = [wire[4*r:4*r+4] for r in range(4)]        # row-major as stored
tan_left  = (m[0][2] - 1.0) / m[0][0]
tan_right = (m[0][2] + 1.0) / m[0][0]
tan_up    = (m[1][2] + 1.0) / m[1][1]
tan_down  = (m[1][2] - 1.0) / m[1][1]
```

**captured** (`vr3`): `vrlink` published `VTE_PROJECTION_RAW_PRAMS` as
`(-1, 1, -1, 1)` for both eyes, and both matrices in every frame yield tangents
`-1, +1, +1, -1` via these formulas; Klepton's OpenXR layer logged the base
layer as `fov 90x90 deg`. That confirms the magnitudes and row-major layout,
while verifying sign and left/right ordering requires an asymmetric frustum
(tested in [frame-layout.md](frame-layout.md)).

The base view uses this per-eye FOV directly. The foveal view's FOV is derived
from the base FOV and the inset rectangle; see
[frame-layout.md](frame-layout.md).

## Display time

`vrlink` converts host timestamps to the client clock using (**static**):

```
local = host_time + A - (A + B) / 2          # A = SVLRoot+0xc7c, B = SVLRoot+0xc84
```

where `B` is the `peer_clock` field of the latest descriptor (`+0x0c`) and `A`
is `vrlink`'s own clock-offset estimate (see `docs/svl-timing/`).

- `ServeBestHardwareBuffer` (+0x102830) selects the decoded frame minimizing
  `|local(display_time) - predicted_display_time|`.
- When descriptor `version > 5`, `FlipFrame` (+0x10ae78) replaces the
  compositor display time it submits with
  `xr_now + (local(display_time) - now) * 1000` ns.

## Captured

In `vr3`, all 8,631 descriptors across 4,260 frames (ids `0..4259`) arrived
intact. Every subsequent descriptor within a frame (4,371 of them) carries
metadata byte-identical to bookend 0. The host sent the **`0xf0`-byte short
form** on all 8,631 descriptors (`metadata_size = 0xf0`, `info = 0x01`),
matching `vr1`, so bytes at `+0xf0` and beyond belong to the trailer; the
`0x154`-byte long form has not been observed.

Across all 4,260 frames, only three fields change: `present_number` (`+0x00`),
the pose's `y` translation (`+0x20`, on the first three frames), and
`display_time` (`+0xe0`). Every other byte of the 240-byte metadata block stays
constant.

| Off | Captured (`vr3`) |
|---|---|
| 0x00 `present_number` | `frame_id + 7` on all 4,260 frames (frame 0 -> 7). `vr1` had `frame_id + 6`. The lead is fixed within a session and differs between sessions |
| 0x04 pose | `[1 0 0 0 / 0 1 0 1.6 / 0 0 1 0]` then `[0 0 0 1]` on 4,257 frames: identity rotation, translation (0, 1.6, 0). The 1.6 sits at +0x20, which confirms row-major 3x4 with translation in the 4th column, meters, +y up. Frames 0..2 had y = 0. The 4th row arrives as `0 0 0 1` on the wire |
| 0x44, 0x84 projections | both eyes `[1 0 0 0 / 0 1 0 0 / 0 0 -1.0001 -0.10001 / 0 0 -1 0]` in stored order, constant: a row-major OpenVR-style projection (`m[3][2] = -1`), symmetric, tangents +-1, near plane 0.1 and far plane 1000 by the usual `far/(near-far)` reading of -1.0001 (vr1's "-1, -0.1" was rounded). It echoes the frustum `vrlink` published; asymmetric frusta are tested in [frame-layout.md](frame-layout.md) |
| 0xc4 | bytes `02 02 ca 00`, constant in both captures. Unknown |
| 0xc8 inset | left `(889, 1043, 3294, 3294)`, right `(868, 1043, 3294, 3294)`, constant over the run and equal to `vr1`. Checked against the decoded picture to 0.1 pixel in [frame-layout.md](frame-layout.md) |
| 0xd8 | 8 zero bytes |
| 0xe0 `display_time` | see below |
| 0xe4 | 0 |
| 0xe5 `info` | 0x01 |
| 0xe6..0xec | `1536, 6144, 1536, 1536` - equal to the SPS picture size and a quarter of it: **captured** confirmation of the `atlas_w, atlas_h, tile_w, tile_h` naming |
| 0xee | bytes `00 02` (u16 0x0200 = 512), constant in both captures. Unknown |

### `display_time` in `vr3`

All measurements below are **captured**; timestamps are 32-bit microseconds on
the host clock unless converted to client time.

- **Frame cadence:** `display_time` advances by `6.8..10.5 ms` from frame to
  frame on 4,253 of 4,259 intervals (median `9,168 us`, mean `9,238 us` =
  `108.2` frames/s; the exceptions are three steps of `10.6..11.8 ms` plus
  steps of `21`, `56`, and `42 ms` after frames 0, 14, and 22). Rather than
  falling on a fixed vsync grid, steps spread across `8.0..10.2 ms` with no
  single period, even though `vrlink` requested `8,333 us` (120 Hz). Frame to
  frame, `display_time` moves in lockstep with the descriptor's `tx_time`
  (median step `9,203 us`, mean `9,234 us`) and with client arrival time (mean
  step `9,234 us`).
- **Lead over `tx_time`:** `display_time - tx_time` starts at `1.7 ms` on frame
  0, climbs to `52 ms` within the first second, and then **decreases linearly
  at roughly 1.4 ms/s** until reaching `20.3 ms` at 24 s, where it settles
  (`19.2..20.8 ms` over the final 16 s, with ~`0.2 ms` frame-to-frame scatter).
  The host therefore stamps each frame with `tx_time` plus a lead and trims
  that lead over the first 24 seconds (`vr1`'s `"a few ms to ~50 ms"` spread
  matches the early portion of this ramp across 78 samples).
- **Converted to client time:** Applying the static formula above with the
  latest `toff` from `vrlink`'s pose packets as `A` and the descriptor's
  `peer_clock` as `B`, the first descriptor of each frame arrives `0.1..2.9 ms`
  after `local(tx_time)` (median `0.29 ms`, settling around `0.2 ms`), which is
  a realistic LAN transit delay and validates the clock conversion. Under that
  conversion, `local(display_time)` sits ~`48 ms` after arrival early in the
  run and settles to ~`20.1 ms` after arrival from 24 s onward (minimum
  `19.0 ms`), which is the time budget the client has to reassemble, decode,
  and queue a frame before its target display time.
- **inferred**: This lead is the host's adaptive estimate of downstream
  pipeline latency, driven by client timing reports (`docs/svl-timing/`); which
  specific report drives the adjustment was not traced here.

## Open questions / to confirm on the wire

`vr3` characterized how `display_time` tracks frame cadence (above) and showed
that the `present_number - frame_id` lead stays constant within a session (`7`
in `vr3`, `6` in `vr1`). Remaining open questions:

1. Capturing a full headset session with head motion and asymmetric per-eye
   projection matrices to check whether the projection matrices or another
   field carry the per-eye IPD offset (`vr3` had a stationary head and
   symmetric frusta).
2. Determining which client pose packet a frame's render pose corresponds to
   (pose age and any host prediction), which requires head motion.
3. Checking whether the inset record updates at runtime when eye tracking is
   enabled (Klepton SL-40 notes a moving foveal region; `vr3` had no eye
   tracking across 4,260 frames).
4. Identifying the constant fields at `+0xc4` (`02 02 ca 00`) and `+0xee`
   (`0x0200`), which stay fixed across captures and have no reader in `vrlink`.
5. Understanding why `present_number` leads `frame_id` (`6` in `vr1`, `7` in
   `vr3`). **inferred**: the host presents several frames internally before
   encoding frame 0.
6. Observing a host that sends the `0x154`-byte long form (`info >= 0x10`) and
   inspecting the extra `0x64` bytes.
7. Identifying what drives the `display_time` lead down from 52 ms to 20 ms,
   and whether 20 ms is a floor or the steady-state target for `vrlink`'s
   reported latency.
