# The phase control loop: `cFramePhase`, `cPhaseOff`, `cStandoff`

Sources: `QSVLClient::PhaseEventDecodeComplete()` +0xf72e8,
`QSVLClient::PhaseEventControlLoop(int)` +0xf71e4,
`QSVLClient::AdjustPhaseOffset(int)` +0xf7110, `QSVLClient::OnTopOfFrame`
+0xf6270, `QSVLClient::OnRenderComplete` +0xf671c,
`QSVLCodecNDK::HandleOnImageAvailable` +0xfde30,
`QSVLClient::ReceivedBookend` +0xf6cf8, `QSVLRendererXR::FlipFrame` +0x10ae78.
All **static** unless marked.

## The three numbers

| key | unit | owner | meaning |
|---|---|---|---|
| `cFramePhase` | fraction of a frame (0..1) | client default, set in the `QSVLClientXR` constructor (xref at Ghidra 0x1f9f90); **captured (Klepton trace)**: 0.3 | where in the client's display frame a decoded video frame should become available, measured from top of frame |
| `sFramePhase` | same | host | if the host has set this key it overrides `cFramePhase` |
| `cPhaseOff` | µs, 0 ≤ x < frametime | client loop state (`QSVLClient+0xcc0`); **captured (Klepton trace)**: starts at 3500 | offset of the pose-send batch within the client frame. This is the loop's actuator |
| `cStandoff` | µs, 0 ≤ x < frametime | derived per frame | `(µs_until_display + cPhaseOff) mod frametime`: the delay between the frame wait returning and the first pose send. Only computed/published when the host version is < 6 — which includes the time before the first descriptor, so a current host does receive it, frozen (**captured**, below) |

`OnRenderComplete` re-reads the target each frame: `sFramePhase` if
`SVLRoot::WasValueSet("sFramePhase")`, else `cFramePhase` if set, into a float
at `QSVLClient+0xcc4`; and publishes `cPhaseOff`.

In the code, `cFramePhase` is the target, `cPhaseOff` is the control output,
and `cStandoff` is `cPhaseOff` shifted by the time to display. Klepton's
SL-26 reads `cStandoff` as "the target" and `cPhaseOff` as "the margin
achieved", which does not match the code.

## The loop

Runs once per decoded frame, from the decoder's image-available callback
(`HandleOnImageAvailable` → `GotDecodedFrame()`, `PhaseEventDecodeComplete()`):

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

**The sign, and what `vr3` can and cannot say about it.** The arithmetic
above is **static** and now **captured**: replaying it over `vr3`'s decode
timestamps reproduces the `cPhaseOff` the client sent (below). When a frame
comes out of the decoder *earlier* than the target point (`err > 0`),
`cPhaseOff` *decreases*; when it comes out later, `cPhaseOff` increases.

What that does to the next frame is a separate question. If the host rendered
a fixed latency after each pose batch, a smaller `cPhaseOff` (batch sent
earlier in the client frame) would make the next frame arrive earlier still,
and the loop would run away from the target instead of settling on it — so
for the loop to close, the consumer of `cPhaseOff` must turn "smaller" into
"later". With a version-14 host nothing consumes it on the client side
(`OnTopOfFrame` ignores it), and `vr3` shows no response on the host side
either: the loop is open. `cPhaseOff` wandered over the whole 0…8,333 range
for 39 s, the phase error never shrank, and the host's frame timing relative
to the client's frame did not follow `cPhaseOff` (below). The convention
between `cPhaseOff` and frame arrival therefore cannot be read off this
capture. It needs either a host that reports version < 6 (where the client
itself applies `cPhaseOff` through `cStandoff`), or a probe that shifts its
pose batch within the frame and watches where the frames land.

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

## Confirmed against capture `vr3`

`vr3`: real client under Klepton, 40.26 s, every datagram timestamped; video
from 0.926 s. The client's keys are read from its class-3 type-7 elements
(17,421, each three `TransportValue_t`), the host's from the four records in
each of the 8,631 descriptor tails. The log's `KL_SVL_TRACE` lines
(`[svl] key = value`) are sparse — about one per key per second (41 for
`cPhaseOff`, one each for `cStandoff`, `cFramePhase`, `dbgPhaFault`) — and
agree with the wire values; the figures below are from the wire.

### The keys over time

- **captured**: `cFramePhase` = 0.3 in all 794 records, with a single
  timestamp: it is set once. The host echoes 0.3 back. No `sFramePhase` in
  any of the 34,524 host records, so the host did not override it. The host's
  own `s*` keys are `sPingMS`, `sRXerr`, `sRXpass`, `sRXpps`, `sTimeConf` and
  nothing else; none is a phase or stand-off value.
