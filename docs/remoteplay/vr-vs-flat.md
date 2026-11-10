# Where Steam Link (flat) and Steam VR Link diverge

Discovery, pairing and the proof are identical. The split is one field of the
streaming request, and everything after the host's response.

## The switch: `stream_interface`

`CMsgRemoteDeviceStreamingRequest.stream_interface` (`EStreamInterface`:
`Default` 0, `RecentGames` 1, `BigPicture` 2, `Desktop` 3, `SteamVR` 4).

**Captured by probe** (`pairing.request_stream`, same paired device, same
host, each request canceled afterwards):

| request | `port` | `transport` | `encrypted_session_key` | `cert` |
|---|---|---|---|---|
| `SteamVR`, form factor VR headset | 0 | `None` (0) | 16-byte key | 192 hex chars: the session string, encrypted with the session key |
| `Default`, form factor VR headset | 27031 | `UDP` (1) | 16-byte key | empty |
| `Default`, form factor Computer | 27031 | `UDP` (1) | 16-byte key | empty |
| `Desktop`, form factor Computer | 27031 | `UDP` (1) | 16-byte key | empty |

So `form_factor` does not select the protocol; `stream_interface` does. A VR
headset asking for `Default` gets an ordinary flat Remote Play session.

## What the client does with each response

**Static**, `CPanelConnect::StartStreaming` in `libshell_arm64-v8a.so` (the
function containing +0xf6d498), which branches on the interface it asked for:

| | VR Link | flat |
|---|---|---|
| session key | used once, to decrypt `cert` | handed to the stream client as hex |
| `cert` | the encrypted session string | passed through as `--cert` when non-empty (a relay certificate) |
| next step | `CShellApplication::StartVRLink(sArgs)` (+0xf80310): launch the VR activity | `CShellApplication::StartStreaming(transport, steamid, server, relay, cert, key)` (+0xf7fa18) |
| handed over | `host~10400~10400~0,0,0~~~~MID0…` | argv: `--transport <EStreamTransport name> --steamid <id64> --server <ip:port> [--relay <r>] [--cert <c>] <session key hex>` |
| stream client | `libvrlink_scene.so` | the `CStreamClient` code (in both `libmain.so` and `libshell`) |
| wire protocol | SVL on UDP 10400 (`../svl-transport/`) | "CStream" on the UDP port in the response (27031), messages in `steammessages_remoteplay.proto` (in the client; see [messages.md](messages.md) for how to recover it) |
| security on the stream | none beyond a session-id checksum | the session key authenticates the connection (`k_EStreamControlAuthenticationRequest`/`Response`); not analyzed here |

The two stream protocols share nothing: `libvrlink_scene.so` has no `CStream*`
symbols, and Klepton's record (STEAMLINK.md SL-7) is that the flat client
pointed at port 10400 reports only CRC failures. That record's conclusion that
the flat client "cannot take the shell's session" is now explained: the shell
had asked for a SteamVR session, so no flat session existed on the host.

The flat protocol opens with a setup sequence the VR one does not have
(`EStreamControlMessage`: `AuthenticationRequest` 1, `AuthenticationResponse`
2, `NegotiationInit` 3, `NegotiationSetConfig` 4, `NegotiationComplete` 5,
`ClientHandshake` 6, `ServerHandshake` 7), on channels `Discovery` 0,
`Control` 1, `Stats` 2, data from 3. Codec, resolution and bitrate are
negotiated there; SVL negotiates none of them.

## A bridge between the two

`steammessages_remoteplay.proto` has `k_EStreamControlVRConnectionReady = 145`
carrying `CVRConnectionReady { optional string connect_params = 1; }`.
**Inferred**: a host can tell an already-connected *flat* client that a VR
session is ready and give it the session string, so that the shell can switch
to VR mid-stream (for example when SteamVR is launched from Big Picture).
Not observed.

## Open questions

- What makes the shell choose `SteamVR`. Its `settings.ini` has
  `streamInterface=0` while the request on the wire says 4; Klepton's record is
  that the choice does not depend on the device presenting as a Quest.
  **Inferred**: the host's `vr_link_caps` in Status, or which tile the user
  picked.
- Whether a flat session and a VR session can exist at once for one device,
  and what `RecentGames` / `BigPicture` change on the host.
- The flat handshake on 27031 has not been captured. Klepton can run the flat
  client (`libmain.so`), which so far has only been pointed at VR sessions;
  given a `Default` session from the probe's `request_stream` it should
  connect.
