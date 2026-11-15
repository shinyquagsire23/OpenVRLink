# Per-frame reports to the host (the type-4 "last RX id" packet)

Sources: `SVLDataLink::SendLastRXID()` +0x15c648,
`SVLDataLink::FrameHasBeenAccepted(unsigned short, int)` +0x15c06c,
`SVLDataLink::FrameHasBeenDecoded(unsigned int, int)` +0x15c080,
`SVLDataLink::FrameHasBeenSubmittedForDisplay(unsigned int, int, int)`
+0x15c0a0, `SVLDataLink::PushOntoIDAndTimeQueue` +0x15bf00,
`QSVLCodecNDK::HandleOnImageAvailable` +0xfde30,
`QSVLRendererXR::FlipFrame` +0x10ae78, `QSVLClient::SendPoses` +0xf4d34.
All details below are **static** unless marked otherwise.

This packet carries the client's per-frame latency feedback, complementing the
loss counters `cRXpps`, `cRXerr`, and `cRXpass` (docs/svl-values/) for host
rate control.

## Report queues

`SVLDataLink` keeps four `std::queue<IDAndTime>` (`{u32 id; i32 time}`), all
under one mutex (`+0xf4`):

| queue | pushed by | id | time |
|---|---|---|---|
| accepted (`+0x120`) | `FrameHasBeenAccepted(frameId16, t)` — called from the video receive path when a frame is complete (docs/svl-video/) | 16-bit network frame id | timestamp passed by caller |
| decoded (`+0x150`) | `FrameHasBeenDecoded(n, t)` from the decoder's image-available callback | `frameIdTable[n & 0x7f]` | timestamp taken at the top of the callback |
| submitted (`+0x180`) | `FrameHasBeenSubmittedForDisplay(n, t_display, t_flip)` from `FlipFrame`, **only when host version > 5** | `frameIdTable[n & 0x7f]` | `t_display` = now + (OpenXR predicted display time − OpenXR now), i.e. the predicted display instant on the SVL clock |
| flip (`+0x1b0`) | same call | same id | `t_flip` = timestamp at entry to `FlipFrame` |

`frameIdTable` is a 128-entry `u16` array at `SVLFEC+0xb20` (reached through
`SVLDataLink+0x10`) that maps the low 7 bits of the first u32 of the frame's
metadata (the value the decoder path carries with each picture) back to the
16-bit network frame id (**static** for the lookup; the table's writer is in
the video path).

## Packet layout

`SendLastRXID` is called from `SendPoses` immediately before every pose packet
— four times per display frame. For each queue, if more than one entry is
queued it pops one entry from the front and then reads the new front without
removing the last remaining entry. An empty queue reports zeros, and the final
entry is repeated until a newer one arrives.

`SendLastRXID` builds a 32-byte `dataset` (8-byte element header plus 24-byte
value) and sends it via `SubmitMessage(pkt, false, false)`. The first two ids
ride in the header's `id` and `index` fields (offsets 0x02 and 0x06), so a
parser that splits header from value sees a 24-byte class-4 type-0x0f element
whose `id` is the decoded frame and whose `index` is the accepted frame.
Offsets below are from the start of the header:

| off | type | value |
|---|---|---|
| 0x00 | u8 | `0x04` — dataset type |
| 0x01 | u8 | `0x0f` — flags |
| 0x02 | u16 | **decoded** frame id |
| 0x04 | u16 | `0x18` — payload length (24) |
| 0x06 | u16 | **accepted** frame id |
| 0x08 | i32 | decoded timestamp |
| 0x0c | i32 | accepted timestamp |
| 0x10 | u16 | **submitted** frame id |
| 0x12 | u16 | 0 |
| 0x14 | i32 | predicted display timestamp of the submitted frame |
| 0x18 | u16 | **flip** frame id (same frame as 0x10 unless the queues are momentarily out of step) |
| 0x1a | u16 | 0 |
| 0x1c | i32 | flip-start timestamp |

All timestamps are client-clock SVL microseconds; the host converts them with
its own offset estimate ([clock-sync.md](clock-sync.md)).

Equivalent logic in Python:

```python
def send_last_rx_id(link):
    def take(q):
        if len(q) > 1: q.popleft()
        return q[0] if q else (0, 0)
    dec_id, dec_t = take(link.decoded)
    acc_id, acc_t = take(link.accepted)
    sub_id, sub_t = take(link.submitted)
    flp_id, flp_t = take(link.flip)
    link.submit(struct.pack("<HHHHiiHHiHHi",
        0x0f04, dec_id & 0xffff, 0x18, acc_id & 0xffff,
        dec_t, acc_t, sub_id & 0xffff, 0, sub_t, flp_id & 0xffff, 0, flp_t))
```

Because one element is dropped per call and the call rate is four per display
frame, the report keeps up with streams of up to four video frames per display
frame; in steady state every frame is reported about four times
(**captured**: an accepted id is repeated in 4 consecutive reports 2,578
times, 3 or 5 times 1,581 times, and other counts 43 times).

## Capture verification (`vr3`)

Capture `vr3` records 40.26 s of `vrlink` under Klepton, with 39.33 s of video
(4,260 frames, ids 0…4,259, none lost) and per-datagram timestamps. Arrival
times below are capture timestamps mapped onto `vrlink`'s SVL clock using the
fit in [clock-sync.md](clock-sync.md); `vrlink` stamps a received packet about
0.1 ms after the tracer does.

