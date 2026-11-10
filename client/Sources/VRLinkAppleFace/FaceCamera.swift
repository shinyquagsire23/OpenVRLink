// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import Foundation
import QuartzCore
import VRLinkCore
import Vision

/// Face tracking from a camera that looks at the wearer's face.
///
/// On visionOS this uses Spatial Persona. This class runs Apple's landmark detector on the feed
/// and then hands the points to the core's `FaceEstimator`. 
/// On a Mac it does the same but with the real camera.
public final class FaceCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private let setup = DispatchQueue(label: "FaceCamera setup")
    private let pictures = DispatchQueue(label: "FaceCamera pictures", qos: .userInitiated)
    private let detector = VNSequenceRequestHandler()
    private var estimator = FaceEstimator()

    private let lock = NSLock()
    private var newest: (estimate: FaceEstimate, time: TimeInterval)?
    /// Recent eye features with their times, for interpolation
    private var history: [(features: EyeFeatures, measures: FaceMeasures, blinking: Bool, time: TimeInterval)] = []
    private var calibration: FaceCalibration?
    private var smoother = FaceSmoother()

    /// in meters
    private var faceIPD: Float = 0.063

    private var running = false
    private var lastPicture: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    // For the once-in-a-while log lines
    private var picturesSeen = 0, facesSeen = 0, lastReport: TimeInterval = 0
    private var pictureSize = (width: 0, height: 0)

    /// Face debug helpers
    public var onPicture: ((CVPixelBuffer, [(name: String, points: [LandmarkPoint])]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return pictureWatcher }
        set { lock.lock(); pictureWatcher = newValue; lock.unlock() }
    }
    private var pictureWatcher: ((CVPixelBuffer, [(name: String, points: [LandmarkPoint])]) -> Void)?

    /// Don't give estimates if the picture is older than this
    public static let faceStaleMaximum: TimeInterval = 0.5

    public override init() { super.init() }

    /// Set the user's IPD, to convert from image space to world space in meters
    public func setIPD(_ meters: Float) {
        lock.lock()
        if meters > 0.04, meters < 0.09 { faceIPD = meters }
        lock.unlock()
    }

    /// Start the camera, with a capture session made for the occasion; any
    /// earlier one is thrown away.
    ///
    /// On visionOS, call this when an immersive space that carries the
    /// Persona camera's anchor has just opened and the app's window is
    /// still open (the system only starts the Persona's camera for an app
    /// with a window), then close the window once `lastPictureTime` shows
    /// pictures arriving: the camera moves to the space's anchor. A session
    /// kept from one space to the next did not make that move again. (The
    /// ALVR visionOS client makes its session inside its space's view, anew
    /// every time, which comes to the same.)
    public func start() {
        lock.lock()
        running = true
        lock.unlock()
        AVCaptureDevice.requestAccess(for: .video) { [self] allowed in
            guard allowed else {
                Log.note("FaceCamera: the camera is not permitted")
                lock.lock()
                running = false
                lock.unlock()
                return
            }
            setup.async { [self] in
                tearDown()
                lock.lock()
                let wanted = running
                lock.unlock()
                guard wanted else { return }
                let camera: AVCaptureDevice?
                if #available(visionOS 2.1, *) {
                    camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                        ?? AVCaptureDevice.default(for: .video)
                } else {
                    camera = AVCaptureDevice.systemPreferredCamera
                }
                let session = AVCaptureSession()
                guard let camera, let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
                    Log.note("FaceCamera: no camera to use")
                    return
                }
                session.beginConfiguration()
                session.addInput(input)
                // Find the highest resolution to get the most accuracy
                if #available(visionOS 2.1, *) {
                    let largest = camera.formats.max {
                        let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                        let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                        return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
                    }
                    let sizes = camera.formats.map { format -> String in
                        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        return "\(d.width)x\(d.height)"
                    }
                    Log.note("FaceCamera: offers \(sizes.joined(separator: ", "))")
                    if let largest, (try? camera.lockForConfiguration()) != nil {
                        camera.activeFormat = largest
                        camera.unlockForConfiguration()
                    }
                }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: pictures)
                if session.canAddOutput(output) { session.addOutput(output) }
                // Mirror so that left and right are user-relative instead of viewer-relative
                if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                    #if os(macOS)
                    connection.automaticallyAdjustsVideoMirroring = false
                    #endif
                    connection.isVideoMirrored = true
                }
                session.commitConfiguration()
                // What the system does to the session, for the log.
                let center = NotificationCenter.default
                observers = [
                    center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { note in
                        #if os(macOS)
                        let reason = "unknown"
                        #else
                        let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey].map { "\($0)" } ?? "unknown"
                        #endif
                        Log.note("FaceCamera: interrupted by the system (reason \(reason))")
                    },
                    center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in
                        Log.note("FaceCamera: interruption over")
                    },
                    center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
                        Log.note("FaceCamera: error \(note.userInfo?[AVCaptureSessionErrorKey] ?? "unknown")")
                    },
                ]
                self.session = session
                session.startRunning()
                Log.note("FaceCamera: started, using \(camera.localizedName)")
            }
        }
    }

    /// On the setup queue: stop and forget the current session.
    private func tearDown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let session {
            if session.isRunning { session.stopRunning() }
            self.session = nil
        }
    }

    /// When the newest picture arrived, on the `CACurrentMediaTime` clock; 0 before the first.
    public var lastPictureTime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return lastPicture
    }

    public func stop() {
        lock.lock()
        running = false
        newest = nil
        history = []
        lock.unlock()
        setup.async { [self] in tearDown() }
    }

    /// Get the current face estimate
    public func estimate() -> FaceEstimate? {
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        guard let newest, now - newest.time < FaceCamera.faceStaleMaximum else { return nil }
        return newest.estimate
    }

    /// Get or set the user's current face calibration, if it exists
    public var faceCalibration: FaceCalibration? {
        get { lock.lock(); defer { lock.unlock() }; return calibration }
        set { lock.lock(); calibration = newValue; lock.unlock() }
    }

    /// The face's measurements averaged over a stretch of time, for recording a calibration pose.
    /// Returns nil if the face was seen fewer than five times
    public func faceMeasures(from start: TimeInterval, to end: TimeInterval) -> FaceMeasures? {
        lock.lock()
        let wanted = history.filter { $0.time >= start && $0.time <= end }.map(\.measures)
        lock.unlock()
        return wanted.count >= 5 ? FaceMeasures.average(wanted) : nil
    }

    /// The eye features averaged over a stretch of time (on the
    /// `CACurrentMediaTime` clock), leaving out blinks; nil if the face was
    /// not seen with open eyes at least twice in it.
    public func eyeFeatures(from start: TimeInterval, to end: TimeInterval) -> EyeFeatures? {
        lock.lock()
        let wanted = history.filter { $0.time >= start && $0.time <= end && !$0.blinking }.map(\.features)
        lock.unlock()
        return wanted.count >= 2 ? EyeFeatures.average(wanted) : nil
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let picture = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        lastPicture = now
        lock.unlock()
        picturesSeen += 1
        if pictureSize.width != CVPixelBufferGetWidth(picture) {
            pictureSize = (CVPixelBufferGetWidth(picture), CVPixelBufferGetHeight(picture))
            Log.note("FaceCamera: pictures are \(pictureSize.width)x\(pictureSize.height)")
        }
        let request = VNDetectFaceLandmarksRequest()
        try? detector.perform([request], on: picture, orientation: .up)
        if let watcher = onPicture {
            var groups: [(name: String, points: [LandmarkPoint])] = []
            if let face = request.results?.first, let found = face.landmarks {
                let box = face.boundingBox
                func inPicture(_ region: VNFaceLandmarkRegion2D?) -> [LandmarkPoint] {
                    (region?.normalizedPoints ?? []).map {
                        LandmarkPoint(Float(box.minX + $0.x * box.width), Float(box.minY + $0.y * box.height))
                    }
                }
                groups = [("eyes", inPicture(found.leftEye) + inPicture(found.rightEye)),
                          ("pupils", inPicture(found.leftPupil) + inPicture(found.rightPupil)),
                          ("brows", inPicture(found.leftEyebrow) + inPicture(found.rightEyebrow)),
                          ("lips", inPicture(found.outerLips) + inPicture(found.innerLips)),
                          ("nose", inPicture(found.noseCrest))]
            }
            watcher(picture, groups)
        }
        if let face = request.results?.first, let found = face.landmarks {
            func points(_ region: VNFaceLandmarkRegion2D?) -> [LandmarkPoint] {
                (region?.normalizedPoints ?? []).map { LandmarkPoint(Float($0.x), Float($0.y)) }
            }
            var landmarks = FaceLandmarks()
            landmarks.boxWidth = Float(face.boundingBox.width)
            landmarks.boxHeight = Float(face.boundingBox.height)
            landmarks.leftEye = points(found.leftEye); landmarks.rightEye = points(found.rightEye)
            landmarks.leftPupil = points(found.leftPupil); landmarks.rightPupil = points(found.rightPupil)
            landmarks.leftBrow = points(found.leftEyebrow); landmarks.rightBrow = points(found.rightEyebrow)
            landmarks.innerLips = points(found.innerLips); landmarks.outerLips = points(found.outerLips)
            landmarks.noseCrest = points(found.noseCrest); landmarks.medianLine = points(found.medianLine)
            lock.lock()
            let spacing = faceIPD
            lock.unlock()
            if var estimate = estimator.estimate(landmarks, eyeSpacing: spacing) {
                facesSeen += 1
                lock.lock()
                // The wearer's own ranges where there are any, then steadied.
                if let calibration, calibration.usable {
                    estimate.face.weights = calibration.weights(for: estimate.measures, fallback: estimate.face.weights)
                }
                estimate.face.weights = smoother.smooth(estimate.face.weights, seconds: now)
                newest = (estimate, now)
                history.append((estimate.eyes, estimate.measures, estimate.blinking, now))
                history.removeAll { now - $0.time > 3 }
                lock.unlock()
            }
        }
        if now - lastReport > 5 {
            if lastReport > 0 {
                Log.note(String(format: "FaceCamera: %.0f pictures/s, a face in %d of the last %d",
                                Double(picturesSeen) / (now - lastReport), facesSeen, picturesSeen))
            }
            lastReport = now
            picturesSeen = 0
            facesSeen = 0
        }
    }
}
