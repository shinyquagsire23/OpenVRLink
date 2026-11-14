// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import AVKit
import GameController
import Metal
import QuartzCore
import RealityKit
import SwiftUI
import VRLinkCore
import VRLinkVisionCompositor
import VRLinkAppleSession
import VRLinkVisionTracking
import VRLinkMetal
import VRLinkVideoToolbox
import simd

/// Experiment: the stream shown with RealityKit instead of a compositor layer.
///
/// It exists for one reason: RealityKit content can carry the view that
/// the Persona's camera sits at, so that camera can be kept in front of the
/// face (see `PersonaTracking`). The method is the ALVR visionOS client's:
///
/// - Each decoded frame is flattened by the ordinary quad renderer into one
///   texture, one eye above the other: for each eye, the base tile with the
///   foveal tile over it, exactly as the host's eye saw them.
/// - Each eye has a flat rectangle ("plane") far away in the world, placed
///   where that eye's picture belongs: it fills the host's frustum for that
///   eye as seen from where the host rendered. Its material shows its half
///   of the texture to its own eye and nothing to the other.
/// - There are three sets of texture and planes, used in turn, with only
///   the newest shown: a texture and the place of its planes then always
///   change together, never one a frame before the other.
///
/// Against the compositor layer this costs a second pass over every pixel
/// and loses the display's own foveation.
@MainActor
public final class RealityKitDisplay {
    private let connection: Connection
    private let head: HeadTracking
    private let settings: SettingsStore
    private let persona: PersonaTracking
    private let inputs: StreamInputs
    var pinches: PinchRays { inputs.pinches }

    private let device = MTLCreateSystemDefaultDevice()!
    private let queue: MTLCommandQueue
    private let renderer: QuadRenderer

    /// One texture and the two planes that show it.
    private struct PlaneSet {
        var texture: LowLevelTexture
        var planes: [ModelEntity]            // left eye, right eye
    }
    private var sets: [PlaneSet] = []
    private var materials: [ShaderGraphMaterial] = []      // left eye, right eye
    private let root = Entity()
    private var personaCamera: Entity?
    private var updates: EventSubscription?
    private var vsync: VsyncPrediction?
    private var eyeSize = (width: 0, height: 0)
    private var framesDrawn = 0, updatesSeen = 0
    /// Black, behind the planes, for a picture that is not keyed (`showBackdrop`).
    private var backdrop: ModelEntity?
    public private(set) var stopped = false

    /// How far away the planes stand, in meters, left then right. Far, so
    /// that everything else RealityKit draws is in front; not the same, so
    /// that the two do not fight over which is in front.
    private static let planeDistance: [Float] = [80, 70]
    /// The black behind the planes stands this far from the head, in
    /// meters, and is twenty times as wide: far more than the eyes see.
    private static let backdropDistance: Float = 90
    /// The flattened picture has this many pixels for each one of a tile,
    /// each way, so that the sharper foveal tile keeps most of its detail.
    private static let flattenScale = 1.6
    private static let largestSide = 3072

    public init?(inputs: StreamInputs, persona: PersonaTracking) {
        guard let queue = device.makeCommandQueue(),
              let renderer = QuadRenderer(device: device, colorFormat: .bgra8Unorm_srgb, linearOutput: true)
        else { return nil }
        self.inputs = inputs
        self.connection = inputs.connection
        self.head = inputs.head
        self.settings = inputs.settings
        self.persona = persona
        self.queue = queue
        self.renderer = renderer
    }

