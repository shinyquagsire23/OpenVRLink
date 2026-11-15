# Phase control loop (`cFramePhase`, `cPhaseOff`, `cStandoff`)

Sources: `QSVLClient::PhaseEventDecodeComplete()` +0xf72e8,
`QSVLClient::PhaseEventControlLoop(int)` +0xf71e4,
`QSVLClient::AdjustPhaseOffset(int)` +0xf7110, `QSVLClient::OnTopOfFrame`
+0xf6270, `QSVLClient::OnRenderComplete` +0xf671c,
`QSVLCodecNDK::HandleOnImageAvailable` +0xfde30,
`QSVLClient::ReceivedBookend` +0xf6cf8, `QSVLRendererXR::FlipFrame` +0x10ae78.
All details below are **static** unless marked otherwise.

## Phase control keys

| key | unit | owner | meaning |
|---|---|---|---|
| `cFramePhase` | fraction of a frame (0..1) | client default, set in the `QSVLClientXR` constructor (xref at Ghidra 0x1f9f90); **captured (Klepton trace)**: 0.3 | where in the client's display frame a decoded video frame should become available, measured from top of frame |
| `sFramePhase` | fraction of a frame (0..1) | host | if the host has set this key it overrides `cFramePhase` |
| `cPhaseOff` | µs, 0 ≤ x < frametime | client loop state (`QSVLClient+0xcc0`); **captured (Klepton trace)**: starts at 3500 | offset of the pose-send batch within the client frame; updated by the control loop |
| `cStandoff` | µs, 0 ≤ x < frametime | derived per frame | `(µs_until_display + cPhaseOff) mod frametime`: the delay between the frame wait returning and the first pose send. Only computed/published when the host version is < 6 — which includes the time before the first descriptor, so a current host still receives a frozen value (**captured**, below) |

`OnRenderComplete` re-reads the target each frame: `sFramePhase` if
`SVLRoot::WasValueSet("sFramePhase")`, else `cFramePhase` if set, into a float
at `QSVLClient+0xcc4`; and publishes `cPhaseOff`.

In the code, `cFramePhase` is the target, `cPhaseOff` is the control output,
and `cStandoff` is `cPhaseOff` shifted by the time to display. Klepton's
SL-26 reads `cStandoff` as "the target" and `cPhaseOff` as "the margin
achieved", which does not match the code.

## Control loop (`PhaseEventControlLoop`)

The control loop runs once per decoded frame, from the decoder's
image-available callback (`HandleOnImageAvailable` → `GotDecodedFrame()`,
`PhaseEventDecodeComplete()`):

```python
def phase_event_decode_complete():
    now = timestamp()
    # positive = the frame came out of the decoder EARLIER than the target point
    err = (self.top_of_frame - now) + int(self.frame_phase * self.frametime)
    report(CR_Rephase /*0x5f*/, err)
    phase_event_control_loop(err)

def phase_event_control_loop(err):
    ft = self.frametime
    e = ((err + ft + ft//2) % ft) - ft//2          # wrap into [-ft/2, ft/2)
    step = trunc(e * 200 / ft)                     # C division (toward zero); |step| < 100 µs
    report(CR_Roll_Norm /*0x5e*/, -step)
    self.phase_off = (self.phase_off - step + ft) % ft
    set_value("cPhaseOff", self.phase_off)
```

`top_of_frame` is the timestamp of the most recent `OnTopOfFrame`, so
`err = target_phase − actual_arrival_phase`.

Replaying the arithmetic above over `vr3`'s decode timestamps reproduces the
`cPhaseOff` values `vrlink` sent on the wire (**static** and **captured**, see
below). When a frame comes out of the decoder *earlier* than the target point
(`err > 0`), `cPhaseOff` *decreases*; when it comes out later, `cPhaseOff`
increases.

How a change in `cPhaseOff` shifts subsequent frame arrivals depends on what
consumes `cPhaseOff`. If the host rendered at a fixed delay after each pose
batch, a smaller `cPhaseOff` (batch sent earlier in the client frame) would
make the next frame arrive even earlier, causing the loop to run away from the
target instead of settling on it — so for negative feedback, whatever consumes
`cPhaseOff` must map a smaller value to a later arrival relative to top of
frame. Against a version-14 host, `OnTopOfFrame` ignores `cPhaseOff` on the
client side, and `vr3` shows no response on the host side either: `cPhaseOff`
wandered across the full 0…8,333 µs range for 39 s, the phase error never
shrank, and host frame timing relative to the client's frame did not track
`cPhaseOff` (see below). Determining the closed-loop sign convention therefore
requires either a host reporting version < 6 (where `vrlink` applies
`cPhaseOff` locally via `cStandoff`) or a probe that shifts its pose batch
within the frame and measures where incoming frames land.

