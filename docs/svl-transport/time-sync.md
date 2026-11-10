# Time sync and SVL timestamps

Source: `SVLRoot::SymmetricTimingUpdate` (`+0x165a38`),
`SVLRoot::GetSVLTimestampFromSystemTimeInTicks` (`+0x165c5c`),
`SVLDataLink::ReceivedData` case 5 (`+0x15a9b8`), `GetCurrentTimestamp`
(exported). The clock-offset *algorithm* is **static**; the packets that feed
it, their units and the estimate's behavior over a session are **captured**
(capture `vr3`: 8,632 class 5 type `0x02` elements, all host→client, the
first 0.926 s after the client's first datagram). The fuller treatment of the
estimator is in `../svl-timing/clock-sync.md`; this page keeps to what the
transport does.

## 1. SVL timestamp units

`GetSVLTimestampFromSystemTimeInTicks(ticks)` (`+0x165c5c`) converts a
system-tick value to an SVL timestamp:

```python
# freq = GetSystemTimeFrequency()  (ticks per second)
svl_ts = base_offset + int(ticks / (freq / 1_000_000.0))
```

So **SVL timestamps are in microseconds** (a 32-bit `int`, wraps ~every 71
min). `base_offset` (`SVLRoot+0x184`) is initialized once, smoothed by a factor
`0.99` (`0x3f7d70a4`) against `GetCurrentTimestamp()` (also µs). `GetCurrentTimestamp`
is the client's µs monotonic clock; Klepton SL-23 corroborates the µs unit (the
≥ 1,000,001 µs = 1 s throttle in `CheckUpdateCounters`).

## 2. Symmetric clock-offset estimator

When a channel‑5 / sub‑type‑`0x02` element arrives, `ReceivedData` reads the
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
  reset if a sample lands wildly early while unconverged.
- The result folds in a half-RTT term and is stored to `this+0x194` /
  `this+0x19c`, clamped to **≤ 100000 µs (100 ms)**.

`ReceivedData` also copies the `int` at value offset 4 of the same element
into `SVLRoot+0xc84` (**static**, `+0x15a9b8`): that is the *host's* estimate
of the offset in the other direction, sent back so each side holds both.

This is a one-way-offset / jitter-smoothing estimator (NTP-ish) with no
request/reply ping: the host stamps every frame descriptor and the
client folds each into the estimate. The estimate is what lets the client place
received frames/audio on a common timeline and compute the decode/display
latencies it reports back (`SendLastRXID`, `reliable-stream.md` §4).

The FEC state also rides the `0x0205` packet: `ReceivedData` reads a byte at
element offset `0x15` and calls `SVLDataLink::HandleFECChange` ("…HandleFECChange(
%d )…") when it changes (owned by the video/FEC agent).

## 3. What `vr3` shows (**captured**)

- **Units.** The value-offset-0 field of successive descriptors advances
  999,944 µs per second of capture clock, and the client's own timestamp in
  its pose packets 999,994 µs per second: both are microsecond clocks, and the
  two machines' clocks differed by about 50 ppm.
- **No reply.** Nothing the client sends answers a descriptor. Instead each
  side reports its current estimate inside traffic it sends anyway: the client
  in the pose header (the `int` after the four header bytes,
  `../svl-tracking-input/poses.md`), the host at descriptor value offset 4.
  Mid-session the two were −839,208,632 and +839,207,664 — equal and opposite
  to within a millisecond, as two estimates of the same offset should be.
- **Start.** The client's reported offset is 0 in its first 402 datagrams and
  becomes non-zero 3.7 ms after the first descriptor arrives. There is no
  other time exchange before video: for the first 0.93 s neither side knows
  the other's clock.
- **Settling.** Relative to its value at the end of the capture, the client's
  estimate was −0.4 ms at its first sample, −8.0 ms at 1.1 s (pulled down by
  the startup burst, where the "late" branch may move it 100 µs per sample),
  then crept back at the "early" branch's 5 µs per sample: −7.1 ms at 2 s,
  −5.2 ms at 5 s, −2.7 ms at 10 s, −0.9 ms at 20 s, −0.3 ms at 30 s. So the
  estimate is good to a millisecond only after about 20 s. In that time the
  round-trip figure the client derives from the two estimates (`cPingMS`) was
  negative, −6.3 ms at worst, and the host's (`sPingMS`) likewise — a
  result of the same undershoot and not a measurement.
- **Jitter.** After the first two seconds, descriptor arrival time minus its
  transmit stamp, above the smallest value seen: median 1.2 ms, 90th
  percentile 2.0 ms, 99th 2.3 ms, maximum 10.8 ms.
- **FEC byte.** Value offset 0x0d (element offset 0x15) was 32 in every
  descriptor, and the client logged `SVLDataLink::HandleFECChange( 32 )` once.
- The host's convergence counter, published as `sTimeConf`, read 387 in the
  first statistics the client received (1.18 s) and 400, its ceiling, from
  1.39 s on: the host had needed under a second of pose packets.

## Open questions / to confirm on the wire

Settled by `vr3`: the host timestamp is a little-endian microsecond `int` at
value offset 0; the FEC byte is at value offset 0x0d; there is no client→host
timing reply; how long the client's estimate takes to settle (about 20 s to
within 1 ms).

Still open:
- Why the client's estimate is pushed 8 ms low during the startup burst. If
  the host stamps descriptors when it queues them and then sends a backlog,
  the samples would err the other way; the direction seen suggests the first
  descriptors were stamped late or the earliest sample was itself an outlier.
  A capture with the host's send times would tell.
- Whether a client that seeds its estimate better (for example by ignoring
  the first second of samples) gets steadier frame pacing; the host's pacing
  uses the pose timestamps (`../svl-timing/`).
- Timestamp wrap: the 32-bit microsecond clocks wrap every 71.6 minutes and no
  capture is that long.
