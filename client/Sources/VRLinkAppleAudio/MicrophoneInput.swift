// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import VRLinkCore

/// Captures the default microphone, vrlink wants 16-bit mono at 48kHz
///
/// Incoming phone, FaceTime, or VoIP calls interrupt the audio session and stop
/// the capture engine. Because visionOS and iOS don't always post an end-of-interruption
/// notification (for example, when a call banner is declined or ignored), we
/// listen for system audio notifications and also run a watchdog timer to rebuild
/// capture if samples stop arriving.
public final class MicrophoneInput {
    private var engine: AVAudioEngine?
    private let wanted = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(MicrophoneFormat.sampleRate),
                                       channels: 1, interleaved: true)!
    /// Protects `engine`, `sink`, and `stall` across the caller's thread and the main-thread watchdog.
    private let lock = NSLock()
    private var sink: (any MicrophoneSink)?
    private var watchdog: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Timestamp of the most recent microphone sample buffer.
    private let lastCapture = Timestamp()
    /// Treat capture as stalled after 1 second without samples, backing off to 3 seconds
    /// while the mic is in use elsewhere (such as during an active call).
    private var stall = StallWatch(limit: 1, backedOff: 3)

    public init() {}

    deinit {
        watchdog?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        engine?.stop()
    }

    /// Request mic access if we haven't done so already
    public static func requestPermission(_ answer: @escaping (Bool) -> Void) {
        #if os(macOS)
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: answer)
        #else
        AVAudioApplication.requestRecordPermission(completionHandler: answer)
        #endif
    }

    /// Start capturing into `uplink`
    /// Returns False if there is no usable microphone
    public func start(into uplink: any MicrophoneSink) -> Bool {
        lock.lock()
        sink = uplink
        let started = begin()
        if !started { sink = nil }
        lock.unlock()
        guard started else {
            AudioOutput.alsoRecording = false
            return false
        }
        // Attach the watchdog timer and notification observers on the main run loop regardless of which thread called start().
        DispatchQueue.main.async { [self] in
            lock.lock()
            let wanted = sink != nil
            lock.unlock()
            guard wanted, watchdog == nil else { return }
            observe()
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        }
        return true
    }

    public func stop() {
        AudioOutput.alsoRecording = false
        lock.lock()
        sink = nil
        tearDown()
        lock.unlock()
        DispatchQueue.main.async { [self] in
            watchdog?.invalidate()
            watchdog = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }

    /// Stops and discards the current engine. Call with `lock` held.
    private func tearDown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Creates a new `AVAudioEngine` and starts capturing into `sink`. Call with `lock` held.
    /// We recreate the engine instead of restarting the existing instance because an interrupted
    /// `AVAudioEngine` can hold onto a stale input format and produce no samples.
    private func begin() -> Bool {
        tearDown()
        guard let uplink = sink else { return false }
        #if !os(macOS)
        // Playing and recording together. AudioOutput watches for the
        // interruption this change can cause and restarts itself.
        AudioOutput.alsoRecording = true
        let session = AVAudioSession.sharedInstance()
        // Make sure that the microphone has noise cancellation/voice isolation
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .allowBluetoothA2DP, .allowAirPlay])
        // Re-activate the session if an interruption deactivated it. This fails harmlessly if a call is still using the mic.
        try? session.setActive(true)
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Keep voice processing from heavily ducking audio from other apps.
        if input.isVoiceProcessingEnabled {
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: wanted)
        else { return false }
        let stamp = lastCapture
        // Returns about 10 ms at a time
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 100), format: format) { [wanted] buffer, _ in
            stamp.now()
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * wanted.sampleRate / format.sampleRate) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: wanted, frameCapacity: capacity) else { return }
            var given = false
            converter.convert(to: converted, error: nil) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            guard converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }
            let bytes = UnsafeRawBufferPointer(start: samples, count: Int(converted.frameLength) * 2)
            uplink.capture(Bytes(bytes))
        }
        do {
            try engine.start()
        } catch {
            print("MicrophoneInput: could not start capturing: \(error)")
            input.removeTap(onBus: 0)
            return false
        }
        self.engine = engine
        lastCapture.now()
        return true
    }

    /// Rebuilds the capture engine after an audio session or hardware notification.
    private func restart(because reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard sink != nil else { return }
        print("MicrophoneInput: \(reason), rebuilding capture")
        if !begin() { print("MicrophoneInput: microphone not available yet, will retry") }
    }

    /// Called periodically by the watchdog timer to rebuild capture if samples stop arriving.
    private func check() {
        lock.lock()
        let wanted = sink != nil, stalled = wanted && stall.shouldRestart(quietFor: lastCapture.secondsSince())
        lock.unlock()
        if stalled { restart(because: "no samples for \(String(format: "%.1f", lastCapture.secondsSince())) s") }
    }

    private func observe() {
        let center = NotificationCenter.default
        // AVAudioEngine stops when the input device or format changes. Since each rebuild creates
        // a new engine instance, we observe all engines and check whether the notification came from ours.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.lock.lock()
            let mine = (note.object as? AVAudioEngine) === self.engine && self.engine != nil
            self.lock.unlock()
            if mine { self.restart(because: "input configuration changed") }
        })
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw.flatMap(AVAudioSession.InterruptionType.init) == .ended { self?.restart(because: "interruption ended") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                                            queue: .main) { [weak self] _ in
            self?.restart(because: "media services were reset")
        })
        #endif
    }
}
