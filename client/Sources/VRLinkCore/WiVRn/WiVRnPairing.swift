// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Proving to a WiVRn host that the PIN typed on the headset is the PIN
/// it shows, without either side sending it (docs/wivrn/protocol.md).
///
/// It is the "socialist millionaires" comparison as Off-the-Record
/// Messaging version 3 specifies it, in the 1536-bit group of RFC 3526,
/// with WiVRn's own way of hashing. The headset speaks first and third;
/// the host second and fourth. Nothing is encrypted by it: it only
/// answers "the same PIN, or not".
struct WiVRnPinCheck {
    enum Failure: Error { case malformed, proofFailed }

    /// The prime everything is a remainder of.
    static let group = Modulus(Natural(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD
        EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
        EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F
        83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA237327FFFFFFFFFFFFFFFF
        """))
    /// How many powers the generator has before they repeat: half the prime, rounded down. Exponents are remainders of it.
    static let order = Modulus(group.value.halved)
    static let generator = Natural(2)

    /// How many numbers each message is.
    static let counts = (first: 6, second: 11, third: 8, fourth: 3)

    private let secret: Natural
    /// Two exponents kept to ourselves from the first message to the last.
    private let ownSecond: Natural, ownThird: Natural
    private var second = Natural.zero, third = Natural.zero
    private var hostsThird = Natural.zero
    /// Our P over the host's, and our Q over the host's.
    private var ratioP = Natural.zero, ratioQ = Natural.zero
    private let random: () -> Natural

    /// `random` gives an exponent nobody could guess; tests give known ones.
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

    /// SHA-256 of a byte 1, the number of the proof, and one or two
    /// numbers, each with its length in four bytes before it and a zero
    /// byte in front when its top bit is set. Read as a number.
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

    /// Something that could be a power of the generator worth using.
    private func isElement(_ number: Natural) -> Bool {
        Natural(2) <= number && number <= g.value - Natural(2)
    }

    private func isExponent(_ number: Natural) -> Bool {
        Natural(1) <= number && number < q.value
    }

    /// A proof of knowing `exponent`, without showing it: the hash of
    /// the generator to a random power, and that power less the
    /// exponent times the hash.
    private func proofOfKnowing(_ exponent: Natural, proof: UInt8) -> [Natural] {
        let r = random()
        let c = WiVRnPinCheck.hash(proof, g.power(WiVRnPinCheck.generator, r))
        return [c, q.subtract(r, q.multiply(exponent, c))]
    }

    /// Whether (c, d) proves its sender knows the exponent that takes the generator to `power`.
    private func provesKnowing(_ c: Natural, _ d: Natural, of power: Natural, proof: UInt8) -> Bool {
        c == WiVRnPinCheck.hash(proof, g.multiply(g.power(WiVRnPinCheck.generator, d), g.power(power, c)))
    }

    /// The first message: the generator to each of our two exponents, each with a proof that we know it.
    func first() -> [Natural] {
        [g.power(WiVRnPinCheck.generator, ownSecond)] + proofOfKnowing(ownSecond, proof: 1)
            + [g.power(WiVRnPinCheck.generator, ownThird)] + proofOfKnowing(ownThird, proof: 2)
    }

    /// The third message, from the host's second.
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

        // Two generators that neither side chose alone.
        second = g.power(hostsSecond, ownSecond)
        third = g.power(hostsThird, ownThird)

        // The host's P and Q are made as it says they are: P the third
        // generator to some power, Q the first to the same power times the second to its PIN.
        let one = WiVRnPinCheck.generator
        let hostsProof = WiVRnPinCheck.hash(
            5, g.multiply(g.power(third, message[9]), g.power(hostsP, message[8])),
            g.multiply(g.multiply(g.power(one, message[9]), g.power(second, message[10])), g.power(hostsQ, message[8])))
        guard hostsProof == message[8] else { throw Failure.proofFailed }

        // Ours, made the same way with our PIN, and the same proof of it.
        let r = random()
        let p = g.power(third, r)
        let qValue = g.multiply(g.power(one, r), g.power(second, secret))
        let r5 = random(), r6 = random()
        let c = WiVRnPinCheck.hash(6, g.power(third, r5), g.multiply(g.power(one, r5), g.power(second, r6)))
        let d5 = q.subtract(r5, q.multiply(r, c)), d6 = q.subtract(r6, q.multiply(secret, c))

        // The two Qs differ by the second generator to the difference of
        // the PINs; raised to both sides' third exponents, that equals the
        // Ps' ratio only if the difference is zero. Our half of the raising, with a proof.
        ratioP = g.multiply(p, g.inverse(hostsP))
        ratioQ = g.multiply(qValue, g.inverse(hostsQ))
        let raised = g.power(ratioQ, ownThird)
        let r7 = random()
        let cRaised = WiVRnPinCheck.hash(7, g.power(one, r7), g.power(ratioQ, r7))
        let d7 = q.subtract(r7, q.multiply(ownThird, cRaised))
        return [p, qValue, c, d5, d6, raised, cRaised, d7]
    }

    /// Whether the PINs are the same, from the host's fourth message.
    func matches(_ message: [Natural]) throws -> Bool {
        guard message.count == WiVRnPinCheck.counts.fourth, isElement(message[0]), isExponent(message[2]) else {
            throw Failure.malformed
        }
        let hostsRaised = message[0]
        // The host raised the Qs' ratio by the exponent its third number came from.
        let proof = WiVRnPinCheck.hash(
            8, g.multiply(g.power(WiVRnPinCheck.generator, message[2]), g.power(hostsThird, message[1])),
            g.multiply(g.power(ratioQ, message[2]), g.power(hostsRaised, message[1])))
        guard proof == message[1] else { throw Failure.proofFailed }
        return g.power(hostsRaised, ownThird) == ratioP
    }
}

/// The keys of an encrypted WiVRn connection (docs/wivrn/protocol.md).
///
/// A 26.9 host makes them from the PIN alone: it hands the result of its
/// key agreement to PBKDF2 under a name PBKDF2 does not read, so the
/// agreement changes nothing (measured on a host, 2026-11-14). A headset
/// already paired uses the PIN "000000". The keys are therefore no
/// secret, and the encryption they do keeps out nobody who has read this.
struct WiVRnSecrets {
    /// What a headset that is already paired uses for a PIN.
    static let pairedPin = "000000"
    static let salt = "saltsalt"
    /// What OpenSSL does when not told otherwise.
    static let rounds = 2048

    let controlKey: Bytes
    let controlCounterToHeadset: Bytes
    let controlCounterFromHeadset: Bytes
    let streamKey: Bytes
    /// The second half of each datagram's counter; the first half goes in front of the datagram.
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

/// Datagrams of an encrypted WiVRn stream: each has eight bytes in front
/// that are the first half of its counter, and the rest is AES in counter mode.
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

    /// Safe to call from any thread: no two datagrams get the same counter.
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

/// What a host knows this headset by: the public half of an X448 key, 56 bytes.
///
/// A 26.9 host asks for no proof that the headset holds the other half,
/// and uses the key for nothing but looking it up among those it has
/// paired with. So there is no other half here: these are 56 random
/// bytes, made once and kept. Being let in without a PIN rests on these
/// bytes alone, and they cross the network in the clear at every connection.
public enum WiVRnIdentity {
    public static var file: URL { DataDirectory.url.appendingPathComponent("wivrn-identity") }

    /// This headset's, made the first time it is asked for.
    public static func own(file: URL = WiVRnIdentity.file) -> Bytes {
        if let kept = try? Data(contentsOf: file), kept.count == 56 { return Bytes(kept) }
        var generator = SystemRandomNumberGenerator()
        let made = (0..<56).map { _ in UInt8.random(in: 0...255, using: &generator) }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(made).write(to: file, options: .atomic)
        return made
    }

    /// The key in PEM: the fixed twelve bytes that say "X448 public key", then the key.
    static func pem(_ key: Bytes) -> String {
        let prefix: Bytes = [0x30, 0x42, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6f, 0x03, 0x39, 0x00]
        return "-----BEGIN PUBLIC KEY-----\n" + Data(prefix + key).base64EncodedString() + "\n-----END PUBLIC KEY-----\n"
    }
}
