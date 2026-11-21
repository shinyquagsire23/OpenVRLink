// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Locates hook target functions in `driver_vrlink` on disk or in memory.
///
/// Rather than overwriting function prologues, `driver_openvrlink` redirects direct
/// `call` and `jmp` displacements to wrapper functions that invoke the unmodified
/// original function. That avoids instruction-length decoding and lets `Cleanup`
/// restore each call site by writing back its original 4-byte displacement. If a target
/// does not resolve to a single function with direct callers, resolution returns
/// `.missing` and the hook is skipped.
public enum Scan {
    /// Executable bytes of an image and the address they are (or would be) loaded at.
    public struct Region {
        public var address: UInt64
        public var bytes: ByteView

        public init(address: UInt64, bytes: ByteView) {
            self.address = address
            self.bytes = bytes
        }
    }

    /// A function the driver intercepts.
    public struct Target {
        public let name: StaticString
        /// Mangled name in the Linux driver's symbol table, for builds that ship with one
        /// (July 2026 did; October 2026 is stripped).
        public let elfSymbol: StaticString?
        /// Byte signatures of the function's first instructions in the Linux driver, used
        /// when there is no symbol. `??` stands for a byte that varies. Any may match, but
        /// only one address may result.
        public let elfSignatures: [StaticString]
        /// The same for the Windows driver.
        public let peSignatures: [StaticString]

        public init(name: StaticString, elfSymbol: StaticString? = nil, elfSignatures: [StaticString] = [], peSignatures: [StaticString] = []) {
            self.name = name
            self.elfSymbol = elfSymbol
            self.elfSignatures = elfSignatures
            self.peSignatures = peSignatures
        }

        /// Whether the target exists in ELF (Linux) or PE (Windows) builds of the driver.
        public func applies(toELF elf: Bool) -> Bool { elf ? elfSymbol != nil || !elfSignatures.isEmpty : !peSignatures.isEmpty }
    }

    /// `SVLRoot::ParsePeerValueSettings(TransportValue_t const*, int)`: records received from the client.
    public static let parseRecords = Target(
        name: "kv-parse", elfSymbol: "_ZN7SVLRoot22ParsePeerValueSettingsEPK16TransportValue_ti",
        elfSignatures: ["55 48 89 E5 41 57 41 56 41 55 41 54 53 48 83 EC 68 85 D2 48 89 7D A8 7E ?? 8D 42 FF 48 89 F3 48 C1 E0 05 48 8D 44 06 20"],
        peSignatures: ["45 85 C0 0F 8E ?? ?? ?? ?? 48 8B C4 48 89 50 10 48 89 48 08 55 53 41 54 48 8D 68 ?? 48 81 EC ?? ?? 00 00 48 89 70 E0 4C 8B E1"])

    /// `SVLRoot::PopulatePeerValueSettings(TransportValue_t*, int)`: records about to be sent to the client.
    public static let populateRecords = Target(
        name: "kv-populate", elfSymbol: "_ZN7SVLRoot25PopulatePeerValueSettingsEP16TransportValue_ti",
        elfSignatures: ["55 48 89 E5 41 57 41 56 41 55 41 54 53 48 83 EC 78 85 D2 89 55 A8 0F 8E ?? ?? ?? ?? 48 8D 87 ?? ?? 00 00 48 89 FB 49 89 F4"],
        peSignatures: ["48 89 54 24 10 48 89 4C 24 08 55 53 56 57 41 54 41 55 41 56 41 57 48 8D 6C 24 ?? 48 81 EC ?? ?? 00 00 33 F6 49 63 C0 48 89 45 ?? 8B DE"])

    /// `SVLHMDDriver::UpdateConstantBuffer(int, int, bool, float*)`: fills the constants
    /// of the Vulkan shaders that prepare a frame for the encoder (Linux, July 2026).
    /// The buffer is its fifth argument.
    public static let updateConstants = Target(
        name: "encode-constants", elfSymbol: "_ZN12SVLHMDDriver20UpdateConstantBufferEiibPf",
        elfSignatures: ["49 89 F9 31 C0 41 89 CA 4C 89 C7 B9 0A 00 00 00 48 63 D2 F3 48 AB"])

