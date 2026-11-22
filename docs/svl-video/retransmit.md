# Retransmission, frame reports, ordering, and reset

This page covers client-to-host messages on the video reply channel (`kind =
4`), along with `vrlink`'s rules for requesting missing packets, accepting and
ordering frames, and resetting the stream on unrecoverable errors.

## Retransmit request - kind 4, type 5 (`resend_fec_request`)

`vrlink` builds retransmit requests in `SVLFECRXFrame::CheckRetry` (+0x15f2cc)
and `SVLFEC::RerequestBookend` (+0x160328), while the shared TX code parses
them in `SVLFECTXFrame::HandleRetransmitRequest` (+0x15f9d0, **static**).

| Off | Type | Name | Notes |
|---|---|---|---|
| 0 | u8 | 4 | |
| 1 | u8 | 5 | |
| 2 | u16 | `frame_id` | |
| 4 | u16 | `len` | `2 * n` |
| 6 | u16 | 0 | |
| 8 | u16[n] | `packet_id` list | |

Each entry takes one of three ranges:

| Value | Meaning |
|---|---|
| 0xffff | "resend the frame descriptor" (when `vrlink` has no descriptor for this frame). Always placed first in the list when present |
| 0x000..0x7ff | data packet |
| 0x800..0xfff | parity packet |

`vrlink` sends the message via `SVLDataLink` virtual `+0x58` `(dataset, false,
true)`—the unreliable path with the third flag set (**inferred**: immediate /
high-priority flush; see `docs/svl-transport/`). Each request increments the
`rexmitReq` `SVLRoot` value by the number of entries and records timing event
`0x42` with that count.

