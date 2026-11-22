// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import COpenXR
import Foundation
import VRLinkCore

/// Errors thrown when loading or calling an OpenXR runtime.
public enum XRFailure: Error, CustomStringConvertible {
    /// No OpenXR runtime or loader could be found or loaded.
    case noRuntime(String)
    /// An OpenXR API call returned an error result.
    case call(String, XrResult)
    /// Required OpenXR feature, extension, or configuration is not supported by the runtime.
    case unsupported(String)

    public var description: String {
        switch self {
        case .noRuntime(let why): return "no OpenXR runtime: \(why)"
        case .call(let name, let result): return "\(name) failed with \(XRFailure.name(of: result))"
        case .unsupported(let what): return "the OpenXR runtime does not support \(what)"
        }
    }

    /// Formats common `XrResult` codes by symbolic name, falling back to the numeric code.
    static func name(of result: XrResult) -> String {
        let names: [Int32: String] = [
            XR_ERROR_VALIDATION_FAILURE.rawValue: "XR_ERROR_VALIDATION_FAILURE",
            XR_ERROR_RUNTIME_FAILURE.rawValue: "XR_ERROR_RUNTIME_FAILURE",
            XR_ERROR_FUNCTION_UNSUPPORTED.rawValue: "XR_ERROR_FUNCTION_UNSUPPORTED",
            XR_ERROR_EXTENSION_NOT_PRESENT.rawValue: "XR_ERROR_EXTENSION_NOT_PRESENT",
            XR_ERROR_API_VERSION_UNSUPPORTED.rawValue: "XR_ERROR_API_VERSION_UNSUPPORTED",
            XR_ERROR_INSTANCE_LOST.rawValue: "XR_ERROR_INSTANCE_LOST",
            XR_ERROR_SESSION_LOST.rawValue: "XR_ERROR_SESSION_LOST",
            XR_ERROR_SESSION_NOT_RUNNING.rawValue: "XR_ERROR_SESSION_NOT_RUNNING",
            XR_ERROR_SESSION_NOT_READY.rawValue: "XR_ERROR_SESSION_NOT_READY",
            XR_ERROR_FORM_FACTOR_UNAVAILABLE.rawValue: "XR_ERROR_FORM_FACTOR_UNAVAILABLE",
            XR_ERROR_FORM_FACTOR_UNSUPPORTED.rawValue: "XR_ERROR_FORM_FACTOR_UNSUPPORTED",
            XR_ERROR_PATH_UNSUPPORTED.rawValue: "XR_ERROR_PATH_UNSUPPORTED",
            XR_ERROR_GRAPHICS_DEVICE_INVALID.rawValue: "XR_ERROR_GRAPHICS_DEVICE_INVALID",
            XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED.rawValue: "XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED",
            XR_ERROR_TIME_INVALID.rawValue: "XR_ERROR_TIME_INVALID",
            XR_ERROR_CALL_ORDER_INVALID.rawValue: "XR_ERROR_CALL_ORDER_INVALID",
            XR_ERROR_HANDLE_INVALID.rawValue: "XR_ERROR_HANDLE_INVALID",
            XR_ERROR_INITIALIZATION_FAILED.rawValue: "XR_ERROR_INITIALIZATION_FAILED",
        ]
        return names[result.rawValue] ?? "XrResult \(result.rawValue)"
    }
}

/// Dynamically loads an OpenXR runtime or loader and resolves `xrGetInstanceProcAddr` without linking an
/// OpenXR loader library at build time.
///
/// On Android, `Loader` opens the bundled Khronos `libopenxr_loader.so`, which discovers the system
/// runtime through Android's OpenXR runtime broker after `XRInstance` initializes it with the JVM.
/// On macOS and Linux, `Loader` reads the active runtime JSON manifest directly and negotiates with the
/// runtime shared library via `xrNegotiateLoaderRuntimeInterface` (set `OPENXR_LOADER` to load an external
/// Khronos loader instead if API layers are needed). Windows registry lookup is not implemented yet.
enum Loader {
    /// Opens a dynamic library that remains loaded for the lifetime of the process.
    private static func library(_ path: String) -> UnsafeMutableRawPointer? {
        #if os(Windows)
        return nil
        #else
        return dlopen(path, RTLD_NOW | RTLD_LOCAL)
        #endif
    }

    private static func symbol<Function>(_ name: String, in library: UnsafeMutableRawPointer, as type: Function.Type) -> Function? {
        #if os(Windows)
        return nil
        #else
        guard let address = dlsym(library, name) else { return nil }
        return unsafeBitCast(address, to: type)
        #endif
    }

