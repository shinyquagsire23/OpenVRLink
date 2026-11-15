// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Zero-knowledge PIN check used to pair with a WiVRn host without transmitting
/// the PIN over the network (docs/wivrn/protocol.md).
///
/// Implements the Socialist Millionaires' Protocol (SMP) from Off-the-Record
/// Messaging v3 over the 1536-bit MODP group from RFC 3526, using WiVRn's
/// custom hash framing. The headset sends messages 1 and 3, and the host sends
/// messages 2 and 4. This exchange only verifies that both sides entered the
/// same PIN; session encryption keys are derived separately.
struct WiVRnPinCheck {
    enum Failure: Error { case malformed, proofFailed }

    /// Prime modulus for the 1536-bit MODP group (RFC 3526 Group 5).
    static let group = Modulus(Natural(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD
        EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
        EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F
        83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA237327FFFFFFFFFFFFFFFF
        """))
    /// Subgroup order `(p - 1) / 2` used for exponent arithmetic.
    static let order = Modulus(group.value.halved)
    static let generator = Natural(2)

    /// Expected integer count for each of the four SMP messages.
    static let counts = (first: 6, second: 11, third: 8, fourth: 3)

    private let secret: Natural
    /// Ephemeral secret exponents retained by the headset across the four-step exchange.
    private let ownSecond: Natural, ownThird: Natural
    private var second = Natural.zero, third = Natural.zero
    private var hostsThird = Natural.zero
    /// Ratios `P_headset / P_host` and `Q_headset / Q_host` in the group.
    private var ratioP = Natural.zero, ratioQ = Natural.zero
    private let random: () -> Natural

    /// Initializes a PIN check with a random exponent generator (injectable for deterministic tests).
    init(pin: String, random: @escaping () -> Natural = WiVRnPinCheck.randomExponent) {
        secret = Natural(bytes: Bytes(pin.utf8))
        self.random = random
        ownSecond = random()
        ownThird = random()
    }

    static func randomExponent() -> Natural {
        var generator = SystemRandomNumberGenerator()
        return Natural(bytes: (0..<192).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    private var g: Modulus { WiVRnPinCheck.group }
    private var q: Modulus { WiVRnPinCheck.order }

    /// Computes WiVRn's SMP proof hash by taking SHA-256 over version byte `1`,
    /// the `proof` stage ID, and one or two MPI-encoded integers (4-byte big-endian
    /// length prefix, with a leading `0x00` sign byte if bit 7 of the MSB is set),
    /// interpreted as an unsigned big-endian integer.
    static func hash(_ proof: UInt8, _ a: Natural, _ b: Natural? = nil) -> Natural {
        var input: Bytes = [1, proof]
        for number in [a, b].compactMap({ $0 }) {
            var magnitude = number.bytes
            if let top = magnitude.first, top & 0x80 != 0 { magnitude.insert(0, at: 0) }
            input += [UInt8(magnitude.count >> 24 & 0xFF), UInt8(magnitude.count >> 16 & 0xFF),
                      UInt8(magnitude.count >> 8 & 0xFF), UInt8(magnitude.count & 0xFF)]
            input += magnitude
        }
        return Natural(bytes: Primitives.sha256(input))
    }

    /// Checks that a group element lies in `[2, p - 2]` to reject trivial values.
    private func isElement(_ number: Natural) -> Bool {
        Natural(2) <= number && number <= g.value - Natural(2)
    }

    private func isExponent(_ number: Natural) -> Bool {
        Natural(1) <= number && number < q.value
    }

    /// Generates a Schnorr zero-knowledge proof `[c, d]` of knowledge of discrete
    /// log `exponent`, where `c = H(proof, g^r)` and `d = (r - exponent * c) mod q`.
    private func proofOfKnowing(_ exponent: Natural, proof: UInt8) -> [Natural] {
        let r = random()
        let c = WiVRnPinCheck.hash(proof, g.power(WiVRnPinCheck.generator, r))
        return [c, q.subtract(r, q.multiply(exponent, c))]
    }

    /// Verifies a Schnorr proof `(c, d)` that the sender knows the discrete log of `power`.
    private func provesKnowing(_ c: Natural, _ d: Natural, of power: Natural, proof: UInt8) -> Bool {
        c == WiVRnPinCheck.hash(proof, g.multiply(g.power(WiVRnPinCheck.generator, d), g.power(power, c)))
    }

    /// Builds SMP message 1 containing `g^a2` and `g^a3` along with Schnorr proofs for both exponents.
    func first() -> [Natural] {
        [g.power(WiVRnPinCheck.generator, ownSecond)] + proofOfKnowing(ownSecond, proof: 1)
            + [g.power(WiVRnPinCheck.generator, ownThird)] + proofOfKnowing(ownThird, proof: 2)
    }

    /// Validates SMP message 2 from the host and builds SMP message 3.
    mutating func third(answering message: [Natural]) throws -> [Natural] {
        guard message.count == WiVRnPinCheck.counts.second else { throw Failure.malformed }
        let hostsSecond = message[0], hostsP = message[6], hostsQ = message[7]
        hostsThird = message[3]
        guard isElement(hostsSecond), isElement(hostsThird), isElement(hostsP), isElement(hostsQ),
              isExponent(message[2]), isExponent(message[5]), isExponent(message[9]), isExponent(message[10])
        else { throw Failure.malformed }
        guard provesKnowing(message[1], message[2], of: hostsSecond, proof: 3),
              provesKnowing(message[4], message[5], of: hostsThird, proof: 4)
        else { throw Failure.proofFailed }

        // Compute the shared Diffie-Hellman generators g2 and g3.
        second = g.power(hostsSecond, ownSecond)
        third = g.power(hostsThird, ownThird)

        // Verify the host's proof that hostsP = g3^b and hostsQ = g1^b * g2^hostPin.
        let one = WiVRnPinCheck.generator
        let hostsProof = WiVRnPinCheck.hash(
            5, g.multiply(g.power(third, message[9]), g.power(hostsP, message[8])),
            g.multiply(g.multiply(g.power(one, message[9]), g.power(second, message[10])), g.power(hostsQ, message[8])))
        guard hostsProof == message[8] else { throw Failure.proofFailed }

        // Compute our own P = g3^r and Q = g1^r * g2^secret, plus the corresponding proof.
        let r = random()
        let p = g.power(third, r)
        let qValue = g.multiply(g.power(one, r), g.power(second, secret))
        let r5 = random(), r6 = random()
        let c = WiVRnPinCheck.hash(6, g.power(third, r5), g.multiply(g.power(one, r5), g.power(second, r6)))
        let d5 = q.subtract(r5, q.multiply(r, c)), d6 = q.subtract(r6, q.multiply(secret, c))

        // Q_headset / Q_host = g1^(r - b) * g2^(pin_headset - pin_host). Raising
        // that ratio to both sides' third exponents yields P_headset / P_host
        // if and only if the PINs match. Compute our half ((Q_headset / Q_host)^a3) and its proof.
        ratioP = g.multiply(p, g.inverse(hostsP))
        ratioQ = g.multiply(qValue, g.inverse(hostsQ))
        let raised = g.power(ratioQ, ownThird)
        let r7 = random()
        let cRaised = WiVRnPinCheck.hash(7, g.power(one, r7), g.power(ratioQ, r7))
        let d7 = q.subtract(r7, q.multiply(ownThird, cRaised))
        return [p, qValue, c, d5, d6, raised, cRaised, d7]
    }

    /// Validates SMP message 4 from the host and returns whether the two PINs match.
    func matches(_ message: [Natural]) throws -> Bool {
        guard message.count == WiVRnPinCheck.counts.fourth, isElement(message[0]), isExponent(message[2]) else {
            throw Failure.malformed
        }
        let hostsRaised = message[0]
        // Verify that hostsRaised = ratioQ^b3 using the same b3 from hostsThird.
        let proof = WiVRnPinCheck.hash(
            8, g.multiply(g.power(WiVRnPinCheck.generator, message[2]), g.power(hostsThird, message[1])),
            g.multiply(g.power(ratioQ, message[2]), g.power(hostsRaised, message[1])))
        guard proof == message[1] else { throw Failure.proofFailed }
        return g.power(hostsRaised, ownThird) == ratioP
    }
}

/// Derives the AES-CTR keys and IV material for an encrypted WiVRn session (docs/wivrn/protocol.md).
///
/// In WiVRn 26.9, keys end up derived solely from the PIN because the server passes
/// its X448 shared secret to OpenSSL's PBKDF2 under an ignored parameter name,
/// leaving the key agreement output unused (verified against a 26.9 host on
/// 2026-11-14). Previously paired headsets derive keys from the fixed PIN
/// `"000000"`, so this encryption provides wire compatibility rather than confidentiality.
struct WiVRnSecrets {
    /// Fixed PIN string used when reconnecting as an already-paired headset.
    static let pairedPin = "000000"
    static let salt = "saltsalt"
    /// OpenSSL's default PBKDF2 iteration count.
    static let rounds = 2048

    let controlKey: Bytes
    let controlCounterToHeadset: Bytes
    let controlCounterFromHeadset: Bytes
    let streamKey: Bytes
    /// Lower 8 bytes of the 16-byte AES-CTR IV; the upper 8 bytes carry the per-datagram packet counter.
    let streamCounterTailToHeadset: Bytes
    let streamCounterTailFromHeadset: Bytes

    init?(pin: String) {
        guard let all = Primitives.pbkdf2SHA1(password: Bytes(pin.utf8), salt: Bytes(WiVRnSecrets.salt.utf8),
                                              rounds: WiVRnSecrets.rounds, count: 80)
        else { return nil }
        controlKey = Bytes(all[0..<16])
        controlCounterToHeadset = Bytes(all[16..<32])
        controlCounterFromHeadset = Bytes(all[32..<48])
        streamKey = Bytes(all[48..<64])
        streamCounterTailToHeadset = Bytes(all[64..<72])
        streamCounterTailFromHeadset = Bytes(all[72..<80])
    }
}

/// Encrypts and decrypts WiVRn UDP stream datagrams using AES-128-CTR. Each
/// datagram starts with an 8-byte packet counter that forms the upper half of the IV.
final class WiVRnStreamCipher {
    private let key: Bytes
    private let tailToHeadset: Bytes, tailFromHeadset: Bytes
    private let lock = NSLock()
    private var sent: UInt64 = 0

    init(_ secrets: WiVRnSecrets) {
        key = secrets.streamKey
        tailToHeadset = secrets.streamCounterTailToHeadset
        tailFromHeadset = secrets.streamCounterTailFromHeadset
    }

    /// Encrypts a packet with a unique monotonically increasing counter (thread-safe).
    func sealed(_ packet: Bytes) -> Bytes {
        lock.lock()
        let number = sent
        sent &+= 1
        lock.unlock()
        var head = Bytes()
        head.append(integer: number)
        return head + (Primitives.CounterCipher(key: key, counter: head + tailFromHeadset)?.apply(packet) ?? [])
    }

    func opened(_ datagram: Bytes) -> Bytes? {
        guard datagram.count > 8 else { return nil }
        return Primitives.CounterCipher(key: key, counter: Bytes(datagram[0..<8]) + tailToHeadset)?.apply(datagram[8...])
    }
}

/// Manages the 56-byte X448 public key that identifies this headset to WiVRn hosts.
///
/// A WiVRn 26.9 host never verifies possession of the corresponding private key
/// and only uses the public key bytes to look up paired clients. We therefore
/// generate 56 random bytes once and persist them on disk without storing a
/// private key. Because this identifier is sent in cleartext during the initial
/// handshake, pairing authentication relies solely on matching these bytes.
public enum WiVRnIdentity {
    public static var file: URL { DataDirectory.url.appendingPathComponent("wivrn-identity") }

    /// Loads the persisted 56-byte headset identity, generating and saving one if none exists.
    public static func own(file: URL = WiVRnIdentity.file) -> Bytes {
        if let kept = try? Data(contentsOf: file), kept.count == 56 { return Bytes(kept) }
        var generator = SystemRandomNumberGenerator()
        let made = (0..<56).map { _ in UInt8.random(in: 0...255, using: &generator) }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(made).write(to: file, options: .atomic)
        return made
    }

    /// Formats the 56-byte key as an X448 `SubjectPublicKeyInfo` PEM string (12-byte ASN.1 DER header + key).
    static func pem(_ key: Bytes) -> String {
        let prefix: Bytes = [0x30, 0x42, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6f, 0x03, 0x39, 0x00]
        return "-----BEGIN PUBLIC KEY-----\n" + Data(prefix + key).base64EncodedString() + "\n-----END PUBLIC KEY-----\n"
    }
}