In the shared TX code (**static**, **inferred** for the host),
`HandleRetransmitRequest` resends each requested packet unless it was sent or
resent within the last 3,000 us. An entry of `0xffff` resends the descriptor,
ids outside the range sent for that frame are ignored, and a request for a
`frame_id` no longer present in the sender's 16 TX slots logs `"Warning:
retransmit request for unknown message %d (frame number=%d"` and is dropped.
The sender counts resent packets in the `rexmitSent` `SVLRoot` value.

### Retransmit triggers

`vrlink` invokes `CheckRetry` from three paths (**static**):

**1. Guided retry (`CheckRetry(group)`):** Runs whenever a packet or descriptor
arrives with a group number higher than any previously seen for that frame,
requesting everything missing from earlier groups:

```python
def check_retry_guided(frame, group):
    n_data = (frame.size + 1023) // 1024
    n_par  = ((n_data + 7) // 8) * 2
    want = [] if frame.has_descriptor else [0xffff]
    for n in range(frame.first_missing_data, min(64 * group, n_data)):
        if not frame.have(n): want.append(n)
    for n in range(max(frame.first_missing_parity, 0x800), min(0x800 + 16 * group, 0x800 + n_par)):
        if not frame.have(n): want.append(n)
    if len(want) > 512: abort_stream()   # "too many packets were missing even to retransmit"
    if want: send_request(frame.id, want)
```

When all eight data packets of a stripe have arrived, the FEC hook marks that
stripe's parity packets received as well, so parity is requested only on
stripes with missing data. On incomplete stripes, `vrlink` requests the Q
packet id too, even when the host never sent Q.

**2. Unguided retry (`CheckRetry(-1)`):** Called from `SVLFEC::Tick` (+0x160a18)
for every active slot as a timer-driven sweep for tail loss (packets lost after
the final packet that arrived):

```python
def check_retry_unguided(frame, now):
    if now - frame.last_request_or_packet_time < 4000: return     # us
    frame.last_request_or_packet_time = now
    t = now - frame.last_packet_time - 4000
    budget = t // 104                    # packets the sender should have got out by now
    want = [] if frame.has_descriptor else [0xffff]
    scan up to `budget` data ids from frame.first_missing_data (bounded by n_data)
    scan up to `budget - 20` parity ids from max(first_missing_parity, 0x800) (bounded by n_par)
    want = want[:20]                     # at most 20 entries per unguided request
    if want: send_request(frame.id, want)
```

`Tick` skips this sweep altogether when the *remote* `ValueTransportSystem`
value **id `0x1a` (26)**, read as a 4-byte `int`, is present and equal to `0`
(`GetRemoteValue(0x1a, &v, 4)`, defaulting to `1` when absent), allowing the
host to disable unguided retries. See `docs/svl-values/` for VTE id names.

**3. Skipped-frame retry (`SVLFEC::RerequestSkippedFrame`, +0x160444):** Runs on
every arriving video packet for frame `F` once at least one frame has been
submitted. For each `frame_id` in `[max(last_submitted + 1, F - 2), F)`, if the
corresponding slot does not hold that frame, `vrlink` initializes the slot with
an unknown size (logging `"SVLFEC: frame %d was entirely dropped, initializing
and re-requesting"`) and runs `CheckRetry(g)` once per frame with `g = 1` when
the size is unknown or `ceil(n_data / 64)` when known—requesting all missing
packets. Requests exceeding 4 entries log `"SVLFEC: substantive retry (%d
packets) due to frame skip ..."`.

`SVLFEC::RerequestBookend(frame_id)` sends a single-entry `[0xffff]` request.

## Frame report - kind 4, type 0x0f (`LastVideoPacket_t`)

`SVLDataLink::SendLastRXID` (+0x15c648) builds `LastVideoPacket_t` and is
called from `QSVLClient::SendPoses` (+0xf4d34, **static**), sending one frame
report alongside every pose packet.

| Off | Type | Name | Source |
|---|---|---|---|
| 0 | u8 | 4 | |
| 1 | u8 | 0x0f | |
| 2 | u16 | `decoded.frame_id` | `FrameHasBeenDecoded` queue |
| 4 | u16 | `len` = 0x18 | |
| 6 | u16 | `accepted.frame_id` | `FrameHasBeenAccepted` queue |
| 8 | u32 | `decoded.time` | |
| 0x0c | u32 | `accepted.time` | |
| 0x10 | u16 | `display.frame_id` | `FrameHasBeenSubmittedForDisplay` queue A |
| 0x12 | u16 | 0 | |
| 0x14 | u32 | `display.predicted_time` | |
| 0x18 | u16 | `display.frame_id` (again) | queue B |
| 0x1a | u16 | 0 | |
| 0x1c | u32 | `display.flip_time` | |

All timestamps use `vrlink`'s `GetCurrentTimestamp()` clock (32-bit
microseconds).

| Event | Pushed by | Time recorded |
|---|---|---|
| accepted | `SVLFEC::InternalAcceptFrameFromRX` (+0x160050) | all packets present / FEC complete |
| decoded | `QSVLCodecNDK::HandleOnImageAvailable` (+0xfde30) | decoder output image available |
| display (predicted) | `QSVLRendererXR::FlipFrame` (+0x10ae78), only when descriptor `version > 5` | `now + (predictedDisplayTime - xr_now)` |
| display (flip) | same | time `FlipFrame` was entered |

Each of the four queues follows the same draining rule (**static**): if two or
more entries are queued, pop one entry, then read and report the front entry
without removing it. Consequently, each report carries the oldest unreported
event, the latest event repeats across consecutive reports until a newer event
is pushed, and a queue that has never had an entry reports `id = 0, time = 0`.
Any queue growing past 1,000 entries is cleared.

The `decoded` and `display` queues translate `present_number` back to
`frame_id` through a 128-entry table (`present_number & 0x7f -> frame_id`)
populated when each descriptor arrives.

On the transmit side, `SVLFEC::ProcessVideoReply` (+0x160938) stores field `+2`
as `m_iLastAcknowledgeFrameNumber` and calls `HandleVideoAcceptedPacket`,
meaning the host treats the **decoded** frame id as the acknowledged frame
(**inferred** for the host from the shared TX code; the host receives one
report per pose packet carrying accepted, decoded, and displayed ids and
timestamps).

## Ordering and the backtrack window

`SVLFEC::InternalAcceptFrameFromRX(size, &buffer, frame_id)` enforces in-order
submission to the decoder (**static**):

