// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Encodes, parses, and validates messages for the OpenVRLink TCP data link. Socket I/O lives in `Link.swift`
/// so framing and path checks can be tested directly.
public enum DataLink {
    public static let version: UInt8 = 1
    /// Size of the initial host handshake (`"OVRL"`, 1-byte version, 3 reserved zero bytes, and 12-byte token).
    public static let helloSize = 20
    public static let tokenSize = 12
    /// Message header size (`u16` kind, `u16` zero flags, `u32` little-endian payload length).
    public static let headerSize = 8
    /// Maximum allowed payload size per message (32 MiB). Larger lengths halt the stream parser.
    public static let longestMessage = 32 << 20

    public enum Kind: UInt16 {
        /// Sent by the host to request all files for a controller model set (`[set]`).
        case wantModels = 1
        /// Sent by the client with one file belonging to a model set (`[set, nameLength] + name + data`).
        case file = 2
        /// Sent by the client at the end of a model set transfer (`[set, status]`, where `0` means complete).
        case done = 3
        /// Sent by the host after saving or rejecting a model set (`[set, status]`, where `0` means saved).
        case result = 4
    }

    /// Decodes the 12-byte authentication token from two 48-bit integer doubles (`oxKey0` and `oxKey1`).
    public static func token(_ first: Double, _ second: Double) -> [UInt8]? {
        var out: [UInt8] = []
        for value in [first, second] {
            guard value >= 0, value < 281_474_976_710_656, value == value.rounded(.towardZero) else { return nil }
            let bits = UInt64(value)
            for byte in 0..<6 { out.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(byte)))) }
        }
        return out
    }

    public static func hello(token: [UInt8]) -> [UInt8] {
        [0x4F, 0x56, 0x52, 0x4C, version, 0, 0, 0] + token
    }

    public static func message(_ kind: Kind, _ payload: [UInt8]) -> [UInt8] {
        let length = UInt32(payload.count)
        return [UInt8(kind.rawValue & 0xFF), UInt8(kind.rawValue >> 8), 0, 0,
                UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8),
                UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 24)] + payload
    }

    /// Returns true if `name` is a safe relative path of one or two `/` components containing only ASCII
    /// letters, digits, `_`, `-`, and `.`, with no leading dots.
    public static func isSafe(name: ArraySlice<UInt8>) -> Bool {
        guard !name.isEmpty, name.count <= 96 else { return false }
        var parts = 1, atStart = true
        for byte in name {
            if byte == 0x2F {
                guard !atStart, parts < 2 else { return false }
                parts += 1
                atStart = true
                continue
            }
            let letter = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            guard letter || byte == 0x5F || byte == 0x2D || (byte == 0x2E && !atStart) else { return false }
            atStart = false
        }
        return !atStart
    }

    /// Buffers incoming TCP bytes and yields complete data link messages.
    public struct Parser {
        private var held: [UInt8] = []
        /// Set when an oversized message header is seen, after which the parser stops accepting input.
        public private(set) var failed = false

        public init() {}

        public mutating func add(_ bytes: UnsafeRawBufferPointer) {
            guard !failed else { return }
            held.append(contentsOf: bytes)
        }

        /// Pops and returns the next complete message if buffered, skipping unrecognized message kinds.
        public mutating func next() -> (kind: Kind, payload: [UInt8])? {
            while !failed, held.count >= DataLink.headerSize {
                let raw = UInt16(held[0]) | UInt16(held[1]) << 8
                let length = Int(UInt32(held[4]) | UInt32(held[5]) << 8 | UInt32(held[6]) << 16 | UInt32(held[7]) << 24)
                guard length <= DataLink.longestMessage else {
                    failed = true
                    held = []
                    return nil
                }
                guard held.count >= DataLink.headerSize + length else { return nil }
                let payload = Array(held[DataLink.headerSize..<(DataLink.headerSize + length)])
                held.removeFirst(DataLink.headerSize + length)
                if let kind = Kind(rawValue: raw) { return (kind, payload) }
            }
            return nil
        }
    }

    /// Parses and validates a `.file` message payload, returning `nil` if truncated or if the file name is unsafe.
    public static func file(in payload: [UInt8]) -> (set: UInt8, name: ArraySlice<UInt8>, bytes: ArraySlice<UInt8>)? {
        guard payload.count >= 2 else { return nil }
        let length = Int(payload[1])
        guard payload.count >= 2 + length else { return nil }
        let name = payload[2..<(2 + length)]
        guard isSafe(name: name) else { return nil }
        return (payload[0], name, payload[(2 + length)...])
    }
}
