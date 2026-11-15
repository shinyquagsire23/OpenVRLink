# Client jitter buffer (`CAudioJitterBuffer<short>`)

Sources (all weak template instantiations in `libvrlink_scene.so`):
ctor +0x156fe0, `Push` +0x1579c0, `Pop` +0x157e14, `BasicPop` +0x158d1c,
`FadeOut` +0x159bd4, `UpdateStats` +0x159c5c;
`SVLAudio::FillFrameBuffer` +0x157d94, `SVLAudio::InitJitterBuffer` +0x158e08,
`SVLAudio::UpdateStats` +0x158f78. `FindBestCrossfadeEndpoint` +0x15991c was
**not** decompiled.

A client does not have to reproduce this bit for bit — the host only sees the
`cAud*` statistics — but the thresholds explain what those statistics mean,
and a client that ignores them will drift against the host's audio clock.

## Structure

- The buffer is a ring of `0x4000` (16384) frames × channels (2 on the client)
  of `short` samples (**static**, constructor arguments `(channels, 0x4000)`
  from the `SVLAudio` constructor). At 48 kHz this holds 341 ms of audio, with
  usable capacity `cap - 1`.
- Buffer occupancy is `fill = (write - read) mod cap`.
- A linearly interpolated 1024-entry `sin²(i/1023 · π/2)` table provides the
  gain curve for every fade and crossfade (**static**, constructor).
- Frame thresholds come from VTE 0x26 (see
  [negotiation-and-settings.md](negotiation-and-settings.md)): `start_fill`
  (50 ms), `min_hi` (25 ms), `min_lo` (15 ms), `target` (20 ms), `low_water`
  (7 ms), `window` (500 ms), `max_rewinds` (2), `fade_in` (50 ms), `xfade_fwd`
  (10 ms), and `xfade_rew` (5 ms).

## Output side

The platform callback asks for N frames; `SVLAudio::FillFrameBuffer` calls
`Pop` (adaptive, default) or `BasicPop` (settings byte 0 == 0) and zero-fills
whatever was not delivered (**static**).

```python
def pop(self, out, n):
    fill = self.fill()
    # 1. start-up / restart gate
    if self.waiting and self.fade_step == 0:
        if fill < self.start_fill:
            self.underrun_frames += n            # -> cAudUnd
            return 0                             # caller outputs silence
        self.waiting = False
        log("CAudioJitterBuffer fade in %d %d", fade_in, fill)
        self.start_fade_in(self.fade_in)         # gain 0 -> 1 over fade_in frames

    # 2. an emergency-rewind streak ends as soon as new data has been pushed
    if self.rewind_streak and self.write != self.write_at_last_rewind:
        self.rewind_streak = 0

    # 3. decide whether to splice
    splice_at = None
    if not self.waiting and not self.crossfading:
        if self.pending_skip == 0:
            if fill - n <= self.low_water:       # about to run dry
                if newest_frame_is_all_zero() or self.rewind_streak >= self.max_rewinds:
                    self.waiting = True
                    self.fade_out(fill)          # gain -> 0 over the remaining frames; cAudFade += 1
                else:
                    tgt = self.target if self.rewind_streak == 0 else self.start_fill
                    self.pending_skip = fill - (tgt + n)          # negative: rewind
                    splice_at = self.find_best_crossfade_endpoint(self.read, max(0, fill - self.xfade_rew))
        else:
            splice_at = next_zero_crossing_after(self.read, max_frames=300)

    # 4. copy frames out, applying fade gain / crossfade; when read == splice_at:
    #      pending_skip <= 0 (rewind): new_read = zero-crossing search backward (<=100 frames)
    #                                  from read + pending_skip; crossfade old -> new over xfade_rew;
    #                                  cAudRew += 1; rewind_streak += 1
    #      pending_skip  > 0 (forward): second cursor = zero-crossing search forward (<=100 frames)
    #                                  from read + pending_skip; crossfade over xfade_fwd, then
    #                                  read = second cursor;  cAudFwd += 1
    #      pending_skip = 0
    # 5. statistics
    self.update_stats(n, n - delivered)
    if delivered < n: log("CAudioJitterBuffer underflow %d %d", n, n - delivered)
    return delivered
```

All of the above is **static** from `Pop`, except the internals of
`find_best_crossfade_endpoint` (**inferred** from its name and arguments: it
returns the read index at which the rewind splice should start).
"Zero crossing" is a sign change of the per-frame sum over channels.

