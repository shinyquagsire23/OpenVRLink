// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import VRLinkCore

/// What the headset's displays are like, as last measured: where each eye
/// is and what it sees (a `DeviceProfile`, its frusta unscaled), and where
/// the middle of the eyes is from the device anchor.
///
/// Only a compositor layer is told these things. The RealityKit renderer
/// is not, so a compositor layer is opened for a moment first, just to
/// measure (the ALVR visionOS client does the same).
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
