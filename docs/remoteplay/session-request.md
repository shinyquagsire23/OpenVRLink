# Starting a session, and where `sArgs` comes from

## Exchange

**Captured** end to end with an already-paired device (times from one run):

| t | direction | message |
|---|---|---|
| 0.0 s | → | `StreamingRequest` |
| +0.2 s | ← | `ProofRequest { challenge: 16 bytes, request_id, update_secret: false }` |
| | → | `ProofResponse { response: 48 bytes, request_id, updated_secret: false }` |
| +1 s | → | `StreamingRequest` again (new `device_token`, same `request_id`) |
| | ← | `StreamingResponse { request_id, result: InProgress }` |
| +2 s, +3 s | → | `StreamingRequest` again, once a second |
| ~+4 s | ← | `StreamingResponse { request_id, result: Success, port: 0, encrypted_session_key: 48 bytes, transport: k_EStreamTransportNone, relay_server: "", cert: 192 hex chars }` |

The client resends the request every second until a final answer arrives
(`SendStartStreamingRequest`, +0xf94690: next send at `time() + 1`), and drops
any message whose `request_id` is not the current one (`Received stale …`).
The roughly four seconds is the host starting SteamVR.

### `StreamingRequest` (5)

As sent by the VR client — **captured**:

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

`stream_interface = 4` is what makes this a VR Link request rather than a flat
Remote Play one. The resolution is the shell's 2D panel size and is
**inferred** to be irrelevant to VR (the stream came up at 1536x6144).

### Proof

`response = symmetric_encrypt(challenge, secret)`
(`HandleStreamingProofRequest`, +0xf99418). 16 bytes of challenge become 48
bytes: wrapped IV, one data block, one block of padding — **captured** length.
See [crypto.md](crypto.md) for `update_secret`.

A host that does not recognize the device answers
`StreamingResponse { result: Unauthorized }` instead; go to
[pairing.md](pairing.md).

### `StreamingResponse` (6)

`result` (`ERemoteDeviceStreamingResult`): `Success` 0, `Unauthorized` 1,
`ScreenLocked` 2, `Failed` 3, `Busy` 4, `InProgress` 5, `Canceled` 6,
`DriversNotInstalled` 7, `Disabled` 8, `BroadcastingActive` 9, `VRActive` 10,
`PINRequired` 11, `TransportUnavailable` 12, `Invisible` 13,
`GameLaunchFailed` 14, `SteamVRNotInstalled` 15.

For a VR Link session the Remote Play fields are empty (`port: 0`,
`transport: None`, no relay) and the session travels in two fields:

1. `session_key = symmetric_decrypt(encrypted_session_key, secret)`
   (`BSaveEncryptedSessionKey`, +0xf98244).
2. `text = symmetric_decrypt(unhex(cert), session_key)`
   (`CPanelConnect::StartStreaming`, +0xf6d498 region, the
   `stream_interface == SteamVR` branch).
3. If `text` starts with `~`, the session string is the host's IP address (as
   the client knows it, no port) followed by `text`; otherwise it is `text`
   as given.

That string is passed to `CShellApplication::StartVRLink(char const*)`
(+0xf80310), which on Android launches the VR activity with it as the `sArgs`
intent extra.

`cert` is a misnomer inherited from Remote Play, where the field carries a
certificate for the flat stream. Here it is the encrypted session string.

## The session string

**Captured** (token redacted):

```
192.0.2.10~10400~10400~0,0,0~~~~MID0<44 base64 chars>
[0] host     [1]   [2]   [3]   [4][5][6] [7] token
```

| field | meaning |
|---|---|
| 0 | host address (prepended by the client, see step 3) |
| 1, 2 | UDP port, twice — 10400 both times in every capture. **Inferred**: one is the host's port and one the client's; see the transport docs |
| 3 | `sStartInfo`, three comma-separated integers. `0,0,0` in this project's captures, `0,0,1` in an older Klepton record. Meaning unknown |
| 4–6 | empty |
| 7 | transport key: a four-character identifier (`MID0`) then URL-safe base64 of 32 bytes. See [../svl-transport/](../svl-transport/) |

The host's part is 70 characters, which encrypts to the 96 bytes (192 hex
characters) seen in `cert`.

A session string is good for about one connection: Klepton's record
(STEAMLINK.md §2.3) is that reusing one gets no replies from the host at all.

## Cancel

`DeviceStreamingCancelRequest { request_id }` (10). The client also sends it in
answer to an `InProgress` response that carries a stale `request_id`.

## To confirm

- Steps 1–3 by actually decrypting: blocked so far only on a pairing secret
  the probe owns (vrlink's stored secret was deliberately left
  unread).
- What the host does if SteamVR is already running, or a headset is already
  connected (`VRActive`? `Busy`?).
- The three integers of `sStartInfo`.
- How long after `Success` the host waits for the first SVL packet before
  discarding the session.

## Probe results (2026-11-10)

`python3 -m ovrlink session` / `stream` with the probe's own pairing:
steps 1-3 of the `StreamingResponse` handling produced a well-formed session
string (`~10400~10400~0,0,0~~~~MID0` + 44 characters) and the SVL session it
names worked. **Captured by probe.** Ending the probe abruptly after 20 s of
streaming did *not* leave the host deaf to discovery this time, so the earlier
outage is not simply "client vanished mid-stream".
