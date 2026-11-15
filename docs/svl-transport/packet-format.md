# SVL datagram and element format

> **Status: CAPTURED.** Verified against capture `vr3`, a mode-1 (XOR0)
> streaming session containing 80,035 intact SVL datagrams (17,446 client→host,
> 62,589 host→client). Every datagram parses cleanly with the layout below (0
> trailing bytes and `res == 0` on every packet), and the §3 checksum folds to
> zero in both directions using a single session ID. The AES (mode-2) framing
> has also been verified by the probe and Swift client against a host with
> streaming encryption enabled, confirming 16-byte padding, whole-datagram
> encryption, and the `0x02` tag byte (see `session-args-and-crypto.md` for key
> and IV details).

Source: `SVLDataLinkUDP::InternalTX` (`+0x167fbc`, TX framing),
`SVLDataLinkUDP::RXThread` (`+0x16709c`, RX parse/validate),
`SVLDataLinkUDP::XMITData` (`+0x1683f8`, element packing),
`SVLDataLinkUDP::Init` (`+0x166b4c`, header length), ctor (`+0x1669d0`, buffer
size + sideband magic), and `SVLDataLink::ReceivedData` (`+0x15a9b8`, element
loop). Code offsets are **static**.

## 1. Transport header (per UDP datagram)

`SVLDataLinkUDP::Init` (`+0x166b4c`, **static**) sets the header length from
the session mode (`this+0x1ec`/`this+0x1f0`): mode 0 writes
`0x00000004_00000004` (4-byte header), while modes 1 and 2 write
`0x00000008_00000008` (8-byte header).

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

In mode 2, the entire datagram (header included) is zero-padded to a 16-byte
multiple (`uVar19 = (len + 0x13) & ~0xf`, `memset` on the pad) and encrypted
with AES-128-CBC before transmission. On RX, the received length must be a
multiple of 16 (`recvlen & 0xf == 0`); after decryption, **byte 7** (the top
byte of `tagcounter`) must equal `0x02` (`"packet received with wrong
identifier. Expected 0x02...... got: %08x"`) and the `res`/counter validation
must pass (`"res field incorrect [encryption mode]"`). The 24-bit `counter`
increments only when `seq` wraps through 0, acting as a rollover counter and
mode tag rather than a CBC nonce.

The TX buffer allocates `malloc(0x5a0)` = 1440 B with a usable datagram cap of
`this+0x1e8 = 0x580` = **1408 B** (ctor `+0x1669d0`), while the RX `recvfrom`
buffer is `0x824` = 2084 B (`+0x16709c`). In capture `vr3` (**captured**),
client→host datagrams measure 512..881 B (17,037 of 17,446 are 537 B
steady-state pose datagrams), and host→client datagrams measure 28..1376 B
(48,775 are 1040 B full video packets and 8,621 are 1032 B frame descriptors),
all fitting within the 1408 B cap.

## 2. Element ("id/len/value triple") format

The payload is a back-to-back list of elements. Both `ReceivedData` and
`XMITData` use an **8-byte element header**:

| off | size | field | notes |
|-----|------|-------|-------|
| 0   | u8   | `class` | channel ID; `ReceivedData` switches on it (`packet-types.md`) |
| 1   | u8   | `type` | sub-type within the class |
| 2   | u16  | `id` | per-class: reliable sequence ID (class 2), video frame ID (class 5); 0 on most others |
| 4   | u16  | `len` | value length, **≤ 0x400 (1024)** |
| 6   | u16  | `index` | per-class: video packet ID within the frame (`0x000`–`0x7ff` data, `0x800`+ parity) or descriptor group number; see `../svl-video/packets.md` |
| 8   | len  | `value` | payload |

Upper layers call this the `dataset` header (`GenSimpleDataset`, `+0x155bc4`).
Other pages in this folder also refer to bytes 0–1 as a single u16 `kind` (low
byte = `class`, high byte = `type`), offset 2 as `seqid`, and offset 6 as
`field6`.