- Each completed frame is placed in a 128-slot ring (`frame_id & 0x7f`) storing
  its buffer pointer and byte size, and `FrameHasBeenAccepted` is recorded.
- Frames are handed to the decoder **strictly in `frame_id` order**. Letting
  `last` be the most recently submitted `frame_id` (if any) and `d = (frame_id
  - last) & 0xffff` (`0` if none has been submitted yet), if `d >= 6`, `vrlink`
  logs `"Received frame outside of backtrack window. Resetting."` and sets the
  unrecoverable-error flag. Otherwise, it walks the ring starting at `last + 1`
  and submits every consecutive completed frame
  (`codec->SubmitFrameForDecode(&buffer, size, frame_id, true)`), stopping at
  the first incomplete slot.
- Up to 5 newer frames can therefore wait in the ring while an earlier gap is
  repaired via trigger 3 above.
- A duplicate completion for the same `frame_id` logs `"[SVLFEC] Saw a
  re-accept in InternalAcceptFrameFromRX."`. A frame completed before its
  descriptor arrives logs `"[SVLFEC] accepting a frame for submission without
  metadata [ %d ]"` and is dropped after decode when metadata lookup fails.

## Unrecoverable errors and reset

`SVLFEC+0xc50` is an unrecoverable-error flag (**static**), set by any of the
following conditions:

| Cause | Log string |
|---|---|
| no decoder input buffer / size > 0x400000 at `Initialize` | `"... WARNING: Could not initialize frame on hardware."` |
| more than 512 packets missing in a guided request | `"ERROR: While trying to request retransmission of packet #%d, too many packets were missing even to retransmit.  Aborting stream."` |
| frame >= 6 ahead of the last submitted | `"Received frame outside of backtrack window.  Resetting."` |
| out-of-order submit | `"Trying to submit frames out-of-order.  Only possible on catastrophic network failure"` |
| `AMediaCodec_queueInputBuffer` failed, input larger than the buffer, codec inactive | `"[SVLDecoder] Unrecoverable error was sent"` |
| decoder stuck: oldest queued frame has produced no output for 300 ms (`QSVLCodecNDK::BIsStuck` +0xfdda8) | same |

`SVLFEC::PeriodicCheckForErrors` (+0x160540) acts on this flag when the next
video packet arrives: it logs `"Fault, SVLFEC Received
ExperiencedAnUnrecoverableError()"`, calls
`SVLRoot::HandleUnrecoverableError(-1)`, clears the last submitted id, flushes
the decoder, clears the 128-slot completed ring, and invalidates all 16 receive
slots.

`QSVLClient::HandleUnrecoverableError` (+0xf4bdc) increments a 16-bit counter
at `QSVLClient+0xe04`, and `QSVLClient::SendPoses` writes that counter as a
**`u16` into every outgoing pose packet** (`ldr w8,[x19,#0xe04]; strh
w8,[sp,#0x130]` at +0xf4e2c). **inferred**: incrementing this `rst` counter
signals the host to reset its encoder and send an IDR keyframe. See
`docs/svl-tracking-input/` for the pose packet layout.

## SVLRoot keys and VTE ids touched by this layer

| Name | Kind | Direction | Use |
|---|---|---|---|
| `rexmitReq` | SVLRoot double | client sets | cumulative count of packet ids requested |
| `rexmitSent` | SVLRoot double | sender sets | cumulative count of packets resent |
| `cRXpass` | SVLRoot double | client sets, sender reads | below 99.99 enables Q parity for 10 s (TX code) |
| `sBWFECLim` | SVLRoot double | sender reads (default 720) | pacing between groups on the TX side |
| `txTimeMS` | SVLRoot double | sender sets | time spent sending one frame, ms |
| VTE id 0x1a | remote value, int32 | host -> client | 0 disables unguided retransmit sweeps |

## Captured

In `vr3` (not in the repo), `vrlink` streamed 39.33 s of video (4,260 frames)
over a clean LAN with client receive timestamps on every datagram. Everything
in this section is **captured** unless marked otherwise. Observations seen only
in the earlier, lossy `vr1` capture appear at the end of this section.

