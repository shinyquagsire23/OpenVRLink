# SVL transport layer (client side)

The "SVL" (Steam VR Link) transport is the UDP wire protocol spoken by
`libvrlink_scene.so` (the Steam Link VR client) to the host on **UDP port
10400**. This folder documents the *transport* only: datagram framing, the
session crypto, the sequence/ack machinery, time sync, socket options, and the
LAN scanner. It stops at the hand-off to the upper "ValueTransportSystem"
(VTS) value channel and to the video/audio decoders; those are owned by another
agent and are only named here where the transport dispatches to them.

## Evidence rules

Claims are **static** (read out of `libvrlink_scene.so`, Android arm64),
**captured** (verified against a real wire trace), or **inferred**. The
captured claims in this folder were re-checked against capture `vr3` (see
`../README.md`): one mode‑1 (XOR0) session, 40.26 s from the client's first
datagram to its last, 80,035 SVL datagrams (17,446 client→host, 62,589
host→client), none torn, each with a monotonic timestamp. The datagram header,
XOR0 checksum, element layout, channel map, sequence behavior, the "no UDP
handshake" finding and the QoS reconnect are **captured**. The AES (mode‑2)
path, the reliable stream (classes 1/2), the broadcast classes (9/10), the
12-byte sideband frame and the teardown datagram **did not occur in `vr3`** and
remain static-only. Each file ends with an **Open questions / to confirm on
the wire** list.

A note for anyone repeating the counts: `kltrace.py` pairs each hex line with
a `[net]` line at most 8 lines earlier (`LOOKBACK`), and in `vr3` 24 datagrams
have theirs further away, so the stock tools yield 80,011 datagrams with 24
apparent sequence gaps. With `kltrace.LOOKBACK = 400` all 80,035 pair up and
no sequence number is missing in either direction.

Ghidra image base is `0x100000`; a file offset `+0xNNNNNN` is Ghidra address
`0x1NNNNNN`. All symbol offsets below are **file offsets** unless written as a
Ghidra `0x2…` address.

## One-paragraph summary

The client opens an `AF_INET` `SOCK_DGRAM` socket, `connect()`s it to
`<host>:10400`, and runs one RX thread. Every datagram begins with a tiny
transport header (**4 bytes** in clear mode, **8 bytes** in the two "crypted"
modes): a 16-bit little-endian sequence counter, a 16-bit reserved field that
must be zero, and (crypted modes only) a 32-bit integrity/mode word. After the
header comes a back-to-back list of **elements** ("id/len/value triples"), each
with an 8-byte element header (`kind`, reliable-seqid, `len`, flags) followed by
`len` value bytes. `kind`'s low byte is the channel (reliable, unreliable,
video, audio, broadcast, debug, feedback); the high byte is a sub-type. The
transport hands each element to `SVLDataLink::ReceivedData`, which dispatches by
channel into the VTS / video / audio layers.

Three session modes exist, chosen by `SVLDataLink::EncModeFromString` and
carried into `SVLDataLink::InitCrypt`:

| mode | name  | header | integrity / cipher | notes |
|------|-------|--------|--------------------|-------|
| 0    | open  | 4 B    | none (res==0 only) | plaintext (static) |
| 1    | XOR0  | 8 B    | 32-bit XOR checksum seeded with a session id; **no cipher** | the `MID0` token path (**captured**) |
| 2    | aes   | 8 B    | AES-128-CBC over the whole datagram + a 0x02 tag byte | static-only |

The token in the real `sArgs` handoff starts with the 4-char key id `MID0`,
which runs **mode 1 (XOR0) — the stream is NOT encrypted** (confirmed: ASCII
payloads like `cPhaseOff` and `[SVLS] ResetVideoStream` are visible on the
wire), only tagged with a per-session id and an XOR checksum. See
`session-args-and-crypto.md`.

The transport header is **8 bytes** (XOR0/AES) or 4 bytes (open): `u16 seq`,
`u16 res`(=0), and (8‑byte only) `u32` integrity word. Each payload element has
an 8‑byte header `u8 class | u8 type | u16 id | u16 len | u16 index`, then `len` value
bytes. Classes: 3 = unreliable stream (poses, values, value transport, host
address list; both directions), 4 = client→host video reply, 5 = video +
frame descriptors, 8 = server text events, 12 = audio, 9 = LAN discovery.

## Files

- `session-args-and-crypto.md` — token parsing, key ids, mode enum, XOR0 vs AES
  key/IV derivation, base64url.
- `packet-format.md` — datagram header, element header, integrity words,
  padding, the 12-byte sideband control packet.
- `packet-types.md` — channel / `kind` values and who each dispatches to.
- `connection-lifecycle.md` — socket setup, connect, keepalive/NAK sideband,
  timeouts, TX failure streak, reconnect/teardown.
- `reliable-stream.md` — reliable channel seqids, acks, retransmit map;
  unreliable loss accounting.
- `time-sync.md` — SVL timestamp definition and the symmetric clock-offset
  estimator.
- `lan-scanner.md` — `VRLinkScanner` probe/reply.
- `host-address-list.md` — the host→client class 3 type 0x18 message: the
  host's interface addresses, every 2 s.

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
