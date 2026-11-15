# Pairing (device authorization)

Pairing runs once per host to establish a shared 32-byte pairing secret
([crypto.md](crypto.md)). Initial documentation here came from **static**
analysis of `CServerManager` in `libshell_arm64-v8a.so` (since initial Klepton
captures used an already-paired headset), and was subsequently verified on the
wire using the Python probe's `pair` command and the Swift client.

## Triggering pairing

An unpaired client starts by sending a normal `StreamingRequest`
([session-request.md](session-request.md)) with a `device_token` encrypted under
a local secret that the host has never seen. When the host replies with
`StreamingResponse { result: k_ERemoteDeviceStreamingUnauthorized }`, the client
transitions into device authorization (`HandleStartStreamingResponse`,
+0xf998fc, case 1 → `SendAuthorizeDeviceRequest`). This corresponds to the Steam
Link shell's "Start Pairing" screen.

## Messages

### 1. `DeviceAuthorizationRequest` (3), client → host

```proto
message CMsgRemoteDeviceAuthorizationRequest {
    required bytes device_token = 1;      // symmetric_encrypt(u64le(device_id), current secret)
    optional string device_name = 2;      // shown on the host; at most 64 chars
    required bytes encrypted_request = 3; // RSA ticket, see below
    optional bytes auth_key = 4;          // x25519_public XOR SHA-256(pin), 32 bytes
    optional uint32 request_id = 5;       // same id the streaming request used
}
```

The ticket inside `encrypted_request`
(`BCreateAuthorizationRequest`, +0xf983f0):

| ticket field | value |
|---|---|
| `password` | the PIN, four ASCII digits |
| `identifier` | the device id |
| `payload` | the client's current 32-byte secret |
| `usage` | 0 (`k_EKeyEscrowUsageStreamingDevice`), set explicitly |
| `device_name` | ≤ 64 chars |
| `device_model` | ≤ 64 chars |
| `device_serial` | ≤ 32 chars |
| `device_provisioning_id` | u32 |
| `timestamp` | not set |

The client logs `Sending authorization request with pin %s` and resends the
request every 3 s (`SendAuthorizeDeviceRequest`, +0xf95834).

The client generates a 4-digit PIN via `random u32 % 10000` (retrying on zero),
formats it as `%4.4u`, and generates a fresh X25519 key pair
(`GenerateAuthorizationPin`, +0xf945f4). The client displays the PIN to the
user, who enters it into the pairing dialog Steam opens on the host.

### 2. `DeviceAuthorizationResponse` (4), host → client

```proto
message CMsgRemoteDeviceAuthorizationResponse {
    required ERemoteDeviceAuthorizationResult result = 1;
    optional fixed64 steamid = 2;
    optional bytes auth_key = 3;      // host's x25519_public XOR SHA-256(pin)
    optional bytes device_token = 4;  // symmetric_encrypt(u64le(device_id), shared)
}
```

`result` values: `Success` 0, `Denied` 1, `NotLoggedIn` 2, `Offline` 3,
`Busy` 4, `InProgress` 5, `TimedOut` 6, `Failed` 7, `Canceled` 8.
`InProgress` indicates that the host is still waiting for the PIN, so the client
continues polling.

On `Success` (`HandleDeviceAuthorizationResponse`, +0xf98988):

- **Key-exchange path (`auth_key` present)**
  (`BHandleKeyExchangeAuthorization`, +0xf98f24):
  1. `auth_key` must be 32 bytes.
  2. `shared = SHA-256(X25519(private, auth_key XOR SHA-256(pin)))`.
  3. `symmetric_decrypt(device_token, shared)` must be 8 bytes equal to the
     client's device id. This verifies the PIN: an incorrect PIN yields the
     wrong `shared` key and decryption fails.
  4. `shared` replaces the stored secret
     (`SavePersistentClientKey(host id, steamid, …)`).
  5. A failed check increments the attempt counter; after three failures, the
     client aborts (`too many PIN attempts, aborting`). Duplicate responses
     carrying identical `auth_key` bytes reuse the previous verdict without
     counting an extra attempt.
- **Legacy escrow path (`auth_key` absent)**: Steam's servers decrypted the RSA
  ticket, so the secret the client placed in `payload` becomes the shared
  pairing secret and the client saves it directly.

`steamid` is recorded against the host in both cases.

### 3. `DeviceAuthorizationConfirmed` (14), client → host

```proto
message CMsgRemoteDeviceAuthorizationConfirmed {
    required ERemoteDeviceAuthorizationResult result = 1;
}
```

Sent only on the key-exchange path, carrying the verdict from step 3 above
(`Success`, or `Denied` on a failed check). A response from a host the client is
not actively pairing with is answered with `Canceled` (8).

After confirming `Success`, the client immediately calls
`SendStartStreamingRequest`.

### Cancel

If the user cancels pairing, the client sends `DeviceAuthorizationCancelRequest`
(9) with an empty body.

## Cloud pairing channel

`CRemoteClientSession` in `libshell` (`StartPairing`, `SetPairingInfo`,
`RegisterForStatusUpdates`, backed by a `wss://…steamserver.net/remoteplay/`
WebSocket) implements a separate cloud-mediated pairing and status channel.
Direct LAN pairing does not require it: in captured runs, both HTTPS bootstrap
requests failed (`CURL error 35`), yet discovery, proof challenges, and session
startup all succeeded.

## To confirm on the wire

- Verify the complete exchange from the probe (`python3 -m ovrlink pair <host>`).
- Check which pairing path a current Windows host selects (key exchange
  expected).
- Check whether the host opens the PIN dialog without receiving a prior
  `StreamingRequest`.
- Measure the count and interval of `InProgress` responses while the PIN dialog
  is open.

## Probe results (2026-11-10)

Tested with `python3 -m ovrlink pair` against Steam for Windows (broadcast
version 8). All **captured by probe**:

- A `StreamingRequest` from the unknown device received
  `StreamingResponse { result: Unauthorized }`.
- The host used the **key-exchange path**: its `AuthorizationResponse(Success)`
  carried a 32-byte `auth_key`, the derived secret decrypted `device_token` to
  the probe's device id, and the same secret subsequently authenticated the
  proof challenge and decrypted the session key. This confirms the PIN mask, the
  post-X25519 SHA-256 hash, and the symmetric encryption scheme.
- The host opened its PIN dialog on an `AuthorizationRequest` sent from an
  ephemeral UDP port with empty `device_model` and `device_serial` fields in the
  RSA ticket. (The Swift client populates both, setting `device_model` to
  `"Apple Vision Pro"` and `device_serial` to 16 random hex digits generated
  once per installation; whether the host uses either field is unknown.)
- Still open: whether the host inspects `encrypted_request` at all, and the
  count and interval of `InProgress` responses (the probe did not log them).

## Client results (2026-11-10)

The Swift client (`client`, `VRLinkCore/Broadcast.swift`) paired a fresh device
identity with the same host via PIN and proceeded directly to streaming. Having
a second independent implementation—built on `swift-crypto` rather than Python's
`cryptography`—complete the exchange confirms the key-exchange path, including
RSA-OAEP with SHA-1 for the escrow ticket. The host accepted an
`AuthorizationRequest` sent immediately after its `Unauthorized` streaming
response from the same ephemeral port.
