// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Combine
import Foundation
import VRLinkCore

/// The user's settings while the app runs: shown and changed by the
/// window, read by the display and session threads, and written to
/// `settings.json` every time one changes.
public final class SettingsStore: ObservableObject {
    @Published public var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            lock.lock()
            snapshot = settings.tidied()
            let toSave = snapshot
            lock.unlock()
            // Off the main thread: a slider changes its setting many times a second.
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

    /// The settings as they are now. Safe from any thread.
    public var current: Settings {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}
