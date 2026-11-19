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
import VRLinkMetal
import VRLinkVisionTracking
import simd

/// Observable state for a `VergenceTest` session, displayed in the Experiments tab.
public final class VergenceTestRun: ObservableObject {
    public init() {}
    /// Whether the test's immersive space is currently open.
    @Published public var open = false
    @Published public var status = ""
    /// True once all charts have been shown and the summary report is ready.
    @Published public var finished = false
    /// Summary lines (`VergenceReport.lines`) from the most recent completed run.
    @Published public var findings: [String] = []
}

/// Runs `VergenceTest` in a dedicated immersive space to evaluate whether
/// Spatial Persona pupil landmarks track eye convergence accurately enough to
/// estimate viewing distance.
///
/// Displays a head-locked reading chart straight ahead against a black surround
/// across a sequence of distances. Keeping the chart centered on the forward
/// axis isolates vergence from conjugate gaze, and scaling chart size linearly
/// with distance keeps angular size constant so stereo disparity is the primary
/// depth cue. While the user reads each chart, pupil positions are recorded
/// from the Persona camera (`EyeFeatures.converging`).
///
/// Uses RealityKit so the Persona camera stays active, matching `GazeCalibrationSpace`.
@MainActor
public final class VergenceTestSpace {
    private let head: HeadTracking
    private let persona: PersonaTracking
    private let store: SettingsStore
    private let run: VergenceTestRun
    /// Midpoint between the eyes in head-anchor space from `MeasuredDisplay`, or `.zero` if unmeasured.
    private let eyes: SIMD3<Float>
    private let test = VergenceTest()

    /// Half-extents of the chart in view tangents (~8 x 4 degrees half-angle).
    private static let halfWidth: Float = 0.14, halfHeight: Float = 0.07
    /// Delay in seconds after the first face detection before step timing starts.
    private static let leadIn = 2.0
    private static let surroundRadius: Float = 40

    private var chart: ModelEntity?
    private var shownStep: Int?
    private var samples: [VergenceSample] = []
    /// `CACurrentMediaTime` timestamp corresponding to `t = 0` of the test, set once the Persona face is detected.
    private var began: TimeInterval?
    private var lastSample: TimeInterval = 0
    private var personaCamera: Entity?
    private var updates: EventSubscription?
    private var ticks = 0
    /// Callbacks provided by the view to dismiss this immersive space and reopen the main window.
    var closeSpace: (() async -> Void)?
    var reopenWindow: (() -> Void)?
    public private(set) var stopped = false

    public init(head: HeadTracking, persona: PersonaTracking, store: SettingsStore, run: VergenceTestRun,
                eyeMidpoint: SIMD3<Float>?) {
        self.head = head
        self.persona = persona
        self.store = store
        self.run = run
        eyes = eyeMidpoint ?? .zero
    }

    func setup(_ content: inout RealityViewContent, attachments: RealityViewAttachments) {
        run.finished = false
        run.open = true
        personaCamera = PersonaAttachments.add(to: &content, from: attachments, settings: store.settings)
        let headAnchor = AnchorEntity(.head)
        headAnchor.anchoring.trackingMode = .continuous
        // Enclose the user in an inverted black sphere so room passthrough doesn't distract fixation.
        let surround = ModelEntity(mesh: .generateSphere(radius: VergenceTestSpace.surroundRadius),
                                   materials: [UnlitMaterial(color: .black)])
        surround.scale = [-1, 1, 1]
        headAnchor.addChild(surround)
        let chart = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [UnlitMaterial(color: .black)])
        chart.isEnabled = false
        headAnchor.addChild(chart)
        self.chart = chart
        content.add(headAnchor)

