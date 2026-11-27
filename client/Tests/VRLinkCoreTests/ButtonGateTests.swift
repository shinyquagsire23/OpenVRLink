// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class ButtonGateTests: XCTestCase {
    private let origin = Pose(position: Vec3(0, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))

    private func controller(trigger: Float = 0, lower: Bool = false, stick: Float = 0) -> HandInput {
        var state = ControllerState(grip: TrackedPose(pose: origin))
        state.trigger = trigger
        state.lowerButton = lower
        state.stickY = stick
        return .controller(state)
    }

    private func trigger(_ hand: HandInput?) -> Float? {
        if case .controller(let state)? = hand { return state.trigger }
        return nil
    }

    func testSuppressesStartupInputsUntilReleased() {
        let gate = ButtonGate()
        let start: UInt64 = 1_000_000_000, ms: UInt64 = 1_000_000
        // A trigger held when the stream starts stays suppressed past the initial 0.3 s window until released.
        XCTAssertEqual(trigger(gate.passing([controller(trigger: 1), controller()], at: start)[0]), 0)
        XCTAssertEqual(trigger(gate.passing([controller(trigger: 1), controller()], at: start + 400 * ms)[0]), 0)
        // A hand that was not holding anything passes inputs once the startup window ends.
        XCTAssertEqual(trigger(gate.passing([controller(trigger: 1), controller(trigger: 1)], at: start + 420 * ms)[1]), 1)
        // Releasing the trigger allows subsequent presses on the first hand through.
        _ = gate.passing([controller(), controller()], at: start + 440 * ms)
        let after = gate.passing([controller(trigger: 1), controller()], at: start + 460 * ms)
        XCTAssertEqual(trigger(after[0]), 1)
        // An idle gap between calls starts a new startup suppression window.
        XCTAssertEqual(trigger(gate.passing([controller(trigger: 1), nil], at: start + 2000 * ms)[0]), 0)
    }

    func testSuppressesButtonsAndThumbsticksWhilePointingAtPanel() {
        let gate = ButtonGate()
        let start: UInt64 = 5_000_000_000, ms: UInt64 = 1_000_000
        var now = start
        func step(_ hand: HandInput, pointing: Bool? = nil) -> HandInput? {
            now += 10 * ms
            if let pointing { gate.pointerOnPanel(pointing, at: now) }
            return gate.passing([hand, nil], at: now)[0]
        }
        for _ in 0..<40 { _ = step(controller()) }
        XCTAssertEqual(trigger(step(controller(trigger: 1))), 1)
        _ = step(controller())
        // While pointing at the panel, button presses and thumbstick scroll inputs are suppressed.
        guard case .controller(let held)? = step(controller(trigger: 1, lower: true, stick: -1), pointing: true) else { return XCTFail() }
        XCTAssertEqual(held.trigger, 0)
        XCTAssertFalse(held.lowerButton)
        XCTAssertEqual(held.stickY, 0)
        // If the pointer leaves the panel while the trigger is still held, suppression continues until release.
        XCTAssertEqual(trigger(step(controller(trigger: 1), pointing: false)), 0)
        XCTAssertEqual(trigger(step(controller(trigger: 0))), 0)
        XCTAssertEqual(trigger(step(controller(trigger: 1))), 1)
        // Panel suppression expires automatically if pointerOnPanel is no longer called.
        _ = step(controller(), pointing: true)
        for _ in 0..<30 { _ = step(controller()) }
        XCTAssertEqual(trigger(step(controller(trigger: 1))), 1)
    }

    func testSuppressesHandGesturesWithoutAlteringPose() {
        let gate = ButtonGate()
        var hand = TrackedHand.flat(wrist: origin, side: .left)
        hand.menu = true
        guard case .hand(let kept)? = gate.passing([.hand(hand), nil], at: 1_000_000_000)[0] else { return XCTFail() }
        XCTAssertTrue(kept.gesturesHeld)
        XCTAssertFalse(kept.menu)
        XCTAssertEqual(kept.joints.count, hand.joints.count)
        XCTAssertFalse(HandGestures(kept, previous: nil).menu)
    }

    func testLowerRateWhenHotDefaultsToFalse() throws {
        XCTAssertFalse(Settings().lowerRateWhenHot)
        var settings = Settings()
        settings.lowerRateWhenHot = true
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(back.lowerRateWhenHot)
        XCTAssertFalse(back.resetToDefaults().lowerRateWhenHot)
    }
}
