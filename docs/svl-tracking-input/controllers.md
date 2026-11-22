# Controller input encoding

Controller input flows from client to host inside the pose packet
([poses.md](poses.md)) as two 28-byte blocks (left at 0x30, right at 0x4c).
There is no separate button message.

## Wire block (28 bytes per hand)

In `QSVLClient::SendPoses` (0xf4d34, **static**), two loops over the
`QSVLControllerInputState` vectors pack one 28-byte block per hand:

| off | type | field |
|---|---|---|
| 0x00 | u64 | `inputType 0` bits ("click"): bit *i* = value of the action with `inputTypeIndex` *i* |
| 0x08 | u64 | `inputType 1` bits ("touch"): bit *i* likewise |
| 0x10 | u8 | 1 if `QSVLControllerState+0x78 == 1`, else 0. The source is `QSVLXRInput+0x188` (left) / `+0x18c` (right), written only by `SetActiveInteractionProfiles` (0x107010): 1 when the hand has no interaction profile and hand tracking is set up (`XRQContext+0x118d` bit 0; log `No interaction profile for %s hand specified, but hand tracking is setup so using that.`), else 0. Indicates that the hand is using hand tracking rather than a controller (**static**) |
| 0x11 | i8×11 | `inputType 2` analog values: byte *i* = `(int8)(value * 127.0)` for the action with `inputTypeIndex` *i* |

Bits are OR-ed as `(int64)(int32)(value_byte << (index & 0x1f))` (**static**),
so only indices 0..31 are usable and index 31 sign-extends into the upper 32
bits. Unused bits and bytes are zero. Float axes are truncated toward zero into
the range −127..127 (−1.0 encodes as 0x81).

## Action-to-bit mapping

`QSVLXRInput::GetControllerState_Controller` (0x10722c, **static**) walks the
action list (0x68-byte entries at `QSVLXRInput+0x40`). Each entry holds an
OpenXR action, an `actionType` (1 = boolean via `xrGetActionStateBoolean`,
2 = float via `xrGetActionStateFloat`; anything else logs
`[XRInput] Unknown input type! %i`), and an 8-byte `{inputType, inputTypeIndex}`
pair copied verbatim into the 12-byte `QSVLControllerInputState`
`{u32 type; u8 index; pad; u8 value}`. An entry is written only when the action
is bound for that hand's subaction path and `isActive` is true.

The action mapping comes from `inputActions[]` in
`assets/config/controller_config.json` rather than being compiled into the
binary. In this APK, the bindings are:

| inputType | index | wire location | binding (oculus/touch_controller; L / R) |
|---|---|---|---|
| 1 touch | 0 | touch bit 0 | `x/touch` / `a/touch` |
| 1 | 1 | touch bit 1 | `y/touch` / `b/touch` |
| 1 | 2 | touch bit 2 | `trigger/touch` |
| 1 | 3 | touch bit 3 | `thumbstick/touch` |
| 1 | 4 | touch bit 4 | `thumbrest/touch` |
| 0 click | 0 | click bit 0 | `x/click` / `a/click` |
| 0 | 1 | click bit 1 | `y/click` / `b/click` |
| 0 | 2 | click bit 2 | `menu/click` (left hand only, `subActionPathHand: 0`) |
| 0 | 3 | click bit 3 | `thumbstick/click` |
| 0 | 4 | click bit 4 | `squeeze/click` (vive_focus3 only) |
| 0 | 5 | click bit 5 | `trigger/click` (vive_focus3 only) |
| 2 axis | 0 | axis byte 0 | `trigger/value` |
| 2 | 1 | axis byte 1 | `thumbstick/x` |
| 2 | 2 | axis byte 2 | `thumbstick/y` |
| 2 | 3 | axis byte 3 | `squeeze/value` |

Axis bytes 4..10 are unused by this config. On the host (**inferred**), these
indices map onto the SteamVR input profile named by the controller's static
props (`sInputProfilePath`, e.g. `{oculus}/input/touch_profile.json`); the
host-side mapping table is not in this binary.

## Interaction profile

- The active profile per hand (**static**) is an `XrPath` at
  `QSVLXRInput+0x150` (left) / `+0x158` (right), set by
  `SetActiveInteractionProfiles` (0x107010) under the mutex at `+0x160`.
  A zero path means no controller is active in that hand.
- In `GetControllerStates` (0x107104, **static**), a hand with a non-zero
  profile is read through OpenXR actions. With a zero profile and host version
  ≥ 7, the hand falls back to hand tracking (below); with version < 7, a zero
  profile produces tracking result 1 and state 0.