    /// Build the scene. `personaCamera` is the entity of the view the Persona's camera sits at.
    func setup(_ content: inout RealityViewContent, attachments: RealityViewAttachments) async {
        content.add(root)
        pinches.onGaze = { [persona, head, settings] direction in
            persona.learn(fromPinchLooking: direction, head: head.latestHead(), settings: settings.current)
        }
        personaCamera = PersonaAttachments.add(to: &content, from: attachments, settings: settings.current)

        // Pinches made at a distance are only reported if the eyes' ray
        // hits something that takes input: an unseen sheet that turns with the head.
        let headAnchor = AnchorEntity(.head)
        headAnchor.anchoring.trackingMode = .continuous
        var unseen = UnlitMaterial(color: .init(red: 0, green: 0, blue: 0, alpha: 0))
        unseen.blending = .transparent(opacity: 0.0)
        unseen.writesDepth = false
        let sheet = MeshResource.generatePlane(width: 1, depth: 1)
        let catcher = ModelEntity(mesh: sheet, materials: [unseen])
        catcher.components.set(InputTargetComponent())
        catcher.components.set(CollisionComponent(shapes: [ShapeResource.generateBox(width: 1, height: 0.01, depth: 1)]))
        catcher.position = [0, 0, -1.5]
        catcher.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        catcher.scale = [6, 6, 6]
        headAnchor.addChild(catcher)

        // Opaque, so it is drawn before the planes, which do not look at
        // depth and so are drawn over it though they are nearer.
        let black = ModelEntity(mesh: sheet, materials: [UnlitMaterial(color: .black)])
        black.position = [0, 0, -RealityKitDisplay.backdropDistance]
        black.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        black.scale = SIMD3(repeating: RealityKitDisplay.backdropDistance * 20)
        black.isEnabled = false
        headAnchor.addChild(black)
        backdrop = black
        content.add(headAnchor)

        do {
            for name in ["/Root/SBSMaterialBilinear_L", "/Root/SBSMaterialBilinear_R"] {
                var material = try await ShaderGraphMaterial(named: name, from: "SBSMaterial.usda", in: .module)
                material.readsDepth = false
                material.writesDepth = false
                materials.append(material)
            }
        } catch {
            Log.note("realitykit: the stereo material could not be loaded: \(error)")
        }
        vsync = VsyncPrediction()
        updates = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        Log.note("realitykit: scene ready")
    }

    /// The end of this display: the space has gone, or is out of sight.
    func stop() {
        guard !stopped else { return }
        stopped = true
        updates?.cancel()
        updates = nil
        vsync?.stop()
        vsync = nil
        connection.stop()
        connection.immersed = false
        persona.leave()
        pinches.forgetAll()
        // What this stream's pinches taught the gaze calibration, unless it was forgotten meanwhile.
        if let tuned = persona.takeTunedCalibration(), settings.settings.gazeCalibration != nil {
            settings.settings.gazeCalibration = tuned
        }
    }

    /// Describe the display to the host as it was last measured, and ask
    /// for a stream to show with RealityKit. The space need not be open
    /// yet. False if the display has not been measured.
    @discardableResult
    public static func connect(_ inputs: StreamInputs, persona: PersonaTracking) -> Bool {
        guard let measured = inputs.measured.value, var profile = inputs.profileForHost() else { return false }
        let chosen = inputs.settings.current
        // This renderer can send the eyes and the face (`PersonaTracking`).
        profile.tracksEyesOrFace = true
        inputs.head.setEyeMidpoint(measured.eyeMidpoint, atConnect: true)
        inputs.controllers.gripsAsRendered = false
        persona.camera.setIPD(profile.eyesInHead[1].position.x - profile.eyesInHead[0].position.x)
        Log.note("realitykit: connecting at \(profile.refreshHz) Hz")
        inputs.connection.start(profile: profile, microphone: chosen.microphone,
                                headProvider: { [head = inputs.head] in head.trackedHead() },
                                handsProvider: { [inputs] in inputs.handsNow() },
                                // There is no rate map to read the gaze from here: the Persona's eyes or nothing.
                                gazeProvider: { [persona, settings = inputs.settings] in persona.gaze(settings.current) },
                                faceProvider: { [persona, settings = inputs.settings] in persona.face(settings.current) },
                                onHaptic: { [controllers = inputs.controllers] in controllers.vibrate($0) })
        return true
    }

    /// Black behind a picture that is not keyed, so that one narrower
    /// than the display (the field-of-view setting) has a black margin and
    /// not the room. With keying, or with no picture, the room shows.
    private func showBackdrop(_ pictureShown: Bool) {
        backdrop?.isEnabled = pictureShown && renderer.chromaKey == nil
    }