        updates = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.everyFrame() }
        }
        tell("Waiting to see your Persona's face")
    }

    /// Cleans up when the immersive space closes.
    func stop() {
        guard !stopped else { return }
        stopped = true
        updates?.cancel()
        updates = nil
        if !run.finished { tell("Stopped early; no results saved") }
        run.open = false
        persona.leave()
        reopenWindow?()
    }

    private func tell(_ text: String) {
        Log.note("vergence: \(text)")
        run.status = text
    }

    private func everyFrame() {
        ticks += 1
        let now = CACurrentMediaTime()
        if let personaCamera, let device = head.anchor(at: now) {
            placePersonaCameraEntity(personaCamera, originFromDevice: device.originFromAnchorTransform, tick: ticks)
        }
        guard !run.finished else { return }
        if began == nil {
            guard persona.camera.estimate() != nil else { return }
            began = now + VergenceTestSpace.leadIn
        }
        guard let began else { return }
        guard let step = test.step(at: max(0, now - began)) else {
            finish()
            return
        }
        if shownStep != step.index { show(step.index, distance: step.distance) }

        // Record each new camera sample once while the current step is in its recording window.
        let fresh = persona.camera.eyeSamples(after: lastSample)
        if let newest = fresh.last { lastSample = newest.time }
        let calibration = store.settings.gazeCalibration.flatMap { $0.usable ? $0 : nil }
        for sample in fresh {
            guard let then = test.step(at: sample.time - began), then.index == step.index, then.recording else { continue }
            // If gaze calibration is available, compute angular offset so off-chart glances can be filtered out.
            let looking = calibration?.tangents(for: sample.features)
            samples.append(VergenceSample(step: step.index, seconds: sample.time - began, distance: step.distance,
                                          signal: sample.features.converging,
                                          offTarget: looking.map { hypot($0.across, $0.up) } ?? 0, eyes: sample.features))
        }
    }

    /// Displays a newly generated reading chart `distance` meters in front of the eye midpoint.
    private func show(_ step: Int, distance: Float) {
        shownStep = step
        tell("Chart \(step + 1) of \(test.steps.count)")
        guard let chart else { return }
        var generator = SystemRandomNumberGenerator()
        if let gray = ReadingChart.image(heading: "Read every letter, top to bottom",
                                         lines: ReadingChart.randomLines(using: &generator),
                                         footing: "\(step + 1) of \(test.steps.count)", seed: UInt64(step) + 1),
           let picture = VergenceTestSpace.inColor(gray),
           let texture = try? TextureResource(image: picture, options: .init(semantic: .color)) {
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(texture))
            chart.model?.materials = [material]
        } else {
            Log.note("vergence: failed to render chart image; falling back to a solid gray quad")
            chart.model?.materials = [UnlitMaterial(color: .gray)]
        }
        chart.position = [eyes.x, eyes.y, eyes.z - distance]
        chart.scale = [2 * VergenceTestSpace.halfWidth * distance, 2 * VergenceTestSpace.halfHeight * distance, 1]
        chart.isEnabled = true
    }

    /// Converts an 8-bit grayscale `CGImage` to RGBA8 sRGB for `TextureResource`.
    private static func inColor(_ gray: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: gray.width, height: gray.height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        canvas.draw(gray, in: CGRect(x: 0, y: 0, width: gray.width, height: gray.height))
        return canvas.makeImage()
    }

    /// Computes `VergenceReport`, logs summary lines, writes raw samples to CSV, and dismisses the immersive space.
    private func finish() {
        var lines = VergenceReport(samples).lines
        if samples.isEmpty { lines.insert("no samples recorded (Persona face was never detected while a chart was visible)", at: 0) }
        if store.settings.gazeCalibration?.usable != true {
            lines.append("gaze is uncalibrated, so off-chart glances were not filtered out")
        }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let file = DataDirectory.url.appendingPathComponent("vergence-\(stamp.string(from: Date())).csv")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(VergenceReport.csv(samples, steps: test.steps).utf8).write(to: file, options: .atomic)
            lines.append("saved raw samples to \(file.lastPathComponent)")
        } catch {
            lines.append("failed to save raw samples: \(error.localizedDescription)")
        }
        for line in lines { Log.note("vergence: \(line)") }
        run.findings = lines
        run.status = "Finished"
        run.finished = true
        chart?.isEnabled = false
        Task { await closeSpace?() }
    }
}

public struct VergenceTestView: View {
    let space: VergenceTestSpace
    let persona: PersonaTracking
    let settings: VRLinkCore.Settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    public init(space: VergenceTestSpace, persona: PersonaTracking, settings: VRLinkCore.Settings) {
        self.space = space
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
        // Clean up if the user dismisses the space externally (for example, via the Digital Crown).
        .onChange(of: scenePhase) {
            if scenePhase == .background { space.stop() }
        }
        .onDisappear { space.stop() }
        // Dismiss the main window while open so visionOS binds the Persona camera to this space's anchor (`GazeCalibrationView`).
        .task { dismissWindow(id: "entry") }
    }
}
#endif
