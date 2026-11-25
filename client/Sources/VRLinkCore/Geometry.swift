// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// World-space geometry types in meters.
///
/// Uses right-handed OpenXR/OpenVR coordinates where +x is right, +y is up, and
/// forward points along -z. `Pose` stores its three basis vectors explicitly so
/// transforms can be expressed directly in terms of `right`, `up`, and `forward`.

public struct Vec3 {
    public var x, y, z: Float
    public init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Float) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public func dot(_ b: Vec3) -> Float { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
}

/// A 3D position and orientation frame.
public struct Pose {
    public var position: Vec3
    public var right: Vec3      // unit vectors
    public var up: Vec3
    public var forward: Vec3

    public init(position: Vec3, right: Vec3, up: Vec3, forward: Vec3) {
        self.position = position
        self.right = right
        self.up = up
        self.forward = forward
    }

    /// Constructs a pose from a position and a `(w, x, y, z)` unit quaternion (the inverse of `quaternion`).
    public init(position: Vec3, quaternion q: [Float]) {
        let (w, x, y, z) = (q[0], q[1], q[2], q[3])
        self.position = position
        right = Vec3(1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y))
        up = Vec3(2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x))
        forward = Vec3(2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)) * -1
    }

    /// Rotates the pose around the world-space rotation vector `turn` (axis times angle in radians).
    public func turned(by turn: Vec3) -> Pose {
        let angle = turn.dot(turn).squareRoot()
        guard angle > 1e-6 else { return self }
        let axis = turn * (1 / angle), c = Float(cos(Double(angle))), s = Float(sin(Double(angle)))
        // Rodrigues' rotation of each axis.
        func rotate(_ v: Vec3) -> Vec3 { v * c + axis.cross(v) * s + axis * (axis.dot(v) * (1 - c)) }
        return Pose(position: position, right: rotate(right), up: rotate(up), forward: rotate(forward))
    }

    /// Translates the pose by `meters` along its local `right` axis (for example,
    /// offsetting an eye from the head by half the IPD).
    public func shifted(right meters: Float) -> Pose {
        var pose = self
        pose.position = position + right * meters
        return pose
    }

    /// Transforms `child` from this pose's local frame (+x right, +y up, +z back)
    /// into this pose's parent frame (for example, `head.placing(eyeInHead)` yields
    /// the eye pose in world space).
    public func placing(_ child: Pose) -> Pose {
        func direction(_ v: Vec3) -> Vec3 { right * v.x + up * v.y + forward * -v.z }
        return Pose(position: position + direction(child.position), right: direction(child.right),
                    up: direction(child.up), forward: direction(child.forward))
    }

    /// Expresses `other` (given in this pose's parent frame) in this pose's local
    /// frame (+x right, +y up, +z back); the inverse of `placing(_:)`.
    public func relative(_ other: Pose) -> Pose {
        func own(_ v: Vec3) -> Vec3 { Vec3(v.dot(right), v.dot(up), -v.dot(forward)) }
        return Pose(position: own(other.position - position), right: own(other.right), up: own(other.up), forward: own(other.forward))
    }

    /// Orientation as a unit quaternion `(w, x, y, z)` for the rotation matrix
    /// with columns `(right, up, -forward)`.
    public var quaternion: [Float] {
        let back = forward * -1
        let (m00, m01, m02) = (right.x, up.x, back.x)
        let (m10, m11, m12) = (right.y, up.y, back.y)
        let (m20, m21, m22) = (right.z, up.z, back.z)
        let trace = m00 + m11 + m22
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            return [s / 4, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s]
        } else if m00 > m11, m00 > m22 {
            let s = (1 + m00 - m11 - m22).squareRoot() * 2
            return [(m21 - m12) / s, s / 4, (m01 + m10) / s, (m02 + m20) / s]
        } else if m11 > m22 {
            let s = (1 + m11 - m00 - m22).squareRoot() * 2
            return [(m02 - m20) / s, (m01 + m10) / s, s / 4, (m12 + m21) / s]
        } else {
            let s = (1 + m22 - m00 - m11).squareRoot() * 2
            return [(m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, s / 4]
        }
    }

    /// Projects a world-space point into `(right, up, forward)` distances in meters from `position`.
    public func local(_ point: Vec3) -> Vec3 {
        let offset = point - position
        return Vec3(offset.dot(right), offset.dot(up), offset.dot(forward))
    }
}

