// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import AVKit
import QuartzCore
import UIKit
import VRLinkCore

/// Asks visionOS for a display refresh rate. There is no call that sets
/// it: the system chooses the rate itself, and by default runs as fast
/// as the displays go. It takes two hints, and both are given (the ALVR
/// visionOS client does the same):
///
/// - a display link's preferred frame rate, so one that does nothing is
///   kept running at the rate wanted;
/// - a window's preferred display criteria, which say "video of this
///   format at this rate is playing". That one needs the stream's format,
///   so it is given once the decoder has seen the stream's parameter sets.
///
/// The criteria are what the system was seen to act on (its log,
/// 2026-11-13): setting them makes this app assert "playing 90 Hz
/// content" (or 96, 100, 120) to the system's rate manager, and the
/// displays changed rate four seconds after the last time that was
/// asserted. Setting them again, even to the same thing, asserts again
/// and the wait starts over, so they are set only when they change.
///
/// The system is free to ignore both; the session watches what the
/// display really does.
final class DisplayRate: NSObject {
    static let shared = DisplayRate()
    private var link: CADisplayLink?
    private var wanted: Float?
    private var format: CMFormatDescription?

    /// Safe to call from any thread.
    func ask(for hz: Float) {
        DispatchQueue.main.async { [self] in
            wanted = hz
            link?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
            link.add(to: .main, forMode: .common)
            self.link = link
            Log.note("display: asked the system for \(hz) Hz")
            applyCriteria()
        }
    }

    /// The format of the video being shown. Safe to call from any thread.
    func videoFormat(_ format: CMFormatDescription) {
        DispatchQueue.main.async { [self] in
            self.format = format
            applyCriteria()
        }
    }

    private var applied: (hz: Float, format: CMFormatDescription)?

    private func applyCriteria() {
        guard let wanted, let format else { return }
        if let applied, applied.hz == wanted, CMFormatDescriptionEqual(applied.format, otherFormatDescription: format) { return }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else {
            Log.note("display: no window to tell that video at \(wanted) Hz is playing")
            return
        }
        window.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: wanted, formatDescription: format)
        applied = (wanted, format)
        Log.note("display: told the system that video at \(wanted) Hz is playing")
    }

    @objc private func tick(_ link: CADisplayLink) {}
}
#endif
