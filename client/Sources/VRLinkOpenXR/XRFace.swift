// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import COpenXR
import Foundation
import VRLinkCore

/// Common interface for OpenXR face-tracking backends.
protocol FaceSource: AnyObject {
    /// Samples face expression weights for `time`. Called by the tracking thread.
    func update(at time: XrTime)
    /// Latest face expression weights, or `nil` while untracked. Thread-safe.
    func expressions() -> FaceExpressions?
    /// Whether the runtime reports that system face calibration has not been completed. Thread-safe.
    var needsCalibration: Bool { get }
}

/// Creates an Android XR or Meta OpenXR face tracker when supported by the runtime.
func makeFaceSource(instance: XRInstance, session: XrSession, log: @escaping (String) -> Void) -> (any FaceSource)? {
    XRFace(instance: instance, session: session, log: log) ?? XRFaceMeta(instance: instance, session: session, log: log)
}

/// Reads face expression weights from `XR_FB_face_tracking2` (camera-based on Quest Pro, or audio-driven on
/// Quest 3), matching `FaceExpressions`' 70-weight layout directly. Requires `com.oculus.permission.FACE_TRACKING`
/// before creating the tracker.
final class XRFaceMeta: FaceSource {
    private var tracker: XrFaceTracker2FB?
    private let read: PFN_xrGetFaceExpressionWeights2FB
    private let destroy: PFN_xrDestroyFaceTracker2FB?
    private let log: (String) -> Void
    private let lock = NSLock()
    private var latest: FaceExpressions?
    private var noted: String?

    init?(instance: XRInstance, session: XrSession, log: @escaping (String) -> Void) {
        guard instance.extensions.contains(XR_FB_FACE_TRACKING2_EXTENSION_NAME),
              let create = try? instance.function("xrCreateFaceTracker2FB", as: PFN_xrCreateFaceTracker2FB.self),
              let read = try? instance.function("xrGetFaceExpressionWeights2FB", as: PFN_xrGetFaceExpressionWeights2FB.self)
        else { return nil }
        var info = XrFaceTrackerCreateInfo2FB()
        info.type = XR_TYPE_FACE_TRACKER_CREATE_INFO2_FB
        info.faceExpressionSet = XR_FACE_EXPRESSION_SET2_DEFAULT_FB
        // Prefer visual camera tracking when available, falling back to audio-driven lip sync.
        var sources = [XR_FACE_TRACKING_DATA_SOURCE2_VISUAL_FB, XR_FACE_TRACKING_DATA_SOURCE2_AUDIO_FB]
        var made: XrFaceTracker2FB?
        let result = sources.withUnsafeMutableBufferPointer { wanted -> XrResult in
            info.requestedDataSourceCount = UInt32(wanted.count)
            info.requestedDataSources = wanted.baseAddress
            return create(session, &info, &made)
        }
        guard result.rawValue >= 0, made != nil else {
            log("openxr: face tracking not available (\(XRFailure.name(of: result)))")
            return nil
        }
        tracker = made
        self.read = read
        destroy = try? instance.function("xrDestroyFaceTracker2FB", as: PFN_xrDestroyFaceTracker2FB.self)
        self.log = log
        log("openxr: face tracking available (XR_FB_face_tracking2)")
    }

    deinit {
        if let tracker { _ = destroy?(tracker) }
    }

    func update(at time: XrTime) {
        var which = XrFaceExpressionInfo2FB()
        which.type = XR_TYPE_FACE_EXPRESSION_INFO2_FB
        which.time = time
        var weights = [Float](repeating: 0, count: Int(XR_FACE_EXPRESSION2_COUNT_FB.rawValue))
        var confidences = [Float](repeating: 0, count: Int(XR_FACE_CONFIDENCE2_COUNT_FB.rawValue))
        var state = XrFaceExpressionWeights2FB()
        state.type = XR_TYPE_FACE_EXPRESSION_WEIGHTS2_FB
        let result = weights.withUnsafeMutableBufferPointer { all in
            confidences.withUnsafeMutableBufferPointer { both -> XrResult in
                state.weightCount = UInt32(all.count)
                state.weights = all.baseAddress
                state.confidenceCount = UInt32(both.count)
                state.confidences = both.baseAddress
                return read(tracker, &which, &state)
            }
        }
        var face: FaceExpressions?
        if result.rawValue >= 0, state.isValid != 0, weights.count == FaceExpressions.weightCount {
            face = FaceExpressions(weights: weights.map { max(0, min(1, $0)) }, lowerFaceConfidence: confidences[0],
                                   upperFaceConfidence: confidences[1])
        }
        let answer = result.rawValue < 0 ? "failed with \(XRFailure.name(of: result))"
            : "\(state.isValid != 0 ? "valid" : "not valid"), from \(state.dataSource == XR_FACE_TRACKING_DATA_SOURCE2_AUDIO_FB ? "the microphone" : "the cameras")"
        if noted != answer {
            noted = answer
            log("openxr: face tracking \(face != nil ? "active" : "inactive") (\(answer))")
        }
        lock.lock()
        latest = face
        lock.unlock()
    }

    var needsCalibration: Bool { false }

    func expressions() -> FaceExpressions? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

/// Reads face blendshape weights from `XR_ANDROID_face_tracking` and maps them to `FaceExpressions`.
///
/// The first 63 parameters of `XR_ANDROID_face_tracking` match `XR_FB_face_tracking2` (used by `FaceExpressions`),
/// and `TONGUE_OUT` maps to index 68. On Android XR, `android.permission.FACE_TRACKING` must be granted before
/// creating the OpenXR instance.
final class XRFace: FaceSource {
    private let instance: XRInstance
    private var tracker: XrFaceTrackerANDROID?
    private let read: PFN_xrGetFaceStateANDROID
    private let destroy: PFN_xrDestroyFaceTrackerANDROID?
    private let log: (String) -> Void
    private let lock = NSLock()
    private var latest: FaceExpressions?
    private var uncalibrated = false
    private var noted: String?
    private let calibrated: PFN_xrGetFaceCalibrationStateANDROID?