/// A view frustum as the tangents of its four half-angles. A point one meter
/// in front of the eye is inside when `left <= x <= right` and `down <= y <= up`
/// (left and down are negative).
public struct Frustum {
    public var left, right, down, up: Float
    public init(left: Float, right: Float, down: Float, up: Float) {
        self.left = left; self.right = right; self.down = down; self.up = up
    }

    public static func symmetric(halfAngleDegrees: Float, aspect: Float = 1) -> Frustum {
        let t = Float(tan(Double(halfAngleDegrees) * .pi / 180))
        return Frustum(left: -t * aspect, right: t * aspect, down: -t, up: t)
    }

    /// Computes the smallest head-aligned frustum that encloses this frustum
    /// when viewed from a canted `eye` pose (given in head space: +x right,
    /// +y up, +z back). The returned frustum shares the eye's origin while
    /// facing straight ahead along the head's forward axis.
    ///
    /// Used for headsets with canted displays: we report parallel eye orientations
    /// with these expanded frusta to the host because many VR titles assume
    /// parallel eyes regardless of reported eye rotation.
    public func enclosing(turnedAs eye: Pose) -> Frustum {
        var out = Frustum(left: .infinity, right: -.infinity, down: .infinity, up: -.infinity)
        for (x, y) in [(left, up), (right, up), (left, down), (right, down)] {
            // A corner of this frustum, one meter along the eye's own forward axis, in the head's frame.
            let corner = eye.right * x + eye.up * y + eye.forward
            let ahead = -corner.z                      // the head looks along -z
            out.left = min(out.left, corner.x / ahead)
            out.right = max(out.right, corner.x / ahead)
            out.down = min(out.down, corner.y / ahead)
            out.up = max(out.up, corner.y / ahead)
        }
        return out
    }

    /// Scales the horizontal tangents by `horizontal` and the vertical tangents by `vertical`.
    public func scaled(horizontal: Float, vertical: Float) -> Frustum {
        Frustum(left: left * horizontal, right: right * horizontal, down: down * vertical, up: up * vertical)
    }

    /// Returns the world-space `[topLeft, topRight, bottomLeft, bottomRight]` corners
    /// of this frustum at `distance` meters in front of `eye`.
    public func corners(from eye: Pose, distance: Float) -> [Vec3] {
        func corner(_ x: Float, _ y: Float) -> Vec3 {
            eye.position + eye.forward * distance + eye.right * (x * distance) + eye.up * (y * distance)
        }
        return [corner(left, up), corner(right, up), corner(left, down), corner(right, down)]
    }

    /// Projects a world-space point into clip space `(x, y, z, w)` from `eye` through
    /// this frustum. Normalized device depth runs from 0 at `near` to 1 at `far`,
    /// or from 1 at `near` to 0 at `far` when `reversed` is true (as used on visionOS).
    public func project(_ point: Vec3, from eye: Pose, near: Float = 0.05, far: Float = 100,
                        reversed: Bool = false) -> [Float] {
        let p = eye.local(point)                 // p.z is meters in front of the eye
        let x = (2 * p.x - (right + left) * p.z) / (right - left)
        let y = (2 * p.y - (up + down) * p.z) / (up - down)
        let z: Float
        if !far.isFinite {
            // Handle an infinite far plane (reported by visionOS) using the limit as far -> infinity.
            z = reversed ? near : p.z - near
        } else {
            z = reversed ? near * (far - p.z) / (far - near) : far * (p.z - near) / (far - near)
        }
        return [x, y, z, p.z]
    }
}

