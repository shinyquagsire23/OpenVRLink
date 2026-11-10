# Video packets

All multi-byte fields are little-endian (arm64 native loads, no byte swaps
anywhere on this path - **static**).

## The `dataset` message header (8 bytes)

Every SVL message above the transport is a `dataset`: an 8-byte header followed
by `len` payload bytes. `GenSimpleDataset` (+0x155bc4) allocates `len + 8` and
fills it exactly like this (**static**):

| Off | Type | Name | Notes |
|---|---|---|---|
| 0 | u8 | `kind` | Top-level class. `SVLDataLink::ReceivedData` (+0x15a9b8) switches on it |
| 1 | u8 | `type` | Sub-type within the kind (the `SVST_*` stream type) |
| 2 | u16 | `id` | For video: frame id. For reliable stream: sequence number |
| 4 | u16 | `len` | Payload length in bytes, not counting this header |
| 6 | u16 | `index` | For video data: packet id. For a descriptor: group number |
| 8 | ... | payload | |

The client's byte accounting adds `len + 0xc` per message
(`ByteLogger::LogBytes(..., len + 0xc)` in every caller), so 12 bytes of
overhead per message are assumed: this 8-byte header plus 4 more. **inferred**:
the other 4 belong to the transport framing - see docs/svl-transport/.

`kind` values seen in `SVLDataLink::ReceivedData` (**static**; only kinds 4 and
5 are in scope here, the rest are listed so a capture can be sorted):

| kind | Meaning | Handler |
|---|---|---|
| 1 | reliable-stream ack | removes the acked element |
| 2 | reliable stream | `RXReliableStream`, then acked with kind 1 |
| 3 | unreliable stream (types 0x01, 0x07 values, 0x0d VTE, 0x12, 0x14, 0x16 ...) | `RXUnreliableStream` |
| 4 | video *reply* channel, client -> host | built by the client; see below |
| 5 | video, host -> client | `SVLFEC::AcceptVideoPacket` |
| 6, 0xb, 0xc | audio | `SVLAudio::TransportRXAudioFrames` |
| 8 | debug message | `RXDebugMessage` |
| 9 / 10 | broadcast / broadcast reply | |

The note in Klepton's STEAMLINK.md section 3.1 that a header reads
`kind=0x0d03` is this pair: `kind = 3`, `type = 0x0d` (a ValueTransportSystem
message). **captured** (`vr3`): class 3 / type 0x0d elements do arrive from the
host (6 of them, 12..216 bytes, all before the first video frame).

## Video messages

| Direction | kind | type | Name | Payload |
|---|---|---|---|---|
| host -> client | 5 | 2 | `SVST_VIDEO_TRANSPORT_DESCRIPTION` (frame descriptor / bookend) | [frame-descriptor.md](frame-descriptor.md) |
| host -> client | 5 | 3 | `SVST_VIDEO_TRANSPORT` (data or parity packet) | below |
| client -> host | 4 | 5 | retransmit request (`resend_fec_request`) | [retransmit.md](retransmit.md) |
| client -> host | 4 | 0x0f | frame report (`LastVideoPacket_t`) | [retransmit.md](retransmit.md) |

The two names are the client's own: `"SVST_VIDEO_TRANSPORT_DESCRIPTION:
WARNING: Could not initialize frame on hardware."` is logged on the `type == 2`
branch and `"SVST_VIDEO_TRANSPORT: WARNING: ..."` on the `type == 3` branch of
`SVLFEC::AcceptVideoPacket` (+0x160684) - **static**. The header words the TX
code writes are `0x0205` (descriptor), `0x0305` (data/parity) in
`SVLFECRAID6TXFrame::InitializeAndSend` (+0x1617a4) / `PopulateFecBlocks`
(+0x161518), and `0x0504`, `0x0f04` for the two client messages
(`SVLFECRXFrame::CheckRetry` +0x15f2cc, `SVLDataLink::SendLastRXID` +0x15c648).

## Data / parity packet (kind 5, type 3)

**static** - `SVLFECRXFrame::AcceptVideoPacket` (+0x15edc8):

| Off | Type | Name | Notes |
|---|---|---|---|
| 0 | u8 | 5 | |
| 1 | u8 | 3 | |
| 2 | u16 | `frame_id` | Wraps at 16 bits. Slot = `frame_id & 0xf` |
| 4 | u16 | `len` | 0x400 for every packet except the last data packet of the frame |
| 6 | u16 | `packet_id` | 0x000..0x7ff = data, 0x800..0xfff = parity; >= 0x1000 is rejected with `"Warning: received packet ID %d in frame %d, but packet id exceeded max frame size"` |
| 8 | u8[len] | payload | |

