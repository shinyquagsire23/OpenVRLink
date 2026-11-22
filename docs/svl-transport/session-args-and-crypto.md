# Session args, key ids, and crypto

Source: `SVLDataLink::InitCrypt` (`+0x15b368`), `SVLDataLink::EncModeFromString`
(`+0x15c0fc`), `SVLCrypt::AES128SetKey` (`+0x15e718`),
`SVLCrypt::Base64DecodeInPlace` (`+0x15dba4`),
`SVLCryptAArch64::AES128Encrypt` (`+0x15eb1c`), and `SVLCrypt::CreateCrypt`
(`+0x15e1f4`). Claims are **static** unless marked otherwise; **captured**
refers to `vrlink` log lines and wire traffic in capture `vr3`.

## 1. Token parsing from `sArgs`

The session launch string uses the `~`-delimited format
`sArgs = "<host-ip>~10400~10400~0,0,1~~~~<token>"`.
`InitCrypt(vector<char>& args, int length, SVLTransportMode mode)` (`+0x15b368`,
**static**) scans at most `length` bytes for the seventh `~` delimiter
(`iVar5 == 7`) and treats everything after it as the token. It logs
`SVLDataLink::InitCrypt(...,%d,%d)` (the string length and mode) followed by
`SVLDataLink::InitCrypt() m_TransportMode = %d // %d`, where the second integer
is the distance from the token's first character to the **end of the backing
`std::vector<char>`** rather than the length of the token string.

