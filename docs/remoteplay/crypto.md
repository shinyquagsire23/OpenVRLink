# Cryptography in the broadcast protocol

The broadcast protocol uses three cryptographic primitives, identified via
**static** analysis of `libshell_arm64-v8a.so` and matching all **captured**
wire lengths (subsequently verified against a live host; see
[Probe results](#probe-results-2026-11-10)).

## Symmetric encryption (`CCrypto::SymmetricEncrypt`, +0xfbf210)

Symmetric encryption uses AES-CBC with PKCS#7 padding and a fresh random
16-byte IV per message. Rather than sending the raw IV, the sender encrypts the
16-byte IV with single-block AES-ECB under the same key and prepends the
encrypted IV to the CBC ciphertext:

```python
def symmetric_encrypt(plaintext, key):          # key is 16 or 32 bytes
    iv = os.urandom(16)
    return aes_ecb_encrypt(key, iv) + aes_cbc_encrypt(key, iv, pkcs7_pad(plaintext))

def symmetric_decrypt(ciphertext, key):
    iv = aes_ecb_decrypt(key, ciphertext[:16])
    return pkcs7_unpad(aes_cbc_decrypt(key, iv, ciphertext[16:]))
```

`CCrypto::SymmetricDecryptRecoverIV` (+0xfbf838) asserts that the key is 16 or
32 bytes and the input is at least 16 bytes. Output length is
`16 + 16 * (len(plaintext) // 16 + 1)`: 8 bytes → 32, 16 → 48, and 70 → 96,
matching the captured byte sizes of `device_token`, the proof response, and the
hex-decoded `cert`.

Ciphertexts carry no MAC or authentication tag; decrypting with the wrong key is
detected only when PKCS#7 unpadding fails or when the decrypted value fails an
application-level check.

## Keys

| key | size | origin | used for |
|---|---|---|---|
| pairing secret | 32 | derived by the PIN key exchange below; persisted per host (Steam Link shell: `<host id>/<steamid>/secret_key.txt`, hex) | `device_token`, proof response, unwrapping the session key |
| session key | 16 (**inferred** from the 48-byte wrapped size) | chosen by the host per streaming request | unwrapping the session string in `cert` |
| transport key | in the `sArgs` token | chosen by the host per session | the SVL transport, [../svl-transport/](../svl-transport/) |

`device_token` is `symmetric_encrypt(u64le(device_id), secret)`
(`CServerManager::BGetDeviceToken`, +0xf98140). Because each call generates a
fresh random IV, `device_token` changes on every packet (**captured**: four
requests produced four distinct tokens).

### Secret rotation

When `CMsgRemoteDeviceProofRequest` sets `update_secret = true`, the client
rotates the pairing secret before computing the proof response:
`secret = SHA-256(secret || challenge)`. It saves the new secret and sets
`updated_secret = true` on `CMsgRemoteDeviceProofResponse`
(`CServerManager::HandleStreamingProofRequest`, +0xf99418). Secret rotation was
never observed on the wire (`update_secret: false` in every capture).

## PIN-masked key exchange

Pairing derives the 32-byte secret with X25519, XOR-masking each side's public
key with `SHA-256(pin)` so only a peer that knows the 4-digit PIN can unmask the
public key and derive the matching shared secret:

```python
pin        = "%04u" % random(1..9999)             # shown to the user
mask       = SHA-256(pin as ASCII)                # 32 bytes
auth_key   = x25519_public XOR mask               # sent in auth_key in both directions
shared     = SHA-256(X25519(my_private, peer_auth_key XOR mask))
```

- PIN and key-pair generation: `CServerManager::GenerateAuthorizationPin` (+0xf945f4).
- Public-key XOR masking: `BCreateAuthorizationRequest` (+0xf983f0) and
  `BHandleKeyExchangeAuthorization` (+0xf98f24).
- Shared-secret derivation: `CCrypto::PerformKeyExchange` (+0xfbed24), calling
  `curve25519_donna` followed by `GenerateSHA256Digest` over the 32-byte DH
  output.

`shared` becomes the pairing secret.

## RSA ticket

`CMsgRemoteDeviceAuthorizationRequest.encrypted_request` contains a serialized
`CKeyEscrow_Ticket` encrypted with RSA-OAEP (SHA-1, OpenSSL padding mode 4) in
chunks of `modulus_bytes - 42` (`CCrypto::RSAEncrypt`, +0xfc25c8), using a
2048-bit public key selected by the host's `euniverse` from a table in
`libshell` rodata (+0x4c5dcc; four base64 DER keys for Public, Beta, Internal,
and Dev). Because only Valve holds the corresponding private keys, this field
supports a legacy server-assisted pairing flow where the host forwards the
ticket to Steam's servers. The Public key is included in
`prototype/minimal/ovrlink/steamcrypto.py`.

## To confirm

- Decrypt a captured `device_token`, proof response, `encrypted_session_key`,
  and `cert` with `vrlink`'s stored secret, or obtain
  `StreamingResponse(Success)` with the Python probe after pairing it. Either
  verifies the symmetric scheme, the session-key size, and the `cert` layout at
  once.
- Whether a host that completes the X25519 key exchange ever inspects
  `encrypted_request`.

## Probe results (2026-11-10)

Running the Python probe to pair and start a session exercised these primitives
against a live host: the symmetric scheme (`device_token`, proof response,
session key, and `cert`), the 16-byte session key size, and the PIN-masked
X25519 key exchange are now **captured by probe**. Secret rotation
(`update_secret`) was not requested by the host and remains **static**.