- Data packet `n` carries bytes `[n*1024, n*1024 + len)` of the encoded frame.
  The client `memcpy`s it to `m_pData + n*1024`, where `m_pData` is the
  MediaCodec input buffer itself (see [decode-handoff.md](decode-handoff.md)).
- Parity packet `0x800 + p` is stored in a per-slot 2 MiB side buffer at
  `(p * 1024)`. Parity packets are always 1024 bytes on the TX side.
- A duplicate (bit already set in the per-frame bitmap) is dropped silently.
- **Frame length before the descriptor arrives:** if the slot has no descriptor
  yet, any packet with `len != 0x400` sets `frame_size = packet_id * 1024 + len`.
  So the short last packet doubles as an end-of-frame marker. A frame whose size
  is an exact multiple of 1024 has no short packet and its size is only known
  from the descriptor.
- After storing, the per-FEC hook `ReceivedVideoPacket(packet_id, now)` runs
  (see [fec.md](fec.md)), then, if the packet's *group* is higher than any seen
  for this frame, `CheckRetry(group)` runs (see [retransmit.md](retransmit.md)).
  Group = `packet_id / 64` for data, `(packet_id - 0x800) / 16` for parity.

### Numbering

```
stripe s  (s = 0..)   data  packets  8*s .. 8*s+7
                      parity packets 0x800 + 2*s  (P)  and  0x800 + 2*s + 1  (Q)
group  g  (g = 0..)   stripes 8*g .. 8*g+7  =  data 64*g .. 64*g+63, parity 0x800+16*g .. +15
n_data   = ceil(frame_size / 1024)
n_stripe = ceil(n_data / 8)
n_group  = ceil(n_data / 64)
```

## Send order for one frame

**static** in the shared TX code - `SVLFECRAID6TXFrame::InitializeAndSend`
(+0x1617a4) does this - and **captured**: 4,259 of the 4,260 frames of `vr3`
arrived in exactly this order, element for element (the one exception lost
its closing bookend on the wire; see "Captured"):

```python
send(descriptor, group=0, bookend=0)                 # see frame-descriptor.md
for g in range(n_group):
    for i in range(64):                              # column-major across the 8 stripes
        n = 64*g + (i // 8) + (i % 8) * 8
        if n*1024 < frame_size:
            send(data_packet(n))                     # len = min(1024, frame_size - n*1024)
    for s in range(8):                               # stripes of this group that hold data
        if (8*g + s) * 8 * 1024 >= frame_size: break
        P, Q = encode(stripe 8*g + s)                # missing data blocks count as zeros
        send(parity_packet(0x800 + 16*g + 2*s))      # P always
    if q_enabled:                                    # see below
        for s in ...same stripes...:
            send(parity_packet(0x800 + 16*g + 2*s + 1))   # Q, after all of the group's P
    send(descriptor, group=g+1, bookend=g+1)
```

- The interleave means consecutive datagrams belong to different stripes, so a
  burst loss of up to 8 consecutive data packets costs each stripe one packet.
- `q_enabled` on the TX side is "the peer's `cRXpass` SVLRoot value was below
  99.99 % at some point in the last 10 s" (**static**: `cRXpass` is read at the
  top of `InitializeAndSend`; the flag is `this+0x4480`). So with a clean link
  only the XOR parity (P) is sent and the stream carries 12.5 % FEC overhead;
  with Q it is 25 %. **captured**: the host sends Q on every frame for the
  first 8.64 s of a stream even though the client never reported a `cRXpass`
  below 100, then P only - see "Captured".
- The TX code refuses a frame with more than its allocated data/parity packets
  with `"FAULT: Packet too big!!! Can't send!!! Dropping"`.

## Captured

One session, capture `vr3` (not in the repo; it holds live credentials): the
real client on a wired-quality LAN, 39.33 s of video, 60,945 class-5 elements
in 59,668 datagrams, none torn, each datagram with a receive timestamp
(CLOCK_MONOTONIC, taken on the client). Everything in this section is
**captured**. Times called "arrival" are those receive timestamps; times called
"tx" are the host's own `tx_time` from the frame's descriptor
([frame-descriptor.md](frame-descriptor.md)).

An earlier capture, `vr1`, had a third of its datagrams torn; its counts were
lower bounds and are replaced by the figures below.

### Header, lengths, reassembly

- The 8-byte `dataset` header exactly as tabled above. 52,314 `05 03`
  elements (43,910 data, 8,404 parity), `len` 1..1024; 8,631 `05 02`
  elements, every one 1016 bytes of payload.
- 4,260 frames, ids 0..4259 with no gap, never interleaved: every element of
  frame `n` arrives before the first element of frame `n+1`, and datagram
  sequence numbers rise monotonically inside every frame.
