# Haptics (host → client)

Message type `0x16` on the unreliable stream. The host sends vibration events;
the client schedules them against its own clock and plays them through OpenXR.

## Message

**static**: `QSVLClient::RXUnreliableStream` (0xf5c00): accepted only if the
payload length (`u16` at +4) is > 0x26 (i.e. ≥ 39; two events are 38 bytes, so
at least one more byte follows — **inferred** padding or a count). It then
calls `AcceptHapticsPacket` (vtable slot 0xe0) on **two** packed 19-byte
records, at dataset offsets 0x08 and 0x1b.

`HapticsPacketData_t` (19 bytes, packed) — **static**:
`QSVLHapticsXR::AcceptHapticsPacket` (0xf99d8),
`QSVLHapticsXR::ProcessHapticsEvents` (0xf9720),
`QSVLXRInput::OnHapticFeedback` (0x1083c0):

| off | type | field | evidence |
|---|---|---|---|
| 0x00 | f32 | frequency, Hz | passed as arg 1 → `XrHapticVibration.frequency` |
| 0x04 | f32 | duration, seconds | arg 2 → `duration = seconds × 1e9` ns |
| 0x08 | f32 | amplitude, 0..1 | arg 3 → `XrHapticVibration.amplitude` |
| 0x0c | i32 | start time, host clock, µs (`GetCurrentTimestamp` units) | rebased below |
| 0x10 | u16 | event sequence id | de-duplication |
| 0x12 | u8 | hand: 0 = left, 1 = right | indexes the per-hand id history and is passed as `QSVLControllerHand` |

**inferred**: each message carries the newest event plus the previous one (or
the latest event of each hand) so a single lost datagram does not drop a pulse;
the client's duplicate filter exists for exactly that.

## Client behavior (all **static**)

1. **Clock rebase** — `QSVLClientXR::AcceptHapticsPacket` (0xfaa70):
   `t_local = t + toff − (toff + c84) / 2` (integer division truncating toward
   zero), where `toff = SVLRoot+0xc7c` and `c84 = SVLRoot+0xc84` are the two
   clock-offset estimates kept by the timing code (docs/svl-timing/). In effect
   `t_local ≈ t + (toff − c84) / 2`.
2. **De-dup** — per hand the client remembers the last two sequence ids
   (`QSVLHapticsXR+0x500 + hand*4`, two u16). An event whose id equals either
   is dropped.
3. **Queue** — events go into a 64-entry ring (19-byte entries at
   `QSVLHapticsXR+0x20`, write index `+0x10`). Start time is clamped to
   `max(now, t_local)`.
4. **Duration fix-ups** at enqueue:
   - `amplitude > 0.01 && duration < 0.001` → duration = 0.02 s
   - then `0.0049 ≤ duration < 0.0051` → duration += 0.035 s
     (**inferred**: SteamVR's legacy 5 ms "pulse" is stretched to something a
     Quest actuator can render).
5. **Playback** — a dedicated thread (`QSVLHapticsXR::HapticsThread` 0xf94d0,
   named `QSVLHapticsXR`) sleeps until the next due time. For each hand it
   picks the most overdue pending event, calls
   `OnHapticFeedback(hand, frequency, duration, amplitude)`, and arms a stop
   deadline `now + 10000 µs + duration × 1e6`; when the deadline passes with no
   newer event it calls `StopHapticFeedback(hand)` (`xrStopHapticFeedback`).
6. **OpenXR call** — `OnHapticFeedback`: let `ns = duration × 1e9`.
   If `ns ≥ 1000`: `XrHapticVibration{duration = ns + 1 ms, frequency,
   amplitude}`. If `ns < 1000`: `duration = 21 ms`, `frequency = 0`
   (`XR_FREQUENCY_UNSPECIFIED`), amplitude unchanged. Applied to the
   `hapticAction` from `controller_config.json`
   (`/user/hand/{left,right}/output/haptic`) on the hand's subaction path.

## Capture check (`vr3`)

**captured** negative: `vr3` (40 s, desktop view, nothing vibrating) contains
no type-`0x16` message. The only inbound class-3 elements are six `0x0d`
value messages and twenty `0x18` messages (179 bytes each; not documented
yet, see docs/README.md), and the haptics path accepts only type `0x16`
(**static**, above). `vr1` had none either. Everything on this page is therefore still **static** only.

The older path that carries two haptic records in the video frame
descriptor's trailer is dead with this host (it is used only when the
descriptor's `version` < 5; docs/svl-video/frame-descriptor.md).

## Open questions / to confirm on the wire

- A captured `?? 16 …` message with length ≥ 39 (needs a SteamVR application
  that vibrates a controller; the desktop view never does); whether the two records are
  "current + previous" or "left + right"; what the bytes after 0x2e are.
- Sequence-id behavior: starts at 0 or 1? An id of 0 collides with the
  client's zero-initialized history, which would drop the very first event.
- Whether the host resends the same event in several consecutive messages and
  at what cadence (only on events, or continuously).
- Units of 0x0c: confirm by comparing with the host timestamps in the
  transport's time-sync exchange. (`vr3` does show one other host-clock µs
  timestamp agreeing with the client's `toff` to 0.7 ms: the prefix of the
  host's debug text message, [events-prompts.md](events-prompts.md).)
- Whether amplitude 0 is used as an explicit "stop".
