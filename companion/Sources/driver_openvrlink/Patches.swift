// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import DriverABI
import PatchCore

/// Finds `driver_vrlink`'s functions and points their call sites at the replacements.
enum Patches {
    /// What `attach` managed to do.
    struct Attached {
        var handshake = false
        var gamma = false
        /// Whether the floor-perimeter NOP patch (`Scan.keepFloorPerimeter`) was applied.
        var floorPerimeter = false
    }

    /// Places written over so far, with what each held, for undoing.
    private static var written: [(address: UInt, before: [UInt8])] = []

    private static func write(_ bytes: [UInt8], at address: UInt) -> Bool {
        let before = Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(bitPattern: address), count: bytes.count))
        guard bytes.withUnsafeBytes({ Platform.writeCode(at: address, $0) }) else { return false }
        written.append((address, before))
        return true
    }

    /// Points every call site of `found` at `replacement`, through a jump placed at `stub`.
    private static func redirect(_ found: Scan.Found, to replacement: UInt, stub: UInt) -> Bool {
        // jmp [rip+0] ; followed by the 64-bit destination
        var jump: [UInt8] = [0xFF, 0x25, 0, 0, 0, 0]
        for shift in stride(from: 0, to: 64, by: 8) { jump.append(UInt8(truncatingIfNeeded: replacement >> UInt(shift))) }
        UnsafeMutableRawPointer(bitPattern: stub)?.copyMemory(from: jump, byteCount: jump.count)
        for site in found.sites {
            let displacement = Int64(bitPattern: UInt64(stub)) - (Int64(bitPattern: site.displacementAt) + 4)
            guard let near = Int32(exactly: displacement) else { return false }
            var bytes: [UInt8] = []
            for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: near >> Int32(shift))) }
            guard write(bytes, at: UInt(site.displacementAt)) else { return false }
        }
        return true
    }

    /// Replaces the pointer in one of `driver_vrlink`'s import slots, returning the one it held.
    private static func redirectImport(slot: UInt, to replacement: UInt) -> UInt? {
        guard let original = UnsafeRawPointer(bitPattern: slot)?.loadUnaligned(as: UInt.self) else { return nil }
        var bytes: [UInt8] = []
        for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: replacement >> UInt(shift))) }
        return write(bytes, at: slot) ? original : nil
    }

    /// Puts back everything `attach` wrote over.
    static func restoreAll() {
        for place in written.reversed() { _ = place.before.withUnsafeBytes { Platform.writeCode(at: place.address, $0) } }
        written.removeAll()
    }

    /// Finds `driver_vrlink`'s functions and redirects them. Returns `nil` while
    /// `driver_vrlink` is not loaded yet.
    static func attach() -> Attached? {
        guard let module = Platform.findVRLink() else { return nil }
        var file: [UInt8]?
        if var path = module.file { file = contents(ofFile: &path) }

        func resolve(_ target: Scan.Target, expected: Bool = true) -> Scan.Found? {
            guard target.applies(toELF: file != nil) else { return nil }
            let resolution = file.map { file in
                file.withUnsafeBufferPointer { Scan.resolve(inELF: target, in: module.code, symbols: $0, slide: UInt64(module.slide)) }
            } ?? Scan.resolve(bySignature: target, in: module.code)
            switch resolution {
            case .found(let found): return found
            case .missing(let missing):
                guard expected else { return nil }
                let name = Message(target.name)
                let message: Message
                switch missing {
                case .notForThisPlatform: message = name.adding(": not for this platform")
                case .notFound: message = name.adding(": function not found in this VR Link build")
                case .ambiguous(let count): message = name.adding(": signature matches ").adding(count).adding(" places")
                case .neverCalledDirectly: message = name.adding(": found, but nothing calls it directly")
                case .tooManyCallers(let count): message = name.adding(": ").adding(count).adding(" call sites, more than expected")
                }
                Server.say(message)
                return nil
            }
        }
        func address<T>(_ function: T) -> UInt { unsafeBitCast(function, to: UInt.self) }

        var attached = Attached()
        // Require both handshake hooks before installing any feature-specific hooks.
        guard let parse = resolve(Scan.parseRecords), let populate = resolve(Scan.populateRecords) else { return attached }
        guard let first = module.code.first, let page = Platform.pageNear(UInt(first.address)) else {
            Server.say("no memory near driver_vrlink for the redirects")
            return attached
        }
        Shared.parse = UInt(parse.function)
        Shared.populate = UInt(populate.function)
        attached.handshake = redirect(parse, to: address(parseRecords), stub: page) && redirect(populate, to: address(populateRecords), stub: page + 16)
        guard attached.handshake else {
            restoreAll()
            Server.say("could not rewrite the handshake call sites")
            return attached
        }
        // Hook constant-buffer updates before shader loading so a patched shader never runs without constant updates.
        // Linux builds match either `updateConstants` or `updateConstantsWide`; only log if neither matches.
        let narrow = resolve(Scan.updateConstants, expected: false), wide = narrow == nil ? resolve(Scan.updateConstantsWide) : nil
        if let constants = narrow ?? wide, let shaders = resolve(Scan.loadSPIRV) {
            Shared.constantsBufferArgument = narrow != nil ? 4 : 5
            Shared.constants = UInt(constants.function)
            Shared.loadSPIRV = UInt(shaders.function)
            attached.gamma = redirect(constants, to: address(updateConstants), stub: page + 32) && redirect(shaders, to: address(loadSPIRV), stub: page + 48)
        }
        if let constants = resolve(Scan.updateConstantsD3D), let slot = module.shaderReadSlot {
            Shared.constantsD3D = UInt(constants.function)
            if redirect(constants, to: address(updateConstantsD3D), stub: page + 64), let original = redirectImport(slot: slot, to: address(readShader)) {
                // The slot is rewritten before `readShader` is first reached, but the original must be in place first.
                Shared.readShader = original
                attached.gamma = true
            }
        }
        if !attached.gamma { Server.say("the encode hooks were not applied; handshake only") }
        // Windows only for now. Apply immediately because `SVLHMDDriver::Activate` runs as soon as a headset connects.
        if file == nil {
            if let place = Scan.resolve(edit: Scan.keepFloorPerimeter, in: module.code) {
                attached.floorPerimeter = write(Scan.keepFloorPerimeter.replacement, at: UInt(place))
            }
            if !attached.floorPerimeter { Server.say("floor-perimeter: not found in this VR Link build; SteamVR will not draw the floor boundary") }
        }
        return attached
    }
}
