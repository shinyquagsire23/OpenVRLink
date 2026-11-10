# SVL datagram and element format

> **Status: CAPTURED.** Verified against capture `vr3`, a real mode‑1 (XOR0)
> streaming session: 80,035 SVL datagrams (17,446 client→host, 62,589
> host→client), none torn. Every one parses exactly with the layout below
> (0 bytes left over, `res == 0` on every one), and the §3 checksum folds to
> zero for every datagram in both directions with a single session id.
> The AES (mode‑2) framing has since been exercised by the probe and the
> Swift client against a host with streaming encryption on: padding to 16
> bytes, whole-datagram encryption and the `0x02` tag byte all hold. Key and
> IV details are in `session-args-and-crypto.md`.

Source: `SVLDataLinkUDP::InternalTX` (`+0x167fbc`, TX framing),
`SVLDataLinkUDP::RXThread` (`+0x16709c`, RX parse/validate),
`SVLDataLinkUDP::XMITData` (`+0x1683f8`, element packing),
`SVLDataLinkUDP::Init` (`+0x166b4c`, header length), ctor (`+0x1669d0`, buffer
size + sideband magic), `SVLDataLink::ReceivedData` (`+0x15a9b8`, element
loop). All **static**.

## 1. Transport header (per UDP datagram)

The header length is set by `Init` from the mode (`this+0x1ec`/`this+0x1f0`):
mode 0 → `0x00000004_00000004` (header = 4), modes 1 and 2 →
`0x00000008_00000008` (header = 8). **static** `+0x166b4c`.

All multi-byte fields are **little-endian**.

### Mode 0 (open) — 4-byte header
| off | size | field | value |
|-----|------|-------|-------|
| 0   | u16  | `seq` | sequence counter (see §4) |
| 2   | u16  | `res` | **must be 0**; RX rejects nonzero ("res field incorrect [clear mode] %04x") |
| 4   | …    | payload | element list |

### Mode 1 (XOR0) — 8-byte header
| off | size | field | value |
|-----|------|-------|-------|
| 0   | u16  | `seq` | sequence counter |
| 2   | u16  | `res` | 0 |
| 4   | u32  | `xorcheck` | integrity word (§3) |
| 8   | …    | payload | element list |

### Mode 2 (AES) — 8-byte header, whole datagram encrypted
| off | size | field (post-decrypt) | value |
|-----|------|----------------------|-------|
| 0   | u16  | `seq` | sequence counter |
| 2   | u16  | `res` | 0 |
| 4   | u32  | `tagcounter` | `(counter & 0x00ffffff) | 0x02000000` |
| 8   | …    | payload | element list |