    /// Three textures and their planes, for a frame like this one shown through `frusta`.
    private func makeSets(for metadata: FrameMetadata, frusta: [Frustum]) {
        guard materials.count == 2 else { return }
        // Foveated when the device can (`FoveatedFlatten`); otherwise a
        // plain texture of a size that keeps most of the foveal tile's detail.
        var scale = RealityKitDisplay.flattenScale
        scale = min(scale, Double(RealityKitDisplay.largestSide) / Double(max(metadata.atlasWidth, metadata.tileHeight, 1)))
        var size = (width: max(16, Int(Double(metadata.atlasWidth) * scale)), height: max(16, Int(Double(metadata.tileHeight) * scale)))
        let sameFrusta = zip(frusta, madeForFrusta).allSatisfy {
            $0.left == $1.left && $0.right == $1.right && $0.down == $1.down && $0.up == $1.up
        } && frusta.count == madeForFrusta.count
        if !sameFrusta || (foveated == nil && !foveationFailed) {
            foveated = FoveatedFlatten(device: device, frusta: frusta)
            foveationFailed = foveated == nil
            madeForFrusta = frusta
            eyeSize = (0, 0)
        }
        if let foveated { size = foveated.target.screen }
        guard size.width != eyeSize.width || size.height != eyeSize.height else { return }
        for set in sets { set.planes.forEach { $0.removeFromParent() } }
        sets = []
        eyeSize = size
        let stored = foveated?.target.texture ?? (width: size.width, height: size.height * 2)
        let sheet = MeshResource.generatePlane(width: 1, depth: 1)
        for _ in 0..<3 {
            // One eye above the other.
            let descriptor = LowLevelTexture.Descriptor(textureType: .type2D, pixelFormat: .bgra8Unorm_srgb,
                                                        width: stored.width, height: stored.height, depth: 1, mipmapLevelCount: 1,
                                                        textureUsage: [.renderTarget, .shaderRead])
            guard let texture = try? LowLevelTexture(descriptor: descriptor),
                  let resource = try? TextureResource(from: texture)
            else {
                Log.note("realitykit: no texture of \(stored.width)x\(stored.height)")
                return
            }
            let planes = Eye.allCases.map { eye -> ModelEntity in
                var material = materials[eye.rawValue]
                try? material.setParameter(name: "texture", value: .textureResource(resource))
                material.faceCulling = .none
                let plane = ModelEntity(mesh: foveated?.meshes[eye.rawValue] ?? sheet, materials: [material])
                plane.isEnabled = false
                root.addChild(plane)
                return plane
            }
            sets.append(PlaneSet(texture: texture, planes: planes))
        }
        Log.note("realitykit: flattening each eye to \(size.width)x\(size.height)"
                 + (foveated == nil ? "" : ", foveated: both eyes stored in \(stored.width)x\(stored.height)"))
    }
    private var foveated: FoveatedFlatten?
    private var foveationFailed = false
    private var madeForFrusta: [Frustum] = []

    private func update() {
        guard !stopped else { return }
        let began = CACurrentMediaTime()
        defer { vsync?.updateTook(CACurrentMediaTime() - began) }
        updatesSeen += 1
        placePersonaCamera()
        // The stream being shown was asked for with this, before this space opened.
        let profile = connection.profile
        renderer.chromaKey = settings.current.chromaKeying(inGame: connection.session?.sceneApplicationRunning ?? false)

        let picked = connection.frames.next()
        if let session = connection.session, let profile {
            // When what is set now will be seen, and how long a refresh
            // lasts, from the display's own refresh signal (`VsyncPrediction`).
            var period = 1 / Double(profile.refreshHz), displayTime = began + period
            if let vsync, vsync.refreshPeriod > 0 {
                period = vsync.refreshPeriod
                displayTime = vsync.nextFrameTime
            }
            func sessionTime(_ time: TimeInterval) -> Int32 {
                session.now() &+ Int32((time - CACurrentMediaTime()) * 1_000_000)
            }
            session.displayWillRefresh(at: sessionTime(displayTime + period), period: period)
            if let picked, picked.isNew {
                session.frameDisplayed(picked.frame.frameID, displayTime: sessionTime(displayTime))
            }
        }
        guard let picked, picked.isNew, let profile else {
            // No stream: show nothing stale.
            if connection.session == nil {
                for set in sets { set.planes.forEach { $0.isEnabled = false } }
                showBackdrop(false)
            } else {
                // The keying setting may have changed with the picture standing still.
                showBackdrop(sets.contains { $0.planes.contains(where: \.isEnabled) })
            }
            return
        }
        let frame = picked.frame
        makeSets(for: frame.metadata, frusta: profile.eyeFrusta)
        guard sets.count == 3, let commands = queue.makeCommandBuffer() else { return }
        framesDrawn += 1
        let set = sets[framesDrawn % 3]

        // Flatten: each eye's quads, seen from exactly where the host's eye
        // was. A pass for each eye, since each has a rate map of its own
        // (`FoveatedFlatten`); the second keeps what the first drew.
        let target = set.texture.replace(using: commands)
        var hostEyes: [Pose] = []
        for eye in Eye.allCases {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = eye == Eye.allCases.first ? .clear : .load
            // Where the picture fades out at its edge it fades to black, unless it is keyed.
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0,
                                                                alpha: renderer.chromaKey == nil ? 1 : 0)
            pass.colorAttachments[0].storeAction = .store
            pass.rasterizationRateMap = foveated?.target.maps[eye.rawValue]
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
            let hostEye = frame.metadata.renderPose.placing(profile.eyesInHead[eye.rawValue])
            hostEyes.append(hostEye)
            // The left eye goes in the lower half of the texture, which is
            // the half the left material reads.
            encoder.setViewport(foveated?.target.viewport(eye)
                                ?? MTLViewport(originX: 0, originY: eye == .left ? Double(eyeSize.height) : 0,
                                               width: Double(eyeSize.width), height: Double(eyeSize.height), znear: 0, zfar: 1))
            renderer.draw(Composition.quads(for: eye, metadata: frame.metadata, profile: profile), of: frame,
                          from: EyeView(eye: hostEye, frustum: profile.eyeFrusta[eye.rawValue]),
                          with: encoder, commands: commands)
            encoder.endEncoding()
        }
        commands.commit()
        // The texture changes hands when the drawing is done; waiting here
        // keeps it in step with the planes moved below.
        commands.waitUntilCompleted()

