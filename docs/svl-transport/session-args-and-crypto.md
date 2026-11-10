# Session args, key ids, and crypto

Source: `SVLDataLink::InitCrypt` (`+0x15b368`), `SVLDataLink::EncModeFromString`
(`+0x15c0fc`), `SVLCrypt::AES128SetKey` (`+0x15e718`),
`SVLCrypt::Base64DecodeInPlace` (`+0x15dba4`),
`SVLCryptAArch64::AES128Encrypt` (`+0x15eb1c`), `SVLCrypt::CreateCrypt`
(`+0x15e1f4`). **Static** unless marked; **captured** means the client's own
log lines and traffic in capture `vr3`.

## 1. From `sArgs` to a token

`sArgs = "<host-ip>~10400~10400~0,0,1~~~~<token>"` — fields split on `~`.
`InitCrypt(vector<char>& args, int length, SVLTransportMode mode)` **static**:
scans at most `length` bytes for the 7th `~` and takes everything after it as
the token (`+0x15b368`, the `iVar5 == 7` loop). It logs
`SVLDataLink::InitCrypt(...,%d,%d)` — the string length and the mode — and
`SVLDataLink::InitCrypt() m_TransportMode = %d // %d`, whose second number is
the distance from the token's first character to the **end of the vector**,
not the token's length.

