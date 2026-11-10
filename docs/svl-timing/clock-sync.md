# Clock synchronization and ping

Sources: `SVLRoot::SymmetricTimingUpdate(int, int)` +0x165a38,
`SVLDataLink::ReceivedData(dataset*)` +0x15a9b8 (type-5 branch),
`QSVLClient::SendPoses(int, int)` +0xf4d34, `QSVLClient::OnRenderComplete`
+0xf671c, `QSVLClient::ReceivedBookend` +0xf6cf8,
`QSVLRendererXR::FlipFrame` +0x10ae78. All **static** unless marked.

## Timestamps

`GetCurrentTimestamp()` returns a signed 32-bit count of microseconds on the
local clock (wraps every ~71.6 min; every comparison in this layer is done on
differences). Each side has its own epoch; nothing on the wire is an absolute
time.

## What each side tells the other

| direction | carrier | field | meaning |
|---|---|---|---|
| host → client | `dataset` type 5 with flags byte 0x02 (word0 & 0xff00 == 0x0200), payload offset 0 (packet offset 8), i32 | host timestamp when the packet was sent | input to the client's estimator |
| host → client | same packet, payload offset 4 (packet offset 0x0c), i32 | the **host's** current offset estimate (`host_now − client_send_time`, filtered) | stored at `SVLRoot+0xc84` |
| client → host | pose packet (`dataset` type 3, flags 0x01), packet offset 0x0c, i32 | the **client's** offset estimate `SVLRoot+0xc7c` (logged as `toff=`) | the mirror of the above |
| client → host | pose packet, packet offset 0x10, i32 | client timestamp just before the packet is submitted | the host's estimator input, to within what `vr3` can resolve (see below) |

(Type 5 / flags 0x02 is the video-stream packet that also carries the frame
descriptor; its remaining layout is in docs/svl-video/. The same packet's byte
at offset 0x15 is the FEC mode — `SVLDataLink::HandleFECChange( %d )`.)

## The estimator

`SymmetricTimingUpdate(peer_ts, local_now)` is called from exactly one place:
`SVLDataLink::ReceivedData`, once for **every** class-5 type-2 element (frame
descriptor), with `peer_ts` = the descriptor's first i32 and `local_now` =
`GetCurrentTimestamp()` taken there (**static**). It keeps `off` (`+0xc7c`)
and a confidence counter `conf` (`+0xc80`, 0..400). It tracks the **smallest**
`local_now − peer_ts` it believes in — i.e. clock difference plus minimum
one-way delay — moving down quickly and up slowly:

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

`wrap32` reproduces the binary's overflow and has to stay. The product `err * k` is a 32-bit signed multiply
in the binary and only the *upper* bound of each step is clamped (**static**).
While `conf` is small `k` is large (166,666 at `conf` = 1), so the product
overflows: in the "creep up" branch that happens for `conf` < 17 whenever
`err * k` ≥ 2³¹, and the wrapped, negative product then moves `off` **down**
by up to 1,073 µs in one update. In the "follow it down" branch (`conf` < 11)
a wrapped product can likewise move `off` up, unclamped. **captured**: this is
exactly what the real client did at stream start in `vr3` (below) — its
estimate fell 7.7 ms below the true offset in 25 ms and took about 25 s to
creep back. An independent client should compute the products in 64 bits; the
host cannot tell, except that the published round trip is right from the first
second instead of negative.

`peer_off` is the value the peer reported (`+0xc84`). Since
`off ≈ (C − H) + d_hc` and `peer_off ≈ (H − C) + d_ch`, their sum is the
round-trip time with the clock difference canceled.

## Published values

`QSVLClient::OnRenderComplete` writes, once per rendered frame:

| key | value | meaning |
|---|---|---|
| `cPingMS` | `(off + peer_off) / 1000.0` | round-trip time in ms |
| `cPingAMS` | `peak / 1000.0` | decaying peak of per-packet latency (jitter excess + half RTT) in ms, capped at 100 |

