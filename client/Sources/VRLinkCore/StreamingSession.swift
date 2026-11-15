// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// What a display, a decoder and an app shell need of a running stream,
/// whichever protocol it speaks: Steam's VR Link (`StreamSession`) or
/// WiVRn's (`WiVRnSession`).
///
/// Times are the system's uptime in nanoseconds (`Uptime.nanoseconds`);
/// each session turns them into its protocol's own clock.
public protocol StreamingSession: AnyObject {
    /// Called on the session's thread with each encoded picture.
    var onFrame: ((EncodedFrame) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }
    /// Asked for the head pose each time one is sent; when nil, the last
    /// pose given to `setHead` is sent.
    var headProvider: (() -> TrackedPose?)? { get set }
    /// Asked for both hands each time poses are sent: left then right, nil
    /// for a hand that is neither holding a tracked controller nor tracked itself.
    var handsProvider: (() -> [HandInput?])? { get set }
    /// Where the eyes look, in meters in the head's own frame; nil for no eye tracking.
    var gazeProvider: (() -> Vec3?)? { get set }
    var faceProvider: (() -> FaceExpressions?)? { get set }
    /// The headset's battery, asked about once a second.
    var headsetPowerProvider: (() -> PowerState?)? { get set }
    /// Called on the session's thread when the host wants a controller to vibrate.
    var onHaptic: ((HapticPulse) -> Void)? { get set }
    /// Called on the session's thread when the host wants another refresh
    /// rate, in Hz. The platform asks its display for it if it can; the
    /// host is always told what the display really runs at.
    var onRefreshRateRequested: ((Float) -> Void)? { get set }
    /// Where microphone audio for the host goes.
    var microphoneSink: any MicrophoneSink { get }
    /// Called on the session's thread when the stream ends without having
    /// been stopped (the host closed it, say), with why.
    var onEnded: ((String) -> Void)? { get set }
    /// Decoded audio waiting to be played.
    var audio: PlaybackBuffer { get }
    /// Whether the host says an application has the scene.
    var sceneApplicationRunning: Bool { get }

    func setHead(_ pose: TrackedPose)
    func start()
    /// `leaving`: the wearer is done, as against the stream being interrupted.
    func stop(leaving: Bool)

    /// The decoder has produced one picture of this frame.
    func frameDecoded(_ frameID: UInt16, picture: Int)
    /// The decoder could not decode one picture of this frame, and will
    /// show nothing until the host sends a frame that depends on no other.
    func frameNotDecoded(_ frameID: UInt16, picture: Int)
    /// This frame has been handed to the display and is expected on screen at the time given.
    func frameShown(_ frameID: UInt16, at uptimeNanoseconds: UInt64)
    /// When the display's next refresh will be seen, and how far apart refreshes are, in seconds.
    func displayRefreshes(at uptimeNanoseconds: UInt64, period: Double)
}

/// Tracks the display's refresh rate across protocols. Display APIs only report next-vsync
/// timestamps and frame intervals rather than explicit rate-change events, so we detect rate
/// changes here by watching for significant shifts in the measured refresh period.
struct RefreshRate {
    /// Frame interval in seconds.
    private(set) var period: Double
    /// Refresh rate rounded to the nearest integer Hz, matching what hosts expect.
    var hz: Float { Float((1 / period).rounded()) }
    /// Relative period jitter ignored before treating a measurement as a new refresh rate (2%).
    static let tolerance = 0.02

    struct Change: Equatable {
        var from: Float, to: Float
        /// Formatted message for session logs.
        var note: String { "display now refreshes at \(to) Hz" }
    }

    init(hz: Float) { period = 1 / Double(hz) }

    /// Updates the tracked period from a display measurement. Returns a `Change` if the period
    /// shifted beyond `tolerance` so the caller can notify the host, or nil if the rate is unchanged.
    mutating func follow(_ measured: Double) -> Change? {
        guard measured > 0, abs(measured - period) > period * RefreshRate.tolerance else { return nil }
        let before = hz
        period = measured
        return Change(from: before, to: hz)
    }
}

/// Deduplicates battery status updates for a single device so the host is only notified
/// when the charge level changes by at least 1% or the charging state flips.
struct PowerNews {
    private var told: PowerState?

    /// Returns the rounded battery state if it changed since the last update, or nil if
    /// unchanged or unavailable on the current platform.
    mutating func news(_ power: PowerState?) -> PowerState? {
        guard let power = power?.rounded, power != told else { return nil }
        told = power
        return power
    }
}
