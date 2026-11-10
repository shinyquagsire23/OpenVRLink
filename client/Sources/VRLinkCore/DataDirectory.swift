// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Where the client keeps its settings and pairing secrets: one folder named
/// OpenVRLink in the platform's per-user data location.
///
/// | platform | folder |
/// |---|---|
/// | Linux, Android | `$XDG_DATA_HOME/OpenVRLink`, or `~/.local/share/OpenVRLink` |
/// | Windows | `%LOCALAPPDATA%\OpenVRLink` |
/// | macOS | `~/Library/Application Support/OpenVRLink` |
/// | iOS, visionOS | the app's Documents folder, `OpenVRLink` inside it |
///
/// Everything goes in the data home; `XDG_CONFIG_HOME` is not used.
public enum DataDirectory {
    public static let name = "OpenVRLink"

    public static var url: URL {
        let files = FileManager.default
        #if os(macOS)
        let base = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        #elseif os(iOS) || os(visionOS) || os(tvOS)
        let base = files.urls(for: .documentDirectory, in: .userDomainMask).first ?? files.temporaryDirectory
        #elseif os(Windows)
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0) }
            ?? files.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local")
        #else
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? files.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        #endif
        return base.appendingPathComponent(name)
    }
}