Each element occupies `len + 8` bytes total. Capture `vr3` (**captured**)
confirms that `len` is a 16-bit integer (reading a `u32` at offset 4 would
consume `index` and fail to parse, whereas all 80,035 datagrams parse cleanly
with u16 `len`), with a maximum observed `len` of 1024 B on full video packets.
Both `id` and `index` are per-element fields: both are 0 on every class 3 and
class 8 element in either direction; class 4 type `0x0f` (frame report) carries
frame IDs in both fields; class 5 carries the frame ID in `id` and the packet
ID or descriptor group in `index`; and class `0xc` (audio) carries a sequential
counter in `id` (0..2912 across 2,913 messages).

Each datagram packs 1–4 elements back to back. Capture `vr3` contained the
following element combinations (**captured**; `class/type`):

| direction | elements, in order | datagrams |
|---|---|---|
| C→H | `3/0x11` `3/0x07` `4/0x0f` `3/0x01` | 17,043 (every datagram from 0.930 s onward) |
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

`vrlink` batches all pending client elements into a single datagram per pose
tick, whereas the host sends almost every element in its own datagram.

`RXThread` (`+0x16709c`, **static**) walks the payload and dispatches elements
to `ReceivedData`:

```python
p = payload           # offset 4 (mode0) or 8 (modes 1/2)
remaining = recvlen - header_len
while remaining >= 8:
    length = u16(p[4:6]); elem = length + 8
    if p[0] != 0:                      # class 0: skip dispatch and continue scanning
        if remaining < elem or length > 0x400:
            log("WARNING: Corrupt UDP packet went long (...)"); break
        ReceivedData(p)                # dispatch by class
    p += elem; remaining -= elem
```

Elements with `class == 0` advance the cursor by `len + 8` without calling
`ReceivedData` rather than terminating the scan (correcting an earlier note
here; see `+0x16709c`). Trailing all-zero mode-2 padding therefore advances 8
bytes at a time to the end of the datagram. No class-0 elements occur in `vr3`.
Note that VTS triples sit inside an element's `value` rather than at the
transport layer: for example, Klepton §3.1 shows one `kind=0x0d03` element with
`payload_len=168` carrying eight VTS triples whose sizes sum to 168.

## 3. XOR0 integrity word (mode 1) — CAPTURED

In capture `vr3` (**captured**, all 80,035 datagrams in both directions with
session ID `0x01xxxxxx`), XOR-folding all little-endian `u32` words of each
*received* datagram (including the stored checksum word) seeded with the
session ID yields **0**. Conversely, zeroing bytes 4..7 and XOR-folding the
datagram seeded with the session ID reproduces the stored checksum word. Both
the host and client seed the fold with the **same** session ID. Because 20,422
datagrams in `vr3` have lengths that are not multiples of 4, the trace also
confirms zero-padding of trailing bytes during the fold.

Both TX (`InternalTX`) and RX (`RXThread`) run the same 32-bit XOR fold over
the whole datagram seeded with `session_id`. TX writes the result at offset 4;
RX folds the entire received datagram and requires the accumulator to equal 0
(since the stored checksum word cancels itself out):

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

Once the checksum passes, RX reports `seq` for loss accounting via
`ReportRXSeqid(seq & 0xffff, 0x10)` (see `reliable-stream.md`). On a nonzero
fold, the client logs `"received packet with invalid session ID (%08x/%08x/%08x)"`.

## 4. Sequence counter

`seq` (header offset 0, u16) comes from an atomic fetch-add at `this+0x2b4`
(`FUN_00304830(1, this+0x2b4)`, a load-exclusive/add-store-exclusive counter).
It increments once per **datagram**, wraps at 65536 (explaining Klepton's
observation of byte 0 cycling `0x00`–`0xff`), and feeds loss statistics rather
than retransmission.

Sequence behavior in `vr3` (**captured**):

- The client's first datagram has `seq = 0`, and subsequent datagrams increment
  consecutively from 0..17445 across 17,446 datagrams with no gaps or
  duplicates.