In mode 2 the entire datagram (header included) is AES-128-CBC encrypted and
zero-padded up to a 16-byte multiple before send (`uVar19 = (len + 0x13) &
~0xf`, `memset` of the pad). On RX the datagram length must be a multiple of 16
(`recvlen & 0xf == 0`), it is decrypted, then **byte 7** (top byte of
`tagcounter`) must equal `0x02` ("packet received with wrong identifier.
Expected 0x02...... got: %08x") and the low res/counter check must pass ("res
field incorrect [encryption mode]"). `counter` (24-bit) increments only when
`seq` wraps through 0, so it works as a rollover counter and mode tag, and is
not used as a CBC nonce.

Max datagram: TX buffer is `malloc(0x5a0)` = 1440 B, the usable cap
`this+0x1e8 = 0x580` = **1408 B** (ctor `+0x1669d0`). RX `recvfrom` buffer is
`0x824` = 2084 B (`+0x16709c`). **Captured** (`vr3`): client→host datagrams
are 512..881 B (537 B for 17,037 of 17,446: the steady-state pose datagram);
host→client 28..1376 B (1040 B = one full video packet for 48,775; 1032 B =
one frame descriptor for 8,621). All sit under the 1408 cap.

## 2. Element ("id/len/value triple") format

The payload is a back-to-back list of elements. `ReceivedData`'s loop and
`XMITData` agree on an **8-byte element header**:

| off | size | field | notes |
|-----|------|-------|-------|
| 0   | u8   | `class` | the channel; `ReceivedData` switches on it (`packet-types.md`) |
| 1   | u8   | `type` | sub-type within the class |
| 2   | u16  | `id` | per-class: reliable sequence id (class 2), video frame id (class 5); 0 on most others |
| 4   | u16  | `len` | value length, **≤ 0x400 (1024)** |
| 6   | u16  | `index` | per-class: video packet id within the frame (0x000–0x7ff data, 0x800+ parity), descriptor group number; see `../svl-video/packets.md` |
| 8   | len  | `value` | payload |

This is the `dataset` header the upper layers use (`GenSimpleDataset`,
+0x155bc4). Older text in this folder calls bytes 0–1 a single u16 `kind`
(low byte = class, high byte = type), offset 2 `seqid` and offset 6 `field6`;
they are the same fields.

Element total size = `len + 8`. **Captured** (`vr3`): `len` is a true u16 — a
`u32` read at offset 4 would swallow `index` and fail to parse (all 80,035
datagrams parse exactly with u16 `len`). The largest `len` seen is 1024 (a full
video packet). `id` and `index` are genuine per-element fields: both are 0 on
every class 3 and class 8 element in either direction; class 4 type 0x0f
(frame report) carries frame ids in both; class 5 carries the frame id in `id`
and the packet id / descriptor group in `index`; class 0xc (audio) carries a
running counter in `id` (0..2912 over 2,913 messages).

A datagram carries 1–4 elements back to back. What `vr3` contained
(**captured**; `class/type`):

| direction | elements, in order | datagrams |
|---|---|---|
| C→H | `3/0x11` `3/0x07` `4/0x0f` `3/0x01` | 17,043 (every datagram from 0.930 s on) |
| C→H | `3/0x07` `4/0x0f` `3/0x01` | 401 (before the first frame descriptor arrived) |
| C→H | `4/0x0f` `3/0x01` | 2 (the first two datagrams, 736 and 779 B) |
| H→C | `5/0x03` | 49,760 |
| H→C | `5/0x03` `5/0x03` | 1,277 |
| H→C | `5/0x02` | 8,616 |
| H→C | `3/0x18` `5/0x02` | 16 |
| H→C | `0xc/0x10` | 2,909 |
| H→C | `3/0x18` `0xc/0x10` or `0xc/0x10` `3/0x18` | 4 |
| H→C | `3/0x0d` | 6 |
| H→C | `8/0x06` | 1 |

So the client batches everything it has into one datagram per pose tick, and
the host sends almost every element in a datagram of its own.

RX loop (**static**, `RXThread` `+0x16709c` → `ReceivedData`):

```python
p = payload           # offset 4 (mode0) or 8 (modes 1/2)
remaining = recvlen - header_len
while remaining >= 8:
    length = u16(p[4:6]); elem = length + 8
    if p[0] != 0:                      # class 0: skipped, the scan goes on
        if remaining < elem or length > 0x400:
            log("WARNING: Corrupt UDP packet went long (...)"); break
        ReceivedData(p)                # dispatch by class
    p += elem; remaining -= elem
```

An element whose class byte is 0 is stepped over using its own `len`, not
treated as a terminator (an earlier version of this page said the scan stops
there; the loop at `+0x16709c` only skips the `ReceivedData` call). All-zero
padding therefore advances 8 bytes at a time to the end of the datagram, which
is how mode‑2 padding is consumed. No class‑0 element occurs in `vr3`.
A worked example from Klepton §3.1: one datagram with `kind=0x0d03
payload_len=168` carrying eight VTS triples summing to 168 — those triples live
*inside* an element's value and belong to the VTS layer, not this transport.

## 3. XOR0 integrity word (mode 1) — CAPTURED

**Confirmed on the wire** (`vr3`, all 80,035 datagrams). For every captured
datagram (both directions, session id `0x01xxxxxx`): folding all u32 LE words of the *received* datagram —
checksum word included — seeded with the session id yields **0**; and clearing
the checksum field, folding the rest seeded with the session id, reproduces the
stored checksum exactly. The host seeds with the **same** session id as the
client. 20,422 of the datagrams have a length that is not a multiple of 4, so
the zero-padding rule in the code below is exercised as well.

Both TX (`InternalTX`) and RX (`RXThread`) compute the same thing: a 32-bit XOR
fold over the whole datagram, seeded with the session id. TX writes it at
offset 4; RX recomputes over the received bytes and requires the result to be 0
(the stored word XORs itself out).

```python
def xor0_checksum(datagram_without_check, session_id):
    buf = bytearray(datagram_without_check)
    buf[4:8] = b"\x00\x00\x00\x00"          # clear the field first
    while len(buf) % 4: buf.append(0)        # zero-pad to u32 multiple
    acc = session_id                         # 0x01xxxxxx
    for i in range(0, len(buf), 4):
        acc ^= u32(buf[i:i+4])
    return acc                               # write to offset 4

# RX validity: fold(session_id, whole received datagram incl. stored word) == 0
```

`seq` is reported for loss accounting via `ReportRXSeqid(seq & 0xffff, 0x10)`
once the checksum passes (see `reliable-stream.md`). On a bad fold the client
logs "received packet with invalid session ID (%08x/%08x/%08x)".

## 4. Sequence counter

`seq` (header offset 0, u16) comes from an atomic fetch-add at `this+0x2b4`
(`FUN_00304830(1, this+0x2b4)`, a load-exclusive/add-store-exclusive counter).
It increments once per **datagram** and wraps at 65536. Klepton saw "byte 0
cycling 0x00–0xff" — that is this counter's low byte. It is used only for
loss statistics, not retransmission.

**Captured** (`vr3`):

- The client's first datagram has `seq = 0` and every later one is the
  previous plus 1: 0..17445 over 17,446 datagrams, no gap, no repeat.
- The host's datagrams are likewise consecutive, 62,589 of them with no gap —
  but the first one the client received has `seq = 5`, not 0 (5..62593).
  **Inferred**: the host's counter belongs to a link object that had already
  sent (or tried to send) five datagrams before this client's first one
  arrived; it is not restarted when a client appears. A session against a host
  that has been streaming for a while should show a large first `seq`.
- Neither direction reached 65536 in 40 s, so the wrap itself has still not
  been seen on the wire.
- Each direction has its own counter; nothing echoes the peer's `seq`.

The receiver's use of `seq` (`ReportRXSeqid`) and what a restart at 0 does to
it are in `reliable-stream.md` §3. The teardown datagram is the one exception
to the counter: it is sent with `seq = 0xffff` (`connection-lifecycle.md` §6,
**static**).

## 5. The 12-byte sideband control packet

`HandleSidebandPacket` (`+0x167688`) and several RX branches send a fixed
12-byte control datagram, rate-limited to once per 500 ms:

| off | size | field | value |
|-----|------|-------|-------|
| 0   | u32  | `magic` | `0x459b4c34` (ctor `+0x1669d0`; on the wire LE: `34 4c 9b 45`) |
| 4   | u32  | `code` | SidebandEventType (see below) |
| 8   | u32  | `zero` | 0 |

**Not seen in `vr3`** (0 of 80,035 datagrams began with the magic
`34 4c 9b 45`, and no 12-byte datagram was sent or received on the socket at
all): the session was healthy, so the NAK path never fired. This frame remains
**static**-only.

Sent with `sendto(..., 0xc, MSG_NOSIGNAL, peer, 16)`. Codes sent by
`RXThread` (**static**, `+0x16709c`): `0x10` (XOR0 checksum did not fold to
zero — "invalid session ID"; also the AES "res field incorrect" case), `0x11`
(AES tag byte wrong, or clear-mode `res != 0`), `0x13` (a datagram arrived
from an IP address other than the current peer's, more than 4 s after the last
peer change and more than 1 s after the last rejected packet, while the
current peer has been heard from within 3 s), and the value of `this+0x2c0`
when that field is non-zero (the datagram is then dropped unparsed). RX also *receives*
12-byte packets: if bytes 0–3 equal the local `magic` and the source matches
the peer, it calls a handler with `code` (vtable+0x90). These are keepalive /
NAK signaling, not data.

**Note:** the LAN discovery probe is also 12 bytes, but it is a normal
clear-mode SVL packet (4-byte header + one kind-9 element) and does not use the
magic sideband format. See `lan-scanner.md`.

## Open questions / to confirm on the wire

Resolved by `vr3`: 8‑byte header, `res == 0`, u16 `len`, the XOR0 fold (folds
to 0; same session id both ways), 1–4 elements per datagram, `seq` starting at
0 on the client and advancing by exactly 1 per datagram in both directions.

Still open:
- Whether `seq`/`res` is really u16+u16 or a single u32. `vr3` is consistent
  with both (max seq 62,593 < 65536, high half always 0); the static read
  (`seq` written as a `short`, `ReportRXSeqid(seq & 0xffff, 16)`) says u16. A
  session longer than about 55 s at the host's rate would show the wrap.
- Why the host's first datagram carried `seq = 5`, and whether that number
  grows with the host's uptime (see §4).
- **mode 2 (AES)** was not exercised: padding to 16 B, whole-datagram
  encryption, and the `0x02` post-decrypt tag byte are still static-only.
- The 12‑byte sideband frame (magic `0x459b4c34`, codes {0x10,0x11,0x13}) was
  not seen; what sets `this+0x2c0` and what the receiving handler
  (vtable+0x90) does with each code are not read.