**Captured** (`vr3`): the handoff string was 82 characters in eight fields —
address, `10400`, `10400`, `0,0,0`, three empty fields, and a 48-character
token (`MID0` + 44 base64url characters including padding, which decode to 32 bytes). The log read
`InitCrypt(...,82,1)` and `m_TransportMode = 1 // 990`: the token starts at
offset 34, so the vector holding the string is 1024 bytes. Every length test
below is made against that 990, which means the tests on the token's length
never fail for a string delivered this way; only the base64 decoder's result
is a real check. The fourth field was `0,0,0` here, where the example above
(from Klepton's notes) has `0,0,1`; its meaning belongs to
`../remoteplay/session-request.md`.

The token is `MID0` (a **4-char key identifier**) followed by a URL-safe
base64 payload. `InitCrypt` copies the first 4 bytes into a 5-byte,
NUL-terminated buffer (`operator_new(5)`; `*puVar6 = *token` copies 4 bytes,
byte 4 set to 0) — this is why a rejected token logs exactly 4 chars
(`Unknown / confusing key identifier: %s`). The key material / payload begins at
**token+4** (i.e. immediately after `MID0`).

## 2. The mode enum (`EncModeFromString`)

`EncModeFromString(const std::string&)` lowercases its argument and returns an
`SVLTransportMode`:

| input string        | returns | meaning |
|---------------------|---------|---------|
| `""`, `open`, `auto`| 0       | open / plaintext (`auto` logs "Defaulting to open mode unless overridden.") |
| `id`, `mid`         | 1       | XOR0 |
| `aes`               | 2       | AES-128 |
| anything else       | 3       | invalid (→ "Unknown / confusing key identifier") |

**static** at `+0x15c0fc` (the `compare` chain against `"open"`, `"id"`, `"mid"`,
`"aes"`, `"auto"`).

`InitCrypt` receives the chosen mode as a parameter (`SVLTransportMode`, stored
to `this+0x34 = m_TransportMode`) and branches on it; the mode is taken from
that parameter and is not re-derived from the 4-char id. **Inferred:** the 4-char id `MID`‑prefix is what
feeds `EncModeFromString` ("mid" → 1).

**CAPTURED:** in the real session the client logs
`SVLDataLink::InitCrypt() m_TransportMode = 1` and
`Starting session with ID: 01xxxxxx`, and the subsequent 10400 traffic is the
8-byte XOR0 framing with **plainly readable ASCII payloads** (`cPhaseOff`,
`cAudBufMax`, `[SVLS] ResetVideoStream`) — i.e. **mode 1, unencrypted**,
exactly as predicted. The session id's top byte is `0x01` (the mode‑1 tag) and
its low 3 bytes match the decoded token prefix. (The token itself is a live
credential and is not reproduced here.)

## 3. Mode 1 — XOR0 (no cipher, session id only)

```python
# remaining = bytes from the token's first character to the end of the args vector
if remaining < 5:                       # no key material: logs "Starting session in mode %d"
    return                              #   and keeps the mode, with no session id set
if remaining < 8:                       # mode 1 only
    raise Reject                        # "Unknown / confusing key identifier: %s"
payload_b64 = token[4:]                 # after "MID0", to the end of the vector
decoded = base64url_decode(payload_b64) # SVLCrypt::Base64DecodeInPlace, into a 1024-byte buffer
if len(decoded) < 5:                    # "Error: XOR0 transport specified, but len too short."
    raise Reject
session_id = (decoded[0] | decoded[1] << 8 | decoded[2] << 16) | 0x01000000
# InitCrypt: *(this+0x30) = *decoded & 0x00ffffff | 0x01000000
m_TransportMode = 1
# logs "Starting session with ID: %08x"
```

- `session_id` = first 3 decoded bytes (little-endian) OR'd with `0x01000000`.
  The top byte `0x01` is the mode tag.
- There is **no encryption key**. `session_id` is the seed for the per-packet
  XOR checksum (see `packet-format.md`). Payload bytes travel in the clear.

## 4. Mode 2 — AES-128-CBC

Entered only when the token payload is long enough: `InitCrypt` requires
`(end - token) >= 0x44` (**68 chars**: `MID`-style 4-char id + ≥64 base64
chars). It passes the raw base64 bytes after the id straight to
`AES128SetKey` for **both** the RX crypt (`this+0x20`) and the TX crypt
(`this+0x28`) — i.e. the same key both directions. Logs
`Starting session with AES Mode 0`.

`SVLCrypt::AES128SetKey(vector<char>&)` **static** `+0x15e718`:

```python
if len(raw_b64) < 0x2a:          # 42 -> return -9
    raise Reject
decoded = base64url_decode(raw_b64)    # into a 256-byte buffer
if len(decoded) < 0x20:          # 32 -> return -100 - n
    raise Reject
key = decoded[0:16]              # SetKeyInternal(this, buf, buf+16)
iv  = decoded[16:32]
set_key_internal(key, iv)        # vtable slot +0x20
```

So the AES key material is **32 decoded bytes = 16-byte key + 16-byte IV**,
base64url-encoded. A ≥64-char payload decodes to ≥48 bytes; only the first 32
are consumed by `SetKeyInternal`. **Unknown:** what (if anything) the extra
decoded bytes beyond 32 are for — _to confirm on the wire / by reading
`SetKeyInternal` at `+0x15e9cc`.._

Cipher: `SVLCryptAArch64::AES128Encrypt` (`+0x15eb1c`) calls
`armv8_enc_aes_cbc_sha1_128` — i.e. **AES-128-CBC** (hardware path; the key
schedule lives at crypt+0x28/0x38, the IV at crypt+0x148). The software
fallback `SVLCryptSoft` uses tiny-AES (`TINY_AES_CBC_encrypt_buffer` /
`TINY_AES_CBC_decrypt_buffer` are exported). `SVLCrypt::CreateCrypt`
(`+0x15e1f4`) benchmarks both with `TestAES` ("Soft AES PERF: %f MByte/s",
"AArch64 AES PERF: %f MByte/s") and keeps the faster (`s_BestCryptService`
1=soft, 5=aarch64).

**Unknown / to confirm:** whether the CBC IV is reset per datagram or reused
from `crypt+0x148` for the whole session. The IV is written once at key setup;
nothing in `InternalTX` was seen re-seeding it, which would mean a fixed
per-session IV (weak, but that is what the static read suggests). _A capture of
two same-length AES datagrams with identical plaintext prefixes would show
whether ciphertext prefixes match (fixed IV) or differ (per-packet IV)._

### Mode 2 on the wire (probe and client results, 2026-11-10)

**Captured by probe** against the real host with Steam's streaming encryption
turned on (with it off the host hands out `MID0` tokens, mode 1):

- The token is `AES0` followed by 44 base64url characters: 32 bytes. (So the
  68-character test above does not bind for a token delivered this way, for
  the same end-of-vector reason as in mode 1.)
- **The first 16 bytes are the IV and the second 16 the key**, the reverse of
  the static reading above. Of 354 datagrams captured from the host, 351
  decrypt to a valid header (byte 7 = 0x02, `res` = 0, element list parses)
  as AES-128-CBC with key = bytes 16..31 and IV = bytes 0..15, and none with
  the halves the other way round, with a zero IV, as ECB, as CTR, or with all
  32 bytes as an AES-256 key. The other three were 12-byte rejection frames.
- **The IV is the same for every datagram**: each one is decrypted from the
  token's IV independently and all are valid. This resolves the question in
  section 4: the IV is fixed per session, neither chained nor per packet.
- Datagram lengths are multiples of 16 (192 and 384 seen before video).
- A client that encrypts its own datagrams the same way (zero-padded by the
  rule above, the counter word `0x02000000`) is accepted: the probe received
  1,183 decodable HEVC frames in 14 s, and `client` streams at the
  display rate. While the probe was sending with the halves swapped, the host
  answered with its own traffic plus rejection frames and acknowledged
  nothing.

## 5. base64url alphabet

`SVLCrypt::Base64DecodeInPlace` (`+0x15dba4`) looks each char up in a
`std::string` alphabet (`DAT_00d5db70`, a runtime-initialized `.bss` object so
its bytes were not statically readable) and explicitly accepts `-` (0x2d) and
`_` (0x5f) in addition to the `isalnum`-class characters, and treats `=`
(0x3d) as padding/terminator. That is standard **URL-safe base64** (`A–Z a–z
0–9 - _`), matching Klepton SL-10/11 (`+` is rejected). Decoding is the
textbook 4-char→3-byte transform; a trailing group of 2 or 3 chars yields 1 or 2
bytes.

## Open questions / to confirm on the wire

- ✅ **Resolved:** `MID0` → mode 1 (XOR0, unencrypted), `session_id` top byte
  `0x01`, payloads in the clear. (Captured again in `vr3`.)
- ✅ **Resolved:** `session_id = 0x01xxxxxx` matches the client's "Starting
  session with ID: 01xxxxxx" log and seeds the XOR0 checksum both directions:
  in `vr3` all 80,035 datagrams fold to zero with that one value.
- What the remaining 29 decoded bytes of the 32-byte mode‑1 token are for.
  The client uses only the first three. 32 bytes is also exactly what mode 2
  would consume as key + IV (§4), so the same token may be usable either way.
  **Inferred**: the host looks the whole token up; a probe could flip a late byte and see whether the session is
  still accepted.
- Who passes the mode to `InitCrypt`, and from what: the caller was not traced,
  so that `MID` → "mid" → mode 1 is still inferred.
- ✅ **Resolved:** mode 2 is what the host uses when streaming encryption is
  on; its id is `AES0`; IV = decoded[0:16], key = decoded[16:32]; the IV is
  fixed for the session (see "Mode 2 on the wire").
- Purpose of decoded bytes beyond offset 32 in the AES payload.