- `len == 1024` on every data packet except the highest packet id of the
  frame, and `packet_id * 1024 + len == frame_size` from the descriptor on that
  one - in all 4,260 frames, no exception. No frame in the capture had a size
  that is an exact multiple of 1024. Every parity packet is 1024 bytes.
- No data packet was missing and none was duplicated: all 4,260 frames
  reassemble from data packets alone. Concatenated in frame-id order, frames
  0..4258 are **byte-identical to the elementary stream the client fed its
  decoder** (`KL_VTDEC_DUMP`), from its first byte on.
- The one frame "not found" in the dump, 4259, is the last frame of the
  capture. The dump file is truncated; it ends
  with the first 6,155 of that frame's 7,724 bytes. Its length is an exact
  multiple of 4096, i.e. the client was killed with the last buffered write
  unflushed. (The dump's index file is cut short the same way: 4,220 lines.)
- A datagram normally carries one video element. 1,277 datagrams carry two:
  the frame's short last data packet shares a datagram with the element sent
  just before it (1,275 times, a full data packet) or just after it (twice, a
  parity packet). That happens exactly when the short packet is 328 bytes or
  less; every short packet of 329 bytes or more (2,983 of them) travels alone.
  So the sender coalesces elements up to 1,368 bytes of elements per datagram.
  Whether that is the video code or the transport is for docs/svl-transport/.

### Send order

- Element order inside a frame equals the pseudo-code in "Send order" in
  4,259 of 4,260 frames: bookend 0, then per group the data packets
  column-major, then the P packet of each stripe, then (when Q is on) the Q
  packet of each stripe, then the bookend `g+1`. Example, frame 8 (9,863
  bytes, 10 data packets): `B0 d0 d8 d1 d9 d2 d3 d4 d5 d6 d7 P0 P1 Q0 Q1`.
- That frame 8 is the exception: its closing bookend never arrived, and the
  inbound datagram sequence has its only gap of the capture (one datagram) at
  exactly that position. So one datagram in 62,589 was lost on the way, and it
  was a bookend. The client did nothing about it (nothing to do: the frame
  was already complete), and the host did not resend it.
- A complete multi-group frame, the largest of the capture - frame 64,
  283,768 bytes, 278 data packets, 5 groups, 354 elements in 353 consecutive
  datagrams, 13.75 ms from first to last arrival:

  | Elements | Count | Arrival, ms after bookend 0 |
  |---|---|---|
  | bookend, group 0, index 0 | 1 | 0.000 |
  | data 0..63, column-major (`0, 8, 16, .. 56, 1, 9, ..`) | 64 | 0.042 .. 2.493 |
  | P of stripes 0..7 (`0x800, 0x802, .. 0x80e`) | 8 | 2.542 .. 2.829 |
  | Q of stripes 0..7 (`0x801, 0x803, .. 0x80f`) | 8 | 2.874 .. 3.176 |
  | bookend, group 1, index 1 | 1 | 3.196 |
  | data 64..127, P 8..15, Q 8..15, bookend 2 | 64 + 8 + 8 + 1 | 3.235 .. 6.088 |
  | data 128..191, P 16..23, Q 16..23, bookend 3 | 64 + 8 + 8 + 1 | 6.118 .. 8.973 |
  | data 192..255, P 24..31, Q 24..31, bookend 4 | 64 + 8 + 8 + 1 | 9.014 .. 12.018 |
  | data 256..277 (`256, 264, 272, 257, 265, 273, .. 262, 270, 263, 271`) | 22 | 12.062 .. 12.779 |
  | P of stripes 32..34, then Q of stripes 32..34 | 3 + 3 | 13.549 .. 13.714 |
  | bookend, group 5, index 5 | 1 | 13.752 |

  The last group shows the column-major order over a partly filled group:
  the columns simply skip packet ids past the end of the frame. Groups are
  not separated by a visible pause: 68 multi-group frames arrive at 19..34
  elements per ms (median 25), about one group every 3 ms.
- Bookends per frame are exactly `1 + n_group`; none is repeated. Counts by
  group number: 0 x4260, 1 x4259, 2 x68, 3 x42, 4 x1, 5 x1.

### P and Q parity

- **vr1 suggested "Q is sent under loss"; vr3 shows Q on a loss-free link.**
  Frames 0..941 - the first 8.64 s of the stream by the host's clock - carry
  both P and Q for every stripe (2,322 Q packets). Frames 942..4259 (the
  other 30.7 s) carry P only. In total 6,082 P packets, one per stripe of
  every frame, and no stripe ever has Q without P.
- During those 8.64 s the client reported `cRXpass` = 100 in every sample it
  sent (732 samples, the first 13 ms before the first video packet), sent no
  retransmit request, and lost one datagram. So the Q period in this run
  happened without any loss. **inferred**: the host starts a stream with
  the "recent loss" flag already set (or reads `cRXpass` as below 99.99 until
  the first value arrives) and the 10 s timer of the TX code runs out; the
  timer would then have started about 1.36 s before the first video frame,
  which is before the first SVL element of the capture. What is measured is
  only: Q for the first 8.64 s, never afterwards.
- A client must therefore expect Q from the first frame and must not treat an
  odd parity id as a sign of trouble.

### Frame sizes and timing

40 s of a mostly static SteamVR scene at 120 Hz nominal. These figures come from
one run and are not a specification.

| Quantity | Value |
|---|---|
| frames | 4,260 in 39.327 s of host `tx_time` = 108.3 frames/s |
| encoded bytes | 42,776,097 (8.70 Mbit/s over the run; 6.81 Mbit/s after frame 200) |
| video element bytes on the wire (headers, parity, bookends included) | 60,638,449 = 1.42 x the encoded bytes |
| frame size, all frames | min 302, 1 % 6,817, median 7,738, mean 10,041, 90 % 9,327, 99 % 128,261, max 283,768 bytes |
| frame size, frames 200.. (steady state) | min 302, 1 % 6,867, median 7,722, 99 % 10,653, max 11,728 bytes |
| data packets per frame | min 1, median 8, mean 10.3, 90 % 10, 99 % 126, max 278; 3,220 frames have exactly 8 |
| frames over 64 data packets (more than one group) | 68, all between frames 44 and 112 (0.44 .. 1.06 s after the first frame) |
| frames under 1024 bytes (one packet) | 9: frames 1, 2, 3, 141, 1109..1113 |
| interval between frames, host `tx_time` | min 3.83, 1 % 7.34, 10 % 8.25, median 9.20, mean 9.23, 90 % 10.16, 99 % 10.59, max 40.81 ms; 94.5 % lie in 8.0 .. 10.5 ms |
| interval between first-packet arrivals (frames 12..) | min 2.24, 1 % 7.35, median 9.20, mean 9.23, 99 % 10.61, max 40.70 ms |
| first-to-last arrival within a frame (frames 200..) | min 0.31, median 0.77, 90 % 0.95, 99 % 1.27, max 10.2 ms |
| gap between consecutive elements of a small frame | median 49 us, 90 % 124 us |

- The interval histogram has no single peak at 8.33 ms: rounded to 1 ms it
  reads 8 ms x769, 9 ms x1707, 10 ms x1658, with 7 ms x54 and 11 ms x51. The
  host paced this run at about 108 frames/s, not 120. Why is for
  docs/svl-timing/.
- The two long intervals are at the start: 31.4 ms before frame 15 and
  40.8 ms before frame 23 by `tx_time`. After frame 140 every interval lies
  between 6.5 and 12 ms.
- The stream opens with small frames (frames 0..43: 536 bytes .. 62 kB), then
  a burst of large ones (frames 44..112: 51..284 kB, 0.64 s at 116 Mbit/s),
  decays (15 kB by frame 120) and settles at ~7.7 kB per frame. The largest
  frame (64) is a P frame, not an
  IDR; the two IDRs of the run are 2,512 and 2,378 bytes
  ([retransmit.md](retransmit.md)).
- Arrival times of the first twelve frames are not usable for pacing: the
  client's receive thread stalled for 111 ms right after the first datagrams
  of frame 0 (the host's `tx_time` shows frames 0..11 sent at a normal 7 ms
  cadence; they were all read in a 24 ms burst afterwards, while the client's
  pose packets kept going out on time). The stall begins when the last data
  packet of frame 0 has been stored, i.e. when the first frame is handed to
  the decoder. **inferred**: decoder start-up blocking the receive thread;
  nothing on the wire.

## Open questions / to confirm on the wire

1. Where the extra 4 bytes of the client's `len + 0xc` accounting live (the
   capture shows an 8-byte datagram prefix shared by all datasets in it, so
   this is probably just the client's estimate).
2. What exactly starts and ends the Q period: is it a fixed 10 s from stream
   set-up, and does a `cRXpass` below 99.99 from the client bring Q back? Needs
   a probe that reports a low `cRXpass` (or drops packets) mid-stream.
3. Whether the host ever sends a frame over 2 MiB (packet ids would pass
   0x7ff) - the client cannot receive it. The largest seen is 283,768 bytes.
4. A frame whose size is an exact multiple of 1024 (no short packet; size
   known only from the descriptor) - none among 4,260.
5. Whether the 1,368-byte coalescing limit is fixed or follows a negotiated
   MTU.
