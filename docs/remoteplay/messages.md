# Messages on UDP 27036

The bodies of the broadcast protocol's datagrams ([broadcast-packet.md](broadcast-packet.md))
are protobuf messages. This page lists the messages and fields the VR path
uses, by field number and type: enough to build or parse them with any
protobuf library, or by hand (`client/Sources/VRLinkCore/Protobuf.swift`
does it by hand). The probe builds its message classes from the same table
(`prototype/minimal/ovrlink/proto/__init__.py`), and this page is generated
from it.

This page covers only part of Steam's definition. Hosts send fields that are not
listed here; a protobuf parser skips them. The full definitions are embedded
in the Steam Link client as serialized descriptors, and
`prototype/minimal/tools/extract_protos.py` will recover them from a copy of
it for study; they are Valve's and are not kept in this repository. That is
also where the flat (non-VR) Remote Play messages on port 27031 are to be
found ([vr-vs-flat.md](vr-vs-flat.md)).

Evidence: field numbers and types are **static** (from those descriptors);
which fields are used, and with what values, is **captured** and described
on the pages for [discovery](discovery.md), [pairing](pairing.md) and the
[session request](session-request.md). Every field is optional on the wire
as far as a client need care.

## Message types

The header's `msg_type` says what the body is.

| number | name | body |
|---|---|---|
| 0 | `k_ERemoteClientBroadcastMsgDiscovery` | `CMsgRemoteClientBroadcastDiscovery` |
| 1 | `k_ERemoteClientBroadcastMsgStatus` | `CMsgRemoteClientBroadcastStatus` |
| 2 | `k_ERemoteClientBroadcastMsgOffline` | (none) |
| 3 | `k_ERemoteDeviceAuthorizationRequest` | `CMsgRemoteDeviceAuthorizationRequest` |
| 4 | `k_ERemoteDeviceAuthorizationResponse` | `CMsgRemoteDeviceAuthorizationResponse` |
| 5 | `k_ERemoteDeviceStreamingRequest` | `CMsgRemoteDeviceStreamingRequest` |
| 6 | `k_ERemoteDeviceStreamingResponse` | `CMsgRemoteDeviceStreamingResponse` |
| 7 | `k_ERemoteDeviceProofRequest` | `CMsgRemoteDeviceProofRequest` |
| 8 | `k_ERemoteDeviceProofResponse` | `CMsgRemoteDeviceProofResponse` |
| 9 | `k_ERemoteDeviceAuthorizationCancelRequest` | `CMsgRemoteDeviceAuthorizationCancelRequest` |
| 10 | `k_ERemoteDeviceStreamingCancelRequest` | `CMsgRemoteDeviceStreamingCancelRequest` |
| 11 | `k_ERemoteClientBroadcastMsgClientIDDeconflict` | `CMsgRemoteClientBroadcastClientIDDeconflict` |
| 12 | `k_ERemoteDeviceStreamTransportSignal` | `CMsgRemoteDeviceStreamTransportSignal` |
| 13 | `k_ERemoteDeviceStreamingProgress` | `CMsgRemoteDeviceStreamingProgress` |
| 14 | `k_ERemoteDeviceAuthorizationConfirmed` | `CMsgRemoteDeviceAuthorizationConfirmed` |

## Messages

### `CMsgRemoteClientBroadcastHeader`

| field | type | wire | name |
|---|---|---|---|
| 1 | uint64 | varint | `client_id` |
| 2 | `ERemoteClientBroadcastMsg` (enumeration) | varint | `msg_type` |
| 3 | uint64 | varint | `instance_id` |
| 5 | bytes | length-delimited | `device_token` |

### `CMsgRemoteClientBroadcastDiscovery`

| field | type | wire | name |
|---|---|---|---|
| 1 | uint32 | varint | `seq_num` |
| 2 | repeated uint64 | varint | `client_ids` |

### `CMsgRemoteClientBroadcastClientIDDeconflict`

| field | type | wire | name |
|---|---|---|---|
| 2 | repeated uint64 | varint | `client_ids` |

### `CMsgRemoteClientBroadcastStatus`