### Windowed fill control loop (`CAudioJitterBuffer::UpdateStats`)

`Pop` calls `UpdateStats` at the end of every callback with `(requested, missing)`:

```python
self.underrun_frames += missing
track min / max / running mean / variance of fill
self.window_frames += requested
if self.window_frames >= self.window:            # every 500 ms of playback
    publish min, max, (mean, variance if >2 samples)
    reset the window
    if not self.waiting and (min > self.min_hi or min < self.min_lo):
        self.pending_skip = min - self.target    # >0 fast-forward, <0 rewind
```

So the regulated quantity is the **minimum** fill seen during the last
500 ms: it is held between 15 and 25 ms, and a correction moves it to 20 ms in
one spliced jump (**static**).

## Input side (`Push`)

```python
def push(self, frames, n):
    if self.splice_next_push:                    # set by overflow or by a sequence gap
        if self.free() < n:
            self.overflow_frames += n; return 0  # -> cAudOvf, packet discarded
        self.splice_next_push = False
        back = min(n, self.fill() - self.low_water)
        if back > 0:
            self.write -= back                   # overwrite the buffered tail ...
            write n frames, the first `back` of them blended new*g + old*(1-g) with the sin² ramp
            return
    k = min(n, self.free())
    copy k frames
    if k < n:
        self.overflow_frames += n - k            # -> cAudOvf
        self.splice_next_push = True
```

`SVLAudio::OnPeerAudioDiscontinuity` +0x157d80 sets `splice_next_push` when
settings byte 2 is non-zero; the FEC receiver calls it on a sequence gap
(see [fec.md](fec.md)) (**static**).

## Statistics published to the host

`SVLAudio::UpdateStats` (client only) writes these SVLRoot keys once per
frame (**static**). "ms" values are `frames * 1000 / output_rate`.

| key | unit | meaning |
|---|---|---|
| `cAudUnd` | frames, cumulative | frames requested by the device that the buffer could not supply (includes all the time spent waiting for start-up fill) |
| `cAudOvf` | frames, cumulative | frames discarded because the ring was full |
| `cAudBufAvg` | ms | mean fill over the last window |
| `cAudBufMin` | ms | minimum fill over the last window |
| `cAudBufMax` | ms | maximum fill over the last window |
| `cAudBufVar` | frames² × 1000 / rate | fill variance over the last window (only if settings byte 1) |
| `cAudRew` | count | rewind splices (only if settings byte 1) |
| `cAudFwd` | count | fast-forward splices (only if settings byte 1) |
| `cAudFade` | count | fade-outs to silence (only if settings byte 1) |
| `cAudDrop`, `cAudFEC` | packets | see [fec.md](fec.md) |

`cSoundSPS` appears in the binary's key vocabulary but its writer was not
found in `SVLAudio`; **inferred** to be a measured samples-per-second figure
from `SoundLogger`.

Klepton's live trace (`STEAMLINK.md` SL-25/26) is consistent with this
reading: `cAudUnd` climbing before the stream starts, `cAudBufAvg` 76–100.
`vr3` values are in the capture section below.

## Capture verification (`vr3`)

Capture `vr3` records 40.26 s of `vrlink` streaming under Klepton (80,011
intact SVL datagrams, each with a `CLOCK_MONOTONIC` receive/send timestamp).
Times below are seconds from the first SVL datagram of the capture. Unlike the
earlier `vr1` capture, which had a third of its datagrams torn and no
timestamps (giving only lower-bound counts), every count here is complete.
The audio burst runs from t = 1.855 to 11.556 s (see
[packet-format.md](packet-format.md)), carrying 9.71 s of all-zero PCM with no
packet loss. Client log lines carry no timestamps of their own and are
bracketed by the datagrams on either side of them in the log.

Playback startup and shutdown in `vr3` match the configured thresholds:

- **captured**: `vrlink` logged `CAudioJitterBuffer fade in 2400 2880` between
  the datagrams at t = 1.9089 and 1.9090 s (54 ms after the first audio
  message). Playback started on the first device callback that found at least
  `start_fill` (2400 frames) buffered — 2880 frames here, out of 3,136 frames
  received by then — with a 2400-frame fade-in.
