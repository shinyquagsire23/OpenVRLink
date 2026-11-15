// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A whole number of any size, zero or more.
///
/// This and `Modulus` are here for one thing: proving to a host that the
/// PIN typed is the PIN shown (WiVRn/WiVRnPairing.swift), which takes
/// arithmetic on numbers of 1536 bits that no system library offers. They
/// encrypt nothing. They take as long as the numbers are large, not a
/// fixed time, which is of no use to anyone timing a check that is made
/// once, on a PIN that is then thrown away.
struct Natural: Equatable, Comparable {
    /// 64 bits each, the least significant first, with no zero at the top.
    private(set) var limbs: [UInt64]

    static let zero = Natural(limbs: [])

    init(limbs: [UInt64]) {
        self.limbs = limbs
        while self.limbs.last == 0 { self.limbs.removeLast() }
    }

    init(_ small: UInt64) { self.init(limbs: [small]) }

    /// From its bytes, the most significant first.
    init(bytes: Bytes) {
        var limbs = [UInt64](repeating: 0, count: (bytes.count + 7) / 8)
        for (index, byte) in bytes.reversed().enumerated() {
            limbs[index / 8] |= UInt64(byte) << UInt64(index % 8 * 8)
        }
        self.init(limbs: limbs)
    }

    /// From hexadecimal digits; anything else in the text is skipped.
    init(hex: String) {
        var digits = hex.compactMap { $0.hexDigitValue }.map { UInt8($0) }
        if digits.count % 2 == 1 { digits.insert(0, at: 0) }
        self.init(bytes: stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] })
    }

    /// Its bytes, the most significant first, as few as hold it: none for zero.
    var bytes: Bytes {
        var out = Bytes()
        for limb in limbs.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift))) }
        }
        return Bytes(out.drop { $0 == 0 })
    }

    var bitCount: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 64 - top.leadingZeroBitCount
    }

    func bit(_ index: Int) -> Bool {
        index / 64 < limbs.count && limbs[index / 64] >> UInt64(index % 64) & 1 == 1
    }

    static func < (a: Natural, b: Natural) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for index in a.limbs.indices.reversed() where a.limbs[index] != b.limbs[index] {
            return a.limbs[index] < b.limbs[index]
        }
        return false
    }

    static func + (a: Natural, b: Natural) -> Natural {
        var out = [UInt64](), carry = false
        for index in 0..<max(a.limbs.count, b.limbs.count) {
            let x = index < a.limbs.count ? a.limbs[index] : 0, y = index < b.limbs.count ? b.limbs[index] : 0
            let (sum, over) = x.addingReportingOverflow(y)
            let (total, overAgain) = sum.addingReportingOverflow(carry ? 1 : 0)
            out.append(total)
            carry = over || overAgain
        }
        if carry { out.append(1) }
        return Natural(limbs: out)
    }

    /// `b` must not be the larger.
    static func - (a: Natural, b: Natural) -> Natural {
        precondition(b <= a)
        var out = a.limbs, borrow = false
        for index in out.indices {
            let y = index < b.limbs.count ? b.limbs[index] : 0
            let (difference, under) = out[index].subtractingReportingOverflow(y)
            let (total, underAgain) = difference.subtractingReportingOverflow(borrow ? 1 : 0)
            out[index] = total
            borrow = under || underAgain
        }
        return Natural(limbs: out)
    }

    var doubled: Natural { self + self }

    var halved: Natural {
        var out = limbs
        for index in out.indices {
            out[index] = out[index] >> 1 | (index + 1 < out.count ? out[index + 1] << 63 : 0)
        }
        return Natural(limbs: out)
    }

    /// What is left after dividing by `divisor`, found a bit at a time:
    /// slow, and used only to bring a number within a modulus once.
    func remainder(dividingBy divisor: Natural) -> Natural {
        precondition(divisor != .zero)
        var rest = Natural.zero
        for index in stride(from: bitCount - 1, through: 0, by: -1) {
            rest = rest.doubled
            if bit(index) { rest = rest + Natural(1) }
            if divisor <= rest { rest = rest - divisor }
        }
        return rest
    }
}

/// Arithmetic on the numbers below an odd number: products, powers, and
/// (when the number is prime) inverses.
///
/// Products are Montgomery's: numbers are kept multiplied by a power of
/// two R, so that taking the remainder of a product is a matter of
/// shifts and no division.
struct Modulus {
    let value: Natural
    private let count: Int
    private let limbs: [UInt64]
    /// The number that times the lowest limb of the modulus gives -1 in 64 bits.
    private let lowInverse: UInt64
    /// R squared, which brings a number into Montgomery's form when multiplied by.
    private let squaredR: [UInt64]

