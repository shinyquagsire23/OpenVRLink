// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
@testable import PatchCore

/// Reads optional paths to local `driver_vrlink` binaries and shaders from environment
/// variables (tests skip when unset because SteamVR files are not redistributed):
///
/// - `OVRL_TEST_VRLINK_DLL`, `OVRL_TEST_VRLINK_SO`: unstripped Windows/Linux `driver_vrlink` binaries
/// - `OVRL_TEST_VRLINK_SO_STRIPPED`: stripped Linux `driver_vrlink.so` (October 2026+)
/// - `OVRL_TEST_VRLINK_SHADERS`: Linux `driver_vrlink` `resources/shaders` folder (July 2026)
/// - `OVRL_TEST_VRLINK_SHADERS_STRIPPED`: Linux `driver_vrlink` `resources/shaders/vulkan` folder (October 2026+)
/// - `OVRL_TEST_VRLINK_FXO`: Windows `driver_vrlink` `resources/shaders/d3d11` folder
/// - `OVRL_TEST_FXO_DIR`: directory of `.fxo` files for DXBC container round-trip tests
/// - `OVRL_TEST_OUT`: optional output directory for writing patched shaders to validate externally
enum RealFiles {
    static func path(_ variable: String) -> URL? {
        ProcessInfo.processInfo.environment[variable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    static func bytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }

    static func save(_ bytes: [UInt8], as name: String) throws {
        guard let folder = path("OVRL_TEST_OUT") else { return }
        try Data(bytes).write(to: folder.appendingPathComponent(name))
    }
}

extension Array where Element == UInt8 {
    /// Calls `body` with the array's bytes as a `ByteView`.
    func view<T>(_ body: (ByteView) throws -> T) rethrows -> T { try withUnsafeBufferPointer(body) }
}