    /// Blendshape index for tongue extension in `XR_FB_face_tracking2`.
    private static let tongueOut = 68

    /// Creates an Android face tracker if `XR_ANDROID_face_tracking` is enabled and supported by the runtime.
    init?(instance: XRInstance, session: XrSession, log: @escaping (String) -> Void) {
        guard instance.extensions.contains(XR_ANDROID_FACE_TRACKING_EXTENSION_NAME),
              let create = try? instance.function("xrCreateFaceTrackerANDROID", as: PFN_xrCreateFaceTrackerANDROID.self),
              let read = try? instance.function("xrGetFaceStateANDROID", as: PFN_xrGetFaceStateANDROID.self)
        else { return nil }
        var info = XrFaceTrackerCreateInfoANDROID()
        info.type = XR_TYPE_FACE_TRACKER_CREATE_INFO_ANDROID
        var made: XrFaceTrackerANDROID?
        let result = create(session, &info, &made)
        guard result.rawValue >= 0, made != nil else {
            log("openxr: face tracking not available (\(XRFailure.name(of: result)))")
            return nil
        }
        self.instance = instance
        tracker = made
        self.read = read
        destroy = try? instance.function("xrDestroyFaceTrackerANDROID", as: PFN_xrDestroyFaceTrackerANDROID.self)
        calibrated = try? instance.function("xrGetFaceCalibrationStateANDROID", as: PFN_xrGetFaceCalibrationStateANDROID.self)
        self.log = log
        log("openxr: face tracking available")
    }

    deinit {
        if let tracker { _ = destroy?(tracker) }
    }

    /// Samples face expression weights for `time`. Called once per frame on the render thread.
    func update(at time: XrTime) {
        var which = XrFaceStateGetInfoANDROID()
        which.type = XR_TYPE_FACE_STATE_GET_INFO_ANDROID
        which.time = time
        var parameters = [Float](repeating: 0, count: Int(XR_FACE_PARAMETER_COUNT_ANDROID))
        var confidences = [Float](repeating: 0, count: Int(XR_FACE_REGION_CONFIDENCE_COUNT_ANDROID))
        var state = XrFaceStateANDROID()
        state.type = XR_TYPE_FACE_STATE_ANDROID
        let result = parameters.withUnsafeMutableBufferPointer { weights in
            confidences.withUnsafeMutableBufferPointer { regions -> XrResult in
                state.parametersCapacityInput = UInt32(weights.count)
                state.parameters = weights.baseAddress
                state.regionConfidencesCapacityInput = UInt32(regions.count)
                state.regionConfidences = regions.baseAddress
                return read(tracker, &which, &state)
            }
        }
        var face: FaceExpressions?
        if result.rawValue >= 0, state.isValid != 0, state.faceTrackingState == XR_FACE_TRACKING_STATE_TRACKING_ANDROID {
            var weights = [Float](repeating: 0, count: FaceExpressions.weightCount)
            let shared = Int(XR_FACE_PARAMETER_INDICES_UPPER_LIP_RAISER_R_ANDROID.rawValue)
            for index in 0...shared { weights[index] = max(0, min(1, parameters[index])) }
            weights[XRFace.tongueOut] = max(0, min(1, parameters[Int(XR_FACE_PARAMETER_INDICES_TONGUE_OUT_ANDROID.rawValue)]))
            // Default confidence to 1.0 if the runtime omits per-region confidence values.
            let given = state.regionConfidencesCountOutput >= 3
            face = FaceExpressions(weights: weights, lowerFaceConfidence: given ? confidences[0] : 1,
                                   upperFaceConfidence: given ? (confidences[1] + confidences[2]) / 2 : 1)
        }
        // Log tracking and calibration state transitions so uncalibrated face trackers are easy to diagnose.
        var isCalibrated: XrBool32 = 0
        let asked = calibrated.map { $0(tracker, &isCalibrated).rawValue >= 0 } ?? false
        let states = [XR_FACE_TRACKING_STATE_PAUSED_ANDROID: "paused", XR_FACE_TRACKING_STATE_STOPPED_ANDROID: "stopped",
                      XR_FACE_TRACKING_STATE_TRACKING_ANDROID: "tracking"]
        let answer = result.rawValue < 0 ? "failed with \(XRFailure.name(of: result))"
            : "\(states[state.faceTrackingState] ?? "state \(state.faceTrackingState.rawValue)"), \(state.isValid != 0 ? "valid" : "not valid"), "
                + "\(state.parametersCountOutput) parameters, \(asked ? (isCalibrated != 0 ? "calibrated" : "not calibrated") : "calibration unknown")"
        if noted != answer {
            noted = answer
            log("openxr: face tracking \(face != nil ? "active" : "inactive") (\(answer))")
        }
        lock.lock()
        latest = face
        uncalibrated = asked && isCalibrated == 0
        lock.unlock()
    }

    /// Whether the runtime reports that system face calibration has not been completed. Thread-safe.
    var needsCalibration: Bool {
        lock.lock()
        defer { lock.unlock() }
        return uncalibrated
    }

    /// Latest face expression weights, or `nil` while untracked. Thread-safe.
    func expressions() -> FaceExpressions? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}
