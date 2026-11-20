// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import DriverABI
import PatchCore

/// OS-level helpers for locating `driver_vrlink` in memory, allocating executable jump
/// stubs within `rel32` range, and modifying code pages.
enum Platform {
    /// The loaded `driver_vrlink` module.
    struct Module {
        /// Its executable memory.
        var code: [Scan.Region] = []
        /// Added to a symbol's value in the file to get its address (Linux).
        var slide: UInt = 0
        /// The file it was loaded from, when the system tells us (Linux).
        var file: [CChar]?
        /// Address of the import slot through which it reads its shader files (Windows).
        var shaderReadSlot: UInt?
    }

    /// A page can hold a jump to anywhere; call sites reach it with a 32-bit displacement.
    static let reach: UInt = 0x7000_0000
    static let page: UInt = 0x1000

    #if os(Windows)

    private static let pageExecuteReadWrite: UInt32 = 0x40
    private static var lockStorage: UnsafeMutableRawPointer?

    static func lock() { AcquireSRWLockExclusive(&lockStorage) }
    static func unlock() { ReleaseSRWLockExclusive(&lockStorage) }
    static func milliseconds() -> UInt64 { GetTickCount64() }

    /// Pins this DLL in memory for the lifetime of the host process. Steam's watchdog
    /// loads every registered driver into `steam.exe` and immediately unloads it, which
    /// is unsafe for a library with a Swift runtime.
    static func pinThisLibrary(containing address: UnsafeRawPointer) {
        var module: UnsafeMutableRawPointer?
        // GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
        _ = GetModuleHandleExA(0x1 | 0x4, address.assumingMemoryBound(to: CChar.self), &module)
    }

    static func findVRLink() -> Module? {
        guard let base = GetModuleHandleA("driver_vrlink.dll") else { return nil }
        let start = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
        guard let size = Scan.peImageSize(ByteView(start: start, count: Int(page))) else { return nil }
        let image = ByteView(start: start, count: size)
        var module = Module(slide: UInt(bitPattern: base))
        for region in Scan.peRegions(image, mapped: true) {
            module.code.append(Scan.Region(address: UInt64(UInt(bitPattern: base)) + region.address, bytes: region.bytes))
        }
        if let slot = Scan.peImportSlot(image, mapped: true, library: Scan.shaderReadImport.library, function: Scan.shaderReadImport.function) {
            module.shaderReadSlot = UInt(bitPattern: base) + UInt(slot)
        }
        return module
    }

    static func writeCode(at address: UInt, _ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let target = UnsafeMutableRawPointer(bitPattern: address), let source = bytes.baseAddress else { return false }
        var old: UInt32 = 0
        guard VirtualProtect(target, bytes.count, pageExecuteReadWrite, &old) != 0 else { return false }
        target.copyMemory(from: source, byteCount: bytes.count)
        _ = VirtualProtect(target, bytes.count, old, &old)
        _ = FlushInstructionCache(GetCurrentProcess(), target, bytes.count)
        return true
    }

    static func pageNear(_ address: UInt) -> UInt? {
        let step: UInt = 0x10000, start = address & ~(step - 1)
        var distance = step
        while distance < reach {
            for candidate in [start &- distance, start &+ distance] where candidate > step && candidate < UInt(Int.max) {
                var information = win_memory_information()
                guard VirtualQuery(UnsafeRawPointer(bitPattern: candidate), &information, MemoryLayout<win_memory_information>.size) != 0,
                      information.state == 0x10000 else { continue }                // MEM_FREE
                // MEM_COMMIT | MEM_RESERVE
                if let page = VirtualAlloc(UnsafeMutableRawPointer(bitPattern: candidate), Int(page), 0x3000, pageExecuteReadWrite) {
                    return UInt(bitPattern: page)
                }
            }
            distance += step
        }
        return nil
    }

    #else

    private static let mutex: UnsafeMutablePointer<pthread_mutex_t> = {
        let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(mutex, nil)
        return mutex
    }()

    static func lock() { pthread_mutex_lock(mutex) }
    static func unlock() { pthread_mutex_unlock(mutex) }

    static func milliseconds() -> UInt64 {
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        return UInt64(now.tv_sec) * 1000 + UInt64(now.tv_nsec) / 1_000_000
    }

    /// Nothing to do: the Linux library links the Swift runtime statically and vrserver
    /// keeps drivers loaded.
    static func pinThisLibrary(containing address: UnsafeRawPointer) {}

    #if os(Linux)

    static func findVRLink() -> Module? {
        var found: Module?
        _ = withUnsafeMutablePointer(to: &found) { context in
            dl_iterate_phdr({ object, _, context in
                guard let object, let name = object.pointee.name, let headers = object.pointee.headers, let context else { return 0 }
                let length = strlen(name), suffix: StaticString = "driver_vrlink.so"
                guard length >= suffix.utf8CodeUnitCount,
                      memcmp(name + length - suffix.utf8CodeUnitCount, suffix.utf8Start, suffix.utf8CodeUnitCount) == 0 else { return 0 }
                var module = Module(slide: object.pointee.slide, file: Array(UnsafeBufferPointer(start: name, count: length + 1)))
                for index in 0..<Int(object.pointee.count) where headers[index].p_type == 1 && headers[index].p_flags & 1 != 0 {
                    let address = object.pointee.slide + UInt(headers[index].p_vaddr)
                    module.code.append(Scan.Region(address: UInt64(address),
                                                   bytes: ByteView(start: UnsafePointer(bitPattern: address), count: Int(headers[index].p_filesz))))
                }
                context.assumingMemoryBound(to: Module?.self).pointee = module
                return 1
            }, context)
        }
        return found
    }

    #else

    /// Other systems have no `driver_vrlink`; the driver builds there only so the rest of
    /// the package can be worked on from a development machine.
    static func findVRLink() -> Module? { nil }

    #endif

    static func writeCode(at address: UInt, _ bytes: UnsafeRawBufferPointer) -> Bool {
        let start = address & ~(page - 1)
        let length = ((address + UInt(bytes.count) + page - 1) & ~(page - 1)) - start
        guard let target = UnsafeMutableRawPointer(bitPattern: address), let source = bytes.baseAddress,
              mprotect(UnsafeMutableRawPointer(bitPattern: start), Int(length), PROT_READ | PROT_WRITE | PROT_EXEC) == 0 else { return false }
        target.copyMemory(from: source, byteCount: bytes.count)
        mprotect(UnsafeMutableRawPointer(bitPattern: start), Int(length), PROT_READ | PROT_EXEC)
        return true
    }

    static func pageNear(_ address: UInt) -> UInt? {
        let step: UInt = 0x10_0000, start = address & ~(step - 1)
        var distance = step
        while distance < reach {
            for hint in [start &- distance, start &+ distance] where hint > step && hint < UInt(Int.max) {
                // The kernel uses the hint when that address is free.
                let mapped = mmap(UnsafeMutableRawPointer(bitPattern: hint), Int(page), PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0)
                // A failed mapping is reported as the address -1 (`MAP_FAILED`, a macro Swift does not import).
                guard let mapped, mapped != UnsafeMutableRawPointer(bitPattern: -1) else { continue }
                let got = UInt(bitPattern: mapped)
                if (got > address ? got - address : address - got) < reach { return got }
                munmap(mapped, Int(page))
            }
            distance += step
        }
        return nil
    }

    #endif
}
