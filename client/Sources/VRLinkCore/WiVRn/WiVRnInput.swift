// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// What the hands hold, as a WiVRn host wants it (docs/wivrn/protocol.md):
/// a controller is a Touch controller, as it is for a Steam host, and a
/// bare hand is OpenXR's "hand interaction" device, whose inputs are a
/// pinch, an aim-and-pinch and a grasp.
///
/// An input is a number with a place in WiVRn's list of them (release
/// 26.9); the right hand's are in the same order as the left's, further on.
extension ControllerState {
    /// Where a Touch controller points from, relative to its grip pose:
    /// the offset the Steam Link client sends for Touch
    /// (docs/svl-tracking-input/controllers.md). Inferred to serve as
    /// OpenXR's aim pose; a platform that knows the aim says so in `aim`.
    func aimPose(_ side: Side) -> Pose {
        if let aim { return aim }
        let offset = ControllerState.gripOffset(side, senseModel: false)
        return grip.pose.placing(Pose(position: Vec3(offset[0], offset[1], offset[2]), quaternion: Array(offset[3...])))
    }

    func wivrnInputs(_ side: Side) -> [(id: UInt8, value: Float)] {
        var out: [(id: UInt8, value: Float)] = []
        func add(_ id: UInt8, _ value: Float) { out.append((id, value)) }
        func add(_ id: UInt8, _ on: Bool) { out.append((id, on ? 1 : 0)) }
        // Left: X and Y, then menu. Right: A and B (and system, never pressed here).
        let face: UInt8 = side == .left ? 17 : 53
        add(face, lowerButton)
        add(face + 1, lowerButtonTouched)
        add(face + 2, upperButton)
        add(face + 3, upperButtonTouched)
        if side == .left { add(21, menuButton) }
        // From the squeeze value on, both hands' lists run alike.
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
    /// Pinch, aim-and-pinch and grasp, each a value and a "ready" beside it.
    func wivrnInputs(_ side: Side) -> [(id: UInt8, value: Float)] {
        let base: UInt8 = side == .left ? 46 : 82
        let pinching: Float = pinch[0] ? 1 : 0, grasping: Float = grip ? 1 : 0
        let values: [(UInt8, Float)] = [(base, pinching), (base + 1, 1), (base + 3, pinching), (base + 4, 1),
                                        (base + 5, grasping), (base + 6, 1)]
        return values.map { (id: $0.0, value: $0.1) }
    }
}
