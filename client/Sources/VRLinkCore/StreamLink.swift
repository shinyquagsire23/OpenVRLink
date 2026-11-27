// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Represents a decoded video frame produced by a platform decoder, pairing platform-specific image buffers
/// with the `FrameLayout` metadata needed for quad composition.
public protocol StreamFrame {
    var frameID: UInt16 { get }
    var layout: FrameLayout { get }
    /// Number of decoded images in this frame (one per active video stream).
    var pictureCount: Int { get }
}

/// Decodes compressed video frames into platform-specific `StreamFrame` values.
public protocol StreamDecoder: AnyObject {
    associatedtype Frame: StreamFrame
    var onImage: ((Frame) -> Void)? { get set }
    /// Invoked with the frame ID and stream index when decoding fails so the session can request a keyframe.
    var onFailure: ((UInt16, Int) -> Void)? { get set }
    /// Resets decoder state before starting a new streaming session.
    func reset()
    func decode(_ frame: EncodedFrame)
    /// Releases hardware decoder resources when a stream ends and ignores incoming frames until `reset()`.
    func close()
}

extension StreamDecoder {
    public func close() {}
}

/// Manages a streaming connection from host handshake and pairing through active frame decoding,
/// independent of platform UI frameworks.
///
/// The app shell controls when sessions start and stop (for example, when a headset is put on or removed),
/// provides pose callbacks, and surfaces `onStatus` messages. `StreamLink` handles connecting, pairing,
/// transforming poses and frame layouts through `playSpace`, feeding `decoder`, and pushing decoded frames
/// to `frames`.
///
/// `VRLinkAppleSession.Connection` wraps `StreamLink` for SwiftUI, while OpenXR targets pair it with
/// `ClientModel` via `XRClient`.
public final class StreamLink<Decoder: StreamDecoder> {
    /// Pose providers and feedback callbacks for an active stream. Input poses are supplied in raw tracking
    /// space and transformed into `playSpace` by `StreamLink`.
    public struct Inputs {
        public var head: () -> TrackedPose?
        public var hands: () -> [HandInput?]
        public var gaze: () -> Vec3? = { nil }
        public var face: () -> FaceExpressions? = { nil }
        public var power: () -> PowerState? = { nil }
        public var haptic: (HapticPulse) -> Void = { _ in }
        public var refreshRateRequested: (Float) -> Void = { _ in }

        public init(head: @escaping () -> TrackedPose?, hands: @escaping () -> [HandInput?]) {
            self.head = head
            self.hands = hands
        }
    }

    /// Queue of decoded frames ready for display.
    public let frames = DisplayQueue<Decoder.Frame>()
    /// Receives human-readable connection status updates on arbitrary threads.
    public var onStatus: (String) -> Void = { _ in }
    /// Called on the connection thread once streaming starts so the caller can attach audio and microphone I/O.
    public var onStarted: ((any StreamingSession) -> Void)?
    /// Called after the session stops so audio and microphone resources can be released.
    public var onStopped: (() -> Void)?
    /// Called with the reason when a connection attempt fails or the host ends the stream (after `onStatus`).
    public var onFailed: ((String) -> Void)?
    /// Called on the session thread when the host requests a play-space recenter.
    public var onRecenterRequested: (() -> Void)?

    private let decoder: Decoder
    private let lock = NSLock()
    private var current: (any StreamingSession)?
    private var starting = false
    /// Cleared by `stop` to cancel an in-flight connection attempt.
    private var wanted = false
    private var space = PlaySpace.trackingSpace
    private var startedWith: DeviceProfile?
    private var pictureArrived = false

    public init(decoder: Decoder) {
        self.decoder = decoder
        decoder.onFailure = { [weak self] frameID, picture in self?.session?.frameNotDecoded(frameID, picture: picture) }
        decoder.onImage = { [weak self] frame in
            guard let self, let session else { return }
            for picture in 0..<frame.pictureCount { session.frameDecoded(frame.frameID, picture: picture) }
            frames.push(frame)
            lock.lock()
            pictureArrived = current != nil
            lock.unlock()
        }
    }

