// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import ARKit
import AVKit
import QuartzCore
import SwiftUI
import VRLinkAppleFace
import VRLinkCore

/// Experimental face expression and eye-gaze tracking driven by the user's Spatial Persona.
///
/// visionOS does not expose direct face or eye tracking APIs to apps, but it
/// does provide a virtual camera feed of the user's Spatial Persona mirroring
/// their facial expressions and eye movements. `FaceCamera` extracts blendshape
/// estimates and pupil positions from that feed, and `GazeCalibration` maps
/// those pupil positions to a gaze direction.
public final class PersonaTracking {
    public init() {}

    public let camera = FaceCamera()
    private let lock = NSLock()
    private var sceneReady: TimeInterval = 0

    /// Timestamp (`CACurrentMediaTime`) when the streaming scene containing the camera anchor
    /// became ready, or 0 if it hasn't yet. Starting the Persona camera before the scene is
    /// ready produces no frames.
    public var sceneReadyTime: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return sceneReady }
        set { lock.lock(); sceneReady = newValue; lock.unlock() }
    }
    private var gazeMaker = GazeFromFeatures()

    /// Stops the Persona camera when leaving an immersive space.
    func leave() {
        camera.stop()
    }

    /// Returns facial expressions for the host, overriding uncalibrated eye
    /// look directions with the calibrated gaze vector when available.
    func face(_ settings: VRLinkCore.Settings) -> FaceExpressions? {
        guard settings.faceFromCamera, var face = camera.estimate()?.face else { return nil }
        lock.lock()
        let gaze = lastGaze
        lock.unlock()
        if let gaze, gaze.z < 0 { face.setEyeDirection(across: gaze.x / -gaze.z, up: gaze.y / -gaze.z) }
        return face
    }

    /// Most recent calibrated gaze vector sent to the host, or `nil` when stale or unavailable.
    private var lastGaze: Vec3?

    /// In-memory gaze calibration refined by indirect pinches during the
    /// current stream. Flushed to settings only when the stream ends
    /// (`takeTunedCalibration`), because mutating settings mid-stream triggers
    /// a SwiftUI view update that can detach the Persona camera anchor (see
    /// `GazeCalibrationView`).
    private var tuned: GazeCalibration?

    /// Refines the active gaze calibration using an indirect pinch made while
    /// streaming. Pairs the world-space pinch gaze `direction` and `head` pose
    /// with the pupil features captured from the Persona camera just prior,
    /// matching the sampling used in `GazeCalibrationSpace`.
    func learn(fromPinchLooking direction: Vec3, head: Pose?, settings: VRLinkCore.Settings) {
        guard settings.faceFromCamera, settings.continuousGazeCalibration, let saved = settings.gazeCalibration,
              let head, let looked = GazeCalibrator.tangents(ofRay: direction, head: head)
        else { return }
        let now = CACurrentMediaTime()
        guard let features = camera.eyeFeatures(from: now - 0.4, to: now - 0.03) else { return }
        lock.lock()
        defer { lock.unlock() }
        let inUse = tuned ?? saved
        let guessed = inUse.tangents(for: features)
        guard let better = inUse.tuned(with: GazeSample(features: features, across: looked.across, up: looked.up)) else {
            Log.note(String(format: "gaze: a pinch looking %.2f across, %.2f up was left out (the calibration said %.2f, %.2f)",
                            looked.across, looked.up, guessed.across, guessed.up))
            return
        }
        tuned = better
        Log.note(String(format: "gaze: tuned by a pinch looking %.2f across, %.2f up (the calibration said %.2f, %.2f); now typically %.1f degrees off",
                        looked.across, looked.up, guessed.across, guessed.up, better.typicalErrorDegrees))
    }

    /// Consumes and returns the gaze calibration refined during the stream so
    /// it can be persisted, or `nil` if no pinches updated it.
    func takeTunedCalibration() -> GazeCalibration? {
        lock.lock()
        defer { lock.unlock() }
        defer { tuned = nil }
        return tuned
    }

    /// Computes the current gaze vector for the host when Persona tracking is
    /// enabled, calibrated, and a face is visible.
    func gaze(_ settings: VRLinkCore.Settings) -> Vec3? {
        lock.lock()
        defer { lock.unlock() }
        // Discard any in-memory refinements if calibration is cleared or continuous tuning is disabled mid-stream.
        if settings.gazeCalibration == nil || !settings.continuousGazeCalibration { tuned = nil }
        guard settings.faceFromCamera, let calibration = tuned ?? settings.gazeCalibration, calibration.usable,
              let estimate = camera.estimate()
        else {
            lastGaze = nil
            return nil
        }
        lastGaze = gazeMaker.gaze(estimate, calibration: calibration, seconds: CACurrentMediaTime())
        return lastGaze
    }
}
#endif