### Layout

- **captured**: All 17,423 class-4 type-0x0f elements carry a 24-byte value,
  sent once per pose packet immediately before the pose element in the same
  datagram. Including the 8-byte header, that matches the 32-byte packet in the
  table above (`vr1`'s 24-byte figure excluded the header).
- **captured**: The two u16 padding fields after the submitted and flip ids
  (0x12, 0x1a) are 0 in all 17,423 reports, and the submitted id equals the
  flip id in all 17,423 reports.
- **captured**: Every non-zero frame id keeps a single timestamp for as long as
  it is reported across 15,931 id/field pairs (the only id seen with two
  timestamps is accepted id 0, which transitions from 0 before video starts to
  frame 0's acceptance timestamp).
- **captured**: No `04 05` element (the retransmit request seen 9 times in
  `vr1`) was sent in `vr3`; frame reports were the only class-4 traffic.

### Start-up

- **captured**: All fields are zero in the first 402 reports, up to the first
  video frame. The first non-zero field is the accepted timestamp while
  accepted id remains 0, because the first frame has id 0: an id of 0 with a
  non-zero timestamp represents frame 0, whereas a zero timestamp indicates
  that no frame has been accepted yet. That report repeats 48 times during the
  host's 111 ms pause after frame 0, followed by accepted ids 1, 2, 3 … in
  consecutive reports as the startup burst arrives.
- **captured**: The decoded field becomes non-zero 2 reports after accepted id
  1 (reporting id 1; frame 0 was never reported decoded, and `vrlink` logged
  `[SVLDecoder] Failed to acquire latest image!` at that point). The submitted
  and flip fields become non-zero 126 ms after the first descriptor, at frame
  3, confirming that this host takes the `version > 5` path (its descriptors
  report version 14).

### Frame IDs versus wire frames

- **captured**: All 4,260 frames were reported accepted, 4,258 were reported
  decoded (all except frame 0 and the frame in flight at capture end), and
  3,705 were reported submitted. The remaining 553 decoded frames were never
  submitted for display: the submitted id jumps by 2–6 between consecutive
  reports 412 times, whereas accepted and decoded never advance by more than 1
  from one report to the next (matching the pop-one-per-call rule above).
- **captured**: The ordering `accepted ≥ decoded ≥ submitted` holds in all
  16,799 reports after startup.
- **captured**: Frame lag behind the newest frame whose opening descriptor has
  arrived when the report is sent:

  | field | 0 frames behind | 1 | 2 | 3 | 4 | 5 or more |
  |---|---|---|---|---|---|---|
  | accepted | 15,711 | 1,088 | | | | |
  | decoded | 10,026 | 6,739 | 34 | | | |
  | submitted | 46 | 2,563 | 6,566 | 3,491 | 3,195 | 938 |

### Timestamps versus arrival times

The table below gives intervals in microseconds for frames after the first
1.5 s as median (5th–95th percentile).

| interval | value | reading |
|---|---|---|
| accepted timestamp − arrival of the frame's **last data packet** | 104 (87–133), minimum 82 | `FrameHasBeenAccepted` is stamped when the last data packet completes the frame. It falls 278 µs *before* the closing descriptor arrives (after the parity packets), so acceptance does not wait for the closing descriptor |
| accepted timestamp − arrival of the frame's first descriptor | 495 (397–664) | time to receive the frame: 0.3–0.6 ms for a typical 7–8 kB frame |
| decoded − accepted | 2,988 (2,318–3,704), max 8,811 | decode latency reported by `vrlink` (VideoToolbox under Klepton) |
| flip − decoded | 15,028 (7,351–35,118) | wait for a display slot |
| predicted display − flip | 8,328 (8,319–8,330) | one 120 Hz period: the runtime's prediction at `FlipFrame` |
| predicted display − accepted | 26,311 (18,589–46,371) | receive-to-photon latency visible to the host |
| predicted display − (host `tx_time` moved to the client clock) | 23,032 (16,248–24,565), last 15 s | receive-to-photon latency measured from the host's send timestamp |
| pose send time − accepted timestamp in the same datagram | 4,589 (444–9,036) | age of the report when sent |

The 26 ms total reflects this Klepton session (a 108 Hz loop presenting through
a desktop compositor) rather than protocol overhead. Because the report carries
separate timestamps for each stage, the host can compute each pipeline interval
directly.

## Open questions

- Probe from `prototype/minimal/` whether the host stalls, drops bitrate, or
  stops sending if these reports are omitted or frozen.
- Check on the wire whether the submitted and flip fields remain zero when
  connected to a host with version ≤ 5 (`vr3`'s host reported version 14).
- Determine why 553 decoded frames went unsubmitted in `vr3` even though host
  and client both ran at ~108 Hz (`ServeBestHardwareBuffer` was not decompiled;
  the host's `dFrmsEarly` key reached 46 versus 12 for `dFrmsLate`, which may
  reflect the same skipped frames).
- Check whether the decoded timestamp must come specifically from decoder
  output or whether stamping any monotonic post-reassembly stage satisfies the
  host.
- Determine how the host uses the accepted-to-display latency figures (bitrate
  control, frame pacing, or telemetry only).
