// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import GameController
import VRLinkCore

/// The controller's Home button (PS on a Sense controller), which visionOS
/// keeps for itself unless both the app and the person say otherwise.
///
/// Two things have to happen for a press to reach the app. The app asks the
/// system not to act on the button (`claim`). And, on visionOS 27, the person
/// allows it: Settings > General > Game Controller > Home Button, where this
/// app's in-app action has to be "Defer to app". The app can read that choice
/// and open that page, but cannot make the choice.
///
/// Everything found is written to the log, because what a controller reports
/// here is not documented and has differed between controllers and releases.
///
/// Measured on visionOS 27 with PlayStation VR2 Sense controllers
/// (2026-11-10): they have no Home button at all as far as an app can see,
/// in the profile, the live inputs, the unmapped inputs or an extended
/// gamepad view (it has none), and that does not
/// change when the person sets "Defer to app". Pressing PS produced no input
/// of any name, while Create/Options ("Button Menu") and the face buttons
/// did. So for those controllers this class finds nothing to deliver; it is
/// here for controllers that do report the button.
public final class HomeButton: ObservableObject {
    public init() {}

    public enum Delivery: String {
        case unknown = "unknown"
        case systemKeepsIt = "the system keeps it"
        case reachesApp = "it reaches this app"
    }
    /// What the person's setting says, as far as it can be read.
    @Published public private(set) var delivery: Delivery = .unknown

    private var manager: AnyObject?
    /// The controllers asked about so far, to ask again when the setting changes.
    private var claimed: [(controller: GCController, side: Side)] = []
    private var updates: Task<Void, Never>?

    /// Ask for the Home button of a controller, and say what it has.
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

    /// Read the person's setting, and keep reading it when it changes.
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
            // What the controllers report may change with the setting: ask them again.
            for entry in claimed where GCController.controllers().contains(where: { $0 === entry.controller }) {
                claim(entry.controller, side: entry.side)
            }
        } catch {
            // It can only be read with a controller connected; the next controller tries again.
            Log.note("home button: the setting could not be read: \(error)")
            manager = nil
            updates?.cancel()
            delivery = .unknown
        }
    }

    /// Open the Settings page where the person can let the button through.
    @MainActor public func openSettings() {
        guard #available(visionOS 27.0, *), let settings = manager as? GCControllerHomeButtonSettingsManager else { return }
        do {
            try settings.openControllerHomeButtonSettings(for: .customizeInAppAction)
        } catch {
            Log.note("home button: could not open its settings: \(error)")
        }
    }

    /// Whether the Home button is down.
    public static func isPressed(_ controller: GCController) -> Bool {
        controller.physicalInputProfile.buttons[GCInputButtonHome]?.isPressed ?? false
    }
}
#endif
