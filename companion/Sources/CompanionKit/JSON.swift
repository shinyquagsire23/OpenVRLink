// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Minimal order-preserving JSON parser and serializer for SteamVR configuration files.
/// Preserves key order and exact number formatting so editing a file only modifies the
/// targeted entries, and tolerates trailing or repeated commas found in some SteamVR files.
public indirect enum JSON: Equatable {
    case null
    case bool(Bool)
    /// Exact number literal as written in the JSON text.
    case number(String)
    case string(String)
    case array([JSON])
    case object([(key: String, value: JSON)])

    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// A number value, written without a fraction when it has none.
    public static func of(_ value: Double) -> JSON {
        .number(value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value))
    }

    public static func object(_ members: KeyValuePairs<String, JSON>) -> JSON { .object(members.map { ($0.key, $0.value) }) }

    public subscript(key: String) -> JSON? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        set {
            guard case .object(var members) = self, let newValue else { return }
            if let index = members.firstIndex(where: { $0.key == key }) { members[index].value = newValue } else { members.append((key, newValue)) }
            self = .object(members)
        }
    }

    public var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var array: [JSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// Tab-indented text, the way SteamVR writes its own files.
    public var text: String {
        var out = ""
        write(to: &out, depth: 0)
        return out + "\n"
    }

    private func write(to out: inout String, depth: Int) {
        let indent = String(repeating: "\t", count: depth), inner = indent + "\t"
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let text): out += text
        case .string(let text): out += JSON.quoted(text)
        case .array(let items) where items.isEmpty: out += "[]"
        case .object(let members) where members.isEmpty: out += "{}"
        case .array(let items):
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += inner
                item.write(to: &out, depth: depth + 1)
                out += index + 1 < items.count ? ",\n" : "\n"
            }
            out += indent + "]"
        case .object(let members):
            out += "{\n"
            for (index, member) in members.enumerated() {
                out += inner + JSON.quoted(member.key) + " : "
                member.value.write(to: &out, depth: depth + 1)
                out += index + 1 < members.count ? ",\n" : "\n"
            }
            out += indent + "}"
        }
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    public init(parsing text: String) throws {
        var parser = Parser(bytes: Array(text.utf8))
        // Some of SteamVR's files start with a byte-order mark.
        if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.at = 3 }
        self = try parser.value()
        parser.skipSpace()
        guard parser.at == parser.bytes.count else { throw parser.error("text after the end of the document") }
    }

    private struct Parser {
        let bytes: [UInt8]
        var at = 0

        func error(_ what: String) -> ParseError { ParseError(description: "\(what) at byte \(at)") }

        mutating func skipSpace() {
            while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 }
        }

        mutating func peek() -> UInt8? {
            skipSpace()
            return at < bytes.count ? bytes[at] : nil
        }

        mutating func word(_ word: String, _ value: JSON) throws -> JSON {
            guard bytes[at...].starts(with: Array(word.utf8)) else { throw error("unexpected text") }
            at += word.utf8.count
            return value
        }

        mutating func value() throws -> JSON {
            guard let next = peek() else { throw error("unexpected end") }
            switch next {
            case UInt8(ascii: "{"):
                at += 1
                var members: [(key: String, value: JSON)] = []
                while true {
                    switch peek() {
                    case UInt8(ascii: "}"):
                        at += 1
                        return .object(members)
                    case UInt8(ascii: ","): at += 1         // tolerate stray and trailing commas
                    case UInt8(ascii: "\""):
                        let name = try string()
                        guard peek() == UInt8(ascii: ":") else { throw error("expected ':'") }
                        at += 1
                        members.append((name, try value()))
                    default: throw error("expected a member or '}'")
                    }
                }
            case UInt8(ascii: "["):
                at += 1
                var items: [JSON] = []
                while true {
                    switch peek() {
                    case UInt8(ascii: "]"):
                        at += 1
                        return .array(items)
                    case UInt8(ascii: ","): at += 1
                    case nil: throw error("unexpected end")
                    default: items.append(try value())
                    }
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): return try word("true", .bool(true))
            case UInt8(ascii: "f"): return try word("false", .bool(false))
            case UInt8(ascii: "n"): return try word("null", .null)
            default:
                let start = at
                while at < bytes.count, "0123456789-+.eE".utf8.contains(bytes[at]) { at += 1 }
                let text = String(decoding: bytes[start..<at], as: UTF8.self)
                guard Double(text) != nil else { throw error("unexpected text") }
                return .number(text)
            }
        }

        mutating func string() throws -> String {
            at += 1
            var out: [UInt8] = []
            while true {
                guard at < bytes.count else { throw error("unterminated string") }
                let byte = bytes[at]
                at += 1
                if byte == UInt8(ascii: "\"") { break }
                guard byte == UInt8(ascii: "\\") else { out.append(byte); continue }
                guard at < bytes.count else { throw error("unterminated string") }
                let escape = bytes[at]
                at += 1
                switch escape {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    guard at + 4 <= bytes.count, let code = UInt32(String(decoding: bytes[at..<(at + 4)], as: UTF8.self), radix: 16)
                    else { throw error("bad escape") }
                    at += 4
                    out.append(contentsOf: String(Unicode.Scalar(code) ?? "\u{FFFD}").utf8)
                default: out.append(escape)
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}
