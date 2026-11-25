// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(Android)
import CAndroidNDK
import Foundation
import VRLinkCore

/// Plays 48 kHz stereo PCM audio on Android using an AAudio low-latency output callback.
///
/// Audio device disconnect recovery is not implemented yet.
public final class AudioOutput {
    private let buffer: PlaybackBuffer
    private var stream: OpaquePointer?

    public init?(buffer: PlaybackBuffer) {
        self.buffer = buffer
        var builder: OpaquePointer?
        guard AAudio_createStreamBuilder(&builder) == Int32(AAUDIO_OK), let builder else { return nil }
        defer { AAudioStreamBuilder_delete(builder) }
        AAudioStreamBuilder_setDirection(builder, Int32(AAUDIO_DIRECTION_OUTPUT))
        AAudioStreamBuilder_setFormat(builder, Int32(AAUDIO_FORMAT_PCM_I16))
        AAudioStreamBuilder_setChannelCount(builder, Int32(PlaybackBuffer.channels))
        AAudioStreamBuilder_setSampleRate(builder, Int32(PlaybackBuffer.sampleRate))
        AAudioStreamBuilder_setPerformanceMode(builder, Int32(AAUDIO_PERFORMANCE_MODE_LOW_LATENCY))
        AAudioStreamBuilder_setDataCallback(builder, { _, context, audio, frames in
            guard let context else { return Int32(AAUDIO_CALLBACK_RESULT_STOP) }
            let output = Unmanaged<AudioOutput>.fromOpaque(context).takeUnretainedValue()
            let samples = audio.bindMemory(to: Int16.self, capacity: Int(frames) * PlaybackBuffer.channels)
            output.buffer.read(into: UnsafeMutableBufferPointer(start: samples, count: Int(frames) * PlaybackBuffer.channels))
            return Int32(AAUDIO_CALLBACK_RESULT_CONTINUE)
        }, Unmanaged.passUnretained(self).toOpaque())
        guard AAudioStreamBuilder_openStream(builder, &stream) == Int32(AAUDIO_OK), let stream else { return nil }
        if AAudioStream_requestStart(stream) != Int32(AAUDIO_OK) { Log.note("audio: failed to start AAudio output stream") }
    }

    deinit {
        guard let stream else { return }
        AAudioStream_requestStop(stream)
        AAudioStream_close(stream)
    }
}
#endif
