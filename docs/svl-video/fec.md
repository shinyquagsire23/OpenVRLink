# Video FEC - `SVLFECRAID6`

The only FEC in this build. `SVLDataLink::SVLDataLink` (+0x15a000) constructs
`SVLFECRAID6(root, 0x20)` unconditionally (**static**); the mode byte 0x20 is
echoed in every frame descriptor (+0x15).

It is a RAID-6 erasure code from the open-source **jerasure** library, using the
**Liber8tion** bit-matrix code (Plank, "The RAID-6 Liber8tion Code"): XOR only,
no Galois-field multiplication on this path. The `galois_*` exports in the
library (`galois_single_multiply` +0x19fe40 etc.) are the rest of jerasure and
are **not** called by the video FEC (**static**: the constructor calls only
`liber8tion_coding_bitmatrix`, `jerasure_smart_bitmatrix_to_schedule`,
`jerasure_generate_schedule_cache`; encode is `jerasure_schedule_encode`,
decode is `jerasure_schedule_decode_cache`).

## Geometry

**static** - constants stored by `SVLFECRAID6::SVLFECRAID6` (+0x161e90):

| Field (SVLFEC+) | Value | Meaning |
|---|---|---|
| 0xc38 | 80 | used only in TX pacing arithmetic |
| 0xc3a | 10 | devices per stripe (k + m) |
| 0xc3c | 8 | k - data packets per stripe |
| 0xc3e | 2 | m - parity packets per stripe |
| 0xc40 | 8 | stripes per group |
| 0xc42 | 16 | parity packets per group |
| 0xc44 | 64 | data packets per group |
| 0xdb8 | 8 | w - word size (sub-blocks per packet) |
| 0xdba | 128 | jerasure `packetsize` - bytes per sub-block |

So each 1024-byte packet is one jerasure "device" made of w = 8 sub-blocks of
128 bytes: sub-block `c` of a packet is bytes `[128*c, 128*c + 128)`.
jerasure is called with `size = 128 * 8 = 1024`, `packetsize = 128`.

Stripe `s` = data packets `8s .. 8s+7` (devices 0..7) and parity packets
`0x800 + 2s` (device 8, "P") and `0x800 + 2s + 1` (device 9, "Q").

## The code

**static** - transcribed from `liber8tion_coding_bitmatrix` (+0x1a1da0) with
k = 8, and checked by running the Python below over all 55 one- and two-erasure
patterns (all recover). The matrix has 71 ones in the Q half, the Liber8tion
minimum (`k*w + k - 1`).

Let `D[j][c]` be sub-block `c` of data packet `j` of the stripe.

- **P** is plain XOR: `P[i] = D[0][i] ^ D[1][i] ^ ... ^ D[7][i]`. In other words
  parity packet `0x800 + 2s` is the byte-wise XOR of the stripe's eight data
  packets. A client that only implements this can already repair any single
  loss per stripe whenever P arrived.
- **Q**: `Q[r] = XOR over j of D[j][ Q_PERM[j][r] ]`, plus one extra term per
  device `j >= 1`: `Q[er] ^= D[j][ec]` with `(er, ec) = Q_EXTRA[j]`.