        for eye in Eye.allCases {
            // The plane fills the host's frustum for this eye, `distance` meters out:
            // its middle is off the eye's axis when the frustum is lopsided.
            let hostEye = hostEyes[eye.rawValue], frustum = profile.eyeFrusta[eye.rawValue]
            let distance = RealityKitDisplay.planeDistance[eye.rawValue]
            let middle = hostEye.position + hostEye.forward * distance
                + hostEye.right * ((frustum.left + frustum.right) / 2 * distance)
                + hostEye.up * ((frustum.down + frustum.up) / 2 * distance)
            let plane = set.planes[eye.rawValue]
            plane.position = [middle.x, middle.y, middle.z]
            // The eye's own axes as a rotation; the sheet lies flat (in x and
            // z) until it is stood up by a quarter turn about x.
            let facing = simd_quatf(simd_float3x3(columns: (
                [hostEye.right.x, hostEye.right.y, hostEye.right.z],
                [hostEye.up.x, hostEye.up.y, hostEye.up.z],
                [-hostEye.forward.x, -hostEye.forward.y, -hostEye.forward.z])))
            plane.orientation = facing * simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            plane.scale = [(frustum.right - frustum.left) * distance, 1, (frustum.up - frustum.down) * distance]
        }
        for other in sets.indices {
            sets[other].planes.forEach { $0.isEnabled = other == framesDrawn % 3 }
        }
        showBackdrop(true)
    }

    /// Keep the Persona's camera one meter in front of the face, facing as
    /// the head faces.
    private func placePersonaCamera() {
        guard let personaCamera, let device = head.anchor(at: CACurrentMediaTime()) else { return }
        placePersonaCameraEntity(personaCamera, originFromDevice: device.originFromAnchorTransform, tick: updatesSeen)
    }
}

/// The RealityKit stream as an immersive space's content.
public struct RealityKitStreamView: View {
    let display: RealityKitDisplay
    let persona: PersonaTracking
    let settings: VRLinkCore.Settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    public init(display: RealityKitDisplay, persona: PersonaTracking, settings: VRLinkCore.Settings) {
        self.display = display
        self.persona = persona
        self.settings = settings
    }

    public var body: some View {
        RealityView { content, attachments in
            await display.setup(&content, attachments: attachments)
        } update: { _, _ in
        } attachments: {
            Attachment(id: PersonaAttachments.anchor) {
                Text("").cameraAnchor(isActive: true)
            }
            Attachment(id: PersonaAttachments.cameraView) {
                PersonaCameraView(persona: persona, wanted: settings.faceFromCamera, showPicture: settings.showFaceCameraPicture,
                                  faceCalibration: settings.faceCalibration, mayStart: { [display] in !display.stopped })
            }
        }
        .gesture(SpatialEventGesture(coordinateSpace: .local).targetedToAnyEntity()
            .onChanged { value in
                display.pinches.handle(value.gestureValue) { value.convert($0, from: .local, to: .scene) }
            }
            .onEnded { value in
                display.pinches.handle(value.gestureValue) { value.convert($0, from: .local, to: .scene) }
            })
        // Without this a SwiftUI view in front leaves the controllers'
        // buttons and sticks to the system, and the app is told nothing.
        // (A compositor layer is given them without asking.)
        .handlesGameControllerEvents(matching: .gamepad)
        // When the space goes out of sight (the crown pressed, the headset
        // taken off) the stream is over, and the space is closed with it:
        // RealityKit goes on updating a space that is merely hidden, and the
        // stream and the Persona's camera were found still running, behind
        // the app's window, when the app was opened again. Only when it is
        // really out of sight: it is briefly "inactive" whenever the app's
        // window closes, which is no reason to leave the stream.
        .onChange(of: scenePhase) {
            guard scenePhase == .background else { return }
            display.stop()
            Task { await dismissImmersiveSpace() }
        }
        .onDisappear { display.stop() }
    }
}
#endif
