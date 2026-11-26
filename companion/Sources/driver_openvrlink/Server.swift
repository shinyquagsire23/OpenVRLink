// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import DriverABI

/// vrserver's log and settings, valid between the provider's `Init` and `Cleanup`.
enum Server {
    static var log: UnsafeMutablePointer<ovr_log>?
    static var settings: UnsafeMutablePointer<ovr_settings>?

    /// Settings section and keys. The companion's copies of these names are in
    /// `Sources/CompanionKit/Install.swift`.
    static let section: StaticString = "driver_openvrlink"
    static let gammaOnKey: StaticString = "encodingGamma"
    static let gammaValueKey: StaticString = "encodingGammaValue"
    static let gammaAvailableKey: StaticString = "gammaAvailable"
    static let statusKey: StaticString = "status"
    /// `PlayForDreamModel.settingsKey`: true in `default.vrsettings` when the Play For Dream controller models are installed.
    static let playForDreamModelsKey: StaticString = "playForDreamModels"
    static let defaultGamma: Float = 1.6
    /// Settings sections installed by `openvrlink-companion` for OpenVRLink's native HMD models (`Install.headsets`).
    static let headsetSections: [StaticString] = ["vrlink_Apple Vision Pro (OpenVRLink)", "vrlink_OpenVRLink Headset"]

    /// Returns true when every section in `headsetSections` is present with `enable` set to `true`.
    static func headsetsKnown() -> Bool {
        guard let settings else { return false }
        for name in headsetSections {
            var error: Int32 = 0
            let enabled = settings.pointee.vtable.pointee.get_bool(settings, cString(name), cString("enable"), &error)
            guard error == 0, enabled else { return false }
        }
        return true
    }

    static func cString(_ text: StaticString) -> UnsafePointer<CChar> {
        UnsafeRawPointer(text.utf8Start).assumingMemoryBound(to: CChar.self)
    }

    /// Writes one line to vrserver's log (which adds the driver's name).
    static func say(_ message: Message) {
        guard let log else { return }
        var text = message.characters + [0x0A, 0]
        text.withUnsafeMutableBufferPointer { log.pointee.vtable.pointee.log(log, $0.baseAddress) }
    }

    static func say(_ text: StaticString) { say(Message(text)) }

    static func bool(_ key: StaticString, default fallback: Bool) -> Bool {
        guard let settings else { return fallback }
        var error: Int32 = 0
        let value = settings.pointee.vtable.pointee.get_bool(settings, cString(section), cString(key), &error)
        return error == 0 ? value : fallback
    }

    static func float(_ key: StaticString, default fallback: Float) -> Float {
        guard let settings else { return fallback }
        var error: Int32 = 0
        let value = settings.pointee.vtable.pointee.get_float(settings, cString(section), cString(key), &error)
        return error == 0 ? value : fallback
    }

    /// Publishes what the driver managed to patch, for SteamVR's settings page.
    static func publish(gammaAvailable: Bool, status: StaticString) {
        guard let settings else { return }
        var error: Int32 = 0
        settings.pointee.vtable.pointee.set_bool(settings, cString(section), cString(gammaAvailableKey), gammaAvailable, &error)
        settings.pointee.vtable.pointee.set_string(settings, cString(section), cString(statusKey), cString(status), &error)
    }
}

/// Lightweight ASCII message buffer used to avoid linking Swift's `String` formatting
/// and Unicode tables into `driver_openvrlink`.
struct Message {
    var characters: [CChar] = []

    init(_ text: StaticString) { add(text) }

    @discardableResult
    mutating func add(_ text: StaticString) -> Message {
        for index in 0..<text.utf8CodeUnitCount { characters.append(CChar(bitPattern: text.utf8Start[index])) }
        return self
    }

    /// Adds a NUL-terminated C string.
    @discardableResult
    mutating func add(cString text: UnsafePointer<CChar>) -> Message {
        var index = 0
        while text[index] != 0 {
            characters.append(text[index])
            index += 1
        }
        return self
    }

    @discardableResult
    mutating func add(_ number: Int) -> Message {
        var digits: [CChar] = []
        var rest = number.magnitude
        repeat {
            digits.append(CChar(0x30 + rest % 10))
            rest /= 10
        } while rest > 0
        if number < 0 { characters.append(0x2D) }
        characters.append(contentsOf: digits.reversed())
        return self
    }

    func adding(_ text: StaticString) -> Message {
        var copy = self
        return copy.add(text)
    }

    func adding(_ number: Int) -> Message {
        var copy = self
        return copy.add(number)
    }

    func adding(cString text: UnsafePointer<CChar>) -> Message {
        var copy = self
        return copy.add(cString: text)
    }
}
