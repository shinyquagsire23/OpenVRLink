# SVL tracking, input and side channels

This folder covers what the Steam Link VR client (`libvrlink_scene.so`, Android
arm64) sends to the host about the head, controllers, hands, eyes and face, and the small
host→client channels that ride beside video: haptics, message prompts, shutdown,
echo. Everything here sits on top of the transport (docs/svl-transport/) and
beside the value system (docs/svl-values/).

All offsets are **file offsets** in `libvrlink_scene.so` (Ghidra address =
offset + 0x100000). Evidence classes: **static** = read from the binary at the
named symbol; **inferred** = a guess, with what would confirm it;
**captured** = seen in a wire capture. The pages are checked against capture
`vr3` (docs/README.md: a clean, timestamped 40 s Klepton session in the
SteamVR desktop view, with a motionless synthetic head and two idle synthetic
Touch controllers), which replaces the earlier check against the torn `vr1`.
Captured there: the pose packet framing, every fixed field and its timing,
`PackedPose_t`, `PackedHmdInput_t`, the piggy-backed value bytes, the short
eye message and the host's debug text message (see the "Capture check"
section in each file). Haptics, prompts, echo, shutdown and hand tracking did
not occur in it (recorded as captured negatives on their pages) and remain
static only; so do button, touch and axis bits and anything that needs
motion.

| file | topic |
|---|---|
| [messages.md](messages.md) | the `dataset` message envelope as this layer sees it, and the message-type byte table (both directions) |
| [poses.md](poses.md) | the pose packet (`QSVLClient::SendPoses`): header, timestamps, `PackedPose_t`, `PackedHmdInput_t` |
| [controllers.md](controllers.md) | button / touch / axis encoding, how `controller_config.json` drives it, hand-tracking-as-controller |
| [skeleton.md](skeleton.md) | hand-tracking packet (`SVLHandTrackingPacket_t`) and the 8-byte-per-bone skeleton codec, with pseudocode |
| [eye-face.md](eye-face.md) | eye gaze and face expression packet (`EyeAndExpressions_t`) |
| [haptics.md](haptics.md) | host→client haptic packets (`HapticsPacketData_t`) and how the client plays them |
| [events-prompts.md](events-prompts.md) | `VRLinkPostedEvent_t` (a local timer queue, not a wire message), message prompts, server shutdown, sideband events, debug messages |

## One-paragraph summary

Once per event-0 tick (**static**, `QSVLClient::HandleEvent` 0xf4bec) the client
sends one unreliable message of type `0x01`: a 360-byte fixed block (timestamps,
frame id, HMD input bits, two 28-byte controller input blocks, three 88-byte
poses: HMD, left, right) followed by up to 372 bytes of piggy-backed
ValueTransportSystem traffic. **captured** (`vr3`): four such packets per
frame, a quarter frame apart (433 per second at the 108 Hz that client's
frame loop ran at); all four carry the same per-frame target time; the
value-transport bytes appear only during the first 1.07 s of the session.
After it, if the link is up, it sends an eye/face
message (`0x11`) and, when hand tracking is running, one `0x17` message per
tracked hand containing a 248-byte compressed 31-bone skeleton. The host sends
haptics as type `0x16` (two redundant 19-byte events per message) and UI
prompts as type `0x12`.

## Thin areas

- Bit meanings of the six hand-gesture flags and of `PackedHmdInput_t` bits are
  inferred from call arguments only.
- The meaning of the two `SubmitMessage` booleans and of the fixed bytes
  `0x0a` / `0x20` in the pose header is not determined.
- `vr3` has no motion and no input: velocities, the angular-velocity frame,
  every button/axis bit, and the `rst` counter (0 throughout) are untested on
  the wire.
- No host-side code is in this binary, so every "host does X with this" is
  inferred.
