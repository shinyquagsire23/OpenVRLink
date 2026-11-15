// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class WiVRnPairingTests: XCTestCase {
    private func bytes(_ hex: String) -> Bytes { Natural(hex: "01" + hex).bytes.dropFirst().map { $0 } }

    func testNumbersGoToBytesAndBack() {
        XCTAssertEqual(Natural(bytes: [0, 0, 1, 2]).bytes, [1, 2])
        XCTAssertEqual(Natural.zero.bytes, [])
        XCTAssertEqual(Natural(hex: "0102030405060708090a").bytes, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(Natural(hex: "ffffffffffffffff") + Natural(1), Natural(hex: "010000000000000000"))
        XCTAssertEqual(Natural(hex: "010000000000000000") - Natural(1), Natural(hex: "ffffffffffffffff"))
        XCTAssertEqual(Natural(hex: "010000000000000001").halved, Natural(hex: "8000000000000000"))
        XCTAssertLessThan(Natural(hex: "ffffffffffffffff"), Natural(hex: "010000000000000000"))
        XCTAssertEqual(Natural(1000).remainder(dividingBy: Natural(7)), Natural(6))
    }

    func testArithmeticBelowASmallModulus() {
        let seven = Modulus(Natural(1_000_000_007))
        XCTAssertEqual(seven.multiply(Natural(123_456_789), Natural(987_654_321)), Natural(259_106_859))
        XCTAssertEqual(seven.power(Natural(2), Natural(100)), Natural(976_371_285))
        XCTAssertEqual(seven.subtract(Natural(3), Natural(5)), Natural(1_000_000_005))
        XCTAssertEqual(seven.multiply(seven.inverse(Natural(12345)), Natural(12345)), Natural(1))
        // More than the modulus going in.
        XCTAssertEqual(seven.multiply(Natural(hex: "0100000000000000000000"), Natural(1)),
                       Natural(hex: "0100000000000000000000").remainder(dividingBy: Natural(1_000_000_007)))
    }

    func testArithmeticInThePairingGroup() {
        let group = WiVRnPinCheck.group, order = WiVRnPinCheck.order
        XCTAssertEqual(group.value.bitCount, 1536)
        // The generator's powers come round after as many as the order says.
        XCTAssertEqual(group.power(Natural(4), order.value), Natural(1))
        let a = WiVRnPinCheck.randomExponent(), b = WiVRnPinCheck.randomExponent()
        XCTAssertEqual(group.power(group.power(Natural(2), a), b), group.power(group.power(Natural(2), b), a))
        let x = group.power(Natural(2), a)
        XCTAssertEqual(group.multiply(x, group.inverse(x)), Natural(1))
    }

    func testHashIsOverLengthsAndSignBytes() {
        // A byte 1, the proof's number, then the number 0x80 as "one byte more than it has, a zero first".
        XCTAssertEqual(WiVRnPinCheck.hash(3, Natural(0x80)), Natural(bytes: Primitives.sha256([1, 3, 0, 0, 0, 2, 0, 0x80])))
        XCTAssertEqual(WiVRnPinCheck.hash(5, Natural(0x7f), Natural(0x0102)),
                       Natural(bytes: Primitives.sha256([1, 5, 0, 0, 0, 1, 0x7f, 0, 0, 0, 2, 1, 2])))
    }

    /// The host's side of the PIN check, as far as answering goes (it checks none of the headset's proofs).
    private struct Host {
        let pin: Natural
        let g = WiVRnPinCheck.group, q = WiVRnPinCheck.order, one = WiVRnPinCheck.generator
        let b2 = WiVRnPinCheck.randomExponent(), b3 = WiVRnPinCheck.randomExponent()
        var second = Natural.zero, third = Natural.zero, p = Natural.zero, qValue = Natural.zero

        init(pin: String) { self.pin = Natural(bytes: Bytes(pin.utf8)) }

        private func knowing(_ exponent: Natural, proof: UInt8) -> [Natural] {
            let r = WiVRnPinCheck.randomExponent()
            let c = WiVRnPinCheck.hash(proof, g.power(one, r))
            return [c, q.subtract(r, q.multiply(exponent, c))]
        }

        mutating func second(answering first: [Natural]) -> [Natural] {
            second = g.power(first[0], b2)
            third = g.power(first[3], b3)
            let r = WiVRnPinCheck.randomExponent(), r5 = WiVRnPinCheck.randomExponent(), r6 = WiVRnPinCheck.randomExponent()
            p = g.power(third, r)
            qValue = g.multiply(g.power(one, r), g.power(second, pin))
            let c = WiVRnPinCheck.hash(5, g.power(third, r5), g.multiply(g.power(one, r5), g.power(second, r6)))
            return [g.power(one, b2)] + knowing(b2, proof: 3) + [g.power(one, b3)] + knowing(b3, proof: 4)
                + [p, qValue, c, q.subtract(r5, q.multiply(r, c)), q.subtract(r6, q.multiply(pin, c))]
        }

        func fourth(answering third: [Natural]) -> (message: [Natural], same: Bool) {
            let ratioP = g.multiply(third[0], g.inverse(p)), ratioQ = g.multiply(third[1], g.inverse(qValue))
            let r = WiVRnPinCheck.randomExponent()
            let c = WiVRnPinCheck.hash(8, g.power(one, r), g.power(ratioQ, r))
            return ([g.power(ratioQ, b3), c, q.subtract(r, q.multiply(b3, c))], g.power(third[5], b3) == ratioP)
        }
    }

    func testTheSamePinIsFoundTheSameAndAnotherIsNot() throws {
        for (typed, shown, same) in [("123456", "123456", true), ("123456", "123457", false)] {
            var headset = WiVRnPinCheck(pin: typed)
            var host = Host(pin: shown)
            let first = headset.first()
            XCTAssertEqual(first.count, WiVRnPinCheck.counts.first)
            let third = try headset.third(answering: host.second(answering: first))
            XCTAssertEqual(third.count, WiVRnPinCheck.counts.third)
            let fourth = host.fourth(answering: third)
            XCTAssertEqual(fourth.same, same)
            XCTAssertEqual(try headset.matches(fourth.message), same)
        }
    }

    func testAHostThatCannotProveItsNumbersIsRefused() throws {
        var headset = WiVRnPinCheck(pin: "123456")
        var host = Host(pin: "123456")
        var second = host.second(answering: headset.first())
        second[2] = second[2] + Natural(1)
        XCTAssertThrowsError(try headset.third(answering: second))
        // And numbers that are no use in the group at all.
        var other = WiVRnPinCheck(pin: "123456")
        var otherHost = Host(pin: "123456")
        var again = otherHost.second(answering: other.first())
        again[6] = Natural(1)
        XCTAssertThrowsError(try other.third(answering: again))
    }

    func testPinCheckPacketsAreNumbersWithTheirLengths() {
        let packet = WiVRnPacket.pinCheck(.pinCheck1, [Natural(0x0102), .zero, Natural(7)])
        XCTAssertEqual(packet, [1, 2, 0, 1, 2, 0, 0, 1, 0, 7])
        var fourth: Bytes = [WiVRn.ToHeadsetKind.pinCheck4.rawValue]
        for number: Bytes in [[9], [1, 0], []] {
            fourth.append(size: number.count)
            fourth += number
        }
        guard case .pinCheck4(let numbers) = WiVRnToHeadset(fourth) else { return XCTFail("not read as the fourth message") }
        XCTAssertEqual(numbers, [Natural(9), Natural(256), .zero])
    }

    func testKeysAreWhatAHostMakesOfThePin() throws {
        // PBKDF2 with HMAC-SHA1, 2048 rounds, the salt "saltsalt": what a 26.9 host derives for a paired headset.
        let secrets = try XCTUnwrap(WiVRnSecrets(pin: WiVRnSecrets.pairedPin))
        XCTAssertEqual(secrets.controlKey, bytes("93949818635fd3a0db5417699fc0f77a"))
        XCTAssertEqual(secrets.controlCounterToHeadset, bytes("e09247f6c971d61036caa5e6eb139d46"))
        XCTAssertEqual(secrets.controlCounterFromHeadset, bytes("64c5c4552f9e1c1e00e5ca4ed993c670"))
        XCTAssertEqual(secrets.streamKey, bytes("558b47a717140727af653cd2044a8ae8"))
        XCTAssertEqual(secrets.streamCounterTailToHeadset, bytes("b0e336c47fad1410"))
        XCTAssertEqual(secrets.streamCounterTailFromHeadset, bytes("d3076aef9bd68f1d"))
    }

    func testCounterModeIsTheStandardsAndCarriesOn() throws {
        // NIST SP 800-38A, F.5.1.
        let key = bytes("2b7e151628aed2a6abf7158809cf4f3c"), counter = bytes("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plain = bytes("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        let sealed = bytes("874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff")
        XCTAssertEqual(try XCTUnwrap(Primitives.CounterCipher(key: key, counter: counter)).apply(plain), sealed)
        // In pieces that are no multiple of a block, the run is the same.
        let pieces = try XCTUnwrap(Primitives.CounterCipher(key: key, counter: counter))
        XCTAssertEqual(pieces.apply(plain[0..<5]) + pieces.apply(plain[5..<21]) + pieces.apply(plain[21...]), sealed)
    }

    func testStreamDatagramsCarryHalfTheirCounter() throws {
        let secrets = try XCTUnwrap(WiVRnSecrets(pin: "123456"))
        let cipher = WiVRnStreamCipher(secrets)
        let packet: Bytes = [8, 1, 2, 3, 4, 5]
        let first = cipher.sealed(packet), second = cipher.sealed(packet)
        XCTAssertEqual(first.count, packet.count + 8)
        XCTAssertEqual(Bytes(first[0..<8]), [0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Bytes(second[0..<8]), [1, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertNotEqual(Bytes(first[8...]), Bytes(second[8...]))
        // The host opens it with the counter in front and the headset's half after.
        let hosts = try XCTUnwrap(Primitives.CounterCipher(key: secrets.streamKey,
                                                           counter: Bytes(second[0..<8]) + secrets.streamCounterTailFromHeadset))
        XCTAssertEqual(hosts.apply(second[8...]), packet)
        // And what the host seals, the headset opens.
        let head: Bytes = [5, 0, 0, 0, 0, 0, 0, 0]
        let fromHost = try XCTUnwrap(Primitives.CounterCipher(key: secrets.streamKey, counter: head + secrets.streamCounterTailToHeadset))
        XCTAssertEqual(cipher.opened(head + fromHost.apply(packet)), packet)
        XCTAssertNil(cipher.opened([1, 2, 3]))
    }

    func testIdentityIsMadeOnceAndKept() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wivrn-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let made = WiVRnIdentity.own(file: file)
        XCTAssertEqual(made.count, 56)
        XCTAssertEqual(WiVRnIdentity.own(file: file), made)
        // PEM of an X448 public key: 68 bytes of DER, the last 56 the key.
        let body = WiVRnIdentity.pem(made).split(separator: "\n")[1]
        let der = try XCTUnwrap(Data(base64Encoded: String(body)))
        XCTAssertEqual(der.count, 68)
        XCTAssertEqual(Bytes(der.suffix(56)), made)
    }
}
