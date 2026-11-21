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
        /// Per-eye deformable meshes used when `Settings.depthFromPicture` is enabled; empty otherwise.
        var bent: [BentPlane] = []
    }
    /// Estimates scene depth from stereo disparity when `Settings.depthFromPicture` is enabled.
    private let depth: DepthEstimator
    private var depthNoted: Double = 0
    /// Temporally smoothed depth field (`depthSettles`) used to deform the display meshes.
    ///
    /// Unlike CompositorServices, RealityKit doesn't expose its exact per-eye rendering poses,
    /// so the poses RealityKit draws from can differ by a few millimeters from the poses the
    /// host rendered for. Because of that offset, frame-to-frame noise in the depth estimate
    /// shifts the image by a fraction of a pixel even when the user's head is still. `BentPlane`
    /// uses perspective-correct UVs to eliminate UV swimming across triangles, and smoothing
    /// the depth field over time suppresses the remaining sub-pixel jitter.
    private var steadyDepth: (field: DepthField, at: Double)?
    /// Exponential smoothing time constant in seconds (`1 - 1/e` response time) for `steadyDepth`.
    private static let depthSettles = 0.1
    /// Retained so the debug depth overlay setting can toggle diagnostic image dumps.
    private let shrink: StereoShrink?
    /// Tracks whether the current `PlaneSet` buffers were allocated with deformable `BentPlane` meshes.
    private var madeBent = false
    /// Mesh subdivision counts when flattening without foveation; foveated targets match the foveation zone grid.
    private static let bentCells = (across: 110, down: 100)
    private var sets: [PlaneSet] = []
    private var materials: [ShaderGraphMaterial] = []      // left eye, right eye
    /// Left and right stereo materials that divide `uv0` by `uv1.x` per pixel for perspective-correct
    /// `BentPlane` meshes. Empty if loading failed, in which case `materials` is used as a fallback.
    private var projectedMaterials: [ShaderGraphMaterial] = []
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
        // Hardware-decoded VideoToolbox buffers use lossless compression that only the GPU sampler can read,
        // so downsampling and stereo matching run on Metal.
        let shrink = StereoShrink(device: device)
        self.shrink = shrink
        depth = DepthEstimator(measure: shrink.map { shrink in { shrink.measure($0, interests: $1, done: $2) } } ?? { $2(nil) })
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
        do {
            var loaded: [ShaderGraphMaterial] = []
            for name in ["/Root/SBSMaterialBilinearProjected_L", "/Root/SBSMaterialBilinearProjected_R"] {
                var material = try await ShaderGraphMaterial(named: name, from: "SBSMaterial.usda", in: .module)
                material.readsDepth = false
                material.writesDepth = false
                loaded.append(material)
            }
            projectedMaterials = loaded
        } catch {
            Log.note("realitykit: failed to load projected stereo materials; falling back to affine UVs: \(error)")
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
    private func makeSets(for eyePixels: (width: Int, height: Int), frusta: [Frustum], bent: Bool) {
        guard materials.count == 2 else { return }
        if bent != madeBent {
            madeBent = bent
            eyeSize = (0, 0)
        }
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
            // Build per-eye deformable meshes subdivided to align with the foveation zone grid;
            // each triple-buffered PlaneSet owns its own mesh instances so updates stay in sync with its texture.
            var sheets: [BentPlane] = []
            let projected = projectedMaterials.count == 2
            if bent {
                sheets = Eye.allCases.compactMap { eye -> BentPlane? in
                    guard let foveated else {
                        return BentPlane(across: RealityKitDisplay.bentCells.across, down: RealityKitDisplay.bentCells.down, projected: projected) { x, y in
                            [x, 1 - y]
                        }
                    }
                    return BentPlane(across: Foveation.zonesAcross * 2, down: Foveation.zonesDown * 2, projected: projected) { x, y in
                        let (fromLeft, fromTop) = foveated.target.stored(eye, x: x, y: y)
                        // Pre-compensate for the stereo material's 0.5x scale and per-eye offset on V, matching FoveatedFlatten.
                        let fromBottom = 1 - fromTop
                        return [fromLeft, eye == .left ? fromBottom * 2 : fromBottom * 2 - 1]
                    }
                }
                if sheets.count != 2 {
                    Log.note("realitykit: failed to create deformable depth meshes; falling back to flat planes")
                    sheets = []
                }
            }
            let planes = Eye.allCases.map { eye -> ModelEntity in
                var material = !sheets.isEmpty && projected ? projectedMaterials[eye.rawValue] : materials[eye.rawValue]
                try? material.setParameter(name: "texture", value: .textureResource(resource))
                material.faceCulling = .none
                let plane = ModelEntity(mesh: sheets.isEmpty ? (foveated?.meshes[eye.rawValue] ?? sheet) : sheets[eye.rawValue].resource,
                                        materials: [material])
                plane.isEnabled = false
                plane.components.set(ModelSortGroupComponent(group: PersonaAttachments.drawOrder, order: 0))
                root.addChild(plane)
                return plane
            }
            sets.append(PlaneSet(texture: texture, planes: planes, bent: sheets))
        }
        Log.note("realitykit: flattening each eye to \(size.width)x\(size.height)"
                 + (foveated == nil ? "" : ", foveated: both eyes stored in \(stored.width)x\(stored.height)")
                 + (bent ? ", with depth-warped meshes" + (projectedMaterials.count == 2 ? "" : " (unprojected UVs)") : ""))
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
        let field = followDepth(frame, at: began)
        let shownDepth = settings.current.showDepth ? field : nil
        makeSets(for: frame.layout.eyePixels, frusta: profile.eyeFrusta, bent: settings.current.depthFromPicture)
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
            // Flatten tiles onto flat quads from the host's rendering eye pose; scene depth
            // is applied afterward by warping the RealityKit display mesh.
            renderer.draw(Composition.quads(for: eye, layout: frame.layout)
                              + (shownDepth.map { Composition.picture(of: $0, for: eye, layout: frame.layout) } ?? []), of: frame,
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
            if set.bent.count == 2 {
                // BentPlane vertices are written directly in world space along this eye's rays
                // using the depth field reprojected to this frame's pose.
                set.bent[eye.rawValue].place(eye: hostEye, frustum: frustum, depth: field?.fitted(to: frame.layout).seen(by: eye),
                                             flatAt: distance)
                plane.transform = Transform()
                continue
            }
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

    /// Submits `frame` to the depth estimator while `Settings.depthFromPicture` is
    /// enabled, logs summary statistics every few seconds, and returns the latest depth field.
    private func followDepth(_ frame: DecodedFrame, at seconds: Double) -> DepthField? {
        guard settings.current.depthFromPicture else {
            steadyDepth = nil
            if depthNoted != 0 {
                depthNoted = 0
                depth.forget()
            }
            return nil
        }
        shrink?.savesPictures = settings.current.showDepth
        // Sample depth densely around the hands or controllers and straight ahead.
        depth.offer(frame, interests: DepthSampling.interests(layout: frame.layout, hands: inputs.handPositions()))
        if depthNoted == 0 { depthNoted = seconds }
        if seconds - depthNoted > 5 {
            depthNoted = seconds
            if let report = depth.report {
                Log.note(String(format: "depth: %.0f%% coverage; center %.2f m, nearest %.2f m; "
                                    + "%.1f ms latency, %d frames processed, %d skipped",
                                report.measured * 100, 1 / max(0.001, report.ahead), 1 / max(0.001, report.nearest),
                                report.behind, report.taken, report.passed))
            } else {
                Log.note("depth: no depth estimate available yet")
            }
        }
        // Reproject once to this frame's rendering pose for both eyes and the debug overlay.
        guard let fresh = depth.field?.fitted(to: frame.layout) else {
            steadyDepth = nil
            return nil
        }
        // Reproject the previous smoothed field to this frame's pose before blending so depth stays world-locked during head rotation.
        var field = fresh
        if let held = steadyDepth {
            let weight = Float(1 - exp(-max(0, seconds - held.at) / RealityKitDisplay.depthSettles))
            field = held.field.fitted(to: frame.layout).eased(toward: fresh, by: weight)
        }
        steadyDepth = (field, seconds)
        return field
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
                                  faceCalibration: settings.faceCalibration, mayStart: { [display] in !display.stopped },
                                  startsCamera: false)
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
