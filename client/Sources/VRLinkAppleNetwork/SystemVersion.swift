// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import VRLinkCore

/// Platform, device model, and client version strings reported to the host
/// during pairing and session setup.
public enum SystemVersion {
    /// Operating system name, e.g. `"visionOS"`.
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

    /// Hardware model string sent to the host during pairing.
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

    /// Client name and bundle version, e.g. `"OpenVRLink 0.1.0-2"`, or just
    /// `"OpenVRLink"` when running outside an app bundle (such as the macOS CLI viewer).
    public static var client: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String,
              let build = info?["CFBundleVersion"] as? String
        else { return product }
        return product + " " + version + "-" + build
    }

    /// OS name and version string, e.g. `"visionOS 27.0.1"`.
    public static var named: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var numbers = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 { numbers += ".\(version.patchVersion)" }
        return name + " " + numbers
    }

    /// Builds a `DeviceIdentity` for this Apple device using `name` as the user-assigned device name.
    public static func device(named name: String) -> DeviceIdentity {
        DeviceIdentity(name: name, model: model, systemName: self.name, systemVersion: named, clientVersion: client)
    }
}
