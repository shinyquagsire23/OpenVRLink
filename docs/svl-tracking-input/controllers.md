# Controller input encoding

Client → host, carried inside the pose packet ([poses.md](poses.md)) as two
28-byte blocks (left at 0x30, right at 0x4c). There is no separate button
message.

## Wire block (28 bytes per hand)

**static**: `QSVLClient::SendPoses` (0xf4d34), the two loops over the
`QSVLControllerInputState` vectors.

| off | type | field |
|---|---|---|
| 0x00 | u64 | `inputType 0` bits ("click"): bit *i* = value of the action with `inputTypeIndex` *i* |
| 0x08 | u64 | `inputType 1` bits ("touch"): bit *i* likewise |
| 0x10 | u8 | 1 if `QSVLControllerState+0x78 == 1`, else 0. The source is `QSVLXRInput+0x188` (left) / `+0x18c` (right), written only by `SetActiveInteractionProfiles` (0x107010): 1 when the hand has no interaction profile and hand tracking is set up (`XRQContext+0x118d` bit 0; log `No interaction profile for %s hand specified, but hand tracking is setup so using that.`), else 0. So: "this hand is a tracked hand, not a controller" (**static**) |
| 0x11 | i8×11 | `inputType 2` analog values: byte *i* = `(int8)(value * 127.0)` for the action with `inputTypeIndex` *i* |

Packing detail (**static**): bits are OR-ed as
`(int64)(int32)(value_byte << (index & 0x1f))`, so only indices 0..31 are
usable and index 31 would sign-extend into the top half. Unused bits/bytes are
zero. A float axis is truncated toward zero, range −127..127; −1.0 → 0x81.

## Where the bit numbers come from

**static**: `QSVLXRInput::GetControllerState_Controller` (0x10722c) walks the
action list (0x68-byte entries at `QSVLXRInput+0x40`). Each entry has an OpenXR
action, an `actionType` (1 = boolean via `xrGetActionStateBoolean`, 2 = float
via `xrGetActionStateFloat`; anything else logs
`[XRInput] Unknown input type! %i`), and an 8-byte `{inputType, inputTypeIndex}`
pair copied verbatim into the 12-byte `QSVLControllerInputState`
`{u32 type; u8 index; pad; u8 value}`. A state is only written when the action
is bound for that hand's subaction path and `isActive` is true.

The table is not in the binary; it is `inputActions[]` in
`assets/config/controller_config.json`. For this APK:

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

Axis bytes 4..10 are unused by this config. **inferred**: the host maps these
indices onto the SteamVR input profile named by the controller's static props
(`sInputProfilePath`, e.g. `{oculus}/input/touch_profile.json`); the mapping
table itself is host-side and not visible here.

## Interaction profile

- **static**: the active profile per hand is an `XrPath` at
  `QSVLXRInput+0x150` (left) / `+0x158` (right), set by
  `SetActiveInteractionProfiles` (0x107010) under the mutex at `+0x160`.
  A zero path means "no controller in this hand".
- **static**: `GetControllerStates` (0x107104): with a non-zero profile the
  hand is read through OpenXR actions; with a zero profile and host version
  ≥ 7 the hand falls back to hand tracking (below); with version < 7 a zero
  profile gives tracking result 1 / state 0.
- The profile also selects the pose offset ([poses.md](poses.md)) and the
  controller's static props (docs/svl-values/). Klepton's finding that an
  `XR_NULL_PATH` answer suppresses `VTE_PROPS_STATIC_L/R` is consistent with
  this code: nothing is published for a hand without a profile.

## Hand tracking presented as a controller (host version ≥ 7)

**static**: `QSVLXRInput::GetControllerState_HandTracking` (0x107ca4),
`QSVLXRInput::QSVLXRInput` (0x1037e0) for the constants.

- Pose: the raw OpenXR **wrist joint** (joint 1) pose from
  `xrLocateHandJoints` at now + 30 ms, in the hand tracker's base space:
  position, orientation (w first on the wire), no conversion. Linear and
  angular velocity are the wrist's `XrHandJointVelocityEXT`, low-pass
  filtered `v = 0.8·v_prev + 0.2·v_new` per hand (each only updated when its
  velocity-valid flag is set), and **not** rotated into the body frame the
  way controller angular velocity is. Tracking result 200 when the wrist's
  two valid bits are set, else 1; state is always 2; trailing u32 0.
