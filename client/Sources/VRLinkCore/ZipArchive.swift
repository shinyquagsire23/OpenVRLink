// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Reads individual entries from a ZIP archive such as an Android APK using its central directory, without
/// loading the whole archive into memory. Only stored and DEFLATE-compressed entries are supported; ZIP64,
/// encrypted, and multi-part archives are not handled.
public struct ZipArchive {
    public struct Entry: Equatable {
        public let name: String
        let method: UInt16, packed: Int, size: Int, header: UInt64
    }

    /// Maximum compressed or uncompressed entry size (32 MiB) accepted by `read(_:)`.
    public static let largestEntry = 32 << 20

    let path: String
    public let entries: [String: Entry]

    public init?(path: String) {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd(), length >= 22 else { return nil }
        // Locate the End of Central Directory record within the final 22 + 65535 bytes of the file.
        let tailSize = min(length, 22 + 65535)
        guard (try? file.seek(toOffset: length - tailSize)) != nil, let tail = try? file.read(upToCount: Int(tailSize)), tail.count == Int(tailSize) else { return nil }
        let bytes = Bytes(tail)
        var found: Int?
        for at in stride(from: bytes.count - 22, through: 0, by: -1) where bytes[at] == 0x50 && bytes[at + 1] == 0x4B && bytes[at + 2] == 5 && bytes[at + 3] == 6 {
            found = at
            break
        }
        guard let found else { return nil }
        let count = Int(ZipArchive.short(bytes, found + 10)), size = Int(ZipArchive.long(bytes, found + 12)), start = UInt64(ZipArchive.long(bytes, found + 16))
        guard size <= 64 << 20, start + UInt64(size) <= length, (try? file.seek(toOffset: start)) != nil,
              let directory = (try? file.read(upToCount: size)).map({ Bytes($0) }), directory.count == size else { return nil }
        var entries: [String: Entry] = [:], at = 0
        for _ in 0..<count {
            guard at + 46 <= directory.count, ZipArchive.long(directory, at) == 0x0201_4B50 else { return nil }
            let nameLength = Int(ZipArchive.short(directory, at + 28)), extra = Int(ZipArchive.short(directory, at + 30)), comment = Int(ZipArchive.short(directory, at + 32))
            guard at + 46 + nameLength + extra + comment <= directory.count else { return nil }
            let name = String(decoding: directory[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(name: name, method: ZipArchive.short(directory, at + 10), packed: Int(ZipArchive.long(directory, at + 20)),
                                  size: Int(ZipArchive.long(directory, at + 24)), header: UInt64(ZipArchive.long(directory, at + 42)))
            at += 46 + nameLength + extra + comment
        }
        self.path = path
        self.entries = entries
    }

    /// Reads and decompresses the entry at `name`, returning `nil` if missing, unsupported, or corrupt.
    public func read(_ name: String) -> Data? {
        guard let entry = entries[name], entry.packed <= ZipArchive.largestEntry, entry.size <= ZipArchive.largestEntry,
              let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        // Skip past the local file header's variable-length file name and extra field.
        guard (try? file.seek(toOffset: entry.header)) != nil, let header = (try? file.read(upToCount: 30)).map({ Bytes($0) }), header.count == 30,
              ZipArchive.long(header, 0) == 0x0403_4B50 else { return nil }
        let skip = UInt64(ZipArchive.short(header, 26)) + UInt64(ZipArchive.short(header, 28))
        guard (try? file.seek(toOffset: entry.header + 30 + skip)) != nil, let packed = try? file.read(upToCount: entry.packed), packed.count == entry.packed else { return nil }
        switch entry.method {
        case 0: return packed.count == entry.size ? packed : nil
        case 8: return Inflate.inflate(Bytes(packed), size: entry.size).map { Data($0) }
        default: return nil
        }
    }

    private static func short(_ bytes: Bytes, _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    private static func long(_ bytes: Bytes, _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}

/// Decompresses raw DEFLATE streams (RFC 1951).
public enum Inflate {
    private struct Reader {
        let bytes: Bytes
        var at = 0, held: UInt32 = 0, count = 0
        var failed = false

        mutating func bits(_ wanted: Int) -> Int {
            while count < wanted {
                guard at < bytes.count else {
                    failed = true
                    return 0
                }
                held |= UInt32(bytes[at]) << UInt32(count)
                at += 1
                count += 8
            }
            let value = Int(held & ((1 << UInt32(wanted)) - 1))
            held >>= UInt32(wanted)
            count -= wanted
            return value
        }
    }

    /// Canonical Huffman prefix table storing code counts per bit length and sorted symbol indices.
    private struct Code {
        var counts = [Int](repeating: 0, count: 16), symbols: [Int] = []

        init(lengths: [Int]) {
            for length in lengths { counts[length] += 1 }
            counts[0] = 0
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<16 { offsets[length] = offsets[length - 1] + counts[length - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }

        func decode(_ reader: inout Reader) -> Int? {
            var code = 0, first = 0, index = 0
            for length in 1..<16 {
                code |= reader.bits(1)
                if reader.failed { return nil }
                let count = counts[length]
                if code - count < first { return symbols[index + (code - first)] }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            return nil
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// Decompresses raw DEFLATE bytes into exactly `size` bytes, returning `nil` if malformed or truncated.
    public static func inflate(_ packed: Bytes, size: Int) -> Bytes? {
        var reader = Reader(bytes: packed)
        var out = Bytes()
        out.reserveCapacity(size)
        var last = false
        while !last {
            last = reader.bits(1) == 1
            let kind = reader.bits(2)
            if reader.failed { return nil }
            switch kind {
            case 0:
                reader.held = 0
                reader.count = 0
                guard reader.at + 4 <= packed.count else { return nil }
                let length = Int(packed[reader.at]) | Int(packed[reader.at + 1]) << 8
                let check = Int(packed[reader.at + 2]) | Int(packed[reader.at + 3]) << 8
                reader.at += 4
                guard length == ~check & 0xFFFF, reader.at + length <= packed.count, out.count + length <= size else { return nil }
                out.append(contentsOf: packed[reader.at..<(reader.at + length)])
                reader.at += length
            case 1, 2:
                var literals: Code, distances: Code
                if kind == 1 {
                    literals = Code(lengths: [Int](repeating: 8, count: 144) + [Int](repeating: 9, count: 112) + [Int](repeating: 7, count: 24) + [Int](repeating: 8, count: 8))
                    distances = Code(lengths: [Int](repeating: 5, count: 30))
                } else {
                    let literalCount = reader.bits(5) + 257, distanceCount = reader.bits(5) + 1, codeCount = reader.bits(4) + 4
                    guard !reader.failed, literalCount <= 286, distanceCount <= 30 else { return nil }
                    var codeLengths = [Int](repeating: 0, count: 19)
                    for index in 0..<codeCount { codeLengths[order[index]] = reader.bits(3) }
                    let lengthCode = Code(lengths: codeLengths)
                    var lengths: [Int] = []
                    while lengths.count < literalCount + distanceCount {
                        guard let symbol = lengthCode.decode(&reader) else { return nil }
                        switch symbol {
                        case 0..<16: lengths.append(symbol)
                        case 16:
                            guard let previous = lengths.last else { return nil }
                            lengths.append(contentsOf: [Int](repeating: previous, count: 3 + reader.bits(2)))
                        case 17: lengths.append(contentsOf: [Int](repeating: 0, count: 3 + reader.bits(3)))
                        default: lengths.append(contentsOf: [Int](repeating: 0, count: 11 + reader.bits(7)))
                        }
                    }
                    guard !reader.failed, lengths.count == literalCount + distanceCount else { return nil }
                    literals = Code(lengths: Array(lengths[..<literalCount]))
                    distances = Code(lengths: Array(lengths[literalCount...]))
                }
                while true {
                    guard let symbol = literals.decode(&reader) else { return nil }
                    if symbol < 256 {
                        guard out.count < size else { return nil }
                        out.append(UInt8(symbol))
                    } else if symbol == 256 {
                        break
                    } else {
                        guard symbol - 257 < lengthBase.count else { return nil }
                        let length = lengthBase[symbol - 257] + reader.bits(lengthExtra[symbol - 257])
                        guard let far = distances.decode(&reader), far < distanceBase.count else { return nil }
                        let distance = distanceBase[far] + reader.bits(distanceExtra[far])
                        guard !reader.failed, distance <= out.count, out.count + length <= size else { return nil }
                        let from = out.count - distance
                        for index in 0..<length { out.append(out[from + index]) }
                    }
                }
            default:
                return nil
            }
        }
        return out.count == size ? out : nil
    }
}
