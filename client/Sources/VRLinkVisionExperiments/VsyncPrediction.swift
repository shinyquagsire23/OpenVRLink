// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import QuartzCore

/// Estimates display presentation timestamps for RealityKit updates using
/// `CADisplayLink`, following the approach used in the ALVR visionOS client.
///
/// RealityKit does not expose per-frame presentation timestamps directly.
/// `CADisplayLink` provides the display refresh cadence, and scene changes
/// appear a whole number of refresh intervals later based on RealityKit's
/// render latency (roughly 14 ms, or two refreshes at 90 Hz).
@MainActor
final class VsyncPrediction: NSObject {
    /// Predicted presentation time (`CACurrentMediaTime`) for changes made in the current scene update.
    private(set) var nextFrameTime: TimeInterval = 0
    /// Display refresh interval in seconds, or `0` before the first display link callback.
    private(set) var refreshPeriod: TimeInterval = 0
    /// Exponentially smoothed estimate of total update-to-display latency, in seconds.
    private var averageDrawTime: TimeInterval = 0.014
    private var link: CADisplayLink?

    override init() {
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(refreshed))
        link.add(to: .main, forMode: .default)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func refreshed(_ link: CADisplayLink) {
        let period = link.targetTimestamp - link.timestamp
        guard period > 0 else { return }
        // Round estimated draw latency up to the next whole refresh interval.
        let latency = (averageDrawTime / period).rounded(.up) * period
        refreshPeriod = period
        nextFrameTime = link.targetTimestamp + latency
    }

    /// Records the CPU/GPU duration of the current update pass, in seconds.
    func updateTook(_ seconds: TimeInterval) {
        averageDrawTime = (averageDrawTime + seconds + refreshPeriod) * 0.5
    }
}
#endif
