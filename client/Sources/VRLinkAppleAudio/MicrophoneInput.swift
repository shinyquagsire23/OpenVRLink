// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import VRLinkCore

/// Captures the default microphone, vrlink wants 16-bit mono at 48kHz
public final class MicrophoneInput {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let wanted = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(MicrophoneUplink.sampleRate),
                                       channels: 1, interleaved: true)!

    public init() {}

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
    public func start(into uplink: MicrophoneUplink) -> Bool {
        #if !os(macOS)
        // Playing and recording together. AudioOutput watches for the
        // interruption this change can cause and restarts itself.
        AudioOutput.alsoRecording = true
        let session = AVAudioSession.sharedInstance()
        // Make sure that the microphone has noise cancellation/voice isolation
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .allowBluetoothA2DP, .allowAirPlay])
        try? session.setActive(true)
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: wanted)
        else { return false }
        self.converter = converter
        // Returns about 10 ms at a time
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 100), format: format) { [wanted] buffer, _ in
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
            return true
        } catch {
            print("MicrophoneInput: could not start capturing: \(error)")
            input.removeTap(onBus: 0)
            return false
        }
    }

    public func stop() {
        AudioOutput.alsoRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
