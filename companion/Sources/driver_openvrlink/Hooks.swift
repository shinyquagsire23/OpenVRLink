// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import DriverABI
import PatchCore

// Hook callbacks invoked from redirected `driver_vrlink` call sites. Each callback
// runs on `driver_vrlink`'s calling thread and forwards to the original function.

/// State shared between the replacements and the provider; guarded by `Platform.lock()`.
enum Shared {
    static var host: HostSide?
    /// Addresses of the original functions.
    static var parse: UInt = 0, populate: UInt = 0, constants: UInt = 0, loadSPIRV: UInt = 0, constantsD3D: UInt = 0, readShader: UInt = 0
    /// Encode shaders handed to `driver_vrlink` with the gamma patch, and ones that could not be patched.
    static var shadersPatched = 0, shadersRefused = 0
    /// Which argument of the Vulkan constants function is the buffer (it differs between builds).
    static var constantsBufferArgument = 4
    /// Where in that buffer, counted in floats, the patched Vulkan shaders read gamma;
    /// known once one has been patched (`SPIRV.patchGamma` reports it).
    static var vulkanGammaConstant: Int?

    /// Gamma for the frame being prepared now.
    static func activeGamma() -> Float {
        Platform.lock()
        defer { Platform.unlock() }
        return host?.activeGamma(atMilliseconds: Platform.milliseconds()) ?? 1
    }
}

typealias ParseRecords = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32) -> UInt
typealias PopulateRecords = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32) -> UInt
/// The Vulkan constants function, taken as six register arguments passed through untouched:
/// its parameters differ between builds, but in all of them one of the six is the buffer.
typealias UpdateConstants = @convention(c) (UInt, UInt, UInt, UInt, UInt, UInt) -> Void
typealias UpdateConstantsD3D = @convention(c) (UnsafeMutableRawPointer?, Bool, Bool, UInt32, UInt32, UnsafeMutablePointer<Float>?) -> Void
typealias LoadSPIRV = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
typealias ReadShader = @convention(c) (UnsafePointer<UInt16>?, UnsafeMutablePointer<UnsafeMutablePointer<d3d_blob>?>?) -> Int32

/// Inspects incoming client key/value records for OpenVRLink handshake keys.
let parseRecords: ParseRecords = { root, records, count in
    if let records, count >= 1, count <= 64 {
        Platform.lock()
        Shared.host?.observe(records, count: Int(count), atMilliseconds: Platform.milliseconds())
        Platform.unlock()
    }
    return unsafeBitCast(Shared.parse, to: ParseRecords.self)(root, records, count)
}

/// Injects OpenVRLink host handshake keys into outgoing record batches when an OpenVRLink client is active.
let populateRecords: PopulateRecords = { root, records, count in
    let result = unsafeBitCast(Shared.populate, to: PopulateRecords.self)(root, records, count)
    if let records, count >= 1, count <= 64 {
        Platform.lock()
        Shared.host?.fill(records, count: Int(count), atMilliseconds: Platform.milliseconds())
        Platform.unlock()
    }
    return result
}

/// Writes the active encoding gamma into the Vulkan encode constant buffer after `UpdateConstantBuffer` runs.
let updateConstants: UpdateConstants = { a, b, c, d, e, f in
    unsafeBitCast(Shared.constants, to: UpdateConstants.self)(a, b, c, d, e, f)
    Platform.lock()
    let index = Shared.vulkanGammaConstant, argument = Shared.constantsBufferArgument
    Platform.unlock()
    guard let index, let constants = UnsafeMutablePointer<Float>(bitPattern: argument == 5 ? f : e) else { return }
    constants[index] = Shared.activeGamma()
}

/// Writes the active encoding gamma into the Direct3D copy-view constant buffer.
let updateConstantsD3D: UpdateConstantsD3D = { driver, layer, flag, width, height, constants in
    unsafeBitCast(Shared.constantsD3D, to: UpdateConstantsD3D.self)(driver, layer, flag, width, height, constants)
    constants?[DXBC.gammaConstant] = Shared.activeGamma()
}

/// The last path component of a C string path, by either separator.
func fileName(of path: UnsafePointer<CChar>) -> UnsafePointer<CChar> {
    var name = path, index = 0
    while path[index] != 0 {
        if path[index] == 0x2F || path[index] == 0x5C { name = path + index + 1 }
        index += 1
    }
    return name
}

func hasPrefix(_ text: UnsafePointer<CChar>, _ prefix: StaticString) -> Bool {
    strncmp(text, Server.cString(prefix), prefix.utf8CodeUnitCount) == 0
}

/// Reads an entire file into memory, or returns `nil` if it cannot be read.
func contents(ofFile path: UnsafePointer<CChar>) -> [UInt8]? {
    guard let file = fopen(path, "rb") else { return nil }
    defer { fclose(file) }
    guard fseek(file, 0, SEEK_END) == 0 else { return nil }
    let size = Int(ftell(file))         // `long`: 32 bits on Windows
    guard size >= 0, fseek(file, 0, SEEK_SET) == 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    let read = bytes.withUnsafeMutableBytes { fread($0.baseAddress, 1, size, file) }
    return read == size ? bytes : nil
}

