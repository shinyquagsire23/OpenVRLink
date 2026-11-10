// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import VRLinkCore
#if canImport(UIKit)
import UIKit
#endif

/// The battery of the device the app runs on, for the host to show.
///
/// UIKit only answers on the main thread and the session asks from its own,
/// so the state is kept here and brought up to date when UIKit says it changed.
public final class HeadsetBattery: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: PowerState?

    /// Nil where the system does not say (macOS, or before the first reading).
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
