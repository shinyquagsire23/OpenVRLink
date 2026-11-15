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

/// Observable state for an active or completed gaze calibration run, displayed in the Experiments tab.
public final class GazeCalibrationRun: ObservableObject {
    public init() {}
    /// Whether the calibration space is open.
    @Published public var open = false
    @Published public var status = ""
    /// True once all calibration targets have been completed.
    @Published public var finished = false
}

/// Runs gaze calibration in a dedicated immersive space.
///
/// Nineteen target dots float 1.5 m in front of the user and stay head-locked
/// so looking at each dot requires eye movement rather than head rotation.
/// The user looks at the highlighted dot and pinches. Because visionOS only
/// exposes an eye-gaze selection ray during an indirect pinch, each pinch ray
/// direction is paired with the pupil positions captured from the Persona
/// camera feed immediately beforehand. Once all targets are collected,
/// `GazeCalibrator` fits a model and saves the result to settings.
///
/// Rendering uses RealityKit so the Persona camera anchor is positioned in
/// front of the face identically to the RealityKit streaming renderer, keeping
/// camera perspective consistent between calibration and streaming.
@MainActor
public final class GazeCalibrationSpace {
    private let head: HeadTracking
    private let persona: PersonaTracking
    private let store: SettingsStore
    private let run: GazeCalibrationRun

    /// Target positions as `(across, up)` tangents in head space, ordered from
    /// center outward through an inner ring and the outer comfortable gaze bounds.
    private static let targets: [(across: Float, up: Float)] = [
        (0, 0), (-0.25, 0.15), (0.25, 0.15), (0.25, -0.15), (-0.25, -0.15),
        (-0.5, 0), (0.5, 0), (0, 0.3), (0, -0.3),
        (-0.5, 0.3), (0.5, 0.3), (0.5, -0.3), (-0.5, -0.3),
        // Extra vertical intermediate points where vertical pupil motion has less signal.
        (0, 0.15), (0, -0.15), (-0.5, 0.15), (0.5, 0.15), (0.5, -0.15), (-0.5, -0.15),
    ]
    private static let distance: Float = 1.5
    /// Maximum tangent distance between the pinch ray and the active target dot (about 8 degrees).
    private static let closeEnough: Float = 0.14

    private var calibrator = GazeCalibrator()
    private var current = 0
    private var pinchesInProgress: Set<SpatialEventCollection.Event.ID> = []
    private var dots: [ModelEntity] = []
    private var personaCamera: Entity?
    private var updates: EventSubscription?
    private var ticks = 0
    private var lastPlacementNote: TimeInterval = 0
    /// Callbacks provided by the view to dismiss this immersive space and reopen the main window.
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
        // Place an invisible collision plane behind the dots because visionOS only
        // reports indirect pinches when the gaze ray hits an input target entity.
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

    /// Cleans up when the immersive space closes. Stopping early leaves any
    /// previously saved calibration unchanged.
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

    /// Updates dot colors and scales: large white for the active target, green
    /// for completed targets, and dim gray for upcoming ones. Because the main
    /// window is hidden during calibration, rejected pinches flash the active
    /// dot briefly with `refused` (orange if gaze missed the dot, red if no
    /// face was detected).
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

    /// Processes spatial pinch events, using `toWorld` to convert points from gesture space to scene space.
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
            // Gesture coordinates are in SwiftUI points (sub-millimeter), so
            // converting two points along the ray yields a very short vector
            // that must be re-normalized.
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
            // Sample slightly before the pinch since the user's gaze settles
            // before their fingers meet and the Persona camera feed has slight latency.
            guard let features = persona.camera.eyeFeatures(from: now - 0.4, to: now - 0.03) else {
                show("Your Persona's face was not in view; pinch again (\(current + 1) of \(dots.count))")
                colorDots(refused: (1, 0, 0))
                continue
            }
            Log.note(String(format: "calibration: pupils %.3f across, %.3f down, %.3f below the corners, lids %.3f open",
                            features.across, features.down, features.belowCorners, features.open))
            // Fit against the measured gaze ray direction rather than the nominal dot position.
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
    /// Stored without `@ObservedObject` so SwiftUI does not re-evaluate this
    /// view while the space is open; re-evaluation can recreate attachment
    /// entities and leave the Persona camera bound to a stale entity.
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
        // If an app window stays open, visionOS locks the Persona camera to
        // that window and ignores this space's camera anchor. Dismiss the
        // main window once the space opens and reopen it when calibration stops.
        .task { dismissWindow(id: "entry") }
    }
}
#endif
