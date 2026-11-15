// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import VRLinkCore

/// Thread-safe store for the headset's measured display geometry: an unscaled
/// `DeviceProfile` (per-eye offsets, frusta, resolution, and refresh rate) and
/// the eye midpoint offset relative to ARKit's device anchor.
///
/// Only `CompositorServices` exposes per-eye transforms and projections on
/// visionOS. Because neither the 2D pre-connection UI nor the RealityKit
/// renderer can query them directly, the app briefly opens a compositor layer
/// at launch to record these values (the same approach used by ALVR on visionOS).
public final class MeasuredDisplay: ObservableObject {
    public init() {}

    private let lock = NSLock()
    private var stored: (profile: DeviceProfile, eyeMidpoint: SIMD3<Float>)?

    public var value: (profile: DeviceProfile, eyeMidpoint: SIMD3<Float>)? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func set(profile: DeviceProfile, eyeMidpoint: SIMD3<Float>) {
        lock.lock()
        stored = (profile, eyeMidpoint)
        lock.unlock()
    }
}
