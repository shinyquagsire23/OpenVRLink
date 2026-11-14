// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import Foundation
import VRLinkAppleSession
import VRLinkCore
import VRLinkVisionTracking

/// Everything a stream is asked for with, and fed from, that has to exist
/// before its immersive space does: the host is connected to first, and
/// the space is opened only when there is a picture to show in it, so
/// that whatever the wearer was in until then (an environment, say) stays.
public final class StreamInputs {
    public let connection: Connection
    public let head: HeadTracking
    public let controllers: ControllerTracking
    public let hands: HandJoints
    public let settings: SettingsStore
    public let measured: MeasuredDisplay
    /// Pinches made at a distance; whichever display is open reports them here.
    public let pinches = PinchRays()
    /// The gaze as a compositor layer's rate map shows it.
    let gaze = GazeFromFoveation()

    public init(connection: Connection, head: HeadTracking, controllers: ControllerTracking, hands: HandJoints,
                settings: SettingsStore, measured: MeasuredDisplay) {
        self.connection = connection
        self.head = head
        self.controllers = controllers
        self.hands = hands
        self.settings = settings
        self.measured = measured
    }

    /// The rates an Apple Vision Pro's displays run at, in Hz (120 only on
    /// the M5 model). An app cannot find out which its headset has, so the
    /// host is offered them all; a rate the display will not go to is
    /// withdrawn by the session when it is tried.
    static let displayRates: [Float] = [90, 96, 100, 120]

    /// The display as last measured, its frusta scaled as the person
    /// chose (the field-of-view setting): more or less than the display
    /// shows. The picture is still drawn where the host rendered it: a wider
    /// one runs off the edge of the display, a narrower one leaves a margin.
    public func profileForHost() -> DeviceProfile? {
        guard var profile = measured.value?.profile else { return nil }
        let chosen = settings.current
        profile.senseControllerModels = chosen.senseControllerModels
        // Both renderers can say where the eyes look: one from the display's
        // rate map, the other from the Persona's eyes.
        profile.tracksGaze = true
        profile.otherRefreshRates = StreamInputs.displayRates
        profile.eyeFrusta = profile.eyeFrusta.map {
            $0.scaled(horizontal: chosen.fovScaleHorizontal, vertical: chosen.fovScaleVertical)
        }
        return profile
    }

    /// Each hand as the host should have it now: a hand holding a tracked
    /// controller is that controller; otherwise it is itself.
    public func handsNow() -> [HandInput?] {
        let chosen = settings.current
        let held = controllers.states(clackSwitching: chosen.clackSwitchesToHands, head: head.latestHead())
        let bare = hands.hands()
        return Side.allCases.map { side in
            if let controller = held[side.rawValue] { return .controller(controller) }
            guard var hand = bare[side.rawValue] else { return nil }
            // The system's pinches, aimed by the eyes, in place of ours aimed by the arm.
            if chosen.gazePinchRays { hand.systemPinch = pinches.pinch(side) }
            return .hand(hand)
        }
    }
}
#endif
