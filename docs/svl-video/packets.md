# Video packets

All multi-byte fields are little-endian (arm64 native loads, with no byte swaps
anywhere on this path - **static**).

## The `dataset` message header (8 bytes)

Every SVL message above the transport is a `dataset`: an 8-byte header followed
by `len` payload bytes. `GenSimpleDataset` (+0x155bc4) allocates `len + 8` and
fills it as follows (**static**):

| Off | Type | Name | Notes |
|---|---|---|---|
| 0 | u8 | `kind` | Top-level class. `SVLDataLink::ReceivedData` (+0x15a9b8) switches on it |
| 1 | u8 | `type` | Sub-type within the kind (the `SVST_*` stream type) |
| 2 | u16 | `id` | For video: frame id. For reliable stream: sequence number |
| 4 | u16 | `len` | Payload length in bytes, not counting this header |
| 6 | u16 | `index` | For video data: packet id. For a descriptor: group number |
| 8 | ... | payload | |

`vrlink`'s byte accounting adds `len + 0xc` per message
(`ByteLogger::LogBytes(..., len + 0xc)` in every caller), assuming 12 bytes of
overhead per message: this 8-byte header plus 4 additional bytes. **inferred**:
the extra 4 bytes are accounted to transport framing (see
`docs/svl-transport/`).

`SVLDataLink::ReceivedData` switches on the following `kind` values (**static**;
only kinds 4 and 5 belong to the video path, while the others are listed to
help classify wire captures):

| kind | Meaning | Handler |
|---|---|---|
| 1 | reliable-stream ack | removes the acked element |
| 2 | reliable stream | `RXReliableStream`, then acked with kind 1 |
| 3 | unreliable stream (types 0x01, 0x07 values, 0x0d VTE, 0x12, 0x14, 0x16 ...) | `RXUnreliableStream` |
| 4 | video *reply* channel, client -> host | built by `vrlink`; see below |
| 5 | video, host -> client | `SVLFEC::AcceptVideoPacket` |
| 6, 0xb, 0xc | audio | `SVLAudio::TransportRXAudioFrames` |
| 8 | debug message | `RXDebugMessage` |
| 9 / 10 | broadcast / broadcast reply | |

Klepton's `STEAMLINK.md` (section 3.1) notes a 16-bit header field
`kind=0x0d03`, which corresponds to these first two bytes read as a
little-endian `u16`: `kind = 3`, `type = 0x0d` (a `ValueTransportSystem`
message). **captured** (`vr3`): kind 3 / type `0x0d` elements arrive from the
host (6 messages of `12..216` bytes, all before the first video frame).

## Video messages

| Direction | kind | type | Name | Payload |
|---|---|---|---|---|
| host -> client | 5 | 2 | `SVST_VIDEO_TRANSPORT_DESCRIPTION` (frame descriptor / bookend) | [frame-descriptor.md](frame-descriptor.md) |
| host -> client | 5 | 3 | `SVST_VIDEO_TRANSPORT` (data or parity packet) | below |
| client -> host | 4 | 5 | retransmit request (`resend_fec_request`) | [retransmit.md](retransmit.md) |
| client -> host | 4 | 0x0f | frame report (`LastVideoPacket_t`) | [retransmit.md](retransmit.md) |

The `SVST_*` names come from `vrlink` log strings (**static**):
`"SVST_VIDEO_TRANSPORT_DESCRIPTION: WARNING: Could not initialize frame on
hardware."` is logged on the `type == 2` branch and `"SVST_VIDEO_TRANSPORT:
WARNING: ..."` on the `type == 3` branch of `SVLFEC::AcceptVideoPacket`
(+0x160684). The 16-bit header words written by the shared TX code are `0x0205`
(descriptor) and `0x0305` (data/parity) in
`SVLFECRAID6TXFrame::InitializeAndSend` (+0x1617a4) and `PopulateFecBlocks`
(+0x161518), while the two client messages write `0x0504` and `0x0f04`
(`SVLFECRXFrame::CheckRetry` +0x15f2cc, `SVLDataLink::SendLastRXID` +0x15c648).

## Data / parity packet (kind 5, type 3)

`SVLFECRXFrame::AcceptVideoPacket` (+0x15edc8) parses data and parity packets
with the following layout (**static**):

| Off | Type | Name | Notes |
|---|---|---|---|
| 0 | u8 | 5 | |
| 1 | u8 | 3 | |
| 2 | u16 | `frame_id` | Wraps at 16 bits. Slot = `frame_id & 0xf` |
| 4 | u16 | `len` | 0x400 for every packet except the last data packet of the frame |
| 6 | u16 | `packet_id` | 0x000..0x7ff = data, 0x800..0xfff = parity; >= 0x1000 is rejected with `"Warning: received packet ID %d in frame %d, but packet id exceeded max frame size"` |
| 8 | u8[len] | payload | |

- Data packet `n` carries bytes `[n*1024, n*1024 + len)` of the encoded frame.
  `vrlink` copies it via `memcpy` to `m_pData + n*1024`, where `m_pData` points
  directly into the MediaCodec input buffer (see
  [decode-handoff.md](decode-handoff.md)).
