// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The cryptography of Steam's pairing protocol (docs/remoteplay/crypto.md),
/// built from standard operations that the system provides (`Primitives`).
public enum SteamCrypto {
    static let block = Primitives.block

    /// AES-CBC with PKCS#7 padding under a random IV; the IV itself is
    /// AES-encrypted as a single block and put in front.
    public static func encrypt(_ plaintext: Bytes, key: Bytes) -> Bytes? {
        var generator = SystemRandomNumberGenerator()
        let iv = (0..<block).map { _ in UInt8.random(in: 0...255, using: &generator) }
        guard let wrappedIV = Primitives.aesBlock(iv, key: key, encrypting: true),
              let body = Primitives.aesCBC(plaintext, key: key, iv: iv, encrypting: true, padded: true)
        else { return nil }
        return wrappedIV + body
    }

    /// Nil on a wrong key (bad padding) or malformed input.
    public static func decrypt(_ ciphertext: Bytes, key: Bytes) -> Bytes? {
        guard ciphertext.count >= 2 * block, ciphertext.count % block == 0,
              let iv = Primitives.aesBlock(Bytes(ciphertext.prefix(block)), key: key, encrypting: false)
        else { return nil }
        return Primitives.aesCBC(Bytes(ciphertext.dropFirst(block)), key: key, iv: iv, encrypting: false, padded: true)
    }

    public static func sha256(_ bytes: Bytes) -> Bytes { Primitives.sha256(bytes) }

    static func xor(_ a: Bytes, _ b: Bytes) -> Bytes { zip(a, b).map { $0 ^ $1 } }

    /// Steam's public-universe RSA key, as embedded in the Steam Link client.
    /// The pairing ticket is encrypted to it; only Steam's servers can open it.
    private static let universePublicKey = Data(base64Encoded:
        "MIIBIDANBgkqhkiG9w0BAQEFAAOCAQ0AMIIBCAKCAQEAx7iQLqQkm17hJPpGiOpb/QJHtQpi"
        + "Kk2pm1zomiuqs3S4bwOroZ+mX9yGys5GpE61q0IaadEDeMO4ZyPfwjlb6kqznauRJ2Hj40Or"
        + "mCSwRW5X2rre/aTRwcerKF5kfbEYi8z47+WKdZXM3TGEXAz3W4q0snB9IY721GoRXQhfzHVK"
        + "dcUN2NAYk2z16WQsZkVjfsO1CUgRuc7tsX0jR4HOVEXC3bOKeHyVhRIWfXovPzR5rCchqt2Y"
        + "EZ7oMvMhxinGVyQ0okL1r/UTB87aCCMu9WRg1PGRyPSISj4qFDYXEAxDz1WtH8fHBSB9hoaX"
        + "zJsj3u1GB2MvfqVNSYmDPckg5wIBEQ==")!

    /// RSA-OAEP (SHA-1) in chunks of modulus - 42 bytes.
    static func encryptTicket(_ ticket: Bytes) -> Bytes? {
        let key = Bytes(universePublicKey)
        let chunk = 256 - 42
        var out = Bytes()
        var offset = 0
        while offset < ticket.count {
            let piece = ticket[offset..<min(offset + chunk, ticket.count)]
            guard let encrypted = Primitives.rsaOAEPSHA1(Bytes(piece), publicKey: key) else { return nil }
            out.append(contentsOf: encrypted)
            offset += chunk
        }
        return out
    }

    /// One side of the PIN-masked X25519 exchange that pairing runs: each
    /// public key travels XORed with SHA-256 of the PIN, and the shared secret
    /// is SHA-256 of the curve output.
    struct KeyExchange {
        private let agreement = Primitives.KeyAgreement()

        func maskedPublicKey(pin: String) -> Bytes {
            xor(agreement.publicKey, sha256(Bytes(pin.utf8)))
        }

        func sharedSecret(maskedPeerKey: Bytes, pin: String) -> Bytes? {
            guard maskedPeerKey.count == 32,
                  let shared = agreement.shared(with: xor(maskedPeerKey, sha256(Bytes(pin.utf8))))
            else { return nil }
            return sha256(shared)
        }
    }
}
