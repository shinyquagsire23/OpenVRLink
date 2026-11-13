// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The five standard cryptographic operations the protocol is made of
/// (docs/remoteplay/crypto.md, docs/svl-transport/session-args-and-crypto.md),
/// and nothing of the protocol itself.
///
/// On Apple's systems they are the operating system's own (CryptoKit,
/// CommonCrypto and Security), so that the app carries no cryptography of
/// its own. Elsewhere they are swift-crypto's. This is the one place where
/// the core chooses by platform instead of being handed a backend: the two
/// halves below must stay the same, function for function.
enum Primitives {
    static let block = 16
}

#if canImport(CommonCrypto)
import CommonCrypto
import CryptoKit
import Security

extension Primitives {
    static func sha256(_ bytes: Bytes) -> Bytes { Bytes(SHA256.hash(data: bytes)) }

    /// AES on one 16-byte block, as it is (ECB). The key is 16 or 32 bytes.
    static func aesBlock(_ block: Bytes, key: Bytes, encrypting: Bool) -> Bytes? {
        guard block.count == Primitives.block else { return nil }
        return crypt(block, key: key, iv: nil, encrypting: encrypting, options: CCOptions(kCCOptionECBMode))
    }

    /// AES in CBC mode. `padded` is PKCS#7 padding; without it the length
    /// must be a multiple of 16. Nil on a bad length, or bad padding when decrypting.
    static func aesCBC(_ bytes: Bytes, key: Bytes, iv: Bytes, encrypting: Bool, padded: Bool) -> Bytes? {
        guard iv.count == Primitives.block, padded || bytes.count % Primitives.block == 0 else { return nil }
        return crypt(bytes, key: key, iv: iv, encrypting: encrypting, options: padded ? CCOptions(kCCOptionPKCS7Padding) : 0)
    }

    private static func crypt(_ bytes: Bytes, key: Bytes, iv: Bytes?, encrypting: Bool, options: CCOptions) -> Bytes? {
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256 else { return nil }
        var out = Bytes(repeating: 0, count: bytes.count + Primitives.block)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypting ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), options,
                             key, key.count, iv, bytes, bytes.count, &out, out.count, &moved)
        guard status == kCCSuccess else { return nil }
        return Bytes(out.prefix(moved))
    }

    /// RSA-OAEP with SHA-1, to a public key given as a DER
    /// SubjectPublicKeyInfo. `bytes` is at most the modulus less 42 bytes.
    static func rsaOAEPSHA1(_ bytes: Bytes, publicKey: Bytes) -> Bytes? {
        // Security wants the bare RSA key that the SubjectPublicKeyInfo wraps.
        guard let bare = bareRSAKey(publicKey) else { return nil }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(Data(bare) as CFData, attributes as CFDictionary, nil),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(bytes) as CFData, nil)
        else { return nil }
        return Bytes(encrypted as Data)
    }

    /// What a SubjectPublicKeyInfo holds: a sequence of the algorithm's
    /// name and a bit string, whose content (after a byte counting unused
    /// bits) is the key itself.
    private static func bareRSAKey(_ info: Bytes) -> Bytes? {
        /// The content of the DER element at `start`, if it has this tag.
        func content(at start: Int, in bytes: Bytes, tag: UInt8) -> Range<Int>? {
            guard start + 2 <= bytes.count, bytes[start] == tag else { return nil }
            var length = Int(bytes[start + 1]), at = start + 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count >= 1, count <= 4, at + count <= bytes.count else { return nil }
                length = bytes[at..<at + count].reduce(0) { $0 << 8 | Int($1) }
                at += count
            }
            guard at + length <= bytes.count else { return nil }
            return at..<at + length
        }
        let sequence: UInt8 = 0x30, bitString: UInt8 = 0x03
        guard let outer = content(at: 0, in: info, tag: sequence),
              let algorithm = content(at: outer.lowerBound, in: info, tag: sequence),
              let bits = content(at: algorithm.upperBound, in: info, tag: bitString),
              bits.count > 1, info[bits.lowerBound] == 0
        else { return nil }
        return Bytes(info[(bits.lowerBound + 1)..<bits.upperBound])
    }

    /// One side of an X25519 key agreement.
    struct KeyAgreement {
        private let privateKey: Curve25519.KeyAgreement.PrivateKey

        init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }

        /// With a private key that is already known (tests).
        init?(privateKey: Bytes) {
            guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else { return nil }
            self.privateKey = key
        }

        var publicKey: Bytes { Bytes(privateKey.publicKey.rawRepresentation) }

        /// The curve's output for the peer's public key, 32 bytes.
        func shared(with peerPublicKey: Bytes) -> Bytes? {
            guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey),
                  let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer)
            else { return nil }
            return shared.withUnsafeBytes { Bytes($0) }
        }
    }
}

#else
import Crypto
import _CryptoExtras

extension Primitives {
    static func sha256(_ bytes: Bytes) -> Bytes { Bytes(SHA256.hash(data: bytes)) }

    /// AES on one 16-byte block, as it is (ECB). The key is 16 or 32 bytes.
    static func aesBlock(_ block: Bytes, key: Bytes, encrypting: Bool) -> Bytes? {
        guard block.count == Primitives.block, key.count == 16 || key.count == 32 else { return nil }
        var out = block
        let symmetricKey = SymmetricKey(data: key)
        do {
            if encrypting { try AES.permute(&out, key: symmetricKey) } else { try AES.inversePermute(&out, key: symmetricKey) }
        } catch {
            return nil
        }
        return out
    }

    /// AES in CBC mode. `padded` is PKCS#7 padding; without it the length
    /// must be a multiple of 16. Nil on a bad length, or bad padding when decrypting.
    static func aesCBC(_ bytes: Bytes, key: Bytes, iv: Bytes, encrypting: Bool, padded: Bool) -> Bytes? {
        guard key.count == 16 || key.count == 32, padded || bytes.count % Primitives.block == 0,
              let cbcIV = try? AES._CBC.IV(ivBytes: iv)
        else { return nil }
        let symmetricKey = SymmetricKey(data: key)
        let out = encrypting
            ? try? AES._CBC.encrypt(bytes, using: symmetricKey, iv: cbcIV, noPadding: !padded)
            : try? AES._CBC.decrypt(bytes, using: symmetricKey, iv: cbcIV, noPadding: !padded)
        return out.map { Bytes($0) }
    }

    /// RSA-OAEP with SHA-1, to a public key given as a DER
    /// SubjectPublicKeyInfo. `bytes` is at most the modulus less 42 bytes.
    static func rsaOAEPSHA1(_ bytes: Bytes, publicKey: Bytes) -> Bytes? {
        guard let key = try? _RSA.Encryption.PublicKey(derRepresentation: publicKey),
              let encrypted = try? key.encrypt(bytes, padding: .PKCS1_OAEP)
        else { return nil }
        return Bytes(encrypted)
    }

    /// One side of an X25519 key agreement.
    struct KeyAgreement {
        private let privateKey: Curve25519.KeyAgreement.PrivateKey

        init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }

        /// With a private key that is already known (tests).
        init?(privateKey: Bytes) {
            guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else { return nil }
            self.privateKey = key
        }

        var publicKey: Bytes { Bytes(privateKey.publicKey.rawRepresentation) }

        /// The curve's output for the peer's public key, 32 bytes.
        func shared(with peerPublicKey: Bytes) -> Bytes? {
            guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey),
                  let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer)
            else { return nil }
            return shared.withUnsafeBytes { Bytes($0) }
        }
    }
}
#endif