- The profile also selects the pose offset ([poses.md](poses.md)) and the
  controller's static props (docs/svl-values/). Klepton's finding that an
  `XR_NULL_PATH` result suppresses `VTE_PROPS_STATIC_L/R` matches this code,
  which publishes nothing for a hand without a profile.

## Hand tracking presented as a controller (host version ≥ 7)

This fallback is implemented in `QSVLXRInput::GetControllerState_HandTracking`
(0x107ca4, **static**), with constants initialized in
`QSVLXRInput::QSVLXRInput` (0x1037e0, **static**).

- **Pose**: Uses the raw OpenXR **wrist joint** (joint 1) pose from
  `xrLocateHandJoints` at `now + 30 ms` in the hand tracker's base space,
  sending position and orientation (`w` first on the wire) with no coordinate
  conversion. Linear and angular velocity come from the wrist's
  `XrHandJointVelocityEXT`, low-pass filtered as `v = 0.8·v_prev + 0.2·v_new`
  per hand (each updated only when its velocity-valid flag is set), and are
  **not** rotated into the body frame like controller angular velocity.
  Tracking result is 200 when both of the wrist's valid bits are set, or 1
  otherwise; state is always 2, and the trailing `u32` is 0.
- **Offset pose**: The 7 floats at 0x38 of `PackedPose_t` are hard-coded in the
  constructor (`QSVLXRInput+0x288 + hand*0x1c`) with orientation
  `Rz(∓90°)·Rx(45°)`:

| hand | offset position | offset orientation (w, x, y, z) |
|---|---|---|
| left | (0.09, −0.02, −0.15) | (0.65328, 0.27060, −0.27060, −0.65328) |
| right | (−0.09, −0.02, −0.15) | (0.65328, 0.27060, 0.27060, 0.65328) |

- **Buttons**: Read from `SkeletalGestureInfo` (0x18 bytes per hand at
  `QSVLXRInput+0x380`). Because `GetHandTracking` ([skeleton.md](skeleton.md))
  zeroes and recomputes this struct *after* the pose packet is built, the pose
  packet carries the previous tick's gestures:

| wire location | source | meaning |
|---|---|---|
| click bit 0 | `info+0x08` (bool) | index pinch |
| click bit 1 | `info+0x10` (bool) | grip: all four fingers curled |
| axis byte 0 | `info+0x04` (float × 127) | index pinch strength, 0 or 1 |
| axis byte 1 | `info+0x0c` (float × 127) | grip strength, 0 or 1 |

  Touch bits and the other axis bytes stay 0; input-block byte 0x10 is 1.
- If hand joints report inactive for more than 2 s (steady clock, deadline at
  `+0x2c8`), the hand is reported absent (tracking result 1, state 0).
- Static props for a tracked hand are hard-coded and power props are constant
  (see docs/svl-values/static-and-power-props.md).

### Hand gestures (`SkeletalGestures::Compute`, 0x130be0)

`SkeletalGestures::Compute` (**static**) takes the 26 hand joints, the Meta aim
state's `status` flags (`XrHandTrackingAimStateFB+0x10`), and the previous
tick's result for hysteresis. The output struct is zeroed before each call.

`GetFingerCurlDegrees` (0x130914, **static**) computes finger curl for finger
`f = 0..3` (index, middle, ring, little) as the angle in degrees (0..180)
between the −Z (forward) axis of the finger's **proximal** joint (`J[7+5f]`)
and that of its **tip** joint (`J[10+5f]`). In the table below, "curled" means
curl > 120° (> 80° if the gesture was already active on the previous tick); the
code also checks < 300°, which is always true.

| field | meaning | computed as |
|---|---|---|
| `+0x00` bool | menu (left hand only) | aim status bit 8 (`MENU_PRESSED`), and middle, ring and little fingers not curled past 120°. When set, the rest of the struct is left zero for the next 200 ms |
| `+0x04` float, `+0x08` bool | index pinch | aim status bit 2 (`INDEX_PINCHING`); strength is 1.0 or 0.0, not analog. Only evaluated if it was already on, or if the hand is not palm-up: with u = the wrist's +Y axis in the base space, `abs(atan2(−u.x, −u.y)) ≥ 30°` |
| `+0x11`, `+0x12`, `+0x13` bool | middle, ring, little pinch | aim status bits 3, 4, 5 |
| `+0x0c` float, `+0x10` bool | grip | all four fingers curled; strength 1.0 |
| `+0x14` bool | point | index curl < 18° (< 40° if already on) and middle, ring, little curled |

Pinch detection relies on the OpenXR runtime (`XR_FB_hand_tracking_aim`) rather
than computing joint distances directly, so a client without that extension must
detect pinches itself. The Meta runtime's exact thresholds are external to this
binary.

## Capture check (`vr3`)

