# Clock synchronization and ping

Sources: `SVLRoot::SymmetricTimingUpdate(int, int)` +0x165a38,
`SVLDataLink::ReceivedData(dataset*)` +0x15a9b8 (type-5 branch),
`QSVLClient::SendPoses(int, int)` +0xf4d34, `QSVLClient::OnRenderComplete`
+0xf671c, `QSVLClient::ReceivedBookend` +0xf6cf8,
`QSVLRendererXR::FlipFrame` +0x10ae78. All details below are **static** unless
marked otherwise.

## Timestamps

`GetCurrentTimestamp()` returns a signed 32-bit count of microseconds on the
local clock (wraps every ~71.6 min; every comparison in this layer is done on
differences). Each side has its own epoch; nothing on the wire is an absolute
time.

## Wire timestamp fields

| direction | carrier | field | meaning |
|---|---|---|---|
| host → client | `dataset` type 5 with flags byte 0x02 (word0 & 0xff00 == 0x0200), payload offset 0 (packet offset 8), i32 | host timestamp when the packet was sent | input to the client's estimator |
| host → client | same packet, payload offset 4 (packet offset 0x0c), i32 | the **host's** current offset estimate (`host_now − client_send_time`, filtered) | stored at `SVLRoot+0xc84` |
| client → host | pose packet (`dataset` type 3, flags 0x01), packet offset 0x0c, i32 | the **client's** offset estimate `SVLRoot+0xc7c` (logged as `toff=`) | mirror of the host's offset field |
| client → host | pose packet, packet offset 0x10, i32 | client timestamp just before the packet is submitted | the host's estimator input, to within what `vr3` can resolve (see below) |

(Type 5 / flags 0x02 is the video-stream packet that also carries the frame
descriptor; its remaining layout is in docs/svl-video/. The same packet's byte
at offset 0x15 is the FEC mode — `SVLDataLink::HandleFECChange( %d )`.)

## Offset estimator (`SymmetricTimingUpdate`)

`SymmetricTimingUpdate(peer_ts, local_now)` is called from one place:
`SVLDataLink::ReceivedData`, once for **every** class-5 type-2 element (frame
descriptor), with `peer_ts` = the descriptor's first i32 and `local_now` =
`GetCurrentTimestamp()` taken there (**static**). It keeps `off` (`+0xc7c`)
and a confidence counter `conf` (`+0xc80`, 0..400). It tracks the **smallest**
plausible `local_now − peer_ts` (clock offset plus minimum one-way delay),
stepping down quickly and creeping up slowly:

```python
def symmetric_timing_update(peer_ts, local_now):
    d = local_now - peer_ts
    if conf == 0:
        off = d; conf = 1
    else:
        k = 1_000_000 // (conf + 5)
        err = d - off
        if err <= 0:
            if err >= -(k // 2):                     # plausible faster path: follow it down
                off -= min(100, trunc(wrap32(err * k) / -200_000))
                if conf < 400: conf += 1
            elif conf < 20:                          # big jump while unsure: restart
                conf = 0
            else:
                conf -= 4
        elif err > k:                                # late packet: distrust slightly
            conf -= 1
        else:                                        # creep up (clock drift)
            off += min(5, trunc(wrap32(err * k) / 2_000_000))
            if conf < 400: conf += 1
    # latency of this packet relative to the best case, plus half the round trip
    lat = (local_now - (off + peer_ts)) + (peer_off + off) // 2      # -> +0x194
    peak = max(lat, peak - decay)                                    # decay = +0x198
    peak = min(peak, 100_000)                                        # -> +0x19c
```

`wrap32` reproduces the binary's 32-bit overflow. The product `err * k` is a
32-bit signed multiply in the binary, and only the *upper* bound of each step
is clamped (**static**). While `conf` is small, `k` is large (166,666 at
`conf` = 1), so the product overflows: in the "creep up" branch that happens
for `conf` < 17 whenever `err * k` ≥ 2³¹, and the wrapped negative product
moves `off` **down** by up to 1,073 µs in a single update. In the "follow it
down" branch (`conf` < 11), a wrapped product can similarly move `off` up
unclamped. **captured**: `vrlink` hit this overflow at stream start in `vr3`
(see below) — its offset estimate dropped 7.7 ms below the true offset within
25 ms and took about 25 s to creep back up. An independent client should
compute the products in 64-bit arithmetic so the published round-trip time
starts accurate rather than negative.

`peer_off` is the value the peer reported (`+0xc84`). Since
`off ≈ (C − H) + d_hc` and `peer_off ≈ (H − C) + d_ch`, their sum is the
round-trip time with the clock difference canceled.

## Published values

`QSVLClient::OnRenderComplete` writes, once per rendered frame:

| key | value | meaning |
|---|---|---|
| `cPingMS` | `(off + peer_off) / 1000.0` | round-trip time in ms |
| `cPingAMS` | `peak / 1000.0` | decaying peak of per-packet latency (jitter excess + half RTT) in ms, capped at 100 |

