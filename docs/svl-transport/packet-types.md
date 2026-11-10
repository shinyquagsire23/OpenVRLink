# Channels and `kind` values

Source: `SVLDataLink::ReceivedData` (`+0x15a9b8`) — the `switch (kind & 0xff)`
dispatcher — plus `SVLDataLink::SubmitMessage` (`+0x15a4fc`),
`SVLDataLink::SendLastRXID` (`+0x15c648`), `SVLDataLinkUDP::XMITData`
(`+0x1683f8`). All **static**.

> **Status: mostly CAPTURED.** The table's class numbers and the directions
> below are confirmed against capture `vr3` (a mode‑1 session, 80,035
> datagrams, complete from the client's first datagram). Classes **1, 2, 9 and
> 10 do not occur in it at all** — not at startup, not during streaming — and
> remain **static**-only.

An element's `kind` (element header offset 0, u16 LE) splits into **low byte =
channel** and **high byte = sub-type**. `ReceivedData` switches on the low byte.
`this+0x98` is the owning `SVLRoot`; `this+0x10` is the stream/video sink.

### Captured element census (`vr3`, the whole session)

| dir | class/type | count | value length | first seen (s after the client's first datagram) | cadence |
|---|---|---|---|---|---|
| C→H | `3/0x01` pose + value transport | 17,446 | 360..731 | 0.000 | every datagram: 433.4 per second, four per client frame |
| C→H | `4/0x0f` frame report | 17,446 | 24 | 0.000 | every datagram |
| C→H | `3/0x07` string→double values | 17,444 | 96 | 0.004 | every datagram but the first two |
| C→H | `3/0x11` eye/face | 17,043 | 17 | 0.930 | every datagram once the first frame descriptor has arrived |
| H→C | `3/0x0d` value transport | 6 | 12..216 | 0.004 | only in the first 42 ms (see `../svl-values/`) |
| H→C | `8/0x06` text event | 1 | 27 | 0.209 | once |
| H→C | `5/0x02` frame descriptor | 8,632 | 1016 | 0.926 | 217 per second: two per frame (`index` 0 and 1) for 4,260 frames, plus 112 with a higher `index` |
| H→C | `5/0x03` video / parity packet | 52,314 | 1..1024 | 0.926 | about 1,050 per second in steady state; 12,654 datagrams in the second after video started |
| H→C | `3/0x18` host address list | 20 | 179 | 1.576 | every 2.000 s (1.995..2.008) |
| H→C | `0xc/0x10` audio | 2,913 | 768..1024 | 1.855 | 300 per second while the host had sound to send (until 11.556 s) |

Not in `vr3`: `4/0x05` retransmit requests (`vr1` had 9; `vr3` lost no
datagram, so the client never asked), any class 1, 2, 9 or 10 element, type
0x0e/0x12/0x14/0x16 on class 3, and the teardown message `3/0x13`.

Class 3 is the **bidirectional unreliable stream**. Class 4 is **client→host
only** (it has no `case 4` in `ReceivedData`). Class 8 carried one server
event: 27 bytes = a `u32` followed by ASCII `[SVLS] ResetVideoStream`.
**Captured**: that `u32` is the host's SVL clock in microseconds — it is within
about 1 ms of the host time computed from the client's clock at arrival and
the clock offset the client reports in its poses (`time-sync.md`).

| channel | dispatch (ReceivedData) | meaning | seen in capture |
|---|---|---|---|
| 1 | removes acked node from reliable map (`this+0x80`) | **reliable ACK** — host acks a reliable element by seqid | no (static) |
| 2 | SVLRoot vtable+0x20, then replies with a kind-1 ack | **reliable stream data** (in-order, windowed) → `SVLRoot::RXReliableStream` | no (static) |
| 3 | if the link is not yet marked active (`this+0xac == 0`) and the type is 0x01 or 0x07, first calls the link's vtable+0x60 (`HandleStreamIsActiveEvent`, `connection-lifecycle.md` §2); always SVLRoot vtable+0x28 (`RXUnreliableStream`) | **unreliable stream**, typed: 0x01 pose (+ value-transport chunks), 0x07 string→double values, 0x0d value transport, 0x11 eye/face, 0x13 teardown, 0x18 host address list, others in `../svl-tracking-input/messages.md` | **yes, both dirs** |
| 4 | *(no `case 4`; client→host only)* | **client→host video reply** — type 0x0f frame report (len 0x18), type 0x05 retransmit request (list of u16 packet ids); `../svl-video/retransmit.md` | **yes, outbound** (0x0f only in `vr3`) |
| 5 | subtype 0x02 → SymmetricTimingUpdate + HandleFECChange; then `this+0x10` vtable+0x30 | **host→client video**: type 0x03 data/parity packets, type 0x02 frame descriptor ("bookend", which also carries the host clock) | **yes, inbound** |
| 6, 11 (0xb), 12 (0xc) | `SVLAudio::TransportRXAudioFrames` | **audio frames** (`0x100c` on class 12) | **yes, inbound (class 12 only)** |
| 8 | SVLRoot vtable+0x40 | **server event / text message** — one `0x0608` = `u32` host time + `"[SVLS] ResetVideoStream"` | **yes, 1 inbound** |
| 9 | SVLRoot vtable+0x30 | **broadcast / LAN discovery** (`lan-scanner.md`); allowed before the link is up | no (static) |
| 10 (0xa) | SVLRoot vtable+0x38 | a second stream entry point on `SVLRoot` (which handler is not confirmed) | no (static) |

Low byte `0` is reserved (terminates the element scan / is mode-2 padding).

## Sub-types seen (high byte)

Captured in `vr3` (and `0x0504` in `vr1`):
- Class 3, client→host: `0x01`, `0x07`, `0x11`. Host→client: `0x0d`, `0x18`.
  `0x07` blocks begin with the ASCII key name (`cPhaseOff`, `cAudBufMax`, …).
  The two directions never used the same type: the host sent no `0x01` and no
  `0x07`, the client no `0x0d`.
- Class 4 (video reply): `0x0f` (`SendLastRXID`, len 0x18) and, in `vr1` only,
  `0x05`.
- Channel 5: `0x02` = timing (host timestamp at value offset 0 →
  `SymmetricTimingUpdate`; FEC byte at element[0x15] → `HandleFECChange`),
  `0x03` = video.
- Channel 12: `0x10` (audio).
- Channel 8: `0x06` (server event text).

Static only:
- `0x0a09` — channel 9 broadcast, sub-type `0x0a`: the LAN discovery probe
  element (`lan-scanner.md`).
- `0x1303` — class 3 type `0x13`, zero length: the client's teardown message
  (`connection-lifecycle.md` §6).
- Class 3 types `0x0e`, `0x12`, `0x14`/`0x15`, `0x16`, `0x17`
  (`../svl-tracking-input/messages.md`).

The sub-type byte is a per-channel opcode. Decoding the *values* (above the
transport) belongs to the VTS/video/audio agents.

## Who can send before "connected"

`XMITData` (`+0x1683f8`) gates sending on the link being up (`this+0x1f8`)
**unless** the element's low-byte kind is `9` (`dVar1 == 9`) — the broadcast /
connection channel is allowed pre-connection. That makes channel 9 the
handshake / discovery carrier.

## Reliable vs unreliable routing (TX side)

`SubmitMessage` (`+0x15a4fc`):
- `kind != 2` → straight to `XMITData` (fire-and-forget, unreliable).
- `kind == 2` → assign a 16-bit reliable seqid from `this+0x90` (monotonic),
  store the element in the reliable map (`this+0x80`) for retransmission, and
  send. The host acks it with a channel-1 element; that ack frees the map node.

## Transport → upper-layer boundary

The transport's job ends at `ReceivedData`. From there:
- VTS value channel: channels 2, 3, 8, 9, 10 via `SVLRoot` vtable slots.
- Video: channel 5 → `this+0x10` vtable+0x30.
- Audio: channels 6/11/12 → `SVLAudio::TransportRXAudioFrames`.

Everything above those calls (value ids, FEC/RAID6 frame assembly, poses,
audio decode) is out of scope for this folder.

## Open questions / to confirm on the wire

Settled by `vr3`: classes 3, 4, 5, 8 and 0xc and their directions; classes 1,
2, 9 and 10 are not part of a normal session at any point, startup included;
the complete list of types a healthy 40 s session uses (the census above).

Still open:
- What uses the reliable classes 1/2 and class 10 at all. Nothing in a session
  with a motionless head, no controller input and no prompts did.
- Whether the host ever sends class 3 type `0x01` or `0x07` (the client has
  handlers for both; in `vr3` the host's string→double values came only inside
  frame descriptors).
- Class 6 and 0xb audio (the client accepts them; the host used 0xc).
