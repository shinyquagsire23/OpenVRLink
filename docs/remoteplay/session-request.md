# Session request and `sArgs`

## Exchange

**Captured** end to end with an already-paired device (timestamps from one run):

| t | direction | message |
|---|---|---|
| 0.0 s | → | `StreamingRequest` |
| +0.2 s | ← | `ProofRequest { challenge: 16 bytes, request_id, update_secret: false }` |
| | → | `ProofResponse { response: 48 bytes, request_id, updated_secret: false }` |
| +1 s | → | `StreamingRequest` again (new `device_token`, same `request_id`) |
| | ← | `StreamingResponse { request_id, result: InProgress }` |
| +2 s, +3 s | → | `StreamingRequest` again, once per second |
| ~+4 s | ← | `StreamingResponse { request_id, result: Success, port: 0, encrypted_session_key: 48 bytes, transport: k_EStreamTransportNone, relay_server: "", cert: 192 hex chars }` |

The client resends `StreamingRequest` once per second until a final response
arrives (`SendStartStreamingRequest`, +0xf94690: schedules next send at
`time() + 1`), ignoring any packet whose `request_id` does not match the active
request (`Received stale …`). The ~4 s `InProgress` window corresponds to the
host launching SteamVR.

### `StreamingRequest` (5)

Fields sent by the Steam Link shell in VR mode — **captured**:

```
request_id: <random u32>
maximum_resolution_x: 1280        maximum_resolution_y: 800
audio_channel_count: 2
device_version: "Android 10"
device_token: <32 bytes>          // symmetric_encrypt(u64le(device_id), secret)
pin: ""                           // present and empty
enable_video_streaming: true      enable_audio_streaming: true
enable_input_streaming: true      network_test: false
client_id: <the HOST's client id> // from its Status header
supported_transport: UDP, UDPRelay, SDR       (1, 2, 4)
restricted: false
form_factor: k_EStreamDeviceFormFactorVRHeadset   (5)
gamepad_count: 0                  gameid: 0
stream_interface: k_EStreamInterfaceSteamVR       (4)
```

Setting `stream_interface = 4` (`k_EStreamInterfaceSteamVR`) selects a VR Link
session instead of a flat Remote Play session. `maximum_resolution_x` and
`maximum_resolution_y` come from the 2D Steam Link shell panel size and are
**inferred** to be ignored for VR sessions (the resulting VR stream ran at
1536x6144).

### Proof

The client replies with `response = symmetric_encrypt(challenge, secret)`
(`HandleStreamingProofRequest`, +0xf99418). Encrypting the 16-byte challenge
produces 48 bytes (16-byte encrypted IV, one 16-byte ciphertext block, and one
16-byte PKCS#7 padding block — **captured** length). See [crypto.md](crypto.md)
for `update_secret`.

If the host does not recognize `device_token`, it replies with
`StreamingResponse { result: Unauthorized }` instead; see
[pairing.md](pairing.md).

### `StreamingResponse` (6)

`result` (`ERemoteDeviceStreamingResult`): `Success` 0, `Unauthorized` 1,
`ScreenLocked` 2, `Failed` 3, `Busy` 4, `InProgress` 5, `Canceled` 6,
`DriversNotInstalled` 7, `Disabled` 8, `BroadcastingActive` 9, `VRActive` 10,
`PINRequired` 11, `TransportUnavailable` 12, `Invisible` 13,
`GameLaunchFailed` 14, `SteamVRNotInstalled` 15.

For a VR Link session, the flat Remote Play connection fields are left empty
(`port: 0`, `transport: None`, `relay_server: ""`), and the SVL session
parameters are carried in `encrypted_session_key` and `cert`:

1. `session_key = symmetric_decrypt(encrypted_session_key, secret)`
   (`BSaveEncryptedSessionKey`, +0xf98244).
2. `text = symmetric_decrypt(unhex(cert), session_key)`
   (`CPanelConnect::StartStreaming`, +0xf6d498 region, the
   `stream_interface == SteamVR` branch).
3. If `text` starts with `~`, the client prepends the host's IP address (without
   a port) to `text` to form the full session string; otherwise it uses `text`
   verbatim.

That string is passed to `CShellApplication::StartVRLink(char const*)`
(+0xf80310), which on Android launches the `vrlink` activity with the string as
the `sArgs` intent extra.

The field name `cert` is inherited from flat Remote Play, where it holds a relay
certificate; in VR Link mode, it carries the hex-encoded encrypted session
string.

## Session string format

**Captured** (token redacted):

```
192.0.2.10~10400~10400~0,0,0~~~~MID0<44 base64 chars>
[0] host     [1]   [2]   [3]   [4][5][6] [7] token
```

| field | meaning |
|---|---|
| 0 | host IP address (prepended by the client in step 3) |
| 1, 2 | UDP port, repeated twice — `10400` in both fields in every capture. **Inferred**: one is the host port and one is the client port; see [../svl-transport/](../svl-transport/) |
| 3 | `sStartInfo`, three comma-separated integers. `0,0,0` in this project's captures, `0,0,1` in an older Klepton log. Meaning unknown |
| 4–6 | empty |
| 7 | transport key: a four-character prefix (`MID0`) followed by 44 characters of URL-safe base64 encoding 32 bytes. See [../svl-transport/](../svl-transport/) |

The host-supplied suffix is 70 ASCII bytes, which encrypts to 96 bytes (192 hex
characters) in `cert`.

Each session string is single-use: per Klepton's notes (STEAMLINK.md §2.3),
reusing a previously consumed session string elicits no replies from the host.

## Cancel

To cancel a pending request, the client sends
`DeviceStreamingCancelRequest { request_id }` (10). It also sends a cancel
message when it receives an `InProgress` response with a stale `request_id`.

## To confirm

- Verify decryption steps 1–3 directly (initially blocked only until the probe
  had its own pairing secret, since `vrlink`'s stored secret was left unread).
- Host behavior when SteamVR is already running or another headset is already
  connected (`VRActive` vs. `Busy`).
- Meaning of the three integers in `sStartInfo`.
- How long after `Success` the host waits for the initial SVL packet before
  expiring the session.

## Probe results (2026-11-10)

Running `python3 -m ovrlink session` and `stream` using the probe's own pairing
key confirmed steps 1–3 of `StreamingResponse` handling: decryption yielded a
well-formed session string (`~10400~10400~0,0,0~~~~MID0` + 44 characters) and
the resulting SVL session connected normally (**captured by probe**). Stopping
the probe abruptly after 20 s of streaming did *not* leave the host unresponsive
to discovery probes, indicating that the earlier discovery outage is not caused
solely by a client disconnecting mid-stream.
