// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import QuartzCore

/// When what RealityKit is given now will be seen, from the display's own
/// refresh signal. (The ALVR visionOS client's method.)
///
/// RealityKit does not say when a change will reach the eyes, but a display
/// link says when each refresh happens, and what RealityKit is handed is
/// shown a whole number of refreshes later: as many as it takes to cover
/// its own drawing time (about 14 ms, so two refreshes at 90 Hz).
@MainActor
final class VsyncPrediction: NSObject {
    /// When what is set in the current update will be seen, on the `CACurrentMediaTime` clock.
    private(set) var nextFrameTime: TimeInterval = 0
    /// The time between two refreshes, in seconds; 0 before the first one.
    private(set) var refreshPeriod: TimeInterval = 0
    /// How long an update takes to reach the display, a running average, in seconds.
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
        // The drawing time, rounded up to whole refreshes.
        let latency = (averageDrawTime / period).rounded(.up) * period
        refreshPeriod = period
        nextFrameTime = link.targetTimestamp + latency
    }

    /// Tell it how long this update's own work took, in seconds.
    func updateTook(_ seconds: TimeInterval) {
        averageDrawTime = (averageDrawTime + seconds + refreshPeriod) * 0.5
    }
}
#endif