    /// Resolves `xrGetInstanceProcAddr` from a Khronos OpenXR loader library.
    private static func loader(at path: String) throws -> PFN_xrGetInstanceProcAddr {
        guard let opened = library(path) else { throw XRFailure.noRuntime("could not load \(path)") }
        guard let entry = symbol("xrGetInstanceProcAddr", in: opened, as: PFN_xrGetInstanceProcAddr.self)
        else { throw XRFailure.noRuntime("\(path) has no xrGetInstanceProcAddr") }
        return entry
    }

    static func entryPoint(log: (String) -> Void) throws -> PFN_xrGetInstanceProcAddr {
        #if os(Android)
        return try loader(at: "libopenxr_loader.so")
        #else
        if let path = ProcessInfo.processInfo.environment["OPENXR_LOADER"], !path.isEmpty {
            log("openxr: using loader at \(path)")
            return try loader(at: path)
        }
        return try runtime(log: log)
        #endif
    }

    /// Returns candidate paths for the active OpenXR runtime manifest in standard Khronos search order.
    static func manifests(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var places: [String] = []
        if let named = environment["XR_RUNTIME_JSON"], !named.isEmpty { places.append(named) }
        let file = "openxr/1/active_runtime.json"
        if let config = environment["XDG_CONFIG_HOME"], !config.isEmpty { places.append(config + "/" + file) }
        if let home = environment["HOME"], !home.isEmpty { places.append(home + "/.config/" + file) }
        for folder in (environment["XDG_CONFIG_DIRS"] ?? "/etc/xdg").split(separator: ":") { places.append(folder + "/" + file) }
        places += ["/etc/" + file, "/usr/local/share/" + file, "/usr/share/" + file]
        return places
    }

    /// Extracts `library_path` from an OpenXR runtime manifest JSON. Relative paths containing a directory
    /// separator are resolved against the manifest's real directory (after resolving symlinks), while bare
    /// library names are passed directly to `dlopen`.
    static func runtimeLibrary(manifest text: Data, at path: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: text) as? [String: Any],
              let runtime = json["runtime"] as? [String: Any], let library = runtime["library_path"] as? String, !library.isEmpty
        else { return nil }
        if library.hasPrefix("/") || !library.contains("/") { return library }
        let folder = URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent()
        return folder.appendingPathComponent(library).standardizedFileURL.path
    }

    /// Loads the active OpenXR runtime library directly and negotiates the loader-runtime interface.
    private static func runtime(log: (String) -> Void) throws -> PFN_xrGetInstanceProcAddr {
        let places = manifests()
        guard let path = places.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let text = FileManager.default.contents(atPath: path)
        else { throw XRFailure.noRuntime("no active runtime manifest (looked in \(places.joined(separator: ", ")))") }
        guard let file = runtimeLibrary(manifest: text, at: path) else { throw XRFailure.noRuntime("missing library_path in \(path)") }
        guard let opened = library(file) else { throw XRFailure.noRuntime("could not load \(file) (from \(path))") }
        guard let negotiate = symbol("xrNegotiateLoaderRuntimeInterface", in: opened, as: PFN_xrNegotiateLoaderRuntimeInterface.self)
        else { throw XRFailure.noRuntime("\(file) is not an OpenXR runtime") }

        var ours = XrNegotiateLoaderInfo()
        ours.structType = XR_LOADER_INTERFACE_STRUCT_LOADER_INFO
        ours.structVersion = UInt32(XR_LOADER_INFO_STRUCT_VERSION)
        ours.structSize = MemoryLayout<XrNegotiateLoaderInfo>.size
        ours.minInterfaceVersion = 1
        ours.maxInterfaceVersion = UInt32(XR_CURRENT_LOADER_RUNTIME_VERSION)
        ours.minApiVersion = ovrl_xr_version(1, 0, 0)
        ours.maxApiVersion = ovrl_xr_version(1, 0x3FF, 0xFFF)
        var theirs = XrNegotiateRuntimeRequest()
        theirs.structType = XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST
        theirs.structVersion = UInt32(XR_RUNTIME_INFO_STRUCT_VERSION)
        theirs.structSize = MemoryLayout<XrNegotiateRuntimeRequest>.size
        let result = negotiate(&ours, &theirs)
        guard result.rawValue >= 0, let entry = theirs.getInstanceProcAddr
        else { throw XRFailure.call("xrNegotiateLoaderRuntimeInterface", result) }
        log("openxr: runtime \(file)")
        return entry
    }
}
