// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// SVL datagram framing (docs/svl-transport/packet-format.md). The session
/// token prefix selects the wire format requested by the host: `MID` sends
/// datagrams unencrypted with a checksum seeded by a session ID, while `AES`
/// encrypts every datagram. Steam's "encrypt streaming" host setting controls
/// which format is used.

/// SVL element classes (docs/svl-transport/packet-types.md). Each class
/// has its own type numbering.
public enum SVLClass {
    public static let padding: UInt8 = 0            // skipped when reading
    public static let unreliable: UInt8 = 3         // bidirectional typed stream: poses, values, hands, haptics
    public static let videoReply: UInt8 = 4         // client to host only
    public static let video: UInt8 = 5              // host to client only
    public static let serverEvent: UInt8 = 8        // text log line from the host
    public static let audio: UInt8 = 0x0B           // parity matches the length of the packets it covers
    public static let audioVariable: UInt8 = 0x0C   // parity `index` records the length of the shorter packet
}

/// Identifies an SVL element by its message class and per-class type ID.
/// Known message types used by this client are defined as static constants;
/// unrecognized wire elements can still be represented with raw values.
public struct SVLKind: Equatable {
    public var messageClass: UInt8
    public var type: UInt8

    public init(_ messageClass: UInt8, _ type: UInt8) {
        self.messageClass = messageClass
        self.type = type
    }

    // Unreliable stream, client to host.
    public static let pose = SVLKind(SVLClass.unreliable, 0x01)               // poses and input, followed by value-transport data
    public static let statistics = SVLKind(SVLClass.unreliable, 0x07)         // string -> double values
    public static let eyesAndFace = SVLKind(SVLClass.unreliable, 0x11)
    public static let goodbye = SVLKind(SVLClass.unreliable, 0x13)            // empty payload ending the session
    public static let hand = SVLKind(SVLClass.unreliable, 0x17)               // hand-tracking skeleton and gestures
    public static let addressList = SVLKind(SVLClass.unreliable, 0x18)        // local reachable addresses (sent both ways)
    // Unreliable stream, host to client.
    public static let valueTransport = SVLKind(SVLClass.unreliable, 0x0D)
    public static let haptics = SVLKind(SVLClass.unreliable, 0x16)
    // Video reply, client to host.
    public static let retransmitRequest = SVLKind(SVLClass.videoReply, 0x05)  // packet IDs requested for retransmission
    public static let frameReport = SVLKind(SVLClass.videoReply, 0x0F)
    // Video, host to client.
    public static let frameDescriptor = SVLKind(SVLClass.video, 0x02)         // also carries the host clock and value transport
    public static let videoPacket = SVLKind(SVLClass.video, 0x03)             // data or parity
    // Bidirectional audio (microphone uplink uses the variable-length form).
    public static let audio = SVLKind(SVLClass.audio, 0x10)
    public static let audioVariable = SVLKind(SVLClass.audioVariable, 0x10)
}

public struct SVLElement {
    public var messageClass: UInt8
    public var type: UInt8
    public var id: UInt16            // per class: video frame id
    public var index: UInt16         // per class: video packet id, descriptor group
    /// Element payload. Parsed wire elements slice directly into the
    /// underlying datagram buffer so video packets are only copied once,
    /// into their destination frame buffer.
    public var value: ByteSlice

    public var kind: SVLKind { SVLKind(messageClass, type) }

    public init(_ kind: SVLKind, id: UInt16 = 0, index: UInt16 = 0, value: ByteSlice) {
        self.messageClass = kind.messageClass
        self.type = kind.type
        self.id = id
        self.index = index
        self.value = value
    }

    public init(_ kind: SVLKind, id: UInt16 = 0, index: UInt16 = 0, value: Bytes) {
        self.init(kind, id: id, index: index, value: value[...])
    }
}

public enum SVL {
    static let headerLength = 8
    static let maxElementValue = 0x400

    /// Decodes the base64url payload following a token's 4-character prefix.
    static func tokenBytes(_ token: String) -> Bytes? {
        var text = String(token.dropFirst(4)).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        return Data(base64Encoded: text).map { Bytes($0) }
    }

    /// XOR of the datagram's little-endian 32-bit words (zero-padded) and a seed.
    static func fold(_ datagram: Bytes, seed: UInt32) -> UInt32 {
        var accumulator = seed
        datagram.withUnsafeBytes { raw in
            let whole = raw.count / 4
            for word in 0..<whole {
                accumulator ^= UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: word * 4, as: UInt32.self))
            }
            // Treat any trailing partial word as zero-padded.
            for index in whole * 4..<raw.count {
                accumulator ^= UInt32(raw[index]) << UInt32((index - whole * 4) * 8)
            }
        }
        return accumulator
    }

    /// Serializes an unencrypted datagram with its sequence number, two zero bytes, a caller-supplied header word, and the encoded elements.
    static func assemble(sequence: UInt16, word: UInt32, elements: [SVLElement]) -> Bytes {
        var datagram = Bytes()
        datagram.append(integer: sequence)
        datagram.append(integer: UInt16(0))
        datagram.append(integer: word)
        for element in elements {
            datagram.append(element.messageClass)
            datagram.append(element.type)
            datagram.append(integer: element.id)
            datagram.append(integer: UInt16(element.value.count))
            datagram.append(integer: element.index)
            datagram.append(contentsOf: element.value)
        }
        return datagram
    }

    /// Parses the elements from an unencrypted datagram.
    static func elements(of datagram: Bytes) -> [SVLElement] {
        var elements: [SVLElement] = []
        var offset = headerLength
        while datagram.count - offset >= 8 {
            let length = Int(datagram.integer(at: offset + 4) as UInt16)
            let end = offset + 8 + length
            guard length <= maxElementValue, end <= datagram.count else { break }
            if datagram[offset] != SVLClass.padding {
                elements.append(SVLElement(SVLKind(datagram[offset], datagram[offset + 1]),
                                           id: datagram.integer(at: offset + 2),
                                           index: datagram.integer(at: offset + 6),
                                           value: datagram[offset + 8..<end]))
            }
            offset = end
        }
        return elements
    }
}


