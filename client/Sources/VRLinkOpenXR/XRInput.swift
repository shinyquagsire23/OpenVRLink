// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import COpenXR
import Foundation
import VRLinkCore

/// Polls head, controller, and hand tracking from an OpenXR session.
///
/// The frame loop calls `update(at:in:)` once per frame with the predicted display timestamp, and the
/// streaming session's pose callbacks read the latest cached sample from any thread.
public final class XRInput {
    /// Logical controller actions mapped to `ControllerState` fields.
    enum Control: String, CaseIterable {
        case lower, upper, menu, stickClick = "stick_click"
        case lowerTouch = "lower_touch", upperTouch = "upper_touch", triggerTouch = "trigger_touch"
        case stickTouch = "stick_touch", restTouch = "rest_touch"
        case trigger, squeeze, stick, grip, aim, haptic

        var type: XrActionType {
            switch self {
            case .trigger, .squeeze: return XR_ACTION_TYPE_FLOAT_INPUT
            case .stick: return XR_ACTION_TYPE_VECTOR2F_INPUT
            case .grip, .aim: return XR_ACTION_TYPE_POSE_INPUT
            case .haptic: return XR_ACTION_TYPE_VIBRATION_OUTPUT
            default: return XR_ACTION_TYPE_BOOLEAN_INPUT
            }
        }
    }

    /// Maps logical `Control` actions to OpenXR input paths under `/user/hand/left` and `/user/hand/right` for
    /// an interaction profile.
    struct Profile {
        var path: String
        /// OpenXR extension required to use this interaction profile, or `nil` for core OpenXR 1.0 profiles.
        var needs: String?
        var left: [Control: String], right: [Control: String]

        init(_ path: String, needs: String? = nil, both: [Control: String], left: [Control: String] = [:],
             right: [Control: String] = [:]) {
            self.path = path
            self.needs = needs
            self.left = both.merging(left) { $1 }
            self.right = both.merging(right) { $1 }
        }
    }

    private static let poses: [Control: String] = [.grip: "input/grip/pose", .aim: "input/aim/pose", .haptic: "output/haptic"]

    /// Common Oculus Touch input bindings that `ControllerState` is modeled after.
    private static let touch: [Control: String] = poses.merging([
        .stickClick: "input/thumbstick/click", .stickTouch: "input/thumbstick/touch", .stick: "input/thumbstick",
        .trigger: "input/trigger/value", .triggerTouch: "input/trigger/touch", .squeeze: "input/squeeze/value",
        .restTouch: "input/thumbrest/touch",
    ]) { $1 }
    private static let touchLeft: [Control: String] = [
        .lower: "input/x/click", .upper: "input/y/click", .lowerTouch: "input/x/touch", .upperTouch: "input/y/touch",
        .menu: "input/menu/click",
    ]
    private static let touchRight: [Control: String] = [
        .lower: "input/a/click", .upper: "input/b/click", .lowerTouch: "input/a/touch", .upperTouch: "input/b/touch",
    ]

    /// Supported OpenXR controller interaction profiles, falling back to `khr/simple_controller` for basic
    /// trigger and menu input.
    static let profiles: [Profile] = [
        Profile("/interaction_profiles/oculus/touch_controller", both: touch, left: touchLeft, right: touchRight),
        Profile("/interaction_profiles/meta/touch_controller_plus", needs: "XR_META_touch_controller_plus",
                both: touch.filter { $0.key != .restTouch }, left: touchLeft, right: touchRight),
        Profile("/interaction_profiles/bytedance/pico4_controller", needs: "XR_BD_controller_interaction",
                both: touch.filter { $0.key != .restTouch }, left: touchLeft, right: touchRight),
        Profile("/interaction_profiles/valve/index_controller", both: poses.merging([
            .lower: "input/a/click", .upper: "input/b/click", .lowerTouch: "input/a/touch", .upperTouch: "input/b/touch",
            .stickClick: "input/thumbstick/click", .stickTouch: "input/thumbstick/touch", .stick: "input/thumbstick",
            .trigger: "input/trigger/value", .triggerTouch: "input/trigger/touch", .squeeze: "input/squeeze/value",
        ]) { $1 }),
        Profile("/interaction_profiles/khr/simple_controller", both: poses.merging([
            .trigger: "input/select/click", .menu: "input/menu/click",
        ]) { $1 }),
    ]

