# Video FEC: `SVLFECRAID6`

`SVLFECRAID6` is the only FEC implementation in `libvrlink_scene.so`.
`SVLDataLink::SVLDataLink` (+0x15a000) constructs `SVLFECRAID6(root, 0x20)`
unconditionally (**static**), and every frame descriptor echoes the mode byte
`0x20` at offset `+0x15`.

It uses a RAID-6 erasure code from the open-source **jerasure** library based on
Plank's **Liber8tion** bit-matrix code ("The RAID-6 Liber8tion Code"), which
performs XOR operations only with no Galois-field multiplication. Although
`libvrlink_scene.so` exports `galois_*` symbols from the rest of jerasure
(`galois_single_multiply` +0x19fe40, etc.), the video FEC never calls them
(**static**: the constructor calls only `liber8tion_coding_bitmatrix`,
`jerasure_smart_bitmatrix_to_schedule`, and `jerasure_generate_schedule_cache`;
encoding uses `jerasure_schedule_encode` and decoding uses
`jerasure_schedule_decode_cache`).

## Geometry

`SVLFECRAID6::SVLFECRAID6` (+0x161e90) stores the following geometry constants
(**static**):

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

Each 1024-byte packet is one jerasure "device" consisting of `w = 8` sub-blocks
of 128 bytes, where sub-block `c` spans bytes `[128*c, 128*c + 128)`. jerasure
is called with `size = 128 * 8 = 1024` and `packetsize = 128`.

Stripe `s` consists of data packets `8s .. 8s+7` (devices 0..7) plus parity
packets `0x800 + 2s` (device 8, "P") and `0x800 + 2s + 1` (device 9, "Q").

## Liber8tion bit-matrix code

The parity equations below are transcribed from `liber8tion_coding_bitmatrix`
(+0x1a1da0) with `k = 8` (**static**) and verified by testing the Python
implementation below across all 55 single- and double-erasure patterns (all
recover). The Q half of the bit-matrix has 71 ones, matching the Liber8tion
minimum (`k*w + k - 1`).

Let `D[j][c]` be sub-block `c` of data packet `j` within the stripe:

- **P** is plain XOR: `P[i] = D[0][i] ^ D[1][i] ^ ... ^ D[7][i]`. Parity packet
  `0x800 + 2s` is the byte-wise XOR of the stripe's eight data packets, so a
  client implementing P alone can repair any single lost data packet per stripe
  whenever P arrives.
- **Q** is a permuted sub-block XOR: `Q[r] = XOR over j of D[j][ Q_PERM[j][r] ]`,
  plus one extra term per device `j >= 1`: `Q[er] ^= D[j][ec]` where
  `(er, ec) = Q_EXTRA[j]`.

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

jerasure runs a precomputed XOR schedule
(`jerasure_generate_schedule_cache(8, 2, 8, bitmatrix, 1)`), which solves the
same linear system, so any valid GF(2) solver is wire-compatible.

**captured** (details below): the host's parity packets match `encode()` byte
for byte across both P and Q.

## Padding rules

Padding on the final stripe works as follows (**static** unless marked):

- On encode (`SVLFECRAID6TXFrame::PopulateFecBlocks` +0x161518), a stripe is
  encoded only if its first data packet starts within `frame_size`. Data blocks
  starting at or beyond `frame_size` are replaced by all-zero 1024-byte blocks.
  In the sender's buffer, the last real data packet is zero-padded out to 1024
  bytes (`InitializeAndSend` memsets the tail) even though only `len` bytes are
  transmitted on the wire.
- On decode (`SVLFECRAID6RXFrame::ReceivedVideoPacket` +0x160de0), before
  running jerasure, if `frame_size` is known and the frame's final data packet
  is present in the stripe, `vrlink` zeroes its tail `[frame_size, next 1024
  boundary)` in the frame buffer.
