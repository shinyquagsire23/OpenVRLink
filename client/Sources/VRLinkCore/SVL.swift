// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// SVL datagram framing (docs/svl-transport/packet-format.md). The session
/// token's first letters say which of two forms the host wants: `MID`, in
/// the clear with a checksum seeded by a session id, or `AES`, every
/// datagram encrypted. Steam's "encrypt streaming" setting on the host
/// chooses between them.

/// The classes of element (docs/svl-transport/packet-types.md). Each class
/// numbers its own types.
public enum SVLClass {
    public static let padding: UInt8 = 0            // skipped when reading
    public static let unreliable: UInt8 = 3         // the typed stream, both ways: poses, values, hands, haptics
    public static let videoReply: UInt8 = 4         // client to host only
    public static let video: UInt8 = 5              // host to client only
    public static let serverEvent: UInt8 = 8        // a line of text from the host
    public static let audio: UInt8 = 0x0B           // parity as long as the packets it covers
    public static let audioVariable: UInt8 = 0x0C   // parity's `index` says how long the shorter packet was
}

/// What an element is: its class and its type within that class. The ones
/// this client sends or reads have names; anything else off the wire is
/// still a kind, just not one of these.
public struct SVLKind: Equatable {
    public var messageClass: UInt8
    public var type: UInt8

    public init(_ messageClass: UInt8, _ type: UInt8) {
        self.messageClass = messageClass
        self.type = type
    }

    // Unreliable stream, client to host.
    public static let pose = SVLKind(SVLClass.unreliable, 0x01)               // poses, input, and value transport after them
    public static let statistics = SVLKind(SVLClass.unreliable, 0x07)         // string -> double values
    public static let eyesAndFace = SVLKind(SVLClass.unreliable, 0x11)
    public static let goodbye = SVLKind(SVLClass.unreliable, 0x13)            // empty: the session is over
    public static let hand = SVLKind(SVLClass.unreliable, 0x17)               // a bare hand's skeleton and gestures
    public static let addressList = SVLKind(SVLClass.unreliable, 0x18)        // where this side can be reached; both ways
    // Unreliable stream, host to client.
    public static let valueTransport = SVLKind(SVLClass.unreliable, 0x0D)
    public static let haptics = SVLKind(SVLClass.unreliable, 0x16)
    // Video reply, client to host.
    public static let retransmitRequest = SVLKind(SVLClass.videoReply, 0x05)  // the packet ids wanted again
    public static let frameReport = SVLKind(SVLClass.videoReply, 0x0F)
    // Video, host to client.
    public static let frameDescriptor = SVLKind(SVLClass.video, 0x02)         // also carries the host clock and value transport
    public static let videoPacket = SVLKind(SVLClass.video, 0x03)             // data or parity
    // Audio, either way (the microphone goes up as the variable form).
    public static let audio = SVLKind(SVLClass.audio, 0x10)
    public static let audioVariable = SVLKind(SVLClass.audioVariable, 0x10)
}

public struct SVLElement {
    public var messageClass: UInt8
    public var type: UInt8
    public var id: UInt16            // per class: video frame id
    public var index: UInt16         // per class: video packet id, descriptor group
    public var value: Bytes

    public var kind: SVLKind { SVLKind(messageClass, type) }

    public init(_ kind: SVLKind, id: UInt16 = 0, index: UInt16 = 0, value: Bytes) {
        self.messageClass = kind.messageClass
        self.type = kind.type
        self.id = id
        self.index = index
        self.value = value
    }
}

public enum SVL {
    static let headerLength = 8
    static let maxElementValue = 0x400

    /// The bytes a token carries after its four-character kind.
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
            // A last partial word counts as if padded with zeros.
            for index in whole * 4..<raw.count {
                accumulator ^= UInt32(raw[index]) << UInt32((index - whole * 4) * 8)
            }
        }
        return accumulator
    }

    /// A datagram in the clear: sequence, a zero, a word the caller decides, then the elements.
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

    /// The elements of a datagram in the clear.
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
                                           value: Bytes(datagram[offset + 8..<end])))
            }
            offset = end
        }
        return elements
    }
}


/// The link probe: a datagram outside the SVL framing, three 32-bit
/// words (a fixed mark, a 2, then 1 for "send this back" or 2 for "here
/// it is back") and whatever padding the asker added. Each side asks the
/// other every few seconds; the reference client answers with the same
/// bytes, the third word changed, and notes the longest answer it has
/// had (read from Steam Link 2.0.25; seen in capture `vr14`). A host
/// given version 14 whose probes go unanswered remakes its socket every
/// two seconds.
enum LinkProbe {
    static let mark: UInt32 = 0x459B_4C33
    static let kind: UInt32 = 2
    static let request: UInt32 = 1, answer: UInt32 = 2

    /// The datagram to send back, if `datagram` is a probe asking for one.
    static func reply(to datagram: Bytes) -> Bytes? {
        guard datagram.count >= 12, datagram.integer(at: 0) as UInt32 == mark,
              datagram.integer(at: 4) as UInt32 == kind, datagram.integer(at: 8) as UInt32 == request
        else { return nil }
        var out = datagram
        out[8] = UInt8(answer)
        return out
    }

    /// Whether `datagram` is any link probe, and so not for the SVL reader.
    static func isProbe(_ datagram: Bytes) -> Bool {
        datagram.count >= 12 && datagram.integer(at: 0) as UInt32 == mark
    }
}

/// One session's datagram form, read from its token.
public struct SVLLink {
    private enum Form {
        /// In the clear; the header's second word makes the XOR of all the
        /// datagram's words and this session id come to zero.
        case checked(sessionID: UInt32)
        /// The whole datagram, padded with zeros to a multiple of 16 bytes,
        /// is AES-128-CBC encrypted, starting from the same IV every time.
        /// The header's second word counts sequence wraps, tagged 0x02 on top.
        case encrypted(key: Bytes, iv: Bytes)
    }
    private let form: Form
    private var wraps: UInt32 = 0
    private var lastSequence: UInt16 = 0

    /// For the log: which form the host chose.
    public let name: String

    /// Nil for a token of a kind this client does not know.
    public init?(token: String) {
        guard let bytes = SVL.tokenBytes(token) else { return nil }
        switch token.prefix(3).uppercased() {
        case "MID":
            // The session id: the token's first three bytes, tagged 0x01.
            guard bytes.count >= 5 else { return nil }
            form = .checked(sessionID: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | 0x0100_0000)
            name = "unencrypted"
        case "AES":
            // 16 bytes of IV, then 16 of key (measured; in that order).
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
            // The reference client's padding: at least four zeros, up to a multiple of 16.
            datagram.append(zeros: ((datagram.count + 0x13) & ~0xF) - datagram.count)
            return Primitives.aesCBC(datagram, key: key, iv: iv, encrypting: true, padded: false) ?? []
        }
    }

    /// Nil when the datagram is not one of this session's.
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
