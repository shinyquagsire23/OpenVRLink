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
        // Room for drawing at the full quality the displays can show: this
        // sets how large the drawable's textures may be, not the quality
        // drawn at (the ALVR visionOS client does the same).
        if foveated, #available(visionOS 26.0, *) {
            configuration.maxRenderQuality = .init(1.0)
        }
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
    /// What a stream is asked for with: made on first use, since it is made of the above.
    private let keptInputs = Kept<StreamInputs>()
    private var streamInputs: StreamInputs {
        keptInputs.value {
            StreamInputs(connection: connection, head: head, controllers: controllers, hands: hands,
                         settings: store, measured: measured)
        }
    }
    /// The version this app was when it last ran here, to notice an update.
    @AppStorage("lastUsedAppVersion") private var lastUsedAppVersion = "never launched"
    @State private var showChanges = false

    init() {
        // A log line written after the console that launched the app has
        // gone away must not end the app (it did: "terminated due to signal 13").
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        let inputs = streamInputs
        WindowGroup(id: "entry") {
            // Two tabs, which visionOS shows as an ornament beside the window.
            TabView {
                EntryView(connection: connection, homeButton: controllers.homeButton, store: store, inputs: inputs,
                          persona: persona)
                    .tabItem { Label("Stream", systemImage: "play.tv") }
                SettingsView(store: store)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                ExperimentsView(store: store, connection: connection, calibration: calibration,
                                faceCalibration: faceCalibration, persona: persona)
                    .tabItem { Label("Experiments", systemImage: "flask") }
            }
            // With the scene's `.contentSize` below, a window of one size.
            .frame(width: EntryView.windowSize.width, height: EntryView.windowSize.height)
            .onAppear {
                // Once for each version of the app: say what is new in it.
                guard lastUsedAppVersion != AppVersion.current else { return }
                lastUsedAppVersion = AppVersion.current
                showChanges = true
            }
            .alert("OpenVRLink v" + AppVersion.current, isPresented: $showChanges) {
                Button("Dismiss") {}
            } message: {
                Text(AppVersion.changes)
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
        .windowResizability(.contentSize)

        ImmersiveSpace(id: "stream") {
            CompositorLayer(configuration: StreamLayerConfiguration()) { layerRenderer in
                CompositorDisplay(layerRenderer, inputs: inputs)?.start()
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
                RealityKitDisplay(inputs: inputs, persona: persona)
            }) {
                RealityKitStreamView(display: display, persona: persona, settings: store.settings)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(store.settings.showHandsOverlaid ? .visible : .hidden)
        .persistentSystemOverlays(store.settings.hideSystemOverlays ? .hidden : .automatic)

        // A compositor layer opened only to learn what the displays are
        // like, before the first connection (`MeasuredDisplay`).
        ImmersiveSpace(id: "measure") {
            CompositorLayer(configuration: StreamLayerConfiguration()) { layerRenderer in
                CompositorDisplay(layerRenderer, inputs: inputs, measureOnly: true)?.start()
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

/// Which version of the app this is, and what is new in it.
enum AppVersion {
    /// As in "0.1.0 build 1".
    static let current: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return version + " build " + build
    }()

    /// Shown once after each update. Rewrite for each release.
    static let changes = """
    What's changed?

    • First test build of OpenVRLink!

    ___________________________

    Known issues:

    • With the RealityKit renderer, taking the headset off and putting it back on does not resume the stream.
    """
}

/// The app's icon, flat: its three layers one over the other, cut round as
/// visionOS shows it.
struct AppIconView: View {
    var body: some View {
        ZStack {
            ForEach(["IconBack", "IconMiddle", "IconFront"], id: \.self) { layer in
                if let image = UIImage(named: layer) {
                    Image(uiImage: image).resizable()
                }
            }
        }
        .clipShape(Circle())
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

    /// The one object, made the first time it is asked for.
    func value(make: () -> Value) -> Value {
        if let kept { return kept }
        let made = make()
        kept = made
        return made
    }
}

struct EntryView: View {
    @ObservedObject var connection: Connection
    @ObservedObject var homeButton: HomeButton
    @ObservedObject var store: SettingsStore
    let inputs: StreamInputs
    let persona: PersonaTracking
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    /// The window is this size and cannot be made another.
    static let windowSize = CGSize(width: 640, height: 480) // God's intended resolution
    @AppStorage("typedAddress") private var typedAddress = ""
    @State private var askingForAddress = false

    /// Connect to `address`, and open the immersive space when there is
    /// a picture to show in it: until then the wearer stays where they
    /// were, in an environment for one.
    private func stream(from address: String) {
        Task {
            connection.hostAddress = address
            connection.waitingForPicture = true
            defer { connection.waitingForPicture = false }
            // Only a compositor layer is told what the displays are like:
            // one is opened for a moment to find out, once.
            let measured = inputs.measured
            if measured.value == nil {
                connection.status = "Measuring the displays"
                if case .opened = await openImmersiveSpace(id: "measure") {
                    // It waits for the views to settle, which takes a few seconds (`CompositorDisplay.settledWithin`).
                    for _ in 0..<200 where measured.value == nil && connection.waitingForPicture {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    await dismissImmersiveSpace()
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            // Stopped meanwhile.
            guard connection.waitingForPicture else { return }
            let realityKit = store.settings.realityKitRenderer
            guard realityKit ? RealityKitDisplay.connect(inputs, persona: persona) : CompositorDisplay.connect(inputs) else {
                connection.status = "Could not measure the displays"
                return
            }
            // Its progress, a pairing PIN and its failure are all shown in the window meanwhile.
            while !connection.hasPicture {
                guard connection.active, connection.waitingForPicture else { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard case .opened = await openImmersiveSpace(id: realityKit ? "stream-realitykit" : "stream") else {
                connection.stop()
                return
            }
            connection.immersed = true
            // Opening the app again brings the window back.
            if store.settings.closeWindowOnEntry { dismissWindow(id: "entry") }
        }
    }

    /// What one button of the gallery of computers shows.
    private func hostTile(_ name: String, glyph: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: glyph).font(.system(size: 56))
            Text(name).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 12)
        // Wide, and wider still for a long name, so the name is never cut short.
        .frame(minWidth: 240, minHeight: 135)
    }

    var body: some View {
        VStack(spacing: 10) {
            // Name and version in the top left corner, the icon in the top right.
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpenVRLink").font(.largeTitle)
                    Text("v" + AppVersion.current).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                AppIconView().frame(width: 64, height: 64)
            }
            Spacer()
            if connection.immersed || connection.waitingForPicture {
                Text(connection.status).font(.title3)
                Button("Stop") {
                    Task {
                        // The connection first: the space going away also
                        // stops it, and that way the host is not told goodbye.
                        connection.waitingForPicture = false
                        connection.stop(leaving: true)
                        if connection.immersed { await dismissImmersiveSpace() }
                        connection.immersed = false
                    }
                }
            } else {
                // Blank until there is one, and keeping its place meanwhile.
                Text(connection.hosts.isEmpty ? " " : "Found On Your Network:").font(.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(connection.hosts, id: \.clientID) { host in
                            Button { stream(from: host.address) } label: {
                                hostTile(host.hostname, glyph: "desktopcomputer")
                            }
                            .buttonBorderShape(.roundedRectangle(radius: 24))
                        }
                        if connection.hosts.isEmpty {
                            // Stands where the first computer will, so nothing moves when it is found.
                            Button {} label: { hostTile("Searching...", glyph: "magnifyingglass") }
                                .buttonBorderShape(.roundedRectangle(radius: 24))
                                .disabled(true)
                        }
                    }
                    .padding(.horizontal, 32)
                    // In the middle while they fit; scrolling once they do not.
                    .frame(minWidth: EntryView.windowSize.width)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -32)
                Button { askingForAddress = true } label: {
                    Label("Connect by IP Address", systemImage: "network")
                }
                if homeButton.delivery == .systemKeepsIt {
                    // The controller's Home button only reaches the app if the person allows it.
                    Button("Let the controller's Home button open SteamVR") { homeButton.openSettings() }
                        .font(.callout)
                }
                Text(connection.status).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(32)
        .task { connection.searchForHosts() }
        .sheet(isPresented: $askingForAddress) {
            VStack(spacing: 20) {
                Text("Connect by IP Address").font(.title2)
                TextField("192.168.1.2", text: $typedAddress)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    .frame(width: 280)
                HStack(spacing: 16) {
                    Button("Cancel") { askingForAddress = false }
                    Button("Connect") {
                        askingForAddress = false
                        stream(from: typedAddress.trimmingCharacters(in: .whitespaces))
                    }
                    .disabled(typedAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(32)
        }
    }
}

/// Everything the person can choose, saved as it is changed.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    /// The chroma key color as a color picker wants it. Kept as sRGB values, the way the picker shows them.
    private var keyColor: Binding<Color> {
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
            Section("Audio") {
                Toggle("Send my microphone", isOn: $store.settings.microphone)
            }

            Section("Hands and controllers") {
                Toggle("Show my hands over the picture", isOn: $store.settings.showHandsOverlaid)
                Toggle("Hide system overlays (palm gesture)", isOn: $store.settings.hideSystemOverlays)
                Toggle("Switch between controllers and hands by looking at and clacking them together twice",
                       isOn: $store.settings.clackSwitchesToHands)
                Toggle("Enable Gaze-Pinch interactions", isOn: $store.settings.gazePinchRays)
            }

            Section("Chroma key") {
                Toggle("Enable Chroma-keyed passthrough", isOn: $store.settings.chromaKey)
                ColorPicker("Color", selection: keyColor, supportsOpacity: false)
                // Below the first distance a color is all room; above the second, all picture.
                slider("Min Color Distance", $store.settings.chromaKeyNear,
                       in: 0...max(0.01, store.settings.chromaKeyFar - 0.01), step: 0.01)
                slider("Max Color Distance", $store.settings.chromaKeyFar, in: 0.01...1, step: 0.01)
                Toggle("Disable passthrough during games", isOn: $store.settings.chromaKeyOffInGames)
            }

            Section {
                slider("Across", $store.settings.fovScaleHorizontal, in: VRLinkCore.Settings.fovScaleRange, step: 0.05)
                slider("Up and down", $store.settings.fovScaleVertical, in: VRLinkCore.Settings.fovScaleRange, step: 0.05)
            } header: {
                Text("Field of view")
            } footer: {
                Text("Increase FoV for timewarp comfort, or sacrifice FoV for sharpness")
            }

            Section("Other") {
                Toggle("Close this window when streaming starts", isOn: $store.settings.closeWindowOnEntry)
            }
        }
        .contentMargins(.top, 30, for: .scrollContent)
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
                Toggle("Render stream with RealityKit", isOn: $store.settings.realityKitRenderer)
                Toggle("Display Persona camera (debug)", isOn: $store.settings.showFaceCameraPicture)
            } header: {
                Text("Renderer")
            } footer: {
                Text("Not recommended; may break in future updates")
            }

            Section {
                Toggle("Show PS VR2 Sense controller models", isOn: $store.settings.senseControllerModels)
            } header: {
                Text("Controllers")
            } footer: {
                Text("Requires the OpenVRLink controller models installed in SteamVR on your PC, otherwise Touch controllers are shown")
            }

            Section {
                Toggle("Enable face and eye tracking", isOn: $store.settings.faceFromCamera)
            } header: {
                Text("Tracking")
            } footer: {
                Text("Face and eye tracking eequires the RealityKit renderer")
            }

            Section("Eye Tracking") {
                if let fit = store.settings.gazeCalibration, fit.usable {
                    //Text(String(format: "Current calibration: %d pinches, ~%.1f degrees off", fit.sampleCount, fit.typicalErrorDegrees))
                    Button("Discard calibration", role: .destructive) { store.settings.gazeCalibration = nil }
                    Toggle("Enable Continuous Calibration", isOn: $store.settings.continuousGazeCalibration)
                        .disabled(fit.samples.isEmpty)
                    if fit.samples.isEmpty {
                        Text("This calibration was saved without its samples. Calibrate again to enable continuous calibration.")
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
            }

            Section("Face Tracking") {
                if let fit = store.settings.faceCalibration, fit.usable {
                    Button("Discard calibration", role: .destructive) { store.settings.faceCalibration = nil }
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
            }
        }
        .contentMargins(.top, 30, for: .scrollContent)
    }

    private func close() {
        Task {
            await dismissImmersiveSpace()
            calibration.open = false
        }
    }
}
