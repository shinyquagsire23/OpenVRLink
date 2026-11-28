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
        /// Aim ray and press strength used to interact with an in-headset panel (controller aim + trigger, or
        /// hand aim + pinch). Kept separate from `aim` and `trigger` so binding `XR_EXT_hand_interaction` does
        /// not report a tracked hand as a controller to the host.
        case point, press

        var type: XrActionType {
            switch self {
            case .trigger, .squeeze, .press: return XR_ACTION_TYPE_FLOAT_INPUT
            case .stick: return XR_ACTION_TYPE_VECTOR2F_INPUT
            case .grip, .aim, .point: return XR_ACTION_TYPE_POSE_INPUT
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
        .restTouch: "input/thumbrest/touch", .point: "input/aim/pose", .press: "input/trigger/value",
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
        Profile("/interaction_profiles/khr/simple_controller", both: poses.merging([
            .trigger: "input/select/click", .menu: "input/menu/click", .point: "input/aim/pose", .press: "input/select/click",
        ]) { $1 }),
        Profile("/interaction_profiles/oculus/touch_controller", both: touch, left: touchLeft, right: touchRight),
        Profile("/interaction_profiles/meta/touch_controller_plus", needs: "XR_META_touch_controller_plus",
                both: touch.filter { $0.key != .restTouch }, left: touchLeft, right: touchRight),
        Profile("/interaction_profiles/facebook/touch_controller_pro", needs: "XR_FB_touch_controller_pro",
                both: touch, left: touchLeft, right: touchRight),
        Profile("/interaction_profiles/bytedance/pico4_controller", needs: "XR_BD_controller_interaction",
                both: touch.filter { $0.key != .restTouch }, left: touchLeft, right: touchRight),
        Profile("/interaction_profiles/bytedance/pico_neo3_controller", needs: "XR_BD_controller_interaction",
                both: touch.filter { $0.key != .restTouch }, left: touchLeft, right: touchRight),
        // Bind button clicks and analog values only; touch paths require a newer revision of XR_HTC_vive_focus3_controller_interaction.
        Profile("/interaction_profiles/htc/vive_focus3_controller", needs: "XR_HTC_vive_focus3_controller_interaction", both: poses.merging([
            .stickClick: "input/thumbstick/click", .stick: "input/thumbstick",
            .trigger: "input/trigger/value", .squeeze: "input/squeeze/value",
            .point: "input/aim/pose", .press: "input/trigger/value",
        ]) { $1 }, left: [.lower: "input/x/click", .upper: "input/y/click", .menu: "input/menu/click"],
                right: [.lower: "input/a/click", .upper: "input/b/click"]),
        Profile("/interaction_profiles/valve/index_controller", both: poses.merging([
            .lower: "input/a/click", .upper: "input/b/click", .lowerTouch: "input/a/touch", .upperTouch: "input/b/touch",
            .stickClick: "input/thumbstick/click", .stickTouch: "input/thumbstick/touch", .stick: "input/thumbstick",
            .trigger: "input/trigger/value", .triggerTouch: "input/trigger/touch", .squeeze: "input/squeeze/value",
            .point: "input/aim/pose", .press: "input/trigger/value",
        ]) { $1 }),
        // Bind hand aim and pinch only to panel pointer actions (omitting grip so tracked hand joints still stream).
        Profile("/interaction_profiles/ext/hand_interaction_ext", needs: "XR_EXT_hand_interaction", both: [
            .point: "input/aim/pose", .press: "input/pinch_ext/value",
        ]),
        // Suggest /interaction_profiles/yvr/touch_controller last: YVR and Play For Dream runtimes accept every
        // suggested profile and activate whichever was suggested last, so placing khr/simple_controller last
        // binds select to the A button and leaves the trigger unbound.
        Profile("/interaction_profiles/yvr/touch_controller", both: poses.merging([
            .stickClick: "input/thumbstick/click", .stickTouch: "input/thumbstick/touch", .stick: "input/thumbstick",
            .trigger: "input/trigger/value", .triggerTouch: "input/trigger/touch", .squeeze: "input/squeeze/click",
            .point: "input/aim/pose", .press: "input/trigger/value",
        ]) { $1 }, left: touchLeft, right: touchRight),
    ]

    /// Maps OpenXR interaction profile paths to `ControllerModel` values (unlisted profiles default to `.touch`).
    static let models: [String: ControllerModel] = [
        "/interaction_profiles/oculus/touch_controller": .touch,
        "/interaction_profiles/facebook/touch_controller_pro": .touchPro,
        "/interaction_profiles/meta/touch_controller_plus": .touchPlus,
        "/interaction_profiles/bytedance/pico_neo3_controller": .picoNeo3,
        "/interaction_profiles/bytedance/pico4_controller": .pico4,
        "/interaction_profiles/htc/vive_focus3_controller": .viveFocus3,
    ]

    /// Polls a platform system button not exposed through OpenXR (such as Android's back button) and maps it to
    /// the left controller menu button or left-hand menu gesture.
    public var systemButton: (() -> Bool)?

    /// Per-hand local grip pose offsets (`[left, right]`) used to align the headset's controller grip with Quest
    /// Touch (`HeadsetQuirks.gripOffset`). Configured before streaming starts.
    public var gripOffsets: [Pose]?

    /// Derive head or controller velocities from finite differences between two predicted poses instead of
    /// using the runtime's reported velocity vectors (`HeadsetQuirks.headVelocityFromPoses`). Configured before
    /// streaming starts.
    public var headVelocityFromPoses = false, controllerVelocityFromPoses = false
    /// Prediction delta used when computing finite-difference velocities.
    private static let velocitySpan: XrDuration = 20_000_000

    /// Gaze fixation point in head space (+X right, +Y up, +Z back, in meters), or `nil` when eye gaze is
    /// untracked. Thread-safe.
    public func gaze() -> Vec3? {
        lock.lock()
        defer { lock.unlock() }
        return latestGaze
    }

    private let instance: XRInstance
    private let session: XrSession
    private let log: (String) -> Void
    private var actionSet: XrActionSet?
    private var actions: [Control: XrAction] = [:]
    private var sides: [XrPath] = []
    private var grips: [XrSpace?] = [nil, nil], aims: [XrSpace?] = [nil, nil], points: [XrSpace?] = [nil, nil]
    private var trackers: [XrHandTrackerEXT?] = [nil, nil]
    private var headSpace: XrSpace?
    /// Eye gaze pose action and action space when `XR_EXT_eye_gaze_interaction` is active.
    private var gazeAction: XrAction?
    private var gazeSpace: XrSpace?
    private var latestGaze: Vec3?
    private var gazeNoted = false
    /// Synthetic fixation distance in meters along the gaze ray, since `XR_EXT_eye_gaze_interaction` reports
    /// direction without convergence depth.
    private static let gazeDistance: Float = 10

    /// Whether eye gaze tracking is available on this session (on Android XR, requires `EYE_TRACKING_FINE`
    /// granted before instance creation).
    public var tracksGaze: Bool { gazeAction != nil }
    /// Whether to sample eye gaze during `update(at:in:)`. When false, `gaze()` returns `nil`. Thread-safe.
    public var samplesGaze: Bool {
        get { lock.lock(); defer { lock.unlock() }; return gazeWanted }
        set { lock.lock(); gazeWanted = newValue; lock.unlock() }
    }
    private var gazeWanted = true

    private let lock = NSLock()
    private var latestHead: TrackedPose?
    private var latestHands: [HandInput?] = [nil, nil]
    private var latestPointers: [Pointer?] = [nil, nil]

    /// Pointer ray and analog press value (`0` to `1`) for interacting with a panel.
    public struct Pointer {
        public var ray: Pose
        public var press: Float
    }
    private var noted: [String] = ["", ""]
    /// Cached mapping from resolved OpenXR interaction profile `XrPath` handles to `ControllerModel`. Accessed only from `update(at:in:)`.
    private var modelsByPath: [XrPath: ControllerModel] = [:]
    /// Joint-based pointer estimators used when the runtime provides no aim action pose for bare hands. Accessed only from `update(at:in:)`.
    private var handPointers = [HandPointer(), HandPointer()]
    private var pointsFromJoints = [false, false]
    private var gripDescribed = [false, false]

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

        if instance.extensions.contains("XR_EXT_eye_gaze_interaction") {
            var info = XrActionCreateInfo()
            info.type = XR_TYPE_ACTION_CREATE_INFO
            info.actionType = XR_ACTION_TYPE_POSE_INPUT
            fill(&info.actionName, with: "gaze")
            fill(&info.localizedActionName, with: "Eye gaze")
            var action: XrAction?
            if calls.createAction(actionSet, &info, &action).rawValue >= 0, let action,
               let path = try? instance.path("/user/eyes_ext/input/gaze_ext/pose"),
               let profile = try? instance.path("/interaction_profiles/ext/eye_gaze_interaction") {
                var binding = XrActionSuggestedBinding(action: action, binding: path)
                var suggestion = XrInteractionProfileSuggestedBinding()
                suggestion.type = XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING
                suggestion.interactionProfile = profile
                suggestion.countSuggestedBindings = 1
                let result = withUnsafePointer(to: &binding) { one -> XrResult in
                    suggestion.suggestedBindings = one
                    return calls.suggestInteractionProfileBindings(instance.handle, &suggestion)
                }
                if result.rawValue >= 0 {
                    gazeAction = action
                } else {
                    log("openxr: eye gaze not offered (\(XRFailure.name(of: result)))")
                }
            }
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
            points[side.rawValue] = try actionSpace(.point, side)
        }

        if let gazeAction {
            var info = XrActionSpaceCreateInfo()
            info.type = XR_TYPE_ACTION_SPACE_CREATE_INFO
            info.action = gazeAction
            info.poseInActionSpace = .identity
            if calls.createActionSpace(session, &info, &gazeSpace).rawValue < 0 { self.gazeAction = nil }
        }
        log("openxr: eye gaze \(gazeAction != nil ? "available" : "not available")")

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
        for space in grips + aims + points + [headSpace, gazeSpace] { if let space { _ = calls.destroySpace(space) } }
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

    /// Returns `[left, right]` pointer rays in tracking space, or `nil` for inactive hands/controllers.
    public func pointers() -> [Pointer?] {
        lock.lock()
        defer { lock.unlock() }
        return latestPointers
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

    /// - Parameter fromPoses: When true, computes linear and angular velocity from finite differences between
    ///   `time` and `time + velocitySpan` instead of using the runtime's reported velocity vectors.
    private func locate(_ space: XrSpace?, in base: XrSpace, at time: XrTime, velocityFromPoses fromPoses: Bool) -> TrackedPose? {
        guard var now = locate(space, in: base, at: time) else { return nil }
        guard fromPoses, let later = locate(space, in: base, at: time + XRInput.velocitySpan)?.pose else { return now }
        let seconds = Float(XRInput.velocitySpan) / 1e9
        now.linearVelocity = (later.position - now.pose.position) * (1 / seconds)
        // Relative rotation from `a` to `b` expressed as a base-space rotation vector divided by `seconds`.
        let a = now.pose.quaternion, b = later.quaternion
        var turn = [b[0] * a[0] + b[1] * a[1] + b[2] * a[2] + b[3] * a[3],
                    -b[0] * a[1] + b[1] * a[0] - b[2] * a[3] + b[3] * a[2],
                    -b[0] * a[2] + b[1] * a[3] + b[2] * a[0] - b[3] * a[1],
                    -b[0] * a[3] - b[1] * a[2] + b[2] * a[1] + b[3] * a[0]]
        if turn[0] < 0 { turn = turn.map { -$0 } }
        let axis = Vec3(turn[1], turn[2], turn[3]), size = axis.dot(axis).squareRoot()
        let spin = size > 1e-6 ? axis * (2 * atan2(size, turn[0]) / size / seconds) : Vec3(0, 0, 0)
        now.angularVelocity = Vec3(spin.dot(now.pose.right), spin.dot(now.pose.up), -spin.dot(now.pose.forward))
        return now
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
              let grip = locate(grips[side.rawValue], in: base, at: time, velocityFromPoses: controllerVelocityFromPoses)
        else { return nil }
        // Query xrGetCurrentInteractionProfile directly because the host caches the first controller static
        // properties it receives, and XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED can arrive after the first pose.
        var current = XrInteractionProfileState()
        current.type = XR_TYPE_INTERACTION_PROFILE_STATE
        var model = ControllerModel.touch
        if instance.calls.getCurrentInteractionProfile(session, sides[side.rawValue], &current).rawValue >= 0 {
            if let known = modelsByPath[current.interactionProfile] {
                model = known
            } else {
                model = XRInput.models[instance.string(current.interactionProfile)] ?? .touch
                modelsByPath[current.interactionProfile] = model
            }
        }
        // Apply HeadsetQuirks.gripOffset only when reporting a Quest Touch controller; native controller
        // profiles use vrlink's per-controller grip offset directly.
        var state = ControllerState(grip: model.isTouch ? gripOffsets.map { grip.placing($0[side.rawValue]) } ?? grip : grip)
        state.model = model
        state.aim = locate(aims[side.rawValue], in: base, at: time)?.pose
        // Log the controller's aim-to-grip offset once per hand (runtimes differ in grip pitch; Quest Touch aims
        // ~46 deg downward relative to the grip).
        if !gripDescribed[side.rawValue], let aim = state.aim {
            gripDescribed[side.rawValue] = true
            let from = grip.pose, along = aim.forward, apart = aim.position - from.position
            let pitch = atan2(along.dot(from.up), along.dot(from.forward)) * 180 / .pi
            let yaw = atan2(along.dot(from.right), along.dot(from.forward)) * 180 / .pi
            log(String(format: "openxr: %@ controller's aim is pitched %.1f and turned %.1f degrees from its grip, and %.3f right, %.3f up, %.3f ahead of it (m)",
                       side == .left ? "left" : "right", pitch, yaw, apart.dot(from.right), apart.dot(from.up), apart.dot(from.forward)))
        }
        state.lowerButton = pressed(.lower, side)
        state.upperButton = pressed(.upper, side)
        state.menuButton = pressed(.menu, side) || (side == .left && systemButton?() == true)
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
        // Chain XrHandTrackingAimStateFB when supported to read Quest's palm-pinch menu gesture.
        var aim = XrHandTrackingAimStateFB()
        aim.type = XR_TYPE_HAND_TRACKING_AIM_STATE_FB
        let readsMenu = instance.extensions.contains("XR_FB_hand_tracking_aim")
        let result = joints.withUnsafeMutableBufferPointer { all -> XrResult in
            located.jointCount = UInt32(all.count)
            located.jointLocations = all.baseAddress
            guard readsMenu else { return locateJoints(tracker, &which, &located) }
            return withUnsafeMutablePointer(to: &aim) { chained in
                located.next = UnsafeMutableRawPointer(chained)
                return locateJoints(tracker, &which, &located)
            }
        }
        let needed = XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT
        guard result.rawValue >= 0, located.isActive != 0, joints.allSatisfy({ $0.locationFlags & needed == needed })
        else { return nil }
        var tracked = TrackedHand(joints: joints.map { Pose($0.pose) })
        // The host reads the menu gesture from the left hand only.
        let gestured = readsMenu && aim.status & XR_HAND_TRACKING_AIM_MENU_PRESSED_BIT_FB != 0
        tracked.menu = side == .left && (gestured || systemButton?() == true)
        return tracked
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
        let head = locate(headSpace, in: base, at: time, velocityFromPoses: headVelocityFromPoses)
        let hands = Side.allCases.map { side -> HandInput? in
            if let held = controller(side, in: base, at: time) { return .controller(held) }
            return hand(side, in: base, at: time).map { .hand($0) }
        }
        let pointers = Side.allCases.map { side -> Pointer? in
            var which = XrActionStateGetInfo()
            which.type = XR_TYPE_ACTION_STATE_GET_INFO
            which.action = actions[.point]
            which.subactionPath = sides[side.rawValue]
            var held = XrActionStatePose()
            held.type = XR_TYPE_ACTION_STATE_POSE
            if calls.getActionStatePose(session, &which, &held).rawValue >= 0, held.isActive != 0,
               let ray = locate(points[side.rawValue], in: base, at: time) {
                return Pointer(ray: ray.pose, press: amount(.press, side))
            }
            // Fall back to joint-derived ray and pinch tracking on runtimes without XR_EXT_hand_interaction.
            guard case .hand(let tracked)? = hands[side.rawValue], let head else { return nil }
            let found = handPointers[side.rawValue].point(tracked, side: side, head: head.pose,
                                                          seconds: Double(Uptime.nanoseconds) / 1e9)
            if !pointsFromJoints[side.rawValue] {
                pointsFromJoints[side.rawValue] = true
                log("openxr: no aim pose for the \(side == .left ? "left" : "right") hand; pointing from its joints")
            }
            return Pointer(ray: found.ray, press: found.pressed ? 1 : 0)
        }
        // Sample eye gaze in head space and project a fixation point along the gaze ray.
        var gaze: Vec3?
        if let gazeAction, let headSpace, samplesGaze {
            var which = XrActionStateGetInfo()
            which.type = XR_TYPE_ACTION_STATE_GET_INFO
            which.action = gazeAction
            var state = XrActionStatePose()
            state.type = XR_TYPE_ACTION_STATE_POSE
            if calls.getActionStatePose(session, &which, &state).rawValue >= 0, state.isActive != 0,
               let look = locate(gazeSpace, in: headSpace, at: time)?.pose {
                gaze = look.position + look.forward * XRInput.gazeDistance
            }
            if (gaze != nil) != gazeNoted {
                gazeNoted = gaze != nil
                log("openxr: eye gaze \(gazeNoted ? "active" : "inactive")")
            }
        }
        lock.lock()
        latestGaze = gaze
        latestHead = head
        latestHands = hands
        latestPointers = pointers
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
