# Flat Steam Link versus Steam VR Link

Discovery, PIN pairing, and the proof challenge-response are identical for both
protocols. The two paths split at a single field in
`CMsgRemoteDeviceStreamingRequest` and use separate streaming protocols once the
host responds.

## Selecting VR mode with `stream_interface`

`CMsgRemoteDeviceStreamingRequest.stream_interface` selects the session mode
(`EStreamInterface`: `Default` 0, `RecentGames` 1, `BigPicture` 2, `Desktop` 3,
`SteamVR` 4).

**Captured by probe** (`pairing.request_stream`, same paired device, same host,
with each request canceled afterward):

| request | `port` | `transport` | `encrypted_session_key` | `cert` |
|---|---|---|---|---|
| `SteamVR`, form factor VR headset | 0 | `None` (0) | 16-byte key | 192 hex chars: the session string, encrypted with the session key |
| `Default`, form factor VR headset | 27031 | `UDP` (1) | 16-byte key | empty |
| `Default`, form factor Computer | 27031 | `UDP` (1) | 16-byte key | empty |
| `Desktop`, form factor Computer | 27031 | `UDP` (1) | 16-byte key | empty |

`form_factor` does not select the streaming protocol; `stream_interface` does. A
VR headset requesting `Default` receives a standard flat Remote Play session on
UDP port 27031.

## Client response handling

**Static** analysis of `CPanelConnect::StartStreaming` in `libshell_arm64-v8a.so`
(the function containing +0xf6d498), which branches on the requested
`stream_interface`:

| | VR Link | flat |
|---|---|---|
| session key | used once to decrypt `cert` | passed to the stream client as hex |
| `cert` | encrypted session string | passed through as `--cert` when non-empty (a relay certificate) |
| next step | `CShellApplication::StartVRLink(sArgs)` (+0xf80310): launch the VR activity | `CShellApplication::StartStreaming(transport, steamid, server, relay, cert, key)` (+0xf7fa18) |
| arguments passed | `host~10400~10400~0,0,0~~~~MID0…` | argv: `--transport <EStreamTransport name> --steamid <id64> --server <ip:port> [--relay <r>] [--cert <c>] <session key hex>` |
| stream client | `libvrlink_scene.so` (`vrlink`) | `CStreamClient` (present in both `libmain.so` and `libshell`) |
| wire protocol | SVL on UDP 10400 (`../svl-transport/`) | "CStream" on the UDP port from the response (27031), defined in `steammessages_remoteplay.proto` (embedded in the client; see [messages.md](messages.md) for extraction) |
| stream security | session-id checksum only | session key authenticates the connection (`k_EStreamControlAuthenticationRequest`/`Response`); not analyzed here |

The two streaming protocols share no framing or implementation:
`libvrlink_scene.so` exports no `CStream*` symbols, and Klepton's log
(STEAMLINK.md SL-7) shows that pointing the flat `CStreamClient` at port 10400
produces only CRC failures. That also explains Klepton's earlier observation
that the flat client could not attach to a session started by the Steam Link
shell: because the shell had requested `SteamVR`, the host opened an SVL
session on port 10400 rather than a flat Remote Play session on port 27031.

Flat Remote Play opens with a control-channel negotiation sequence that SVL does
not have (`EStreamControlMessage`: `AuthenticationRequest` 1,
`AuthenticationResponse` 2, `NegotiationInit` 3, `NegotiationSetConfig` 4,
`NegotiationComplete` 5, `ClientHandshake` 6, `ServerHandshake` 7) across
channels `Discovery` 0, `Control` 1, `Stats` 2, and data channels starting at 3.
Codec, resolution, and bitrate are negotiated during that handshake, whereas SVL
does not use that negotiation flow.

## Switching from flat Remote Play to VR

`steammessages_remoteplay.proto` defines `k_EStreamControlVRConnectionReady = 145`
carrying `CVRConnectionReady { optional string connect_params = 1; }`.
**Inferred**: this allows a host to notify an already-connected *flat* client
that a VR session is ready and deliver its session string so the Steam Link
shell can hand off to `vrlink` mid-stream (for example, when SteamVR is launched
from Big Picture). This transition has not been observed in captures.

## Open questions

- How the Steam Link shell decides to send `stream_interface = 4` (`SteamVR`).
  Its `settings.ini` contains `streamInterface=0` while wire packets send `4`,
  and Klepton's notes show that the choice does not depend on presenting Quest
  device properties (**inferred**: driven either by `vr_link_caps` in
  `MsgStatus` or by which UI tile the user selects).
- Whether a flat session and a VR session can coexist for a single client
  device, and how `RecentGames` and `BigPicture` affect host behavior.
- The flat Remote Play handshake on port 27031 has not been captured yet.
  Klepton can run the flat client (`libmain.so`), which so far has only been
  pointed at VR sessions; passing it a `Default` session from the probe's
  `request_stream` should connect.
