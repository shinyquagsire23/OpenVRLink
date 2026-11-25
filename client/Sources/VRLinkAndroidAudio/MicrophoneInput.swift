// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(Android)
import CAndroidNDK
import Foundation
import VRLinkCore

/// Captures 48 kHz mono 16-bit PCM audio (`MicrophoneFormat`) via AAudio and forwards buffers to a `MicrophoneSink`.
///
/// Requires `android.permission.RECORD_AUDIO` to be granted before calling `start(into:)`.
public final class MicrophoneInput {
    private var stream: OpaquePointer?
    private weak var sink: (any MicrophoneSink)?

    public init() {}

    deinit { stop() }

    /// Starts capturing into `sink`; returns `false` if the microphone stream could not be opened.
    public func start(into sink: any MicrophoneSink) -> Bool {
        stop()
        self.sink = sink
        var builder: OpaquePointer?
        guard AAudio_createStreamBuilder(&builder) == Int32(AAUDIO_OK), let builder else { return false }
        defer { AAudioStreamBuilder_delete(builder) }
        AAudioStreamBuilder_setDirection(builder, Int32(AAUDIO_DIRECTION_INPUT))
        AAudioStreamBuilder_setFormat(builder, Int32(AAUDIO_FORMAT_PCM_I16))
        AAudioStreamBuilder_setChannelCount(builder, 1)
        AAudioStreamBuilder_setSampleRate(builder, Int32(MicrophoneFormat.sampleRate))
        AAudioStreamBuilder_setPerformanceMode(builder, Int32(AAUDIO_PERFORMANCE_MODE_LOW_LATENCY))
        // Use the voice-communication preset to enable platform acoustic echo cancellation.
        AAudioStreamBuilder_setInputPreset(builder, Int32(AAUDIO_INPUT_PRESET_VOICE_COMMUNICATION))
        AAudioStreamBuilder_setDataCallback(builder, { _, context, audio, frames in
            guard let context else { return Int32(AAUDIO_CALLBACK_RESULT_STOP) }
            let input = Unmanaged<MicrophoneInput>.fromOpaque(context).takeUnretainedValue()
            // Forward little-endian 16-bit PCM samples to the sink.
            input.sink?.capture(Bytes(UnsafeRawBufferPointer(start: audio, count: Int(frames) * 2)))
            return Int32(AAUDIO_CALLBACK_RESULT_CONTINUE)
        }, Unmanaged.passUnretained(self).toOpaque())
        guard AAudioStreamBuilder_openStream(builder, &stream) == Int32(AAUDIO_OK), let stream else {
            self.stream = nil
            return false
        }
        guard AAudioStream_requestStart(stream) == Int32(AAUDIO_OK) else {
            stop()
            return false
        }
        return true
    }

    public func stop() {
        guard let stream else { return }
        AAudioStream_requestStop(stream)
        AAudioStream_close(stream)
        self.stream = nil
    }
}
#endif