    private let instance: XRInstance
    private let session: XrSession
    private let log: (String) -> Void
    private var actionSet: XrActionSet?
    private var actions: [Control: XrAction] = [:]
    private var sides: [XrPath] = []
    private var grips: [XrSpace?] = [nil, nil], aims: [XrSpace?] = [nil, nil]
    private var trackers: [XrHandTrackerEXT?] = [nil, nil]
    private var headSpace: XrSpace?

    private let lock = NSLock()
    private var latestHead: TrackedPose?
    private var latestHands: [HandInput?] = [nil, nil]
    private var noted: [String] = ["", ""]

    init(instance: XRInstance, session: XrSession, log: @escaping (String) -> Void) throws {
        self.instance = instance
        self.session = session
        self.log = log
        let calls = instance.calls
        sides = [try instance.path("/user/hand/left"), try instance.path("/user/hand/right")]

        var setInfo = XrActionSetCreateInfo()
        setInfo.type = XR_TYPE_ACTION_SET_CREATE_INFO
        fill(&setInfo.actionSetName, with: "stream")
        fill(&setInfo.localizedActionSetName, with: "Streaming")
        try check(calls.createActionSet(instance.handle, &setInfo, &actionSet), "xrCreateActionSet")

        for control in Control.allCases {
            var info = XrActionCreateInfo()
            info.type = XR_TYPE_ACTION_CREATE_INFO
            info.actionType = control.type
            fill(&info.actionName, with: control.rawValue)
            fill(&info.localizedActionName, with: control.rawValue.replacingOccurrences(of: "_", with: " "))
            var action: XrAction?
            try sides.withUnsafeBufferPointer { both in
                info.countSubactionPaths = UInt32(both.count)
                info.subactionPaths = both.baseAddress
                _ = try check(calls.createAction(actionSet, &info, &action), "xrCreateAction(\(control.rawValue))")
            }
            actions[control] = action
        }

        for profile in XRInput.profiles where profile.needs.map(instance.extensions.contains) ?? true {
            var bindings: [XrActionSuggestedBinding] = []
            for (hand, controls) in [("/user/hand/left/", profile.left), ("/user/hand/right/", profile.right)] {
                for (control, place) in controls {
                    guard let action = actions[control], let path = try? instance.path(hand + place) else { continue }
                    bindings.append(XrActionSuggestedBinding(action: action, binding: path))
                }
            }
            var suggestion = XrInteractionProfileSuggestedBinding()
            suggestion.type = XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING
            suggestion.interactionProfile = try instance.path(profile.path)
            let result = bindings.withUnsafeBufferPointer { all -> XrResult in
                suggestion.countSuggestedBindings = UInt32(all.count)
                suggestion.suggestedBindings = all.baseAddress
                return calls.suggestInteractionProfileBindings(instance.handle, &suggestion)
            }
            // Runtimes may reject interaction profiles they do not implement; other suggested profiles remain active.
            if result.rawValue < 0 { log("openxr: \(profile.path) not offered (\(XRFailure.name(of: result)))") }
        }

        var attach = XrSessionActionSetsAttachInfo()
        attach.type = XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO
        try withUnsafePointer(to: actionSet) { set in
            attach.countActionSets = 1
            attach.actionSets = set
            _ = try check(calls.attachSessionActionSets(session, &attach), "xrAttachSessionActionSets")
        }

        for side in Side.allCases {
            grips[side.rawValue] = try actionSpace(.grip, side)
            aims[side.rawValue] = try actionSpace(.aim, side)
        }

        var view = XrReferenceSpaceCreateInfo()
        view.type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO
        view.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW
        view.poseInReferenceSpace = .identity
        try check(calls.createReferenceSpace(session, &view, &headSpace), "xrCreateReferenceSpace(view)")

        if instance.extensions.contains("XR_EXT_hand_tracking"), let create = calls.createHandTracker {
            for side in Side.allCases {
                var info = XrHandTrackerCreateInfoEXT()
                info.type = XR_TYPE_HAND_TRACKER_CREATE_INFO_EXT
                info.hand = side == .left ? XR_HAND_LEFT_EXT : XR_HAND_RIGHT_EXT
                info.handJointSet = XR_HAND_JOINT_SET_DEFAULT_EXT
                var tracker: XrHandTrackerEXT?
                // xrCreateHandTrackerEXT fails when the connected headset does not support hand tracking.
                if create(session, &info, &tracker).rawValue >= 0 { trackers[side.rawValue] = tracker }
            }
            log("openxr: hand tracking \(trackers.contains { $0 != nil } ? "available" : "not available on this headset")")
        }
    }

