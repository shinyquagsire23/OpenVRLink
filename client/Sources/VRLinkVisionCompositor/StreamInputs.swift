// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import Foundation
import VRLinkAppleSession
import VRLinkCore
import VRLinkVisionTracking

/// Shared tracking, configuration, and connection state created before opening
/// an immersive space. The client connects to the host first and opens the
/// immersive space only once video frames arrive, keeping the user's current
/// visionOS environment visible while connecting.
public final class StreamInputs {
    public let connection: Connection
    public let head: HeadTracking
    public let controllers: ControllerTracking
    public let hands: HandJoints
    public let settings: SettingsStore
    public let measured: MeasuredDisplay
    /// Tracks spatial pinch events forwarded from whichever immersive display is active.
    public let pinches = PinchRays()
    /// Gaze estimator driven by the compositor layer's rasterization rate map.
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

    /// Refresh rates supported by Apple Vision Pro displays, in Hz (120 Hz is
    /// available only on the M5 model). Because visionOS provides no API to
    /// query which rates the current hardware supports, we advertise all of
    /// them to the host and let the session drop any rate the display does not adopt.
    static let displayRates: [Float] = [90, 96, 100, 120]

    /// Builds the `DeviceProfile` to send to the host from the latest display
    /// measurement, scaling eye frusta by the user's FOV settings. Quads are
    /// still rendered at the exact frustum angles the host drew: scales above
    /// 1.0 extend past the edges of the display, while scales below 1.0 leave margins.
    public func profileForHost() -> DeviceProfile? {
        guard var profile = measured.value?.profile else { return nil }
        let chosen = settings.current
        profile.senseControllerModels = chosen.senseControllerModels
        // Both visionOS renderers use `QuadRenderer`, which supports per-frame host chroma keying and
        // transparent passthrough.
        profile.hostChromaKey = true
        // Both renderers provide gaze input: CompositorDisplay reads the
        // rasterization rate map, and the RealityKit renderer uses Persona eye tracking.
        profile.tracksGaze = true
        profile.otherRefreshRates = StreamInputs.displayRates
        profile.eyeFrusta = profile.eyeFrusta.map {
            $0.scaled(horizontal: chosen.fovScaleHorizontal, vertical: chosen.fovScaleVertical)
        }
        return profile
    }

    private let handsLock = NSLock()
    private var lastHandPositions: [Vec3] = []

    /// Returns the world-space hand or controller positions recorded by the most recent
    /// `handsNow()` call so other callers can read them without polling the trackers again.
    public func handPositions() -> [Vec3] {
        handsLock.lock()
        defer { handsLock.unlock() }
        return lastHandPositions
    }

    /// Returns the current input state for each side, using a tracked controller when
    /// one is held and falling back to optical hand tracking otherwise.
    public func handsNow() -> [HandInput?] {
        let chosen = settings.current
        let held = controllers.states(clackSwitching: chosen.clackSwitchesToHands, head: head.latestHead())
        let bare = hands.hands()
        let hands = Side.allCases.map { side -> HandInput? in
            if let controller = held[side.rawValue] { return .controller(controller) }
            guard var hand = bare[side.rawValue] else { return nil }
            // Override wrist/arm aim rays with visionOS's gaze-targeted spatial pinch rays when enabled.
            if chosen.gazePinchRays { hand.systemPinch = pinches.pinch(side) }
            return .hand(hand)
        }
        let positions = hands.compactMap { hand -> Vec3? in
            switch hand {
            case .controller(let controller): return controller.grip.pose.position
            case .hand(let tracked): return tracked.joints.first?.position
            case nil: return nil
            }
        }
        handsLock.lock()
        lastHandPositions = positions
        handsLock.unlock()
        return hands
    }
}
#endif