- Host datagrams are also strictly consecutive across 62,589 packets with no
  gaps, starting at `seq = 5` rather than 0 (5..62593). **Inferred**: the
  host's counter belongs to a link object that had already sent (or attempted
  to send) five datagrams before the client's first packet arrived, and is not
  reset when a client connects. Connecting to a host that has already been
  streaming should show a correspondingly higher initial `seq`.
- Neither direction reached 65536 during the 40 s capture, so 16-bit wraparound
  was not directly observed in `vr3`.
- Each direction maintains an independent counter; neither side echoes the
  peer's `seq`.

Receiver sequence tracking (`ReportRXSeqid`) and the effect of resetting `seq`
to 0 across sessions are covered in `reliable-stream.md` §3. The teardown
datagram is the sole exception to sequential numbering, always using
`seq = 0xffff` (`connection-lifecycle.md` §6, **static**).

## 5. 12-byte sideband control packet

`HandleSidebandPacket` (`+0x167688`) and several RX error paths emit a fixed
12-byte control datagram, rate-limited to once per 500 ms:

| off | size | field | value |
|-----|------|-------|-------|
| 0   | u32  | `magic` | `0x459b4c34` (ctor `+0x1669d0`; wire LE: `34 4c 9b 45`) |
| 4   | u32  | `code` | `SidebandEventType` (see below) |
| 8   | u32  | `zero` | 0 |

Capture `vr3` contains no packets starting with `34 4c 9b 45` and no 12-byte
datagrams in either direction because the session stayed healthy and never
triggered a NAK, leaving this frame **static**-only in `vr3` (rejection frames
were later seen in mode-2 probe tests; see `session-args-and-crypto.md`).

The packet is sent via `sendto(..., 0xc, MSG_NOSIGNAL, peer, 16)`. `RXThread`
(`+0x16709c`, **static**) sends codes `0x10` (XOR0 checksum failure — `"invalid
session ID"` — or AES `"res field incorrect"`), `0x11` (wrong AES tag byte, or
clear-mode `res != 0`), `0x13` (datagram received from an IP other than the
current peer's, more than 4 s after the last peer change and more than 1 s
after the last rejected packet, while the current peer was heard from within
3 s), or the nonzero value at `this+0x2c0` (dropping the triggering datagram
unparsed). On RX, if a 12-byte packet starts with `magic` and comes from the
current peer, `RXThread` passes `code` to vtable+0x90. These frames carry
keepalive and NAK signaling rather than stream elements.

**Note:** the LAN discovery probe is also 12 bytes long, but it is a standard
mode-0 SVL datagram (4-byte header + one kind-9 element) rather than a magic
sideband packet; see `lan-scanner.md`.

## Open questions / to confirm on the wire

Capture `vr3` confirmed the 8-byte header, `res == 0`, u16 `len`, the
bidirectional XOR0 checksum fold with a shared session ID, 1–4 elements packed
per datagram, and `seq` starting at 0 on the client and advancing by 1 per
datagram in both directions.

Remaining open questions:
- Whether `seq` and `res` are u16 + u16 or a single u32 on the wire. Capture
  `vr3` is consistent with both because max host `seq` was 62,593 (< 65536) with
  the upper 16 bits always zero, though static code writes `seq` as a `short`
  and calls `ReportRXSeqid(seq & 0xffff, 16)`. A host stream longer than ~55 s
  will cross 65536 and show the wrap.
- Why the host's first datagram in `vr3` carried `seq = 5`, and whether that
  starting value grows with host uptime (§4).
- Capturing **mode 2 (AES)** traffic from `vrlink` itself (16 B padding,
  whole-datagram encryption, and the `0x02` post-decrypt tag byte were not
  exercised in `vr3`, though verified by the probe and Swift client).
- Observing the 12-byte sideband frame (`magic = 0x459b4c34`, codes `0x10`,
  `0x11`, and `0x13`) from `vrlink`, and tracing what sets `this+0x2c0` and how
  vtable+0x90 handles incoming codes.