    deinit {
        let calls = instance.calls
        for tracker in trackers { if let tracker { _ = calls.destroyHandTracker?(tracker) } }
        for space in grips + aims + [headSpace] { if let space { _ = calls.destroySpace(space) } }
    }

    private func actionSpace(_ control: Control, _ side: Side) throws -> XrSpace? {
        var info = XrActionSpaceCreateInfo()
        info.type = XR_TYPE_ACTION_SPACE_CREATE_INFO
        info.action = actions[control]
        info.subactionPath = sides[side.rawValue]
        info.poseInActionSpace = .identity
        var space: XrSpace?
        try check(instance.calls.createActionSpace(session, &info, &space), "xrCreateActionSpace")
        return space
    }

    /// Returns the latest head (`VIEW` space) pose for `StreamingSession.headProvider`.
    public func head() -> TrackedPose? {
        lock.lock()
        defer { lock.unlock() }
        return latestHead
    }

    /// Returns `[left, right]` inputs for `StreamingSession.handsProvider`, preferring an active controller
    /// over hand-joint tracking on each side.
    public func hands() -> [HandInput?] {
        lock.lock()
        defer { lock.unlock() }
        return latestHands
    }

    public func vibrate(_ pulse: HapticPulse) {
        guard let action = actions[.haptic] else { return }
        var target = XrHapticActionInfo()
        target.type = XR_TYPE_HAPTIC_ACTION_INFO
        target.action = action
        target.subactionPath = sides[pulse.side.rawValue]
        var vibration = XrHapticVibration()
        vibration.type = XR_TYPE_HAPTIC_VIBRATION
        vibration.duration = XrDuration(pulse.seconds * 1e9)
        vibration.frequency = pulse.frequency
        vibration.amplitude = max(0, min(1, pulse.amplitude))
        withUnsafeBytes(of: &vibration) { bytes in
            _ = instance.calls.applyHapticFeedback(session, &target, bytes.baseAddress?.assumingMemoryBound(to: XrHapticBaseHeader.self))
        }
    }

    private func locate(_ space: XrSpace?, in base: XrSpace, at time: XrTime) -> TrackedPose? {
        guard let space else { return nil }
        var velocity = XrSpaceVelocity()
        velocity.type = XR_TYPE_SPACE_VELOCITY
        var location = XrSpaceLocation()
        location.type = XR_TYPE_SPACE_LOCATION
        let result = withUnsafeMutablePointer(to: &velocity) { chained -> XrResult in
            location.next = UnsafeMutableRawPointer(chained)
            return instance.calls.locateSpace(space, base, time, &location)
        }
        guard result.rawValue >= 0 else { return nil }
        return TrackedPose(location, velocity)
    }

    private func pressed(_ control: Control, _ side: Side) -> Bool {
        var which = XrActionStateGetInfo()
        which.type = XR_TYPE_ACTION_STATE_GET_INFO
        which.action = actions[control]
        which.subactionPath = sides[side.rawValue]
        var state = XrActionStateBoolean()
        state.type = XR_TYPE_ACTION_STATE_BOOLEAN
        guard instance.calls.getActionStateBoolean(session, &which, &state).rawValue >= 0, state.isActive != 0 else { return false }
        return state.currentState != 0
    }

    private func amount(_ control: Control, _ side: Side) -> Float {
        var which = XrActionStateGetInfo()
        which.type = XR_TYPE_ACTION_STATE_GET_INFO
        which.action = actions[control]
        which.subactionPath = sides[side.rawValue]
        var state = XrActionStateFloat()
        state.type = XR_TYPE_ACTION_STATE_FLOAT
        guard instance.calls.getActionStateFloat(session, &which, &state).rawValue >= 0, state.isActive != 0 else { return 0 }
        return state.currentState
    }

