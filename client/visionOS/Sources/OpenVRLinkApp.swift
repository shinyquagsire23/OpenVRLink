// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVKit
import CompositorServices
import SwiftUI
import VRLinkCore
import VRLinkVisionExperiments
import VRLinkVisionCompositor
import VRLinkAppleSession
import VRLinkVisionTracking

/// OpenVRLink for visionOS, first draft: a small window to pick a host, and
/// an immersive space that shows the stream.

struct StreamLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.colorFormat = .rgba16Float
        configuration.depthFormat = .depth32Float
        let foveated = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveated
        // Both eyes as layers of one texture, which the renderer draws in one pass.
        let layouts = capabilities.supportedLayouts(options: foveated ? [.foveationEnabled] : [])
        configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
    }
}

@main
struct OpenVRLinkApp: App {
    @StateObject private var connection = Connection()
    @StateObject private var store = SettingsStore()
    private let head = HeadTracking()
    private let controllers = ControllerTracking()
    private let hands = HandJoints()
    private let persona = PersonaTracking()
    @StateObject private var calibration = GazeCalibrationRun()
    @StateObject private var measured = MeasuredDisplay()
    @StateObject private var keptDisplay = Kept<RealityKitDisplay>()
    @StateObject private var keptCalibration = Kept<GazeCalibrationSpace>()
    @StateObject private var faceCalibration = FaceCalibrationRun()
    @StateObject private var keptFaceCalibration = Kept<FaceCalibrationSpace>()
    private static var trackingStarted = false