/// A world-space pose paired with linear and angular velocities so the host can
/// predict pose at display time. Velocities are in meters/second (world space)
/// and radians/second (around the pose's local right, up, and backward axes).
public struct TrackedPose {
    public var pose: Pose
    public var linearVelocity = Vec3(0, 0, 0)
    public var angularVelocity = Vec3(0, 0, 0)

    public init(pose: Pose) { self.pose = pose }

    /// Angular velocity transformed from the pose's local axes into world space.
    public var worldAngularVelocity: Vec3 {
        pose.right * angularVelocity.x + pose.up * angularVelocity.y + pose.forward * -angularVelocity.z
    }

    /// Transforms `child` from this pose's local frame into world space (see `Pose.placing`), propagating linear
    /// and angular velocity (including tangential velocity from rotation across the offset).
    public func placing(_ child: Pose) -> TrackedPose {
        var out = TrackedPose(pose: pose.placing(child))
        let turning = worldAngularVelocity
        out.linearVelocity = linearVelocity + turning.cross(out.pose.position - pose.position)
        out.angularVelocity = Vec3(turning.dot(out.pose.right), turning.dot(out.pose.up), -turning.dot(out.pose.forward))
        return out
    }

    /// Extrapolates the pose `seconds` into the future assuming constant linear and angular velocity.
    public func predicted(seconds: Float) -> TrackedPose {
        var out = self
        out.pose = pose.turned(by: worldAngularVelocity * seconds)
        out.pose.position = pose.position + linearVelocity * seconds
        return out
    }

    /// Returns a copy of this pose with velocities estimated by finite difference from `earlier` over `seconds`.
    public func withVelocities(since earlier: Pose, seconds: Float) -> TrackedPose {
        var out = self
        guard seconds > 0 else { return out }
        out.linearVelocity = (pose.position - earlier.position) * (1 / seconds)
        // The rotation from the earlier orientation to the current orientation,
        // expressed in the earlier frame, is conj(q1) * q2; twice its vector part
        // divided by dt approximates angular velocity for small steps.
        let a = earlier.quaternion, b = pose.quaternion
        let scale = 2 / seconds
        out.angularVelocity = Vec3((a[0] * b[1] - a[1] * b[0] - a[2] * b[3] + a[3] * b[2]) * scale,
                                   (a[0] * b[2] + a[1] * b[3] - a[2] * b[0] - a[3] * b[1]) * scale,
                                   (a[0] * b[3] - a[1] * b[2] + a[2] * b[1] - a[3] * b[0]) * scale)
        return out
    }
}

/// Head position and yaw/pitch orientation with velocities.
public struct HeadPose {
    public var position: Vec3
    public var yaw: Float
    public var pitch: Float
    /// World-space linear velocity in meters/second; `yawRate` and `pitchRate` are in radians/second.
    public var velocity = Vec3(0, 0, 0)
    public var yawRate: Float = 0
    public var pitchRate: Float = 0

    public init(position: Vec3, yaw: Float = 0, pitch: Float = 0) {
        self.position = position
        self.yaw = yaw
        self.pitch = pitch
    }

    public var pose: Pose {
        let right = Vec3(Float(cos(Double(yaw))), 0, -Float(sin(Double(yaw))))
        let forward = Vec3(-Float(sin(Double(yaw)) * cos(Double(pitch))),
                           Float(sin(Double(pitch))),
                           -Float(cos(Double(yaw)) * cos(Double(pitch))))
        return Pose(position: position, right: right, up: right.cross(forward), forward: forward)
    }

    /// Angular velocity in the head's own frame (about its right, up and back
    /// axes), which is the form the host expects. Yaw turns about the world's
    /// up axis and pitch about the head's right axis.
    public var angularVelocity: Vec3 {
        let pose = self.pose
        let world = Vec3(0, 1, 0) * yawRate + pose.right * pitchRate
        return Vec3(world.dot(pose.right), world.dot(pose.up), world.dot(pose.forward * -1))
    }

    public var tracked: TrackedPose {
        var out = TrackedPose(pose: pose)
        out.linearVelocity = velocity
        out.angularVelocity = angularVelocity
        return out
    }
}

import Foundation
