# Refresh rate / frame time negotiation

Sources: `QSVLClient::UpdateFrameVariables()` +0xf5248, the watch callback at
+0xf8034 (anonymous `std::function` body; Ghidra `FUN_001f8034`),
`QSVLClient::HandleEvent` +0xf4bec, `QSVLClient::OnTopOfFrame` +0xf6270.
All **static** unless marked. The ValueTransportSystem wire format and the
full id table are in docs/svl-values/; only the timing-relevant ids are here.

| id | name (from log strings) | direction | payload |
|---|---|---|---|
| 0x20 | `VTE_AVAILABLE_FRAMETIMES_US` | client → host | 16-byte header then `float32[count]`: `u32 1`, `u32 count` (≤ 250), 8 zero bytes, then the display's supported refresh rates **in Hz** (despite the name). Total size `16 + 4·count` |
| 0x21 | (request; no name string found) | host → client | a float, read with `GetRemoteValueAsFloat`: the refresh rate in Hz the host wants |
| 0x0c | `VTE_REQ_FRAMETIME_US` | client → host | `u32` frame time in µs: `(uint)(1000000.5 / actual_hz)` |

## Sequence

1. The client marks 0x20 dirty at start and again **once per second**
   (posted event type 4) until the host has made a request. When dirty,
   `UpdateFrameVariables` asks the XR layer for the supported rates
   (vtable +0x110), logs each as
   `[SVLClient] Sending Available Frequency (%d/%d) = %f Hz`, publishes 0x20
   with the "force" flag set (`UpdateValue(..., true)`), and logs
   `[SVLClient] VTE_AVAILABLE_FRAMETIMES_US was updated`.
2. The host picks one and sets 0x21.
3. The client's watch on 0x21 fires
   (`[SVLClient] Received display frequency request update`): it rounds the
   float to the nearest integer Hz, asks the XR layer to switch
   (vtable +0x158, which returns the rate actually set), logs
   `[SVLClient] Server requested refresh rate %.1f was not available. Using %.1f`
   if they differ by more than 0.1, publishes 0x0c with the resulting frame
   time (force flag set), logs
   `[SVLClient] VTE_REQ_FRAMETIME_US was set to %i`, and stops the 1 Hz
   re-advertisement (`QSVLClient+0x3eb9 = 1`).

**captured (Klepton trace)**: one advertised rate of 72 Hz led to
`VTE_REQ_FRAMETIME_US = 13888`. Klepton also records that a host given an
empty rate list never sends video. **captured** (`vr3`): the whole exchange
on the wire, below.

## Frame time the client actually paces with

Independent of the negotiation, the pacing code uses the period OpenXR
reports each frame (`OnTopOfFrame`'s second argument, accepted when within
2000..20000 µs, else 11111), stored at `SVLRoot+0x178`. So the number in 0x0c
is a statement to the host; the client's own schedule follows the real
display.

## Confirmed against capture `vr3`

`vr3`: real client under Klepton, display advertised as 120 Hz, every
datagram timestamped. Times are from the client's first datagram. Each value
is one ValueTransportSystem record: `0x80|version, id, u16 chunk, u32 total`,
then the data (docs/svl-values/).

| t (ms) | direction, carrier | bytes | meaning |
|---|---|---|---|
| 30.3 | client → host, in a pose packet | `81 20 00 00 14 00 00 00` + `01 00 00 00  01 00 00 00  00 00 00 00 00 00 00 00  00 00 f0 42` | 0x20 version 1, 20 bytes: `u32 1`, `u32 count = 1`, 8 zero bytes, `float32 120.0` |
| 33.4 | host → client, class 3 type 0x0d | `01 20 00 00`, and `81 21 00 00 04 00 00 00  00 00 f0 42` | ack of 0x20 v1, and 0x21 version 1 = `float32 120.0`. The 0x21 record is sent twice 51 µs apart, the second time as a 12-byte element of its own |
| 34.6 | client → host, pose packet | `01 21 00 00` twice | one ack per copy received |
| 38.4 | client → host, pose packet | `81 0c 00 00 04 00 00 00  8d 20 00 00` | 0x0c version 1 = `u32 8333` |
| 41.7 | host → client, class 3 type 0x0d | `01 0c 00 00` | ack of 0x0c |
| 70.8 … 913.2 | client → host, pose packets | 0x20 **version 2**, same 20 bytes, 27 times, one every ~32 ms | a second publication of the same list, repeated because unacknowledged |
| 926.2 | host → client, first frame descriptor | `02 20 00 00` in its tail | ack of 0x20 v2; first video |

