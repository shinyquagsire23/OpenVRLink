// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Maps controller and hand state to WiVRn input IDs (docs/wivrn/protocol.md).
/// Controllers map to Oculus Touch profiles (matching SteamVR), and tracked
/// hands map to `XR_EXT_hand_interaction` with pinch, aim-activate, and grasp inputs.
///
/// Each input is identified by its index in WiVRn's input table (release 26.9).
/// Right-hand input IDs follow the same layout as left-hand IDs at a higher base offset.
extension ControllerState {
    /// Returns the OpenXR aim pose for a Touch controller. If the platform
    /// provides a native aim pose in `aim`, that is used directly; otherwise
    /// it is derived from the grip pose using the Touch offset from `vrlink`
    /// (docs/svl-tracking-input/controllers.md).
    func aimPose(_ side: Side) -> Pose {
        if let aim { return aim }
        let offset = ControllerState.gripOffset(side, senseModel: false)
        return grip.pose.placing(Pose(position: Vec3(offset[0], offset[1], offset[2]), quaternion: Array(offset[3...])))
    }

    func wivrnInputs(_ side: Side) -> [(id: UInt8, value: Float)] {
        var out: [(id: UInt8, value: Float)] = []
        func add(_ id: UInt8, _ value: Float) { out.append((id, value)) }
        func add(_ id: UInt8, _ on: Bool) { out.append((id, on ? 1 : 0)) }
        // Left hand sends X, Y, and menu; right hand sends A and B (system is unused).
        let face: UInt8 = side == .left ? 17 : 53
        add(face, lowerButton)
        add(face + 1, lowerButtonTouched)
        add(face + 2, upperButton)
        add(face + 3, upperButtonTouched)
        if side == .left { add(21, menuButton) }
        // Starting from squeeze, both hands use identical relative offsets.
        let base: UInt8 = side == .left ? 24 : 60
        add(base, squeeze)
        add(base + 2, trigger)
        add(base + 3, triggerTouched)
        add(base + 8, stickX)
        add(base + 9, stickY)
        add(base + 10, stickClick)
        add(base + 11, stickTouched)
        add(base + 12, thumbRestTouched)
        return out
    }
}

extension HandGestures {
    /// Encodes pinch, aim-activate, and grasp values along with their ready flags.
    func wivrnInputs(_ side: Side) -> [(id: UInt8, value: Float)] {
        let base: UInt8 = side == .left ? 46 : 82
        let pinching: Float = pinch[0] ? 1 : 0, grasping: Float = grip ? 1 : 0
        let values: [(UInt8, Float)] = [(base, pinching), (base + 1, 1), (base + 3, pinching), (base + 4, 1),
                                        (base + 5, grasping), (base + 6, 1)]
        return values.map { (id: $0.0, value: $0.1) }
    }
}
