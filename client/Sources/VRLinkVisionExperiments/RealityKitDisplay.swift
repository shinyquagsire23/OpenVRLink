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

/// Experimental RealityKit-based stream renderer used instead of a CompositorServices layer.
///
/// RealityKit is used here because a RealityView can host the SwiftUI camera
/// anchor needed to keep the Spatial Persona camera positioned in front of the
/// user's face (see `PersonaTracking`). The rendering pipeline follows the
/// ALVR visionOS client:
///
/// - Each decoded frame is composited by `QuadRenderer` into a single stacked
///   texture (one eye per vertical half), blending the foveal tile over the
///   base tile from the host's rendered eye pose.
/// - Each eye views a distant quad plane sized and positioned to fill that
///   eye's host frustum from the rendered eye pose. A stereo ShaderGraph
///   material displays each half of the stacked texture only to the matching eye.
/// - Textures and plane entities are triple-buffered, enabling only the newest
///   set each frame so texture contents and plane poses always update atomically.
///
/// Compared with the CompositorServices path, this requires an extra full-frame
/// render pass and forfeits system compositor foveation.
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
    /// Opaque black backdrop placed behind the eye planes when chroma keying is inactive (`showBackdrop`).
    private var backdrop: ModelEntity?
    public private(set) var stopped = false

    /// Distance in meters to the left and right eye planes. Placed far out so
    /// other RealityKit content renders in front, and staggered to avoid z-fighting.
    private static let planeDistance: [Float] = [80, 70]
    /// Distance in meters from the head to the black backdrop plane, which is
    /// scaled to 20x this distance so it covers the entire field of view.
    private static let backdropDistance: Float = 90
    /// Per-axis resolution multiplier applied to eye tile dimensions when
    /// flattening without foveation, preserving detail from the higher-density foveal tile.
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

    /// Populates the RealityKit scene and attaches the Persona camera anchor entity.
    func setup(_ content: inout RealityViewContent, attachments: RealityViewAttachments) async {
        content.add(root)
        pinches.onGaze = { [persona, head, settings] direction in
            persona.learn(fromPinchLooking: direction, head: head.latestHead(), settings: settings.current)
        }
        personaCamera = PersonaAttachments.add(to: &content, from: attachments, settings: settings.current)

        // Add a head-locked invisible collision plane because visionOS only reports
        // indirect pinches when the gaze ray intersects an input target entity.
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

        // Keep the backdrop opaque so RealityKit renders it before the eye
        // planes, which disable depth testing and composite on top of it.
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

    /// Stops streaming and tears down tracking when the immersive space closes or moves to the background.
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
        // Persist any continuous gaze calibration updates from this session unless calibration was cleared.
        if let tuned = persona.takeTunedCalibration(), settings.settings.gazeCalibration != nil {
            settings.settings.gazeCalibration = tuned
        }
    }

    /// Starts a host streaming session configured for RealityKit display using
    /// the last measured display profile. Can be called before the immersive
    /// space opens; returns `false` if no display measurements are available.
    @discardableResult
    public static func connect(_ inputs: StreamInputs, persona: PersonaTracking) -> Bool {
        guard let measured = inputs.measured.value, var profile = inputs.profileForHost() else { return false }
        let chosen = inputs.settings.current
        // RealityKit mode supports Persona-based eye and face tracking (`PersonaTracking`).
        profile.tracksEyesOrFace = true
        inputs.head.setEyeMidpoint(measured.eyeMidpoint, atConnect: true)
        inputs.controllers.gripsAsRendered = false
        persona.camera.setIPD(profile.eyesInHead[1].position.x - profile.eyesInHead[0].position.x)
        Log.note("realitykit: connecting at \(profile.refreshHz) Hz")
        inputs.connection.start(profile: profile, microphone: chosen.microphone,
                                headProvider: { [head = inputs.head] in head.trackedHead() },
                                handsProvider: { [inputs] in inputs.handsNow() },
                                // RealityKit provides no compositor rasterization rate map, so gaze comes solely from PersonaTracking.
                                gazeProvider: { [persona, settings = inputs.settings] in persona.gaze(settings.current) },
                                faceProvider: { [persona, settings = inputs.settings] in persona.face(settings.current) },
                                onHaptic: { [controllers = inputs.controllers] in controllers.vibrate($0) })
        return true
    }

    /// Whether the current frame carries its own alpha transparency, allowing passthrough to show through.
    /// When false and chroma keying is off, `showBackdrop` enables a black surround so reduced-FOV frames
    /// show black margins instead of the passthrough room.
    private var pictureTransparent = false

    private func showBackdrop(_ pictureShown: Bool) {
        backdrop?.isEnabled = pictureShown && renderer.chromaKey == nil && !pictureTransparent
    }

    /// Allocates or resizes the three buffered render targets and eye planes for `eyePixels` and `frusta`.
    private func makeSets(for eyePixels: (width: Int, height: Int), frusta: [Frustum]) {
        guard materials.count == 2 else { return }
        // Use a foveated target when supported (`FoveatedFlatten`), falling back
        // to a scaled uniform texture large enough to preserve foveal tile detail.
        var scale = RealityKitDisplay.flattenScale
        scale = min(scale, Double(RealityKitDisplay.largestSide) / Double(max(eyePixels.width, eyePixels.height, 1)))
        var size = (width: max(16, Int(Double(eyePixels.width) * scale)), height: max(16, Int(Double(eyePixels.height) * scale)))
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
            // Stack both eyes vertically in a single 2D texture.
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
        // Display profile negotiated with the host before the immersive space opened.
        let profile = connection.profile
        renderer.chromaKey = settings.current.chromaKeying(inGame: connection.session?.sceneApplicationRunning ?? false)

        let picked = connection.frames.next()
        if let session = connection.session, let profile {
            // Estimate next presentation time and refresh period from `VsyncPrediction`.
            var period = 1 / Double(profile.refreshHz), displayTime = began + period
            if let vsync, vsync.refreshPeriod > 0 {
                period = vsync.refreshPeriod
                displayTime = vsync.nextFrameTime
            }
            // Convert `CACurrentMediaTime` timestamps to monotonic system uptime nanoseconds for the session.
            func uptime(_ time: TimeInterval) -> UInt64 {
                UInt64(max(0, Double(Uptime.nanoseconds) + (time - CACurrentMediaTime()) * 1e9))
            }
            session.displayRefreshes(at: uptime(displayTime + period), period: period)
            if let picked, picked.isNew {
                session.frameShown(picked.frame.frameID, at: uptime(displayTime))
            }
        }
        guard let picked, picked.isNew, let profile else {
            // Hide planes and backdrop when disconnected so stale frames do not remain visible.
            if connection.session == nil {
                for set in sets { set.planes.forEach { $0.isEnabled = false } }
                showBackdrop(false)
            } else {
                // Update the backdrop in case chroma key settings changed between new frames.
                showBackdrop(sets.contains { $0.planes.contains(where: \.isEnabled) })
            }
            return
        }
        let frame = picked.frame
        makeSets(for: frame.layout.eyePixels, frusta: profile.eyeFrusta)
        guard sets.count == 3, let commands = queue.makeCommandBuffer() else { return }
        framesDrawn += 1
        let set = sets[framesDrawn % 3]

        // Composite each eye's quads from the host's rendered eye pose. Run a
        // separate render pass per eye because each eye uses its own rasterization
        // rate map (`FoveatedFlatten`), loading the first eye's output on the second pass.
        let target = set.texture.replace(using: commands)
        var hostEyes: [Pose] = []
        for eye in Eye.allCases {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = eye == Eye.allCases.first ? .clear : .load
            // Clear to opaque black so edge feathering blends to black unless chroma keying or frame alpha is active.
            pictureTransparent = frame.layout.transparent
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0,
                                                                alpha: renderer.chromaKey == nil && !pictureTransparent ? 1 : 0)
            pass.colorAttachments[0].storeAction = .store
            pass.rasterizationRateMap = foveated?.target.maps[eye.rawValue]
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
            let hostEye = frame.layout.views[eye.rawValue].eye
            hostEyes.append(hostEye)
            // The left eye goes in the lower half of the texture, which is
            // the half the left material reads.
            encoder.setViewport(foveated?.target.viewport(eye)
                                ?? MTLViewport(originX: 0, originY: eye == .left ? Double(eyeSize.height) : 0,
                                               width: Double(eyeSize.width), height: Double(eyeSize.height), znear: 0, zfar: 1))
            renderer.draw(Composition.quads(for: eye, layout: frame.layout), of: frame,
                          from: EyeView(eye: hostEye, frustum: profile.eyeFrusta[eye.rawValue]),
                          with: encoder, commands: commands)
            encoder.endEncoding()
        }
        commands.commit()
        // Wait for rendering to finish so the updated texture swaps in on the
        // same RealityKit update as the plane transforms below.
        commands.waitUntilCompleted()

        for eye in Eye.allCases {
            // Size and center the plane to fill this eye's host frustum at `distance`
            // meters; asymmetric frusta shift the plane center off the forward axis.
            let hostEye = hostEyes[eye.rawValue], frustum = profile.eyeFrusta[eye.rawValue]
            let distance = RealityKitDisplay.planeDistance[eye.rawValue]
            let middle = hostEye.position + hostEye.forward * distance
                + hostEye.right * ((frustum.left + frustum.right) / 2 * distance)
                + hostEye.up * ((frustum.down + frustum.up) / 2 * distance)
            let plane = set.planes[eye.rawValue]
            plane.position = [middle.x, middle.y, middle.z]
            // Build a rotation from the eye's basis vectors, then pitch +90 degrees
            // around X to stand the XZ plane upright facing the eye.
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

    /// Updates the Persona camera anchor to stay one meter in front of the user's head.
    private func placePersonaCamera() {
        guard let personaCamera, let device = head.anchor(at: CACurrentMediaTime()) else { return }
        placePersonaCameraEntity(personaCamera, originFromDevice: device.originFromAnchorTransform, tick: updatesSeen)
    }
}

/// Immersive space content view for the RealityKit streaming renderer.
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
        // Required so SwiftUI routes gamepad button and thumbstick input to the
        // app instead of consuming it for system UI navigation (CompositorServices
        // layers receive controller input automatically).
        .handlesGameControllerEvents(matching: .gamepad)
        // Stop streaming and dismiss the immersive space when backgrounded
        // (for example, when the user presses the Digital Crown or removes the
        // headset). RealityKit continues updating hidden spaces, which otherwise
        // leaves the stream and Persona camera running behind the reopened main
        // window. Ignore `.inactive`, which fires briefly whenever an app window closes.
        .onChange(of: scenePhase) {
            guard scenePhase == .background else { return }
            display.stop()
            Task { await dismissImmersiveSpace() }
        }
        .onDisappear { display.stop() }
    }
}
#endif
