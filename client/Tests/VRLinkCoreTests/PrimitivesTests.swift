// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore
#if canImport(Security)
import Security
#endif

/// The cryptographic operations against answers worked out by another
/// implementation (Python's `cryptography`), so that whichever half of
/// `Primitives` is built here is known to be right.
final class PrimitivesTests: XCTestCase {
    private let key32 = Bytes(0..<32), key16 = Bytes(16..<32), iv = Bytes(0xA0..<0xB0)
    private let block = Bytes(hex: "00112233445566778899aabbccddeeff")!

    func testSHA256() {
        XCTAssertEqual(Primitives.sha256(Bytes("abc".utf8)).hex,
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testAESOnOneBlock() throws {
        for (key, answer) in [(key32, "8ea2b7ca516745bfeafc49904b496089"), (key16, "e18a556701fe934a34ba4c026b35f6c1")] {
            let encrypted = try XCTUnwrap(Primitives.aesBlock(block, key: key, encrypting: true))
            XCTAssertEqual(encrypted.hex, answer)
            XCTAssertEqual(Primitives.aesBlock(encrypted, key: key, encrypting: false), block)
        }
        XCTAssertNil(Primitives.aesBlock(block + [0], key: key32, encrypting: true))
        XCTAssertNil(Primitives.aesBlock(block, key: Bytes(0..<24), encrypting: true))
    }

    func testAESCBCWithPadding() throws {
        let message = Bytes("The pairing secret is thirty-two bytes.".utf8)
        let answer = "64a1fcb9cd62b8966a91fe927276b5d2ccc0ec488878efdf09b7ebcfc05a573d8175a979b2555c0041e70baec1506b0c"
        let encrypted = try XCTUnwrap(Primitives.aesCBC(message, key: key32, iv: iv, encrypting: true, padded: true))
        XCTAssertEqual(encrypted.hex, answer)
        XCTAssertEqual(Primitives.aesCBC(encrypted, key: key32, iv: iv, encrypting: false, padded: true), message)
        // The wrong key leaves bad padding (or, one time in a few hundred, other bytes).
        XCTAssertNotEqual(Primitives.aesCBC(encrypted, key: Bytes(1..<33), iv: iv, encrypting: false, padded: true), message)
    }

    func testAESCBCWithoutPadding() throws {
        let message = Bytes(0..<48)
        let answer = "3a5eb8fc7284be1035c8c6dc6c30aafa6dd5507a17590a411348b5c7e5d48d8ca3021f3a7062ca0fccc50c23c6f07e6a"
        let encrypted = try XCTUnwrap(Primitives.aesCBC(message, key: key16, iv: iv, encrypting: true, padded: false))
        XCTAssertEqual(encrypted.hex, answer)
        XCTAssertEqual(Primitives.aesCBC(encrypted, key: key16, iv: iv, encrypting: false, padded: false), message)
        XCTAssertNil(Primitives.aesCBC(Bytes(0..<47), key: key16, iv: iv, encrypting: true, padded: false))
    }

    /// Steam's own form: the IV encrypted as one block, then CBC with padding.
    func testSteamSymmetricForm() throws {
        let message = Bytes(0..<8)
        let ciphertext = Bytes(hex: "dc9f01fd76b87c0d0f4be8850b0bece0a17b2f73758182deab94330da00c3860")!
        XCTAssertEqual(SteamCrypto.decrypt(ciphertext, key: key32), message)
        let ours = try XCTUnwrap(SteamCrypto.encrypt(message, key: key32))
        XCTAssertEqual(ours.count, 32)
        XCTAssertEqual(SteamCrypto.decrypt(ours, key: key32), message)
    }

    /// RFC 7748, section 6.1.
    func testX25519() throws {
        let alice = try XCTUnwrap(Primitives.KeyAgreement(
            privateKey: Bytes(hex: "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")!))
        let bob = try XCTUnwrap(Primitives.KeyAgreement(
            privateKey: Bytes(hex: "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")!))
        XCTAssertEqual(alice.publicKey.hex, "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        XCTAssertEqual(bob.publicKey.hex, "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        let shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
        XCTAssertEqual(alice.shared(with: bob.publicKey)?.hex, shared)
        XCTAssertEqual(bob.shared(with: alice.publicKey)?.hex, shared)
    }

    func testPINMaskedExchangeAgrees() throws {
        let headset = SteamCrypto.KeyExchange(), host = SteamCrypto.KeyExchange()
        let ours = try XCTUnwrap(headset.sharedSecret(maskedPeerKey: host.maskedPublicKey(pin: "0420"), pin: "0420"))
        XCTAssertEqual(ours.count, 32)
        XCTAssertEqual(host.sharedSecret(maskedPeerKey: headset.maskedPublicKey(pin: "0420"), pin: "0420"), ours)
        XCTAssertNotEqual(host.sharedSecret(maskedPeerKey: headset.maskedPublicKey(pin: "0420"), pin: "0421"), ours)
    }

    /// The ticket is encrypted to a key only Steam can open with, so all
    /// that shows here is that the key is read and each piece comes out a modulus long.
    func testTicketIsEncryptedInPieces() throws {
        XCTAssertEqual(SteamCrypto.encryptTicket(Bytes(repeating: 7, count: 100))?.count, 256)
        XCTAssertEqual(SteamCrypto.encryptTicket(Bytes(repeating: 7, count: 300))?.count, 512)
    }

    #if canImport(Security)
    /// RSA-OAEP to a key made here, opened again with its private half.
    func testRSAOAEPOpensWithThePrivateKey() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let bare = Bytes(try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data)

        // Wrapped as a SubjectPublicKeyInfo, the form the client's key comes in.
        func der(_ tag: UInt8, _ content: Bytes) -> Bytes {
            [tag, 0x82, UInt8(content.count >> 8), UInt8(content.count & 0xFF)] + content
        }
        let rsaEncryption: Bytes = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let info = der(0x30, rsaEncryption + der(0x03, [0] + bare))

        let message = Bytes("a ticket".utf8)
        let encrypted = try XCTUnwrap(Primitives.rsaOAEPSHA1(message, publicKey: info))
        XCTAssertEqual(encrypted.count, 256)
        let opened = try XCTUnwrap(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA1, Data(encrypted) as CFData, nil))
        XCTAssertEqual(Bytes(opened as Data), message)
    }
    #endif
}
