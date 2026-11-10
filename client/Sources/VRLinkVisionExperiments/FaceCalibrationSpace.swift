// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import AVKit
import QuartzCore
import RealityKit
import SwiftUI
import VRLinkCore
import VRLinkAppleSession
import VRLinkVisionTracking
import simd

/// What the face calibration is asking for, shown in its space and (when it
/// is over) in the Experiments tab.
public final class FaceCalibrationRun: ObservableObject {
    public init() {}
    @Published public var open = false
    /// The instruction of the moment, in large type.
    @Published public var prompt = ""
    /// Smaller: progress, or what went wrong.
    @Published public var status = ""
    @Published public var finished = false
}

/// The face calibration, as an immersive space of its own.
///
/// A panel in front of the wearer shows their Persona as the camera sees
/// it and asks for one expression after another (`FacePose`). Each is
/// counted in, then the face's measurements are averaged for a little over
/// a second. From the set a `FaceCalibration` is made and saved in the
/// settings; a run that is abandoned changes nothing.
///
/// It is drawn with RealityKit and arranged like the stream's space, so
/// that the Persona's camera is in front of the face here too.
@MainActor
public final class FaceCalibrationSpace {
    private let head: HeadTracking
    private let persona: PersonaTracking
    private let store: SettingsStore
    private let run: FaceCalibrationRun
    private var personaCamera: Entity?
    private var updates: EventSubscription?
    private var sequence: Task<Void, Never>?
    private var ticks = 0
    public private(set) var stopped = false
    var closeSpace: (() async -> Void)?
    var reopenWindow: (() -> Void)?

    public init(head: HeadTracking, persona: PersonaTracking, store: SettingsStore, run: FaceCalibrationRun) {
        self.head = head
        self.persona = persona
        self.store = store
        self.run = run
    }

    func setup(_ content: inout RealityViewContent, attachments: RealityViewAttachments) {
        run.finished = false
        run.open = true
        personaCamera = PersonaAttachments.add(to: &content, from: attachments, settings: store.settings)
        // The panel goes a meter and a half in front of wherever the wearer
        // is facing now, upright, turned to face them.
        if let panel = attachments.entity(for: PersonaAttachments.cameraView),
           let device = head.anchor(at: CACurrentMediaTime()) {
            let m = device.originFromAnchorTransform
            var ahead = SIMD3<Float>(-m.columns.2.x, 0, -m.columns.2.z)          // level
            ahead = simd_length(ahead) > 0.01 ? simd_normalize(ahead) : [0, 0, -1]
            let at = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z) + ahead * 1.5
            panel.position = [at.x, at.y - 0.1, at.z]
            panel.orientation = simd_quatf(from: [0, 0, 1], to: -ahead)
        }
        updates = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.everyFrame() }
        }
        sequence = Task { [weak self] in await self?.askForEachPose() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        sequence?.cancel()
        updates?.cancel()
        updates = nil
        if !run.finished {
            run.status = store.settings.faceCalibration == nil ? "Calibration stopped early"
                                                               : "Calibration stopped early; the earlier one is kept"
        }
        run.prompt = ""
        run.open = false
        persona.leave()
        reopenWindow?()
    }

    private func everyFrame() {
        ticks += 1
        guard let personaCamera, let device = head.anchor(at: CACurrentMediaTime()) else { return }
        placePersonaCameraEntity(personaCamera, originFromDevice: device.originFromAnchorTransform, tick: ticks)
    }

    private func pause(_ seconds: Double) async -> Bool {
        (try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))) != nil && !stopped
    }

    private func askForEachPose() async {
        run.prompt = "Get ready"
        run.status = "You will be asked for nine expressions; hold each until the next appears"
        guard await pause(3) else { return }
        var recorded: [FacePose: FaceMeasures] = [:]
        let poses = FacePose.allCases
        for (number, pose) in poses.enumerated() {
            var tries = 0
            while recorded[pose] == nil {
                tries += 1
                run.prompt = pose.prompt
                for count in [3, 2, 1] {
                    run.status = "\(number + 1) of \(poses.count): in \(count)"
                    guard await pause(1) else { return }
                }
                run.status = "\(number + 1) of \(poses.count): hold it"
                let began = CACurrentMediaTime()
                // Longer with the eyes shut, since nobody can see when to stop.
                guard await pause(pose == .eyesClosed ? 2.6 : 1.6) else { return }
                // The first moments are the face still getting there.
                if let measures = persona.camera.faceMeasures(from: began + 0.4, to: CACurrentMediaTime()) {
                    recorded[pose] = measures
                    Log.note(String(format: "face calibration: %@: mouth open %.3f wide %.3f, corners %.3f %.3f, brows %.3f %.3f, eyes %.3f %.3f",
                                    pose.rawValue, measures.mouthOpen, measures.mouthWidth, measures.cornerDropL, measures.cornerDropR,
                                    measures.browLiftL, measures.browLiftR, measures.eyeOpenL, measures.eyeOpenR))
                } else if tries >= 3 {
                    run.prompt = "Your Persona's face could not be seen"
                    run.status = "The calibration was not changed"
                    Log.note("face calibration: gave up at \(pose.rawValue): no face in the pictures")
                    _ = await pause(3)
                    await closeSpace?()
                    return
                } else {
                    run.prompt = "Your face was not seen; once more"
                    guard await pause(1.5) else { return }
                }
            }
        }
        store.settings.faceCalibration = FaceCalibration(poses: recorded)
        run.prompt = "Done"
        run.status = "Face calibrated"
        run.finished = true
        Log.note("face calibration: saved")
        _ = await pause(2)
        await closeSpace?()
    }
}

public struct FaceCalibrationView: View {
    let space: FaceCalibrationSpace
    /// Not observed here (see `GazeCalibrationView`); the panel observes it.
    let run: FaceCalibrationRun
    let persona: PersonaTracking
    let settings: VRLinkCore.Settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    public init(space: FaceCalibrationSpace, run: FaceCalibrationRun, persona: PersonaTracking, settings: VRLinkCore.Settings) {
        self.space = space
        self.run = run
        self.persona = persona
        self.settings = settings
    }

    public var body: some View {
        RealityView { content, attachments in
            space.closeSpace = { await dismissImmersiveSpace() }
            space.reopenWindow = { openWindow(id: "entry") }
            space.setup(&content, attachments: attachments)
        } update: { _, _ in
        } attachments: {
            Attachment(id: PersonaAttachments.anchor) {
                Text("").cameraAnchor(isActive: true)
            }
            Attachment(id: PersonaAttachments.cameraView) {
                // The rules of thumb, not an earlier calibration, while measuring.
                PersonaCameraView(persona: persona, wanted: settings.faceFromCamera, showPicture: true,
                                  faceCalibration: nil, asking: run)
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background { space.stop() }
        }
        .onDisappear { space.stop() }
        .task { dismissWindow(id: "entry") }
    }
}
#endif
