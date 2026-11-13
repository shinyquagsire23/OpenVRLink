# Pairing (device authorization)

Done once per host. Its only product is the 32-byte pairing secret
([crypto.md](crypto.md)). Everything here is **static** — read from
`CServerManager` in `libshell_arm64-v8a.so` — because every capture so far was
taken with a device that was already paired. The Python probe's `pair` command
implements this page and is the test of it.

## When it starts

A client that has never paired just sends a `StreamingRequest`
([session-request.md](session-request.md)) with a `device_token` made from a
secret the host has never seen. The host answers
`StreamingResponse { result: k_ERemoteDeviceStreamingUnauthorized }`, and the
client goes to authorization (`HandleStartStreamingResponse`, +0xf998fc,
case 1 → `SendAuthorizeDeviceRequest`). The shell's "Start Pairing" screen is
this state.

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

The PIN is `random u32 % 10000`, redrawn while zero, formatted `%4.4u`, and a
fresh X25519 key pair is made with it (`GenerateAuthorizationPin`, +0xf945f4).
The client displays the PIN, and the user types it into the dialog Steam raises 
on the host.

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
`InProgress` means "still waiting for the PIN"; keep going.

On `Success` (`HandleDeviceAuthorizationResponse`, +0xf98988):

- **With `auth_key`** — the key-exchange route
  (`BHandleKeyExchangeAuthorization`, +0xf98f24):
  1. `auth_key` must be 32 bytes.
  2. `shared = SHA-256(X25519(private, auth_key XOR SHA-256(pin)))`.
  3. `symmetric_decrypt(device_token, shared)` must be exactly 8 bytes equal to
     the client's device id. This is the PIN check: a wrong PIN gives a wrong
     `shared` and the decrypt fails.
  4. `shared` replaces the stored secret
     (`SavePersistentClientKey(host id, steamid, …)`).
  5. A failed check counts as an attempt; after three, the client gives up
     (`too many PIN attempts, aborting`). The same response received again is
     recognized by its `auth_key` bytes and gets the same verdict without
     costing an attempt.
- **Without `auth_key`** — the legacy route: Steam's servers opened the RSA
  ticket, so the secret the client put in `payload` is now the shared one, and
  the client just saves it.

`steamid` is recorded against the host in both cases.

### 3. `DeviceAuthorizationConfirmed` (14), client → host

```proto
message CMsgRemoteDeviceAuthorizationConfirmed {
    required ERemoteDeviceAuthorizationResult result = 1;
}
```

Sent only on the key-exchange route, carrying the verdict from step 3 above
(`Success`, or `Denied` for a failed check). A response arriving from a host
the client is not currently pairing with is answered with `Canceled` (8).

Then the client goes straight back to `SendStartStreamingRequest`.

### Cancel

`DeviceAuthorizationCancelRequest` (9), empty body, when the user backs out.

## Not on this path

`CRemoteClientSession` in libshell (`StartPairing`, `SetPairingInfo`,
`RegisterForStatusUpdates`, a `wss://…steamserver.net/remoteplay/` websocket)
is a second, cloud-mediated pairing and status channel. LAN pairing does not
depend on it: in the captured runs both HTTPS requests that bootstrap it failed
(`CURL error 35`) and discovery, proof and session start all still worked.

## To confirm on the wire

- The whole exchange, from the probe: `python3 -m ovrlink pair <host>`.
- Which route a current Windows host takes (key exchange expected).
- Whether the host shows the PIN dialog without the client first sending a
  `StreamingRequest`.
- How many `InProgress` responses arrive, and at what interval, while the
  dialog is open.

## Probe results (2026-11-10)

`python3 -m ovrlink pair` against Steam for Windows (broadcast version 8).
All **captured by probe**:

- A `StreamingRequest` from the unknown device was answered
  `StreamingResponse { result: Unauthorized }`.
- The host took the **key-exchange route**: its `AuthorizationResponse(Success)`
  carried a 32-byte `auth_key`, the derived secret decrypted `device_token` to
  the probe's device id, and the secret then worked for the proof and session
  key. So the PIN mask, the SHA-256 after X25519, and the symmetric scheme are
  all confirmed.
- The host raised its PIN dialog on an `AuthorizationRequest` sent from an
  ephemeral UDP port, with an RSA ticket whose model and serial were empty.
  (The client now fills them in: the model as "Apple Vision Pro", the serial
  as 16 hex digits made up once per installation. What the host does with
  either is not known.)
- Still open: whether the host reads `encrypted_request` at all, and the
  count and spacing of `InProgress` responses (the probe did not log them).

## Client results (2026-11-10)

The Swift client (`client`, `VRLinkCore/Broadcast.swift`) paired a
fresh device identity with the same host by PIN and went straight on to
streaming. A second, independent implementation of this page - on
swift-crypto rather than Python's `cryptography` - reaching the same result
confirms the key-exchange route, including RSA-OAEP with SHA-1 for the ticket.
The host accepted an `AuthorizationRequest` sent right after its
`Unauthorized` streaming response, from the same ephemeral port.