The gain is small by design: at most 100 µs of correction per decoded frame,
so pulling in a half-frame error at 90 Hz takes ~55 frames.

`AdjustPhaseOffset(delta)` does the same update with an explicit delta
(`cPhaseOff = (cPhaseOff + delta + ft) % ft`, reports `CR Roll Norm`); it has
no static caller in this build.

The loop only has an effect on what is sent when the host version is < 6
(below): for newer hosts `OnTopOfFrame` ignores `cPhaseOff` when scheduling,
although the loop still runs and still publishes `cPhaseOff`, so the host can
read it (**inferred**: newer hosts do the phase alignment themselves from
`cPhaseOff` / the frame reports).

## Host version thresholds

`QSVLClient::ReceivedBookend` copies the u32 at offset 0x20 of every
`SVLVideoFrameDescriptor_t` into `SVLRoot+0xba8`. Its use as a set of
"at least version N" gates makes it almost certainly the host's protocol
version (**inferred**; the descriptor is documented in docs/svl-video/):

| test | where | behavior |
|---|---|---|
| `< 5` | `ReceivedBookend` | haptic pulses are read from the bookend tail (two 6-byte records) and dispatched; newer hosts send haptics another way |
| `< 6` | `OnTopOfFrame`, `SendPoses` | client-side phase lock: pose batch delayed by `cStandoff`, pose packet target-time field = batch anchor; `cStandoff` published |
| `≥ 6` | `OnTopOfFrame`, `SendPoses` | pose batch sent immediately at top of frame; target-time field = predicted display time |
| `> 5` | `FlipFrame` | `FrameHasBeenSubmittedForDisplay` is reported, and the OpenXR display time for the layer is replaced by the frame metadata's host-specified time converted to the client clock |
| `< 9` | `FlipFrame` | frames are taken FIFO (`QSVLFrameServer::ServeNextHardwareBuffer`); if none is ready and a flag is set, wait up to 5 ms for the decoder |
| `≥ 9` | `FlipFrame` | `QSVLFrameServer::ServeBestHardwareBuffer(now + until_display, period)` picks the frame for the display slot |

Until the first bookend arrives the field is below 6: **captured** (`vr3`),
the client runs the `< 6` path for the 0.926 s before the first descriptor —
`cStandoff` is published every frame and the pose packet's target-time field
is the batch anchor — and switches on the first descriptor.

## Per-frame debug bookkeeping (not on the wire)

`OnRenderComplete` / `FrameSwap` (+0xf6a94) advance a 512-entry ring indexed by
display frame and keep, per slot: display periods elapsed, frames decoded
(`GotDecodedFrame`), frames received from the network (`GotNetworkFrame`),
and frames the host says it generated (`GotNoteFromServerThatFrameWasGenerated`,
driven by host timing event 0x24). `ReportTimingEventWithTimestamp` +0xf7378
keeps the last 512 timing events (`{u8 event, u8 arg, i32 time}`). These feed
`SVLRoot::DebugRender`. `dbgPhaFault` is `QSVLClient+0xe00`, published once a
second; its writer was not found (**captured (Klepton trace)**: always 0).

`OnRenderComplete` also reads remote VTE id 2 (8 bytes) each frame and calls
`ValueTransportSystem::InvalidateAll()` when it changes — **inferred**: a host
session/instance id, so a restarted host gets every value re-sent.

## Capture verification (`vr3`)

Capture `vr3` records 40.26 s of `vrlink` under Klepton with per-datagram
timestamps and video starting at 0.926 s. `vrlink`'s keys are read from its
class-3 type-7 elements (17,421 elements, each carrying three
`TransportValue_t` records), and the host's keys are read from the four records
in each of the 8,631 descriptor tails. The log's `KL_SVL_TRACE` lines
(`[svl] key = value`) are sparse — about one per key per second (41 for
`cPhaseOff`, and one each for `cStandoff`, `cFramePhase`, and `dbgPhaFault`) —
and agree with the wire values; all figures below come from the wire.

### Observed key behavior

- **captured**: `cFramePhase` = 0.3 in all 794 records, sharing a single
  timestamp (set once at startup). The host echoes 0.3 back. `sFramePhase`
  never appears in any of the 34,524 host records, so the host did not override
  `cFramePhase`. The host's own `s*` keys are `sPingMS`, `sRXerr`, `sRXpass`,
  `sRXpps`, and `sTimeConf`, none of which is a phase or stand-off parameter.
- **captured**: `cPhaseOff` stays at 3500 with a fresh timestamp every frame
  until video starts, then updates on every decoded frame: 4,629 distinct
  updates on the wire across 3,225 distinct values spanning 3…8,331, wrapping
  across the 8,333 µs frame boundary many times. It appears in 5,016 records
  total, 4,639 of them in the "changed keys" slots.
