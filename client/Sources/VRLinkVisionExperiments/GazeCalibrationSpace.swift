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

/// What the Experiments tab shows of a calibration in progress.
public final class GazeCalibrationRun: ObservableObject {
    public init() {}
    /// Whether the calibration space is open.
    @Published public var open = false
    @Published public var status = ""
    /// Set when the last dot has been done.
    @Published public var finished = false
}

/// The gaze calibration, as an immersive space of its own.
///
/// Nineteen dots float 1.5 m in front of the face and turn with the head,
/// so that looking at each one turns the eyes, not the head. The wearer
/// looks at the bright one and pinches. visionOS reports the pinch with a
/// ray from the eyes to what they were looking at, which is the one moment
/// it says where the eyes look; the pupil positions seen in the Persona's
/// picture just before are paired with that ray's direction. After the
/// last dot the pairs are fitted (`GazeCalibrator`) and the fit is saved in
/// the settings.
///
/// It is drawn with RealityKit, so that the Persona's camera is held in
/// front of the face here exactly as it is by the RealityKit renderer
/// while streaming: the pupils are then seen from the same place in both.
@MainActor
public final class GazeCalibrationSpace {
    private let head: HeadTracking
    private let persona: PersonaTracking
    private let store: SettingsStore
    private let run: GazeCalibrationRun

    /// Where the dots are, as tangents in the head's frame (across, up): the
    /// middle first, then a ring, then the corners and edges of the area
    /// the eyes comfortably reach.
    private static let targets: [(across: Float, up: Float)] = [
        (0, 0), (-0.25, 0.15), (0.25, 0.15), (0.25, -0.15), (-0.25, -0.15),
        (-0.5, 0), (0.5, 0), (0, 0.3), (0, -0.3),
        (-0.5, 0.3), (0.5, 0.3), (0.5, -0.3), (-0.5, -0.3),
        // More between top and bottom, where the pupils say least.
        (0, 0.15), (0, -0.15), (-0.5, 0.15), (0.5, 0.15), (0.5, -0.15), (-0.5, -0.15),
    ]
    private static let distance: Float = 1.5
    /// A pinch counts for the bright dot when its ray passes this close to it (tangent; about 8 degrees).
    private static let closeEnough: Float = 0.14

    private var calibrator = GazeCalibrator()
    private var current = 0
    private var pinchesInProgress: Set<SpatialEventCollection.Event.ID> = []
    private var dots: [ModelEntity] = []
    private var personaCamera: Entity?
    private var updates: EventSubscription?
    private var ticks = 0
    private var lastPlacementNote: TimeInterval = 0
    /// Set by the view: how to close this space and how to bring the app's window back.
    var closeSpace: (() async -> Void)?
    var reopenWindow: (() -> Void)?
    public private(set) var stopped = false

    public init(head: HeadTracking, persona: PersonaTracking, store: SettingsStore, run: GazeCalibrationRun) {
        self.head = head
        self.persona = persona
        self.store = store
        self.run = run
    }

    private static func material(_ red: Float, _ green: Float, _ blue: Float) -> UnlitMaterial {
        UnlitMaterial(color: .init(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1))
    }

    func setup(_ content: inout RealityViewContent, attachments: RealityViewAttachments) {
        run.finished = false
        run.open = true
        personaCamera = PersonaAttachments.add(to: &content, from: attachments, settings: store.settings)
        // Everything else turns with the head.
        let headAnchor = AnchorEntity(.head)
        headAnchor.anchoring.trackingMode = .continuous
        let d = GazeCalibrationSpace.distance
        for target in GazeCalibrationSpace.targets {
            let dot = ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [GazeCalibrationSpace.material(0.15, 0.15, 0.15)])
            dot.position = [target.across * d, target.up * d, -d]
            headAnchor.addChild(dot)
            dots.append(dot)
        }
        // Pinches are only reported if the eyes' ray hits something that
        // takes input: an unseen sheet just behind the dots.
        var unseen = UnlitMaterial(color: .init(red: 0, green: 0, blue: 0, alpha: 0))
        unseen.blending = .transparent(opacity: 0.0)
        unseen.writesDepth = false
        let sheet = MeshResource.generatePlane(width: 1, depth: 1)
        let catcher = ModelEntity(mesh: sheet, materials: [unseen])
        catcher.components.set(InputTargetComponent())
        catcher.components.set(CollisionComponent(shapes: [ShapeResource.generateBox(width: 1, height: 0.01, depth: 1)]))
        catcher.position = [0, 0, -(d + 0.1)]
        catcher.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        catcher.scale = [8, 8, 8]
        headAnchor.addChild(catcher)
        content.add(headAnchor)

