# Per-frame reports to the host (the type-4 "last RX id" packet)

Sources: `SVLDataLink::SendLastRXID()` +0x15c648,
`SVLDataLink::FrameHasBeenAccepted(unsigned short, int)` +0x15c06c,
`SVLDataLink::FrameHasBeenDecoded(unsigned int, int)` +0x15c080,
`SVLDataLink::FrameHasBeenSubmittedForDisplay(unsigned int, int, int)`
+0x15c0a0, `SVLDataLink::PushOntoIDAndTimeQueue` +0x15bf00,
`QSVLCodecNDK::HandleOnImageAvailable` +0xfde30,
`QSVLRendererXR::FlipFrame` +0x10ae78, `QSVLClient::SendPoses` +0xf4d34.
All **static** unless marked.

This is the whole of the client's per-frame latency feedback. Together with
the loss counters `cRXpps` / `cRXerr` / `cRXpass` (docs/svl-values/) it is
what a host rate controller has to work with.

## Four queues

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

## The packet

`SendLastRXID` is called from `SendPoses` immediately before every pose packet
— four times per display frame. For each queue it discards the front element
while more than one is queued (so it always reports the **second-newest…
newest-remaining** entry: it pops one if size > 1, then reads the front), and
reads the front without removing the last one. An empty queue reports zeros.
The same entry is therefore repeated until a newer one arrives.

`dataset`, 32 bytes in all — the 8-byte element header plus a 24-byte value —
submitted with `SubmitMessage(pkt, false, false)`. The first two ids ride in
the header's own `id` and `index` fields (offsets 0x02 and 0x06), which is why
a parser that splits header from value sees a 24-byte class-4 type-0x0f
element whose `id` is the decoded frame and whose `index` is the accepted
frame. Offsets below are from the start of the header:

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

Pseudocode for an alternative client:

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
frame, the report keeps up with a stream at up to four frames per display
frame; in steady state every frame is reported about four times
(**captured**: an accepted id is repeated in 4 consecutive reports 2,578
times, 3 or 5 times 1,581 times, anything else 43 times).

## Confirmed against capture `vr3`

`vr3`: real client under Klepton, 40.26 s of capture, 39.33 s of video
(4,260 frames, ids 0…4,259, none lost), every datagram timestamped. Arrival
times below are capture timestamps moved onto the client's SVL clock with the
fit in [clock-sync.md](clock-sync.md); the client stamps a received packet
about 0.1 ms after the tracer does.

### Layout

- **captured**: 17,423 class-4 type-0x0f elements, every one with a 24-byte
  value, exactly one per pose packet and immediately before it in the same
  datagram. With the 8-byte header that is the 32-byte packet of the table
  above; vr1's "24" and this page's "32" were the same packet counted
  without and with its header.
- **captured**: the two u16s after the submitted and flip ids (0x12, 0x1a)
  are 0 in all 17,423. Submitted id = flip id in all 17,423.
- **captured**: every id keeps one timestamp for as long as it is reported
  (15,931 id/field pairs; the only one with two timestamps is accepted id 0,
  which is "nothing yet" and then frame 0).
- **captured**: no `04 05` element (the retransmit request vr1 saw 9 of) was
  sent in `vr3`; the report is the only class-4 traffic.

### Start-up

- **captured**: all fields are zero in the first 402 reports, up to the first
  video frame. The first non-zero field is the accepted timestamp — with
  accepted id still 0, because the first frame *is* id 0: a zero id with a
  non-zero timestamp means "frame 0", a zero timestamp means "nothing yet".
  That report is repeated 48 times (the host paused 111 ms after frame 0);
  then accepted ids 1, 2, 3 … follow in consecutive reports as the host's
  start-up burst arrives.
- **captured**: decoded becomes non-zero 2 reports after accepted id 1 (id 1; frame 0 was
  never reported decoded — the client logged
  `[SVLDecoder] Failed to acquire latest image!` at that point). Submitted
  and flip become non-zero 126 ms after the first descriptor, at frame 3,
  i.e. this host counts as "version > 5" (its descriptors say 14).

### Ids against the frames on the wire

- **captured**: every one of the 4,260 frames was reported accepted, 4,258
  decoded (all but frame 0 and the frame in flight when the capture ends),
  and 3,705 submitted. The other 553 decoded frames were never submitted for
  display: the submitted id jumps by 2–6 between consecutive reports 412
  times, while accepted and decoded never advance by more than 1 from one
  report to the next (the pop-one-per-call rule above).
- **captured**: order accepted ≥ decoded ≥ submitted holds in all 16,799
  reports after start-up.
- **captured**: how far each trails the newest frame whose first descriptor
  has arrived when the report is sent:

  | field | 0 frames behind | 1 | 2 | 3 | 4 | 5 or more |
  |---|---|---|---|---|---|---|
  | accepted | 15,711 | 1,088 | | | | |
  | decoded | 10,026 | 6,739 | 34 | | | |
  | submitted | 46 | 2,563 | 6,566 | 3,491 | 3,195 | 938 |

### Timestamps against arrival times

All in µs, frames after the first 1.5 s; median (5th–95th percentile).

| interval | value | reading |
|---|---|---|
| accepted timestamp − arrival of the frame's **last data packet** | 104 (87–133), minimum 82 | `FrameHasBeenAccepted` is stamped when the last data packet completes the frame. It is 278 µs *before* the closing descriptor arrives (which follows the parity packets), so acceptance does not wait for it |
| accepted timestamp − arrival of the frame's first descriptor | 495 (397–664) | time to receive the frame: 0.3–0.6 ms for the usual 7–8 kB frame |
| decoded − accepted | 2,988 (2,318–3,704), max 8,811 | decode latency as the client reports it (VideoToolbox under Klepton) |
| flip − decoded | 15,028 (7,351–35,118) | wait for a display slot |
| predicted display − flip | 8,328 (8,319–8,330) | one 120 Hz period: the runtime's prediction at `FlipFrame` |
| predicted display − accepted | 26,311 (18,589–46,371) | what the host can read as receive-to-photon |
| predicted display − (host `tx_time` moved to the client clock) | 23,032 (16,248–24,565), last 15 s | the same, from the host's send stamp |
| pose send time − accepted timestamp in the same datagram | 4,589 (444–9,036) | age of the report when it leaves |

The 26 ms is this Klepton session's figure (a 108 Hz loop presenting through
a desktop compositor), not a property of the protocol; the point is that
every stage's timestamp is in the report and the host has what it needs to
compute each of these itself.

## Open questions

- Whether the host stalls, drops bitrate or stops sending when these reports
  are missing or frozen — the first thing to probe from `prototype/minimal/`.
- Whether the submitted/flip fields stay zero for host version ≤ 5 on the wire
  (as the code implies; `vr3`'s host is version 14).
- Why 553 decoded frames were never submitted in `vr3` although host and
  client produced frames at the same 108 Hz (`ServeBestHardwareBuffer` was
  not read; the host's `dFrmsEarly` key ran up to 46 against `dFrmsLate`
  up to 12, which may be its view of the same thing).
- Whether "decoded" must mean decoder output specifically, or any monotonic
  post-reassembly stage is acceptable to the host.
- What the host does with the accepted-to-display figures (bitrate, its own
  frame pacing, or statistics only).
