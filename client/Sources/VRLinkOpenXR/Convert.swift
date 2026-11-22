// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import COpenXR
import Foundation
import VRLinkCore

// OpenXR and `VRLinkCore` both use a right-handed coordinate system (+X right, +Y up, -Z forward, in meters),
// differing only in quaternion component order (`xyzw` in OpenXR vs. `wxyz` in `Pose`).

extension Pose {
    init(_ pose: XrPosef) {
        self.init(position: Vec3(pose.position.x, pose.position.y, pose.position.z),
                  quaternion: [pose.orientation.w, pose.orientation.x, pose.orientation.y, pose.orientation.z])
    }

    var xr: XrPosef {
        let q = quaternion
        return XrPosef(orientation: XrQuaternionf(x: q[1], y: q[2], z: q[3], w: q[0]),
                       position: XrVector3f(x: position.x, y: position.y, z: position.z))
    }
}

extension XrPosef {
    static let identity = XrPosef(orientation: XrQuaternionf(x: 0, y: 0, z: 0, w: 1), position: XrVector3f(x: 0, y: 0, z: 0))
}

extension Frustum {
    /// Converts OpenXR signed field-of-view angles (in radians) to tangent half-angles.
    init(_ fov: XrFovf) {
        self.init(left: tan(fov.angleLeft), right: tan(fov.angleRight), down: tan(fov.angleDown), up: tan(fov.angleUp))
    }
}

extension TrackedPose {
    /// Constructs a `TrackedPose` from an OpenXR space location and velocity, returning `nil` if position or
    /// orientation tracking is invalid.
    ///
    /// OpenXR reports angular velocity in the base reference space, whereas `TrackedPose` stores angular
    /// velocity in the pose's local right, up, and backward (+Z) axes.
    init?(_ location: XrSpaceLocation, _ velocity: XrSpaceVelocity) {
        let needed = XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT
        guard location.locationFlags & needed == needed else { return nil }
        self.init(pose: Pose(location.pose))
        if velocity.velocityFlags & XR_SPACE_VELOCITY_LINEAR_VALID_BIT != 0 {
            linearVelocity = Vec3(velocity.linearVelocity.x, velocity.linearVelocity.y, velocity.linearVelocity.z)
        }
        if velocity.velocityFlags & XR_SPACE_VELOCITY_ANGULAR_VALID_BIT != 0 {
            let spin = Vec3(velocity.angularVelocity.x, velocity.angularVelocity.y, velocity.angularVelocity.z)
            angularVelocity = Vec3(spin.dot(pose.right), spin.dot(pose.up), -spin.dot(pose.forward))
        }
    }
}
