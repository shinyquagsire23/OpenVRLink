# Eye gaze and face expressions

Eye gaze and face expressions are sent from client to host in unreliable message
type `0x11`, once per pose packet while the link is active
(`QSVLClient::SendPoses` → vtable slot 0x150 → `QSVLClientXR::HandleEyeInput`
0xfb6ec → `SubmitMessage(msg, false, false)`). `vrlink` sends this message
**every tick even when no eye tracker is present**; the validity byte indicates
whether the gaze vector is valid.

## `EyeAndExpressions_t`

`QSVLDeviceHmd::HandleEyeInput` (0x100da0, **static**) populates a 0x139-byte
buffer zeroed by the caller:

| off | size | type | field |
|---|---|---|---|
| 0x00 | 4 | — | `03 11 00 00` (class 3, type 0x11) |
| 0x04 | 2 | u16 | payload length: `0x11` without face data, `0x131` with |
| 0x06 | 2 | u16 | 0 |
| 0x08 | 12 | f32×3 | gaze vector x, y, z (see below) |
| 0x14 | 1 | u8 | expression format: `0` = none, `2` = FB face tracking v2 weights |
| 0x15 | 1 | u8 | gaze valid (0/1) |
| 0x16 | 1 | u8 | expression count: `0` or `0x46` (70) |
| 0x17 | 2 | — | 0 |
| 0x19 | 8 | f32×2 | face confidences (the two `XrFaceExpressionWeights2FB.confidences`: lower face, upper face) — only with face data |
| 0x21 | 280 | f32×70 | expression weights in `XrFaceExpression2FB` order — only with face data |

Total message size (including the 8-byte dataset header) is 25 bytes
(`8 + 0x11`) without face data, or 313 bytes (`8 + 0x131`) with face data.

`vrlink` reads two OpenXR gaze sources and combines them as follows
(**static**):

- `XRQGetSocialEyeTracking(ctx, XRQEyeVector&)` (0x138b74), using FB social eye
  tracking (`xrGetEyeGazesFB`).
- `QSVLDeviceHmd::GetInteractionGaze(ctx, XrVector3f*)` (0x100f4c), using the
  `XR_EXT_eye_gaze_interaction` pose action (`pamir_eye_tracking_pose`).

| social | interaction | gaze written | valid |
|---|---|---|---|
| no | no | (0, 0, 1.0) | 0 |
| yes | no | the social vector | 1 |
| no | yes | the interaction vector | 1 |
| yes | yes | interaction vector × length(social vector) | 1 |

The gaze vector is a head-space direction whose magnitude carries the
convergence (focus) distance when social eye tracking supplies one, whereas the
interaction gaze is a unit vector (**inferred**; confirmed by client testing
below). The exact construction of the social vector inside
`XRQGetSocialEyeTracking` was not traced.

Face data is included when `QSVLDeviceHmd+0x1b8` is set (**inferred**: a face
tracker was created; strings `XR_FB_face_tracking`,
`com.oculus.permission.FACE_TRACKING`, `[XRQ] Face tracking supported: %s`).
The weights buffer is `QSVLDeviceHmd+0x98` (70 floats) and the confidences
`+0x1b0` (2 floats), filled by `XRQGetFaceTracking` (0x13b2b4) with an
`XrFaceExpressionWeights2FB` of `weightCount = 0x46`, `confidenceCount = 2`.
PICO eye/face entry points (`xrGetFaceTrackingDataPICO`,
`xrStartEyeTrackingPICO`) exist in the XRQ layer; whether PICO face data is
converted into this same 70-weight layout was not traced.

## Capture check (`vr3`)

Unless marked otherwise, everything in this section is **captured** from `vr3`,
a Klepton session without eye or face tracking (`vrlink` logs
`Eye gaze interaction supported: No`, `FB Eye tracking Social supported: No`,
and `Face tracking supported: No`). The capture contains 17,020 type-`0x11`
messages.

All 17,020 messages are byte-identical, starting with header
`03 11 00 00 11 00 00 00` (element id 0, length 0x11 = 17, index 0) followed by
these 17 payload bytes:

| dataset off | bytes | field | value |
|---|---|---|---|
| 0x08 | `00 00 00 00` | gaze x | 0.0 |
| 0x0c | `00 00 00 00` | gaze y | 0.0 |
| 0x10 | `00 00 80 3f` | gaze z | 1.0 |
| 0x14 | `00` | expression format | 0 = none |
| 0x15 | `00` | gaze valid | 0 |
| 0x16 | `00` | expression count | 0 |
| 0x17 | `00 00` | unused | 0 |

This matches the first row of the combination table above (no social or
interaction gaze): the placeholder vector (0, 0, 1.0) with `gaze valid = 0`.
Because no byte varies over the session, this confirms the 25-byte short layout
on the wire and verifies that `vrlink` sends it on every tick even with no eye
tracker.

