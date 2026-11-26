// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Holds UI state and handles user actions for the client without depending on a UI framework.
///
/// `ClientModel` tracks discovered hosts, connection status, pairing PIN prompts, and user settings, and provides
/// methods for connecting, disconnecting, answering PIN prompts, and changing settings. On visionOS,
/// `VRLinkAppleSession.Connection` republishes this model to SwiftUI; on OpenXR platforms, `VRLinkPanel` draws it
/// with Dear ImGui.
///
/// The app shell provides `startStream` and `stopStream` closures to run the session and reports lifecycle events
/// back through `show`, `streamStarted`, `streamPaused`, and `streamEnded`. All properties and methods are
/// thread-safe, and `onChange` runs on whichever thread made the change.
public final class ClientModel {
    /// Connection target specifying the host protocol, address, optional port, and display name.
    public struct Target: Equatable, Codable {
        public var kind: HostKind
        public var address: String
        public var port: UInt16?
        /// Display name shown in the UI (defaults to `address`).
        public var name: String

        public init(kind: HostKind, address: String, port: UInt16? = nil, name: String? = nil) {
            self.kind = kind
            self.address = address
            self.port = port
            self.name = name ?? address
        }

        public init(_ host: FoundHost) {
            self.init(kind: host.kind, address: host.address, port: host.port, name: host.name)
        }

        /// Parses `steam://address`, `wivrn://address[:port]`, or a bare address (defaulting to `kind`).
        public init?(parsing text: String, kind: HostKind = .steam) {
            var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var kind = kind
            if rest.hasPrefix("steam://") {
                kind = .steam
                rest = String(rest.dropFirst("steam://".count))
            } else if rest.hasPrefix("wivrn://") {
                kind = .wivrn
                rest = String(rest.dropFirst("wivrn://".count))
            }
            var port: UInt16?
            if kind == .wivrn, let colon = rest.lastIndex(of: ":"), let given = UInt16(rest[rest.index(after: colon)...]) {
                port = given
                rest = String(rest[..<colon])
            }
            guard !rest.isEmpty else { return nil }
            self.init(kind: kind, address: rest, port: port)
        }
    }

    public enum Phase: Equatable {
        /// Idle state showing the discovered host list.
        case choosing
        /// Connecting, pairing, or waiting for the session to start.
        case connecting
        /// Active streaming session.
        case streaming
    }

    /// Snapshot of UI-visible connection state.
    public struct State: Equatable {
        public var phase = Phase.choosing
        /// Status message, Steam pairing PIN instructions, or error description.
        public var status = "Not connected"
        public var hosts: [FoundHost] = []
        /// True when an unpaired WiVRn host is waiting for the user to enter its PIN via `answerPin(_:)`.
        public var askingForPin = false
        /// Currently active or connecting host. Retained across temporary pauses (such as removing the headset)
        /// so the shell can reconnect automatically.
        public var target: Target?

        public init() {}
    }

    /// Persists the last manually entered IP address and protocol across launches.
    public struct Remembered: Codable, Equatable {
        public var address = ""
        public var kind = HostKind.steam
        public init() {}
    }

    public let finder: HostFinder
    /// Called after any change to `state`, `settings`, or `remembered`.
    public var onChange: (() -> Void)?
    /// Called on the caller's thread to start streaming from the selected target.
    public var startStream: ((Target) -> Void)?
    /// Called to stop the active stream; `leaving` is `true` when initiated by the user so the host closes the session.
    public var stopStream: ((_ leaving: Bool) -> Void)?
    /// Called with the updated settings after a change.
    public var onSettings: ((Settings) -> Void)?

    private let lock = NSLock()
    private var held = State()
    private var heldSettings: Settings
    private var heldRemembered: Remembered
    private var pinAnswer: String??
    private let saving = DispatchQueue(label: "client-model", qos: .utility)
    private let settingsFile: URL, rememberedFile: URL

    public init(finder: HostFinder, folder: URL = DataDirectory.url) {
        self.finder = finder
        settingsFile = folder.appendingPathComponent("settings.json")
        rememberedFile = folder.appendingPathComponent("panel.json")
        heldSettings = Settings.load(from: settingsFile)
        heldRemembered = (try? JSONDecoder().decode(Remembered.self, from: Data(contentsOf: rememberedFile))) ?? Remembered()
        finder.busy = { [weak self] in self?.state.phase != .choosing }
        finder.onChange = { [weak self] hosts in self?.change { $0.hosts = hosts } }
    }

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    private func change(_ body: (inout State) -> Void) {
        lock.lock()
        let before = held
        body(&held)
        let changed = held != before
        lock.unlock()
        if changed { onChange?() }
    }

