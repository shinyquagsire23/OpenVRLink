# Refresh rate / frame time negotiation

Sources: `QSVLClient::UpdateFrameVariables()` +0xf5248, the watch callback at
+0xf8034 (anonymous `std::function` body; Ghidra `FUN_001f8034`),
`QSVLClient::HandleEvent` +0xf4bec, `QSVLClient::OnTopOfFrame` +0xf6270.
All details below are **static** unless marked otherwise. The
ValueTransportSystem wire format and the full id table are in docs/svl-values/;
only the timing-relevant ids are covered here.

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

**captured (Klepton trace)**: Advertising a single 72 Hz rate led to
`VTE_REQ_FRAMETIME_US = 13888`. Klepton also records that a host given an empty
rate list never sends video. The full wire exchange from `vr3` is shown below
(**captured**).

## Local pacing period versus `VTE_REQ_FRAMETIME_US`

Independent of the negotiation, the pacing code uses the period OpenXR
reports each frame (`OnTopOfFrame`'s second argument, accepted when within
2000..20000 µs, else 11111), stored at `SVLRoot+0x178`. Thus 0x0c reports the
negotiated frame time to the host, while the client's own schedule follows the
display period reported by OpenXR.

## Capture verification (`vr3`)

Capture `vr3` records `vrlink` under Klepton with the display advertised as
120 Hz and every datagram timestamped. Times below are measured from `vrlink`'s
first datagram. Each value is a ValueTransportSystem record formatted as
`0x80|version, id, u16 chunk, u32 total` followed by the payload
(docs/svl-values/).

| t (ms) | direction, carrier | bytes | meaning |
|---|---|---|---|
| 30.3 | client → host, in a pose packet | `81 20 00 00 14 00 00 00` + `01 00 00 00  01 00 00 00  00 00 00 00 00 00 00 00  00 00 f0 42` | 0x20 version 1, 20 bytes: `u32 1`, `u32 count = 1`, 8 zero bytes, `float32 120.0` |
| 33.4 | host → client, class 3 type 0x0d | `01 20 00 00`, and `81 21 00 00 04 00 00 00  00 00 f0 42` | ack of 0x20 v1, and 0x21 version 1 = `float32 120.0`. The 0x21 record is sent twice 51 µs apart, the second time as a 12-byte element of its own |
| 34.6 | client → host, pose packet | `01 21 00 00` twice | one ack per copy received |
| 38.4 | client → host, pose packet | `81 0c 00 00 04 00 00 00  8d 20 00 00` | 0x0c version 1 = `u32 8333` |
| 41.7 | host → client, class 3 type 0x0d | `01 0c 00 00` | ack of 0x0c |
| 70.8 … 913.2 | client → host, pose packets | 0x20 **version 2**, same 20 bytes, 27 times, one every ~32 ms | a second publication of the same list, repeated because unacknowledged |
| 926.2 | host → client, first frame descriptor | `02 20 00 00` in its tail | ack of 0x20 v2; first video |

- **captured**: The layout of all three values matches the table at the top:
  the 0x20 header's first u32 is 1 and its 8 reserved bytes are zero; 0x21 is
  4 bytes (float32 Hz); 0x0c is 4 bytes (u32 µs), with `8333 =
  (uint)(1000000.5 / 120)`.
- **captured**: The host's request (0x21) arrived 3.1 ms after `vrlink` sent
  the list (0x20), the frame-time reply (0x0c) left 5.0 ms after the request,
  and the host acknowledged 0x0c 3.4 ms later. **Video started 884 ms after the
  host received 0x0c** (926 ms into the session), long after refresh-rate
  negotiation completed. What the host waits for during that gap is covered in
  docs/svl-values/startup-exchange.md; its probe-derived minimum startup set
  for a cold host includes 0x20 and omits 0x0c, confirming that the host does
  not wait for 0x0c.