Message cadence relative to pose packets ([poses.md](poses.md)):

- Once eye messages start, `vrlink` sends exactly one per pose packet,
  traveling one datagram behind: the eye message is always the first element of
  a datagram ending in a pose dataset (`[3/0x11] [3/0x07] [4/0x0f] [3/0x01]`)
  and never travels in a datagram of its own. This matches
  `SubmitMessage(msg, false, false)` queueing the eye message after pose *k*
  and the next pose's `SubmitMessage(..., false, true)` flushing it.
- The first 403 pose datagrams (0..0.926 s) have no eye element; every one of
  the 17,020 pose datagrams after that has one (`17,423 − 403 = 17,020`, with
  no gaps). (`vr1`'s 1,241 vs 1,637 count reflected the same startup gap,
  blurred by torn datagrams.)
- `SendPoses` calls `HandleEyeInput` only when `SVLRoot::BIsConnectionActive()`
  returns true, reading the byte at `SVLRoot+0xc78` (0x165a04, **static**).
  Pose packet 402 (sent at 0.930 s) queued the first eye message; it was also
  the first pose packet sent after the first video packet arrived (0.926 s),
  the first with a non-zero clock offset at 0x0c, and the first without startup
  value-transport bytes. All four change together because the connection is
  marked active upon receiving the host's first stream traffic rather than its
  first inbound datagram (**inferred**; the host had already been sending value
  messages since 4 ms). The exact code path that sets `+0xc78` was not traced.

The 313-byte face variant, valid gaze vectors, and expression formats other
than 0 do not occur in `vr3`.

## Client results (2026-11-10): gaze vector coordinates and foveation

Tested with `client` on macOS (**captured**) using a motionless head, 63 mm
eye spacing, and symmetric frusta, reading the center of the left eye's foveal
tile (as tangents) from each frame's inset record:

| gaze sent (x, y, z), valid = 1 | left fovea center x, y |
|---|---|
| (0, 0, -1) | 0.031, 0.000 |
| (0.3, 0, -1) | 0.331, 0.000 |
| (0, 0.3, -1) | 0.031, 0.301 |
| (0.6, 0, -2) | 0.316, 0.000 |
| (0.3, 0, +1) | 0.006, -0.100 |

From these measurements:

- The host steers its foveal tile along the gaze vector every frame. The vector
  is in **head space with +X right, +Y up, and −Z forward** (matching OpenXR
  view space).
- **Vector length encodes fixation distance in meters.** The left eye's fovea
  shifts right of the gaze direction by half the eye spacing divided by that
  distance: 0.031 for a 1 m vector (`0.0315 / 1`), and 0.016 for the same
  direction at 2.09 m. The host converges both eyes' foveal regions onto the 3D
  fixation point.
- A vector pointing behind the head (+Z) is treated the same as an invalid gaze
  (`valid = 0`), placing the fovea at a fixed fallback position slightly below
  center (0.006, −0.100).
- The foveal tile's half-width stayed 0.466 throughout.

`client` queues this message with every pose in the same position as `vrlink`
(first element of the pose datagram). On visionOS, where apps do not receive
raw eye-tracking vectors, `client` estimates gaze from the densest point of
each eye's rasterization rate map
(`Sources/VRLinkVisionCompositor/GazeFromFoveation.swift`); that path had not
run on a headset as of this test. The 313-byte form with face expressions is
implemented and unit-tested for size and field placement (see below).

## Client results (2026-11-10): 313-byte face expression packet

Tested with `client` on macOS (**captured**) with experimental face tracking
enabled using the Mac's built-in camera: `client` sent the 313-byte packet
(expression format 2, count 70, both confidences 1.0, weights updating every
camera frame, `gaze valid = 0`) alongside every pose for a 45 s session. Video
streamed steadily at 120 frames/s throughout, and neither `driver_vrlink.txt`
nor `vrserver.txt` on the host logged any errors or warnings mentioning face,
expression, or eye tracking. The host accepts the 313-byte face layout without
requiring `gaze valid = 1`. Whether SteamVR forwards those weights to
applications was not tested, since nothing reading face weights was running on
the host.

See "Experiments" in [../client-architecture.md](../client-architecture.md) for
how `client` derives face weights on platforms without native face tracking and
calibrates gaze without raw eye tracking.

## Open questions / to confirm on the wire

- What sets `SVLRoot+0xc78` (connection active), which gates this message.
- ✅ The host does not require this message (earlier sessions sent none) and
  steers its foveal region along the gaze vector; coordinate frame and units
  are confirmed above.
- What the host does with the face weights, and whether it requires
  `gaze valid = 1` to forward them.
- Whether expression format values other than 0 and 2 exist (1 is unused here;
  **inferred**: FB face tracking v1 with 63 weights, or a PICO layout).