/// Handles link-probe datagrams sent outside normal SVL framing. A probe
/// consists of three 32-bit words (a magic marker, protocol kind 2, and 1 for
/// a request or 2 for a reply) followed by arbitrary padding from the sender.
/// Both peers send probes every few seconds; `vrlink` echoes the packet back
/// with the third word set to `answer` and tracks the largest probe size
/// received (observed in Steam Link 2.0.25 and capture `vr14`). Under minor
/// version 14, a host recreates its UDP socket every two seconds if its probes
/// go unanswered.
enum LinkProbe {
    static let mark: UInt32 = 0x459B_4C33
    static let kind: UInt32 = 2
    static let request: UInt32 = 1, answer: UInt32 = 2

    /// Returns an echo reply if `datagram` is a link-probe request, or nil otherwise.
    static func reply(to datagram: Bytes) -> Bytes? {
        guard datagram.count >= 12, datagram.integer(at: 0) as UInt32 == mark,
              datagram.integer(at: 4) as UInt32 == kind, datagram.integer(at: 8) as UInt32 == request
        else { return nil }
        var out = datagram
        out[8] = UInt8(answer)
        return out
    }

    /// Returns true if `datagram` is a link probe (request or reply) rather than an SVL datagram.
    static func isProbe(_ datagram: Bytes) -> Bool {
        datagram.count >= 12 && datagram.integer(at: 0) as UInt32 == mark
    }
}

/// Framing and optional encryption state for an SVL session, configured from its session token.
public struct SVLLink {
    private enum Form {
        /// Unencrypted datagrams; the second header word is a checksum chosen
        /// so that XORing all 32-bit words with `sessionID` yields zero.
        case checked(sessionID: UInt32)
        /// AES-128-CBC encrypted datagrams zero-padded to a 16-byte boundary,
        /// reusing the static IV for every packet. The second header word
        /// tracks 16-bit sequence wraparounds with `0x02` in the high byte.
        case encrypted(key: Bytes, iv: Bytes)
    }
    private let form: Form
    private var wraps: UInt32 = 0
    private var lastSequence: UInt16 = 0

    /// Human-readable description of the transport mode for logging.
    public let name: String

    /// Returns nil if the token prefix or payload is unrecognized.
    public init?(token: String) {
        guard let bytes = SVL.tokenBytes(token) else { return nil }
        switch token.prefix(3).uppercased() {
        case "MID":
            // Session ID formed from the token's first three bytes with 0x01 in the high byte.
            guard bytes.count >= 5 else { return nil }
            form = .checked(sessionID: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | 0x0100_0000)
            name = "unencrypted"
        case "AES":
            // 16 bytes of IV followed by 16 bytes of key (measured in that order).
            guard bytes.count >= 32 else { return nil }
            form = .encrypted(key: Bytes(bytes[16..<32]), iv: Bytes(bytes[0..<16]))
            name = "AES-128 encrypted"
        default:
            return nil
        }
    }

    public mutating func pack(sequence: UInt16, elements: [SVLElement]) -> Bytes {
        switch form {
        case .checked(let sessionID):
            var datagram = SVL.assemble(sequence: sequence, word: 0, elements: elements)
            let checksum = SVL.fold(datagram, seed: sessionID)
            for index in 0..<4 { datagram[4 + index] = UInt8(truncatingIfNeeded: checksum >> UInt32(index * 8)) }
            return datagram
        case .encrypted(let key, let iv):
            if sequence < lastSequence, sequence != 0xFFFF { wraps &+= 1 }
            lastSequence = sequence
            // The goodbye datagram (sequence 0xffff) carries a counter of all ones.
            let counter = sequence == 0xFFFF ? 0x00FF_FFFF : wraps & 0x00FF_FFFF
            var datagram = SVL.assemble(sequence: sequence, word: counter | 0x0200_0000, elements: elements)
            // Match vrlink's padding: append at least 4 zero bytes, padded to a 16-byte multiple.
            datagram.append(zeros: ((datagram.count + 0x13) & ~0xF) - datagram.count)
            return Primitives.aesCBC(datagram, key: key, iv: iv, encrypting: true, padded: false) ?? []
        }
    }

    /// Unpacks a datagram, or returns nil if decryption or validation fails.
    public func unpack(_ datagram: Bytes) -> [SVLElement]? {
        switch form {
        case .checked(let sessionID):
            guard datagram.count >= SVL.headerLength, SVL.fold(datagram, seed: sessionID) == 0 else { return nil }
            return SVL.elements(of: datagram)
        case .encrypted(let key, let iv):
            guard datagram.count >= 16, datagram.count % 16 == 0,
                  let clear = Primitives.aesCBC(datagram, key: key, iv: iv, encrypting: false, padded: false),
                  clear.count >= SVL.headerLength, clear[7] == 0x02, clear[2] == 0, clear[3] == 0
            else { return nil }
            return SVL.elements(of: clear)
        }
    }
}
