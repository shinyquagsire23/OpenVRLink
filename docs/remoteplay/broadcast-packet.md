# Broadcast datagram format

| offset | size | field |
|---|---|---|
| 0 | 8 | magic `ff ff ff ff 21 4c 5f a0` |
| 8 | 4 | `header_len`, u32 little-endian |
| 12 | `header_len` | `CMsgRemoteClientBroadcastHeader` (protobuf) |
| … | 4 | `body_len`, u32 little-endian |
| … | `body_len` | the message selected by `header.msg_type` (protobuf) |

`CServerManager::SendMessage` (libshell+0xf96090) writes the magic as two ints, `-1` and `0xA05F4C21`.

## Header

```proto
message CMsgRemoteClientBroadcastHeader {
    optional uint64 client_id = 1;
    optional ERemoteClientBroadcastMsg msg_type = 2;
    optional uint64 instance_id = 3;
    optional uint64 device_id_OBSOLETE = 4;
    optional bytes device_token = 5;
}
```

| field | client → host | host → client |
|---|---|---|
| `client_id` | the client's **device id**: a random non-zero u64 made once and persisted (`CServerManager::GetDeviceID`, +0xf9688c; file `device_id.txt`) — **static + captured** | the host's client id, stable across runs — **captured** |
| `msg_type` | always present | always present |
| `instance_id` | absent — **captured** | present; changes when Steam restarts — **inferred** from the name, one value seen |
| `device_token` | absent on direct LAN sends. Set only when the client has no address for the host and relays through Steam's servers (`SendMessage` falls through to `CRemoteClientSession::SendMessage`) — **static** | absent |

A captured client header is 12 bytes (`client_id` + `msg_type`), a host header
23 bytes (adds `instance_id`).

## Message types

`ERemoteClientBroadcastMsg`, with the body each carries:

| value | name | body | direction |
|---|---|---|---|
| 0 | `MsgDiscovery` | `CMsgRemoteClientBroadcastDiscovery` | client → broadcast |
| 1 | `MsgStatus` | `CMsgRemoteClientBroadcastStatus` | host → client |
| 2 | `MsgOffline` | (none known) | host → broadcast |
| 3 | `DeviceAuthorizationRequest` | `CMsgRemoteDeviceAuthorizationRequest` | client → host |
| 4 | `DeviceAuthorizationResponse` | `CMsgRemoteDeviceAuthorizationResponse` | host → client |
| 5 | `DeviceStreamingRequest` | `CMsgRemoteDeviceStreamingRequest` | client → host |
| 6 | `DeviceStreamingResponse` | `CMsgRemoteDeviceStreamingResponse` | host → client |
| 7 | `DeviceProofRequest` | `CMsgRemoteDeviceProofRequest` | host → client |
| 8 | `DeviceProofResponse` | `CMsgRemoteDeviceProofResponse` | client → host |
| 9 | `DeviceAuthorizationCancelRequest` | empty message | client → host |
| 10 | `DeviceStreamingCancelRequest` | `CMsgRemoteDeviceStreamingCancelRequest` | client → host |
| 11 | `MsgClientIDDeconflict` | `CMsgRemoteClientBroadcastClientIDDeconflict` | either |
| 12 | `DeviceStreamTransportSignal` | `CMsgRemoteDeviceStreamTransportSignal` | either |
| 13 | `DeviceStreamingProgress` | `CMsgRemoteDeviceStreamingProgress` | host → client |
| 14 | `DeviceAuthorizationConfirmed` | `CMsgRemoteDeviceAuthorizationConfirmed` | client → host |

Types 0, 1, 5, 6, 7, 8 are **captured**; the rest are **static** (the enum and
the handlers named `CServerManager::Handle*` / `Send*`).

## Sockets

- **captured**: the client binds one UDP socket to `[::]:27036` (dual-stack)
  and uses it for everything in this layer. Replies to unicast requests come
  back to the sending port, so a client does not need port 27036 itself —
  **captured by probe**: `ovrlink discover <host>` gets a Status from an
  ephemeral port. Binding 27036 is only needed to hear other machines'
  unsolicited broadcasts.
- A machine that also runs Steam already owns 27036 (Klepton STEAMLINK.md §3.1);
  another reason not to bind it.

## Open questions

- `MsgOffline` body and when a host sends it.
- Whether a host rate-limits or ignores requests from a port other than 27036
  for types 3 and 5 (only Discovery has been probed from an ephemeral port).