- **Phantom erasures on the final stripe (**inferred** from static code):**
  `vrlink` never marks data packets that lie completely beyond `frame_size` as
  received, so it counts them as *erased*. The final stripe of a frame
  therefore starts with `8 - n_real` phantom erasures, meaning `vrlink` can
  only repair it via FEC when `(8 - n_real) + really_missing <= 2`—that is,
  only when the final stripe holds 6, 7, or 8 real packets. Shorter final
  stripes rely on retransmission in `vrlink`. A third-party client can improve
  on this while remaining wire-compatible by passing known 1024-byte zero
  blocks for out-of-range slots (as `decode()` above does when given
  `bytes(1024)`).

## Receive algorithm

`SVLFECRAID6RXFrame::ReceivedVideoPacket(packet_id, now)` runs after storing
every data or parity packet (**static**):

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

- Decoding writes recovered data directly into the decoder input buffer at
  `n * 1024` and regenerates missing parity blocks in place.
- `SVLFECRAID6RXFrame::CheckRXComplete` (+0x161264) considers a frame complete
  when it has not yet been accepted or submitted, `frame_size != 0`, and the
  contiguous received prefix of data packets (`this+0x1a`) is at least
  `ceil(frame_size / 1024)`. Once complete, it calls
  `SVLFEC::InternalAcceptFrameFromRX(size, &buffer, frame_id)` and records
  timing event `0x4c`. See [retransmit.md](retransmit.md) for frame ordering
  and [decode-handoff.md](decode-handoff.md) for decoder submission.

## Captured

In `vr3` (not in the repo), all 4,260 frames arrived with zero lost data
packets and 8,404 parity packets. Running `encode()` and `decode()` above
against every stripe of every frame yields the following results (all
**captured**):

- Across all 6,082 stripes in the capture, every stripe has a P packet and
  2,322 stripes also have a Q packet (the host sent Q only during the first
  8.64 s; see [packets.md](packets.md)). The host's parity matches `encode()`
  in every instance:

  | | stripes checked | equal to `encode()` |
  |---|---|---|
  | P, full stripe (8 real data packets) | 5,063 | 5,063 |
  | P, short last stripe (1..7 real data packets) | 1,019 | 1,019 |
  | Q, full stripe | 2,000 | 2,000 |
  | Q, short last stripe | 322 | 322 |
  | **total parity packets** | **8,404** | **8,404** |

  This confirms the stripe geometry (`8 + 2`, 1024-byte packets, 128-byte
  sub-blocks), the assignment of P and Q to even and odd parity ids, `Q_PERM`
  and `Q_EXTRA`, and sub-block byte ordering across full stripes (`vr1` had
  only 4 P and 5 Q intact samples, none of them a complete stripe carrying both
  parities).
- Across all 1,019 short final stripes (real data packet counts per short
  stripe: `1` x332, `2` x211, `3` x147, `4` x15, `5` x11, `6` x25, `7` x278),
  the short final packet is zero-extended to 1024 bytes and data blocks past
  `frame_size` are treated as all-zero blocks. Parity packets are always 1024
  bytes on the wire, even on a single-packet 302-byte frame.
- A stripe carries parity if and only if its first data packet starts inside
  `frame_size`: in every frame, the set of P packet ids is `0x800 + 2s` for
  `s = 0 .. ceil(n_data / 8) - 1`, with no extra or missing stripes.
- Because `vr3` had no lost data packets, decoding was verified by simulating
  erasures against the host's captured parity. Across 300 randomly sampled
  stripes carrying both P and Q, dropping one or two of the ten blocks at
  random and running `decode()` recovered the exact original data bytes in 300
  of 300 single-erasure trials and 300 of 300 double-erasure trials. Live FEC
  repair of an actual wire loss verified against decoder input was observed
  once in `vr1` (one frame with one missing data packet).
- `fec_mode` is `0x20` on all 8,631 descriptors.

## Open questions / to confirm on the wire

1. Whether any host build uses a `fec_mode` value other than `0x20`.
2. Observing a live (non-simulated) two-erasure recovery on `vrlink`, along
   with `vrlink`'s behavior when the final stripe has phantom erasures (see
   "Padding rules" above), which requires a lossy link or a packet-dropping
   proxy.
