// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Low-level cryptographic primitives shared across pairing and transport protocols
/// (`docs/remoteplay/crypto.md`, `docs/svl-transport/session-args-and-crypto.md`,
/// `docs/wivrn/protocol.md`).
///
/// Uses system frameworks (`CryptoKit`, `CommonCrypto`, and `Security`) on Apple
/// platforms and `swift-crypto` elsewhere. Keep the `#if canImport(CommonCrypto)`
/// and `#else` extensions signature-identical.
enum Primitives {
    static let block = 16
}

#if canImport(CommonCrypto)
import CommonCrypto
import CryptoKit
import Security

extension Primitives {
    static func sha256(_ bytes: Bytes) -> Bytes { Bytes(SHA256.hash(data: bytes)) }

    /// Single-block 16-byte AES-ECB permutation using a 16- or 32-byte key.
    static func aesBlock(_ block: Bytes, key: Bytes, encrypting: Bool) -> Bytes? {
        guard block.count == Primitives.block else { return nil }
        return crypt(block, key: key, iv: nil, encrypting: encrypting, options: CCOptions(kCCOptionECBMode))
    }

    /// AES-CBC encryption or decryption. Uses PKCS#7 padding when `padded` is true;
    /// otherwise `bytes.count` must be a multiple of 16. Returns `nil` on invalid
    /// input lengths or bad padding.
    static func aesCBC(_ bytes: Bytes, key: Bytes, iv: Bytes, encrypting: Bool, padded: Bool) -> Bytes? {
        guard iv.count == Primitives.block, padded || bytes.count % Primitives.block == 0 else { return nil }
        return crypt(bytes, key: key, iv: iv, encrypting: encrypting, options: padded ? CCOptions(kCCOptionPKCS7Padding) : 0)
    }

    private static func crypt(_ bytes: Bytes, key: Bytes, iv: Bytes?, encrypting: Bool, options: CCOptions) -> Bytes? {
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256 else { return nil }
        // Encrypt or decrypt directly into uninitialized output storage to avoid
        // zero-filling or extra copies on the per-datagram hot path.
        var status = CCCryptorStatus(kCCSuccess)
        let out = Bytes(unsafeUninitializedCapacity: bytes.count + Primitives.block) { buffer, count in
            var moved = 0
            status = CCCrypt(CCOperation(encrypting ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), options,
                             key, key.count, iv, bytes, bytes.count, buffer.baseAddress, buffer.count, &moved)
            count = status == kCCSuccess ? moved : 0
        }
        return status == kCCSuccess ? out : nil
    }

