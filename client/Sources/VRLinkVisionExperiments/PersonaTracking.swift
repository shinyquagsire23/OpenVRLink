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

/// Experiment: face expressions and gaze from the wearer's Spatial Persona.
///
/// visionOS gives apps neither face nor eye tracking, but it will give an
/// app a camera picture of the wearer's Persona, whose face and eyes move
/// as the wearer's do. `FaceCamera` reads expressions and pupil positions
/// off that picture; a calibration (`GazeCalibration`) turns the pupil
/// positions into a gaze direction.
public final class PersonaTracking {
    public init() {}

    public let camera = FaceCamera()
    private let lock = NSLock()
    private var gazeMaker = GazeFromFeatures()

    /// The space has gone: the camera is only kept running inside one.
    func leave() {
        camera.stop()
    }

    /// The expressions for the host. Where the eyes look comes from the
    /// calibrated gaze when there is one, which is far better than the
    /// rules of thumb at it.
    func face(_ settings: VRLinkCore.Settings) -> FaceExpressions? {
        guard settings.faceFromCamera, var face = camera.estimate()?.face else { return nil }
        lock.lock()
        let gaze = lastGaze
        lock.unlock()
        if let gaze, gaze.z < 0 { face.setEyeDirection(across: gaze.x / -gaze.z, up: gaze.y / -gaze.z) }
        return face
    }

    /// The gaze last given to the host, while it is fresh.
    private var lastGaze: Vec3?

    /// Continuous calibration: the saved calibration as tuned by this
    /// stream's pinches so far. Kept here and saved when the stream ends
    /// (`takeTunedCalibration`), not at each pinch: a change to the settings
    /// makes SwiftUI look at the stream's view again, which can cost the
    /// Persona's camera its place (see `GazeCalibrationView`).
    private var tuned: GazeCalibration?

    /// A pinch made while streaming: its ray is where the eyes looked, in
    /// world space, and `head` is where the head was. Paired with what the
    /// camera saw of the eyes just before, exactly as in the calibration
    /// space, it tunes the calibration in use.
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

    /// The stream has ended: the calibration as this stream tuned it, to be
    /// saved, or nil if no pinch tuned it.
    func takeTunedCalibration() -> GazeCalibration? {
        lock.lock()
        defer { lock.unlock() }
        defer { tuned = nil }
        return tuned
    }

    /// The gaze for the host, when the experiment is on, calibrated, and the face is in view.
    func gaze(_ settings: VRLinkCore.Settings) -> Vec3? {
        lock.lock()
        defer { lock.unlock() }
        // Forgetting the calibration, or turning the tuning off, mid-stream also drops what was tuned.
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
