// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import AVKit
import QuartzCore
import UIKit
import VRLinkCore

/// Requests a target display refresh rate from visionOS.
///
/// visionOS does not expose an API to force a refresh rate; the OS manages the
/// display rate itself and defaults to maximum refresh. Following the ALVR
/// visionOS client, we pass two hints:
///
/// - A no-op `CADisplayLink` configured with `preferredFrameRateRange` set to
///   the target rate.
/// - `AVDisplayCriteria` on the key window's `avDisplayManager`, which signals
///   that video of a given format and framerate is playing. Because this
///   requires a `CMFormatDescription`, we apply it once the decoder parses the
///   stream's parameter sets.
///
/// In system logs, `AVDisplayCriteria` is the hint that triggers a rate switch:
/// setting it asserts content playback at 90, 96, 100, or 120 Hz to the system
/// rate manager, and the displays switch roughly four seconds after the last
/// assertion. Re-assigning identical criteria resets that four-second timer, so
/// we deduplicate updates in `applyCriteria()`.
///
/// Because visionOS may ignore both hints, the streaming session still measures
/// the actual display refresh interval directly.
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

    /// Updates the active video format description. Safe to call from any thread.
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