**captured** (`vr3`, wired LAN): `cPingMS` 1.399 at the first descriptor,
negative (down to −6.289) while the estimator recovered from its start-up
overflow, 0.58–0.65 from 24 s on. `cPingAMS` hit the 100.0 clamp once, at
stream start, and sat near 1.0–1.3 late in the run. Earlier Klepton traces
showed `cPingMS` 1.3–9.2 and `cPingAMS` 45–100.

## Converting a host timestamp to the client clock

Used for host timing events and for the frame's target display time:

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

## Confirmed against capture `vr3`

`vr3`: real client under Klepton, 40.26 s, 80,011 intact datagrams with
CLOCK_MONOTONIC capture timestamps; 17,423 pose elements (class 3 type 1)
client → host and 8,631 frame descriptors (class 5 type 2) host → client.
Offsets below are element-value offsets (dataset offset − 8).

### The fields

- **captured**: the pose packet's i32 at value offset 4 (`toff`) is 0 in the
  first 402 pose packets and non-zero from the first pose packet after the
  first descriptor (3.8 ms after it) to the end: 3,148 distinct values in
  17,021 packets. Value offsets 8 and 12 are the send and build timestamps;
  send − build is 3–15 µs (1st–99th percentile; median 5, max 360).
- **captured**: the descriptor's i32 at value offset 0 (`tx_time`) is a
  per-frame stamp, not a per-packet one: the descriptor sent before a frame's
  packets and the one sent after them carry the same value although they
  arrive a median 0.78 ms apart, and it advances a median 9,203 µs per frame.
  The i32 at value offset 4 (the host's estimate) took 1,034 distinct values,
  between 839,208,204 and 839,207,026, falling: 7,591 steps of 0, 1,029 steps of
  −1…−4, ten of +1…+4, a steady −29.7 µs/s.
- **captured**: the two estimates have opposite signs and their sum is the
  round trip: 1,399 µs at the first descriptor, 579–646 µs from 24 s to the
  end. In between it is wrong (below).
- **captured**: the client's estimate rose +32.0 µs/s over the last 12 s while
  the host's fell 29.4 µs/s: the two machines' clocks drift apart by about
  30 ppm and each estimator follows it, the sum staying put.

### The client's clock against the capture clock

- **captured**: the pose send timestamp equals the capture's CLOCK_MONOTONIC
  microseconds, mod 2³², plus 1,455,121 µs at the start of the run — so the
  client's SVL clock is not CLOCK_MONOTONIC as the tracer reads it, and the
  offset is **not constant**: the lower envelope of (capture time − send
  timestamp), taken per second, grows by 6.0 µs/s (linear fit, residuals
  within ±9 µs over 41 one-second windows), 0.24 ms over the run. Above that
  envelope the tracer's stamp trails the client's own by a median 25 µs
  (99th percentile ~190 µs, one outlier of 7.3 ms).
- **captured**: on receive the order is reversed: the client stamps a
  descriptor 110–180 µs after the tracer does (177 µs for the very first
  descriptor, where `toff` is simply `local_now − tx_time`; ~115 µs fits the
  last 15 s).

### Does the estimator reproduce `toff`?

The estimator above was fed the 8,631 captured `tx_time` values with
`local_now` = capture timestamp converted to the client clock (the fit above)
plus a constant receive delay, and its `off` compared with the `toff` in each
of the 17,021 later pose packets.

- **captured**: with the multiply done in 32 bits and a 120 µs receive delay:
  290 exact matches, 3,602 within ±5 µs, 7,768 within ±50 µs; residual
  (simulated − sent) 0 / +6 / +89 / +361 / +791 µs at the 1st / 25th / 50th /
  75th / 99th percentile. The misfit is all in the first 22 s (median +343,
  none exact); over the last 16 s (6,615 packets) the simulation is 0 to
  +13 µs from the sent value, median +5, 290 exact. Branches taken: 1 initialize, 6,618 creep up, 1,242 follow down,
  770 late, no restart and no "−4".
- **captured**: with the multiply done in unbounded integers (the page's
  earlier pseudocode) the fit is far worse — residual −110 / +105 / +1,482 /
  +6,609 µs at the 25th / 50th / 75th / 99th percentile, 7.6 ms at worst —
  because that version never produces the start-up drop.
- **captured**: the start-up drop itself is reproduced step for step. The
  host sent frame 0, paused 111 ms, then sent frames 1–14 in a 32 ms burst
  whose `tx_time`s are 6.5–15 ms apart; each arrives "less late" than the one
  before, all of them later than the first. With `conf` below 15 the
  wrapped product in the creep-up branch is negative, and the client's `toff`
  stepped −931, −533, −715, −850, −1,151, −1,522, −1,041, −985 µs between
  consecutive pose packets (−7,728 in all). The simulation follows the first
  four steps to within 8 µs and then departs by a few hundred µs (the wrapped
  product is chaotic in the exact `local_now`, which the capture only knows to
  ±50 µs); at 2.9 s it is 0.76 ms above the real value.
- **captured**: recovery is slow because the creep-up branch adds at most
  5 µs per descriptor: `toff` + host estimate was −6,314 µs just after the
  burst, −4,713 at 2.9 s, −923 at 10.9 s, +98 at 16.9 s, +579 at 24.9 s.
- An exact match on every packet is not obtainable from a capture: the
  estimator's `local_now` is the client's own clock read, which is not on the
  wire.

### Published values

- **captured**: `cPingMS` × 1000 equals `toff` + host estimate. Of 3,153
  distinct `cPingMS` updates sent after 1.5 s, 3,123 equal the sum of a pose
  `toff` and a descriptor estimate adjacent in time exactly; the rest are
  within 10 µs. `cPingMS` was negative for the first ~16 s (minimum −6.289).
- **captured**: the host publishes `sPingMS` and it equals the client's
  `cPingMS` at the same moment to 0.001 ms in every sample — the host forms
  the same sum, negative values included. The host also publishes `sTimeConf`
  (387 in its first record, 400 after), matching the estimator's confidence
  ceiling: the host runs the same estimator.
- **captured**: `cPingAMS` reached exactly 100.0 (the clamp) when the burst
  arrived 105 ms "late", then fell by exactly 1.000 ms per descriptor until it
  met the live latency: the decay step at `SVLRoot+0x198` is 1,000 µs in this
  session. It is 0 before any descriptor and −0.5 right after the first.

### What the host's estimator is fed

- **captured**: the 8-byte datagram prefix holds a sequence number, a zero
  u16 and the checksum (docs/svl-transport/) — no timestamp. vr1's "`ts`
  field" was the checksum.
- **captured**: the host publishes `tsLastWGP`, a host-clock timestamp. Mapped
  to the client clock with `toff` it lands 509–612 µs (one round trip) after
  the send timestamp of a **sub-index 0** pose packet in all 65 samples after
  25 s, so it is the host's receive time for that packet. `tsLastWGP` − that
  packet's value-offset-8 timestamp − the host's estimate is −58 µs at the
  median (−85…+35, 0th–99th percentile; 167 samples, 166 of them matched to a sub-index 0
  packet): the host's estimate sits
  within 0.1 ms of "host receive time − pose send timestamp". So the input is
  a pose-packet timestamp. Value offsets 8 and 12 are 5 µs apart, which is
  below what this can separate.
- **captured**: payload byte 13 of the descriptor (the FEC mode byte) is 0x20
  in all 8,631 and byte 2 of all 17,423 pose packets is 0x20.
  `SVLDataLink::HandleFECChange( 32 )` is logged once.

## Open questions

- Which of the pose packet's two timestamps (dataset offset 0x10 or 0x14) the
  host uses; a probe that sends them far apart would show it in the host's
  estimate.
- Why the client's SVL clock runs 6 µs/s against the tracer's CLOCK_MONOTONIC
  and sits 1.455 s from it (Klepton's guest clock source was not examined;
  on a real headset the two may be one clock).
- Whether the host's estimator has the same 32-bit overflow. Its estimate
  moved by at most 4 µs per descriptor in `vr3`, so it never met the
  condition.
- Whether the host does anything with a negative `cPingMS` / `sPingMS` during
  the first seconds (its `dPingThr` key dipped as low as 0.11 in `vr3`; not tied to
  this).
- Whether the decay step at `SVLRoot+0x198` is a constant (its writer was not
  traced; 1,000 µs observed).
