// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Combine
import Foundation
import VRLinkCore

/// Observable wrapper around `Settings` used by the SwiftUI settings views,
/// providing thread-safe snapshots for the render and session threads and
/// persisting changes to `settings.json`.
public final class SettingsStore: ObservableObject {
    @Published public var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            lock.lock()
            snapshot = settings.tidied()
            let toSave = snapshot
            lock.unlock()
            // Write to disk on a background queue since UI sliders can update many times per second.
            saving.async { toSave.save() }
        }
    }

    private let lock = NSLock()
    private var snapshot: Settings
    private let saving = DispatchQueue(label: "settings", qos: .utility)

    public init() {
        let loaded = Settings.load()
        settings = loaded
        snapshot = loaded
    }

    /// Returns the latest validated settings snapshot. Safe to call from any thread.
    public var current: Settings {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}