        updates = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.everyFrame() }
        }
        colorDots()
        show("Look at the bright dot and pinch (1 of \(dots.count))")
    }

    /// The space has gone, finished or not. An unfinished calibration
    /// changes nothing: the one saved before stays.
    func stop() {
        guard !stopped else { return }
        stopped = true
        updates?.cancel()
        updates = nil
        if !run.finished {
            show(store.settings.gazeCalibration == nil ? "Calibration stopped before the last dot"
                                                       : "Calibration stopped before the last dot; the earlier one is kept")
        }
        run.open = false
        persona.leave()
        reopenWindow?()
    }

    private func everyFrame() {
        ticks += 1
        let now = CACurrentMediaTime()
        guard let personaCamera, let device = head.anchor(at: now) else {
            if now - lastPlacementNote > 5 {
                lastPlacementNote = now
                Log.note("calibration: cannot place the Persona's camera (\(personaCamera == nil ? "no entity for it" : "no head pose"))")
            }
            return
        }
        placePersonaCameraEntity(personaCamera, originFromDevice: device.originFromAnchorTransform, tick: ticks)
        if now - lastPlacementNote > 5 {
            lastPlacementNote = now
            let at = personaCamera.position, headAt = device.originFromAnchorTransform.columns.3
            Log.note(String(format: "calibration: Persona camera at (%.2f, %.2f, %.2f), head at (%.2f, %.2f, %.2f), in a scene: %@",
                            at.x, at.y, at.z, headAt.x, headAt.y, headAt.z, personaCamera.scene == nil ? "no" : "yes"))
        }
    }

    /// Bright and larger for the one to look at; green once done; dim for
    /// those to come. There is no room for words in the space (the app's
    /// window is away), so a refused pinch shows as the bright dot turning
    /// `refused` for a moment: orange for "you were not looking at it", red
    /// for "your face was not seen".
    private func colorDots(refused: (Float, Float, Float)? = nil) {
        if refused != nil {
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                colorDots()
            }
        }
        for (number, dot) in dots.enumerated() {
            dot.model?.materials = [number == current ? GazeCalibrationSpace.material(refused?.0 ?? 1, refused?.1 ?? 1, refused?.2 ?? 1)
                                    : number < current ? GazeCalibrationSpace.material(0.1, 0.6, 0.1)
                                    : GazeCalibrationSpace.material(0.15, 0.15, 0.15)]
            dot.scale = number == current ? [1.8, 1.8, 1.8] : [1, 1, 1]
        }
    }

    private func show(_ text: String) {
        Log.note("calibration: \(text)")
        run.status = text
    }

    /// Pinches, with `toWorld` to bring a point from the gesture's coordinates into the scene's.
    func pinched(_ events: SpatialEventCollection, toWorld: (Point3D) -> SIMD3<Float>) {
        let now = CACurrentMediaTime()
        for event in events where event.kind == .indirectPinch {
            // A hand keeps the same event id from one pinch to the next, so
            // an id is only "in progress" until its pinch ends.
            if event.phase != .active { pinchesInProgress.remove(event.id) }
            guard event.phase == .active, pinchesInProgress.insert(event.id).inserted, current < dots.count
            else { continue }
            guard let ray = event.selectionRay, let device = head.anchor(at: now) else {
                Log.note("calibration: a pinch came without \(event.selectionRay == nil ? "a ray" : "a head pose")")
                continue
            }
            // The gesture's coordinates are SwiftUI's, where one unit is a
            // point (well under a millimeter): the ray's direction, taken
            // as the difference of two converted points, comes out tiny and
            // has to be made a unit vector again.
            let from = toWorld(ray.origin)
            let towards = simd_normalize(toWorld(ray.origin + ray.direction) - from)
            let headPose = HeadTracking.pose(device.originFromAnchorTransform)
            guard let looked = GazeCalibrator.tangents(ofRay: Vec3(towards.x, towards.y, towards.z), head: headPose)
            else {
                Log.note("calibration: a pinch's ray did not point ahead of the head")
                continue
            }
            let target = GazeCalibrationSpace.targets[current]
            let miss = ((looked.across - target.across) * (looked.across - target.across)
                        + (looked.up - target.up) * (looked.up - target.up)).squareRoot()
            Log.note(String(format: "calibration: pinch looking %.2f across, %.2f up; the dot is at %.2f, %.2f",
                            looked.across, looked.up, target.across, target.up))
            guard miss < GazeCalibrationSpace.closeEnough else {
                show("Look at the bright dot while you pinch (\(current + 1) of \(dots.count))")
                colorDots(refused: (1, 0.5, 0))
                continue
            }
            // The eyes were on the dot for a moment before the fingers met,
            // and the Persona's picture runs a little behind.
            guard let features = persona.camera.eyeFeatures(from: now - 0.4, to: now - 0.03) else {
                show("Your Persona's face was not in view; pinch again (\(current + 1) of \(dots.count))")
                colorDots(refused: (1, 0, 0))
                continue
            }
            Log.note(String(format: "calibration: pupils %.3f across, %.3f down, %.3f below the corners, lids %.3f open",
                            features.across, features.down, features.belowCorners, features.open))
            // The ray, not the dot, is where the eyes really were.
            calibrator.add(features, across: looked.across, up: looked.up)
            current += 1
            colorDots()
            guard current >= dots.count else {
                show("Look at the bright dot and pinch (\(current + 1) of \(dots.count))")
                continue
            }
            if let fit = calibrator.fit() {
                show(String(format: "Calibrated: typically %.1f degrees off on its own samples", fit.typicalErrorDegrees))
                store.settings.gazeCalibration = fit
            } else {
                show("The samples could not be fitted; the calibration was not changed")
            }
            run.finished = true
            Task {
                try? await Task.sleep(for: .seconds(2))          // long enough to read the result
                await closeSpace?()
            }
        }
    }
}

