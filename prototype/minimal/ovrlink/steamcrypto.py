# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The cryptography Steam's pairing protocol uses (docs/remoteplay/crypto.md)."""
import base64
import hashlib
import os

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

BLOCK = 16

# Steam's public-universe RSA key, as embedded in the Steam Link client. The
# pairing ticket is encrypted to it so that only Steam's servers can read it.
UNIVERSE_PUBLIC_RSA_KEY = base64.b64decode(
    "MIIBIDANBgkqhkiG9w0BAQEFAAOCAQ0AMIIBCAKCAQEAx7iQLqQkm17hJPpGiOpb/QJHtQpi"
    "Kk2pm1zomiuqs3S4bwOroZ+mX9yGys5GpE61q0IaadEDeMO4ZyPfwjlb6kqznauRJ2Hj40Or"
    "mCSwRW5X2rre/aTRwcerKF5kfbEYi8z47+WKdZXM3TGEXAz3W4q0snB9IY721GoRXQhfzHVK"
    "dcUN2NAYk2z16WQsZkVjfsO1CUgRuc7tsX0jR4HOVEXC3bOKeHyVhRIWfXovPzR5rCchqt2Y"
    "EZ7oMvMhxinGVyQ0okL1r/UTB87aCCMu9WRg1PGRyPSISj4qFDYXEAxDz1WtH8fHBSB9hoaX"
    "zJsj3u1GB2MvfqVNSYmDPckg5wIBEQ==")


def _ecb(key):
    return Cipher(algorithms.AES(key), modes.ECB())


def symmetric_encrypt(plaintext, key, iv=None):
    """CCrypto::SymmetricEncrypt: AES-CBC with PKCS#7 padding under a random
    IV, with the IV itself AES-ECB-encrypted and put in front."""
    iv = iv or os.urandom(BLOCK)
    pad = BLOCK - len(plaintext) % BLOCK
    encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    body = encryptor.update(plaintext + bytes([pad]) * pad) + encryptor.finalize()
    return _ecb(key).encryptor().update(iv) + body


def symmetric_decrypt(ciphertext, key):
    """Inverse of symmetric_encrypt. Raises ValueError on a wrong key."""
    if len(ciphertext) < 2 * BLOCK or len(ciphertext) % BLOCK:
        raise ValueError("ciphertext is not IV + whole blocks")
    iv = _ecb(key).decryptor().update(ciphertext[:BLOCK])
    decryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    padded = decryptor.update(ciphertext[BLOCK:]) + decryptor.finalize()
    pad = padded[-1]
    if not 1 <= pad <= BLOCK or padded[-pad:] != bytes([pad]) * pad:
        raise ValueError("bad padding (wrong key?)")
    return padded[:-pad]


def rsa_encrypt(plaintext, der_public_key=UNIVERSE_PUBLIC_RSA_KEY):
    """CCrypto::RSAEncrypt: RSA-OAEP(SHA-1), in chunks of modulus-42 bytes."""
    key = serialization.load_der_public_key(der_public_key)
    oaep = padding.OAEP(mgf=padding.MGF1(hashes.SHA1()), algorithm=hashes.SHA1(), label=None)
    chunk = key.key_size // 8 - 42
    return b"".join(key.encrypt(plaintext[i:i + chunk], oaep)
                    for i in range(0, len(plaintext), chunk))


def pin_mask(pin):
    return hashlib.sha256(pin.encode()).digest()


def xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b, strict=True))


class KeyExchange:
    """One side of the PIN-masked X25519 exchange that pairing runs."""

    def __init__(self):
        self._private = X25519PrivateKey.generate()
        self.public = self._private.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)

    def masked_public(self, pin):
        return xor(self.public, pin_mask(pin))

    def shared_secret(self, masked_peer_public, pin):
        """CCrypto::PerformKeyExchange: SHA-256 of the raw X25519 output."""
        peer = X25519PublicKey.from_public_bytes(xor(masked_peer_public, pin_mask(pin)))
        return hashlib.sha256(self._private.exchange(peer)).digest()