- **captured**: `vrlink` logged `CAudioJitterBuffer fade out 479 479` followed
  by `CAudioJitterBuffer underflow 240 1` between t = 11.581 and 11.585 s (25
  to 29 ms after the last audio message). Once input stopped and fill reached
  the low-water mark, the buffer faded out over its remaining 479 frames,
  leaving the next 240-frame callback one frame short. Those are the only
  fade-in, fade-out, and underflow log lines in the session.

The `cAud*` keys travel client to host as 32-byte records (name, f64, i32) in
class 3 type 0x07 messages. Below are the **captured** values across the 40 s
session:

| key | before the burst | during | after |
|---|---|---|---|
| `cAudUnd` | 4080 at t = 0.006 s, rising at 47,929 frames/s in steps that are multiples of 240 (mostly 480) | flat at 95,040 from t = 1.900 to 11.587 s | 95,041 at t = 11.587 s (the one-frame underflow), then rising at 47,996 frames/s to 1,470,961 at the end |
| `cAudBufAvg` | 0 | 50 at t = 2.40 s, 30 from t = 2.91 s (29 once) | stays 30 |
| `cAudBufMin` | 0 | 39 at t = 2.40 s, 19 from t = 2.91 s | stays 19 |
| `cAudBufMax` | 0 | 64 at t = 2.40 s, 49 at 2.91 s, then alternating 39 / 44 | stays 44 |
| `cAudBufVar` | 0 | 1164 at t = 2.40 s, then 846 to 1544, a new value every 0.5 s | stays at the last value (959) |
| `cAudFwd` | 0 | 0 -> 1 at t = 2.41 s | 1 |
| `cAudFade` | 0 | 0 | 0 -> 1 at t = 11.59 s |
| `cAudRew`, `cAudOvf`, `cAudDrop`, `cAudFEC` | 0 | 0 | 0 |

These measurements confirm several parts of the static analysis:

- **captured**: `cAudUnd` advances at the 48 kHz device rate (in multiples of
  the 240-frame burst) whenever the buffer is waiting for start-up fill, both
  before audio first arrives and after the stream stops, and stays flat while
  audio plays. As a result, `cAudUnd` climbs at 48,000 frames/s whenever the
  host is not sending audio. (`vr1` attributed a session-long climb to tracer
  starvation, whereas `vr3` shows that `cAudUnd` climbs whenever the host is
  silent.)
- **captured**: Window statistics are published every 0.5 s of playback (new
  values at t = 2.40, 2.91, 3.41, 3.91, ...), matching the 500 ms window, and
  are reported in milliseconds: the first window reports min 39 / avg 50 /
  max 64 for a buffer that started playing at 2880 frames (60 ms).
- **captured**: In the first 500 ms window, the minimum fill (39 ms) exceeded
  `min_hi` (25 ms); `cAudFwd` incremented to 1 within 10 ms of that window
  being published, and the next window reported min 19 / avg 30 — a 20 ms drop
  versus the predicted `min - target` = 19 ms. For the remaining 9 s of
  playback, the minimum stayed at 19 ms (inside the 15 to 25 ms band) with no
  further splices.
- **captured**: `cAudFade` counts the fade-out (one log line, one count), and
  the settings-byte-1 keys (`cAudRew`, `cAudFwd`, `cAudFade`, `cAudBufVar`)
  are published as configured by byte 1 = 1.
- **captured**: After the stream stops, the window keys retain their last
  values for the rest of the session rather than resetting to 0, consistent
  with `Pop` returning at the start-up gate before `UpdateStats` runs.
- **captured**: The host echoes all eleven `cAud*` keys back in frame
  descriptor trailers (docs/svl-video/frame-descriptor.md).
- `vr1` reported `cAudFade` 0 -> 54 and all window statistics at 0 because
  tracer overhead starved that session's audio path; `vr3` supersedes it.

## Open questions

- Rewind, overflow, emergency rewind, and sequence-gap splices were not
  exercised (`cAudRew`, `cAudOvf`, and `cAudDrop` stayed 0) and remain
  **static** only; testing them requires a lossy or jittery link.
- The exact scaling of `cAudBufVar` (846 to 1544 in `vr3`) is not pinned down
  by the capture.
- Whether the host changes its behavior in response to any `cAud*` key (such as
  rate matching or toggling FEC) is unknown; a probe reporting large `cAudDrop`
  would test this. The minimal probe sends no `cAud*` keys at all and still
  receives audio (docs/svl-values/startup-exchange.md).
- `FindBestCrossfadeEndpoint` (+0x15991c) has not been decompiled (likely a
  correlation search).
