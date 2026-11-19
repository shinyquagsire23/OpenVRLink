// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import VRLinkCore

/// Plays the session's audio through the default output device, and keeps
/// itself alive--
///
/// visionOS is basically an iPad, so only one source can run at a time,
/// meaning that system sounds, other apps and the Digital Crown can sometimes
/// interrupt the audio session, and the OS will just stop asking for audio with 
/// no error. So the output watches for the notifications that exist and, because
/// some stops have none, also checks a few times a second that CoreAudio is still 
/// asking. If not, we rebuild the session.
public final class AudioOutput {
    /// Set while the microphone is in use, so that rebuilding the output
    /// does not put the audio session back into a playback-only mode
    public static var alsoRecording = false

    private let buffer: PlaybackBuffer
    private var engine: AVAudioEngine?
    private var watchdog: Timer?
    private var observers: [NSObjectProtocol] = []
    /// When the sound card last asked for audio.
    private let lastRender = Timestamp()
    /// Treat the output as stopped after 0.5 seconds without a render callback,
    /// backing off to 3 seconds after repeated restarts fail to recover it.
    private var stall = StallWatch(limit: 0.5, backedOff: 3)

    public init?(buffer: PlaybackBuffer) {
        self.buffer = buffer
        configureSession()
        guard start() else { return nil }
        observeSession()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    deinit {
        watchdog?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        engine?.stop()
    }

    /// Rebuild the output from scratch. 
    /// Called when the app is re-foregrounded or an immersive space resumes to make sure audio keeps pumping
    public func resume() {
        configureSession()
        _ = start()
    }

    private func configureSession() {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        do {
            if AudioOutput.alsoRecording {
                // Make sure that the mic mode is set to do noise cancellation
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .allowBluetoothA2DP, .allowAirPlay])
            } else {
                // Allow mixing with audio from other apps (such as Mac Virtual Display running
                // alongside an immersive space) so starting playback doesn't silence them.
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setPreferredSampleRate(Double(PlaybackBuffer.sampleRate))
            try session.setActive(true)
            // Direct stereo (other modes follow windows)
            try session.setPreferredOutputNumberOfChannels(PlaybackBuffer.channels)
            #if os(visionOS)
            try session.setIntendedSpatialExperience(.bypassed)
            #endif
        } catch {
            print("AudioOutput: session setup failed: \(error)")
        }
        #endif
    }

    /// Creates a new AVAudioEngine and starts it
    private func start() -> Bool {
        engine?.stop()
        engine = nil

        print("AudioOutput: stopping and rebuilding AVAudioEngine")

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PlaybackBuffer.sampleRate),
                                         channels: AVAudioChannelCount(PlaybackBuffer.channels), interleaved: true)
        else { return false }
        let buffer = self.buffer, stamp = lastRender

        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            stamp.now()
            let list = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = list.first?.mData else { return noErr }
            let count = Int(frameCount) * PlaybackBuffer.channels
            buffer.read(into: UnsafeMutableBufferPointer(start: data.bindMemory(to: Int16.self, capacity: count), count: count))
            return noErr
        }
        let engine = AVAudioEngine()
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            print("AudioOutput: could not start output: \(error)")
            return false
        }
        self.engine = engine
        lastRender.now()
        return true
    }

    private func check() {
        guard stall.shouldRestart(quietFor: lastRender.secondsSince()) else { return }

        print("AudioOutput: output went quiet, rebuilding...")
        resume()
    }

    /// Sets up observers to make sure that audio doesn't go dead for too long
    private func observeSession() {
        #if !os(macOS)
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw.flatMap(AVAudioSession.InterruptionType.init) == .ended { self?.resume() }
        })
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: .main) { [weak self] _ in
                self?.resume()
            })
        }
        #endif
    }
}
