# Time sync and SVL timestamps

Source: `SVLRoot::SymmetricTimingUpdate` (`+0x165a38`),
`SVLRoot::GetSVLTimestampFromSystemTimeInTicks` (`+0x165c5c`),
`SVLDataLink::ReceivedData` case 5 (`+0x15a9b8`), and `GetCurrentTimestamp`
(exported). The clock-offset *algorithm* is **static**; the packets that feed
it, their units, and the estimate's behavior across a session are **captured**
(capture `vr3`: 8,632 class 5 type `0x02` elements, all host→client, starting
0.926 s after the client's first datagram). Full details on the estimator live
in `../svl-timing/clock-sync.md`; this page covers the transport-level fields
and dispatch.

## 1. SVL timestamp units

`GetSVLTimestampFromSystemTimeInTicks(ticks)` (`+0x165c5c`) converts a
system-tick value to an SVL timestamp:

```python
# freq = GetSystemTimeFrequency()  (ticks per second)
svl_ts = base_offset + int(ticks / (freq / 1_000_000.0))
```

**SVL timestamps are in microseconds** (stored as a 32-bit `int` that wraps
every ~71.6 min). `base_offset` (`SVLRoot+0x184`) is initialized once and
smoothed by a factor of `0.99` (`0x3f7d70a4`) against `GetCurrentTimestamp()`
(also in µs). `GetCurrentTimestamp` is the client's monotonic microsecond clock;
Klepton SL-23 corroborates the microsecond unit via the ≥ 1,000,001 µs (1 s)
throttle in `CheckUpdateCounters`.

## 2. Symmetric clock-offset estimator

When a channel-5 / sub-type-`0x02` element arrives, `ReceivedData` reads the
**host timestamp** from the element's value (offset 0, `int` µs) and calls:

```
SVLRoot::SymmetricTimingUpdate(host_ts, local_ts = GetCurrentTimestamp())
```

`SymmetricTimingUpdate(param_1 = host_ts, param_2 = local_ts)` (`+0x165a38`)
maintains a filtered estimate of the client→host clock offset under a mutex
(`SVLRoot+0xc88`):

- `offset_raw = local_ts - host_ts` (`iVar2`).
- A convergence counter (`this+0xc80`) grows from 0; the per-sample step size
  is `1_000_000 / (counter + 5)` µs, so the filter starts coarse and tightens
  as it converges (up to counter 399).
- The running offset estimate (`this+0xc7c`) is nudged toward `offset_raw` by a
  clamped step (±100 µs per late sample, +5 µs max per early sample), with a
  reset if a sample lands far early while unconverged.
- The result folds in a half-RTT term and is stored to `this+0x194` /
  `this+0x19c`, clamped to **≤ 100000 µs (100 ms)**.

`ReceivedData` also copies the `int` at value offset 4 of the same element
into `SVLRoot+0xc84` (**static**, `+0x15a9b8`), which holds the *host's*
estimate of the offset in the opposite direction so both endpoints know both
estimates.

This acts as a one-way-offset and jitter-smoothing filter without a dedicated
ping/pong exchange: the host stamps every frame descriptor and the client
feeds each stamp into its filter. The resulting offset lets the client place
received video and audio frames on a shared timeline and compute the
decode/display latencies reported via `SendLastRXID` (`reliable-stream.md` §4).

FEC configuration also rides on `0x0205` frame descriptors: `ReceivedData`
reads the byte at element offset `0x15` and calls `SVLDataLink::HandleFECChange`
(`"…HandleFECChange( %d )…"`) whenever it changes (see `../svl-video/`).

## 3. Captured behavior in `vr3` (**captured**)

- Descriptor timestamps at value offset 0 advance by 999,944 µs per second of
  capture clock, while client pose timestamps advance by 999,994 µs per second,
  confirming microsecond clocks on both machines with ~50 ppm relative drift.
- `vrlink` sends no dedicated reply to a frame descriptor. Instead, each
  endpoint embeds its current offset estimate inside regular traffic: the
  client writes its estimate in the pose header (the `int` after the four
  header bytes; `../svl-tracking-input/poses.md`), and the host writes its
  estimate at descriptor value offset 4. Mid-session, the two values were
  −839,208,632 µs and +839,207,664 µs — equal and opposite to within 1 ms.
- The client's reported offset is 0 across its first 402 datagrams and becomes
  non-zero 3.7 ms after the first descriptor arrives. Neither endpoint
  exchanges timestamps during the 0.93 s before video starts.
- Relative to its final value at the end of the capture, the client's offset
  estimate started at −0.4 ms on the first sample, dropped to −8.0 ms at 1.1 s
  during the startup video burst (where delayed samples can pull the estimate
  down by 100 µs per sample in the "late" branch), and then crept back at the
  "early" branch limit of +5 µs per sample (−7.1 ms at 2 s, −5.2 ms at 5 s,
  −2.7 ms at 10 s, −0.9 ms at 20 s, and −0.3 ms at 30 s). Reaching 1 ms
  accuracy therefore took roughly 20 s. During that recovery, the RTT figure
  derived from summing the two one-way estimates went negative on both sides
  (reaching −6.3 ms in `cPingMS` and similarly negative values in `sPingMS`) as
  an artifact of the asymmetric filter clamp.
- After the first 2 s, one-way arrival jitter (descriptor arrival time minus
  transmit timestamp, relative to the session minimum) had a median of 1.2 ms,
  90th percentile of 2.0 ms, 99th percentile of 2.3 ms, and maximum of 10.8 ms.
- The FEC byte at value offset `0x0d` (element offset `0x15`) was 32 in every
  descriptor, and `vrlink` logged `SVLDataLink::HandleFECChange( 32 )` once.
- The host's convergence counter (`sTimeConf`) read 387 in the first stats
  batch received at 1.18 s and hit its ceiling of 400 from 1.39 s onward,
  converging in under 1 s of pose traffic.

## Open questions / to confirm on the wire

Capture `vr3` confirmed that the host timestamp is a little-endian microsecond
`int` at value offset 0, the FEC byte is at value offset `0x0d`, the client
sends no separate timing reply, and the client's offset estimate takes ~20 s to
settle within 1 ms.

Remaining open questions:
- Why the client's offset estimate dips 8 ms low during the startup burst. If
  the host stamped descriptors when queuing them and then drained a backlog,
  the samples would err in the opposite direction; the observed sign suggests
  that early descriptors were stamped late or the initial sample was an
  outlier. Comparing host transmit timestamps against wire arrival times would
  distinguish the two.
- Whether seeding or gating the client estimator (for example, ignoring samples
  during the first second of video) produces steadier frame pacing, since host
  pacing uses client pose timestamps (`../svl-timing/`).
- Behavior across 32-bit microsecond clock wraparound every 71.6 minutes, which
  no capture has yet reached.
