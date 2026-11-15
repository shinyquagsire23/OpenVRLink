# Channels and `kind` values

Source: `SVLDataLink::ReceivedData` (`+0x15a9b8`) — the `switch (kind & 0xff)`
dispatcher — plus `SVLDataLink::SubmitMessage` (`+0x15a4fc`),
`SVLDataLink::SendLastRXID` (`+0x15c648`), and `SVLDataLinkUDP::XMITData`
(`+0x1683f8`). Code offsets are **static**.

> **Status: mostly CAPTURED.** The class numbers and directions in the table
> below are confirmed against capture `vr3` (a mode-1 session of 80,035
> datagrams, complete from the client's first datagram). Classes **1, 2, 9, and
> 10** never appear during startup or steady-state streaming in `vr3` and
> remain **static**-only.

An element's `kind` (element header offset 0, u16 LE) splits into **low byte =
channel** and **high byte = sub-type**. `ReceivedData` switches on the low byte.
`this+0x98` is the owning `SVLRoot`; `this+0x10` is the stream/video sink.

### Captured element census (`vr3`, full session)

| dir | class/type | count | value length | first seen (s after the client's first datagram) | cadence |
|---|---|---|---|---|---|
| C→H | `3/0x01` pose + value transport | 17,446 | 360..731 | 0.000 | every datagram: 433.4 per second, four per client frame |
| C→H | `4/0x0f` frame report | 17,446 | 24 | 0.000 | every datagram |
| C→H | `3/0x07` string→double values | 17,444 | 96 | 0.004 | every datagram except the first two |
| C→H | `3/0x11` eye/face | 17,043 | 17 | 0.930 | every datagram once the first frame descriptor arrives |
| H→C | `3/0x0d` value transport | 6 | 12..216 | 0.004 | only in the first 42 ms (see `../svl-values/`) |
| H→C | `8/0x06` text event | 1 | 27 | 0.209 | once |
| H→C | `5/0x02` frame descriptor | 8,632 | 1016 | 0.926 | 217 per second: two per frame (`index` 0 and 1) for 4,260 frames, plus 112 with a higher `index` |
| H→C | `5/0x03` video / parity packet | 52,314 | 1..1024 | 0.926 | about 1,050 per second in steady state; 12,654 datagrams in the second after video started |
| H→C | `3/0x18` host address list | 20 | 179 | 1.576 | every 2.000 s (1.995..2.008) |
| H→C | `0xc/0x10` audio | 2,913 | 768..1024 | 1.855 | 300 per second while the host had audio to send (until 11.556 s) |

Capture `vr3` contains no `4/0x05` retransmit requests (`vr1` had 9, whereas
`vr3` had zero packet loss), no class 1, 2, 9, or 10 elements, no class 3
types `0x0e`/`0x12`/`0x14`/`0x16`, and no `3/0x13` teardown message.

Class 3 is the **bidirectional unreliable stream**. Class 4 is **client→host
only** (with no `case 4` in `ReceivedData`). Class 8 carried a single 27-byte
server event consisting of a `u32` timestamp followed by ASCII
`[SVLS] ResetVideoStream`. That `u32` is the host's microsecond SVL clock
(**captured**), matching the host time derived from the client's arrival
timestamp and reported pose clock offset to within ~1 ms (`time-sync.md`).

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
| 10 (0xa) | SVLRoot vtable+0x38 | second stream entry point on `SVLRoot` (handler not confirmed) | no (static) |

Low byte `0` is skipped during the element scan (consuming mode-2 zero-padding;
see `packet-format.md` §2).

## Sub-types seen (high byte)

Sub-types observed on the wire in `vr3` (plus `0x0504` in `vr1`):
- Class 3 uses `0x01`, `0x07`, and `0x11` from client to host, and `0x0d` and
  `0x18` from host to client. `0x07` payloads start with an ASCII key name
  (`cPhaseOff`, `cAudBufMax`, …). The two directions use disjoint sub-types in
  `vr3`: the host never sends `0x01` or `0x07`, and the client never sends
  `0x0d`.
- Class 4 (video reply): `0x0f` (`SendLastRXID`, len `0x18`) and, in `vr1`
  only, `0x05`.
- Channel 5: `0x02` = frame descriptor and timing (host timestamp at value
  offset 0 → `SymmetricTimingUpdate`; FEC byte at element[`0x15`] →
  `HandleFECChange`), `0x03` = video / parity data.
- Channel 12: `0x10` (audio).
- Channel 8: `0x06` (server event text).

Sub-types known from **static** analysis only:
- `0x0a09` — channel 9 broadcast, sub-type `0x0a`: the LAN discovery probe
  element (`lan-scanner.md`).
- `0x1303` — class 3 type `0x13`, zero length: the client's teardown message
  (`connection-lifecycle.md` §6).
- Class 3 types `0x0e`, `0x12`, `0x14`/`0x15`, `0x16`, `0x17`
  (`../svl-tracking-input/messages.md`).

The sub-type byte acts as a per-channel opcode. Payload layouts inside element
values are documented in the VTS, video, and audio folders.

## Pre-connection transmit gate

`XMITData` (`+0x1683f8`) drops outbound elements until the link is marked up
(`this+0x1f8`), **unless** the element's low-byte class is `9` (`dVar1 == 9`),
allowing channel 9 LAN-discovery broadcasts before an active session exists.

## Reliable vs unreliable routing (TX side)

`SubmitMessage` (`+0x15a4fc`) routes outbound elements by class:
- `kind != 2` → passed straight to `XMITData` (fire-and-forget, unreliable).
- `kind == 2` → assigned a monotonic 16-bit reliable seqid from `this+0x90`,
  stored in the reliable map (`this+0x80`) for retransmission, and transmitted.
  An incoming channel-1 ack from the host frees the map node.

## Transport → upper-layer boundary

Transport processing ends at `ReceivedData`, which dispatches elements to the
upper layers:
- VTS value channel: channels 2, 3, 8, 9, and 10 via `SVLRoot` vtable slots.
- Video: channel 5 → `this+0x10` vtable+0x30.
- Audio: channels 6/11/12 → `SVLAudio::TransportRXAudioFrames`.

Everything above those calls (value IDs, FEC/RAID6 frame assembly, poses, and
audio decoding) is documented outside this folder.

## Open questions / to confirm on the wire

Capture `vr3` confirmed the active classes (3, 4, 5, 8, and `0xc`) and their
directions, showed that classes 1, 2, 9, and 10 are unused during normal
session startup and streaming, and provided a complete sub-type census for a
40 s session.

Remaining open questions:
- Which features exercise reliable classes 1/2 and class 10 (none fired during
  a session with a stationary headset, no controller input, and no UI prompts).
- Whether the host ever sends class 3 type `0x01` or `0x07` (`vrlink` has
  receive handlers for both, though in `vr3` host string→double values arrived
  only inside frame descriptors).
- When audio classes 6 and `0xb` are used (`vrlink` routes all three to
  `TransportRXAudioFrames`, while the host in `vr3` used only `0xc`).
