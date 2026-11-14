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
