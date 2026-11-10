// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The "1 euro" filter (Casiez, Roussel and Vogel, 2012): a low-pass filter
/// that smooths hard when the value is nearly still, which hides jitter, and
/// lightly when it moves fast, which avoids lag.
///
/// This one filters a Vec3 (a position in meters, a direction), taking the
/// speed that sets the smoothing from the length of its change. The filter
/// itself works the same on a vector of any size.
struct OneEuroFilterVec3 {
    /// Smoothing when still: lower is steadier. Hz.
    var slowestCutoff: Float
    /// How quickly smoothing lets go as speed rises: Hz per unit of speed.
    var speedGain: Float
    private var value: Vec3?
    private var rate = Vec3(0, 0, 0)

    init(slowestCutoff: Float, speedGain: Float) {
        self.slowestCutoff = slowestCutoff
        self.speedGain = speedGain
    }

    /// How much of a new sample to take, for a cutoff frequency and a time step.
    private static func share(cutoff: Float, seconds: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / seconds)
    }

    mutating func smooth(_ sample: Vec3, seconds: Float) -> Vec3 {
        guard let last = value, seconds > 0 else {
            value = sample
            return sample
        }
        // The speed is itself smoothed, at 1 Hz, before it sets the cutoff.
        let newRate = (sample - last) * (1 / seconds)
        let rateShare = OneEuroFilterVec3.share(cutoff: 1, seconds: seconds)
        rate = rate + (newRate - rate) * rateShare
        let cutoff = slowestCutoff + speedGain * length(rate)
        let smoothed = last + (sample - last) * OneEuroFilterVec3.share(cutoff: cutoff, seconds: seconds)
        value = smoothed
        return smoothed
    }
}