- Offset pose (the 7 floats at 0x38 of `PackedPose_t`; hard-coded in the
  constructor, `QSVLXRInput+0x288 + hand*0x1c`), orientation = Rz(∓90°)·Rx(45°):

| hand | offset position | offset orientation (w, x, y, z) |
|---|---|---|
| left | (0.09, −0.02, −0.15) | (0.65328, 0.27060, −0.27060, −0.65328) |
| right | (−0.09, −0.02, −0.15) | (0.65328, 0.27060, 0.27060, 0.65328) |

- Buttons from `SkeletalGestureInfo` (0x18 bytes per hand at
  `QSVLXRInput+0x380`). Note it is zeroed and recomputed by
  `GetHandTracking` ([skeleton.md](skeleton.md)), which runs *after* the pose
  packet is built, so the pose packet carries the previous tick's gestures:

| wire location | source | meaning |
|---|---|---|
| click bit 0 | `info+0x08` (bool) | index pinch |
| click bit 1 | `info+0x10` (bool) | grip: all four fingers curled |
| axis byte 0 | `info+0x04` (float × 127) | index pinch strength, 0 or 1 |
| axis byte 1 | `info+0x0c` (float × 127) | grip strength, 0 or 1 |

  Touch bits and the other axis bytes stay 0; input-block byte 0x10 is 1.
- If hand joints report inactive for more than 2 s (steady clock, deadline at
  `+0x2c8`) the hand is reported absent (tracking result 1, state 0).
- Static props for a tracked hand are hard-coded, and power props are a
  constant: docs/svl-values/static-and-power-props.md.

### Hand gestures (`SkeletalGestures::Compute`, 0x130be0)

**static**. Inputs: the 26 joints, the Meta aim state's `status` flags
(`XrHandTrackingAimStateFB+0x10`), the previous result for the hand (kept for
hysteresis). The info struct is all zero before each call.

Finger curl (`GetFingerCurlDegrees` 0x130914), for finger f = 0..3 = index,
middle, ring, little: the angle in degrees (0..180) between the −Z (forward)
axis of the finger's **proximal** joint (J[7+5f]) and that of its **tip**
joint (J[10+5f]). "Curled" below means curl > 120° (> 80° if the gesture was
already on last time); the code also tests < 300°, always true.

| field | meaning | computed as |
|---|---|---|
| `+0x00` bool | menu (left hand only) | aim status bit 8 (`MENU_PRESSED`), and middle, ring and little fingers not curled past 120°. When set, the rest of the struct is left zero for the next 200 ms |
| `+0x04` float, `+0x08` bool | index pinch | aim status bit 2 (`INDEX_PINCHING`); strength is 1.0 or 0.0, not analog. Only evaluated if it was already on, or if the hand is not palm-up: with u = the wrist's +Y axis in the base space, `abs(atan2(−u.x, −u.y)) ≥ 30°` |
| `+0x11`, `+0x12`, `+0x13` bool | middle, ring, little pinch | aim status bits 3, 4, 5 |
| `+0x0c` float, `+0x10` bool | grip | all four fingers curled; strength 1.0 |
| `+0x14` bool | point | index curl < 18° (< 40° if already on) and middle, ring, little curled |

The pinches come from the runtime (`XR_FB_hand_tracking_aim`), not from
joint distances; a client without that extension has to detect pinches
itself. The exact thresholds the Meta runtime uses are not in this binary.

## Capture check (`vr3`)

**captured**, all 17,423 pose packets of `vr3` (a desktop-view session under
Klepton, whose OpenXR runtime presents two synthetic Touch controllers; the
client log shows `Setting active interaction profile for left hand to:
/interaction_profiles/oculus/touch_controller`, and the same for the right):

- Both 28-byte input blocks are all zero in every packet: no click bit, no
  touch bit, byte 0x10 = 0, all eleven axis bytes 0.
