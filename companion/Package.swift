// swift-tools-version: 5.9
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

let package = Package(
    name: "OpenVRLinkCompanion",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "openvrlink-companion", targets: ["openvrlink-companion"]),
        .library(name: "driver_openvrlink", type: .dynamic, targets: ["driver_openvrlink"]),
    ],
    targets: [
        // Binary scanning, shader patching, and handshake state (no Foundation dependency).
        .target(name: "PatchCore"),
        .testTarget(name: "PatchCoreTests", dependencies: ["PatchCore"]),
        // Steam discovery, Sense controller model setup, and driver installation.
        .target(name: "CompanionKit", dependencies: ["PatchCore"]),
        .testTarget(name: "CompanionKitTests", dependencies: ["CompanionKit"]),
        .executableTarget(name: "openvrlink-companion", dependencies: ["CompanionKit", "PatchCore"]),
        // C interface declarations for OpenVR vtables, ID3DBlob, and OS calls.
        .target(name: "DriverABI"),
        // SteamVR driver loaded into vrserver alongside driver_vrlink.
        // Build with `--static-swift-stdlib` so the Swift runtime is statically linked into
        // a single shared library. (PatchCore and driver_openvrlink also avoid constructs
        // unsupported by Embedded Swift, once the Windows Swift toolchain ships embedded stdlib.)
        .target(name: "driver_openvrlink", dependencies: ["PatchCore", "DriverABI"]),
    ]
)
