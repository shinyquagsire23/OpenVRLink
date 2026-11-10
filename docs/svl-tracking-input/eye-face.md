# Eye gaze and face expressions

Client → host, message type `0x11`, unreliable, one per pose packet while the
link is active (`QSVLClient::SendPoses` → vtable slot 0x150 →
`QSVLClientXR::HandleEyeInput` 0xfb6ec → `SubmitMessage(msg, false, false)`).
The message is sent **every tick even with no eye tracker**; the validity byte
says whether the gaze is real.

## `EyeAndExpressions_t`

**static**: `QSVLDeviceHmd::HandleEyeInput` (0x100da0); the caller zeroes a
0x139-byte buffer first.

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

Total message size: 8 + 0x11 = 25 bytes, or 8 + 0x131 = 313 bytes.

Gaze sources and combination (**static**):

- `XRQGetSocialEyeTracking(ctx, XRQEyeVector&)` (0x138b74): FB social eye
  tracking (`xrGetEyeGazesFB`).
- `QSVLDeviceHmd::GetInteractionGaze(ctx, XrVector3f*)` (0x100f4c):
  `XR_EXT_eye_gaze_interaction` pose action (`pamir_eye_tracking_pose`).

| social | interaction | gaze written | valid |
|---|---|---|---|
| no | no | (0, 0, 1.0) | 0 |
| yes | no | the social vector | 1 |
| no | yes | the interaction vector | 1 |
| yes | yes | interaction vector × length(social vector) | 1 |

**inferred**: the vector is a gaze direction in head space whose length
carries the convergence (focus) distance when social eye tracking supplies one;
the interaction gaze is a unit direction. The exact construction of the social
vector is in `XRQGetSocialEyeTracking`, not read.

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

**captured** unless marked. `vr3` is a Klepton session with no eye or face
tracking (client log: `Eye gaze interaction supported: No`,
`FB Eye tracking Social supported: No`, `Face tracking supported: No`). It
holds 17,020 type-0x11 messages.

Content: all 17,020 are byte-identical. Header `03 11 00 00 11 00 00 00`
(element id 0, length 0x11 = 17, index 0), then these 17 payload bytes:

| dataset off | bytes | field | value |
|---|---|---|---|
| 0x08 | `00 00 00 00` | gaze x | 0.0 |
| 0x0c | `00 00 00 00` | gaze y | 0.0 |
| 0x10 | `00 00 80 3f` | gaze z | 1.0 |
| 0x14 | `00` | expression format | 0 = none |
| 0x15 | `00` | gaze valid | 0 |
| 0x16 | `00` | expression count | 0 |
| 0x17 | `00 00` | unused | 0 |

That is the first row of the table above (no social, no interaction gaze):
the placeholder vector (0, 0, 1.0) with the valid byte clear. No byte varies
over the session, so the "17-byte message" is the short layout exactly, 25
bytes on the wire with its header, and the client does send it on every tick
with no eye tracker at all.

Cadence, against the pose packets ([poses.md](poses.md)):

- Exactly one eye message per pose packet once it starts, traveling one
  datagram behind: it is always the first element of a datagram that ends in
  a pose dataset (`[3/0x11] [3/0x07] [4/0x0f] [3/0x01]`), never in a datagram
  of its own. This fits `SubmitMessage(msg, false, false)` queueing it after
  pose *k* and the next pose's `(false, true)` flushing it.
- The first 403 pose datagrams (0..0.926 s) have no eye element; every one of
  the 17,020 after that has exactly one. So 17,423 − 403 = 17,020, with no
  gaps. (`vr1`'s 1241 vs 1637 was the same start-up gap, blurred by torn
  datagrams.)
- Why it starts late: `SendPoses` only calls `HandleEyeInput` when
  `SVLRoot::BIsConnectionActive()` is true, which is the byte at
  `SVLRoot+0xc78` (**static**, 0x165a04). The first eye message was queued by
  pose packet 402, sent at 0.930 s. That is the first pose packet after the
  first video packet arrived (0.926 s), the first with a non-zero clock
  offset at 0x0c, and the first without start-up value-transport bytes.
  **inferred**: all four change together because the connection is marked
  active by the host's first stream traffic, not by the first inbound
  datagram (the host had been sending value messages since 4 ms). What
  exactly sets `+0xc78` was not traced.

The 313-byte face variant, a valid gaze, and expression formats other than 0
do not occur in `vr3`.

## Client results (2026-11-10): the fovea follows the gaze

**Captured by client** (`client` on macOS, a motionless head, eyes 63
mm apart, symmetric frusta; the center of the left eye's foveal tile read from
each frame's inset record, as tangents):

| gaze sent (x, y, z), valid = 1 | left fovea center x, y |
|---|---|
| (0, 0, -1) | 0.031, 0.000 |
| (0.3, 0, -1) | 0.331, 0.000 |
| (0, 0.3, -1) | 0.031, 0.301 |
| (0.6, 0, -2) | 0.316, 0.000 |
| (0.3, 0, +1) | 0.006, -0.100 |

So:

- The host aims its foveal tile along the gaze every frame. The vector is in
  the **head's frame, x right, y up, -z forward** (the OpenXR view space).
- **Its length is the fixation distance in meters.** The left eye's fovea
  sits right of the gaze direction by half the eye spacing over that
  distance: 0.031 for a 1 m vector (0.0315 / 1), 0.016 for the same
  direction at 2.09 m. The host converges the two eyes' foveae on the point.
- A vector pointing behind the head is treated like no gaze: the fovea goes
  to a fixed place, slightly below center (0.006, -0.100), which is also
  where it sits when the valid byte is clear.
- The foveal tile's half-width stayed 0.466 throughout.

`client` sends this message with every pose, in the reference
client's place (first element of the pose datagram). On visionOS, which
gives apps no eye tracking, the gaze is taken from the densest point of each
eye's rasterization rate map (`Sources/VRLinkVisionCompositor/GazeFromFoveation.swift`);
that has not run on a headset yet. The 313-byte form with face expressions
is built and unit-tested for size and field placement; see the next section
for the first time it was sent.

## Client results (2026-11-10): the face form is accepted

**Captured by client** (`client` on macOS, the face experiment on,
the Mac's own camera as the source): the 313-byte form (expression format 2,
count 70, both confidences 1.0, weights changing every camera frame, gaze
not valid) was sent with every pose for a 45 s session. The stream ran at
120 frames/s throughout, and the host's `driver_vrlink.txt` and
`vrserver.txt` have no line mentioning face, expression or eye tracking for
that session. So the host takes the long form without complaint and without
needing a valid gaze beside it. Whether SteamVR passes the weights on to
applications was not checked: nothing was run on the host that reads them.

Where the weights come from on a platform without face tracking, and how a
gaze is calibrated on one without eye tracking, is in
[../client-architecture.md](../client-architecture.md), "Experiments".

## Open questions / to confirm on the wire

- What sets `SVLRoot+0xc78` (connection active), which gates this message.
- ✅ The host does not require this message (earlier sessions sent none) and
  its fovea follows the gaze; frame and units are above.
- What the host does with the face weights, and whether it needs the gaze
  valid for them.
- Whether expression format values other than 0 and 2 exist (1 is unused here;
  **inferred**: FB face tracking v1 with 63 weights, or a PICO layout).
