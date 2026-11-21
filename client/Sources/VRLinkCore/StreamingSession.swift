// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Common interface between the display/decoder pipeline, app shell, and an
/// active streaming backend (`StreamSession` for Steam VR Link or
/// `WiVRnSession` for WiVRn).
///
/// Timestamps passed across this interface use system uptime in nanoseconds
/// (`Uptime.nanoseconds`); each session converts them to its own protocol clock.
public protocol StreamingSession: AnyObject {
    /// Called on the session's thread with each encoded picture.
    var onFrame: ((EncodedFrame) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }
    /// Polled whenever the session sends a head pose; falls back to the last
    /// pose passed to `setHead` when nil.
    var headProvider: (() -> TrackedPose?)? { get set }
    /// Polled whenever poses are sent for `[left, right]` hand inputs, using
    /// nil for any hand without an active controller or hand tracking.
    var handsProvider: (() -> [HandInput?])? { get set }
    /// Eye-gaze fixation point in head-local meters, or nil when eye tracking is unavailable.
    var gazeProvider: (() -> Vec3?)? { get set }
    var faceProvider: (() -> FaceExpressions?)? { get set }
    /// Polled roughly once per second for the headset's battery state.
    var headsetPowerProvider: (() -> PowerState?)? { get set }
    /// Called on the session's thread when the host wants a controller to vibrate.
    var onHaptic: ((HapticPulse) -> Void)? { get set }
    /// Called on the session's thread when the host requests a target refresh
    /// rate in Hz. The platform switches its display rate if supported, while
    /// always reporting the actual display rate back to the host.
    var onRefreshRateRequested: ((Float) -> Void)? { get set }
    /// Called on the session thread when the host requests a recenter so the play space
    /// aligns with the user's current position and heading.
    var onRecenterRequested: (() -> Void)? { get set }
    /// Sink that accepts captured microphone audio for uplink to the host.
    var microphoneSink: any MicrophoneSink { get }
    /// Called on the session's thread with a reason string if the stream
    /// terminates unexpectedly (for example, when closed by the host).
    var onEnded: ((String) -> Void)? { get set }
    /// Decoded audio waiting to be played.
    var audio: PlaybackBuffer { get }
    /// Whether a scene application is currently running on the host.
    var sceneApplicationRunning: Bool { get }

    func setHead(_ pose: TrackedPose)
    func start()
    /// Stops the session. Pass `leaving: true` when the user explicitly exits,
    /// rather than when the stream is temporarily interrupted.
    func stop(leaving: Bool)

    /// Notifies the session that `picture` of `frameID` finished decoding.
    func frameDecoded(_ frameID: UInt16, picture: Int)
    /// Notifies the session that `picture` of `frameID` failed to decode and
    /// the decoder needs a new keyframe to recover.
    func frameNotDecoded(_ frameID: UInt16, picture: Int)
    /// Notifies the session that `frameID` was submitted for display at the given vsync uptime.
    func frameShown(_ frameID: UInt16, at uptimeNanoseconds: UInt64)
    /// Reports the next expected display vsync timestamp and refresh interval in seconds.
    func displayRefreshes(at uptimeNanoseconds: UInt64, period: Double)
    /// Sends a room boundary to the host as floor corners in `PlaySpace` coordinates,
    /// or clears the boundary when empty. Safe to call from any thread before or after `start`.
    func setBoundary(_ boundary: [Point2])
}

extension StreamingSession {
    /// Default no-op for protocols that do not support sending a room boundary.
    public func setBoundary(_ boundary: [Point2]) {}
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
