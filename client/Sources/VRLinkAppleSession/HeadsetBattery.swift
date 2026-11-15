// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import VRLinkCore
#if canImport(UIKit)
import UIKit
#endif

/// Tracks headset battery level and charging state for reporting to the host.
///
/// `UIDevice` battery properties must be read on the main thread, while the
/// streaming session polls from its own thread, so we cache updates from UIKit
/// battery notifications behind a lock.
public final class HeadsetBattery: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: PowerState?

    /// Latest battery reading, or nil when unavailable (on macOS or before the initial read).
    public var state: PowerState? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    public init() {
        #if canImport(UIKit)
        DispatchQueue.main.async { [self] in
            UIDevice.current.isBatteryMonitoringEnabled = true
            for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.read() }
                }
            }
            read()
        }
        #endif
    }

    #if canImport(UIKit)
    @MainActor private func read() {
        let device = UIDevice.current
        // A level below zero means "unknown".
        let reading = device.batteryLevel >= 0
            ? PowerState(level: device.batteryLevel, charging: device.batteryState == .charging || device.batteryState == .full)
            : nil
        lock.lock()
        latest = reading
        lock.unlock()
    }
    #endif
}
