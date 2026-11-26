// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import COpenXR
import Foundation
import VRLinkCore

/// Throws `XRFailure.call` when `result` is negative; qualified positive success codes pass through.
@discardableResult
func check(_ result: XrResult, _ name: String) throws -> XrResult {
    try XRFailure.check(result, name)
}

extension XRFailure {
    /// Throws `XRFailure.call` if `result` indicates an OpenXR error.
    @discardableResult
    public static func check(_ result: XrResult, _ name: String) throws -> XrResult {
        guard result.rawValue >= 0 else { throw XRFailure.call(name, result) }
        return result
    }
}

/// Copies a UTF-8 string into a fixed-size C `char[N]` tuple field, truncating if needed and null-terminating.
func fill<Field>(_ field: inout Field, with text: String) {
    withUnsafeMutableBytes(of: &field) { bytes in
        guard !bytes.isEmpty else { return }
        let characters = Array(text.utf8.prefix(bytes.count - 1))
        bytes.copyBytes(from: characters)
        bytes[characters.count] = 0
    }
}

/// Decodes a null-terminated UTF-8 string from a fixed-size C `char[N]` tuple field.
func text<Field>(of field: Field) -> String {
    withUnsafeBytes(of: field) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// Platform process handles passed during OpenXR loader and instance initialization (used on Android).
public struct XRProcess {
    /// Pointers to the Android `JavaVM` and `ANativeActivity` JNI object required by `XR_KHR_loader_init_android`.
    public var javaVM: UnsafeMutableRawPointer?
    public var activity: UnsafeMutableRawPointer?

    public init(javaVM: UnsafeMutableRawPointer? = nil, activity: UnsafeMutableRawPointer? = nil) {
        self.javaVM = javaVM
        self.activity = activity
    }
}

/// Manages an `XrInstance`, its resolved OpenXR function pointers, and the target HMD `XrSystemId`.
public final class XRInstance {
    public let handle: XrInstance
    /// OpenXR system ID for the head-mounted display.
    public let system: XrSystemId
    /// Instance extensions enabled during creation.
    public let extensions: Set<String>
    /// All instance extensions advertised by the OpenXR runtime, recorded for diagnostic logging.
    public let offered: Set<String>
    /// Human-readable runtime name and version string.
    public let runtimeName: String

    private let entry: PFN_xrGetInstanceProcAddr
    let calls: Calls

    /// Optional extensions enabled automatically whenever the runtime advertises them.
    static let optional = [
        "XR_KHR_convert_timespec_time",      // display times on the client's clock
        "XR_EXT_hand_tracking",
        "XR_EXT_hand_interaction",           // hand aim ray and pinch actions for panel UI
        "XR_EXT_eye_gaze_interaction",       // eye gaze for foveated encoding and social gaze
        "XR_ANDROID_face_tracking",
        "XR_FB_hand_tracking_aim",           // system hand gestures (such as Quest's left-hand menu pinch)
        "XR_FB_display_refresh_rate",
        "XR_FB_color_space",                 // declare content color primaries on wide-gamut displays
        "XR_FB_passthrough",                 // passthrough layer when alpha-blend mode is unavailable
        "XR_ANDROID_recommended_resolution", // dynamic eye resolution notifications on Android XR
        "XR_EXT_performance_settings",       // sustained clock requests and thermal throttling events
        "XR_EXT_local_floor",
        "XR_META_touch_controller_plus",
        "XR_FB_touch_controller_pro",
        "XR_BD_controller_interaction",
        "XR_HTC_vive_focus3_controller_interaction",
        "XR_FB_face_tracking2",              // Quest Pro camera face tracking and Quest 3 audio lip sync
    ]

    /// - Parameter required: Instance extensions required by the graphics backend.
    public init(applicationName: String, required: [String], process: XRProcess = XRProcess(),
                log: (String) -> Void) throws {
        let entry = try Loader.entryPoint(log: log)
        self.entry = entry
        func early<Function>(_ name: String, _ type: Function.Type) throws -> Function {
            var found: PFN_xrVoidFunction?
            let result = entry(nil, name, &found)
            guard result.rawValue >= 0, let found else { throw XRFailure.call("xrGetInstanceProcAddr(\(name))", result) }
            return unsafeBitCast(found, to: type)
        }

        var wanted = required
        #if os(Android)
        // Initialize the Android OpenXR loader with the JVM and Activity context before enumerating extensions.
        var start = XrLoaderInitInfoAndroidKHR()
        start.type = XR_TYPE_LOADER_INIT_INFO_ANDROID_KHR
        start.applicationVM = process.javaVM
        start.applicationContext = process.activity
        let initialize = try early("xrInitializeLoaderKHR", PFN_xrInitializeLoaderKHR.self)
        try withUnsafeBytes(of: &start) { bytes in
            _ = try check(initialize(bytes.baseAddress?.assumingMemoryBound(to: XrLoaderInitInfoBaseHeaderKHR.self)),
                          "xrInitializeLoaderKHR")
        }
        wanted.append("XR_KHR_android_create_instance")
        #endif

        let enumerate = try early("xrEnumerateInstanceExtensionProperties", PFN_xrEnumerateInstanceExtensionProperties.self)
        var count: UInt32 = 0
        try check(enumerate(nil, 0, &count, nil), "xrEnumerateInstanceExtensionProperties")
        var blank = XrExtensionProperties()
        blank.type = XR_TYPE_EXTENSION_PROPERTIES
        var offered = [XrExtensionProperties](repeating: blank, count: Int(count))
        try check(enumerate(nil, count, &count, &offered), "xrEnumerateInstanceExtensionProperties")
        let available = Set(offered.prefix(Int(count)).map { text(of: $0.extensionName) })
        for name in wanted where !available.contains(name) { throw XRFailure.unsupported(name) }
        wanted += XRInstance.optional.filter { available.contains($0) && !wanted.contains($0) }
        extensions = Set(wanted)
        self.offered = available

        var info = XrInstanceCreateInfo()
        info.type = XR_TYPE_INSTANCE_CREATE_INFO
        fill(&info.applicationInfo.applicationName, with: applicationName)
        fill(&info.applicationInfo.engineName, with: "OpenVRLink")
        info.applicationInfo.applicationVersion = 1
        // Request OpenXR 1.0 for compatibility across all OpenXR 1.x runtimes.
        info.applicationInfo.apiVersion = ovrl_xr_version(1, 0, 0)
        let names = wanted.map { strdup($0) }
        defer { names.forEach { free($0) } }
        let pointers = names.map { UnsafePointer<CChar>($0) }
        info.enabledExtensionCount = UInt32(pointers.count)
        let create = try early("xrCreateInstance", PFN_xrCreateInstance.self)
        var made: XrInstance?
        #if os(Android)
        var android = XrInstanceCreateInfoAndroidKHR()
        android.type = XR_TYPE_INSTANCE_CREATE_INFO_ANDROID_KHR
        android.applicationVM = process.javaVM
        android.applicationActivity = process.activity
        try withUnsafePointer(to: &android) { android in
            info.next = UnsafeRawPointer(android)
            try pointers.withUnsafeBufferPointer {
                info.enabledExtensionNames = $0.baseAddress
                _ = try check(create(&info, &made), "xrCreateInstance")
            }
        }
        #else
        try pointers.withUnsafeBufferPointer {
            info.enabledExtensionNames = $0.baseAddress
            _ = try check(create(&info, &made), "xrCreateInstance")
        }
        #endif
        guard let made else { throw XRFailure.call("xrCreateInstance", XR_ERROR_RUNTIME_FAILURE) }
        handle = made
        calls = try Calls { name in
            var found: PFN_xrVoidFunction?
            _ = entry(made, name, &found)
            return found
        }

        var properties = XrInstanceProperties()
        properties.type = XR_TYPE_INSTANCE_PROPERTIES
        try check(calls.getInstanceProperties(made, &properties), "xrGetInstanceProperties")
        let version = properties.runtimeVersion
        runtimeName = "\(text(of: properties.runtimeName)) \(ovrl_xr_version_major(version)).\(ovrl_xr_version_minor(version))."
            + "\(ovrl_xr_version_patch(version))"

        var which = XrSystemGetInfo()
        which.type = XR_TYPE_SYSTEM_GET_INFO
        which.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY
        var system: XrSystemId = 0
        do {
            try check(calls.getSystem(made, &which, &system), "xrGetSystem")
        } catch {
            _ = calls.destroyInstance(made)
            throw error
        }
        self.system = system
    }

    deinit { _ = calls.destroyInstance(handle) }

    /// Resolves an extension function pointer by name via `xrGetInstanceProcAddr`.
    public func function<Function>(_ name: String, as type: Function.Type) throws -> Function {
        var found: PFN_xrVoidFunction?
        let result = entry(handle, name, &found)
        guard result.rawValue >= 0, let found else { throw XRFailure.call("xrGetInstanceProcAddr(\(name))", result) }
        return unsafeBitCast(found, to: type)
    }

    public func path(_ string: String) throws -> XrPath {
        var path: XrPath = 0
        try check(calls.stringToPath(handle, string, &path), "xrStringToPath(\(string))")
        return path
    }

    public func string(_ path: XrPath) -> String {
        guard path != 0 else { return "" }
        var characters = [CChar](repeating: 0, count: Int(XR_MAX_PATH_LENGTH))
        var count: UInt32 = 0
        guard calls.pathToString(handle, path, UInt32(characters.count), &count, &characters).rawValue >= 0 else { return "" }
        return String(cString: characters)
    }

    /// Queries the HMD system name from `xrGetSystemProperties`.
    public func systemName() -> String {
        var properties = XrSystemProperties()
        properties.type = XR_TYPE_SYSTEM_PROPERTIES
        guard calls.getSystemProperties(handle, system, &properties).rawValue >= 0 else { return "" }
        return text(of: properties.systemName)
    }
}

/// Core and optional OpenXR function pointers resolved once per `XrInstance`.
struct Calls {
    let destroyInstance: PFN_xrDestroyInstance
    let getInstanceProperties: PFN_xrGetInstanceProperties
    let pollEvent: PFN_xrPollEvent
    let getSystem: PFN_xrGetSystem
    let getSystemProperties: PFN_xrGetSystemProperties
    let stringToPath: PFN_xrStringToPath
    let pathToString: PFN_xrPathToString
    let enumerateViewConfigurationViews: PFN_xrEnumerateViewConfigurationViews
    let enumerateEnvironmentBlendModes: PFN_xrEnumerateEnvironmentBlendModes
    let createSession: PFN_xrCreateSession
    let destroySession: PFN_xrDestroySession
    let beginSession: PFN_xrBeginSession
    let endSession: PFN_xrEndSession
    let requestExitSession: PFN_xrRequestExitSession
    let enumerateReferenceSpaces: PFN_xrEnumerateReferenceSpaces
    let createReferenceSpace: PFN_xrCreateReferenceSpace
    let getReferenceSpaceBoundsRect: PFN_xrGetReferenceSpaceBoundsRect
    let destroySpace: PFN_xrDestroySpace
    let locateSpace: PFN_xrLocateSpace
    let locateViews: PFN_xrLocateViews
    let enumerateSwapchainFormats: PFN_xrEnumerateSwapchainFormats
    let createSwapchain: PFN_xrCreateSwapchain
    let destroySwapchain: PFN_xrDestroySwapchain
    let enumerateSwapchainImages: PFN_xrEnumerateSwapchainImages
    let acquireSwapchainImage: PFN_xrAcquireSwapchainImage
    let waitSwapchainImage: PFN_xrWaitSwapchainImage
    let releaseSwapchainImage: PFN_xrReleaseSwapchainImage
    let waitFrame: PFN_xrWaitFrame
    let beginFrame: PFN_xrBeginFrame
    let endFrame: PFN_xrEndFrame
    let createActionSet: PFN_xrCreateActionSet
    let createAction: PFN_xrCreateAction
    let suggestInteractionProfileBindings: PFN_xrSuggestInteractionProfileBindings
    let attachSessionActionSets: PFN_xrAttachSessionActionSets
    let createActionSpace: PFN_xrCreateActionSpace
    let syncActions: PFN_xrSyncActions
    let getActionStateBoolean: PFN_xrGetActionStateBoolean
    let getActionStateFloat: PFN_xrGetActionStateFloat
    let getActionStateVector2f: PFN_xrGetActionStateVector2f
    let getActionStatePose: PFN_xrGetActionStatePose
    let applyHapticFeedback: PFN_xrApplyHapticFeedback
    let getCurrentInteractionProfile: PFN_xrGetCurrentInteractionProfile

    // Optional extension functions (`nil` when unsupported by the runtime).
    let convertTimeToTimespecTime: PFN_xrConvertTimeToTimespecTimeKHR?
    let createHandTracker: PFN_xrCreateHandTrackerEXT?
    let destroyHandTracker: PFN_xrDestroyHandTrackerEXT?
    let locateHandJoints: PFN_xrLocateHandJointsEXT?
    let enumerateDisplayRefreshRates: PFN_xrEnumerateDisplayRefreshRatesFB?
    let getDisplayRefreshRate: PFN_xrGetDisplayRefreshRateFB?
    let setPerformanceLevel: PFN_xrPerfSettingsSetPerformanceLevelEXT?
    let requestDisplayRefreshRate: PFN_xrRequestDisplayRefreshRateFB?
    let setColorSpace: PFN_xrSetColorSpaceFB?
    let createPassthrough: PFN_xrCreatePassthroughFB?
    let destroyPassthrough: PFN_xrDestroyPassthroughFB?
    let passthroughStart: PFN_xrPassthroughStartFB?
    let passthroughPause: PFN_xrPassthroughPauseFB?
    let createPassthroughLayer: PFN_xrCreatePassthroughLayerFB?
    let destroyPassthroughLayer: PFN_xrDestroyPassthroughLayerFB?

    init(_ find: (String) -> PFN_xrVoidFunction?) throws {
        func need<Function>(_ name: String) throws -> Function {
            guard let found = find(name) else { throw XRFailure.unsupported(name) }
            return unsafeBitCast(found, to: Function.self)
        }
        func extra<Function>(_ name: String) -> Function? {
            find(name).map { unsafeBitCast($0, to: Function.self) }
        }
        destroyInstance = try need("xrDestroyInstance")
        getInstanceProperties = try need("xrGetInstanceProperties")
        pollEvent = try need("xrPollEvent")
        getSystem = try need("xrGetSystem")
        getSystemProperties = try need("xrGetSystemProperties")
        stringToPath = try need("xrStringToPath")
        pathToString = try need("xrPathToString")
        enumerateViewConfigurationViews = try need("xrEnumerateViewConfigurationViews")
        enumerateEnvironmentBlendModes = try need("xrEnumerateEnvironmentBlendModes")
        createSession = try need("xrCreateSession")
        destroySession = try need("xrDestroySession")
        beginSession = try need("xrBeginSession")
        endSession = try need("xrEndSession")
        requestExitSession = try need("xrRequestExitSession")
        enumerateReferenceSpaces = try need("xrEnumerateReferenceSpaces")
        createReferenceSpace = try need("xrCreateReferenceSpace")
        getReferenceSpaceBoundsRect = try need("xrGetReferenceSpaceBoundsRect")
        destroySpace = try need("xrDestroySpace")
        locateSpace = try need("xrLocateSpace")
        locateViews = try need("xrLocateViews")
        enumerateSwapchainFormats = try need("xrEnumerateSwapchainFormats")
        createSwapchain = try need("xrCreateSwapchain")
        destroySwapchain = try need("xrDestroySwapchain")
        enumerateSwapchainImages = try need("xrEnumerateSwapchainImages")
        acquireSwapchainImage = try need("xrAcquireSwapchainImage")
        waitSwapchainImage = try need("xrWaitSwapchainImage")
        releaseSwapchainImage = try need("xrReleaseSwapchainImage")
        waitFrame = try need("xrWaitFrame")
        beginFrame = try need("xrBeginFrame")
        endFrame = try need("xrEndFrame")
        createActionSet = try need("xrCreateActionSet")
        createAction = try need("xrCreateAction")
        suggestInteractionProfileBindings = try need("xrSuggestInteractionProfileBindings")
        attachSessionActionSets = try need("xrAttachSessionActionSets")
        createActionSpace = try need("xrCreateActionSpace")
        syncActions = try need("xrSyncActions")
        getActionStateBoolean = try need("xrGetActionStateBoolean")
        getActionStateFloat = try need("xrGetActionStateFloat")
        getActionStateVector2f = try need("xrGetActionStateVector2f")
        getActionStatePose = try need("xrGetActionStatePose")
        applyHapticFeedback = try need("xrApplyHapticFeedback")
        getCurrentInteractionProfile = try need("xrGetCurrentInteractionProfile")
        convertTimeToTimespecTime = extra("xrConvertTimeToTimespecTimeKHR")
        createHandTracker = extra("xrCreateHandTrackerEXT")
        destroyHandTracker = extra("xrDestroyHandTrackerEXT")
        locateHandJoints = extra("xrLocateHandJointsEXT")
        enumerateDisplayRefreshRates = extra("xrEnumerateDisplayRefreshRatesFB")
        getDisplayRefreshRate = extra("xrGetDisplayRefreshRateFB")
        setPerformanceLevel = extra("xrPerfSettingsSetPerformanceLevelEXT")
        requestDisplayRefreshRate = extra("xrRequestDisplayRefreshRateFB")
        setColorSpace = extra("xrSetColorSpaceFB")
        createPassthrough = extra("xrCreatePassthroughFB")
        destroyPassthrough = extra("xrDestroyPassthroughFB")
        passthroughStart = extra("xrPassthroughStartFB")
        passthroughPause = extra("xrPassthroughPauseFB")
        createPassthroughLayer = extra("xrCreatePassthroughLayerFB")
        destroyPassthroughLayer = extra("xrDestroyPassthroughLayerFB")
    }
}
