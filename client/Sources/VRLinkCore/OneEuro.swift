// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Adaptive 1-euro low-pass filter (Casiez, Roussel, and Vogel, 2012) for `Vec3`
/// positions or directions. Applies heavy smoothing at low speeds to suppress
/// jitter and raises the cutoff frequency at high speeds to minimize lag, using
/// the Euclidean magnitude of the derivative vector to drive the cutoff.
struct OneEuroFilterVec3 {
    /// Minimum cutoff frequency at rest, in Hz (lower values increase smoothing).
    var slowestCutoff: Float
    /// Cutoff slope (beta), in Hz per unit of speed.
    var speedGain: Float
    private var value: Vec3?
    private var rate = Vec3(0, 0, 0)

    init(slowestCutoff: Float, speedGain: Float) {
        self.slowestCutoff = slowestCutoff
        self.speedGain = speedGain
    }

    /// Computes the exponential smoothing factor alpha for `cutoff` (Hz) and `seconds` (dt).
    private static func share(cutoff: Float, seconds: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / seconds)
    }

    mutating func smooth(_ sample: Vec3, seconds: Float) -> Vec3 {
        guard let last = value, seconds > 0 else {
            value = sample
            return sample
        }
        // Low-pass filter the derivative at 1 Hz before computing the adaptive cutoff.
        let newRate = (sample - last) * (1 / seconds)
        let rateShare = OneEuroFilterVec3.share(cutoff: 1, seconds: seconds)
        rate = rate + (newRate - rate) * rateShare
        let cutoff = slowestCutoff + speedGain * length(rate)
        let smoothed = last + (sample - last) * OneEuroFilterVec3.share(cutoff: cutoff, seconds: seconds)
        value = smoothed
        return smoothed
    }
}
