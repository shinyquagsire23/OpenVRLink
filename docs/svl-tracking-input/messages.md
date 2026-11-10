# Message envelope and type table (as seen above the transport)

The transport hands this layer a `dataset*`. Only the first 8 bytes are common;
the layer documented here never looks at the UDP header (docs/svl-transport/).

## `dataset` header

| off | type | field | evidence |
|---|---|---|---|
| 0x00 | u8 | class. Every message this layer builds writes `0x03` here | **static**: constants `0x103` (`SendPoses` 0xf4d34), `0x1103` (`QSVLDeviceHmd::HandleEyeInput` 0x100da0), `0x1703` (`QSVLClientXR::HandleHandTracking` 0xfb794), `0x1503` (`SVLRoot::RXUnreliableStream` 0x164ae0). **inferred**: 3 = "unreliable stream" channel |
| 0x01 | u8 | message type (table below) | **static**: every RX dispatcher switches on `param_1[1]` |
| 0x02 | u16 | per-type; `0x14` echo copies it into the reply | **static** 0x164ae0 |
| 0x04 | u16 | payload length in bytes (bytes following the 8-byte header) | **static**: `SendPoses` writes `0x168 + vte_len`; `RXUnreliableStream` passes `*(u16*)(d+4)` as the length to `ValueTransportSystem::RXMessage` |
| 0x06 | u16 | per-type; 0 for poses/eye/hand; echo uses it as a byte count | **static** |
| 0x08 | … | payload | |

Little-endian throughout (**static**: plain arm64 stores).

## Message types seen in this layer

Dispatch chain for received unreliable messages (**static**):
`QSVLClientXR::RXUnreliableStream` (0xfab44) → `QSVLClient::RXUnreliableStream`
(0xf5c00) → `SVLRoot::RXUnreliableStream` (0x164ae0). Reliable:
`QSVLClientXR::RXReliableStream` (0xfab40) → `QSVLClient::RXReliableStream`
(0xf5e40) → `SVLRoot::RXReliableStream` (0x164adc, empty).

| type | dir | name / meaning | handled at | doc |
|---|---|---|---|---|
| 0x01 | C→H | pose + input packet (plus piggy-backed VTE bytes) | built in `QSVLClient::SendPoses` 0xf4d34 | [poses.md](poses.md) |
| 0x01 | H→C | *any* type-1 message makes the client adopt the link it arrived on as its active `SVLDataLink` (`this+0x140 = link`); the body is not parsed here | `SVLRoot::RXUnreliableStream` 0x164ae0 | **inferred**: the host's mirror "frame/pose" packet; body unknown from this binary's upper layer |
| 0x07 | H→C | peer value settings: array of 32-byte `TransportValue_t`, count = len >> 5 | `SVLRoot::RXUnreliableStream` → `ParsePeerValueSettings` | docs/svl-values/ |
| 0x0d | H→C | ValueTransportSystem bytes, `len` bytes at +8 | `SVLRoot::RXUnreliableStream` → `ValueTransportSystem::RXMessage` | docs/svl-values/ |
| 0x0e | H→C | `SYST_SERVER_SHUTDOWN` (log string `Received SYST_SERVER_SHUTDOWN`); raises client event 1 with zero payload to the app callback at `this+0x3f20` | `QSVLClientXR::RXUnreliableStream` 0xfab44 | [events-prompts.md](events-prompts.md) |
| 0x11 | C→H | eye gaze + face expressions | `QSVLClientXR::HandleEyeInput` 0xfb6ec | [eye-face.md](eye-face.md) |
| 0x12 | H→C | message prompt (accepted on both unreliable and reliable streams) | `QSVLClient::HandleMessagePromptMessageReceived` 0xf5c90 | [events-prompts.md](events-prompts.md) |
| 0x13 | C→H | teardown: zero-length message in a datagram with `seq = 0xffff`, sent five times 100 ms apart from a fresh socket when the stream scene is destroyed. **static** only; not in any capture | built in `SVLDataLinkUDP::PrepareForPossibleShutdown` 0x168608, sent by `SVLDataLink::SendPostTeardownShutdown` 0x15c920 | docs/svl-transport/connection-lifecycle.md §6 |
| 0x14 | H→C | echo request | `SVLRoot::RXUnreliableStream` 0x164ae0 | below |
| 0x15 | C→H | echo reply | same | below |
| 0x16 | H→C | haptics, two 19-byte events | `QSVLClient::RXUnreliableStream` 0xf5c00 | [haptics.md](haptics.md) |
| 0x17 | C→H | hand tracking skeleton (one message per hand) | `QSVLClientXR::HandleHandTracking` 0xfb794 | [skeleton.md](skeleton.md) |
| 0x18 | H→C | host address list: 179 bytes in `vr3`, one record per host interface address (family, port 10400, prefix length, address), every 2 s once video runs. **captured** | **none** — no case for it in any of the three `RXUnreliableStream` functions (0xfab44 → 0xf5c00 → 0x164ae0); this client build drops it silently | docs/svl-transport/host-address-list.md |

