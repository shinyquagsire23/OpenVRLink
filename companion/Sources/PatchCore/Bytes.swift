// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// `PatchCore` contains binary scanning, shader patching, and handshake logic shared
// between `openvrlink-companion` and `driver_openvrlink`. It uses only Swift standard
// library value types and raw pointers (avoiding Foundation, existentials, and untyped
// errors) to keep `driver_openvrlink`'s runtime footprint inside `vrserver` small.

/// Read-only bytes of a file or of loaded memory.
public typealias ByteView = UnsafeBufferPointer<UInt8>

extension UnsafeBufferPointer where Element == UInt8 {
    /// Little-endian integer at `offset`, or `nil` if it would run past the end.
    @inline(__always)
    func integer<T: FixedWidthInteger>(at offset: Int, as type: T.Type = T.self) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count, let base = baseAddress else { return nil }
        return T(littleEndian: UnsafeRawPointer(base).loadUnaligned(fromByteOffset: offset, as: T.self))
    }

    /// A sub-range, or `nil` if it is not wholly inside the view.
    func slice(at offset: Int, count length: Int) -> ByteView? {
        guard offset >= 0, length >= 0, offset + length <= count, let base = baseAddress else { return nil }
        return ByteView(start: base + offset, count: length)
    }

    /// Whether the NUL-terminated string at `offset` equals `text`.
    func hasCString(_ text: StaticString, at offset: Int, ignoringCase: Bool = false) -> Bool {
        let length = text.utf8CodeUnitCount
        guard offset >= 0, offset + length < count, self[offset + length] == 0 else { return false }
        for index in 0..<length {
            var (a, b) = (self[offset + index], text.utf8Start[index])
            if ignoringCase {
                if a >= 0x41, a <= 0x5A { a += 0x20 }
                if b >= 0x41, b <= 0x5A { b += 0x20 }
            }
            if a != b { return false }
        }
        return true
    }

    /// Whether `text` occurs anywhere in the view, with a NUL after it.
    func containsCString(_ text: StaticString) -> Bool {
        let length = text.utf8CodeUnitCount
        guard length > 0, count > length else { return false }
        for offset in 0..<(count - length) where self[offset] == text.utf8Start[0] && hasCString(text, at: offset) {
            return true
        }
        return false
    }
}

extension Array where Element == UInt8 {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var remaining = value.littleEndian
        for _ in 0..<MemoryLayout<T>.size {
            append(UInt8(truncatingIfNeeded: remaining))
            remaining >>= 8
        }
    }
}

extension Array where Element == UInt32 {
    /// The words as little-endian bytes.
    var bytes: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count * 4)
        for word in self { out.append(littleEndian: word) }
        return out
    }
}

/// Little-endian 32-bit words of `bytes`, or `nil` if its length is not a multiple of four.
func words(of bytes: ByteView) -> [UInt32]? {
    guard bytes.count % 4 == 0 else { return nil }
    var out: [UInt32] = []
    out.reserveCapacity(bytes.count / 4)
    for index in 0..<(bytes.count / 4) { out.append(bytes.integer(at: index * 4)!) }
    return out
}
