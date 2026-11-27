// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Blocks controller buttons, triggers, thumbsticks, and hand gestures from reaching the host right after a
/// stream starts and whenever a pointer ray hits the in-headset panel. This keeps the button press that
/// launched the stream or clicked a panel control like Stop from clicking through into SteamVR.
///
/// Once a hand's inputs are suppressed, they stay suppressed until all buttons, triggers, and gestures on
/// that hand are released, so a press started on the panel does not leak to the host if the pointer slides
/// off the quad. Head, controller, and hand poses always pass through unmodified.
public final class ButtonGate: @unchecked Sendable {
    /// Duration in seconds to suppress inputs at the start of a stream.
    public static let quietAtStart: Double = 0.3
    /// Duration in nanoseconds that panel-hover suppression remains active without a fresh `pointerOnPanel` call.
    static let pointerStands: UInt64 = 250_000_000
    /// Idle gap between `passing` calls in nanoseconds after which the next call is treated as a new stream.
    static let newStreamAfter: UInt64 = 500_000_000

    private let lock = NSLock()
    private var pointedUntil: UInt64 = 0, quietUntil: UInt64 = 0, lastAsked: UInt64 = 0
    private var keptBack = [false, false]

    public init() {}

    /// Updates whether a pointer ray is currently intersecting the panel. Called each frame while the panel is visible.
    public func pointerOnPanel(_ on: Bool, at now: UInt64 = Uptime.nanoseconds) {
        lock.lock()
        pointedUntil = on ? now &+ ButtonGate.pointerStands : 0
        lock.unlock()
    }

    /// Filters `hands` for the current timestamp, zeroing button and gesture states on any suppressed hand.
    public func passing(_ hands: [HandInput?], at now: UInt64 = Uptime.nanoseconds) -> [HandInput?] {
        lock.lock()
        defer { lock.unlock() }
        if lastAsked == 0 || now &- lastAsked > ButtonGate.newStreamAfter { quietUntil = now &+ UInt64(ButtonGate.quietAtStart * 1e9) }
        lastAsked = now
        let closed = now < quietUntil || now < pointedUntil
        return hands.enumerated().map { index, hand in
            guard let hand, keptBack.indices.contains(index) else { return hand }
            if closed {
                keptBack[index] = true
            } else if keptBack[index], !ButtonGate.holdsSomething(hand) {
                keptBack[index] = false
            }
            return keptBack[index] ? ButtonGate.emptied(hand) : hand
        }
    }

    static func holdsSomething(_ hand: HandInput) -> Bool {
        switch hand {
        case .controller(let state):
            return state.lowerButton || state.upperButton || state.menuButton || state.stickClick
                || state.trigger > 0.1 || state.squeeze > 0.1
        case .hand(let tracked):
            let made = HandGestures(tracked, previous: nil)
            return made.pinch.contains(true) || made.grip || made.menu
        }
    }

    static func emptied(_ hand: HandInput) -> HandInput {
        switch hand {
        case .controller(var state):
            (state.lowerButton, state.upperButton, state.menuButton, state.stickClick) = (false, false, false, false)
            (state.lowerButtonTouched, state.upperButtonTouched, state.triggerTouched) = (false, false, false)
            (state.stickTouched, state.thumbRestTouched) = (false, false)
            (state.trigger, state.squeeze, state.stickX, state.stickY) = (0, 0, 0, 0)
            return .controller(state)
        case .hand(var tracked):
            tracked.gesturesHeld = true
            tracked.systemPinch = nil
            tracked.menu = false
            return .hand(tracked)
        }
    }
}