Types not listed (video, audio, FEC, retransmit, timing) are dispatched below
this layer or in other classes; see docs/svl-video/, docs/svl-audio/,
docs/svl-timing/.

### 0x14 / 0x15 echo

**static** (`SVLRoot::RXUnreliableStream` 0x164ae0):

```
reply = zeroed 0x408 bytes
reply[0] = 0x03; reply[1] = 0x15
reply.u16[2] = req.u16[2]                       # opaque id, copied
reply.u16[4] = min(req.u16[6], 0x400)           # reply length
n = min(req.u16[4], req.u16[6], 0x400)
reply[8 : 8+n] = req[8 : 8+n]
SubmitMessage(link, reply, false, true)
```

So the request's `+6` field says how many bytes the host wants back and the
reply is zero-padded to that length. **inferred**: an MTU / path / bandwidth
probe (the SVLRoot string key `sNetworkTest` exists). Confirm by capture: a
`03 14` message from the host answered by a `03 15` of length `req[6..8]`.

## Capture check

**captured** (one macOS-hosted Klepton session; wire framing per
docs/svl-transport/: datasets `[u8 class][u8 type][u16 a][u16 len][u16 b]`
concatenated in a datagram):

- Outbound datasets from this layer: `3/0x01` pose (1637), `3/0x11` eye
  (1241), `3/0x07` values (1637); class byte 3 confirmed for all, and
  `a = b = 0` for pose and eye.
- Inbound `3/0x0d` VTS (28) confirmed.
- **Not seen** in this session: `0x12` prompt, `0x14`/`0x15` echo, `0x16`
  haptics, `0x17` hand tracking, `0x0e` shutdown. Their layouts remain
  **static** only.
- An inbound class `8`, type `0x06` dataset was seen once: 27 payload bytes =
  4 binary bytes followed by ASCII `[SVLS] ResetVideoStream`. This is a host
  debug/log text message; see [events-prompts.md](events-prompts.md).
- Typical outbound datagram order `[3/0x11] [3/0x07] [4/0x0f] [3/0x01]`:
  eye is queued and flushed with the next pose, which supports reading the
  second `SubmitMessage` boolean as "flush now".

## Open questions / to confirm on the wire

- What byte 0 (class) is on H→C messages 0x0e/0x12/0x16 (the client never
  checks it here; C→H class 3 is captured).
- Whether `0x12` prompts actually arrive on the reliable stream, the unreliable
  one, or both.
- The body of the host's type-`0x01` message (only its arrival matters here).
- The two booleans of `SVLDataLink::SubmitMessage(dataset*, bool, bool)`:
  poses and echo use `(false, true)`, eye and hand use `(false, false)`.
  **inferred**: the second is "flush now / high priority". The transport doc
  owns this.