- Both controller poses are present and valid from the very first packet and
  are byte-identical for the whole 40 s. Left: position (−0.22, 1.35, −0.40),
  orientation (w,x,y,z) = (0.9483, 0.3173, 0, 0), i.e. pitched 37° about +x;
  right: the same with x = +0.22. Linear and angular velocity zero, tracking
  result 200, state 2, trailing u32 0.
- Offset pose per hand: position (∓0.007, −0.0342, −0.0961), orientation
  (0.9839, −0.1788, 0, 0) for both. That matches the Touch entry of
  `controller_config.json` with x mirrored for the right hand
  ([poses.md](poses.md)).
- The HMD-input "no controller" bit (flags bit3) is set in packet 0 only,
  although packet 0 already carries both poses; see poses.md for why it lags.

Captured negatives in `vr3`: no packet with an absent controller (tracking
result 1 / state 0), none in "no input" form (all-zero pose blocks, which
`vr1` had in 1020 of 1637 packets), no hand-tracked hand, and no button,
touch or axis bit ever set. The index table above is therefore still
**static** only.

## Client results (2026-11-10)

**Captured by client** (`client`, the macOS viewer with made-up
hands, against the real host, protocol version 14):

- A client that publishes no controller values at start and then, on the
  first pose packet, publishes 0x0e/0x0f (the Touch strings) and 0x11/0x12,
  while sending valid grip poses with the Touch offset pose, gets two Quest 2
  controllers drawn in SteamVR Home at the poses sent, with a pointer ray.
  So controller identity can be published after the session has begun.
- A hand sent as a tracked hand - the hand static props with driver type 1
  published once the host version is known (after the first bookend, so
  mid-stream), the wrist pose with the hand offset pose, input-block byte
  0x10 = 1, and one `0x17` message per pose packet in a datagram of its
  own - is accepted: the host keeps streaming at the full rate and draws a
  small pointer marker where the hand is. The other hand was a Touch
  controller in the same session, so the two kinds mix.
- A hand left absent is sent as tracking result 1 / state 0 with the rest of
  the pose zero; the host draws nothing for it.

First headset run (Vision Pro, PS VR2 Sense controllers and bare hands, as
reported by the wearer): controllers appear and follow the real ones but
swim, having been sent unpredicted; hands appear and mostly line up with
the real hands; pinching had no effect in SteamVR; a hand vanished when
partly closed (a client fault: it dropped the hand whenever one joint was
hidden). Whether the pinch reaches the host as a button is still open.

Not yet seen: any button, axis or gesture having an effect (nothing was
pressed), haptics, and a real hand skeleton (the made-up hand is flat).

## Client results (2026-11-10): the button bits, seen working

**Captured by client** (`client` on macOS holding one control at a
time on two pretend controllers of the Touch type; SteamVR's controller model
watched for the matching part moving, by differencing captures of the
button area against an idle capture; areas of the controller body away from
the buttons changed by 0 pixels in every case):

| held | bit sent | left model | right model |
|---|---|---|---|
| lower face button | click bit 0 | moves | moves |
| upper face button | click bit 1 | moves | moves |
| menu | click bit 2 | moves | does not |
| stick click | click bit 3 | moves | moves |

So click bits 0, 1 and 3 are what the table above says for both hands, and
bit 2 acts on the left hand only, as vrlink's configuration
has it. (Trigger and grip, axis bytes 0 and 3, move the model's parts on a
headset, reported by the wearer.)

## Open questions / to confirm on the wire

- Press each button on a Touch controller and watch the bit named above flip
  in the 0x30 / 0x4c blocks; push the stick and confirm axis bytes 1/2 as
  signed ±127.
- Byte 0x10 of each block is the tracked-hand flag by static reading; a
  capture with bare hands would confirm the host sees it.
- Whether the host needs the thumbstick deadzoned or raw.
- Whether the host accepts axis indices above 3 or click bits above 5 for
  other controller types.
- What the host binds the pinch / grip / gesture bits to (its `svl_hand_interaction_augmented` input profile).