| field | type | wire | name |
|---|---|---|---|
| 1 | int32 | varint | `version` |
| 2 | int32 | varint | `min_version` |
| 3 | uint32 | varint | `connect_port` |
| 4 | string | length-delimited | `hostname` |
| 6 | uint32 | varint | `enabled_services` |
| 9 | repeated `CMsgRemoteClientBroadcastStatus.User` | length-delimited | `users` |
| 11 | int32 | varint | `euniverse` |
| 12 | uint32 | varint | `timestamp` |
| 13 | bool | varint | `screen_locked` |
| 14 | bool | varint | `games_running` |
| 18 | bool | varint | `vr_active` |
| 20 | repeated string | length-delimited | `ip_addresses` |
| 22 | bool | varint | `remoteplay_active` |
| 26 | `EVRLinkCaps` (enumeration) | varint | `vr_link_caps` |
| 28 | fixed64 | 64-bit | `connected_paired_network_hash` |
| 29 | bool | varint | `wifi_dongle_present` |

### `CMsgRemoteClientBroadcastStatus.User`

| field | type | wire | name |
|---|---|---|---|
| 1 | fixed64 | 64-bit | `steamid` |
| 2 | uint32 | varint | `auth_key_id` |

### `CMsgRemoteDeviceAuthorizationRequest`

| field | type | wire | name |
|---|---|---|---|
| 1 | bytes | length-delimited | `device_token` |
| 2 | string | length-delimited | `device_name` |
| 3 | bytes | length-delimited | `encrypted_request` |
| 4 | bytes | length-delimited | `auth_key` |
| 5 | uint32 | varint | `request_id` |

### `CMsgRemoteDeviceAuthorizationRequest.CKeyEscrow_Ticket`

| field | type | wire | name |
|---|---|---|---|
| 1 | bytes | length-delimited | `password` |
| 2 | uint64 | varint | `identifier` |
| 3 | bytes | length-delimited | `payload` |
| 4 | uint32 | varint | `timestamp` |
| 5 | int32 | varint | `usage` |
| 6 | string | length-delimited | `device_name` |
| 7 | string | length-delimited | `device_model` |
| 8 | string | length-delimited | `device_serial` |
| 9 | uint32 | varint | `device_provisioning_id` |

### `CMsgRemoteDeviceAuthorizationCancelRequest`

No fields.

### `CMsgRemoteDeviceAuthorizationResponse`

| field | type | wire | name |
|---|---|---|---|
| 1 | `ERemoteDeviceAuthorizationResult` (enumeration) | varint | `result` |
| 2 | fixed64 | 64-bit | `steamid` |
| 3 | bytes | length-delimited | `auth_key` |
| 4 | bytes | length-delimited | `device_token` |

### `CMsgRemoteDeviceAuthorizationConfirmed`

| field | type | wire | name |
|---|---|---|---|
| 1 | `ERemoteDeviceAuthorizationResult` (enumeration) | varint | `result` |

### `CMsgRemoteDeviceStreamingRequest`

| field | type | wire | name |
|---|---|---|---|
| 1 | uint32 | varint | `request_id` |
| 2 | int32 | varint | `maximum_resolution_x` |
| 3 | int32 | varint | `maximum_resolution_y` |
| 4 | int32 | varint | `audio_channel_count` |
| 5 | string | length-delimited | `device_version` |
| 6 | bool | varint | `stream_desktop` |
| 7 | bytes | length-delimited | `device_token` |
| 8 | bytes | length-delimited | `pin` |
| 9 | bool | varint | `enable_video_streaming` |
| 10 | bool | varint | `enable_audio_streaming` |
| 11 | bool | varint | `enable_input_streaming` |
| 12 | bool | varint | `network_test` |
| 13 | uint64 | varint | `client_id` |
| 14 | repeated int32 | varint | `supported_transport` |
| 15 | bool | varint | `restricted` |
| 16 | int32 | varint | `form_factor` |
| 17 | int32 | varint | `gamepad_count` |
| 19 | uint64 | varint | `gameid` |
| 20 | int32 | varint | `stream_interface` |

### `CMsgRemoteDeviceStreamingCancelRequest`

| field | type | wire | name |
|---|---|---|---|
| 1 | uint32 | varint | `request_id` |

### `CMsgRemoteDeviceStreamingProgress`