- **captured**: layout of all three values is as the table at the top says:
  the 0x20 header's first u32 is 1 and its 8 reserved bytes are zero; 0x21 is
  4 bytes (float32 Hz); 0x0c is 4 bytes (u32 µs). 8333 =
  `(uint)(1000000.5 / 120)`.
- **captured**: order and timing. The request (0x21) came 3.1 ms after the
  list (0x20) left, the frame-time reply (0x0c) 5.0 ms after the request, and
  the host acknowledged it 3.4 ms later. **Video started 884 ms after the
  host had 0x0c** (926 ms into the session), so the negotiation is finished
  long before the first frame. What the host waits for in between is in
  docs/svl-values/startup-exchange.md; its probe-derived minimum set for a
  cold host contains 0x20 but not 0x0c, so the host does not wait for the
  frame-time reply.
- **captured**: the client log has
  `[SVLClient] Sending Available Frequency (0/1) = 120.000000 Hz` three times
  (init, after `Server requested prop refresh`, and once more), then
  `Received display frequency request update`,
  `[XRQ] XRQRequestRefreshRate: Set refresh rate to 120.0Hz` and
  `VTE_REQ_FRAMETIME_US was set to 8333` once each. Three publications became
  two wire versions because a new version is not started until the previous
  one is acknowledged. After the request there was no further publication
  (version 2 is the last), consistent with the "stop re-advertising" flag.
- **captured**: the host could not acknowledge version 2 for 855 ms: it sent
  no class-3 type-0x0d element between 41.7 ms and the first descriptor, and
  descriptor tails are its only other carrier for acks (**inferred** for the
  cause; the gap and the 27 repeats are measured).
- **captured**: this host asked for **120.0 Hz**, the one rate offered. The
  probe section below saw the same host ask for 90.0 Hz whatever was offered,
  on the same day; the two are not reconciled (a host-side setting may have
  changed between the runs).
- **captured**: frames were then delivered at 108.4 per second (4,260 in
  39.33 s; the host's own `tx_time` advances a median 9,203 µs per frame) —
  below both 120 and 90, and equal to the rate of the client's frame loop
  (108.3 pose groups per second, see [event-schedule.md](event-schedule.md)),
  whose target-time field advances by the same ~9.2 ms per frame.

## Open questions

- Whether the host re-requests when the client re-advertises a different
  list (e.g. after the headset changes mode).
- Why the request was 120.0 Hz in `vr3` and 90.0 Hz in the probe runs.
- What sets the delivered frame rate. `vr3`: 120 Hz agreed, 108.4 delivered,
  equal to the client's frame-loop rate. Probe: delivered rate followed the
  agreed rate and not the pose cadence, provided the pose target time was
  constant within a frame. One reading that fits both — the host renders
  one frame per distinct pose target time up to the agreed rate — is
  **inferred** and untested.

## Probe results (2026-11-10)

See "Refresh rate and pacing (probe)" in
[../svl-values/startup-exchange.md](../svl-values/startup-exchange.md): the
host's 0x21 request was 90.0 Hz regardless of the offered list; delivered
frame rate followed the offered rate (73 per second with only 72 Hz offered,
90.0 with 90), and did not follow the client's pose cadence.

## Changing the rate mid-session (probe, 2026-11-10)

One session, six seconds per step, the probe's pose loop following each new
rate. **Captured by probe**:

| step | host's reply | delivered |
|---|---|---|
| start, 0x20 = [90] | 0x21 = 90.0 | 90.0 fps |
| publish 0x20 = [72] | 0x21 = 72.0 | 72.0 fps |
| publish 0x20 = [120] and 0x0c = 8333 | 0x21 = 120.0 | 119.8 fps |
| publish 0x0c = 16666 only (loop at 60) | none | 119.7 fps - unchanged |
| publish 0x20 = [45] and 0x0c | (0x21 = 45) | 45.0 fps |
| publish 0x20 = [96] and 0x0c | (0x21 = 96) | 95.6 fps |

No frame was incomplete across any change, and the stream did not restart.

So:

- **A client changes the stream's rate by re-publishing 0x20 with the one rate
  it now wants.** The host answers with a 0x21 request for that rate and
  switches. This is the mechanism for a display whose refresh rate moves under
  the client (visionOS between 45, 60, 90, 96 and 120 Hz).
- **0x0c alone changes nothing.** It is only the acknowledgement of a 0x21.
- Arbitrary rates are accepted: 45, 72, 90, 96 and 120 all worked.
- This also explains the earlier warm-host observation that the delivered rate
  followed the offered list while 0x21 did not appear to: those sessions did
  not log the later 0x21.

Not measured: how many frames the switch takes, whether the encoder is reset
(`encResets`), and what the host does with a list of several rates.