/// Records that an encode shader was handed over patched, or could not be. Vulkan shaders
/// say where they read gamma; one that disagrees with the others counts as refused, since
/// the driver fills one buffer for all of them.
private func notePatched(_ patched: Bool, vulkanGammaConstant: Int? = nil) {
    Platform.lock()
    var patched = patched
    if patched, let vulkanGammaConstant {
        if let known = Shared.vulkanGammaConstant, known != vulkanGammaConstant { patched = false } else { Shared.vulkanGammaConstant = vulkanGammaConstant }
    }
    if patched { Shared.shadersPatched += 1 } else { Shared.shadersRefused += 1 }
    Platform.unlock()
}

/// Intercepts `LoadSpirvFile` on Linux and substitutes a gamma-patched copy written to
/// `/tmp` for `genforencode_c*` shaders. The original function returns a
/// `std::optional<std::vector<uint32_t>>` via sret pointer `result`.
let loadSPIRV: LoadSPIRV = { result, path in
    let original = unsafeBitCast(Shared.loadSPIRV, to: LoadSPIRV.self)
    // `genforencode_comp_*` in the July 2026 build, `genforencode_cs_*` since October.
    guard let path, hasPrefix(fileName(of: path), "genforencode_c") else { return original(result, path) }
    let name = fileName(of: path)
    var patched: [UInt8]?, gammaConstant: Int?
    if let stock = contents(ofFile: path), let result = stock.withUnsafeBufferPointer({ try? SPIRV.patchGamma($0) }) {
        (patched, gammaConstant) = (result.bytes, result.gammaConstant)
    }
    #if os(Windows)
    let process = 0
    #else
    let process = Int(getpid())
    #endif
    var copy = Message("/tmp/openvrlink-").adding(process).adding("-").adding(cString: name).characters + [0]
    var written = false
    if let patched, let file = fopen(&copy, "wb") {
        written = patched.withUnsafeBytes { fwrite($0.baseAddress, 1, patched.count, file) } == patched.count
        fclose(file)
    }
    notePatched(written, vulkanGammaConstant: gammaConstant)
    Server.say(Message("VR Link read shader ").adding(cString: name).adding(written ? ": encoding gamma added" : ": left stock"))
    return written ? original(result, &copy) : original(result, path)
}

// A blob of our own, holding a patched Direct3D shader.
private let blobVtable: UnsafeMutablePointer<d3d_blob_vtable> = {
    let vtable = UnsafeMutablePointer<d3d_blob_vtable>.allocate(capacity: 1)
    vtable.initialize(to: d3d_blob_vtable(
        // The only interfaces a blob has are IUnknown and ID3DBlob, and this object is both.
        query_interface: { blob, _, out in
            blob?.pointee.references += 1
            out?.pointee = UnsafeMutableRawPointer(blob)
            return 0
        },
        add_ref: { blob in
            blob?.pointee.references += 1
            return blob?.pointee.references ?? 0
        },
        release: { blob in
            guard let blob else { return 0 }
            blob.pointee.references -= 1
            let left = blob.pointee.references
            if left == 0 {
                free(blob.pointee.bytes)
                free(blob)
            }
            return left
        },
        pointer: { blob in UnsafeMutableRawPointer(blob?.pointee.bytes) },
        size: { blob in blob?.pointee.size ?? 0 }))
    return vtable
}()

/// Intercepts `D3DReadFileToBlob` in Windows `driver_vrlink.dll`. Substitutes a
/// gamma-patched DXBC blob (`DXBC.patchGamma`) for `genforencode_*` copy-view shaders,
/// and passes all other shaders (or any shader that fails patching) through unchanged.
let readShader: ReadShader = { path, blob in
    let result = unsafeBitCast(Shared.readShader, to: ReadShader.self)(path, blob)
    guard let path else { return result }
    // The file name, narrowed to ASCII for the log and the comparison.
    var name: [CChar] = []
    var index = 0
    while path[index] != 0, index < 1024 {
        if path[index] == 0x2F || path[index] == 0x5C { name.removeAll(keepingCapacity: true) } else { name.append(CChar(truncatingIfNeeded: path[index] & 0x7F)) }
        index += 1
    }
    name.append(0)
    guard result >= 0, let blob, let read = blob.pointee, hasPrefix(name, "genforencode_") else {
        Server.say(Message("VR Link read shader ").adding(cString: name))
        return result
    }
    // The real blob has the same first five methods as ours.
    let stock = ByteView(start: read.pointee.vtable.pointee.pointer(read)?.assumingMemoryBound(to: UInt8.self), count: read.pointee.vtable.pointee.size(read))
    if let patched = try? DXBC.patchGamma(stock), let bytes = malloc(patched.count), let ours = malloc(MemoryLayout<d3d_blob>.size) {
        patched.withUnsafeBytes { bytes.copyMemory(from: $0.baseAddress!, byteCount: patched.count) }
        let ours = ours.assumingMemoryBound(to: d3d_blob.self)
        ours.initialize(to: d3d_blob(vtable: blobVtable, references: 1, bytes: bytes.assumingMemoryBound(to: UInt8.self), size: patched.count))
        _ = read.pointee.vtable.pointee.release(read)
        blob.pointee = ours
        notePatched(true)
        Server.say(Message("VR Link read shader ").adding(cString: name).adding(": encoding gamma added"))
    } else {
        notePatched(false)
        Server.say(Message("VR Link read shader ").adding(cString: name).adding(": left stock"))
    }
    return result
}