- **captured**: `vrlink`'s log records
  `[SVLClient] Sending Available Frequency (0/1) = 120.000000 Hz` three times
  (at init, after `Server requested prop refresh`, and once more), followed by
  `Received display frequency request update`,
  `[XRQ] XRQRequestRefreshRate: Set refresh rate to 120.0Hz`, and
  `VTE_REQ_FRAMETIME_US was set to 8333` once each. Three local publications
  produced two wire versions because a new wire version does not start until
  the previous version is acknowledged. No further publication occurred after
  the request (version 2 is final), matching the `QSVLClient+0x3eb9 = 1` flag
  that stops the 1 Hz re-advertisement.
- **captured**: The host did not acknowledge version 2 for 855 ms because it
  sent no class-3 type-0x0d element between 41.7 ms and the first descriptor,
  and descriptor tails are its only other carrier for acknowledgments
  (**inferred** for the cause; the 855 ms gap and 27 repeats are **captured**).
- **captured**: In `vr3`, the host requested **120.0 Hz**, matching the single
  rate offered. On the same day, the initial probe runs below saw the same host
  request 90.0 Hz regardless of what was offered; a host-side setting may have
  changed between runs.
- **captured**: Video frames were delivered at 108.4 fps (4,260 frames in
  39.33 s, with the host's `tx_time` advancing a median 9,203 µs per frame) —
  below both 120 and 90 Hz, and matching `vrlink`'s actual frame-loop rate
  (108.3 pose groups/s; see [event-schedule.md](event-schedule.md)), whose
  target-time field advances by the same ~9.2 ms per frame.

## Open questions

- Check whether `vrlink` re-triggers host rate selection when a headset changes
  its available refresh rates mid-session (see the probe test below).
- Determine why the host requested 120.0 Hz in `vr3` versus 90.0 Hz in the
  initial probe runs.
- Clarify what governs the delivered frame rate: in `vr3`, 120 Hz was agreed
  while 108.4 fps was delivered (matching `vrlink`'s frame-loop rate), whereas
  in probe runs the delivered rate followed the agreed rate rather than pose
  cadence as long as pose target time stayed constant within each frame. One
  explanation consistent with both (**inferred**, untested) is that the host
  renders at most one frame per distinct pose target time up to the agreed
  refresh rate.

## Probe results (2026-11-10)

See "Refresh rate and pacing (probe)" in
[../svl-values/startup-exchange.md](../svl-values/startup-exchange.md): the
host's 0x21 request was 90.0 Hz regardless of the offered list, while the
delivered frame rate followed the offered rate (73 fps with only 72 Hz offered,
and 90.0 fps with 90 Hz offered) rather than the client's pose cadence.

## Mid-session rate changes (probe, 2026-11-10)

In a single session, the probe stepped through six rate changes at six seconds
per step, pacing its pose loop to match each new rate (**captured**):

| step | host's reply | delivered |
|---|---|---|
| start, 0x20 = [90] | 0x21 = 90.0 | 90.0 fps |
| publish 0x20 = [72] | 0x21 = 72.0 | 72.0 fps |
| publish 0x20 = [120] and 0x0c = 8333 | 0x21 = 120.0 | 119.8 fps |
| publish 0x0c = 16666 only (loop at 60) | none | 119.7 fps - unchanged |
| publish 0x20 = [45] and 0x0c | (0x21 = 45) | 45.0 fps |
| publish 0x20 = [96] and 0x0c | (0x21 = 96) | 95.6 fps |

No frame was incomplete across any rate change, and the stream continued
without restarting.

Key takeaways:

- **Re-publishing 0x20 with a single new rate changes the stream's frame rate
  mid-session.** The host replies with a matching 0x21 request and switches
  output rate. This supports displays whose refresh rate changes dynamically
  (for example, visionOS switching among 45, 60, 90, 96, and 120 Hz).
- **Publishing 0x0c alone has no effect**; 0x0c only acknowledges a 0x21
  request.
- Non-standard rates are accepted: 45, 72, 90, 96, and 120 Hz all worked.
- This also explains earlier warm-host runs where the delivered rate followed
  0x20 without an apparent 0x21 change: those runs did not log subsequent 0x21
  updates.

Transition time in frames, whether rate switches increment `encResets`, and how
the host selects from a multi-rate 0x20 list were not measured.