    // MARK: Settings

    /// Validated user settings; assigning a new value saves `settings.json` asynchronously.
    public var settings: Settings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return heldSettings
        }
        set {
            let tidy = newValue.tidied()
            lock.lock()
            let changed = heldSettings != tidy
            heldSettings = tidy
            lock.unlock()
            guard changed else { return }
            saving.async { [settingsFile] in tidy.save(to: settingsFile) }
            onSettings?(tidy)
            onChange?()
        }
    }

    public var remembered: Remembered {
        get {
            lock.lock()
            defer { lock.unlock() }
            return heldRemembered
        }
        set {
            lock.lock()
            let changed = heldRemembered != newValue
            heldRemembered = newValue
            lock.unlock()
            guard changed else { return }
            saving.async { [rememberedFile] in
                try? FileManager.default.createDirectory(at: rememberedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(newValue).write(to: rememberedFile, options: .atomic)
            }
            onChange?()
        }
    }

    // MARK: User actions

    /// Starts background host discovery.
    public func search() {
        finder.start()
    }

    /// Starts connecting to a discovered host.
    public func connect(to host: FoundHost) {
        connect(to: Target(host))
    }

    /// Starts connecting to `target` if not already connecting or streaming.
    public func connect(to target: Target) {
        var begun = false
        change {
            guard $0.phase == .choosing else { return }
            $0.phase = .connecting
            $0.target = target
            $0.status = "Connecting to \(target.name)"
            begun = true
        }
        if begun { startStream?(target) }
    }

    /// Connects to the last manually entered address in `remembered`, if valid.
    public func connectToTyped() {
        let typed = remembered
        guard let target = Target(parsing: typed.address, kind: typed.kind) else { return }
        connect(to: target)
    }

    /// Cancels an in-progress connection or disconnects an active stream at the user's request.
    public func stop() {
        var had = false
        change {
            had = $0.phase != .choosing
            $0.phase = .choosing
            $0.target = nil
            $0.askingForPin = false
            if had { $0.status = "Not connected" }
        }
        lock.lock()
        if pinAnswer == nil { pinAnswer = .some(nil) }
        lock.unlock()
        guard had else { return }
        stopStream?(true)
        finder.restartServices()
    }

    /// Submits the user-entered WiVRn pairing PIN (or `nil` to cancel) to a waiting `askPin` call.
    public func answerPin(_ pin: String?) {
        lock.lock()
        pinAnswer = .some(pin)
        lock.unlock()
        change { $0.askingForPin = false }
    }

    // MARK: Shell callbacks

    /// Logs and updates the displayed status string (used for `HostConnector.show`).
    public func show(_ status: String) {
        Log.note(status)
        change { $0.status = status }
    }

    /// Blocks until the user submits a WiVRn pairing PIN or `canceled` returns `true` (used for
    /// `HostConnector.askPin`). The host times out on its own after two minutes.
    public func askPin(canceled: () -> Bool) -> String? {
        lock.lock()
        pinAnswer = nil
        lock.unlock()
        change { $0.askingForPin = true }
        defer { change { $0.askingForPin = false } }
        while !canceled() {
            lock.lock()
            let answer = pinAnswer
            lock.unlock()
            if let answer { return answer }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    /// Marks the connection phase as actively streaming.
    public func streamStarted() {
        change { if $0.phase == .connecting { $0.phase = .streaming } }
    }

    /// Marks the stream as paused while keeping `target` set so the shell can resume when the session becomes
    /// active again.
    public func streamPaused() {
        change {
            guard $0.phase != .choosing else { return }
            $0.phase = .connecting
            $0.status = "Paused"
        }
    }

    /// Transitions a running stream back to `.connecting` and displays `why`, keeping `target` set so the
    /// client can reconnect automatically (for example, after a SteamVR restart or network interface change).
    public func streamInterrupted(_ why: String) {
        change {
            guard $0.phase != .choosing else { return }
            $0.phase = .connecting
            $0.askingForPin = false
            $0.status = why
        }
    }

    /// Resets back to the host list and displays `why` after a connection failure or host disconnect.
    public func streamEnded(_ why: String) {
        change {
            $0.phase = .choosing
            $0.target = nil
            $0.askingForPin = false
            $0.status = why
        }
        finder.restartServices()
    }
}
