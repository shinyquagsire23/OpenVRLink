// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Little-endian byte packing. Everything on the SVL wire is little-endian.

public typealias Bytes = [UInt8]

public struct ByteReader {
    public let bytes: Bytes
    public var offset: Int

    public init(_ bytes: Bytes, at offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public var remaining: Int { bytes.count - offset }

    public mutating func integer<T: FixedWidthInteger>(_ type: T.Type = T.self) -> T {
        let value: T = bytes.integer(at: offset)
        offset += MemoryLayout<T>.size
        return value
    }

    public mutating func float() -> Float { Float(bitPattern: integer(UInt32.self)) }
    public mutating func double() -> Double { Double(bitPattern: integer(UInt64.self)) }

    public mutating func take(_ count: Int) -> Bytes {
        let end = min(offset + count, bytes.count)
        defer { offset = end }
        return Bytes(bytes[offset..<end])
    }

    public mutating func skip(_ count: Int) { offset += count }
}

public extension Array where Element == UInt8 {
    /// Reads past the end as zero, so a short message parses as zeros rather than trapping.
    func integer<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size where offset + index < count {
            value |= T(truncatingIfNeeded: self[offset + index]) << T(index * 8)
        }
        return value
    }

    func float(at offset: Int) -> Float { Float(bitPattern: integer(at: offset) as UInt32) }

    mutating func append<T: FixedWidthInteger>(integer value: T) {
        for index in 0..<MemoryLayout<T>.size {
            append(UInt8(truncatingIfNeeded: value >> T(index * 8)))
        }
    }

    mutating func append(float value: Float) { append(integer: value.bitPattern) }
    mutating func append(double value: Double) { append(integer: value.bitPattern) }
    mutating func append(zeros count: Int) { append(contentsOf: Bytes(repeating: 0, count: count)) }

    /// A C string in a fixed, zero-filled field.
    mutating func append(text: String, fieldSize: Int) {
        var field = Bytes(text.utf8.prefix(fieldSize - 1))
        field.append(zeros: fieldSize - field.count)
        append(contentsOf: field)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var out = Bytes()
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16)
            else { return nil }
            out.append(byte)
        }
        self = out
    }
}
