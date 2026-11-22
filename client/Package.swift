// swift-tools-version:5.9
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

/// Non-Apple platforms that need swift-crypto instead of CryptoKit.
let otherThanApple: [Platform] = [.linux, .android, .windows]

let package = Package(
    name: "OpenVRLink",
    platforms: [.macOS(.v14), .visionOS("26.0")],
    products: [
        .library(name: "VRLinkCore", targets: ["VRLinkCore"]),
        .library(name: "VRLinkApple", targets: ["VRLinkVideoToolbox", "VRLinkMetal", "VRLinkAppleAudio", "VRLinkAppleNetwork", "VRLinkAppleFace",
                                                "VRLinkVisionTracking", "VRLinkAppleSession", "VRLinkVisionCompositor",
                                                "VRLinkVisionRooms"]),
        .library(name: "VRLinkOpenXR", targets: ["VRLinkOpenXR", "VRLinkOpenXRMetal"]),
        // Native shared library loaded by the Android XR NativeActivity (libOpenVRLinkAndroid.so).
        .library(name: "OpenVRLinkAndroid", type: .dynamic, targets: ["OpenVRLinkAndroid"]),
        // Separate library product since nothing else depends on it.
        .library(name: "VRLinkExperiments", targets: ["VRLinkVisionExperiments"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // Core protocol, session, and frame composition. Depends only on
        // Foundation, POSIX sockets, and crypto (CryptoKit on Apple platforms,
        // or swift-crypto via `Primitives` elsewhere), with no UI, graphics,
        // audio, or decoder frameworks.
        .target(name: "VRLinkCore", dependencies: [
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: otherThanApple)),
            .product(name: "_CryptoExtras", package: "swift-crypto", condition: .when(platforms: otherThanApple)),
        ]),
        // Platform backends (see docs/client-architecture.md).
        .target(name: "VRLinkVideoToolbox", dependencies: ["VRLinkCore"]),            // hardware video decoder
        .target(name: "VRLinkMetal", dependencies: ["VRLinkCore", "VRLinkVideoToolbox"],    // Metal quad renderer for decoded frames
                resources: [.copy("Quad.metal"), .copy("Shrink.metal")]),
        .target(name: "VRLinkAppleAudio", dependencies: ["VRLinkCore"]),              // audio playback and mic capture
        .target(name: "VRLinkAppleNetwork"),                                          // Bonjour discovery, Ethernet detection, OS version
        .target(name: "VRLinkAppleFace", dependencies: ["VRLinkCore"]),               // camera-based face and eye tracking
        // Head, hand, and controller tracking via ARKit, GameController, and
        // spatial events on visionOS (empty on other platforms).
        .target(name: "VRLinkVisionTracking", dependencies: ["VRLinkCore"]),
        // Host discovery, pairing, session lifecycle (including video decoding
        // and audio), and persistent user settings.
        .target(name: "VRLinkAppleSession", dependencies: [
            "VRLinkCore", "VRLinkVideoToolbox", "VRLinkAppleAudio", "VRLinkAppleNetwork",
        ]),
        // Room selection and the Room Setup immersive space for visionOS (empty on other platforms).
        .target(name: "VRLinkVisionRooms", dependencies: ["VRLinkCore", "VRLinkVisionTracking", "VRLinkAppleSession"]),
        // CompositorServices renderer for visionOS (empty on other platforms).
        .target(name: "VRLinkVisionCompositor", dependencies: [
            "VRLinkCore", "VRLinkVideoToolbox", "VRLinkMetal", "VRLinkVisionTracking", "VRLinkAppleSession",
            "VRLinkAppleNetwork",
        ]),
        // Experimental visionOS features, including RealityKit stream rendering,
        // Spatial Persona face/gaze tracking, and calibration flows (empty on other platforms).
        .target(name: "VRLinkVisionExperiments", dependencies: [
            "VRLinkCore", "VRLinkVideoToolbox", "VRLinkMetal", "VRLinkAppleFace", "VRLinkVisionTracking",
            "VRLinkAppleSession", "VRLinkVisionCompositor",
        ], resources: [.copy("SBSMaterial.usda")]),
        // C module exposing the Khronos OpenXR headers without linking an OpenXR loader (see VRLinkOpenXR/Loader.swift).
        .target(name: "COpenXR", dependencies: ["CAndroidNDK"]),
        // Graphics-API-independent OpenXR session, tracking, and input backend.
        .target(name: "VRLinkOpenXR", dependencies: ["VRLinkCore", "COpenXR"]),
        // Metal graphics backend for OpenXR sessions (empty on non-Apple platforms).
        .target(name: "VRLinkOpenXRMetal", dependencies: [
            "VRLinkCore", "COpenXR", "VRLinkOpenXR", "VRLinkMetal", "VRLinkVideoToolbox",
        ]),
        // macOS OpenXR client executable for testing against desktop runtimes such as OXRSys.
        .executableTarget(name: "OpenVRLinkXR", dependencies: [
            "VRLinkCore", "VRLinkOpenXR", "VRLinkOpenXRMetal", "VRLinkVideoToolbox", "VRLinkAppleAudio", "VRLinkAppleNetwork",
        ]),
        // C module exposing Android NDK headers for NativeActivity, MediaCodec, AAudio, and Vulkan (empty on other platforms).
        .target(name: "CAndroidNDK", linkerSettings: ["android", "log", "mediandk", "aaudio", "vulkan"].map {
            .linkedLibrary($0, .when(platforms: [.android]))
        }),
        // Android platform backends for MediaCodec hardware-buffer decoding, Vulkan OpenXR rendering,
        // and AAudio playback (empty on other platforms).
        .target(name: "VRLinkMediaCodec", dependencies: ["VRLinkCore", "CAndroidNDK"]),
        .target(name: "VRLinkVulkan", dependencies: ["VRLinkCore", "CAndroidNDK", "COpenXR", "VRLinkOpenXR", "VRLinkMediaCodec"],
                exclude: ["Shaders"]),
        .target(name: "VRLinkAndroidAudio", dependencies: ["VRLinkCore", "CAndroidNDK"]),
        // Android XR NativeActivity entry point, packaged into an APK by client/android/build.sh.
        .target(name: "OpenVRLinkAndroid", dependencies: [
            "VRLinkCore", "CAndroidNDK", "VRLinkOpenXR", "VRLinkVulkan", "VRLinkMediaCodec", "VRLinkAndroidAudio",
        ]),
        // Standalone macOS test viewer that renders the VR stream in a window.
        .executableTarget(name: "OpenVRLink", dependencies: [
            "VRLinkCore", "VRLinkVideoToolbox", "VRLinkMetal", "VRLinkAppleAudio", "VRLinkAppleNetwork", "VRLinkAppleFace",
        ]),
        .testTarget(name: "VRLinkCoreTests", dependencies: ["VRLinkCore"]),
        .testTarget(name: "VRLinkOpenXRTests", dependencies: ["VRLinkCore", "VRLinkOpenXR"]),
        .testTarget(name: "VRLinkVideoToolboxTests", dependencies: ["VRLinkCore", "VRLinkVideoToolbox"]),
        .testTarget(name: "VRLinkMetalTests", dependencies: ["VRLinkCore", "VRLinkVideoToolbox", "VRLinkMetal"]),
    ]
)