    /// Encrypts `bytes` using RSA-OAEP-SHA1 with a DER-encoded `SubjectPublicKeyInfo`
    /// key (`bytes.count` must be at most `modulusBytes - 42`).
    static func rsaOAEPSHA1(_ bytes: Bytes, publicKey: Bytes) -> Bytes? {
        // Security.framework expects the inner PKCS#1 RSAPublicKey payload rather than SubjectPublicKeyInfo.
        guard let bare = bareRSAKey(publicKey) else { return nil }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(Data(bare) as CFData, attributes as CFDictionary, nil),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(bytes) as CFData, nil)
        else { return nil }
        return Bytes(encrypted as Data)
    }

    /// Extracts the inner PKCS#1 public key bytes from a DER `SubjectPublicKeyInfo`
    /// (`SEQUENCE { algorithm SEQUENCE, subjectPublicKey BIT STRING }` with 0 unused bits).
    private static func bareRSAKey(_ info: Bytes) -> Bytes? {
        /// Returns the payload byte range of the DER TLV at `start` if its tag matches `tag`.
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

    /// Derives `count` key bytes from `password` and `salt` using PBKDF2-HMAC-SHA1.
    static func pbkdf2SHA1(password: Bytes, salt: Bytes, rounds: Int, count: Int) -> Bytes? {
        var out = Bytes(repeating: 0, count: count)
        let status = password.withUnsafeBytes { secret in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.bindMemory(to: CChar.self).baseAddress, password.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), UInt32(rounds), &out, count)
        }
        return status == Int32(kCCSuccess) ? out : nil
    }

    /// Stateful AES-CTR stream cipher (identical for encryption and decryption)
    /// using a 16-byte big-endian counter incremented across calls.
    final class CounterCipher {
        private var cryptor: CCCryptorRef?

        init?(key: Bytes, counter: Bytes) {
            guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256, counter.count == Primitives.block,
                  CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                          CCPadding(ccNoPadding), counter, key, key.count, nil, 0, 0,
                                          CCModeOptions(kCCModeOptionCTR_BE), &cryptor) == kCCSuccess
            else { return nil }
        }

        deinit { CCCryptorRelease(cryptor) }

        func apply<Run: ContiguousBytes>(_ bytes: Run) -> Bytes {
            bytes.withUnsafeBytes { input in
                Bytes(unsafeUninitializedCapacity: input.count) { buffer, count in
                    var moved = 0
                    let status = CCCryptorUpdate(cryptor, input.baseAddress, input.count, buffer.baseAddress, buffer.count, &moved)
                    count = status == kCCSuccess ? moved : 0
                }
            }
        }
    }

    /// Ephemeral or static key pair for X25519 Diffie-Hellman key agreement.
    struct KeyAgreement {
        private let privateKey: Curve25519.KeyAgreement.PrivateKey

        init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }

        /// Initializes from an existing 32-byte private key (used by tests).
        init?(privateKey: Bytes) {
            guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else { return nil }
            self.privateKey = key
        }

        var publicKey: Bytes { Bytes(privateKey.publicKey.rawRepresentation) }

        /// Computes the 32-byte raw X25519 shared secret with `peerPublicKey`.
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

    /// Single-block 16-byte AES-ECB permutation using a 16- or 32-byte key.
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

    /// AES-CBC encryption or decryption. Uses PKCS#7 padding when `padded` is true;
    /// otherwise `bytes.count` must be a multiple of 16. Returns `nil` on invalid
    /// input lengths or bad padding.
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

    /// Encrypts `bytes` using RSA-OAEP-SHA1 with a DER-encoded `SubjectPublicKeyInfo`
    /// key (`bytes.count` must be at most `modulusBytes - 42`).
    static func rsaOAEPSHA1(_ bytes: Bytes, publicKey: Bytes) -> Bytes? {
        guard let key = try? _RSA.Encryption.PublicKey(derRepresentation: publicKey),
              let encrypted = try? key.encrypt(bytes, padding: .PKCS1_OAEP)
        else { return nil }
        return Bytes(encrypted)
    }

    /// Derives `count` key bytes from `password` and `salt` using PBKDF2-HMAC-SHA1.
    static func pbkdf2SHA1(password: Bytes, salt: Bytes, rounds: Int, count: Int) -> Bytes? {
        let key = try? KDF.Insecure.PBKDF2.deriveKey(from: password, salt: salt, using: .insecureSHA1,
                                                     outputByteCount: count, unsafeUncheckedRounds: rounds)
        return key.map { $0.withUnsafeBytes { Bytes($0) } }
    }

    /// Stateful AES-CTR stream cipher (identical for encryption and decryption)
    /// using a 16-byte big-endian counter incremented across calls.
    final class CounterCipher {
        private let key: Bytes
        private var counter: Bytes
        /// Unused keystream bytes remaining from the current encrypted counter block.
        private var pad = ByteSlice()

        init?(key: Bytes, counter: Bytes) {
            guard key.count == 16 || key.count == 32, counter.count == Primitives.block else { return nil }
            self.key = key
            self.counter = counter
        }

        func apply<Run: ContiguousBytes>(_ bytes: Run) -> Bytes {
            var out = bytes.withUnsafeBytes { Bytes($0) }
            for index in out.indices {
                if pad.isEmpty {
                    pad = (Primitives.aesBlock(counter, key: key, encrypting: true) ?? Bytes(repeating: 0, count: Primitives.block))[...]
                    for place in counter.indices.reversed() {
                        counter[place] &+= 1
                        if counter[place] != 0 { break }
                    }
                }
                out[index] ^= pad.removeFirst()
            }
            return out
        }
    }

    /// Ephemeral or static key pair for X25519 Diffie-Hellman key agreement.
    struct KeyAgreement {
        private let privateKey: Curve25519.KeyAgreement.PrivateKey

        init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }

        /// Initializes from an existing 32-byte private key (used by tests).
        init?(privateKey: Bytes) {
            guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else { return nil }
            self.privateKey = key
        }

        var publicKey: Bytes { Bytes(privateKey.publicKey.rawRepresentation) }

        /// Computes the 32-byte raw X25519 shared secret with `peerPublicKey`.
        func shared(with peerPublicKey: Bytes) -> Bytes? {
            guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey),
                  let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer)
            else { return nil }
            return shared.withUnsafeBytes { Bytes($0) }
        }
    }
}
#endif
