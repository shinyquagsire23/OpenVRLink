// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CImGui
import Foundation
import VRLinkCore

/// Renders the `ClientModel` host picker, manual IP keypad, pairing PIN prompt, connection status, and
/// settings UI into an RGBA pixel buffer using Dear ImGui.
///
/// Because output is rasterized on the CPU into a plain RGBA buffer (`PanelPicture`), app shells can upload
/// it to an OpenXR quad swapchain (`XRDisplay.panel`) or blit it directly into a 2D window. The shell updates
/// `pointer` in panel pixel coordinates and calls `update()` once per frame.
///
/// Dear ImGui uses a single global context, so each process creates one `Panel` and accesses it from one
/// thread at a time.
public final class Panel {
    public let model: ClientModel
    public let width: Int, height: Int
    /// Platform capabilities controlling which settings items are shown.
    public var features: SettingsForm.Features
    /// Detected headset quirks (before user overrides) shown in the Quirks tab, or `nil` to hide the tab.
    public var quirks: HeadsetQuirks?
    /// Active quirks from app startup, used to indicate pending changes that require a restart.
    public var quirksInEffect: HeadsetQuirks?
    /// Subtitle displayed next to the header (for example, app version and device model).
    public var caption = ""
    /// Optional footer hint explaining how to toggle the panel while streaming.
    public var hint = ""
    /// Current pointer position in pixels from the top-left corner and button state, or `nil` when inactive.
    public var pointer: (x: Float, y: Float, pressed: Bool)?
    /// Vertical thumbstick deflection in `-1...1` (positive up) used to scroll the active list under the
    /// pointer, or at the center of the panel when no pointer ray hits it.
    public var scroll: Float = 0
    /// Action invoked when the top-right close button (`X`) is pressed; when `nil`, the close button is hidden.
    public var onClose: (() -> Void)?
    /// Scroll speed in wheel steps per second at full thumbstick deflection.
    private static let scrollRate: Float = 4
    /// Whether to draw a cursor dot at `pointer` (enabled for ray pointers, disabled for direct touch).
    public var showsPointer = false
    /// Most recently rasterized RGBA image of the panel.
    public private(set) var picture: PanelPicture

    private let rasterizer: PanelRasterizer
    private var lastDrawn: UInt64 = 0
    private var lastUpdate = Uptime.nanoseconds
    /// In-progress keypad input for an IP address or pairing PIN.
    private var typed = ""
    private var typing = false
    private let unit: Float

    /// Candidate system font paths tried in order; falls back to ImGui's built-in bitmap font if none exist.
    public static let systemFonts = [
        "/system/fonts/Roboto-Regular.ttf", "/system/fonts/NotoSans-Regular.ttf", "/system/fonts/DroidSans.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf", "/Library/Fonts/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "C:\\Windows\\Fonts\\segoeui.ttf",
    ]

    /// - Parameters:
    ///   - width, height: Output image dimensions in pixels. Layout metrics are authored at 1280x800 and scale with `height`.
    public init(model: ClientModel, features: SettingsForm.Features, width: Int = 1280, height: Int = 800,
                fonts: [String] = Panel.systemFonts) {
        self.model = model
        self.features = features
        self.width = width
        self.height = height
        picture = PanelPicture(width: width, height: height)
        unit = Float(height) / 800
        let font = fonts.first { FileManager.default.isReadableFile(atPath: $0) }
        igCreate(font, (30 * unit).rounded(), 2 * unit)
        var pixels: UnsafePointer<UInt8>?
        var atlasWidth: Int32 = 0, atlasHeight: Int32 = 0
        igFontAtlas(&pixels, &atlasWidth, &atlasHeight)
        rasterizer = PanelRasterizer(atlas: Array(UnsafeBufferPointer(start: pixels, count: Int(atlasWidth * atlasHeight))),
                                     atlasWidth: Int(atlasWidth), atlasHeight: Int(atlasHeight))
        igStyleRounding(24 * unit, 12 * unit, 10 * unit)
        igStylePadding(32 * unit, 24 * unit, 18 * unit, 12 * unit, 14 * unit, 12 * unit)
        igStyleColor(IGColorWindow, 0.10, 0.11, 0.13, 0.96)
        igStyleColor(IGColorChild, 0, 0, 0, 0)
        igStyleColor(IGColorTextDisabled, 0.62, 0.64, 0.68, 1)
        igStyleColor(IGColorFrame, 0.20, 0.22, 0.26, 1)
        igStyleColor(IGColorFrameHovered, 0.26, 0.29, 0.35, 1)
        igStyleColor(IGColorFrameActive, 0.30, 0.34, 0.42, 1)
        igStyleColor(IGColorButton, 0.22, 0.25, 0.31, 1)
        igStyleColor(IGColorButtonHovered, 0.24, 0.42, 0.70, 1)
        igStyleColor(IGColorButtonActive, 0.20, 0.50, 0.90, 1)
        igStyleColor(IGColorTab, 0.16, 0.18, 0.22, 1)
        igStyleColor(IGColorTabHovered, 0.24, 0.42, 0.70, 1)
        igStyleColor(IGColorTabSelected, 0.20, 0.36, 0.62, 1)
        igStyleColor(IGColorSlider, 0.36, 0.58, 0.92, 1)
        igStyleColor(IGColorSliderActive, 0.50, 0.70, 1.0, 1)
        igStyleColor(IGColorCheck, 0.50, 0.75, 1.0, 1)
        igStyleColor(IGColorScrollbar, 0, 0, 0, 0)
    }

