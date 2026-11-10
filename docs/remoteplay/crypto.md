# Cryptography in the broadcast protocol

Three primitives, all **static** from `libshell_arm64-v8a.so` and consistent
with every length **captured** on the wire. They have not yet been checked by
decrypting captured fields — see "To confirm".

## Symmetric encryption (`CCrypto::SymmetricEncrypt`, +0xfbf210)

AES in CBC mode with PKCS#7 padding, under a fresh random 16-byte IV. The IV is
not sent in the clear: it is AES-ECB-encrypted under the same key and put in
front.

```python
def symmetric_encrypt(plaintext, key):          # key is 16 or 32 bytes
    iv = os.urandom(16)
    return aes_ecb_encrypt(key, iv) + aes_cbc_encrypt(key, iv, pkcs7_pad(plaintext))

def symmetric_decrypt(ciphertext, key):
    iv = aes_ecb_decrypt(key, ciphertext[:16])
    return pkcs7_unpad(aes_cbc_decrypt(key, iv, ciphertext[16:]))
```

`CCrypto::SymmetricDecryptRecoverIV` (+0xfbf838) asserts the key is 16 or 32
bytes and the input is at least 16. Output length is
`16 + 16 * (len(plaintext) // 16 + 1)`: 8 bytes → 32, 16 → 48, 70 → 96, which
are exactly the captured sizes of `device_token`, the proof response and the
decoded `cert`.

There is no MAC. A wrong key shows up only as bad padding.

## Keys

| key | size | origin | used for |
|---|---|---|---|
| pairing secret | 32 | made by the key exchange below; stored per host (vrlink: `<host id>/<steamid>/secret_key.txt`, hex) | `device_token`, proof response, unwrapping the session key |
| session key | 16 (**inferred** from the 48-byte wrapped size) | chosen by the host per streaming request | unwrapping the session string in `cert` |
| transport key | in the `sArgs` token | chosen by the host per session | the SVL transport, [../svl-transport/](../svl-transport/) |

`device_token` is `symmetric_encrypt(u64le(device_id), secret)`
(`CServerManager::BGetDeviceToken`, +0xf98140). It changes on every send
because the IV does — **captured**: four requests, four different tokens.

### Secret rotation

A `CMsgRemoteDeviceProofRequest` with `update_secret = true` replaces the
secret before the proof is computed: `secret = SHA-256(secret || challenge)`,
saved, and the response carries `updated_secret = true`
(`CServerManager::HandleStreamingProofRequest`, +0xf99418). Not seen on the
wire (`update_secret: false` in every capture).

## PIN-masked key exchange

Pairing derives the secret with X25519, each public key hidden under a hash of
the PIN so that only someone who knows the PIN can complete it:

```python
pin        = "%04u" % random(1..9999)             # shown to the user
mask       = SHA-256(pin as ASCII)                # 32 bytes
auth_key   = x25519_public XOR mask               # what goes on the wire, both ways
shared     = SHA-256(X25519(my_private, peer_auth_key XOR mask))
```

- PIN and key pair: `CServerManager::GenerateAuthorizationPin` (+0xf945f4).
- Masking: `BCreateAuthorizationRequest` (+0xf983f0) and
  `BHandleKeyExchangeAuthorization` (+0xf98f24).
- The hash after the curve: `CCrypto::PerformKeyExchange` (+0xfbed24),
  `curve25519_donna` then `GenerateSHA256Digest` over the 32-byte output.

`shared` becomes the pairing secret.

## RSA ticket

`CMsgRemoteDeviceAuthorizationRequest.encrypted_request` is a serialized
`CKeyEscrow_Ticket` encrypted with RSA-OAEP (SHA-1, OpenSSL padding mode 4) in
chunks of `modulus_bytes - 42` (`CCrypto::RSAEncrypt`, +0xfc25c8), to a
2048-bit key selected by the host's `euniverse` from a table in the client
(libshell rodata +0x4c5dcc; four base64 DER keys for Public, Beta, Internal,
Dev). Only Valve holds the private keys: this is the older pairing route, in
which the host forwards the ticket to Steam's servers. The Public key is in
`prototype/minimal/ovrlink/steamcrypto.py`.

## To confirm

- Decrypt a captured `device_token`, proof response, `encrypted_session_key`
  and `cert` with vrlink's stored secret, or (equivalently) get a
  `StreamingResponse(Success)` with the Python probe after pairing it. Either
  proves the symmetric scheme, the session-key size and the `cert` layout at
  once.
- Whether a host that completes the key exchange ever looks at
  `encrypted_request`.

## Probe results (2026-11-10)

The probe paired and then started a session, which exercises every primitive
on this page against a real host: the symmetric scheme (device token, proof
response, session key, `cert`), the 16-byte session key, and the PIN-masked
key exchange are now **captured by probe**. Secret rotation
(`update_secret`) was not requested and remains static.