    init() {
        // A log line written after the console that launched the app has
        // gone away must not end the app (it did: "terminated due to signal 13").
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup(id: "entry") {
            // Two tabs, which visionOS shows as an ornament beside the window.
            TabView {
                EntryView(connection: connection, homeButton: controllers.homeButton, store: store, measured: measured,
                          persona: persona)
                    .tabItem { Label("Stream", systemImage: "play.tv") }
                SettingsView(store: store)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                ExperimentsView(store: store, connection: connection, calibration: calibration,
                                faceCalibration: faceCalibration, persona: persona)
                    .tabItem { Label("Experiments", systemImage: "flask") }
            }
                .task {
                    // Once, however often the window is closed and opened again.
                    guard !OpenVRLinkApp.trackingStarted else { return }
                    OpenVRLinkApp.trackingStarted = true
                    head.start()
                    controllers.start()
                    hands.start()
                }
        }
        .defaultSize(width: 560, height: 640)

        ImmersiveSpace(id: "stream") {
            CompositorLayer(configuration: StreamLayerConfiguration()) { layerRenderer in
                CompositorDisplay(layerRenderer, connection: connection, head: head, controllers: controllers,
                                  hands: hands, settings: store, measured: measured)?.start()
            }
        }
        // Mixed, so the system does not fence the wearer into the small area a
        // fully immersive space allows; the picture itself still covers the view.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        // The wearer's real hands, cut out of the cameras' view and laid over the picture.
        .upperLimbVisibility(store.settings.showHandsOverlaid ? .visible : .hidden)
        // The menu that appears on looking at a raised palm, among others.
        .persistentSystemOverlays(store.settings.hideSystemOverlays ? .hidden : .automatic)

        // Experiment: the stream drawn by RealityKit.
        ImmersiveSpace(id: "stream-realitykit") {
            // The same display for as long as the space is open, however often this is asked.
            if let display = keptDisplay.value(unless: \.stopped, make: {
                RealityKitDisplay(connection: connection, head: head, controllers: controllers, hands: hands,
                                  settings: store, persona: persona, measured: measured)
            }) {
                RealityKitStreamView(display: display, persona: persona, settings: store.settings)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(store.settings.showHandsOverlaid ? .visible : .hidden)
        .persistentSystemOverlays(store.settings.hideSystemOverlays ? .hidden : .automatic)

        // A compositor layer opened only to learn what the displays are
        // like, which RealityKit cannot say (`MeasuredDisplay`).
        ImmersiveSpace(id: "measure") {
            CompositorLayer(configuration: StreamLayerConfiguration()) { layerRenderer in
                CompositorDisplay(layerRenderer, connection: connection, head: head, controllers: controllers,
                                  hands: hands, settings: store, measured: measured, measureOnly: true)?.start()
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        // The face calibration of the Persona experiment: expressions to hold.
        ImmersiveSpace(id: "face-calibration") {
            if let space = keptFaceCalibration.value(unless: \.stopped, make: {
                FaceCalibrationSpace(head: head, persona: persona, store: store, run: faceCalibration)
            }) {
                FaceCalibrationView(space: space, run: faceCalibration, persona: persona, settings: store.settings)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.visible)

        // The gaze calibration of the Persona experiment: dots to look at and pinch.
        ImmersiveSpace(id: "calibration") {
            if let space = keptCalibration.value(unless: \.stopped, make: {
                GazeCalibrationSpace(head: head, persona: persona, store: store, run: calibration)
            }) {
                GazeCalibrationView(space: space, run: calibration, persona: persona, settings: store.settings)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.visible)
    }
}

/// Holds on to one object across the many times SwiftUI asks a scene for
/// its content, and makes a new one only when the old one is finished with.
@MainActor
final class Kept<Value: AnyObject>: ObservableObject {
    private var kept: Value?

    func value(unless finished: KeyPath<Value, Bool>, make: () -> Value?) -> Value? {
        if let kept, !kept[keyPath: finished] { return kept }
        kept = make()
        return kept
    }
}

struct EntryView: View {
    @ObservedObject var connection: Connection
    @ObservedObject var homeButton: HomeButton
    @ObservedObject var store: SettingsStore
    let measured: MeasuredDisplay
    let persona: PersonaTracking
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var typedAddress = ""

    /// Open the immersive space, which connects to `address` once it is running.
    private func stream(from address: String) {
        Task {
            connection.hostAddress = address
            var space = "stream"
            if store.settings.realityKitRenderer {
                space = "stream-realitykit"
                // RealityKit cannot say what the displays are like: open a
                // compositor layer for a moment to find out, once.
                if measured.value == nil, case .opened = await openImmersiveSpace(id: "measure") {
                    // It waits for the views to settle, which takes a few seconds (`CompositorDisplay.settledWithin`).
                    for _ in 0..<200 where measured.value == nil { try? await Task.sleep(for: .milliseconds(50)) }
                    await dismissImmersiveSpace()
                    try? await Task.sleep(for: .milliseconds(300))
                }
                guard measured.value != nil else {
                    connection.status = "Could not measure the displays"
                    return
                }
            }
            guard case .opened = await openImmersiveSpace(id: space) else { return }
            connection.immersed = true
            // Opening the app again brings the window back.
            if store.settings.closeWindowOnEntry { dismissWindow(id: "entry") }
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("OpenVRLink").font(.largeTitle)
            if connection.immersed {
                Text(connection.status).font(.title3)
                Button("Stop") {
                    Task {
                        await dismissImmersiveSpace()
                        connection.immersed = false
                    }
                }
            } else {
                if connection.hosts.isEmpty {
                    Text("Looking for computers running Steam").foregroundStyle(.secondary)
                }
                ForEach(connection.hosts, id: \.clientID) { host in
                    Button(host.hostname) { stream(from: host.address) }
                }
                HStack {
                    TextField("Or type an address", text: $typedAddress)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(maxWidth: 280)
                    Button("Connect") { stream(from: typedAddress) }
                        .disabled(typedAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if homeButton.delivery == .systemKeepsIt {
                    // The controller's Home button only reaches the app if the person allows it.
                    Button("Let the controller's Home button open SteamVR") { homeButton.openSettings() }
                        .font(.callout)
                }
                Text(connection.status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .task { connection.searchForHosts() }
    }
}

/// Everything the person can choose, saved as it is changed.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    /// The chroma key color as a color picker wants it. Kept as sRGB values, the way the picker shows them.
    private var keyColour: Binding<Color> {
        Binding(
            get: {
                let c = store.settings.chromaKeyColor
                return Color(.sRGB, red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]))
            },
            set: { picked in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                guard UIColor(picked).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
                store.settings.chromaKeyColor = [red, green, blue].map { Float(max(0, min(1, $0))) }
            })
    }

    private func slider(_ title: String, _ value: Binding<Float>, in range: ClosedRange<Float>, step: Float) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: step)
            Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 50, alignment: .trailing)
        }
    }

    var body: some View {
        Form {
            Section("Hands and controllers") {
                Toggle("Show my hands over the picture", isOn: $store.settings.showHandsOverlaid)
                Toggle("Hide system overlays (the palm gesture)", isOn: $store.settings.hideSystemOverlays)
                Toggle("Knock the controllers together twice, in front of your face, to switch between controllers and hands",
                       isOn: $store.settings.clackSwitchesToHands)
                Toggle("Point by looking and pinching, instead of with the arm", isOn: $store.settings.gazePinchRays)
                Toggle("Send my microphone", isOn: $store.settings.microphone)
                Toggle("Close this window when streaming starts", isOn: $store.settings.closeWindowOnEntry)
            }
            Section {
                Toggle("See the room through one colour of the picture", isOn: $store.settings.chromaKey)
                ColorPicker("Colour", selection: keyColour, supportsOpacity: false)
                // Below the first distance a color is all room; above the second, all picture.
                slider("All room within", $store.settings.chromaKeyNear,
                       in: 0...max(0.01, store.settings.chromaKeyFar - 0.01), step: 0.01)
                slider("All picture beyond", $store.settings.chromaKeyFar, in: 0.01...1, step: 0.01)
                Toggle("Turn it off while a game is running", isOn: $store.settings.chromaKeyOffInGames)
            } header: {
                Text("Chroma key")
            } footer: {
                Text("SteamVR says when a game is running but not which one, so this cannot be set per game.")
            }
            Section {
                slider("Across", $store.settings.fovScaleHorizontal, in: VRLinkCore.Settings.fovScaleRange, step: 0.05)
                slider("Up and down", $store.settings.fovScaleVertical, in: VRLinkCore.Settings.fovScaleRange, step: 0.05)
            } header: {
                Text("Field of view")
            } footer: {
                Text("More than 1 leaves a margin for fast head turns; less gives a smaller, sharper picture. Used from the next connection. The microphone setting is too.")
            }
        }
    }
}


/// Things that may not work: off unless asked for.
struct ExperimentsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var connection: Connection
    @ObservedObject var calibration: GazeCalibrationRun
    @ObservedObject var faceCalibration: FaceCalibrationRun
    let persona: PersonaTracking
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        Form {
            Section {
                Toggle("Face and eye tracking from my Spatial Persona", isOn: $store.settings.faceFromCamera)
            } footer: {
                Text("Reads your expressions off your Persona and sends them to SteamVR as face tracking. Needs the RealityKit renderer below, which keeps the Persona's camera in front of your face.")
            }
            Section {
                Toggle("Draw the stream with RealityKit", isOn: $store.settings.realityKitRenderer)
                Toggle("Show the Persona camera's picture", isOn: $store.settings.showFaceCameraPicture)
            } footer: {
                Text("Slower and less sharp at the edges than the ordinary renderer. Used from the next time streaming starts.")
            }
            Section {
                if let fit = store.settings.gazeCalibration, fit.usable {
                    Text(String(format: "Calibrated from %d pinches, typically %.1f degrees off", fit.sampleCount, fit.typicalErrorDegrees))
                    Button("Forget the calibration", role: .destructive) { store.settings.gazeCalibration = nil }
                    Toggle("Keep calibrating from pinches while streaming", isOn: $store.settings.continuousGazeCalibration)
                        .disabled(fit.samples.isEmpty)
                    if fit.samples.isEmpty {
                        Text("This calibration was saved without its samples. Calibrate once more to keep calibrating while streaming.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not calibrated: the eyes are not sent").foregroundStyle(.secondary)
                }
                if calibration.open {
                    Text(calibration.status)
                    Button("Stop calibrating") { close() }
                } else {
                    Button("Calibrate eye tracking") {
                        Task {
                            calibration.finished = false
                            if case .opened = await openImmersiveSpace(id: "calibration") { calibration.open = true }
                        }
                    }
                    .disabled(!store.settings.faceFromCamera || connection.immersed || faceCalibration.open)
                    if !calibration.status.isEmpty { Text(calibration.status).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Eye tracking")
            } footer: {
                Text("Dots appear in front of you and follow your head. Look at the bright one and pinch, for each of the nineteen. With a calibration, SteamVR's sharp area follows your eyes.")
            }
            Section {
                if let fit = store.settings.faceCalibration, fit.usable {
                    Text("Calibrated to your face")
                    Button("Forget the calibration", role: .destructive) { store.settings.faceCalibration = nil }
                } else {
                    Text("Not calibrated: expressions are guessed with fixed rules").foregroundStyle(.secondary)
                }
                if faceCalibration.open {
                    Text(faceCalibration.status)
                } else {
                    Button("Calibrate face tracking") {
                        Task {
                            faceCalibration.finished = false
                            _ = await openImmersiveSpace(id: "face-calibration")
                        }
                    }
                    .disabled(!store.settings.faceFromCamera || connection.immersed || calibration.open)
                    if !faceCalibration.status.isEmpty { Text(faceCalibration.status).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Face tracking")
            } footer: {
                Text("A panel shows your Persona and asks for nine expressions, about five seconds each. Each expression sent to SteamVR is then measured against your own resting face and your own fullest version of it.")
            }
        }
    }

    private func close() {
        Task {
            await dismissImmersiveSpace()
            calibration.open = false
        }
    }
}