- Parity packet `0x800 + p` is stored in a per-slot 2 MiB side buffer at
  `p * 1024`. Parity packets are always 1024 bytes on the TX side.
- Duplicate packets (whose bit is already set in the per-frame bitmap) are
  dropped silently.
- **Frame length before the descriptor arrives:** if the slot has not yet
  received a descriptor, any packet with `len != 0x400` sets `frame_size =
  packet_id * 1024 + len`, so the short final packet also acts as an
  end-of-frame marker. When a frame's byte length is an exact multiple of 1024,
  there is no short packet and its size is known only from the descriptor.
- After storing the payload, the per-FEC hook `ReceivedVideoPacket(packet_id,
  now)` runs (see [fec.md](fec.md)); then, if the packet's *group* exceeds any
  group previously seen for this frame, `CheckRetry(group)` runs (see
  [retransmit.md](retransmit.md)). Group index is `packet_id / 64` for data
  packets and `(packet_id - 0x800) / 16` for parity packets.

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

`SVLFECRAID6TXFrame::InitializeAndSend` (+0x1617a4) transmits each frame in the
order below (**static** in the shared TX code), and **captured** traffic
matches: 4,259 of the 4,260 frames in `vr3` arrived in this exact
element-by-element sequence (frame 8 lost its closing bookend on the wire; see
"Captured" below):

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

- Column-major interleaving places consecutive datagrams into different
  stripes, so a burst loss of up to 8 consecutive data packets drops at most
  one packet per stripe.
- In the shared TX code (**static**), `InitializeAndSend` reads the peer's
  `cRXpass` `SVLRoot` value at the top of the function and sets `q_enabled`
  (`this+0x4480`) if `cRXpass` fell below `99.99%` at any point within the last
  10 s. On a clean link, only XOR parity (P) is sent (12.5% FEC overhead); with
  Q enabled, FEC overhead is 25%. **captured**: the host sends Q on every frame
  for the first 8.64 s of a stream even though `vrlink` never reported
  `cRXpass` below `100`, then sends P only (see "Captured" below).
- The TX code rejects any frame exceeding its allocated packet count with
  `"FAULT: Packet too big!!! Can't send!!! Dropping"`.

## Captured

Capture `vr3` (omitted from the repo because it contains live credentials)
records `vrlink` on a wired-quality LAN over 39.33 s of video: 60,945 kind-5
elements across 59,668 intact datagrams, each stamped with a client
`CLOCK_MONOTONIC` receive timestamp. Everything in this section is
**captured**. Below, "arrival" refers to those client receive timestamps and
"tx" refers to the host's `tx_time` from the frame descriptor
([frame-descriptor.md](frame-descriptor.md)).

An earlier capture (`vr1`) had a third of its datagrams truncated; its lower
bounds are superseded by the figures below.

### Header, lengths, reassembly

- Every message uses the 8-byte `dataset` header tabled above: 52,314 `05 03`
  elements (43,910 data and 8,404 parity, with `len` in `1..1024`) and 8,631
  `05 02` descriptor elements (each with 1016 bytes of payload).
- All 4,260 frames (`frame_id` `0..4259`, with no gaps) arrive sequentially
  without interleaving: every element of frame `n` arrives before the first
  element of frame `n+1`, and transport datagram sequence numbers rise
  monotonically inside every frame.
- Across all 4,260 frames without exception, `len == 1024` on every data packet
  except the highest `packet_id` of the frame, where `packet_id * 1024 + len ==
  frame_size` matches the descriptor. None of the captured frames had a byte
  length that was an exact multiple of 1024. Every parity packet has `len ==
  1024`.
- Zero data packets were lost or duplicated, so all 4,260 frames reassemble
  from data packets alone. Concatenated in `frame_id` order, frames `0..4258`
  are **byte-identical to the elementary stream `vrlink` fed to its decoder**
  (`KL_VTDEC_DUMP`) from byte 0 onward.
- Frame 4259 (the final frame of the capture) is truncated in the dump file,
  which ends after the first 6,155 of its 7,724 bytes. Because the dump file's
  length is an exact multiple of 4096 bytes, `vrlink` was terminated before
  flushing its final buffered write (the dump's index file is similarly cut
  short at 4,220 lines).
- Most datagrams carry a single video element, while 1,277 datagrams carry two:
  the frame's short final data packet shares a datagram with the element sent
  immediately before it (1,275 times, a full data packet) or immediately after
  it (twice, a parity packet). Coalescing occurs whenever the short packet
  payload is 328 bytes or smaller, whereas every short packet of 329 bytes or
  more (2,983 frames) travels in its own datagram—capping coalesced element
  bytes at 1,368 bytes per datagram. Whether coalescing lives in the video
  layer or transport layer is covered in `docs/svl-transport/`.

### Send order

- Within a frame, element arrival order matches the pseudocode in "Send order
  for one frame" in 4,259 of 4,260 frames: bookend 0, followed for each group
  by column-major data packets, P parity packets for each stripe, Q parity
  packets for each stripe (when Q is active), and bookend `g+1`. For example,
  frame 8 (9,863 bytes, 10 data packets) arrived as `B0 d0 d8 d1 d9 d2 d3 d4 d5
  d6 d7 P0 P1 Q0 Q1`.