### Retransmit requests

- `vr3` contains **zero retransmit requests**: the only kind-4 messages sent by
  `vrlink` are 17,423 frame reports (type `0x0f`), with no `04 05` messages.
  `vrlink` never published `rexmitReq` in its `SVLRoot` values, and its log
  contains none of the retry, re-accept, late-metadata, FEC-fail, or fault
  messages listed above.
- No retransmission was needed because every data packet of every frame arrived
  intact. The single lost datagram in the run was frame 8's closing bookend
  (see [packets.md](packets.md)); because frame 8 was already complete, neither
  the guided nor the unguided retry trigger fired, and the host did not resend
  the bookend unprompted.
- Host retransmission behavior—what the host sends in reply, response latency,
  the 3,000 us cooldown, whether it answers requests for unsent Q packets, and
  `0xffff` descriptor resends—is therefore **not observable in `vr3`** (see the
  OpenVRLink loss-injection results below). Across 60,945 video elements in
  `vr3`, the host sent zero duplicate data, parity, or bookend messages.

### IDR frames and resets

- `vr3` contains **two IDR frames—frame 0 and frame 4**—each carrying `VPS,
  SPS, PPS` plus four IDR slices (NAL types `32`, `33`, `34`, and `19` x4;
  2,512 and 2,378 bytes). All other 4,258 frames contain four non-IDR P slices
  (type `1`). There is **no periodic IDR**: after frame 4, the stream runs for
  4,255 consecutive frames (39.3 s) on P frames alone.
- Before frame 0 arrives (0.72 s prior to the first video datagram), the host
  sends one debug message (kind 8, type 6) with text `[SVLS] ResetVideoStream`—
  the only such message in the capture.
