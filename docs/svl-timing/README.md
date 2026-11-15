# SVL frame timing

This folder documents how the client paces itself against the host: clock-offset
estimation, the per-frame event schedule, the phase control loop behind `cPhaseOff` /
`cStandoff` / `cFramePhase`, the timing-event vocabulary, and the per-frame
reports the client sends back. Derived from static analysis of `libvrlink_scene.so`
and verified against capture `vr3` (40 s of `vrlink` with per-datagram timestamps).

| file | topic |
|---|---|
| [clock-sync.md](clock-sync.md) | SVL timestamps, `SymmetricTimingUpdate`, `cPingMS` / `cPingAMS`, converting host timestamps |
| [event-schedule.md](event-schedule.md) | `VRLinkPostedEvent_t`, what `OnTopOfFrame` schedules, the four pose sends per frame, the 1 ms and 1 s ticks |
| [phase-loop.md](phase-loop.md) | `cFramePhase`, `cPhaseOff`, `cStandoff`, `PhaseEventControlLoop`, host-version thresholds |
| [timing-events.md](timing-events.md) | the full `timingevent` enum (108 entries) and how host timing events arrive in the bookend tail |
| [frame-reports.md](frame-reports.md) | the type-4 "last RX id" packet: frame accepted / decoded / submitted / displayed |
| [refresh-rate.md](refresh-rate.md) | VTE 0x20 (available rates), 0x21 (host request), 0x0c (`VTE_REQ_FRAMETIME_US`) |

## Overview

All times are 32-bit microsecond "SVL timestamps" on each side's own clock.
Each side continuously estimates `offset = local_now - peer_send_time` from
timestamped packets and reports its estimate to the peer; the sum of the two
estimates is the round-trip time. Once per display frame (after `xrWaitFrame`)
the client schedules four pose transmissions a quarter of the display period
apart — immediately for a current host, or `cStandoff` µs later for a host
older than version 6 (including before the first descriptor arrives). The host
renders and encodes one frame per client frame. When a decoded frame comes out
of the decoder, the client compares the time since top of frame against the
target `cFramePhase × frametime` and nudges `cPhaseOff` (by less than 100 µs
per frame); with a current host, nothing visibly acts on that number. Alongside
each pose packet, the client also sends a compact report of the last frame
accepted from the network, decoded, and submitted for display, each with a
timestamp.

## Capture status

Each file includes verification results from capture `vr3`, which supersedes
the earlier `vr1` capture (where torn, untimestamped datagrams gave only
lower-bound counts). Key findings from `vr3`:

- **Clock sync**: Wire fields and `cPingMS` = sum of the two offset estimates
  were confirmed (exact in 3,123 of 3,153 samples). Replaying the estimator
  reproduces a 32-bit overflow that pulls `vrlink`'s estimate 7.7 ms low at
  stream start and makes `cPingMS` negative for ~16 s. Steady-state round-trip
  time is 0.58–0.65 ms, the two clocks drift apart by 30 ppm, and `vrlink`'s
  SVL clock differs from the tracer's `CLOCK_MONOTONIC` (offset by 1.455 s and
  drifting 6 µs/s).
- **Event schedule**: The frame counter increments by 1 per group, with four
  sub-indices sent at 0, 2.2, 4.3, and 6.4 ms — quarters of the reported
  8,333 µs display period even though the frame loop took 9,231 µs. No
  stand-off delay is applied once video starts.
- **Frame reports**: Each report is 32 bytes with its header (24-byte payload).
  The accepted timestamp is stamped on the last data packet (+0.1 ms), decode
  takes 3.0 ms, accepted-to-predicted-display latency is 26 ms in this session,
  and 553 of 4,258 decoded frames were never submitted.
- **Phase loop**: Replaying the control law matches wire `cPhaseOff` values
  within ±0.28 ms over 4,258 frames and confirms the sign (early frame arrival
  moves `cPhaseOff` down). Against a version-14 host the loop is open, though
  the host still receives a frozen `cStandoff`.
- **Refresh rate**: The VTE 0x20, 0x21, and 0x0c bytes and sequence were
  captured; negotiation finished 42 ms into the session and video began at
  926 ms. Although 120 Hz was agreed, frames were delivered at 108.4 fps.
- **Timing events**: The bookend tail check passed on all 8,631 descriptors,
  with `nEvents` equal to 0 in every descriptor.

Several components remain **static** only: the posted-event table, the
timing-event record layout, behavior gated on host version < 6 after the first
descriptor, and the 3-second connection-lost test.

## Unresolved details

- The writer of `dbgPhaFault`'s counter (`QSVLClient+0xe00`) was not found.
- `QSVLClient::AdjustPhaseOffset` has no static caller.
- `QSVLFrameServer::ServeBestHardwareBuffer` (frame selection for host version
  ≥ 9) was not decompiled.
- The call sites raising `CN Got Bookend*`, `CN Got Complete Frame`, and
  `CN Req Retransmit` were not traced here (they live in `SVLFEC`; see
  docs/svl-video/).
- Host-side handling of these timing numbers is **inferred** only.