```python
K, M, W, PS = 8, 2, 8, 128

Q_PERM = [            # Q_PERM[j][r] = sub-block of data packet j feeding Q sub-block r
    [0,1,2,3,4,5,6,7],
    [7,3,0,2,6,1,5,4],
    [6,2,4,0,7,3,1,5],
    [2,5,7,6,0,3,4,1],
    [5,6,1,7,2,4,3,0],
    [1,2,3,4,5,6,7,0],
    [3,0,6,5,1,7,4,2],
    [4,7,1,5,3,2,0,6],
]
Q_EXTRA = {1:(4,7), 2:(1,3), 3:(5,4), 4:(2,0), 5:(7,2), 6:(6,5), 7:(3,1)}   # j: (r, c)

def parity_rows():
    """16 parity sub-blocks (P0..P7, Q0..Q7), each the set of (j, c) XORed into it."""
    rows = [{(j, i) for j in range(K)} for i in range(W)]
    for r in range(W):
        s = {(j, Q_PERM[j][r]) for j in range(K)}
        for j, (er, ec) in Q_EXTRA.items():
            if er == r:
                s ^= {(j, ec)}
        rows.append(s)
    return rows
ROWS = parity_rows()

def xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b))

def encode(data):                      # data: 8 blocks of 1024 bytes -> [P, Q]
    out = []
    for dev in range(M):
        blk = b''
        for i in range(W):
            acc = bytes(PS)
            for (j, c) in ROWS[dev*W + i]:
                acc = xor(acc, data[j][c*PS:(c+1)*PS])
            blk += acc
        out.append(blk)
    return out

def decode(blocks):
    """blocks: 10 entries (8 data, P, Q), each 1024 bytes or None. Returns the 8 data blocks.
    Works for any <= 2 missing entries. Plain GF(2) Gaussian elimination on 128-byte symbols."""
    erased = [j for j in range(K) if blocks[j] is None]
    if not erased:
        return blocks[:K]
    unk = [(j, c) for j in erased for c in range(W)]
    idx = {u: n for n, u in enumerate(unk)}
    eqs = []                                           # [bitmask over unknowns, rhs bytes]
    for dev in range(M):
        if blocks[K+dev] is None:
            continue
        for i in range(W):
            mask, rhs = 0, blocks[K+dev][i*PS:(i+1)*PS]
            for (j, c) in ROWS[dev*W + i]:
                if (j, c) in idx: mask |= 1 << idx[(j, c)]
                else:             rhs = xor(rhs, blocks[j][c*PS:(c+1)*PS])
            eqs.append([mask, rhs])
    row = 0
    for col in range(len(unk)):
        p = next((r for r in range(row, len(eqs)) if eqs[r][0] >> col & 1), None)
        if p is None:
            raise ValueError('unrecoverable')
        eqs[row], eqs[p] = eqs[p], eqs[row]
        for r in range(len(eqs)):
            if r != row and eqs[r][0] >> col & 1:
                eqs[r][0] ^= eqs[row][0]
                eqs[r][1] = xor(eqs[r][1], eqs[row][1])
        row += 1
    sol = {unk[e[0].bit_length() - 1]: e[1] for e in eqs[:len(unk)]}
    out = list(blocks[:K])
    for j in erased:
        out[j] = b''.join(sol[(j, c)] for c in range(W))
    return out
```

jerasure itself runs a precomputed XOR schedule
(`jerasure_generate_schedule_cache(8, 2, 8, bitmatrix, 1)`); the result is the
same linear system, so any correct GF(2) solver is wire-compatible.

**captured** (details at the end): the host's parity bytes equal `encode()`
above, for both P and Q.

## Padding rules

**static** unless marked:

- Encode (`SVLFECRAID6TXFrame::PopulateFecBlocks` +0x161518): a stripe is encoded
  only if its first data packet starts inside the frame. Data blocks that start
  at or beyond `frame_size` are replaced by an all-zero 1024-byte block. The
  last real data packet is zero-padded to 1024 in the sender's buffer
  (`InitializeAndSend` memsets the tail) even though only `len` bytes are sent.
- Decode (`SVLFECRAID6RXFrame::ReceivedVideoPacket` +0x160de0): before decoding,
  for each *received* data packet of the stripe that is the frame's last
  packet, the client zeroes the tail `[frame_size, next 1024 boundary)` in the
  frame buffer. It does this only when `frame_size` is known.
- **Consequence (inferred from the code, worth knowing):** the client counts
  data packets of the stripe that lie entirely beyond the end of the frame as
  *erased* - nothing ever marks them received. The last stripe of a frame
  therefore has `8 - n_real` phantom erasures, and FEC can only help it when
  `phantom + really_missing <= 2`, i.e. the last stripe is FEC-protected only if
  it holds 6, 7 or 8 real packets. Otherwise losses there are repaired by
  retransmission. A new client should instead treat phantom blocks as known
  zeros (the `decode()` above does if you pass `bytes(1024)` for them), which
  is strictly better and still compatible.

## Receive algorithm

**static** - `SVLFECRAID6RXFrame::ReceivedVideoPacket(packet_id, now)`, called
after every stored data or parity packet:

```python
def received_video_packet(frame, packet_id, now):
    s = packet_id // 8 if packet_id < 0x800 else (packet_id - 0x800) // 2
    data_ids   = range(8*s, 8*s + 8)
    parity_ids = range(0x800 + 2*s, 0x800 + 2*s + 2)

    erasures = [i for i, n in enumerate(data_ids) if not frame.have(n)]
    if not erasures:                                   # all 8 data packets present
        for n in parity_ids: frame.mark_received(n, now)   # so parity is never re-requested
        return frame.check_rx_complete()

    erasures += [8 + i for i, n in enumerate(parity_ids) if not frame.have(n)]
    if len(erasures) >= 3:                             # not yet decodable
        return frame.check_rx_complete()

    zero_tail_of_last_packet_if_present(frame, data_ids)
    ok = jerasure_schedule_decode_cache(k=8, m=2, w=8, cache, erasures + [-1],
                                        data_ptrs, parity_ptrs, size=1024, packetsize=128)
    if ok == 0:
        for n in list(data_ids) + list(parity_ids): frame.mark_received(n, now)
    else:
        log("FEC decode fail %d %d %d", frame.id, s // 8, ok)
    return frame.check_rx_complete()
```

- Decoding writes recovered data straight into the decoder input buffer at
  `n * 1024` and regenerates missing parity in place.
- `SVLFECRAID6RXFrame::CheckRXComplete` (+0x161264): the frame is complete when
  it is not already accepted/submitted, `frame_size != 0`, and the contiguous
  received prefix of data packets (`this+0x1a`) is at least
  `ceil(frame_size / 1024)`. Then `SVLFEC::InternalAcceptFrameFromRX(size,
  &buffer, frame_id)` and timing event 0x4c. See
  [retransmit.md](retransmit.md) for ordering and [decode-handoff.md](decode-handoff.md).

## Captured

Capture `vr3` (not in the repo): 4,260 complete frames, no data packet lost,
8,404 parity packets. The `encode()` / `decode()` above (the same code as the
scratch file used for `vr1`) were run against every stripe of every frame.
Everything here is **captured**.

- Every stripe of every frame was checked: 6,082 stripes, each with its P
  packet; 2,322 of them also have Q (the host sent Q only for the first
  8.64 s, see [packets.md](packets.md)). The host's parity equals `encode()`
  in every case:

  | | stripes checked | equal to `encode()` |
  |---|---|---|
  | P, full stripe (8 real data packets) | 5,063 | 5,063 |
  | P, short last stripe (1..7 real data packets) | 1,019 | 1,019 |
  | Q, full stripe | 2,000 | 2,000 |
  | Q, short last stripe | 322 | 322 |
  | **total parity packets** | **8,404** | **8,404** |

  That confirms the geometry (8 + 2, 1024-byte packets, 128-byte
  sub-blocks), the P/Q assignment to even/odd parity ids, `Q_PERM` /
  `Q_EXTRA`, and the sub-block byte order, now over full stripes (vr1 only
  had 4 P and 5 Q samples, none of them a full stripe with both parities).
- Padding rule, over the 1,019 short last stripes (real data packets per
  short stripe: 1 x332, 2 x211, 3 x147, 4 x15, 5 x11, 6 x25, 7 x278): the
  short last packet is zero-extended to 1024 and data blocks beyond the end
  of the frame are all-zero blocks. Parity packets are always 1024 bytes on
  the wire, also for a single-packet frame of 302 bytes.
- A stripe has parity exactly when its first data packet starts inside the
  frame: in every frame the set of P ids is `0x800 + 2s` for
  `s = 0 .. ceil(n_data / 8) - 1`, no more and no fewer.
- Decode against host parity: nothing was lost in this capture, so erasures
  were simulated. From 300 stripes that have both P and Q (sampled at
  random), one and then two of the ten blocks were dropped at random and the
  stripe rebuilt with `decode()` from the host's own parity: 300 of 300
  single erasures and 300 of 300 double erasures recovered the original data
  bytes. A real loss repaired by FEC and then matched against the decoder
  input was seen once in `vr1` (one frame, one missing data packet).
- `fec_mode` is 0x20 on all 8,631 descriptors.

## Open questions / to confirm on the wire

1. Whether any host build uses a `fec_mode` other than 0x20.
2. A real (not simulated) two-erasure recovery, and what the client does
   when the last stripe has "phantom" erasures (see "Padding rules") - needs a
   lossy link or a probe that drops packets.
