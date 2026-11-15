# Haptics (host → client)

Haptics travel from host to client in message type `0x16` on the unreliable
stream. The host sends vibration events, and `vrlink` schedules them against its
local clock and plays them through OpenXR.

## Message layout

In `QSVLClient::RXUnreliableStream` (0xf5c00, **static**), a type-`0x16` packet
is accepted only if the payload length (`u16` at +4) is `> 0x26` (≥ 39 bytes;
two 19-byte events take 38 bytes, so at least one trailing byte follows —
**inferred** to be padding or a record count). It then calls
`AcceptHapticsPacket` (vtable slot 0xe0) on **two** packed 19-byte records at
dataset offsets 0x08 and 0x1b.

`HapticsPacketData_t` (19 bytes, packed; **static** from
`QSVLHapticsXR::AcceptHapticsPacket` at 0xf99d8,
`QSVLHapticsXR::ProcessHapticsEvents` at 0xf9720, and
`QSVLXRInput::OnHapticFeedback` at 0x1083c0):

| off | type | field | evidence |
|---|---|---|---|
| 0x00 | f32 | frequency, Hz | passed as arg 1 → `XrHapticVibration.frequency` |
| 0x04 | f32 | duration, seconds | arg 2 → `duration = seconds × 1e9` ns |
| 0x08 | f32 | amplitude, 0..1 | arg 3 → `XrHapticVibration.amplitude` |
| 0x0c | i32 | start time, host clock, µs (`GetCurrentTimestamp` units) | rebased below |
| 0x10 | u16 | event sequence id | deduplication |
| 0x12 | u8 | hand: 0 = left, 1 = right | indexes the per-hand id history and is passed as `QSVLControllerHand` |

Each packet likely carries the newest event alongside the previous event (or the
latest event for each hand) so a single lost UDP datagram does not drop a haptic
pulse (**inferred**), which explains `vrlink`'s sequence-id deduplication filter
below.

## Client behavior (all **static**)

1. **Clock rebase** — `QSVLClientXR::AcceptHapticsPacket` (0xfaa70) computes
   `t_local = t + toff − (toff + c84) / 2` (integer division truncating toward
   zero), where `toff = SVLRoot+0xc7c` and `c84 = SVLRoot+0xc84` are the two
   clock-offset estimates maintained by the timing code (docs/svl-timing/). In
   effect, `t_local ≈ t + (toff − c84) / 2`.
2. **Deduplication** — per hand, `vrlink` remembers the last two sequence ids
   (`QSVLHapticsXR+0x500 + hand*4`, two `u16` values). Any event whose id
   matches either entry is dropped.
3. **Queue** — events are appended to a 64-entry ring buffer (19-byte entries at
   `QSVLHapticsXR+0x20`, write index `+0x10`), with start time clamped to
   `max(now, t_local)`.
4. **Duration fix-ups** at enqueue:
   - `amplitude > 0.01 && duration < 0.001` → `duration = 0.02` s
   - then `0.0049 ≤ duration < 0.0051` → `duration += 0.035` s
     (**inferred**: stretches SteamVR's legacy 5 ms pulse to a duration Quest
     actuators can render).
5. **Playback** — a dedicated thread (`QSVLHapticsXR::HapticsThread` at 0xf94d0,
   named `QSVLHapticsXR`) sleeps until the next due timestamp. For each hand, it
   picks the most overdue pending event, calls
   `OnHapticFeedback(hand, frequency, duration, amplitude)`, and arms a stop
   deadline at `now + 10000 µs + duration × 1e6`; if the deadline expires with
   no newer event, it calls `StopHapticFeedback(hand)` (`xrStopHapticFeedback`).
6. **OpenXR call** — `OnHapticFeedback` computes `ns = duration × 1e9`. If
   `ns ≥ 1000`, it submits `XrHapticVibration{duration = ns + 1 ms, frequency,
   amplitude}`. If `ns < 1000`, it uses `duration = 21 ms`, `frequency = 0`
   (`XR_FREQUENCY_UNSPECIFIED`), and leaves amplitude unchanged. The vibration
   is applied to `hapticAction` from `controller_config.json`
   (`/user/hand/{left,right}/output/haptic`) on that hand's subaction path.

## Capture check (`vr3`)

`vr3` (40 s in the desktop view with nothing vibrating) contains no type-`0x16`
messages (**captured** negative). The only inbound class-3 elements are six
`0x0d` value messages and twenty `0x18` messages (179 bytes each; not documented
here, see docs/README.md), while the haptics handler accepts only
type `0x16` (**static**). `vr1` contained none either, so everything on this
page remains **static** only.

An older code path that reads two haptic records from the video frame
descriptor's trailer is unused with current hosts (it runs only when the
descriptor's `version` < 5; see docs/svl-video/frame-descriptor.md).

## Open questions / to confirm on the wire

- Capture a `?? 16 …` message with length ≥ 39 (requires a SteamVR application
  that vibrates a controller, since the desktop view never does), and check
  whether the two records represent "current + previous" or "left + right", plus
  what follows offset 0x2e.
- Check whether sequence ids start at 0 or 1. An initial id of 0 would collide
  with `vrlink`'s zero-initialized history and drop the very first haptic event.
- Whether the host resends the same event across several consecutive messages
  and at what cadence (only on events, or continuously).
- Confirm the units of offset 0x0c by comparing against host timestamps in the
  transport's time-sync exchange. (`vr3` shows one other host-clock µs timestamp
  matching `vrlink`'s `toff` within 0.7 ms: the prefix of the host's debug text
  message in [events-prompts.md](events-prompts.md).)
- Whether amplitude 0 is used as an explicit stop command.
