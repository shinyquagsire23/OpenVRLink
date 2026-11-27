// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Defines user-configurable settings as UI-independent sections of controls bound to `Settings` key paths,
/// filtered by the `Features` supported on the current platform.
///
/// The visionOS app builds its SwiftUI forms directly so it can mix in Room Setup and calibration controls.
public enum SettingsForm {
    /// Platform capabilities that determine which settings sections and items are shown.
    public struct Features: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let microphone = Features(rawValue: 1 << 0)
        /// Platform compositor can overlay the user's real hands on top of the stream.
        public static let handsOverlay = Features(rawValue: 1 << 1)
        public static let systemOverlays = Features(rawValue: 1 << 2)
        /// Tracks both controllers and hands, allowing the user to switch between them.
        public static let controllersAndHands = Features(rawValue: 1 << 3)
        public static let gazePinch = Features(rawValue: 1 << 4)
        /// Supports chroma-keyed passthrough rendering.
        public static let chromaKey = Features(rawValue: 1 << 5)
        /// Runs in a separate 2D window that can be dismissed when streaming starts.
        public static let window = Features(rawValue: 1 << 6)
        public static let senseControllers = Features(rawValue: 1 << 7)
        /// Supports estimating scene depth from decoded stereo video frames.
        public static let depthFromPicture = Features(rawValue: 1 << 8)
        /// Supports dynamic thermal refresh-rate stepping across multiple display refresh rates.
        public static let rateSteps = Features(rawValue: 1 << 9)
    }

    public enum Control {
        case toggle(WritableKeyPath<Settings, Bool>)
        case slider(WritableKeyPath<Settings, Float>, in: ClosedRange<Float>, step: Float)
        /// sRGB `[red, green, blue]` components in `0...1`.
        case color(WritableKeyPath<Settings, [Float]>)
    }

    public struct Item {
        public var title: String
        public var control: Control
        var needs: Features = []
    }

    public struct Section {
        public var title: String
        public var footer: String?
        public var items: [Item]
    }

    private static let everything: [Section] = [
        Section(title: "Audio", items: [
            Item(title: "Send my microphone", control: .toggle(\.microphone), needs: .microphone),
        ]),
        Section(title: "Hands and controllers", items: [
            Item(title: "Show my hands over the picture", control: .toggle(\.showHandsOverlaid), needs: .handsOverlay),
            Item(title: "Hide system overlays (palm gesture)", control: .toggle(\.hideSystemOverlays), needs: .systemOverlays),
            Item(title: "Switch between controllers and hands by looking at and clacking them together twice",
                 control: .toggle(\.clackSwitchesToHands), needs: .controllersAndHands),
            Item(title: "Enable Gaze-Pinch interactions", control: .toggle(\.gazePinchRays), needs: .gazePinch),
            Item(title: "Show PS VR2 Sense controller models", control: .toggle(\.senseControllerModels), needs: .senseControllers),
        ]),
        Section(title: "Chroma key", items: [
            Item(title: "Enable Chroma-keyed passthrough", control: .toggle(\.chromaKey), needs: .chromaKey),
            Item(title: "Color", control: .color(\.chromaKeyColor), needs: .chromaKey),
            Item(title: "Min Color Distance", control: .slider(\.chromaKeyNear, in: 0...1, step: 0.01), needs: .chromaKey),
            Item(title: "Max Color Distance", control: .slider(\.chromaKeyFar, in: 0.01...1, step: 0.01), needs: .chromaKey),
            Item(title: "Disable passthrough during games", control: .toggle(\.chromaKeyOffInGames), needs: .chromaKey),
        ]),
        Section(title: "Depth", footer: "Estimates scene depth from stereo disparity so nearby surfaces stay in place "
                    + "as your head moves between frames", items: [
            Item(title: "Estimate depth from stereo video", control: .toggle(\.depthFromPicture), needs: .depthFromPicture),
            Item(title: "Display estimated depth (debug)", control: .toggle(\.showDepth), needs: .depthFromPicture),
        ]),
        Section(title: "Heat", footer: "Reduces the display refresh rate during thermal throttling and restores it once "
                    + "the headset cools, at the cost of a brief hitch on each change", items: [
            Item(title: "Lower refresh rate when hot", control: .toggle(\.lowerRateWhenHot), needs: .rateSteps),
        ]),
        Section(title: "Field of view", footer: "Increase FoV for timewarp comfort, or sacrifice FoV for sharpness", items: [
            Item(title: "Across", control: .slider(\.fovScaleHorizontal, in: Settings.fovScaleRange, step: 0.05)),
            Item(title: "Up and down", control: .slider(\.fovScaleVertical, in: Settings.fovScaleRange, step: 0.05)),
        ]),
        Section(title: "Other", items: [
            Item(title: "Close this window when streaming starts", control: .toggle(\.closeWindowOnEntry), needs: .window),
        ]),
    ]

    /// Returns the non-empty settings sections applicable to `features`.
    public static func sections(for features: Features) -> [Section] {
        everything.compactMap { section in
            var kept = section
            kept.items = section.items.filter { features.isSuperset(of: $0.needs) }
            return kept.items.isEmpty ? nil : kept
        }
    }
}