- Frame 4 leaves the host 34.8 ms after frame 0 by `tx_time` without any reset
  request from `vrlink`: the pose packet `rst` counter stays **`0` across all
  17,423 pose packets**, with no second `ResetVideoStream` message and no
  retransmit request. Up to that point, `vrlink`'s frame reports carried
  `accepted = 0` (starting 3.8 ms after frame 0 arrived) and `decoded = 0` with
  timestamp `0` (`vrlink`'s first non-zero decoded report, for frame 1, went
  out 116 ms after frame 0 arrived). `vr1` showed the same pattern (IDRs at
  frames 0 and 5), so an early second IDR during startup is normal host
  behavior with `vrlink` and is not triggered by `rst` (**inferred**
  possibilities: the host resends an IDR until a decoded frame is acknowledged,
  or restarts its encoder during startup once client settings settle; the
  host's `encResets` value already read `3` on its first sample).
- By comparison, the 20 s stream captured by this repo's Python probe
  (`probe1`, 2,217 access units) has parameter sets and an IDR only at access
  unit 0, with no second IDR.
- **The `rst` -> IDR path was not exercised in `vr3`** because `vrlink` never
  encountered an unrecoverable error and `rst` stayed at `0` (verified with
  OpenVRLink below).

### Frame reports (kind 4, type 0x0f)

`vr3` contains 17,423 frame reports matching the 24-byte payload layout above,
bundled one-to-one with every pose packet (all 17,423 share their datagram with
a pose message) at 433 reports/s (median spacing `2.13 ms`, or roughly four
reports per video frame). Both padding fields (`+0x12` and `+0x1a`) are `0` in
every report. Timing details are analyzed further in
`docs/svl-timing/frame-reports.md`; the points relevant to video tracking
follow below.

To compare `vrlink` timestamps against packet arrival times, `vrlink`'s clock
was aligned to the capture clock via the pose packet's transmit timestamp in
the same datagram (accurate to ~`0.2 ms`).

| Slot | Ids reported | Timestamp relative to arrival of the frame's last data packet |
|---|---|---|
| accepted | **every frame, 0..4259**, each once and in order | -0.17 .. +0.11 ms (median -0.03, max 1.3): the accept time *is* the arrival of the last data packet |
| decoded | frames 1..4258, each once, in order (frame 0 never appears with a time; 4259 arrived as the capture ended) | +2.0 .. +8.8 ms (1 % 2.2, median 3.0, 99 % 4.0) |
| display, flip time | 3,705 distinct frames, first 3, last 4257, in order | +4.2 .. +44.6 ms (median 18.1, 90 % 36.3) |
| display, predicted time | the same id as the flip slot in all 17,423 reports | flip time + 8.29 .. 8.33 ms (one 120 Hz period) |

- **Frame acceptance does not wait for parity or the closing bookend.** The
  `accepted` timestamp precedes the arrival of the frame's final element by
  `0.2..7 ms` (median `0.42 ms`) and coincides with the arrival of the final
  *data* packet, matching `CheckRXComplete`: a frame is accepted as soon as its
  data prefix is complete.
- Decode latency (`decoded.time - accepted.time`) across 4,258 frames is
  `2.1 ms` min, `3.0 ms` median, `4.0 ms` 99th percentile, and `8.8 ms` max
  (measured with `vrlink` running under Klepton on a Mac rather than a
  headset).
- For displayed frames, 3,705 of the 4,260 frames reached `FlipFrame` (94
  frames/s displayed versus 108 frames/s received). Steps between consecutive
  displayed ids are `1` x3289, `2` x320, `3` x69, `4` x18, and `5..7` x8:
  display-time selection skips frames when needed and never presents frames out
  of order. Flip time minus decode time has a median of `15.2 ms` and a 99th
  percentile of `38.2 ms`.
- Relative to wire arrival, the first report carrying a frame's `accepted`
  entry goes out `0.1 ms` or more after its final data packet arrives (median
  `1.3 ms`, 99% `3.5 ms`), and the first report carrying its `decoded` entry
  goes out `2.3 ms` or more after arrival (median `4.3 ms`, 99% `7.2 ms`). The
  worst case for both is `63 ms`, caused by a single `69 ms` pause in
  `vrlink`'s outgoing pose packets 0.17 s into the stream. At the moment each
  report is sent, its `accepted` id matches the newest completely arrived frame
  in 16,539 of 16,945 reports (and is one frame behind in 403); its `decoded`
  id is the newest in 10,774 reports (and one behind in 6,165); and its
  `displayed` id typically trails by `1..4` frames (mode `2`).
- The queue draining rule holds throughout: ids in every slot never move
  backward, and the `accepted` and `decoded` slots advance one id at a time, so
  at four reports per frame each `(id, time)` pair typically repeats across
  `3..5` consecutive reports (`4` times in 2,592 of 4,260 frames for
  `accepted`).
- Before frame 0 arrives, all four slots report zero (402 all-zero reports, the
  last sent `0.6 ms` before the first video datagram). At startup, the slots
  populate in order: `accepted` (frame 0, `3.8 ms` after arrival), `decoded`
  (frame 1, `116 ms`), and `display` (frame 3, `126 ms`), reflecting the
  `111 ms` MediaCodec startup stall described in [packets.md](packets.md).
- Because the host received a report every `2.3 ms` with zero packet loss,
  `vr3` alone does not show which report fields drive host error recovery.

### Lossy-link observations from `vr1`

- Nine `04 05` retransmit requests appeared on the wire with `index` (`+6`)
  always `0` and a payload of `u16` packet ids—for example, frame 7 carried
  `05 00 06 00 07 00` (ids `5, 6, 7`), and frame 21 requested ids `0..0xa` and
  `0x800..0x803`. Data ids came first in ascending order followed by parity
  ids, matching `CheckRetry`'s guided scan. None of the nine requests included
  `0xffff`.
- `vrlink` logged `"Fault, SVLFEC Received ExperiencedAnUnrecoverableError()"`
  14 times during that run, the pose `rst` counter climbed from `0` to `18`,
  and the decoder stream contained 5 IDR access units (frames 0, 5, and three
  later frames). Resets were followed by IDRs, though fewer IDRs arrived than
  resets, and datagram truncation prevented pairing individual resets with
  IDRs.

## Open questions / to confirm on the wire

1. Capturing a `0xffff` descriptor retransmit request from `vrlink` when a
   frame's initial bookend is lost (verified with OpenVRLink below).
2. Determining which fields of `LastVideoPacket_t` the host acts on and how it
   uses the reported timestamps.
3. Tracing a single `vrlink` reset to its `rst` increment and resulting host
   IDR, and counting IDRs per reset (`vr3` had no resets; `vr1` had 14 fault
   lines and `rst` up to 18 across 5 IDRs).
4. Understanding why the host sends a second IDR a few frames after frame 0
   (frame 4 in `vr3`, frame 5 in `vr1`) when `vrlink` connects, whereas the
   Python probe received only frame 0's IDR.
5. Measuring what the host sends in reply to a retransmit request and how
   quickly (including the 3,000 us resend cooldown), and checking whether it
   answers requests for Q parity packets it never originally sent.
6. Checking the value and name of VTE id `0x1a` in a live session.
7. Determining the exact transport behavior of the third argument (`true`) of
   the `SVLDataLink` send call used for descriptors and retransmit requests.

## Client results: loss recovery against a SteamVR host

OpenVRLink (`VRLinkCore/Video.swift`) randomly dropped a configurable fraction
of incoming kind-5 messages (data, parity, and descriptors alike) over an
otherwise clean LAN at 90 Hz (**captured**, ~12 s per row):

| simulated loss | frames per second | packets repaired by FEC | packets re-requested | frames abandoned |
|---|---|---|---|---|
| 0 % | 90 | 0 | 0 | 0 |
| 2 % | 90 | 214 | 56 | 0 |
| 10 % | 90 | 759 | 1,188 | 0 |
| 30 % | 90 | 804 | 7,920 | 0 |

These runs confirm three behaviors:

- **The host answers retransmit requests** (kind 4, type 5) for both data
  packets and frame descriptors (`0xffff`), fast enough that zero frames missed
  their decode turn even at 30% packet loss (previously static-only).
- **Live FEC repairs** against host parity succeed, including on short final
  stripes when out-of-range data blocks are treated as known zeros.
- **Incrementing the pose `rst` counter triggers a fresh keyframe.** An earlier
  build of OpenVRLink's frame assembler abandoned frames and incremented the
  pose packet's `rst` counter; each increment was answered by `[SVLS]
  ResetVideoStream` from the host followed by a new IDR keyframe, confirming
  the `rst` -> keyframe mechanism.

OpenVRLink uses a simpler retransmit policy than `vrlink`: when a packet from a
later group arrives, request every missing data packet from earlier groups;
when an incomplete frame has been idle for 4 ms, request up to 20 missing data
packets (or `0xffff` if the descriptor is missing); and never request parity
packets. Completed frames go to the decoder strictly in `frame_id` order; any
frame that blocks later frames for 100 ms or falls outside the host's 16-frame
window is abandoned, incrementing `rst` to request a keyframe.

These runs did not measure single-packet retransmit round-trip latency, the
picture-quality impact of retransmit bitrate overhead, or recovery under burst
loss (simulated drops were independent per message).

## Client results: pacing of unprompted requests

Initially, whenever an incomplete frame had been quiet for 4 ms, OpenVRLink
requested its first 20 missing packets and reset the 4 ms timer. When many
frames were incomplete at once during a stall, that unthrottled rule sent
thousands of requests per second (570,000 requested packet ids in 15 s of a
stalled session). OpenVRLink now implements `vrlink`'s unguided budget rule
above: it requests only as many missing packets as the host should have
transmitted so far—counted at 104 us per packet from the end of the 4 ms quiet
window, capped at 20 packets per request—and while waiting for a recovery
keyframe it sends retries only for the three newest frames.

With that pacing and an optimized build, OpenVRLink recovers from 10% and 25%
simulated packet loss on a 120 Hz stream of `100..150 kB` frames at full frame
rate with zero abandoned frames (roughly 1,000 packets repaired by FEC and
1,700 re-requested over 15 s at 10% loss).
