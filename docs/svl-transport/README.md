# SVL transport layer (client side)

The "SVL" (Steam VR Link) transport is the UDP wire protocol spoken by
`libvrlink_scene.so` (`vrlink`) to the host on **UDP port
10400**. This folder documents the *transport* only: datagram framing,
session crypto, sequence/ack machinery, time sync, socket options, and the
LAN scanner. It stops at the hand-off to the upper "ValueTransportSystem"
(VTS) value channel and to the video/audio decoders, which are documented in
sibling folders and named here only where the transport dispatches to them.

## Evidence rules

Claims are **static** (read out of `libvrlink_scene.so`, Android arm64),
**captured** (verified against a wire trace), or **inferred**. The
captured claims in this folder were re-checked against capture `vr3` (see
`../README.md`), a 40.26 s mode-1 (XOR0) session spanning 80,035 intact SVL
datagrams (17,446 client→host, 62,589 host→client) with monotonic timestamps
from the client's first datagram to its last. The datagram header,
XOR0 checksum, element layout, channel map, sequence behavior, absence of a UDP
handshake, and QoS socket replacement are **captured**. The AES (mode-2)
path, reliable stream (classes 1/2), broadcast classes (9/10),
12-byte sideband frame, and teardown datagram **did not occur in `vr3`** and
remain static-only in that trace (see individual pages for subsequent probe
and client captures). Each file ends with an **Open questions / to confirm on
the wire** list.

When reproducing these packet counts, note that `kltrace.py` pairs each hex line
with a `[net]` line at most 8 lines earlier (`LOOKBACK`). In `vr3`, 24 datagrams
appear more than 8 lines after their `[net]` line, so the default setting yields
80,011 datagrams with 24 apparent sequence gaps. Setting `kltrace.LOOKBACK = 400`
pairs all 80,035 datagrams with no missing sequence numbers in either direction.

Ghidra image base is `0x100000`; a file offset `+0xNNNNNN` is Ghidra address
`0x1NNNNNN`. All symbol offsets below are **file offsets** unless written as a
Ghidra `0x2…` address.

## Overview

The client opens an `AF_INET` `SOCK_DGRAM` socket, `connect()`s it to
`<host>:10400`, and runs one RX thread. Every datagram begins with a compact
transport header (**4 bytes** in clear mode, **8 bytes** in `XOR0` and `aes`
modes): a 16-bit little-endian sequence counter, a 16-bit reserved field that
must be zero, and (in 8-byte modes) a 32-bit integrity/mode word. After the
header comes a back-to-back list of **elements** ("id/len/value triples"), each
with an 8-byte element header (`kind`, reliable-seqid, `len`, flags) followed by
`len` value bytes. The low byte of `kind` selects the channel (reliable, unreliable,
video, audio, broadcast, debug, feedback) and the high byte is a sub-type. The
transport passes each element to `SVLDataLink::ReceivedData`, which dispatches by
channel into the VTS, video, and audio layers.

Three session modes exist, chosen by `SVLDataLink::EncModeFromString` and
passed into `SVLDataLink::InitCrypt`:

| mode | name  | header | integrity / cipher | notes |
|------|-------|--------|--------------------|-------|
| 0    | open  | 4 B    | none (res==0 only) | plaintext (static) |
| 1    | XOR0  | 8 B    | 32-bit XOR checksum seeded with a session id; **no cipher** | the `MID0` token path (**captured**) |
| 2    | aes   | 8 B    | AES-128-CBC over the whole datagram + a 0x02 tag byte | static in `vr3`; verified by probe |

In a standard unencrypted session, the token in the `sArgs` handoff starts with
the 4-char key ID `MID0`, which selects **mode 1 (XOR0)**. Mode 1 tags each
datagram with a per-session ID and an XOR checksum while leaving payloads in
the clear (ASCII strings such as `cPhaseOff` and `[SVLS] ResetVideoStream` are
visible on the wire). See `session-args-and-crypto.md`.

In summary, the transport header is **8 bytes** (XOR0/AES) or 4 bytes (open)
containing `u16 seq`, `u16 res` (= 0), and (in 8-byte modes) a `u32` integrity
word. Each payload element starts with an 8-byte header
`u8 class | u8 type | u16 id | u16 len | u16 index` followed by `len` value
bytes. Active element classes include 3 for the bidirectional unreliable stream
(poses, values, value transport, and host address list), 4 for client→host
video replies, 5 for video data and frame descriptors, 8 for server text
events, 9 for LAN discovery, and 12 for audio.

## Files

- `session-args-and-crypto.md` — token parsing, key IDs, mode enum, XOR0 vs AES
  key/IV derivation, and base64url decoding.
- `packet-format.md` — datagram header, element header, integrity words,
  padding, and the 12-byte sideband control packet.
- `packet-types.md` — channel / `kind` values and their dispatch targets.
- `connection-lifecycle.md` — socket setup, startup sequence, keepalive/NAK
  sideband, timeouts, TX failure streak, and reconnect/teardown.
- `reliable-stream.md` — reliable channel seqids, acks, retransmit map, and
  unreliable loss accounting.
- `time-sync.md` — SVL timestamp units and the symmetric clock-offset
  estimator.
- `lan-scanner.md` — `VRLinkScanner` broadcast probe and reply handling.
- `host-address-list.md` — host→client class 3 type 0x18 message advertising
  the host's interface addresses every 2 s.

## Key functions (file offsets)

`SVLDataLink`: ctor `+0x15a000`, Init `+0x15a4f4`, InitCrypt `+0x15b368`,
EncModeFromString `+0x15c0fc`, ReceivedData `+0x15a9b8`, SubmitMessage
`+0x15a4fc`, ReportRXSeqid `+0x15bd1c`, ReportDropCount `+0x15bdd0`,
SendLastRXID `+0x15c648`, CheckUpdateCounters `+0x15b15c`,
SetPairAddress `+0x15caa8`, SendPostTeardownShutdown `+0x15c920`.
`SVLDataLinkUDP`: ctor `+0x1669d0`, Init `+0x166b4c`, Reconnect `+0x1677a8`,
RXThread `+0x16709c`, InternalTX `+0x167fbc`, XMITData `+0x1683f8`,
HandleSidebandPacket `+0x167688`, HandleStreamIsActiveEvent `+0x166e48`,
HandleStreamIsInactiveEvent `+0x167060`, ChangeQoSState `+0x1685a0`,
PrepareForPossibleShutdown `+0x168608`.
`SVLCrypt`: CreateCrypt `+0x15e1f4`, AES128SetKey `+0x15e718`,
Base64DecodeInPlace `+0x15dba4`; `SVLCryptAArch64::AES128Encrypt` `+0x15eb1c`.
`SVLRoot`: SymmetricTimingUpdate `+0x165a38`,
GetSVLTimestampFromSystemTimeInTicks `+0x165c5c`.
`VRLinkScanner::ScanThread` `+0x153f2c`.