    /// Returns `false` before `start` or after `stop` has been called, allowing blocking steps such as PIN
    /// prompts to abort a canceled connection attempt. Thread-safe.
    public var isWanted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wanted
    }

    /// The device profile given to the host for the active or starting stream. Thread-safe.
    public var profile: DeviceProfile? {
        lock.lock()
        defer { lock.unlock() }
        return startedWith
    }

    /// Whether this stream has had a frame decoded yet. Thread-safe.
    public var hasPicture: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pictureArrived
    }

    /// Currently active streaming session, or `nil` when idle. Thread-safe.
    public var session: (any StreamingSession)? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Returns `true` while a session is connecting or actively streaming. Thread-safe.
    public var active: Bool {
        lock.lock()
        defer { lock.unlock() }
        return starting || current != nil
    }

    /// Coordinate space reported to the host. Outgoing poses are transformed into `playSpace` and incoming
    /// rendered eye poses are transformed back into tracking space. Thread-safe.
    public var playSpace: PlaySpace {
        get {
            lock.lock()
            defer { lock.unlock() }
            return space
        }
        set {
            lock.lock()
            let boundaryChanged = space.boundary != newValue.boundary
            space = newValue
            let session = current
            lock.unlock()
            if boundaryChanged { session?.setBoundary(newValue.boundary) }
        }
    }

    /// Connects to the host at `address` on a background thread and begins streaming. Ignored if a session is
    /// already connecting or active.
    public func start(_ kind: HostKind, address: String, port: UInt16? = nil, profile: DeviceProfile,
                      connector: HostConnector, inputs: Inputs) {
        lock.lock()
        let busy = starting || current != nil
        starting = !busy
        wanted = true
        if !busy {
            startedWith = profile
            pictureArrived = false
        }
        lock.unlock()
        if busy { return }
        Thread.detachNewThread { [self] in
            defer {
                lock.lock()
                starting = false
                lock.unlock()
            }
            var connector = connector
            let cancelled = connector.cancelled
            connector.cancelled = { [weak self] in
                guard let self else { return true }
                lock.lock()
                defer { lock.unlock() }
                return !wanted || cancelled()
            }
            let show = connector.show
            connector.show = { [weak self] in
                show($0)
                self?.onStatus($0)
            }
            do {
                guard let (session, hostName) = try connector.connect(kind, address: address, port: port, profile: profile)
                else { return }
                session.onLog = connector.log
                session.onEnded = { [weak self, weak session] reason in
                    guard let self, let session, self.session === session else { return }
                    stop()
                    onStatus("The stream ended: \(reason)")
                    onFailed?("The stream ended: \(reason)")
                }
                session.headProvider = { [weak self] in
                    guard let head = inputs.head(), let self else { return nil }
                    return playSpace.entering(head)
                }
                session.handsProvider = { [weak self] in
                    let hands = inputs.hands()
                    guard let space = self?.playSpace else { return hands }
                    return hands.map { $0.map { space.entering($0) } }
                }
                session.gazeProvider = inputs.gaze
                session.faceProvider = inputs.face
                session.headsetPowerProvider = inputs.power
                session.onHaptic = inputs.haptic
                session.onRefreshRateRequested = inputs.refreshRateRequested
                session.onRecenterRequested = { [weak self] in self?.onRecenterRequested?() }
                session.setBoundary(playSpace.boundary)
                decoder.reset()
                session.onFrame = { [decoder, weak self] frame in
                    guard let space = self?.playSpace else { return }
                    decoder.decode(EncodedFrame(frameID: frame.frameID, picture: frame.picture, data: frame.data,
                                                layout: space.leaving(frame.layout)))
                }
                session.start()
                lock.lock()
                let stillWanted = wanted
                if stillWanted { current = session }
                lock.unlock()
                guard stillWanted else {
                    session.stop(leaving: false)
                    return
                }
                onStarted?(session)
                // WiVRn hosts do not send video frames until an OpenXR app starts on the PC.
                onStatus(kind == .steam ? "Streaming from \(hostName)" : "Connected to \(hostName); waiting for an application there")
            } catch {
                onStatus("Could not connect: \(error)")
                onFailed?("Could not connect: \(error)")
            }
        }
    }

    /// Stops the active session or cancels an in-progress connection. Pass `leaving: true` when the user is
    /// intentionally disconnecting rather than temporarily suspending (see `StreamingSession.stop(leaving:)`).
    public func stop(leaving: Bool = false) {
        lock.lock()
        let session = current
        current = nil
        wanted = false
        startedWith = nil
        pictureArrived = false
        lock.unlock()
        frames.clear()
        guard let session else { return }
        session.stop(leaving: leaving)
        decoder.close()
        onStopped?()
    }
}