    deinit { igDestroy() }

    /// Runs one ImGui frame for the current `model` state and `pointer`, re-rasterizing `picture` only when
    /// the draw lists change. Returns `true` if `picture` was updated.
    @discardableResult
    public func update() -> Bool {
        let now = Uptime.nanoseconds
        let elapsed = Float(now &- lastUpdate) / 1e9
        lastUpdate = now
        // Apply a 0.25 dead zone and scale scroll speed linearly with thumbstick deflection.
        let pushed = abs(scroll) < 0.25 ? 0 : (abs(scroll) - 0.25) / 0.75 * (scroll < 0 ? -1 : 1)
        if let pointer {
            igPointer(pointer.x, pointer.y, pointer.pressed)
        } else if pushed != 0 {
            igPointer(Float(width) / 2, Float(height) / 2, false)
        } else {
            igPointer(-1, -1, false)
        }
        if pushed != 0 { igScroll(pushed * Panel.scrollRate * min(0.25, elapsed)) }
        igNewFrame(Float(width), Float(height), min(0.25, elapsed))
        layout()
        if showsPointer, let pointer { igDot(pointer.x, pointer.y, (pointer.pressed ? 9 : 12) * unit) }
        igRender()
        return draw()
    }

    // MARK: Drawing

    private func draw() -> Bool {
        // Hash ImGui's vertex and index buffers so unchanged frames skip CPU rasterization.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ bytes: UnsafeRawBufferPointer) {
            var index = 0
            while index + 8 <= bytes.count {
                hash = (hash ^ bytes.loadUnaligned(fromByteOffset: index, as: UInt64.self)) &* 0x0000_0100_0000_01B3
                index += 8
            }
            while index < bytes.count {
                hash = (hash ^ UInt64(bytes[index])) &* 0x0000_0100_0000_01B3
                index += 1
            }
        }
        let lists = (0..<Int(igDrawListCount())).map { igDrawListAt(Int32($0)) }
        for list in lists {
            mix(UnsafeRawBufferPointer(start: list.vertices, count: Int(list.vertexCount) * MemoryLayout<IGVertex>.stride))
            mix(UnsafeRawBufferPointer(start: list.indices, count: Int(list.indexCount) * 2))
        }
        if hash == lastDrawn { return false }
        lastDrawn = hash
        picture.pixels.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) }
        for (number, list) in lists.enumerated() {
            let vertices = UnsafeRawBufferPointer(start: list.vertices, count: Int(list.vertexCount) * MemoryLayout<IGVertex>.stride)
                .bindMemory(to: PanelRasterizer.Vertex.self)
            for command in 0..<list.commandCount {
                let drawn = igDrawCommandAt(Int32(number), command)
                guard drawn.elementCount > 0, let first = list.indices else { continue }
                let indices = UnsafeBufferPointer(start: first + Int(drawn.indexOffset), count: Int(drawn.elementCount))
                let offset = UnsafeBufferPointer(rebasing: vertices[Int(drawn.vertexOffset)...])
                rasterizer.draw(offset, indices, clip: drawn.clip, into: &picture)
            }
        }
        return true
    }

    // MARK: Layout

    private func layout() {
        let state = model.state
        igBeginPanel("OpenVRLink")
        igFontScale(1.5)
        igText("OpenVRLink")
        igFontScale(1)
        if !caption.isEmpty {
            igSameLine(16 * unit)
            igTextDim(caption)
        }
        if let onClose {
            igSameLine(0)
            igCursorX(Float(width) - 100 * unit)
            if igButton("X", 68 * unit, 56 * unit) { onClose() }
        }
        if igBeginTabBar("tabs") {
            if igBeginTabItem("Stream") {
                igSpacing()
                if state.askingForPin {
                    askPin()
                } else if state.phase == .choosing {
                    choose(state)
                } else {
                    streaming(state)
                }
                igEndTabItem()
            }
            if igBeginTabItem("Settings") {
                settings()
                igEndTabItem()
            }
            if let quirks, igBeginTabItem("Quirks") {
                quirksTab(quirks)
                igEndTabItem()
            }
            igEndTabBar()
        }
        igEnd()
    }

    private func centered(_ text: String, dim: Bool = false) {
        igCursorX(max(igGetCursorX(), (Float(width) - igTextWidth(text)) / 2))
        if dim { igTextDim(text) } else { igText(text) }
    }

    private func choose(_ state: ClientModel.State) {
        if typing {
            enterAddress()
            return
        }
        centered(state.hosts.isEmpty ? "Searching for hosts on your network..." : "Found on your network:")
        igSpacing()
        igBeginChild("hosts", 0, 300 * unit, false)
        // Lay out two host buttons per row so long hostnames with "(WiVRn)" still fit.
        let tile = (width: (igAvailableWidth() - 14 * unit) / 2 - 1, height: 110 * unit)
        for (index, host) in state.hosts.enumerated() {
            if index % 2 != 0 { igSameLine(-1) }
            igPushID(Int32(index))
            if igButton(host.title, tile.width, tile.height) { model.connect(to: host) }
            igPopID()
        }
        igEndChild()
        if igButton("Connect by IP address", 420 * unit, 0) {
            typed = model.remembered.address
            typing = true
        }
        igSpacing()
        igTextDim(state.status)
        if !hint.isEmpty { igTextDim(hint) }
    }

    /// Renders a 12-button numeric keypad for entering IPv4 addresses and pairing PINs.
    private func keypad() {
        let key = (width: 110 * unit, height: 76 * unit)
        for (index, label) in ["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "<"].enumerated() {
            if index % 3 != 0 { igSameLine(-1) }
            if igButton(label, key.width, key.height) {
                if label == "<" {
                    if !typed.isEmpty { typed.removeLast() }
                } else if typed.count < 40 {
                    typed += label
                }
            }
        }
    }

    private func enterAddress() {
        var remembered = model.remembered
        igText("Connect by IP address")
        igBeginChild("keys", 380 * unit, 370 * unit, false)
        keypad()
        igEndChild()
        igSameLine(40 * unit)
        igBeginChild("address", 0, 370 * unit, false)
        igFontScale(1.4)
        igText(typed.isEmpty ? "192.168.1.2" : typed)
        igFontScale(1)
        igSeparator()
        igSpacing()
        igText("Protocol")
        if igRadio("Steam", remembered.kind == .steam) { remembered.kind = .steam }
        igSameLine(30 * unit)
        if igRadio("WiVRn", remembered.kind == .wivrn) { remembered.kind = .wivrn }
        igSpacing()
        igSpacing()
        if igButton("Cancel", 200 * unit, 0) { typing = false }
        igSameLine(-1)
        igBeginDisabled(typed.isEmpty)
        if igButton("Connect", 200 * unit, 0) {
            remembered.address = typed
            typing = false
            model.remembered = remembered
            model.connectToTyped()
        }
        igEndDisabled()
        igEndChild()
        if remembered.kind != model.remembered.kind {
            var kept = model.remembered
            kept.kind = remembered.kind
            model.remembered = kept
        }
    }

    private func askPin() {
        igText("Pair with WiVRn")
        igTextDim("Type the PIN the computer shows.")
        igBeginChild("keys", 380 * unit, 370 * unit, false)
        keypad()
        igEndChild()
        igSameLine(40 * unit)
        igBeginChild("pin", 0, 370 * unit, false)
        igFontScale(1.8)
        igText(typed.isEmpty ? "------" : typed)
        igFontScale(1)
        igSeparator()
        igSpacing()
        if igButton("Cancel", 200 * unit, 0) {
            typed = ""
            model.answerPin(nil)
        }
        igSameLine(-1)
        igBeginDisabled(typed.isEmpty)
        if igButton("Pair", 200 * unit, 0) {
            model.answerPin(typed)
            typed = ""
        }
        igEndDisabled()
        igEndChild()
    }

    private func streaming(_ state: ClientModel.State) {
        igDummy(0, 60 * unit)
        if let target = state.target { centered(target.kind == .steam ? target.name : target.name + " (WiVRn)", dim: true) }
        igSpacing()
        igFontScale(1.2)
        if igTextWidth(state.status) < igAvailableWidth() { centered(state.status) } else { igTextWrapped(state.status) }
        igFontScale(1)
        igDummy(0, 30 * unit)
        igCursorX((Float(width) - 260 * unit) / 2)
        if igButton("Stop", 260 * unit, 80 * unit) { model.stop() }
        if !hint.isEmpty {
            igDummy(0, 30 * unit)
            igTextDim(hint)
        }
    }

    /// Renders per-quirk override controls persisted to `Settings.quirkOverrides` (applied on next app launch).
    private func quirksTab(_ defaults: HeadsetQuirks) {
        igBeginChild("quirks", 0, 0, false)
        var overrides = model.settings.quirkOverrides
        let before = overrides
        let current = defaults.overridden(by: overrides)
        igTextWrapped("Workarounds for \(defaults.headset.rawValue). Changes take effect the next time the app starts.")
        igSpacing()
        var id: Int32 = 1000
        for option in HeadsetQuirks.options {
            guard let usual = defaults.value(of: option.key), let now = current.value(of: option.key) else { continue }
            id += 1
            igPushID(id)
            /// Stores an override only when the value differs from the headset default.
            func set(_ value: String) { overrides[option.key] = value == usual ? nil : value }
            let waiting = !HeadsetQuirks.liveKeys.contains(option.key) && quirksInEffect?.value(of: option.key).map { $0 != now } ?? false
            let title = option.title + (waiting ? "  (restart the app to apply)" : now == usual ? "" : "  (changed)")
            switch option.kind {
            case .flag:
                var on = now == "1"
                if igCheckbox(title, &on) { set(on ? "1" : "0") }
            case .choice(let names):
                // Render radio choices below the label, wrapping onto a new line when horizontal space runs out.
                igText(title)
                for (index, name) in names.enumerated() {
                    if index > 0 {
                        igSameLine(16 * unit)
                        if igAvailableWidth() < igTextWidth(name) + 70 * unit { igDummy(0, 0) }
                    }
                    if igRadio(name, now == name) { set(name) }
                }
            case .number(let range, let step):
                var value = Float(now) ?? range.lowerBound
                igNextItemWidth(520 * unit)
                if igSlider(title, &value, range.lowerBound, range.upperBound, step < 1 ? "%.1f" : "%.0f") {
                    let stepped = (value / step).rounded() * step
                    set(step < 1 ? String(format: "%.1f", stepped) : String(Int(stepped)))
                }
            }
            igPopID()
        }
        igSpacing()
        if !overrides.isEmpty, igButton("Reset to this headset's defaults", 0, 0) { overrides = [:] }
        if overrides != before {
            var settings = model.settings
            settings.quirkOverrides = overrides
            model.settings = settings
        }
        igEndChild()
    }

    private func settings() {
        igBeginChild("settings", 0, 0, false)
        var settings = model.settings
        let before = settings
        var id: Int32 = 0
        for section in SettingsForm.sections(for: features) {
            igSeparatorText(section.title)
            for item in section.items {
                id += 1
                igPushID(id)
                switch item.control {
                case .toggle(let field):
                    var value = settings[keyPath: field]
                    if igCheckbox(item.title, &value) { settings[keyPath: field] = value }
                case .slider(let field, let range, let step):
                    var value = settings[keyPath: field]
                    igNextItemWidth(520 * unit)
                    if igSlider(item.title, &value, range.lowerBound, range.upperBound, "%.2f") {
                        settings[keyPath: field] = (value / step).rounded() * step
                    }
                case .color(let field):
                    var value = settings[keyPath: field]
                    if value.count == 3, igColor(item.title, &value) { settings[keyPath: field] = value }
                }
                igPopID()
            }
            if let footer = section.footer { igTextDim(footer) }
            igSpacing()
        }
        if settings.differsFromDefaults, igButton("Reset settings to defaults", 0, 0) { settings = settings.resetToDefaults() }
        if settings != before { model.settings = settings }
        igEndChild()
    }
}