Across all 17,423 pose packets of `vr3` (**captured**, a desktop-view session
under Klepton whose OpenXR runtime presents two synthetic Touch controllers;
`vrlink` logs `Setting active interaction profile for left hand to:
/interaction_profiles/oculus/touch_controller` and the same for the right):

- Both 28-byte input blocks are all zero in every packet (no click bits, no
  touch bits, byte 0x10 = 0, and all eleven axis bytes = 0).
- Both controller poses are present and valid from the first packet and remain
  byte-identical across the entire 40 s capture. Left is at position
  (−0.22, 1.35, −0.40) with orientation (w, x, y, z) = (0.9483, 0.3173, 0, 0),
  pitched 37° about +x; right is identical with x = +0.22. Linear and angular
  velocity are zero, tracking result is 200, state is 2, and the trailing `u32`
  is 0.
- The offset pose per hand has position (∓0.007, −0.0342, −0.0961) and
  orientation (0.9839, −0.1788, 0, 0) for both hands, matching the Touch entry
  in `controller_config.json` with x mirrored for the right hand
  ([poses.md](poses.md)).
- The HMD-input "no controller" bit (flags bit3) is set in packet 0 only, even
  though packet 0 already carries both poses; see [poses.md](poses.md) for why
  it lags by one packet.

`vr3` contains no packets with an absent controller (tracking result 1 /
state 0), no packets in "no input" mode (all-zero pose blocks, which `vr1` had
in 1,020 of 1,637 packets), no hand-tracked hands, and no set button, touch, or
axis bits (**captured** negatives). The index table above therefore remains
**static** only in `vr3`.

## Client results

Sending synthetic hands from the OpenVRLink macOS viewer against a SteamVR host
speaking protocol version 14 (**captured**):

- Publishing no controller values at startup and then, on the first pose
  packet, publishing 0x0e/0x0f (the Touch strings) and 0x11/0x12 while sending
  valid grip poses with the Touch offset pose causes SteamVR Home to render two
  Quest 2 controllers at those poses with pointer rays. Controller identity can
  therefore be published after the session has started.
- Sending a hand as a tracked hand — publishing the hand static props (driver
  type 1) once the host version is known after the first bookend (mid-stream),
  sending the wrist pose with the hand offset pose, setting input-block byte
  0x10 = 1, and sending one `0x17` message per pose packet in its own
  datagram — is accepted by the host. The host keeps streaming at full frame
  rate and draws a small pointer marker at the hand's position. Sending a Touch
  controller on the other hand in the same session also works, confirming that
  controller and tracked-hand inputs can be mixed.
- Leaving a hand absent (tracking result 1 / state 0 with the rest of the pose
  zeroed) causes the host to draw nothing for that hand.

In an early Vision Pro run with PS VR2 Sense controllers and bare hands,
controllers appeared and tracked physical movement but swam when poses were
sent unpredicted. Tracked hands appeared and mostly lined up with the user's
hands, though pinching had no effect in SteamVR and a hand vanished when partly
closed (due to an early bug that dropped the hand whenever any single joint was
occluded). Whether the pinch gesture reaches the host as a button press is
resolved in [skeleton.md](skeleton.md).

That initial run did not exercise button presses, analog axes, active gestures,
haptics, or articulated hand skeletons (the synthetic macOS hand is flat).

## Client results: button bit verification

Holding one control at a time on two synthetic Touch controllers in the macOS
viewer (**captured**) and checking whether the corresponding part of SteamVR's
rendered controller model moved (measured by differencing screenshots of the
button region against an idle baseline; regions of the controller body away
from the buttons changed by 0 pixels in every case):

| held | bit sent | left model | right model |
|---|---|---|---|
| lower face button | click bit 0 | moves | moves |
| upper face button | click bit 1 | moves | moves |
| menu | click bit 2 | moves | does not |
| stick click | click bit 3 | moves | moves |

Click bits 0, 1, and 3 match the action table above for both hands, and bit 2
applies to the left hand only, matching `vrlink`'s configuration. On a headset,
trigger and grip (axis bytes 0 and 3) also animate the corresponding parts on
the controller model.

## Open questions / to confirm on the wire

- Press each button on a Touch controller and watch the bit named above flip
  in the 0x30 / 0x4c blocks; push the stick and confirm axis bytes 1/2 as
  signed ±127.
- Byte 0x10 of each block is the tracked-hand flag (**static**); a wire capture
  with bare hands would confirm how `vrlink` sends it.
- Whether the host needs the thumbstick deadzoned or raw.
- Whether the host accepts axis indices above 3 or click bits above 5 for
  other controller types.
- What the host binds the pinch / grip / gesture bits to (its `svl_hand_interaction_augmented` input profile).