    private func controller(_ side: Side, in base: XrSpace, at time: XrTime) -> ControllerState? {
        var which = XrActionStateGetInfo()
        which.type = XR_TYPE_ACTION_STATE_GET_INFO
        which.action = actions[.grip]
        which.subactionPath = sides[side.rawValue]
        var held = XrActionStatePose()
        held.type = XR_TYPE_ACTION_STATE_POSE
        guard instance.calls.getActionStatePose(session, &which, &held).rawValue >= 0, held.isActive != 0,
              let grip = locate(grips[side.rawValue], in: base, at: time)
        else { return nil }
        var state = ControllerState(grip: grip)
        state.aim = locate(aims[side.rawValue], in: base, at: time)?.pose
        state.lowerButton = pressed(.lower, side)
        state.upperButton = pressed(.upper, side)
        state.menuButton = pressed(.menu, side)
        state.stickClick = pressed(.stickClick, side)
        state.lowerButtonTouched = pressed(.lowerTouch, side)
        state.upperButtonTouched = pressed(.upperTouch, side)
        state.triggerTouched = pressed(.triggerTouch, side)
        state.stickTouched = pressed(.stickTouch, side)
        state.thumbRestTouched = pressed(.restTouch, side)
        state.trigger = amount(.trigger, side)
        state.squeeze = amount(.squeeze, side)
        which.action = actions[.stick]
        var stick = XrActionStateVector2f()
        stick.type = XR_TYPE_ACTION_STATE_VECTOR2F
        if instance.calls.getActionStateVector2f(session, &which, &stick).rawValue >= 0, stick.isActive != 0 {
            state.stickX = stick.currentState.x
            state.stickY = stick.currentState.y
        }
        return state
    }

    /// Queries the 26 `XR_EXT_hand_tracking` joints, whose order and axes match `TrackedHand`.
    private func hand(_ side: Side, in base: XrSpace, at time: XrTime) -> TrackedHand? {
        guard let tracker = trackers[side.rawValue], let locateJoints = instance.calls.locateHandJoints else { return nil }
        var which = XrHandJointsLocateInfoEXT()
        which.type = XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT
        which.baseSpace = base
        which.time = time
        var joints = [XrHandJointLocationEXT](repeating: XrHandJointLocationEXT(), count: TrackedHand.jointCount)
        var located = XrHandJointLocationsEXT()
        located.type = XR_TYPE_HAND_JOINT_LOCATIONS_EXT
        let result = joints.withUnsafeMutableBufferPointer { all -> XrResult in
            located.jointCount = UInt32(all.count)
            located.jointLocations = all.baseAddress
            return locateJoints(tracker, &which, &located)
        }
        let needed = XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT
        guard result.rawValue >= 0, located.isActive != 0, joints.allSatisfy({ $0.locationFlags & needed == needed })
        else { return nil }
        return TrackedHand(joints: joints.map { Pose($0.pose) })
    }

    /// Synchronizes OpenXR actions and samples head, controller, and hand poses at `time` in `base`.
    func update(at time: XrTime, in base: XrSpace) {
        let calls = instance.calls
        var active = XrActiveActionSet(actionSet: actionSet, subactionPath: 0)
        var sync = XrActionsSyncInfo()
        sync.type = XR_TYPE_ACTIONS_SYNC_INFO
        withUnsafePointer(to: &active) { set in
            sync.countActiveActionSets = 1
            sync.activeActionSets = set
            // Returns XR_SESSION_NOT_FOCUSED (a qualified success code) when the session is unfocused.
            _ = calls.syncActions(session, &sync)
        }
        let head = locate(headSpace, in: base, at: time)
        let hands = Side.allCases.map { side -> HandInput? in
            if let held = controller(side, in: base, at: time) { return .controller(held) }
            return hand(side, in: base, at: time).map { .hand($0) }
        }
        lock.lock()
        latestHead = head
        latestHands = hands
        lock.unlock()
    }

    /// Logs changes to the active controller interaction profile for each hand.
    func noteControllers() {
        for side in Side.allCases {
            var state = XrInteractionProfileState()
            state.type = XR_TYPE_INTERACTION_PROFILE_STATE
            guard instance.calls.getCurrentInteractionProfile(session, sides[side.rawValue], &state).rawValue >= 0 else { continue }
            let name = instance.string(state.interactionProfile)
            guard name != noted[side.rawValue] else { continue }
            noted[side.rawValue] = name
            log("openxr: \(side == .left ? "left" : "right") hand interaction profile: \(name.isEmpty ? "none" : name)")
        }
    }
}
