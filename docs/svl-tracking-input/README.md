# SVL tracking, input, and side channels

This folder covers what `vrlink` (`libvrlink_scene.so`, Android arm64) sends to
the host for head, controller, hand, eye, and face tracking, along with the
small host→client channels that run alongside video: haptics, message prompts,
shutdown, and echo. Everything here sits on top of the transport layer
(docs/svl-transport/) and beside the value system (docs/svl-values/).

All offsets are **file offsets** in `libvrlink_scene.so` (Ghidra address =
offset + 0x100000). Evidence tags indicate how each detail was established:
**static** means read from the binary at the named symbol, **inferred** means an
educated guess along with what would confirm it, and **captured** means observed
in a wire capture. The pages are checked against capture `vr3` (docs/README.md:
a clean, timestamped 40 s Klepton session in the SteamVR desktop view, with a
motionless synthetic head and two idle synthetic Touch controllers), which
replaces the earlier check against the torn `vr1` capture. `vr3` captures the
pose packet framing, every fixed field and its timing, `PackedPose_t`,
`PackedHmdInput_t`, the piggy-backed value bytes, the short eye message, and the
host's debug text message (see the "Capture check" section in each file).
Haptics, prompts, echo, shutdown, and hand tracking did not occur in `vr3`
(recorded as captured negatives on their pages) and remain **static** only,
along with button, touch, and axis bits and anything that requires motion.

| file | topic |
|---|---|
| [messages.md](messages.md) | the `dataset` message envelope as this layer sees it, and the message-type byte table (both directions) |
| [poses.md](poses.md) | the pose packet (`QSVLClient::SendPoses`): header, timestamps, `PackedPose_t`, `PackedHmdInput_t` |
| [controllers.md](controllers.md) | button / touch / axis encoding, how `controller_config.json` drives it, hand-tracking-as-controller |
| [skeleton.md](skeleton.md) | hand-tracking packet (`SVLHandTrackingPacket_t`) and the 8-byte-per-bone skeleton codec, with pseudocode |
| [eye-face.md](eye-face.md) | eye gaze and face expression packet (`EyeAndExpressions_t`) |
| [haptics.md](haptics.md) | host→client haptic packets (`HapticsPacketData_t`) and how `vrlink` plays them |
| [events-prompts.md](events-prompts.md) | `VRLinkPostedEvent_t` (local timer queue), message prompts, server shutdown, sideband events, debug messages |

## Overview

Once per event-0 tick (**static**, `QSVLClient::HandleEvent` 0xf4bec), `vrlink`
sends one unreliable message of type `0x01` containing a 360-byte fixed block
(timestamps, frame id, HMD input bits, two 28-byte controller input blocks, and
three 88-byte poses for HMD, left, and right) followed by up to 372 bytes of
piggy-backed ValueTransportSystem traffic. In `vr3` (**captured**), `vrlink`
sends four pose packets per frame spaced a quarter frame apart (433 packets/s at
the 108 Hz rate of that session's frame loop). All four carry the same per-frame
target time, and the value-transport bytes appear only during the first 1.07 s
of the session. Right after each pose packet, if the link is active, `vrlink`
sends an eye/face message (`0x11`) and, when hand tracking is running, one
`0x17` message per tracked hand containing a 248-byte compressed 31-bone
skeleton. From host to client, haptics arrive as type `0x16` (two redundant
19-byte events per message) and UI prompts arrive as type `0x12`.

## Open questions and limitations

- Bit meanings of the six hand-gesture flags and of `PackedHmdInput_t` bits are
  inferred from call arguments only.
- The meaning of the two `SubmitMessage` booleans and of the fixed bytes
  `0x0a` / `0x20` in the pose header is not determined.
- `vr3` has no motion and no input, so velocities, the angular-velocity frame,
  every button/axis bit, and the `rst` counter (0 throughout) are untested on
  the wire.
- This binary contains no host-side code, so all host behavior is inferred.
