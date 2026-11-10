// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Just enough protobuf for the handful of messages the pairing protocol
/// needs (docs/remoteplay/)

public enum ProtoValue {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case bytes(Bytes)
}

public struct ProtoWriter {
    public private(set) var bytes = Bytes()
    public init() {}

    private mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    public mutating func varint(_ field: Int, _ value: UInt64) {
        varint(UInt64(field << 3))
        varint(value)
    }

    public mutating func bool(_ field: Int, _ value: Bool) { varint(field, value ? 1 : 0) }

    public mutating func bytes(_ field: Int, _ value: Bytes) {
        varint(UInt64(field << 3 | 2))
        varint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    public mutating func string(_ field: Int, _ value: String) { bytes(field, Bytes(value.utf8)) }
}

public struct ProtoMessage {
    private var fields: [Int: [ProtoValue]] = [:]

    /// Returns nil for malformed input.
    public init?(_ bytes: Bytes) {
        var offset = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while offset < bytes.count, shift < 64 {
                let byte = bytes[offset]
                offset += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while offset < bytes.count {
            guard let tag = varint() else { return nil }
            let field = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = varint() else { return nil }
                fields[field, default: []].append(.varint(value))
            case 1:
                guard offset + 8 <= bytes.count else { return nil }
                fields[field, default: []].append(.fixed64(bytes.integer(at: offset)))
                offset += 8
            case 2:
                guard let length = varint(), offset + Int(length) <= bytes.count else { return nil }
                fields[field, default: []].append(.bytes(Bytes(bytes[offset..<offset + Int(length)])))
                offset += Int(length)
            case 5:
                guard offset + 4 <= bytes.count else { return nil }
                fields[field, default: []].append(.fixed32(bytes.integer(at: offset)))
                offset += 4
            default:
                return nil
            }
        }
    }

    public func varint(_ field: Int) -> UInt64? {
        if case .varint(let value)? = fields[field]?.last { return value }
        return nil
    }

    public func bytes(_ field: Int) -> Bytes? {
        if case .bytes(let value)? = fields[field]?.last { return value }
        return nil
    }

    public func string(_ field: Int) -> String? { bytes(field).map { String(decoding: $0, as: UTF8.self) } }
}