- **captured**: `cStandoff` updated 78 times before video started (3,490–3,500),
  and its timestamp stopped advancing at 0.926 s when the first descriptor
  arrived with version 14. Because `vrlink` retains the key in its table, the
  round-robin slot continues re-sending the frozen 3,497 value every ~0.11 s
  through the end of the capture (836 records total), and the host echoes
  `cStandoff` = 3497 back in 169 descriptor tails. Consequently, **a version-14
  host still receives `cStandoff`** — live during the first second before video
  starts, and frozen for the remainder of the session (matching `vr1`'s
  observation that updates stop once streaming begins).
- **captured**: With `cPhaseOff` = 3500, `cStandoff` = 3,490–3,500 means
  `µs_until_display mod 8333` was 8,323–8,333: the runtime predicts display one
  period after the frame wait returns. Streaming-phase pose packets show the
  same timing (target − build time ≤ 8,330 µs; see
  [event-schedule.md](event-schedule.md)).
- **captured**: `dbgPhaFault` stayed 0 throughout (41 updates, once per second).
- **captured**: The descriptor's version field (dataset offset 0x20, value
  offset 0x18) is 14 in all 8,631 descriptors, placing every threshold in the
  table above on its modern branch: no bookend haptics, no stand-off after the
  first descriptor, display reports enabled, and `ServeBestHardwareBuffer`
  active.

### Control-law replay

Each frame report carries the decode-complete timestamp of its frame
([frame-reports.md](frame-reports.md)) — the same instant
`PhaseEventDecodeComplete` runs — and the pose packets provide top of frame
(target time − 8,333). Starting from 3500 and running the pseudocode above
across all 4,258 decoded frames in order reproduces the wire sequence:

- **captured**: The replayed `cPhaseOff` stays within −278…+259 µs of the wire
  value across all 4,560 comparable samples (−184…+194 µs at the 1st–99th
  percentile, 14 exact) over a 39 s open-loop integration of 4,258 steps of up
  to ±99 µs. Rounding division toward −∞ instead of toward zero causes the
  replay to drift by up to 2.2 ms, confirming that C truncation toward zero
  (`step = trunc(e * 200 / ft)`) is used.
- **captured**: This replay confirms the sign (earlier than target moves
  `cPhaseOff` down), the ±ft/2 wrap, the `200 / ft` gain, the
  `0.3 × 8,333 = 2,499 µs` target, and that the loop continues updating
  `cPhaseOff` against a version-14 host.

### Open-loop behavior with host version 14

- **captured**: Decoded frames emerged a median 5.8 ms after top of frame,
  spread across the entire frame period (5th–95th percentile 0.9–8.6 ms),
  versus the 2.5 ms target. The wrapped error stayed large throughout the run
  (mean `|e|` of 1.8–2.3 ms in the first 25 s and 3.2–3.3 ms in the last 15 s;
  frames within 1 ms of target made up 15–29% per 5 s window in the first 25 s
  and 0% in the last 15 s), while unwrapped `cPhaseOff` accumulated +17.2 ms
  (more than two full frame periods).
- **captured**: Host frame timing does not track `cPhaseOff`. Regressing the
  interval from the most recent sub-index 0 pose to a frame's opening
  descriptor against `cPhaseOff` (as a phase angle) yields R² = 0.017 over the
  run, and the linear slope changes sign across successive thirds of the
  capture (+0.26, −0.26, and +0.03 µs/µs). Arrival phase drifted over the
  session (medians of 4.4 ms, 4.0 ms, and 2.9 ms across successive thirds)
  independently of `cPhaseOff`.
- Against this version-14 host, `cFramePhase`, `cPhaseOff`, and `cStandoff`
  serve only as telemetry: `vrlink` publishes them and the host echoes them,
  with no measurable closed-loop timing effect in `vr3`.

## Open questions

- Determine the closed-loop sign convention between `cPhaseOff` and frame
  arrival (see "Control loop" above) using either a version < 6 host or a probe
  that shifts its pose-batch timing.
- Test whether an independent client can force the local `cStandoff` path
  against a version-14 host and whether doing so stabilizes arrival phase.
- Check whether any host configuration sets `sFramePhase` (absent in `vr3`).
- Determine why decoded frames landed ~3.3 ms after the 0.3-frame target under
  Klepton and whether physical headset hardware tracks closer to it (`vr3`'s
  frame loop ran at 108 Hz while `frametime` was 8,333 µs, continuously
  shifting the relative phase).
- Check whether the host uses frozen `cStandoff` or live `cPhaseOff` for
  internal telemetry such as `dFrmsEarly` and `dFrmsLate`.
