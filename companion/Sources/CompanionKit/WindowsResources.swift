// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Builds raw Win32 icon (`RT_ICON` / `RT_GROUP_ICON`) and version (`VS_VERSIONINFO`)
/// resource payloads embedded into `openvrlink-companion.exe` by `pack`. Kept platform-independent
/// so resource serialization can be unit-tested on any OS.
public enum WindowsResources {
    /// Win32 resource type IDs (`RT_ICON`, `RT_GROUP_ICON`, and `RT_VERSION`).
    public static let iconType = 3, iconGroupType = 14, versionType = 16
    /// Resource IDs for the embedded icon group (loaded by `Window.swift`) and version info.
    public static let iconGroupID = 1, versionID = 1

    private static func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
    private static func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word((value >> 16) & 0xFFFF) }

    /// Splits a `.ico` file into individual `RT_ICON` image payloads (assigned 1-based IDs)
    /// and an `RT_GROUP_ICON` directory header. Returns `nil` if `file` is not a valid `.ico` image.
    public static func icon(fromICO file: [UInt8]) -> (group: [UInt8], images: [(id: Int, data: [UInt8])])? {
        func read(_ at: Int, _ count: Int) -> Int? {
            guard at >= 0, at + count <= file.count else { return nil }
            return (0..<count).reduce(0) { $0 | Int(file[at + $1]) << (8 * $1) }
        }
        guard read(0, 2) == 0, read(2, 2) == 1, let count = read(4, 2), count > 0, 6 + 16 * count <= file.count else { return nil }
        var group = word(0) + word(1) + word(count), images: [(id: Int, data: [UInt8])] = []
        for index in 0..<count {
            let entry = 6 + 16 * index
            guard let length = read(entry + 8, 4), let offset = read(entry + 12, 4), length > 0, offset + length <= file.count else { return nil }
            // GRPICONDIRENTRY matches ICONDIRENTRY except the 4-byte file offset is replaced by a 2-byte resource ID.
            group += file[entry..<(entry + 12)] + word(index + 1)
            images.append((index + 1, Array(file[offset..<(offset + length)])))
        }
        return (group, images)
    }

    /// String table metadata displayed in Windows File Explorer's Details tab.
    public struct Details {
        public var product = "OpenVRLink Companion"
        public var description = "OpenVRLink Companion"
        public var company = "OpenVRLink"
        public var copyright = "Mozilla Public License 2.0"
        public var internalName = "openvrlink-companion"
        public var fileName = "openvrlink-companion-windows-x86_64.exe"
        public init() {}
    }

    /// Builds a binary `VS_VERSIONINFO` resource for `version` (for example `"0.1.0-8"`,
    /// using up to the first four numeric components for the fixed file and product versions).
    public static func versionInfo(version: String, details: Details = Details()) -> [UInt8] {
        var numbers = Release.numbers(version).prefix(4).map { min($0, 0xFFFF) }
        while numbers.count < 4 { numbers.append(0) }
        func text(_ string: String) -> [UInt8] { Array(string.utf16).flatMap { word(Int($0)) } + word(0) }
        /// Encodes a `VS_VERSIONINFO` structure (`wLength`, `wValueLength`, `wType`, UTF-16 `szKey`,
        /// 4-byte aligned value, and 4-byte aligned child blocks). Because the root and every child
        /// start on a 4-byte boundary, aligning relative to the start of the block keeps global alignment.
        func block(_ key: String, text isText: Bool, value: [UInt8] = [], valueLength: Int? = nil, children: [[UInt8]] = []) -> [UInt8] {
            var body = text(key)
            func pad() { while (6 + body.count) % 4 != 0 { body.append(0) } }
            if !value.isEmpty {
                pad()
                body += value
            }
            for child in children {
                pad()
                body += child
            }
            return word(6 + body.count) + word(valueLength ?? value.count) + word(isText ? 1 : 0) + body
        }
        let dotted = numbers.map(String.init).joined(separator: ".")
        var fixed: [UInt8] = long(0xFEEF04BD) + long(0x0001_0000)
        for _ in 0..<2 { fixed += long(numbers[0] << 16 | numbers[1]) + long(numbers[2] << 16 | numbers[3]) }    // file, product
        fixed += long(0x3F) + long(0)               // dwFileFlagsMask = VS_FFI_FILEFLAGSMASK, dwFileFlags = 0
        fixed += long(0x0004_0004) + long(1)        // dwFileOS = VOS_NT_WINDOWS32, dwFileType = VFT_APP
        fixed += long(0) + long(0) + long(0)        // dwFileSubtype = 0, dwFileDateMS/LS = 0
        let strings: [(String, String)] = [
            ("CompanyName", details.company), ("FileDescription", details.description), ("FileVersion", dotted),
            ("InternalName", details.internalName), ("LegalCopyright", details.copyright),
            ("OriginalFilename", details.fileName), ("ProductName", details.product), ("ProductVersion", version),
        ]
        // Language 0x0409 (US English), code page 0x04B0 (UTF-16LE).
        let table = block("040904B0", text: true, children: strings.map { key, value in
            block(key, text: true, value: text(value), valueLength: value.utf16.count + 1)
        })
        return block("VS_VERSION_INFO", text: false, value: fixed, children: [
            block("StringFileInfo", text: true, children: [table]),
            block("VarFileInfo", text: true, children: [block("Translation", text: false, value: word(0x0409) + word(0x04B0))]),
        ])
    }
}
