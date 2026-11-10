# SVL frame timing

This folder describes how the client paces itself against the host: clock-offset
estimation, the per-frame event schedule, the phase control loop behind `cPhaseOff` /
`cStandoff` / `cFramePhase`, the timing-event vocabulary, and the per-frame
reports the client sends back. Read out of `libvrlink_scene.so` and checked
against capture `vr3` (40 s of a real client, every datagram timestamped).

| file | topic |
|---|---|
| [clock-sync.md](clock-sync.md) | SVL timestamps, `SymmetricTimingUpdate`, `cPingMS` / `cPingAMS`, converting host timestamps |
| [event-schedule.md](event-schedule.md) | `VRLinkPostedEvent_t`, what `OnTopOfFrame` schedules, the four pose sends per frame, the 1 ms and 1 s ticks |
| [phase-loop.md](phase-loop.md) | `cFramePhase`, `cPhaseOff`, `cStandoff`, `PhaseEventControlLoop`, host-version thresholds |
| [timing-events.md](timing-events.md) | the full `timingevent` enum (108 entries) and how host timing events arrive in the bookend tail |
| [frame-reports.md](frame-reports.md) | the type-4 "last RX id" packet: frame accepted / decoded / submitted / displayed |
| [refresh-rate.md](refresh-rate.md) | VTE 0x20 (available rates), 0x21 (host request), 0x0c (`VTE_REQ_FRAMETIME_US`) |

## One-paragraph model

All times are 32-bit microsecond "SVL timestamps" on each side's own clock.
Each side continuously estimates `offset = local_now - peer_send_time` from
timestamped packets and tells the other its estimate; the sum of the two
estimates is the round trip. Once per display frame (after `xrWaitFrame`) the
client schedules four pose transmissions a quarter of the display period
apart — at once for a current host, `cStandoff` µs later for a host older
than version 6 or not yet heard from. The host renders and encodes one frame
per client frame. When a decoded frame pops out of the decoder, the client
compares "time since top of frame" with the target `cFramePhase × frametime`
and nudges `cPhaseOff` (less than 100 µs per frame); with a current host
nothing visibly acts on that number. With each pose packet the client also
sends a small report of the last frame accepted from the network, decoded,
and submitted for display, each with a timestamp.

## Capture status

Every page has a "Confirmed against capture `vr3`" section. `vr3` replaced
`vr1` (a third of its datagrams torn, no timestamps), whose counts were lower
bounds. Headlines:

- **Clock sync**: fields and `cPingMS` = sum of the two estimates confirmed
  (3,123 of 3,153 samples exact). The estimator is confirmed including a
  32-bit overflow that drags the client's estimate 7.7 ms low at stream start
  and makes `cPingMS` negative for ~16 s. Round trip 0.58–0.65 ms; the two
  clocks drift 30 ppm; the client's SVL clock is not the tracer's
  CLOCK_MONOTONIC (offset 1.455 s, drifting 6 µs/s).
- **Event schedule**: frame counter +1 per group, four sub-indices at
  0 / 2.2 / 4.3 / 6.4 ms — quarters of the 8,333 µs display period, although
  the frame loop took 9,231 µs. No stand-off once video starts.
- **Frame reports**: 32 bytes with header, 24 without. Accepted is stamped at
  the last data packet (+0.1 ms); decode 3.0 ms; accepted to predicted
  display 26 ms in this session; 553 of 4,258 decoded frames never submitted.
- **Phase loop**: control law replayed to within ±0.28 ms over 4,258 frames,
  sign confirmed (early frame → `cPhaseOff` down). The loop is open with a
  version-14 host; such a host still receives a frozen `cStandoff`.
- **Refresh rate**: 0x20 / 0x21 / 0x0c bytes and order captured; negotiation
  over 42 ms into the session, video at 926 ms; 120 Hz agreed, 108.4
  frames per second delivered.
- **Timing events**: tail check passes on all 8,631 descriptors; `nEvents`
  is always 0.

**Still static only**: the posted-event table, the timing-event record
layout, everything gated on host version < 6 after the first descriptor, the
connection-lost test.

## Thin areas

- The writer of `dbgPhaFault`'s counter (`QSVLClient+0xe00`) was not found.
- `QSVLClient::AdjustPhaseOffset` has no static caller.
- `QSVLFrameServer::ServeBestHardwareBuffer` (frame selection for host version
  ≥ 9) was not read.
- Where the `CN Got Bookend*` / `CN Got Complete Frame` / `CN Req Retransmit`
  events are raised (SVLFEC; see docs/svl-video/).
- Everything about what the host *does* with these numbers is inference.
