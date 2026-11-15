// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

/// Tests for refresh rate and battery change detection shared by both session types.
final class SessionChangeTests: XCTestCase {
    func testAPeriodMeasuredALittleOffIsTheSameRate() {
        var rate = RefreshRate(hz: 90)
        XCTAssertEqual(rate.hz, 90)
        // Minor vsync timing jitter within the 2% tolerance should not trigger a rate change.
        for off in [0.985, 1.0, 1.015] { XCTAssertNil(rate.follow(off / 90)) }
        // Ignored jitter must not drift the stored baseline period.
        XCTAssertEqual(rate.period, 1.0 / 90, accuracy: 1e-12)
    }

    func testAnotherRateIsSaidOnceWithWhatItWas() {
        var rate = RefreshRate(hz: 90)
        let change = rate.follow(1.0 / 120)
        XCTAssertEqual(change, RefreshRate.Change(from: 90, to: 120))
        XCTAssertEqual(change?.note, "display now refreshes at 120.0 Hz")
        XCTAssertEqual(rate.hz, 120)
        XCTAssertEqual(rate.period, 1.0 / 120, accuracy: 1e-12)
        XCTAssertNil(rate.follow(1.0 / 120))
        // Reported Hz values are rounded to whole numbers even if the measured period is slightly off.
        XCTAssertEqual(rate.follow(1.0 / 99.6), RefreshRate.Change(from: 120, to: 100))
        XCTAssertEqual(rate.follow(1.0 / 90), RefreshRate.Change(from: 100, to: 90))
    }

    func testAPeriodThatIsNoneIsIgnored() {
        var rate = RefreshRate(hz: 100)
        XCTAssertNil(rate.follow(0))
        XCTAssertNil(rate.follow(-0.01))
        XCTAssertEqual(rate.hz, 100)
    }

    func testABatteryIsNewsWhenAPercentOrTheChargerChanges() {
        var news = PowerNews()
        // Nil battery readings produce no update.
        XCTAssertNil(news.news(nil))
        XCTAssertEqual(news.news(PowerState(level: 0.804, charging: false)), PowerState(level: 0.80, charging: false))
        // Sub-percent fluctuations round to the same value and do not trigger an update.
        XCTAssertNil(news.news(PowerState(level: 0.801, charging: false)))
        XCTAssertNil(news.news(nil))
        XCTAssertEqual(news.news(PowerState(level: 0.79, charging: false))?.level, 0.79)
        XCTAssertEqual(news.news(PowerState(level: 0.79, charging: true)), PowerState(level: 0.79, charging: true))
        XCTAssertNil(news.news(PowerState(level: 0.79, charging: true)))
        // Resetting the tracker (e.g. when a hand switches devices) re-sends the current state.
        news = PowerNews()
        XCTAssertNotNil(news.news(PowerState(level: 0.79, charging: true)))
    }
}