    /// The same function in the Linux build of October 2026 (`0xbe410`), where the
    /// constant block grew from 80 to 128 bytes and the function to
    /// `(this, int, bool, bool, bool, float*)`: the buffer is its sixth argument.
    public static let updateConstantsWide = Target(
        name: "encode-constants-wide",
        elfSignatures: ["55 49 89 FA 31 C0 41 89 CB 48 89 E5 B9 0E 00 00 00 48 83 EC 08 48 8D 7D 90 F3 48 AB"])

    /// `LoadSpirvFile(char const*)`: reads one of the Vulkan encode shaders (Linux).
    public static let loadSPIRV = Target(
        name: "load-spirv", elfSymbol: "_ZL13LoadSpirvFilePKc",
        elfSignatures: ["55 48 89 F2 31 C0 48 89 E5 41 56 49 89 F6 41 55 48 8D 35 ?? ?? ?? ?? 49 89 FD 31 FF 41 54 53 48 83 EC 20 E8"])

    /// Constant-buffer fill helper in Windows `driver_vrlink.dll` (`0x1809f2870` in the
    /// 2026-11-13 build): `(this, bool layer, bool flag, uint width, uint height, float *constants)`,
    /// called between `Map` and `Unmap` of the constant buffer in the `"vrlink copy views to
    /// atlas"` pass before drawing with `genforencode_ps_copy_view[_cas]`.
    public static let updateConstantsD3D = Target(
        name: "encode-constants-d3d",
        peSignatures: ["48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 48 81 EC A0 00 00 00 0F B6 FA 41 8B E9 33 D2 41 0F B6 F0 48 8B D9 48 8D 4C 24 30 44 8D 42 70"])

    public static let targets = [parseRecords, populateRecords, updateConstants, updateConstantsWide, loadSPIRV, updateConstantsD3D]

    /// An in-memory byte patch in `driver_vrlink` located by a surrounding byte signature.
    public struct Edit {
        public let name: StaticString
        /// Byte pattern in the Windows driver (`??` for wildcard bytes). Must match uniquely.
        public let peSignature: StaticString
        /// Byte offset within `peSignature` where `replacement` is written.
        public let offset: Int
        public let replacement: [UInt8]
    }

    /// Patches out the final call in `SVLHMDDriver::Activate` on Windows (`0x1809e9940` in
    /// the 2026-11-13 build). That call invokes `IVRServerInternal` vtable slot 69 to set a
    /// flag in `vrserver` that makes `vrcompositor` force
    /// `collisionBounds/CollisionBoundsGroundPerimeterOn` off, since VR Link assumes the
    /// headset draws its own boundary. Replacing the 6-byte call with a NOP lets the SteamVR
    /// setting take effect again. The signature matches the tail of `Activate` starting where
    /// it sets bool property 0x844. Not yet located in the Linux driver, which uses a
    /// different vtable layout.
    public static let keepFloorPerimeter = Edit(
        name: "floor-perimeter",
        peSignature: "41 B1 01 41 B8 44 08 00 00 E8 ?? ?? ?? ?? 48 8B CE E8 ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 8B C8 48 8B 10 FF 92 28 02 00 00",
        offset: 33, replacement: [0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00])

    /// Returns the target patch address if `edit.peSignature` matches exactly once in `regions`.
    public static func resolve(edit: Edit, in regions: [Region]) -> UInt64? {
        let signature = parseSignature(edit.peSignature)
        var places: [UInt64] = []
        for region in regions { places += findSignature(in: region, signature) }
        return places.count == 1 ? places[0] + UInt64(edit.offset) : nil
    }

    /// The import through which the Windows driver reads every one of its Direct3D
    /// shaders from disk (`D3DReadFileToBlob(path, &blob)`).
    public static let shaderReadImport: (library: StaticString, function: StaticString) = ("D3DCOMPILER_47.dll", "D3DReadFileToBlob")

