# Retransmission, frame reports, ordering and reset

Client -> host messages on the video reply channel (`kind = 4`), and the
client-side rules that decide when a frame is requested again, accepted,
submitted or abandoned.

## Retransmit request - kind 4, type 5 (`resend_fec_request`)

**static** - built in `SVLFECRXFrame::CheckRetry` (+0x15f2cc) and
`SVLFEC::RerequestBookend` (+0x160328); parsed by
`SVLFECTXFrame::HandleRetransmitRequest` (+0x15f9d0).

| Off | Type | Name | Notes |
|---|---|---|---|
| 0 | u8 | 4 | |
| 1 | u8 | 5 | |
| 2 | u16 | `frame_id` | |
| 4 | u16 | `len` | `2 * n` |
| 6 | u16 | 0 | |
| 8 | u16[n] | `packet_id` list | |

Each entry is one of:

| Value | Meaning |
|---|---|
| 0xffff | "resend the frame descriptor" (the client has no descriptor for this frame). Always first in the list when present |
| 0x000..0x7ff | data packet |
| 0x800..0xfff | parity packet |

It is sent with `SVLDataLink` virtual `+0x58` `(dataset, false, true)` - the
unreliable path with the last flag set (**inferred**: "send now / high
priority"; the transport doc owns that flag). Each request also bumps the
SVLRoot value `rexmitReq` by the number of entries and reports timing event
0x42 with the count.

Sender behavior (**inferred** for the host, static in the shared TX code): for
each entry, resend that packet unless it was (re)sent less than 3000 us ago;
0xffff resends the descriptor; ids outside what was sent are ignored; a request
for a frame that is no longer in one of the sender's 16 TX slots logs
`"Warning: retransmit request for unknown message %d (frame number=%d"` and is
dropped. The sender counts resends in the SVLRoot value `rexmitSent`.

### When the client asks

Three triggers, all ending in `CheckRetry` (**static**):

**1. Guided - `CheckRetry(group)`**, when a packet or a descriptor arrives whose
group number is higher than any seen for that frame. Everything that should
already have arrived is requested:

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

Parity of a stripe whose eight data packets all arrived is marked received by
the FEC hook, so only stripes with a hole have parity requested. Note that the
Q packet of such a stripe is requested even if the host never sent it.

**2. Unguided - `CheckRetry(-1)`**, from `SVLFEC::Tick` (+0x160a18) for every
active slot, a time-based sweep for tail loss (the packets after the last one
that arrived):

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

`Tick` skips the sweep entirely when the *remote* ValueTransportSystem value
**id 0x1a (26)**, read as a 4-byte int, is present and equal to 0
(`GetRemoteValue(0x1a, &v, 4)`; default when absent is 1). So the host can
switch unguided retries off. Name of that id: see docs/svl-values/.

**3. Skipped frame - `SVLFEC::RerequestSkippedFrame`** (+0x160444). On every
video packet for frame `F`, for each frame id in
`[max(last_submitted + 1, F - 2), F)` (only once a frame has been submitted):
if the slot does not hold that frame it is initialized with an unknown size
(`"SVLFEC: frame %d was entirely dropped, initializing and re-requesting"`),
then `CheckRetry(g)` runs once per frame with `g = 1` if the size is unknown or
`ceil(n_data / 64)` otherwise - i.e. "request everything". More than 4 entries
logs `"SVLFEC: substantive retry (%d packets) due to frame skip ..."`.

`SVLFEC::RerequestBookend(frame_id)` sends a one-entry request `[0xffff]`.

## Frame report - kind 4, type 0x0f (`LastVideoPacket_t`)

**static** - `SVLDataLink::SendLastRXID` (+0x15c648), called from
`QSVLClient::SendPoses` (+0xf4d34), so it goes out once per pose packet.

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

All times are the client's `GetCurrentTimestamp()` clock (us, 32-bit).

| Event | Pushed by | Time recorded |
|---|---|---|
| accepted | `SVLFEC::InternalAcceptFrameFromRX` (+0x160050) | all packets present / FEC complete |
| decoded | `QSVLCodecNDK::HandleOnImageAvailable` (+0xfde30) | decoder output image available |
| display (predicted) | `QSVLRendererXR::FlipFrame` (+0x10ae78), only when descriptor `version > 5` | `now + (predictedDisplayTime - xr_now)` |
| display (flip) | same | time `FlipFrame` was entered |

Queue rule (per queue, **static**): if two or more entries are queued, pop one;
then report the front entry without removing it. So each report carries the
oldest unreported event, the latest event is repeated until a newer one
arrives, and a queue that has never had an entry reports id 0, time 0. A queue
that grows past 1000 entries is cleared.

The decoded/display queues are keyed by frame id via a 128-entry table
`present_number & 0x7f -> frame_id` filled when the descriptor arrives.

On the sending side `SVLFEC::ProcessVideoReply` (+0x160938) stores field +2 as
`m_iLastAcknowledgeFrameNumber` and calls `HandleVideoAcceptedPacket` - so the
**decoded** frame id is what the host treats as the acknowledged frame
(**inferred** for the host; per frame the host expects one of these per pose packet, carrying
accepted/decoded/displayed ids and times).

## Ordering and the backtrack window

**static** - `SVLFEC::InternalAcceptFrameFromRX(size, &buffer, frame_id)`:

- A completed frame goes into a 128-slot ring (`frame_id & 0x7f`) holding the
  buffer pointer and size. `FrameHasBeenAccepted` is recorded.
- Frames are handed to the decoder **strictly in frame-id order**. With `last`
  = last submitted id (or none): let `d = (frame_id - last) & 0xffff` (0 if
  none yet). If `d >= 6`: `"Received frame outside of backtrack window.
  Resetting."` and the unrecoverable flag is set. Otherwise the ring is walked
  from `last + 1` and every consecutive completed frame is submitted
  (`codec->SubmitFrameForDecode(&buffer, size, frame_id, true)`); the walk
  stops at the first frame that is not yet complete.
- So up to 5 later frames can wait for a hole to be repaired; the hole is
  being re-requested by trigger 3 above in the meantime.
- A second completion of the same id logs `"[SVLFEC] Saw a re-accept in
  InternalAcceptFrameFromRX."`. A frame completed without its descriptor logs
  `"[SVLFEC] accepting a frame for submission without metadata [ %d ]"` and is
  then dropped after decode for lack of metadata.

## Unrecoverable errors and reset

**static**. `SVLFEC+0xc50` is a "something broke" flag, set by:

| Cause | Log string |
|---|---|
| no decoder input buffer / size > 0x400000 at `Initialize` | `"... WARNING: Could not initialize frame on hardware."` |
| more than 512 packets missing in a guided request | `"ERROR: While trying to request retransmission of packet #%d, too many packets were missing even to retransmit.  Aborting stream."` |
| frame >= 6 ahead of the last submitted | `"Received frame outside of backtrack window.  Resetting."` |
| out-of-order submit | `"Trying to submit frames out-of-order.  Only possible on catastrophic network failure"` |
| `AMediaCodec_queueInputBuffer` failed, input larger than the buffer, codec inactive | `"[SVLDecoder] Unrecoverable error was sent"` |
| decoder stuck: oldest queued frame has produced no output for 300 ms (`QSVLCodecNDK::BIsStuck` +0xfdda8) | same |

It is acted on at the next video packet (`SVLFEC::PeriodicCheckForErrors`
+0x160540): log `"Fault, SVLFEC Received ExperiencedAnUnrecoverableError()"`,
call `SVLRoot::HandleUnrecoverableError(-1)`, forget the last submitted id,
flush the decoder, clear the completed ring and invalidate all 16 slots.

`QSVLClient::HandleUnrecoverableError` (+0xf4bdc) only increments a counter at
`QSVLClient+0xe04`. `QSVLClient::SendPoses` copies that counter as a **u16 into
every pose packet** (`ldr w8,[x19,#0xe04]; strh w8,[sp,#0x130]` at +0xf4e2c).
**inferred**: a change in that counter is how the host learns it must restart
the stream with a keyframe. The field's offset inside the pose packet is in
docs/svl-tracking-input/.

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

Capture `vr3` (not in the repo): the real client on a clean LAN, 39.33 s of
video, 4,260 frames, every datagram timestamped on the client. Everything in
this section is **captured** unless marked. The earlier capture `vr1` was a
lossy, torn run; what only it showed is kept at the end.

### Retransmit requests: none

- `vr3` contains **no retransmit request**. The only kind-4 elements the
  client sent are 17,423 frame reports (type 0x0f); there is no `04 05`.
  The client never set `rexmitReq` in its SVLRoot values either, and its
  log has none of the retry, re-accept, late-metadata, FEC-fail or fault
  strings quoted on this page.
- Nothing needed one: no data packet of any frame was missing. The single
  datagram lost in the run was the closing bookend of frame 8 (see
  [packets.md](packets.md)); the frame was already complete, so neither the
  guided nor the unguided trigger fires, and the host did not resend it on
  its own.
- Consequently the host's side of retransmission - what it sends in reply,
  how fast, the 3000 us resend floor, whether it answers for Q it never sent,
  the 0xffff case - is **not observable in `vr3`** and stays open. The host
  sent no packet twice: no duplicate data, parity or bookend in 60,945 video
  elements.

### IDR frames and resets

- The stream has **two IDR frames: frame 0 and frame 4**, each
  `VPS, SPS, PPS` plus four IDR slices (NAL types 32, 33, 34, 19 x4; 2,512
  and 2,378 bytes). The other 4,258 frames are four non-IDR slices (type 1)
  each. There is **no periodic IDR**: after frame 4 the stream runs 4,255
  frames (39.3 s) on P frames alone.
- What precedes them: 0.72 s before the first video datagram the host sends
  one debug message (kind 8, type 6) with the text `[SVLS] ResetVideoStream`;
  it is the only one in the capture. Frame 0 is the first frame after it.
- Frame 4 follows 34.8 ms after frame 0 by the host's `tx_time`, with
  nothing from the client that asks for it: the pose packet's `rst` counter
  is **0 in all 17,423 pose packets**, there is no second `ResetVideoStream`
  message, and no request of any kind. The client's frame reports up to
  then said "accepted frame 0" from 3.8 ms after frame 0 arrived and
  "decoded: nothing yet" (the client's first decoded report, for frame 1,
  came 116 ms after frame 0 arrived). `vr1` showed the same shape (IDRs at
  frames 0 and 5). So an early second IDR is normal host behavior at stream
  start and is unprompted as far as the `rst` counter goes; its cause is
  open (**inferred** candidates: the host repeats the keyframe until a
  decoded frame is acknowledged, or its encoder was reset twice during
  start-up - the host's own `encResets` value read 3 from its first sample
  on).
- By contrast, the 20 s stream received by this project's Python client
  (`probe1`, 2,217 access units) has parameter sets only before access unit
  0: one IDR, no second one.
- **The `rst` -> IDR link is not testable in `vr3`**: the client never hit an
  unrecoverable error, so `rst` never changed. Whether each client reset is
  answered by exactly one IDR is still open; it needs a lossy run or a probe
  that bumps `rst`.

### Frame reports (kind 4, type 0x0f)

Layout as tabled above: 17,423 reports, every one with a 24-byte payload,
one in every pose datagram (17,423 of 17,423 share their datagram with the
pose packet), 433 per second (median spacing 2.13 ms), i.e. four reports per
video frame. The two zero fields (+0x12, +0x1a) are 0 in all. The timing
fields are studied further in docs/svl-timing/frame-reports.md; what follows
is what bears on this page.

To compare the client's timestamps with packet arrival, the client clock was
mapped onto the capture clock through the pose packet's own transmit stamp
(same clock, same datagram); the mapping is good to about 0.2 ms.

| Slot | Ids reported | Timestamp relative to arrival of the frame's last data packet |
|---|---|---|
| accepted | **every frame, 0..4259**, each exactly once and in order | -0.17 .. +0.11 ms (median -0.03, max 1.3): the accept time *is* the arrival of the last data packet |
| decoded | frames 1..4258, each once, in order (frame 0 never appears with a time; 4259 arrived as the capture ended) | +2.0 .. +8.8 ms (1 % 2.2, median 3.0, 99 % 4.0) |
| display, flip time | 3,705 distinct frames, first 3, last 4257, in order | +4.2 .. +44.6 ms (median 18.1, 90 % 36.3) |
| display, predicted time | the same id as the flip slot in all 17,423 reports | flip time + 8.29 .. 8.33 ms (one 120 Hz period) |

- **Accept does not wait for parity or the closing bookend.** The accepted
  time precedes the arrival of the frame's last element by 0.2 .. 7 ms
  (median 0.42) and coincides with the last *data* packet, as
  `CheckRXComplete` says: a frame is done when its data prefix is complete.
- Decode latency, decoded time minus accepted time: min 2.1, median 3.0,
  99 % 4.0, max 8.8 ms (4,258 frames). This is vrlink under
  Klepton on a Mac, not a headset.
- Displayed: 3,705 of 4,260 frames reached `FlipFrame` (94 per second
  against 108 frames per second received). Step between consecutive
  displayed ids: 1 x3289, 2 x320, 3 x69, 4 x18, 5..7 x8 - frames are skipped
  by the display-time selection, never shown out of order. Flip minus
  decoded: median 15.2 ms, 99 % 38.2 ms.
- How far a report trails the wire: the first report that carries a frame's
  accepted entry leaves 0.1 ms or more after its last data packet arrived
  (median 1.3 ms, 99 % 3.5 ms); the first carrying its decoded entry, 2.3 ms
  or more (median 4.3, 99 % 7.2). The worst case for both is 63 ms, at a
  single 69 ms pause in the client's pose packets 0.17 s into the stream. At the moment a report is sent, its accepted id is the
  newest completely arrived frame in 16,539 of 16,945 reports and one behind
  in 403; its decoded id is the newest in 10,774 and one behind in 6,165;
  its displayed id is mostly 1..4 frames behind (mode 2).
- The queue rule holds: ids in each slot never go backwards and the accepted
  and decoded slots advance one id at a time, so with four reports per frame
  each (id, time) pair is repeated, typically in 3..5 consecutive reports
  (4 in 2,592 of 4,260 cases for accepted).
- Before the first frame all four slots are zero: 402 all-zero reports, the
  last 0.6 ms before the first video datagram. At start the slots fill in
  the order accepted (frame 0, 3.8 ms after it arrived), decoded (frame 1,
  116 ms), display (frame 3, 126 ms). The 110 ms hole is the client's
  start-up stall described in [packets.md](packets.md).
- The host got one of these every 2.3 ms for the whole session and never
  needed to act on loss, so which field it reacts to is still not visible.

### From `vr1` only (lossy run; not re-observed)

- Retransmit request layout. Nine `04 05` datasets, `index` (+6) always 0,
  payload a list of u16 ids, e.g. frame 7: `05 00 06 00 07 00` (ids 5, 6, 7);
  frame 21: ids `0..0xa, 0x800..0x803`. Data ids come first in ascending
  order, parity ids after, as the guided scan produces them. No request
  contained 0xffff.
- Client log: 14 `"Fault, SVLFEC Received ExperiencedAnUnrecoverableError()"`
  lines in that run, the pose `rst` counter rose 0 -> 18, and the decoder's
  stream contained 5 IDR access units (frames 0, 5 and three later). So
  resets are followed by IDRs, but fewer IDRs than resets; the pairing was
  not traced through the torn log.

## Open questions / to confirm on the wire

1. A request with 0xffff as first id (lose the first bookend of a frame).
2. Which field of the frame report the host reacts to, and what it does with
   the times.
3. Tie one client reset to the pose-packet `rst` counter changing and to the
   next IDR, and count IDRs per reset (`vr3` had no reset; `vr1` had 14 fault
   lines but 5 IDRs).
4. Why the host sends a second IDR a few frames after the first (frame 4 in
   `vr3`, frame 5 in `vr1`) when the real client connects, and not for the
   Python client.
5. What the host sends in reply to a request and how fast (the 3000 us
   resend floor), and whether it answers requests for Q parity it never
   sent. Needs a lossy run with timestamps.
6. The value and name of VTE id 0x1a in a real session.
7. The exact meaning of the third argument of the datalink send call (the
   `true` used for descriptors and requests).

## Client results (2026-11-10): loss recovery against a real host

The Swift viewer (`client`, `VRLinkCore/Video.swift`) discarded a
random fraction of incoming class-5 messages (data, parity and descriptors
alike) on an otherwise clean LAN, at 90 Hz. **Captured by client**, about 12 s
per row:

| simulated loss | frames per second | packets repaired by FEC | packets re-requested | frames abandoned |
|---|---|---|---|---|
| 0 % | 90 | 0 | 0 | 0 |
| 2 % | 90 | 214 | 56 | 0 |
| 10 % | 90 | 759 | 1,188 | 0 |
| 30 % | 90 | 804 | 7,920 | 0 |

What this settles:

- **The host answers retransmit requests** (class 4 type 5), for data packets
  and for the descriptor (`0xffff`), fast enough that no frame missed its turn
  even at 30 % loss. This was static-only before.
- **Real FEC repairs** against host parity work, including in short last
  stripes with the missing blocks treated as known zeros.
- **The reset counter requests a keyframe.** An earlier, buggy build of the
  assembler abandoned frames and bumped the pose message's reset counter; each
  bump was followed by `[SVLS] ResetVideoStream` from the host and a fresh
  keyframe. So the `rst` -> keyframe link is real.

The client's rules, simpler than vrlink's: when a packet from a
later group arrives, request every missing data packet of the earlier groups;
when an incomplete frame has been quiet for 4 ms, request up to 20 of its
missing data packets (or just the descriptor); never request parity. Frames go
to the decoder strictly in order; a frame that holds later ones up for 100 ms,
or falls out of the host's 16-frame window, is abandoned and a keyframe
requested.

Not measured: how long a retransmission takes, the picture quality cost of the
extra bitrate, or behavior under burst loss (the simulated loss is
independent per message).

## Client results (2026-11-10): pacing of unprompted requests

`client` first asked, for every incomplete frame that had been quiet
for 4 ms, for its first 20 missing packets, and reset the timer on each
request. With many frames incomplete at once that is thousands of requests a
second (measured: 570,000 packet requests in 15 s of a stalled session). It
now follows vrlink's rule above: only as many of the frame's
missing packets as the host should have sent by now, at 104 microseconds a
packet counted from the end of the quiet interval, and at most 20. While it
is waiting for a keyframe it only chases the newest three frames.

With that, and an optimized build, 10 % and 25 % simulated loss on a 120 Hz
stream of 100 to 150 kB frames is recovered at the full frame rate with no
frame abandoned (about 1,000 packets repaired by FEC and 1,700 re-requested
in 15 s at 10 %).
