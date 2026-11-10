# Remote Play broadcast protocol (UDP 27036)

This layer handles everything before the VR stream: a client finds a host,
pairs with it and asks it to start a SteamVR streaming session. It is Steam's
long-lived "In-Home Streaming" discovery protocol, and VR Link adds two enum
values and reuses one response field. The Steam Link shell (`libshell_arm64-v8a.so`,
`CServerManager`) is vrlink.

| file | topic |
|---|---|
| [broadcast-packet.md](broadcast-packet.md) | datagram framing, the header, message types |
| [discovery.md](discovery.md) | probe and Status reply |
| [crypto.md](crypto.md) | the symmetric scheme, the PIN-masked key exchange, the RSA ticket |
| [pairing.md](pairing.md) | first-time authorization by PIN |
| [session-request.md](session-request.md) | starting a session; where `sArgs` comes from |
| [vr-vs-flat.md](vr-vs-flat.md) | where flat Steam Link and VR Link diverge |
| [messages.md](messages.md) | the protobuf messages and fields the VR path uses, by number and type |

The output of this layer is one string, `sArgs`, which names the host, the UDP
port and a per-session key for the SVL transport
([../svl-transport/](../svl-transport/)).

```
client                                   host (Steam, UDP 27036)
  | Discovery ------------------------->  |
  | <------------------------- Status     |   vr_link_caps, client_id
  |                                       |
  | StreamingRequest ------------------>  |   device_token proves nothing yet
  | <------------- StreamingResponse(Unauthorized)      (first time only)
  | AuthorizationRequest (PIN-masked key) |   person types the PIN on the host
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

- **captured** -> seen in a Klepton `KL_TRACE_NET` trace of the real vrlink client against a Windows host (Steam build 1793235415, broadcast protocol version 8);
- **static** -> static analysis, read from `libshell_arm64-v8a.so` (addresses are file offsets; add 0x100000 for Ghidra)
- **inferred** -> a guesstimate

`prototype/minimal/ovrlink/{broadcast,steamcrypto,pairing}.py` implement this
layer.
