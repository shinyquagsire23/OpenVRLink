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
import VRLinkVisionRooms
import VRLinkVisionTracking

/// visionOS app entry point, providing a compact host-picker window and
/// immersive spaces for streaming and calibration.

struct StreamLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.colorFormat = .rgba16Float
        configuration.depthFormat = .depth32Float
        let foveated = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveated
        // Allow full-resolution drawable textures when foveation is active.
        // This caps the maximum texture allocation rather than forcing the
        // render resolution (matching the ALVR visionOS client).
        if foveated, #available(visionOS 26.0, *) {
            configuration.maxRenderQuality = .init(1.0)
        }
        // Prefer a layered texture array so both eyes can be rendered in a single pass.
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
    @StateObject private var vergence = VergenceTestRun()
    @StateObject private var keptVergence = Kept<VergenceTestSpace>()
    private static var trackingStarted = false
    /// Lazily initialized bundle of tracking and session dependencies passed to the renderer.
    private let keptInputs = Kept<StreamInputs>()
    private var streamInputs: StreamInputs {
        keptInputs.value {
            StreamInputs(connection: connection, head: head, controllers: controllers, hands: hands,
                         settings: store, measured: measured)
        }
    }
    /// Tracks saved rooms for streaming sessions and Room Setup.
    private let keptRooms = Kept<RoomTracker>()
    private var rooms: RoomTracker {
        keptRooms.value { RoomTracker(connection: connection, head: head) }
    }
    @StateObject private var roomSetup = RoomSetupControls()
    @StateObject private var keptRoomSetup = Kept<RoomSetupSpace>()
    /// Tracks the last launched app version so we can show release notes after an update.
    @AppStorage("lastUsedAppVersion") private var lastUsedAppVersion = "never launched"
    @State private var showChanges = false

    init() {
        // Ignore SIGPIPE so writing logs after a debugging console disconnects
        // doesn't crash the app with signal 13.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        let inputs = streamInputs
        let rooms = self.rooms
        WindowGroup(id: "entry") {
            // visionOS renders the TabView bar as a floating ornament beside the window.
            TabView {
                EntryView(connection: connection, homeButton: controllers.homeButton, store: store, inputs: inputs,
                          persona: persona, rooms: rooms, roomSetup: roomSetup)
                    .tabItem { Label("Stream", systemImage: "play.tv") }
                SettingsView(store: store, connection: connection, rooms: rooms, roomSetup: roomSetup)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                ExperimentsView(store: store, connection: connection, calibration: calibration,
                                faceCalibration: faceCalibration, vergence: vergence, persona: persona)
                    .tabItem { Label("Experiments", systemImage: "flask") }
            }
            // Combined with `.windowResizability(.contentSize)` below, locks the window to a fixed size.
            .frame(width: EntryView.windowSize.width, height: EntryView.windowSize.height)
            .onAppear {
                // Show release notes on the first launch of a new version.
                guard lastUsedAppVersion != AppVersion.current else { return }
                lastUsedAppVersion = AppVersion.current
                showChanges = true
            }
            // Present release notes as a modal sheet in front of the main window.
            .sheet(isPresented: $showChanges) { ChangesView() }
            .task {
                // Start tracking providers once across window close/reopen cycles.
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
            // Holding the Digital Crown recenters the active play space.
            .onWorldRecenter { phase in
                if phase == .ended { rooms.worldRecentered() }
            }
        }
        // Use `.mixed` immersion so visionOS doesn't enforce the tight movement
        // boundary of `.full`, even though our video quad still fills the view.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        // Optionally composite the user's real hands on top of the streamed video.
        .upperLimbVisibility(store.settings.showHandsOverlaid ? .visible : .hidden)
        // Optionally hide system overlays such as the palm-up hand menu.
        .persistentSystemOverlays(store.settings.hideSystemOverlays ? .hidden : .automatic)

        // Experimental RealityKit-based stream renderer.
        ImmersiveSpace(id: "stream-realitykit") {
            // Reuse the same display instance across SwiftUI view evaluations while the space stays open.
            if let display = keptDisplay.value(unless: \.stopped, make: {
                RealityKitDisplay(inputs: inputs, persona: persona)
            }) {
                RealityKitStreamView(display: display, persona: persona, settings: store.settings)
                    .onWorldRecenter { phase in
                        if phase == .ended { rooms.worldRecentered() }
                    }
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(store.settings.showHandsOverlaid ? .visible : .hidden)
        .persistentSystemOverlays(store.settings.hideSystemOverlays ? .hidden : .automatic)

        // Immersive space for creating, positioning, and drawing boundaries for rooms.
        ImmersiveSpace(id: RoomSetupControls.spaceID) {
            if let space = keptRoomSetup.value(unless: \.stopped, make: {
                RoomSetupSpace(rooms: rooms, head: head, controllers: controllers, hands: hands, controls: roomSetup)
            }) {
                RoomSetupView(space: space)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.visible)

        // Floating borderless toolbar for Room Setup controls.
        WindowGroup(id: RoomSetupControls.windowID) {
            RoomSetupControlsView(controls: roomSetup)
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        // Only opened from Room Setup; never restored or shown at app launch.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        // Temporary compositor space opened briefly before the first connection
        // to query display FOV, resolution, and refresh rates (`MeasuredDisplay`).
        ImmersiveSpace(id: "measure") {
            CompositorLayer(configuration: StreamLayerConfiguration()) { layerRenderer in
                CompositorDisplay(layerRenderer, inputs: inputs, measureOnly: true)?.start()
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        // Immersive space for measuring Persona eye-vergence tracking accuracy (`VergenceTestSpace`).
        ImmersiveSpace(id: "vergence-test") {
            if let space = keptVergence.value(unless: \.stopped, make: {
                VergenceTestSpace(head: head, persona: persona, store: store, run: vergence,
                                  eyeMidpoint: measured.value?.eyeMidpoint)
            }) {
                VergenceTestView(space: space, persona: persona, settings: store.settings)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        // Immersive space for calibrating Persona-based facial expression tracking.
        ImmersiveSpace(id: "face-calibration") {
            if let space = keptFaceCalibration.value(unless: \.stopped, make: {
                FaceCalibrationSpace(head: head, persona: persona, store: store, run: faceCalibration)
            }) {
                FaceCalibrationView(space: space, run: faceCalibration, persona: persona, settings: store.settings)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.visible)

        // Immersive space for calibrating Persona-based eye gaze tracking.
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

/// Modal sheet displaying release notes after an app update, sized slightly
/// smaller than the main window.
private struct ChangesView: View {
    @Environment(\.dismiss) private var dismiss
    /// Size reduction relative to `EntryView.windowSize`, in points.
    static let inset: CGFloat = 40

    var body: some View {
        VStack(spacing: 16) {
            Text("OpenVRLink v" + AppVersion.current).font(.title2)
            ScrollView {
                Text(AppVersion.changes)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Dismiss") { dismiss() }
        }
        .padding(24)
        .frame(width: EntryView.windowSize.width - ChangesView.inset,
               height: EntryView.windowSize.height - ChangesView.inset)
    }
}

enum AppVersion {
    /// Formatted version string, e.g. "0.1.0 build 1".
    static let current: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return version + " build " + build
    }()

    // TODO: Remove these changes before App Store

    /// Shown once after each update. Rewrite for each release.
    static let changes = """
    What's changed?

    • Fixed boiling effect when using RealityKit with depth correction
    • Fixed Persona face/eye tracking sometimes not working
    • Fixed WiVRn sometimes crashing on entry 
    • Added companion app+driver to GitHub for extending features to Steam VR Link
    • (Extension) Added encoding gamma for preserving dark detail
    • (Extension) Added aspect-correct resolution for Vision Pro
    • (Extension) Added helper for high-res encoding configuration

    ___________________________

    Known issues:

    • With the RealityKit renderer, taking the headset off and putting it back on does not resume the stream.
    • Framerate selection does not work correctly on M5 Vision Pros
    • Streaming from ARM64 Linux machines (DGX Spark et al) for SteamVR Link is not currently working.
    • PSVR2 models require installing some assets on your PC using scripts from the repo (companion app ETA son)
    """
}

/// Renders the three-layer app icon clipped to a circle, matching the visionOS
/// home screen appearance.
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

/// Caches an object instance across repeated SwiftUI scene body evaluations,
/// recreating it only once it marks itself finished.
@MainActor
final class Kept<Value: AnyObject>: ObservableObject {
    private var kept: Value?

    func value(unless finished: KeyPath<Value, Bool>, make: () -> Value?) -> Value? {
        if let kept, !kept[keyPath: finished] { return kept }
        kept = make()
        return kept
    }

    /// Returns the cached instance, creating it on first access.
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
    let rooms: RoomTracker
    let roomSetup: RoomSetupControls
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    /// Fixed window dimensions in points.
    static let windowSize = CGSize(width: 640, height: 480) // God's intended resolution
    @AppStorage("typedAddress") private var typedAddress = ""
    /// Server protocol for manual IP connections, since we can't infer it from the address.
    @AppStorage("typedAddressKind") private var typedKind = HostKind.steam
    @State private var askingForAddress = false
    @State private var typedPin = ""

    /// Maximum time in seconds to wait for the RealityKit scene to become ready before starting the Persona camera anyway.
    static let longestWaitForScene = 8.0

    /// Connects to `address` and waits for the first decoded video frame before
    /// opening the immersive space so the user isn't placed in a blank scene.
    private func stream(from address: String, kind: HostKind) {
        Task {
            connection.hostAddress = address
            connection.hostKind = kind
            connection.waitingForPicture = true
            defer { connection.waitingForPicture = false }
            // Close Room Setup first because visionOS allows only one open immersive space at a time.
            if roomSetup.open {
                await dismissImmersiveSpace()
                try? await Task.sleep(for: .milliseconds(300))
            }
            // Reset room selection and any temporary recenter offset from the previous session.
            rooms.sessionBegins()
            // Display metrics are only exposed through a CompositorLayer, so we
            // briefly open a measurement space once before the first connection.
            let measured = inputs.measured
            if measured.value == nil {
                connection.status = "Measuring the displays"
                if case .opened = await openImmersiveSpace(id: "measure") {
                    // Wait for the compositor view configuration to settle (`CompositorDisplay.settledWithin`).
                    for _ in 0..<200 where measured.value == nil && connection.waitingForPicture {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    await dismissImmersiveSpace()
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            // Bail out if the user canceled while measuring.
            guard connection.waitingForPicture else { return }
            let realityKit = store.settings.realityKitRenderer
            guard realityKit ? RealityKitDisplay.connect(inputs, persona: persona) : CompositorDisplay.connect(inputs) else {
                connection.status = "Could not measure the displays"
                return
            }
            // Connection progress, pairing PIN prompts, and errors are displayed in the window while waiting.
            while !connection.hasPicture {
                guard connection.active, connection.waitingForPicture else { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            // Opening can fail transiently (most often right after the measurement space was dismissed,
            // or while the system is busy with another scene), so retry briefly before giving up, and
            // report the failure instead of silently returning to the host list.
            var opened = false
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(600)) }
                guard connection.active, connection.waitingForPicture else { return }
                let result = await openImmersiveSpace(id: realityKit ? "stream-realitykit" : "stream")
                if case .opened = result {
                    opened = true
                    break
                }
                print("EntryView: opening the immersive space failed (\(result)), attempt \(attempt + 1) of 3")
                if case .userCancelled = result { break }
            }
            guard opened else {
                connection.stop()
                connection.status = "Could not open the immersive space; try connecting again"
                return
            }
            connection.immersed = true
            let spaceOpened = CACurrentMediaTime()
            func sinceOpening() -> Int { Int((CACurrentMediaTime() - spaceOpened) * 1000) }
            guard realityKit, store.settings.faceFromCamera else {
                // Opening the app again brings the window back.
                if store.settings.closeWindowOnEntry { dismissWindow(id: "entry") }
                return
            }
            // visionOS has undocumented timing requirements between the RealityKit scene, the app
            // window, and the Spatial Persona camera. Headset testing (2026-11-20) showed the
            // following behavior across different startup orders:
            //  - Dismissing the window when the space opened and starting the camera once the scene
            //    was ready worked when scene setup was quick (apart from occasional silent starts),
            //    but produced no frames when scene setup was slow because the window closed before
            //    session startup finished (~9 s), and visionOS requires an open window to start the
            //    Persona camera.
            //  - Starting the camera 200 ms after the space opened, before the scene and camera
            //    anchor were ready, produced no frames.
            //  - Keeping the window open until the first camera frame arrived produced frames, but
            //    left the camera anchored to the window's position instead of following the head.
            //  - Waiting until the scene was ready, then dismissing the window and starting the
            //    camera immediately afterward produced head-tracked frames almost every time.
            //
            // Accordingly, we wait for the scene to report ready, then dismiss the window and start
            // the camera back-to-back, which matches ALVR's visionOS client. Startup timings are
            // logged below to help diagnose any future regressions.
            var waited = 0.0
            while persona.sceneReadyTime < spaceOpened, waited < EntryView.longestWaitForScene, connection.immersed, connection.active {
                try? await Task.sleep(for: .milliseconds(10))
                waited += 0.01
            }
            guard connection.immersed, connection.active else { return }
            let ready = sinceOpening()
            // Dismiss the window and start the camera synchronously on the main actor with no await
            // in between so the window is already closing before the camera session binds to an anchor.
            if store.settings.closeWindowOnEntry { dismissWindow(id: "entry") }
            let started = sinceOpening()
            persona.camera.start()
            for _ in 0..<100 where persona.camera.lastPictureTime < spaceOpened && connection.immersed {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let pictured = persona.camera.lastPictureTime >= spaceOpened ? "\(sinceOpening()) ms" : "timed out after 5 s"
            print("EntryView: Persona camera: scene ready at \(ready) ms"
                  + (persona.sceneReadyTime < spaceOpened ? " (timed out waiting)" : "")
                  + ", window \(store.settings.closeWindowOnEntry ? "dismissed" : "kept open"), camera started at \(started) ms, first frame: \(pictured)")
        }
    }

    /// Renders a button tile for a discovered host.
    private func hostTile(_ name: String, glyph: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: glyph).font(.system(size: 56))
            Text(name).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 12)
        // Enforce a minimum tile size while allowing wider tiles so long hostnames aren't truncated.
        .frame(minWidth: 240, minHeight: 135)
    }

    var body: some View {
        VStack(spacing: 10) {
            // Header with app title/version on the left and icon on the right.
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
                        // Stop the connection with `leaving: true` before dismissing the space;
                        // dismissing first triggers a non-leaving stop that won't tell the host to exit.
                        connection.waitingForPicture = false
                        connection.stop(leaving: true)
                        if connection.immersed { await dismissImmersiveSpace() }
                        connection.immersed = false
                    }
                }
            } else {
                // Use a space when empty to preserve vertical layout height before hosts appear.
                Text(connection.hosts.isEmpty ? " " : "Found On Your Network:").font(.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(connection.hosts) { host in
                            Button { stream(from: host.address, kind: host.kind) } label: {
                                // A machine running both Steam and WiVRn will appear twice, so label WiVRn entries.
                                hostTile(host.kind == .steam ? host.name : host.name + " (WiVRn)", glyph: "desktopcomputer")
                            }
                            .buttonBorderShape(.roundedRectangle(radius: 24))
                        }
                        if connection.hosts.isEmpty {
                            // Placeholder tile matching host tile dimensions so the layout doesn't jump on discovery.
                            Button {} label: { hostTile("Searching...", glyph: "magnifyingglass") }
                                .buttonBorderShape(.roundedRectangle(radius: 24))
                                .disabled(true)
                        }
                    }
                    .padding(.horizontal, 32)
                    // Center tiles when they fit in the window, and scroll horizontally when they overflow.
                    .frame(minWidth: EntryView.windowSize.width)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -32)
                Button { askingForAddress = true } label: {
                    Label("Connect by IP Address", systemImage: "network")
                }
                if homeButton.delivery == .systemKeepsIt {
                    // Prompt the user if visionOS is still intercepting the controller Home button.
                    Button("Let the controller's Home button open SteamVR") { homeButton.openSettings() }
                        .font(.callout)
                }
                Text(connection.status).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(32)
        .task { connection.searchForHosts() }
        // Prompt for the pairing PIN displayed on an unpaired WiVRn host.
        .sheet(isPresented: Binding(get: { connection.askingForPin },
                                    set: { if !$0, connection.askingForPin { connection.answerPin(nil) } })) {
            VStack(spacing: 20) {
                Text("Pair with WiVRn").font(.title2)
                Text("Type the PIN the computer shows.").foregroundStyle(.secondary)
                TextField("000000", text: $typedPin)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .frame(width: 200)
                HStack(spacing: 16) {
                    Button("Cancel") { connection.answerPin(nil) }
                    Button("Pair") {
                        connection.answerPin(typedPin.trimmingCharacters(in: .whitespaces))
                        typedPin = ""
                    }
                    .disabled(typedPin.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(32)
        }
        .sheet(isPresented: $askingForAddress) {
            VStack(spacing: 20) {
                Text("Connect by IP Address").font(.title2)
                TextField("192.168.1.2", text: $typedAddress)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    .frame(width: 280)
                Picker("What it runs", selection: $typedKind) {
                    Text("Steam").tag(HostKind.steam)
                    Text("WiVRn").tag(HostKind.wivrn)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                HStack(spacing: 16) {
                    Button("Cancel") { askingForAddress = false }
                    Button("Connect") {
                        askingForAddress = false
                        stream(from: typedAddress.trimmingCharacters(in: .whitespaces), kind: typedKind)
                    }
                    .disabled(typedAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(32)
        }
    }
}

/// User preferences form; changes are persisted immediately.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var connection: Connection
    let rooms: RoomTracker
    @ObservedObject var roomSetup: RoomSetupControls
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var askingToDeleteRooms = false
    @State private var roomSetupNote = ""

    /// Bridges the stored sRGB float array to a SwiftUI `Color` binding for `ColorPicker`.
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
            Section {
                if roomSetup.open {
                    Button("Leave Room Setup") {
                        Task { await dismissImmersiveSpace() }
                    }
                } else {
                    Button("Room Setup") {
                        Task {
                            roomSetupNote = ""
                            // Mark Room Setup open before opening its toolbar window, since the window dismisses itself when `open` is false.
                            roomSetup.open = true
                            if case .opened = await openImmersiveSpace(id: RoomSetupControls.spaceID) {
                                openWindow(id: RoomSetupControls.windowID)
                            } else {
                                roomSetup.open = false
                                roomSetupNote = "Could not open Room Setup"
                            }
                        }
                    }
                    .disabled(connection.immersed || connection.waitingForPicture)
                    if !roomSetupNote.isEmpty { Text(roomSetupNote).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Rooms")
            }

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
                // Colors closer than `chromaKeyNear` become fully transparent (passthrough); colors beyond `chromaKeyFar` stay opaque.
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

            Section {
                Button("Delete All Rooms") { askingToDeleteRooms = true }
                    .foregroundStyle(.red)
                    .disabled(connection.immersed || connection.waitingForPicture)
            } footer: {
                Text("Removes every room and the world anchors that hold them in place.")
            }
        }
        .contentMargins(.top, 30, for: .scrollContent)
        .confirmationDialog("Delete all rooms?", isPresented: $askingToDeleteRooms, titleVisibility: .visible) {
            Button("Delete All Rooms", role: .destructive) {
                Task { await rooms.anchors.removeEverything() }
            }
        }
    }
}


/// Experimental features, disabled by default.
struct ExperimentsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var connection: Connection
    @ObservedObject var calibration: GazeCalibrationRun
    @ObservedObject var faceCalibration: FaceCalibrationRun
    @ObservedObject var vergence: VergenceTestRun
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
                Toggle("Estimate depth from stereo video", isOn: $store.settings.depthFromPicture)
                Toggle("Display estimated depth (debug)", isOn: $store.settings.showDepth)
                    .disabled(!store.settings.depthFromPicture)
                /*if vergence.open {
                    Text(vergence.status)
                    Button("Stop measuring") { closeVergence() }
                } else {
                    Button("Measure eye convergence") {
                        Task {
                            vergence.finished = false
                            vergence.findings = []
                            vergence.status = ""
                            if case .opened = await openImmersiveSpace(id: "vergence-test") { vergence.open = true }
                        }
                    }
                    .disabled(!store.settings.faceFromCamera || connection.immersed || calibration.open || faceCalibration.open)
                    if !vergence.status.isEmpty { Text(vergence.status).foregroundStyle(.secondary) }
                    ForEach(vergence.findings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }*/
            } header: {
                Text("Reprojection")
            } footer: {
                Text("Estimates scene depth from stream's stereo disparity, so nearby surfaces like the floor don't swim when head motion is overpredicted.")
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
                    .disabled(!store.settings.faceFromCamera || connection.immersed || faceCalibration.open || vergence.open)
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
                    .disabled(!store.settings.faceFromCamera || connection.immersed || calibration.open || vergence.open)
                    if !faceCalibration.status.isEmpty { Text(faceCalibration.status).foregroundStyle(.secondary) }
                }
            }
        }
        .contentMargins(.top, 30, for: .scrollContent)
    }

    private func closeVergence() {
        Task {
            await dismissImmersiveSpace()
            vergence.open = false
        }
    }

    private func close() {
        Task {
            await dismissImmersiveSpace()
            calibration.open = false
        }
    }
}