    init(_ value: Natural) {
        precondition(value.bit(0), "the modulus must be odd")
        self.value = value
        limbs = value.limbs
        count = limbs.count
        // Each round doubles the number of bits that are right.
        var inverse = limbs[0]
        for _ in 0..<6 { inverse = inverse &* (2 &- limbs[0] &* inverse) }
        lowInverse = 0 &- inverse
        var power = [UInt64](repeating: 0, count: 2 * count + 1)
        power[2 * count] = 1
        squaredR = Modulus.padded(Natural(limbs: power).remainder(dividingBy: value), to: count)
    }

    private static func padded(_ number: Natural, to count: Int) -> [UInt64] {
        number.limbs + [UInt64](repeating: 0, count: count - number.limbs.count)
    }

    func reduce(_ number: Natural) -> Natural {
        number < value ? number : number.remainder(dividingBy: value)
    }

    /// a times b over R, all below the modulus.
    private func montgomery(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        // Through pointers: this is where all the time goes, and an
        // unoptimised build checks every index otherwise.
        var sum = [UInt64](repeating: 0, count: count + 2)
        let count = count, lowInverse = lowInverse
        sum.withUnsafeMutableBufferPointer { sum in
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    limbs.withUnsafeBufferPointer { limbs in
                        for i in 0..<count {
                            // Add a's limb times b.
                            var carry: UInt64 = 0
                            for j in 0..<count {
                                let (high, low) = a[i].multipliedFullWidth(by: b[j])
                                let (first, over) = sum[j].addingReportingOverflow(low)
                                let (second, overAgain) = first.addingReportingOverflow(carry)
                                sum[j] = second
                                carry = high &+ (over ? 1 : 0) &+ (overAgain ? 1 : 0)
                            }
                            let (top, over) = sum[count].addingReportingOverflow(carry)
                            sum[count] = top
                            sum[count + 1] = over ? 1 : 0
                            // Add the multiple of the modulus that makes the lowest limb zero, and drop that limb.
                            let factor = sum[0] &* lowInverse
                            var (high, low) = factor.multipliedFullWidth(by: limbs[0])
                            carry = high &+ (sum[0].addingReportingOverflow(low).overflow ? 1 : 0)
                            for j in 1..<count {
                                (high, low) = factor.multipliedFullWidth(by: limbs[j])
                                let (first, over) = sum[j].addingReportingOverflow(low)
                                let (second, overAgain) = first.addingReportingOverflow(carry)
                                sum[j - 1] = second
                                carry = high &+ (over ? 1 : 0) &+ (overAgain ? 1 : 0)
                            }
                            let (last, overLast) = sum[count].addingReportingOverflow(carry)
                            sum[count - 1] = last
                            sum[count] = sum[count + 1] &+ (overLast ? 1 : 0)
                        }
                    }
                }
            }
        }
        // Below twice the modulus now: one subtraction at most.
        var aboveOrEqual = sum[count] != 0
        if !aboveOrEqual {
            aboveOrEqual = true
            for index in stride(from: count - 1, through: 0, by: -1) where sum[index] != limbs[index] {
                aboveOrEqual = sum[index] > limbs[index]
                break
            }
        }
        var out = Array(sum[0..<count])
        if aboveOrEqual {
            var borrow = false
            for index in 0..<count {
                let (difference, under) = out[index].subtractingReportingOverflow(limbs[index])
                let (total, underAgain) = difference.subtractingReportingOverflow(borrow ? 1 : 0)
                out[index] = total
                borrow = under || underAgain
            }
        }
        return out
    }

    private func entering(_ number: Natural) -> [UInt64] {
        montgomery(Modulus.padded(reduce(number), to: count), squaredR)
    }

    private func leaving(_ number: [UInt64]) -> Natural {
        var one = [UInt64](repeating: 0, count: count)
        one[0] = 1
        return Natural(limbs: montgomery(number, one))
    }

    func multiply(_ a: Natural, _ b: Natural) -> Natural {
        leaving(montgomery(entering(a), entering(b)))
    }

    func power(_ base: Natural, _ exponent: Natural) -> Natural {
        let base = entering(base)
        var out = entering(Natural(1))
        for index in stride(from: exponent.bitCount - 1, through: 0, by: -1) {
            out = montgomery(out, out)
            if exponent.bit(index) { out = montgomery(out, base) }
        }
        return leaving(out)
    }

    /// a less b, brought back within the modulus.
    func subtract(_ a: Natural, _ b: Natural) -> Natural {
        let a = reduce(a), b = reduce(b)
        return b <= a ? a - b : a + value - b
    }

    /// The number that times `a` gives one. Only when the modulus is prime, and `a` not a multiple of it.
    func inverse(_ a: Natural) -> Natural {
        power(a, value - Natural(2))
    }
}