    /// A `call rel32` or `jmp rel32` whose destination is a hooked function.
    public struct Site: Equatable {
        /// Address of the 4-byte displacement (one past the opcode).
        public var displacementAt: UInt64
        public var isCall: Bool
    }

    public struct Found: Equatable {
        public var function: UInt64
        public var sites: [Site]
    }

    public enum Missing: Equatable {
        case notForThisPlatform
        case notFound
        case ambiguous(Int)
        case neverCalledDirectly
        case tooManyCallers(Int)
    }

    public enum Resolution: Equatable {
        case found(Found)
        case missing(Missing)
    }

    /// More call sites than this means the match is probably not the function it is taken for.
    static let mostSites = 8

    /// Parses `"48 8B ?? C4"` into byte values, with `-1` for a wildcard.
    public static func parseSignature(_ text: StaticString) -> [Int16] {
        var out: [Int16] = []
        var index = 0
        let count = text.utf8CodeUnitCount
        func digit(_ character: UInt8) -> Int16? {
            switch character {
            case 0x30...0x39: return Int16(character) - 0x30
            case 0x41...0x46: return Int16(character) - 0x41 + 10
            case 0x61...0x66: return Int16(character) - 0x61 + 10
            default: return nil
            }
        }
        while index + 1 < count {
            let (a, b) = (text.utf8Start[index], text.utf8Start[index + 1])
            if a == 0x20 { index += 1; continue }
            if let high = digit(a), let low = digit(b) { out.append(high * 16 + low) } else { out.append(-1) }
            index += 2
        }
        return out
    }

    public static func findSignature(in region: Region, _ signature: [Int16]) -> [UInt64] {
        var found: [UInt64] = []
        guard let first = signature.first, first >= 0, region.bytes.count >= signature.count, let base = region.bytes.baseAddress
        else { return found }
        let (first8, last) = (UInt8(first), region.bytes.count - signature.count)
        var start = 0
        while start <= last {
            if base[start] == first8 {
                var matches = true
                for index in 1..<signature.count where signature[index] >= 0 && base[start + index] != UInt8(signature[index]) {
                    matches = false
                    break
                }
                if matches { found.append(region.address + UInt64(start)) }
            }
            start += 1
        }
        return found
    }