public struct GazeCalibrationView: View {
    let space: GazeCalibrationSpace
    /// Not observed here: this view must not be evaluated again while the
    /// space is open, or SwiftUI may make the attachments' entities afresh
    /// and leave the Persona's camera on one that is no longer being moved.
    let run: GazeCalibrationRun
    let persona: PersonaTracking
    let settings: VRLinkCore.Settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    public init(space: GazeCalibrationSpace, run: GazeCalibrationRun, persona: PersonaTracking, settings: VRLinkCore.Settings) {
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
                PersonaCameraView(persona: persona, wanted: settings.faceFromCamera, showPicture: settings.showFaceCameraPicture,
                                  faceCalibration: settings.faceCalibration)
            }
        }
        .gesture(SpatialEventGesture(coordinateSpace: .local).targetedToAnyEntity()
            .onChanged { value in space.pinched(value.gestureValue) { value.convert($0, from: .local, to: .scene) } }
            .onEnded { value in space.pinched(value.gestureValue) { value.convert($0, from: .local, to: .scene) } })
        // The space can be dismissed from outside the app (the crown).
        .onChange(of: scenePhase) {
            if scenePhase == .background { space.stop() }
        }
        .onDisappear { space.stop() }
        // While a window of the app is open the Persona's camera stays at
        // it, whatever anchor this space offers: the window is put away for
        // the calibration (a moment after the space is up) and brought back
        // when it ends, finished or not.
        .task { dismissWindow(id: "entry") }
    }
}
#endif