- Frame 8 is the sole exception: its closing bookend never arrived, coinciding
  with the single gap in inbound transport sequence numbers across all 62,589
  datagrams. Because frame 8's data packets were already complete, `vrlink`
  took no action and the host did not resend the bookend.
- Frame 64—the largest frame in the capture (283,768 bytes, 278 data packets,
  5 groups, 354 elements across 353 consecutive datagrams, spanning 13.75 ms
  from first to last arrival)—illustrates a complete multi-group send sequence:

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

  Group 4's partial data run (`256..277`) shows how column-major ordering works
  on a partially filled group: each column simply skips `packet_id` values at
  or beyond `n_data`. Groups are transmitted back to back without a noticeable
  pause: the 68 multi-group frames arrive at `19..34` elements/ms (median `25`),
  or roughly one group every 3 ms.
- Bookend count per frame is `1 + n_group` with no repeats; counts by group
  number are `0` x4260, `1` x4259, `2` x68, `3` x42, `4` x1, and `5` x1.

### P and Q parity

- **`vr1` suggested Q parity was sent only under packet loss, whereas `vr3`
  shows Q parity on a clean link at startup.** Frames `0..941`—the first 8.64 s
  of video by the host's clock—carry both P and Q on every stripe (2,322 Q
  packets). Frames `942..4259` (the remaining 30.7 s) carry P only. Across the
  entire run there are 6,082 P packets (one per stripe of every frame), and no
  stripe ever carries Q without P.
- Throughout those initial 8.64 s, `vrlink` reported `cRXpass = 100` in every
  sample (732 samples, starting 13 ms before the first video packet), sent zero
  retransmit requests, and lost only frame 8's closing bookend. The initial Q
  window therefore occurred without data loss. **inferred**: the host begins a
  stream with its "recent loss" flag set (or treats `cRXpass` as below `99.99`
  until the first client sample is processed) and lets the TX code's 10 s timer
  expire—which would place timer start ~1.36 s before frame 0, prior to the
  first captured SVL element. Directly measured on the wire, Q parity is sent
  for the first 8.64 s and omitted afterward.
- Clients should expect Q parity from frame 0 and should not treat odd parity
  packet ids as an error indicator.

### Frame sizes and timing

The table below summarizes 40 s of a mostly static SteamVR dashboard scene at a
120 Hz nominal target; these numbers reflect a single capture rather than
protocol limits.

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

- Rounded to 1 ms, the inter-frame interval histogram has no sharp peak at
  8.33 ms: `8 ms` x769, `9 ms` x1707, `10 ms` x1658, plus `7 ms` x54 and
  `11 ms` x51. The host paced this run at roughly 108 frames/s rather than 120;
  host frame pacing is analyzed in `docs/svl-timing/`.
- The two long `tx_time` gaps occur near startup: `31.4 ms` before frame 15 and
  `40.8 ms` before frame 23. After frame 140, every interval stays within
  `6.5..12 ms`.
- Frame sizes start small (`0..43`: `536 bytes .. 62 kB`), spike during a
  0.64 s burst (`44..112`: `51..284 kB`, averaging 116 Mbit/s), decay (`15 kB`
  by frame 120), and settle around `7.7 kB` per frame. The largest frame (frame
  64) is a P frame rather than an IDR; the two IDRs in `vr3` are 2,512 and
  2,378 bytes ([retransmit.md](retransmit.md)).
- Client arrival timestamps on frames `0..11` do not reflect wire pacing
  because `vrlink`'s receive thread stalled for 111 ms right after storing the
  final data packet of frame 0 (when frame 0 was queued to the decoder). Host
  `tx_time` values show frames `0..11` went out at a steady ~7 ms cadence and
  were drained in a 24 ms burst once the thread resumed, while `vrlink`'s
  outgoing pose thread kept sending on schedule. **inferred**: MediaCodec
  startup blocked `vrlink`'s receive thread locally rather than any pause
  occurring on the wire.

## Open questions / to confirm on the wire

1. Where the extra 4 bytes in `vrlink`'s `len + 0xc` byte logger come from
   (wire datagrams carry a shared 8-byte transport prefix across all datasets
   in the datagram, so `+ 0xc` is likely an approximation in `ByteLogger`).
2. What starts and ends the Q-parity window: whether it is a fixed 10 s timer
   from stream setup, and whether reporting `cRXpass < 99.99` from the client
   re-enables Q parity mid-stream (testable with a probe that reports a low
   `cRXpass` or drops packets).
3. Whether a host ever attempts to send a frame larger than 2 MiB (where packet
   ids would exceed `0x7ff`, which `vrlink` rejects); the largest frame seen in
   `vr3` is 283,768 bytes.
4. Observing a frame whose encoded size is an exact multiple of 1024 bytes (no
   short final packet, so `frame_size` comes solely from the descriptor); none
   occurred among the 4,260 frames in `vr3`.
5. Whether the 1,368-byte datagram coalescing threshold is hardcoded or derived
   from a negotiated MTU.