In capture `vr3` (**captured**), the handoff string was 82 characters across
eight fields: host IP address, `10400`, `10400`, `0,0,0`, three empty fields,
and a 48-character token (`MID0` + 44 base64url characters including padding,
decoding to 32 bytes). `vrlink` logged `InitCrypt(...,82,1)` and
`m_TransportMode = 1 // 990`: because the token starts at byte offset 34, the
backing vector is 1024 bytes long. Every pre-decode length check below compares
against that 990-byte vector remainder, so those checks never fail when `sArgs`
is passed in a 1024-byte buffer; only the decoded base64 byte length is an
effective check. The fourth field in `vr3` was `0,0,0` (compared to `0,0,1` in
Klepton's example above; see `../remoteplay/session-request.md`).

The token starts with `MID0` (a **4-char key identifier**) followed by a
URL-safe base64 payload. `InitCrypt` copies the first 4 bytes into a 5-byte
NUL-terminated buffer (`operator_new(5)`; `*puVar6 = *token` copies 4 bytes and
sets byte 4 to 0), which is why a rejected token logs 4 characters
(`"Unknown / confusing key identifier: %s"`). The base64 key material begins at
**token+4** (immediately after `MID0`).

## 2. Transport mode enum (`EncModeFromString`)

`EncModeFromString(const std::string&)` (`+0x15c0fc`, **static**) lowercases its
argument and compares it against `"open"`, `"id"`, `"mid"`, `"aes"`, and
`"auto"`, returning an `SVLTransportMode`:

| input string        | returns | meaning |
|---------------------|---------|---------|
| `""`, `open`, `auto`| 0       | open / plaintext (`auto` logs `"Defaulting to open mode unless overridden."`) |
| `id`, `mid`         | 1       | XOR0 |
| `aes`               | 2       | AES-128 |
| anything else       | 3       | invalid (→ `"Unknown / confusing key identifier"`) |

`InitCrypt` receives the selected `SVLTransportMode` as a parameter (stored to
`this+0x34 = m_TransportMode`) and branches on it directly without re-parsing
the 4-char key ID. The caller passes the 3-letter prefix of the 4-char key ID
(such as `"mid"` from `MID0` → mode 1) into `EncModeFromString` (**inferred**).

In capture `vr3` (**captured**), `vrlink` logs
`SVLDataLink::InitCrypt() m_TransportMode = 1` and
`Starting session with ID: 01xxxxxx`, and the subsequent UDP 10400 traffic uses
8-byte XOR0 framing with **cleartext ASCII payloads** (`cPhaseOff`,
`cAudBufMax`, `[SVLS] ResetVideoStream`), confirming **mode 1 (unencrypted)**.
The top byte of `session_id` is `0x01` (the mode-1 tag) and its low 3 bytes
match the decoded token prefix (the live token credential itself is omitted
here).

## 3. Mode 1 — XOR0 (no cipher, session ID only)

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

- `session_id` is formed from the first 3 decoded bytes (little-endian) OR'd
  with `0x01000000`, where the top byte `0x01` is the mode tag.
- Mode 1 uses **no encryption key**: `session_id` seeds the per-packet XOR
  checksum (`packet-format.md`), and payload bytes travel in the clear.

## 4. Mode 2 — AES-128-CBC

In mode 2, `InitCrypt` requires `(end - token) >= 0x44` (**68 bytes**: 4-char
key ID + ≥64 base64 chars), passes the raw base64 bytes after the 4-char ID
straight to `AES128SetKey` for **both** the RX cipher (`this+0x20`) and the TX
cipher (`this+0x28`) so both directions share the same key, and logs
`Starting session with AES Mode 0`.

`SVLCrypt::AES128SetKey(vector<char>&)` (`+0x15e718`, **static**) decodes and
loads the key material:

```python
if len(raw_b64) < 0x2a:          # 42 -> return -9
    raise Reject
decoded = base64url_decode(raw_b64)    # into a 256-byte buffer
if len(decoded) < 0x20:          # 32 -> return -100 - n
    raise Reject
# Note: static parameter naming below guessed (key, iv), whereas wire captures
# below proved SetKeyInternal(+0x15e9cc) uses bytes 0..15 as IV and 16..31 as key.
half0 = decoded[0:16]            # SetKeyInternal(this, buf, buf+16)
half1 = decoded[16:32]
set_key_internal(half0, half1)   # vtable slot +0x20
```

`AES128SetKey` consumes **32 decoded bytes** (16-byte IV + 16-byte key,
base64url-encoded; see wire verification below for the half ordering). If a
≥64-char base64 payload were supplied (≥48 decoded bytes), `SetKeyInternal`
would still read only the first 32 bytes; whether extra bytes beyond offset 32
ever occur or serve any purpose is unknown (`SetKeyInternal` is at `+0x15e9cc`).

For encryption, `SVLCryptAArch64::AES128Encrypt` (`+0x15eb1c`) calls
`armv8_enc_aes_cbc_sha1_128` (**AES-128-CBC** hardware path; expanded key
schedule at `crypt+0x28`/`0x38`, IV at `crypt+0x148`). The software fallback
`SVLCryptSoft` uses tiny-AES (`TINY_AES_CBC_encrypt_buffer` and
`TINY_AES_CBC_decrypt_buffer` are exported). `SVLCrypt::CreateCrypt`
(`+0x15e1f4`) benchmarks both implementations via `TestAES` (`"Soft AES PERF:
%f MByte/s"`, `"AArch64 AES PERF: %f MByte/s"`) and selects the faster one
(`s_BestCryptService`: 1 = soft, 5 = aarch64).

Static inspection showed the IV written once at key setup with nothing in
`InternalTX` re-seeding it per packet, suggesting a fixed per-session IV; the
wire tests below confirmed that every datagram decrypts independently from that
fixed session IV.

### Mode 2 on the wire (probe and client results)

Probe and client tests against a SteamVR host with Steam's streaming encryption
enabled (**captured** by probe; with encryption disabled, the host issues `MID0`
mode-1 tokens instead) established the wire behavior:

- The token is `AES0` followed by 44 base64url characters (32 decoded bytes).
  As in mode 1, the 68-byte check in `InitCrypt` does not reject a 48-char
  token when delivered in the 1024-byte `sArgs` vector.
- **Bytes 0..15 are the IV and bytes 16..31 are the AES-128 key** (reversing
  the initial static guess for `SetKeyInternal`'s two pointer arguments). Of
  354 datagrams captured from the host, 351 decrypted to a valid header (byte 7
  == `0x02`, `res == 0`, valid element list) under AES-128-CBC with
  `key = decoded[16:32]` and `IV = decoded[0:16]`; none decrypted with key and
  IV swapped, a zero IV, ECB, CTR, or 32-byte AES-256. The remaining three
  packets were 12-byte sideband rejection frames.
- **Every datagram reuses the same IV**: each packet decrypts independently
  using `decoded[0:16]`, confirming a fixed per-session IV with no cross-packet
  CBC chaining or per-packet nonce derivation.
- Encrypted datagram lengths are multiples of 16 bytes (192 B and 384 B seen
  before video).
- Encrypting outbound client datagrams with the same parameters (zero-padded to
  16 bytes, tag/counter word `0x02000000`) works end-to-end: the probe received
  1,183 decodable HEVC frames in 14 s, and the Swift client streamed at full
  display rate. While the probe was sending with key and IV swapped, the host
  sent its own startup packets plus 12-byte rejection frames and acknowledged
  nothing.

## 5. base64url alphabet

`SVLCrypt::Base64DecodeInPlace` (`+0x15dba4`) looks up each character in a
`std::string` alphabet (`DAT_00d5db70`, a runtime-initialized `.bss` object
whose bytes are not in `.rodata`), explicitly accepting `-` (`0x2d`) and `_`
(`0x5f`) alongside alphanumeric characters and treating `=` (`0x3d`) as
padding/terminator. That matches standard **URL-safe base64** (`A–Z a–z 0–9 -
_`) and Klepton SL-10/11 (`+` is rejected). Decoding uses the standard
4-char→3-byte transform, where a trailing 2- or 3-char group yields 1 or 2
bytes.

## Open questions / to confirm on the wire

- ✅ `MID0` selects mode 1 (XOR0, unencrypted), `session_id` has top byte
  `0x01`, and payloads travel in the clear (confirmed in `vr3`).
- ✅ `session_id = 0x01xxxxxx` matches `vrlink`'s `"Starting session with ID:
  01xxxxxx"` log and seeds the XOR0 checksum in both directions (all 80,035
  datagrams in `vr3` fold to zero with that value).
- ✅ When streaming encryption is enabled on the host, the token uses prefix
  `AES0` (mode 2), `IV = decoded[0:16]`, `key = decoded[16:32]`, and a fixed
  per-session IV reused independently for each datagram (see "Mode 2 on the
  wire").
- What the remaining 29 decoded bytes in the 32-byte `MID0` token are used for.
  `vrlink` reads only the first 3 bytes in mode 1, though 32 bytes matches the
  combined IV + key length consumed by mode 2 (§4), suggesting the host may
  generate a uniform 32-byte token payload in both modes (**inferred**; a probe
  could flip a trailing byte to check whether the host inspects the full token).
- Which caller invokes `InitCrypt` and extracts the prefix passed to
  `EncModeFromString` (`MID0` → `"mid"` → mode 1 remains **inferred**).
- Whether any `AES0` token ever carries decoded bytes beyond offset 32, and
  what purpose they would serve.
