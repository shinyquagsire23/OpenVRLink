// swift-tools-version: 5.9
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

/// Windows linker flags for `openvrlink-companion`. Builds a GUI subsystem binary (so
/// double-clicking it does not open a console window) using the standard `main` entry point,
/// and embeds a manifest enabling themed common controls. When built with
/// `--static-swift-stdlib`, the executable only depends on Windows system DLLs plus
/// `MSVCP140.dll` and `VCRUNTIME140.dll`, which Steam installs alongside SteamVR.
let windowsProgramFlags = [
    "/SUBSYSTEM:WINDOWS", "/ENTRY:mainCRTStartup",
    "/MANIFEST:EMBED",
    "/MANIFESTDEPENDENCY:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'",
].flatMap { ["-Xlinker", $0] }

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
        // version.json from the repository root, compiled in as text.
        .target(name: "RepoVersion"),
        // The Play For Dream controller render models, compiled in as bytes.
        .target(name: "ControllerModels", exclude: ["pfd"]),
        .target(name: "CompanionKit", dependencies: ["PatchCore", "RepoVersion", "ControllerModels"]),
        .testTarget(name: "CompanionKitTests", dependencies: ["CompanionKit"]),
        // C target exposing Win32 GUI, WinHTTP, and resource APIs on Windows (empty on other platforms).
        .target(name: "WinAPI"),
        // Installer and diagnostic tool; opens a GUI window on Windows when launched without arguments, or runs as a CLI tool.
        .executableTarget(
            name: "openvrlink-companion", dependencies: ["CompanionKit", "PatchCore", "WinAPI"],
            linkerSettings: [
                .linkedLibrary("winhttp", .when(platforms: [.windows])),
                .linkedLibrary("comctl32", .when(platforms: [.windows])),
                .linkedLibrary("gdi32", .when(platforms: [.windows])),
                .unsafeFlags(windowsProgramFlags, .when(platforms: [.windows])),
            ]),
        // C interface declarations for OpenVR vtables, ID3DBlob, and OS calls.
        .target(name: "DriverABI"),
        // SteamVR driver loaded into vrserver alongside driver_vrlink.
        // Build with `--static-swift-stdlib` so the Swift runtime is statically linked into
        // a single shared library. (PatchCore and driver_openvrlink also avoid constructs
        // unsupported by Embedded Swift, once the Windows Swift toolchain ships embedded stdlib.)
        .target(name: "driver_openvrlink", dependencies: ["PatchCore", "DriverABI"]),
    ]
)