**captured** (`vr3`, wired LAN): `cPingMS` started at 1.399 ms on the first
descriptor, went negative (down to −6.289 ms) while the estimator recovered
from its startup overflow, and settled at 0.58–0.65 ms from 24 s onward.
`cPingAMS` hit the 100.0 ms clamp once at stream start and stayed near
1.0–1.3 ms late in the run. Earlier Klepton traces showed `cPingMS` of
1.3–9.2 ms and `cPingAMS` of 45–100 ms.

## Converting a host timestamp to the client clock

The client converts a host timestamp to the local SVL clock when processing
host timing events and frame target display times:

```python
local = host_ts + off - (off + peer_off) // 2
```

(`ReceivedBookend`: `off + ts − (peer_off + off)/2`; `FlipFrame` applies the
same expression to the frame metadata's u32 at byte offset 0xe0 and, for host
version > 5, rewrites the OpenXR display time to
`xr_now + (local − svl_now) × 1000 ns`.)

## Connection-alive test

`SVLRoot::ReceivedBookend` +0x1659b4 and `HandleUpdatedRemotePacket`
+0x1659dc stamp `SVLRoot+0xc70` with the 64-bit microsecond clock. The 1 ms
tick (event type 1, see [event-schedule.md](event-schedule.md)) declares the
connection lost when that stamp is 3,000,000 µs old (vtable +0x50,
`HandleConnectionLostEvent`) and regained when it is fresh again (vtable
+0x58). `SVLRoot::BIsConnectionActive` gates microphone transmission.

## Capture verification (`vr3`)

Capture `vr3` records 40.26 s of `vrlink` under Klepton across 80,011 intact
datagrams with `CLOCK_MONOTONIC` capture timestamps, containing 17,423
client-to-host pose elements (class 3 type 1) and 8,631 host-to-client frame
descriptors (class 5 type 2). Offsets below are element-value offsets
(dataset offset − 8).

### Timestamp and offset fields

- **captured**: The pose packet's i32 at value offset 4 (`toff`) is 0 in the
  first 402 pose packets and non-zero from the first pose packet after the
  first descriptor (3.8 ms after it) to the end: 3,148 distinct values across
  17,021 packets. Value offsets 8 and 12 are the send and build timestamps;
  send − build is 3–15 µs (1st–99th percentile; median 5 µs, max 360 µs).
