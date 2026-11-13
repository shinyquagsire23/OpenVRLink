// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Which system this is running on, for the host to be told when a
/// session is asked for.
public enum SystemVersion {
    /// As in "visionOS 27.0.1".
    public static var named: String {
        #if os(visionOS)
        let name = "visionOS"
        #elseif os(macOS)
        let name = "macOS"
        #elseif os(tvOS)
        let name = "tvOS"
        #else
        let name = "iOS"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var numbers = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 { numbers += ".\(version.patchVersion)" }
        return name + " " + numbers
    }
}
