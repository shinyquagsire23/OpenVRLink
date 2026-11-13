// swift-tools-version:5.9
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

let package = Package(
    name: "OpenVRLink",
    platforms: [.macOS(.v14), .visionOS("26.0")],
    products: [
        .library(name: "VRLinkCore", targets: ["VRLinkCore"]),
        .library(name: "VRLinkApple", targets: ["VRLinkVideoToolbox", "VRLinkMetal", "VRLinkAppleAudio", "VRLinkAppleNetwork", "VRLinkAppleFace",
                                                "VRLinkVisionTracking", "VRLinkAppleSession", "VRLinkVisionCompositor"]),
        // Kept apart: nothing else depends on it.
        .library(name: "VRLinkExperiments", targets: ["VRLinkVisionExperiments"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // Protocol, session and frame composition. No UI, graphics, audio or
        // decoder frameworks; it needs only Foundation, POSIX sockets and swift-crypto.
        .target(name: "VRLinkCore", dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
        // Platform backends, one per seam (docs/client-architecture.md).
        .target(name: "VRLinkVideoToolbox", dependencies: ["VRLinkCore"]),            // decoder
        .target(name: "VRLinkMetal", dependencies: ["VRLinkCore", "VRLinkVideoToolbox"],    // graphics, paired with that decoder's frames
                resources: [.copy("Quad.metal")]),
        .target(name: "VRLinkAppleAudio", dependencies: ["VRLinkCore"]),              // audio out
        .target(name: "VRLinkAppleNetwork"),                                          // which interfaces are wired
        .target(name: "VRLinkAppleFace", dependencies: ["VRLinkCore"]),               // face from a camera picture
        // visionOS: head, hands and controllers from ARKit, buttons and haptics
        // from GameController, pinches from spatial events. Empty elsewhere.
        .target(name: "VRLinkVisionTracking", dependencies: ["VRLinkCore"]),
        // Finding a host, pairing, and a session that can be stopped and started
        // again, with its decoder and audio; and the person's settings while the app runs.
        .target(name: "VRLinkAppleSession", dependencies: [
            "VRLinkCore", "VRLinkVideoToolbox", "VRLinkAppleAudio", "VRLinkAppleNetwork",
        ]),
        // visionOS: the stream drawn into a compositor layer. Empty elsewhere.
        .target(name: "VRLinkVisionCompositor", dependencies: [
            "VRLinkCore", "VRLinkVideoToolbox", "VRLinkMetal", "VRLinkVisionTracking", "VRLinkAppleSession",
            "VRLinkAppleNetwork",
        ]),
        // visionOS experiments: the stream drawn with RealityKit, face and gaze
        // from the Spatial Persona, and their calibrations. Empty elsewhere.
        .target(name: "VRLinkVisionExperiments", dependencies: [
            "VRLinkCore", "VRLinkVideoToolbox", "VRLinkMetal", "VRLinkAppleFace", "VRLinkVisionTracking",
            "VRLinkAppleSession", "VRLinkVisionCompositor",
        ], resources: [.copy("SBSMaterial.usda")]),
        // The macOS viewer: a window standing in for an XR runtime.
        .executableTarget(name: "OpenVRLink", dependencies: [
            "VRLinkCore", "VRLinkVideoToolbox", "VRLinkMetal", "VRLinkAppleAudio", "VRLinkAppleNetwork", "VRLinkAppleFace",
        ]),
        .testTarget(name: "VRLinkCoreTests", dependencies: ["VRLinkCore"]),
        .testTarget(name: "VRLinkVideoToolboxTests", dependencies: ["VRLinkCore", "VRLinkVideoToolbox"]),
        .testTarget(name: "VRLinkMetalTests", dependencies: ["VRLinkCore", "VRLinkVideoToolbox", "VRLinkMetal"]),
    ]
)
