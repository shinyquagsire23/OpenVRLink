// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Which system this is running on and which build of the client this
/// is, for the host to be told.
public enum SystemVersion {
    /// As in "visionOS".
    public static var name: String {
        #if os(visionOS)
        return "visionOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #else
        return "iOS"
        #endif
    }

    private static let product = "OpenVRLink"

    /// What kind of device this is, as a host is told when pairing.
    /// TODO: an Android shell has the real model to give (Build.MODEL).
    public static var model: String {
        #if os(visionOS)
        return "Apple Vision Pro"
        #elseif os(macOS)
        return "Mac"
        #elseif os(tvOS)
        return "Apple TV"
        #else
        return "iPhone"
        #endif
    }

    /// The client and its bundle's version and build, as in "OpenVRLink
    /// 0.1.0-2"; only "OpenVRLink" where it is not run from an app bundle
    /// (the Mac viewer).
    public static var client: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String,
              let build = info?["CFBundleVersion"] as? String
        else { return product }
        return product + " " + version + "-" + build
    }

    /// As in "visionOS 27.0.1".
    public static var named: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var numbers = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 { numbers += ".\(version.patchVersion)" }
        return name + " " + numbers
    }
}
