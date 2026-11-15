# Remote Play broadcast protocol (UDP 27036)

The Remote Play broadcast layer handles host discovery, PIN pairing, and session
initiation before the VR stream begins. It uses Steam's In-Home Streaming
discovery protocol on UDP port 27036, adding two VR Link enum values and
repurposing one response field. In Valve's Android APK, the 2D Steam Link shell
(`libshell_arm64-v8a.so`, `CServerManager`) implements this layer before
launching `vrlink`.

| file | topic |
|---|---|
| [broadcast-packet.md](broadcast-packet.md) | datagram framing, header fields, and message types |
| [discovery.md](discovery.md) | discovery probes and `MsgStatus` replies |
| [crypto.md](crypto.md) | symmetric encryption, PIN-masked key exchange, and RSA escrow tickets |
| [pairing.md](pairing.md) | first-time device authorization via 4-digit PIN |
| [session-request.md](session-request.md) | starting a session and obtaining `sArgs` |
| [vr-vs-flat.md](vr-vs-flat.md) | differences between flat Steam Link and VR Link |
| [messages.md](messages.md) | protobuf message and enum schemas used by the VR path |

This layer produces a single session string, `sArgs`, which provides the host
address, UDP port, and per-session key to the SVL transport
([../svl-transport/](../svl-transport/)).

```
client                                   host (Steam, UDP 27036)
  | Discovery ------------------------->  |
  | <------------------------- Status     |   vr_link_caps, client_id
  |                                       |
  | StreamingRequest ------------------>  |   unrecognized device_token
  | <------------- StreamingResponse(Unauthorized)      (first time only)
  | AuthorizationRequest (PIN-masked key) |   user enters PIN on the host
  | <------------ AuthorizationResponse   |   host's masked key -> shared secret
  | AuthorizationConfirmed ------------>  |
  |                                       |
  | StreamingRequest ------------------>  |   repeated every second
  | <----------------------- ProofRequest |   16-byte challenge
  | ProofResponse --------------------->  |   challenge encrypted with the secret
  | <---- StreamingResponse(InProgress)   |   SteamVR starting
  | <---- StreamingResponse(Success)      |   encrypted session key + encrypted sArgs
  |                                       |
  |  ===== SVL transport, UDP 10400 ===== |
```

## Notation

- **captured** — observed in a Klepton `KL_TRACE_NET` trace of `vrlink` against a Windows host (Steam build 1793235415, broadcast protocol version 8).
- **static** — read from `libshell_arm64-v8a.so` via static analysis (addresses are file offsets; add `0x100000` for Ghidra).
- **inferred** — an unverified estimate based on surrounding behavior or names.

`prototype/minimal/ovrlink/broadcast.py`, `steamcrypto.py`, and `pairing.py`
implement this layer.
