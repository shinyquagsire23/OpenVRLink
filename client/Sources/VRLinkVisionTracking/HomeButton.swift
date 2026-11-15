// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import GameController
import VRLinkCore

/// Claims and monitors the controller Home button (the PS button on a Sense
/// controller), which visionOS intercepts unless configured otherwise by both
/// the app and the user.
///
/// Delivering Home button presses to the app requires two steps: the app must
/// disable the preferred system gesture on the button (`claim`), and on
/// visionOS 27 the user must set Settings > General > Game Controller > Home
/// Button to "Defer to app" for this app. The app can read that setting and
/// deep-link to the Settings page, but cannot change the setting itself.
///
/// Button discovery details are logged because controller button reporting is
/// undocumented and varies across controller models and OS releases.
///
/// Tested on visionOS 27 with PlayStation VR2 Sense controllers (2026-11-10):
/// Sense controllers do not expose a Home button in `physicalInputProfile`,
/// live inputs, unmapped inputs, or `extendedGamepad` (which is `nil`), even
/// when the user selects "Defer to app". Pressing PS generates no input event
/// under any name, whereas Create/Options (`"Button Menu"`) and face buttons
/// work normally. This class is therefore a no-op for Sense controllers,
/// retained for spatial or standard controllers that do expose `Button Home`.
public final class HomeButton: ObservableObject {
    public init() {}

    public enum Delivery: String {
        case unknown = "unknown"
        case systemKeepsIt = "the system keeps it"
        case reachesApp = "it reaches this app"
    }
    /// Current state of the user's Home button routing setting, if readable.
    @Published public private(set) var delivery: Delivery = .unknown

    private var manager: AnyObject?
    /// Connected controllers already inspected, retained so they can be re-queried if settings change.
    private var claimed: [(controller: GCController, side: Side)] = []
    private var updates: Task<Void, Never>?

    /// Requests control of `controller`'s Home button and logs its available system/menu buttons.
    public func claim(_ controller: GCController, side: Side) {
        if !claimed.contains(where: { $0.controller === controller }) { claimed.append((controller, side)) }
        let profile = controller.physicalInputProfile
        var report: [String] = []
        for name in [GCInputButtonHome, GCInputButtonMenu, GCInputButtonOptions, GCInputButtonShare] {
            guard let button = profile.buttons[name] else {
                report.append("\(name): absent")
                continue
            }
            var state = "present"
            if name == GCInputButtonHome {
                button.preferredSystemGestureState = .disabled
                state = button.preferredSystemGestureState == .disabled ? "claimed" : "claim refused"
            }
            report.append("\(name): \(state)\(button.isBoundToSystemGesture ? ", bound to a system gesture" : "")")
        }
        Log.note("home button: \(side) controller: " + report.joined(separator: "; "))
        Log.note("home button: \(side) controller's buttons, by name: " + profile.buttons.keys.sorted().joined(separator: ", "))
        Task { @MainActor in self.watchSetting() }
    }

    /// Reads the user's Home button setting and subscribes to updates.
    @MainActor private func watchSetting() {
        guard #available(visionOS 27.0, *), manager == nil else { return }
        let settings = GCControllerHomeButtonSettingsManager()
        manager = settings
        read(settings)
        updates = Task { @MainActor [weak self] in
            for await _ in settings.settingsUpdates { self?.read(settings) }
        }
    }

    @available(visionOS 27.0, *)
    @MainActor private func read(_ settings: GCControllerHomeButtonSettingsManager) {
        do {
            let (action, _) = try settings.controllerHomeButtonInAppAction
            let now: Delivery = action == .defer ? .reachesApp : .systemKeepsIt
            guard now != delivery else { return }
            delivery = now
            Log.note("home button: the setting says \(delivery.rawValue)")
            // Re-claim and re-log connected controllers in case exposed buttons changed with the setting.
            for entry in claimed where GCController.controllers().contains(where: { $0 === entry.controller }) {
                claim(entry.controller, side: entry.side)
            }
        } catch {
            // Reading fails when no controller is connected; reset so the next controller connection retries.
            Log.note("home button: the setting could not be read: \(error)")
            manager = nil
            updates?.cancel()
            delivery = .unknown
        }
    }

    /// Opens the system Settings page where the user can defer the Home button to this app.
    @MainActor public func openSettings() {
        guard #available(visionOS 27.0, *), let settings = manager as? GCControllerHomeButtonSettingsManager else { return }
        do {
            try settings.openControllerHomeButtonSettings(for: .customizeInAppAction)
        } catch {
            Log.note("home button: could not open its settings: \(error)")
        }
    }

    /// Returns whether `controller`'s Home button is currently pressed.
    public static func isPressed(_ controller: GCController) -> Bool {
        controller.physicalInputProfile.buttons[GCInputButtonHome]?.isPressed ?? false
    }
}
#endif