| field | type | wire | name |
|---|---|---|---|
| 1 | uint32 | varint | `request_id` |
| 2 | float | 32-bit | `progress` |

### `CMsgRemoteDeviceStreamingResponse`

| field | type | wire | name |
|---|---|---|---|
| 1 | uint32 | varint | `request_id` |
| 2 | `ERemoteDeviceStreamingResult` (enumeration) | varint | `result` |
| 3 | uint32 | varint | `port` |
| 4 | bytes | length-delimited | `encrypted_session_key` |
| 6 | int32 | varint | `transport` |
| 7 | string | length-delimited | `relay_server` |
| 8 | string | length-delimited | `cert` |

### `CMsgRemoteDeviceProofRequest`

| field | type | wire | name |
|---|---|---|---|
| 1 | bytes | length-delimited | `challenge` |
| 2 | uint32 | varint | `request_id` |
| 3 | bool | varint | `update_secret` |

### `CMsgRemoteDeviceProofResponse`

| field | type | wire | name |
|---|---|---|---|
| 1 | bytes | length-delimited | `response` |
| 2 | uint32 | varint | `request_id` |
| 3 | bool | varint | `updated_secret` |

### `CMsgRemoteDeviceStreamTransportSignal`

| field | type | wire | name |
|---|---|---|---|
| 1 | bytes | length-delimited | `token` |
| 2 | bytes | length-delimited | `payload` |

## Enumerations

### `EVRLinkCaps`

| number | name |
|---|---|
| 0 | `k_EVRLinkCapsUnknown` |
| 1 | `k_EVRLinkCapsAvailable` |
| 2 | `k_EVRLinkCapsUnimplemented` |
| 3 | `k_EVRLinkCapsMissingHardwareEncoding` |

### `ERemoteDeviceAuthorizationResult`

| number | name |
|---|---|
| 0 | `k_ERemoteDeviceAuthorizationSuccess` |
| 1 | `k_ERemoteDeviceAuthorizationDenied` |
| 2 | `k_ERemoteDeviceAuthorizationNotLoggedIn` |
| 3 | `k_ERemoteDeviceAuthorizationOffline` |
| 4 | `k_ERemoteDeviceAuthorizationBusy` |
| 5 | `k_ERemoteDeviceAuthorizationInProgress` |
| 6 | `k_ERemoteDeviceAuthorizationTimedOut` |
| 7 | `k_ERemoteDeviceAuthorizationFailed` |
| 8 | `k_ERemoteDeviceAuthorizationCanceled` |

### `ERemoteDeviceStreamingResult`

| number | name |
|---|---|
| 0 | `k_ERemoteDeviceStreamingSuccess` |
| 1 | `k_ERemoteDeviceStreamingUnauthorized` |
| 2 | `k_ERemoteDeviceStreamingScreenLocked` |
| 3 | `k_ERemoteDeviceStreamingFailed` |
| 4 | `k_ERemoteDeviceStreamingBusy` |
| 5 | `k_ERemoteDeviceStreamingInProgress` |
| 6 | `k_ERemoteDeviceStreamingCanceled` |
| 7 | `k_ERemoteDeviceStreamingDriversNotInstalled` |
| 8 | `k_ERemoteDeviceStreamingDisabled` |
| 9 | `k_ERemoteDeviceStreamingBroadcastingActive` |
| 10 | `k_ERemoteDeviceStreamingVRActive` |
| 11 | `k_ERemoteDeviceStreamingPINRequired` |
| 12 | `k_ERemoteDeviceStreamingTransportUnavailable` |
| 13 | `k_ERemoteDeviceStreamingInvisible` |
| 14 | `k_ERemoteDeviceStreamingGameLaunchFailed` |
| 15 | `k_ERemoteDeviceStreamingSteamVRNotInstalled` |

Three fields of `CMsgRemoteDeviceStreamingRequest` and one of the response
are enumerations in the full definition and plain integers here; the values
the VR path uses are: `supported_transport` 1 (UDP), 2 (UDP relay), 4 (SDR);
`form_factor` 5 (VR headset); `stream_interface` 4 (SteamVR); the
response's `transport` 0 (none: the VR session is not on the flat
transport). The ticket's `usage` is 0 (streaming device).