- **captured**: The descriptor's i32 at value offset 0 (`tx_time`) is stamped
  once per frame rather than per packet: the opening and closing descriptors
  for a frame carry the same `tx_time` even though they arrive a median 0.78 ms
  apart, and `tx_time` advances by a median 9,203 µs per frame. The i32 at
  value offset 4 (the host's estimate) took 1,034 distinct values between
  839,208,204 and 839,207,026, drifting downward at −29.7 µs/s (7,591 steps of
  0, 1,029 steps of −1…−4, and ten steps of +1…+4).
- **captured**: The two estimates have opposite signs and sum to the round-trip
  time: 1,399 µs at the first descriptor, and 579–646 µs from 24 s to the end.
  Between stream start and 24 s, the sum goes negative due to the 32-bit
  overflow described below.
- **captured**: `vrlink`'s estimate rose by +32.0 µs/s over the last 12 s while
  the host's fell by 29.4 µs/s: the two machines' clocks drift apart by about
  30 ppm and each estimator tracks the drift while their sum stays roughly
  constant.

### Client SVL clock versus capture clock

- **captured**: The pose send timestamp equals the capture's `CLOCK_MONOTONIC`
  microseconds, mod 2³², plus 1,455,121 µs at the start of the run — so
  `vrlink`'s SVL clock is distinct from `CLOCK_MONOTONIC` as read by the
  tracer, and the offset is **not constant**: the lower envelope of
  (capture time − send timestamp), taken per second, grows by 6.0 µs/s (linear
  fit, residuals within ±9 µs over 41 one-second windows), totaling 0.24 ms
  over the run. Above that envelope, the tracer's timestamp trails `vrlink`'s
  send timestamp by a median 25 µs (99th percentile ~190 µs, one outlier of
  7.3 ms).
- **captured**: On receive the order is reversed: `vrlink` stamps a descriptor
  110–180 µs after the tracer does (177 µs on the first descriptor, where
  `toff` is `local_now − tx_time`; ~115 µs fits the last 15 s).

### Estimator replay against captured `toff`

The estimator above was fed the 8,631 captured `tx_time` values with
`local_now` set to the capture timestamp converted to the client clock (using
the fit above) plus a constant receive delay, and its `off` was compared
against `toff` in each of the 17,021 subsequent pose packets.

- **captured**: Using 32-bit signed multiplication and a 120 µs receive delay,
  the replay produces 290 exact matches, 3,602 within ±5 µs, and 7,768 within
  ±50 µs, with residuals (simulated − sent) of 0 / +6 / +89 / +361 / +791 µs
  at the 1st / 25th / 50th / 75th / 99th percentiles. Nearly all error sits in
  the first 22 s (median +343 µs, 0 exact); over the last 16 s (6,615 packets),
  the simulation stays within 0 to +13 µs of the sent value (median +5 µs, 290
  exact). Across the run, the estimator took the initialize branch once,
  creep-up 6,618 times, follow-down 1,242 times, and late 770 times, with zero
  restarts and zero −4 confidence steps.
- **captured**: With unbounded integer multiplication instead of 32-bit wrap,
  the fit is much worse — residuals of −110 / +105 / +1,482 / +6,609 µs at the
  25th / 50th / 75th / 99th percentiles (7.6 ms worst case) — because unbounded
  arithmetic never produces the startup drop.
- **captured**: Replaying with 32-bit wrap reproduces the startup drop step by
  step. The host sent frame 0, paused 111 ms, and then sent frames 1–14 in a
  32 ms burst whose `tx_time` values are 6.5–15 ms apart; each arrives "less
  late" than the previous frame, while all arrive later than frame 0. With
  `conf` below 15, the wrapped product in the creep-up branch goes negative,
  and `vrlink`'s `toff` stepped −931, −533, −715, −850, −1,151, −1,522,
  −1,041, and −985 µs between consecutive pose packets (−7,728 µs total). The
  simulation matches the first four steps within 8 µs before diverging by a few
  hundred µs (the wrapped product is sensitive to exact `local_now`, which the
  capture only resolves to ±50 µs); at 2.9 s it sits 0.76 ms above `vrlink`'s
  value.
- **captured**: Recovery is slow because the creep-up branch adds at most 5 µs
  per descriptor: `toff` + host estimate was −6,314 µs right after the burst,
  −4,713 µs at 2.9 s, −923 µs at 10.9 s, +98 µs at 16.9 s, and +579 µs at
  24.9 s.
- Exact per-packet agreement is not possible from a wire capture alone because
  `local_now` is read inside `vrlink` and never sent on the wire.

### Published values

- **captured**: `cPingMS` × 1000 equals `toff` + host estimate. Of 3,153
  distinct `cPingMS` updates sent after 1.5 s, 3,123 match the sum of an
  adjacent pose `toff` and descriptor estimate exactly, and the rest are within
  10 µs. `cPingMS` stayed negative for the first ~16 s (minimum −6.289 ms).
- **captured**: The host publishes `sPingMS`, which matches `vrlink`'s
  `cPingMS` at the same instant to within 0.001 ms in every sample, including
  negative values. The host also publishes `sTimeConf` (387 in its first
  record, 400 afterward), matching the estimator's confidence ceiling and
  confirming that the host runs the same estimator.
- **captured**: `cPingAMS` hit the 100.0 ms clamp when the startup burst
  arrived 105 ms "late", then decayed by 1.000 ms per descriptor until reaching
  live latency, showing that the decay step at `SVLRoot+0x198` is 1,000 µs in
  this session. It starts at 0 before the first descriptor and reads −0.5 right
  after it.

### Host estimator input

- **captured**: The 8-byte datagram prefix holds a sequence number, a zero u16,
  and a checksum (docs/svl-transport/) with no timestamp; the field tentatively
  labeled `ts` in `vr1` was the checksum.
- **captured**: The host publishes `tsLastWGP`, a host-clock timestamp. Mapped
  onto the client clock using `toff`, it lands 509–612 µs (one round trip)
  after the send timestamp of a **sub-index 0** pose packet in all 65 samples
  after 25 s, identifying it as the host's receive time for that packet. Across
  167 samples (166 matched to a sub-index 0 packet), `tsLastWGP` minus that
  packet's value-offset-8 timestamp minus the host's estimate has a median of
  −58 µs (−85…+35 µs, 0th–99th percentile), placing the host's estimate within
  0.1 ms of `host_receive_time − pose_send_timestamp`. Value offsets 8 and 12
  sit only 5 µs apart, which is too close for the capture to separate.
- **captured**: Payload byte 13 of the descriptor (the FEC mode byte) is 0x20
  in all 8,631 descriptors, and byte 2 is 0x20 in all 17,423 pose packets.
  `SVLDataLink::HandleFECChange( 32 )` is logged once.

## Open questions

- Determine which of the pose packet's two timestamps (dataset offset 0x10 or
  0x14) feeds the host's estimator; a probe sending them with a large offset
  would show which one moves the host's estimate.
- Determine why `vrlink`'s SVL clock sits 1.455 s away from the tracer's
  `CLOCK_MONOTONIC` and drifts by 6 µs/s relative to it (Klepton's guest clock
  source was not inspected; on physical headset hardware they may be the same
  clock).
- Check whether the host's estimator has the same 32-bit overflow; its estimate
  stepped by at most 4 µs per descriptor in `vr3` and never hit the overflow
  threshold.
- Check whether negative `cPingMS` / `sPingMS` values during startup affect
  host behavior (the host's `dPingThr` key dipped to 0.11 in `vr3`, though no
  connection to negative ping was established).
- Check whether the decay step at `SVLRoot+0x198` is always a fixed 1,000 µs
  (its writer was not traced).