- **captured**: `cPhaseOff` is 3500 with a fresh timestamp every frame until
  video starts, then moves on every decoded frame: 4,629 distinct updates on
  the wire, 3,225 distinct values spanning 3…8,331, wrapping inside one
  8,333 µs frame many times. 5,016 records carry it, 4,639 of them in the
  "changed keys" slots.
- **captured**: `cStandoff` was updated 78 times, all before video
  (3,490–3,500), and its timestamp stops changing at 0.926 s — when the
  first descriptor, with its version field, arrived. The client keeps the key: the round-robin slot keeps re-sending the
  frozen 3,497 every ~0.11 s to the end of the capture (836 records in all),
  and the host echoes `cStandoff` = 3497 back in 169 descriptor tails. So
  **a version-14 host does see `cStandoff`**: live for the first second,
  stale ever after. vr1's "stops being refreshed" was right; "never sees it"
  would be wrong.
- **captured**: with `cPhaseOff` = 3500, `cStandoff` 3,490–3,500 means
  `µs_until_display mod 8333` was 8,323–8,333: the runtime predicts display
  one period after the frame wait returns. The streaming-phase pose packets
  say the same (target − build time ≤ 8,330, see
  [event-schedule.md](event-schedule.md)).
- **captured**: `dbgPhaFault` = 0 throughout (41 updates, one per second).
- **captured**: the descriptor's version field (dataset offset 0x20, value
  offset 0x18) is 14 in all 8,631 descriptors, so every threshold in the
  table above is on its "new" side: no bookend haptics, no stand-off after
  the first descriptor, display reports sent, best-frame serving.

### The control law, replayed

The frame report carries the decode-complete timestamp of every frame
([frame-reports.md](frame-reports.md)) — the same instant
`PhaseEventDecodeComplete` runs — and the pose packets give top of frame
(target time − 8,333). Starting from 3500 and applying the pseudocode above
to the 4,258 decoded frames in order:

- **captured**: the replayed `cPhaseOff` stays within −278…+259 µs of the
  value on the wire across all 4,560 comparable samples (−184…+194 at the
  1st–99th percentile, 14 exact) — over a 39 s open-loop integration of 4,258
  steps of up to ±99 µs. With the division rounded toward −∞ instead of
  toward zero the replay drifts by up to 2.2 ms, so the C truncation in the
  pseudocode matters; it should read `step = trunc(e * 200 / ft)`.
- **captured**: this confirms the sign (earlier than target → `cPhaseOff`
  down), the ±ft/2 wrap, the 200/ft gain, the 0.3 × 8,333 = 2,499 µs target,
  and that the loop keeps running against a version-14 host.

### The loop is open

- **captured**: decoded frames came out a median 5.8 ms after top of
  frame, spread over the whole frame (5th–95th percentile 0.9–8.6 ms),
  against a target of 2.5 ms. The wrapped error stayed large for the whole
  run (mean |e| 1.8–2.3 ms in the first 25 s, 3.2–3.3 ms in the last 15; the
  share of frames within 1 ms of target was 15–29% per 5 s window in the
  first 25 s and 0% in the last 15), and `cPhaseOff`
  gained a net +17.2 ms unwrapped — two full turns of the frame.
- **captured**: the host's frame timing does not track `cPhaseOff`. Arrival
  of a frame's first descriptor after the most recent sub-index 0 pose,
  regressed on `cPhaseOff` as a phase angle: R² = 0.017 over the run, and the
  fitted dependence changes sign between thirds of the run (linear slope
  +0.26, −0.26, +0.03 µs per µs). The arrival phase did drift (median 4.4 ms,
  4.0 ms, 2.9 ms in successive thirds) but not with `cPhaseOff`.
- So with this host the three keys are telemetry: published, echoed, and not
  acted on in any way the capture can show.

## Open questions

- Sign convention between `cPhaseOff` and frame arrival (see "The sign"
  above): needs a host of version < 6 or a probe that moves its pose batch.
- Whether a client may claim/assume a lower host version than the descriptor
  states (14 here) to get the stand-off path, and whether that helps.
- Whether a host ever sets `sFramePhase` (not in `vr3`).
- Why frames land 3 ms later than the 0.3-frame target under Klepton and
  whether a real headset sits on it; `vr3`'s frame loop ran at 108 Hz while
  the loop's `frametime` was 8,333 µs, which alone keeps the error moving.
- Whether the host uses the frozen `cStandoff` or the live `cPhaseOff` for
  anything (statistics, its `dFrmsEarly` / `dFrmsLate` counters).