    /// Every `E8`/`E9` in the regions whose 32-bit displacement lands exactly on `function`.
    public static func findSites(in regions: [Region], calling function: UInt64) -> [Site] {
        var sites: [Site] = []
        for region in regions {
            guard region.bytes.count >= 5, let base = region.bytes.baseAddress else { continue }
            let raw = UnsafeRawPointer(base)
            var index = 0
            let last = region.bytes.count - 5
            while index <= last {
                let opcode = base[index]
                if opcode == 0xE8 || opcode == 0xE9 {
                    let displacement = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: index + 1, as: Int32.self))
                    let next = region.address &+ UInt64(index) &+ 5
                    if next &+ UInt64(bitPattern: Int64(displacement)) == function {
                        sites.append(Site(displacementAt: region.address + UInt64(index) + 1, isCall: opcode == 0xE8))
                    }
                }
                index += 1
            }
        }
        return sites
    }

    static func withSites(_ function: UInt64, in regions: [Region]) -> Resolution {
        let sites = findSites(in: regions, calling: function)
        if sites.isEmpty { return .missing(.neverCalledDirectly) }
        if sites.count > mostSites { return .missing(.tooManyCallers(sites.count)) }
        return .found(Found(function: function, sites: sites))
    }

    /// Resolves a target by signature (the Windows driver).
    public static func resolve(bySignature target: Target, in regions: [Region]) -> Resolution {
        resolve(signatures: target.peSignatures, in: regions)
    }

    private static func resolve(signatures: [StaticString], in regions: [Region]) -> Resolution {
        guard !signatures.isEmpty else { return .missing(.notForThisPlatform) }
        var places: [UInt64] = []
        for text in signatures {
            let signature = parseSignature(text)
            for region in regions {
                for address in findSignature(in: region, signature) where !places.contains(address) { places.append(address) }
            }
        }
        switch places.count {
        case 0: return .missing(.notFound)
        case 1: return withSites(places[0], in: regions)
        default: return .missing(.ambiguous(places.count))
        }
    }

    /// Resolves a target in the Linux driver: by symbol when the driver's file (`symbols`)
    /// has it, else by signature. `slide` is added to symbol values to get addresses in `regions`.
    public static func resolve(inELF target: Target, in regions: [Region], symbols: ByteView?, slide: UInt64) -> Resolution {
        if let symbols, let name = target.elfSymbol, let value = elfSymbol(symbols, named: name) {
            return withSites(value &+ slide, in: regions)
        }
        return resolve(signatures: target.elfSignatures, in: regions)
    }

    public static func isELF64(_ file: ByteView) -> Bool {
        file.count > 0x40 && file[0] == 0x7F && file[1] == 0x45 && file[2] == 0x4C && file[3] == 0x46 && file[4] == 2 && file[5] == 1
    }

    public static func isPE(_ file: ByteView) -> Bool {
        file.count > 0x40 && file[0] == 0x4D && file[1] == 0x5A
    }

    /// Value of a symbol in an ELF64 file's `.symtab`.
    public static func elfSymbol(_ file: ByteView, named name: StaticString) -> UInt64? {
        guard isELF64(file), let table: UInt64 = file.integer(at: 0x28), let entry: UInt16 = file.integer(at: 0x3A),
              let count: UInt16 = file.integer(at: 0x3C) else { return nil }
        for index in 0..<Int(count) {
            let header = Int(table) + index * Int(entry)
            guard let kind: UInt32 = file.integer(at: header + 4), kind == 2,       // SHT_SYMTAB
                  let offset: UInt64 = file.integer(at: header + 0x18), let size: UInt64 = file.integer(at: header + 0x20),
                  let link: UInt32 = file.integer(at: header + 0x28) else { continue }
            let strings = Int(table) + Int(link) * Int(entry)
            guard let namesAt: UInt64 = file.integer(at: strings + 0x18), let namesSize: UInt64 = file.integer(at: strings + 0x20),
                  let names = file.slice(at: Int(namesAt), count: Int(namesSize)) else { continue }
            var symbol = Int(offset)
            while symbol + 24 <= Int(offset) + Int(size) {
                if let at: UInt32 = file.integer(at: symbol), names.hasCString(name, at: Int(at)),
                   let value: UInt64 = file.integer(at: symbol + 8), value != 0 {
                    return value
                }
                symbol += 24
            }
        }
        return nil
    }

    /// Executable segments of an ELF64 file, addressed as linked (add the load slide for a live module).
    public static func elfRegions(_ file: ByteView) -> [Region] {
        var regions: [Region] = []
        guard isELF64(file), let table: UInt64 = file.integer(at: 0x20), let entry: UInt16 = file.integer(at: 0x36),
              let count: UInt16 = file.integer(at: 0x38) else { return regions }
        for index in 0..<Int(count) {
            let header = Int(table) + index * Int(entry)
            guard let kind: UInt32 = file.integer(at: header), let flags: UInt32 = file.integer(at: header + 4),
                  kind == 1, flags & 1 != 0,
                  let offset: UInt64 = file.integer(at: header + 8), let address: UInt64 = file.integer(at: header + 0x10),
                  let size: UInt64 = file.integer(at: header + 0x20),
                  let bytes = file.slice(at: Int(offset), count: Int(size)) else { continue }
            regions.append(Region(address: address, bytes: bytes))
        }
        return regions
    }

    private struct Section {
        var virtualSize, address, rawSize, rawAt: Int
        var flags: UInt32
    }

    private static func peSections(_ image: ByteView) -> (header: Int, sections: [Section])? {
        guard isPE(image), let at: UInt32 = image.integer(at: 0x3C), let magic: UInt32 = image.integer(at: Int(at)),
              magic == 0x0000_4550,
              let count: UInt16 = image.integer(at: Int(at) + 6), let optional: UInt16 = image.integer(at: Int(at) + 20)
        else { return nil }
        var sections: [Section] = []
        for index in 0..<Int(count) {
            let section = Int(at) + 24 + Int(optional) + index * 40
            guard let virtualSize: UInt32 = image.integer(at: section + 8), let address: UInt32 = image.integer(at: section + 12),
                  let rawSize: UInt32 = image.integer(at: section + 16), let rawAt: UInt32 = image.integer(at: section + 20),
                  let flags: UInt32 = image.integer(at: section + 36) else { continue }
            sections.append(Section(virtualSize: Int(virtualSize), address: Int(address), rawSize: Int(rawSize), rawAt: Int(rawAt), flags: flags))
        }
        return (Int(at), sections)
    }

    /// Executable sections of a PE image. `mapped` says whether `image` is a loaded module
    /// (sections at their virtual addresses) or a file on disk. Addresses are relative to
    /// the image base; add the module base for a live module.
    public static func peRegions(_ image: ByteView, mapped: Bool) -> [Region] {
        var regions: [Region] = []
        guard let (_, sections) = peSections(image) else { return regions }
        for section in sections where section.flags & 0x2000_0000 != 0 {
            let (start, size) = mapped ? (section.address, section.virtualSize) : (section.rawAt, min(section.rawSize, section.virtualSize))
            if let bytes = image.slice(at: start, count: size) { regions.append(Region(address: UInt64(section.address), bytes: bytes)) }
        }
        return regions
    }

    /// `SizeOfImage` from a PE header, for sizing a loaded module from its first page.
    public static func peImageSize(_ firstPage: ByteView) -> Int? {
        guard let at: UInt32 = firstPage.integer(at: 0x3C), let size: UInt32 = firstPage.integer(at: Int(at) + 24 + 56) else { return nil }
        return Int(size)
    }

    /// Address (relative to the image base) of the import-table slot through which a
    /// 64-bit PE image calls `function` of `library`. Replacing the pointer in that slot
    /// intercepts the image's calls by name alone, independent of how it was compiled.
    public static func peImportSlot(_ image: ByteView, mapped: Bool, library: StaticString, function: StaticString) -> UInt64? {
        guard let (header, sections) = peSections(image), let magic: UInt16 = image.integer(at: header + 24), magic == 0x20B,
              let directory: UInt32 = image.integer(at: header + 24 + 112 + 8) else { return nil }
        func offset(_ address: Int) -> Int? {
            if mapped { return address }
            for section in sections where address >= section.address && address < section.address + section.rawSize {
                return address - section.address + section.rawAt
            }
            return nil
        }
        guard var descriptor = offset(Int(directory)) else { return nil }
        while let lookup: UInt32 = image.integer(at: descriptor), let name: UInt32 = image.integer(at: descriptor + 12),
              let slots: UInt32 = image.integer(at: descriptor + 16), name != 0 {
            if let nameAt = offset(Int(name)), image.hasCString(library, at: nameAt, ignoringCase: true),
               let table = offset(Int(lookup != 0 ? lookup : slots)) {
                var index = 0
                while let entry: UInt64 = image.integer(at: table + index * 8), entry != 0 {
                    // Imports by ordinal have the top bit set; the rest name a hint and a string.
                    if entry >> 63 == 0, let hint = offset(Int(entry)), image.hasCString(function, at: hint + 2) {
                        return UInt64(slots) + UInt64(index * 8)
                    }
                    index += 1
                }
            }
            descriptor += 20
        }
        return nil
    }

    /// Resolves every target that applies to a driver file on disk, for checking a
    /// SteamVR build without running it.
    public static func resolveAll(inFile file: ByteView) -> [(target: Target, resolution: Resolution)] {
        let elf = isELF64(file)
        let regions = elf ? elfRegions(file) : peRegions(file, mapped: false)
        var out: [(target: Target, resolution: Resolution)] = []
        for target in targets where target.applies(toELF: elf) {
            out.append((target, elf ? resolve(inELF: target, in: regions, symbols: file, slide: 0) : resolve(bySignature: target, in: regions)))
        }
        return out
    }
}
