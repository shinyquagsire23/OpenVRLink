// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import COpenXR
import VRLinkCore
import XCTest
@testable import VRLinkOpenXR

final class VRLinkOpenXRTests: XCTestCase {
    func testManifestSearchOrder() {
        let places = Loader.manifests(environment: ["XR_RUNTIME_JSON": "/tmp/mine.json", "HOME": "/home/me", "XDG_CONFIG_HOME": "/cfg"])
        XCTAssertEqual(Array(places.prefix(3)),
                       ["/tmp/mine.json", "/cfg/openxr/1/active_runtime.json", "/home/me/.config/openxr/1/active_runtime.json"])
        XCTAssertTrue(places.contains("/etc/xdg/openxr/1/active_runtime.json"))
    }

    func testRuntimeLibraryPathResolution() {
        func library(_ path: String) -> String? {
            let manifest = #"{"file_format_version": "1.0.0", "runtime": {"name": "A", "library_path": "\#(path)"}}"#
            return Loader.runtimeLibrary(manifest: Data(manifest.utf8), at: "/opt/runtime/share/runtime.json")
        }
        XCTAssertEqual(library("./libruntime.dylib"), "/opt/runtime/share/libruntime.dylib")
        XCTAssertEqual(library("../lib/libruntime.so"), "/opt/runtime/lib/libruntime.so")
        XCTAssertEqual(library("/usr/lib/libruntime.so"), "/usr/lib/libruntime.so")
        // Bare library names are left unmodified for dlopen's search path.
        XCTAssertEqual(library("libruntime.so"), "libruntime.so")
        XCTAssertNil(Loader.runtimeLibrary(manifest: Data("{}".utf8), at: "/x.json"))
    }

    func testPoseRoundTrip() {
        // Rotating 90 degrees left around +Y maps forward (-Z) to -X.
        let half = Float(0.5).squareRoot()
        let turned = XrPosef(orientation: XrQuaternionf(x: 0, y: half, z: 0, w: half), position: XrVector3f(x: 1, y: 2, z: 3))
        let pose = Pose(turned)
        XCTAssertEqual(pose.position.y, 2)
        XCTAssertEqual(pose.forward.x, -1, accuracy: 1e-5)
        XCTAssertEqual(pose.right.z, -1, accuracy: 1e-5)
        let back = pose.xr
        XCTAssertEqual(back.orientation.y, half, accuracy: 1e-5)
        XCTAssertEqual(back.orientation.w, half, accuracy: 1e-5)
        XCTAssertEqual(back.position.z, 3)
    }

    func testFovConvertsToTangents() {
        let frustum = Frustum(XrFovf(angleLeft: -.pi / 4, angleRight: .pi / 4, angleUp: 0.5, angleDown: -0.25))
        XCTAssertEqual(frustum.left, -1, accuracy: 1e-5)
        XCTAssertEqual(frustum.right, 1, accuracy: 1e-5)
        XCTAssertEqual(frustum.up, tan(0.5), accuracy: 1e-5)
        XCTAssertEqual(frustum.down, -tan(0.25), accuracy: 1e-5)
    }

    func testAngularVelocityProjectsOntoLocalPoseAxes() {
        // When facing -X (90-degree left yaw), angular velocity around world -X is a roll around local
        // forward (-Z), which maps to -2 on the local +Z (backward) axis of TrackedPose.
        let half = Float(0.5).squareRoot()
        var location = XrSpaceLocation()
        location.locationFlags = XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT
        location.pose = XrPosef(orientation: XrQuaternionf(x: 0, y: half, z: 0, w: half), position: XrVector3f(x: 0, y: 0, z: 0))
        var velocity = XrSpaceVelocity()
        velocity.velocityFlags = XR_SPACE_VELOCITY_ANGULAR_VALID_BIT | XR_SPACE_VELOCITY_LINEAR_VALID_BIT
        velocity.angularVelocity = XrVector3f(x: -2, y: 0, z: 0)
        velocity.linearVelocity = XrVector3f(x: 0, y: 1, z: 0)
        let tracked = TrackedPose(location, velocity)
        XCTAssertEqual(tracked?.angularVelocity.z ?? 0, -2, accuracy: 1e-5)
        XCTAssertEqual(tracked?.angularVelocity.x ?? 9, 0, accuracy: 1e-5)
        XCTAssertEqual(tracked?.linearVelocity.y, 1)
        location.locationFlags = XR_SPACE_LOCATION_POSITION_VALID_BIT
        XCTAssertNil(TrackedPose(location, velocity))
    }

    func testFixedSizeCharFieldsTruncateAndNullTerminate() {
        var info = XrActionSetCreateInfo()
        fill(&info.actionSetName, with: "stream")
        XCTAssertEqual(text(of: info.actionSetName), "stream")
        fill(&info.actionSetName, with: String(repeating: "a", count: 200))
        XCTAssertEqual(text(of: info.actionSetName).count, Int(XR_MAX_ACTION_SET_NAME_SIZE) - 1)
    }

    func testControllerProfilesBindPosesTriggerAndHaptics() {
        for profile in XRInput.profiles {
            for hand in [profile.left, profile.right] {
                // Every profile can work the panel; the hand profile binds nothing else, so that tracked hands
                // keep streaming as hands.
                XCTAssertNotNil(hand[.point], profile.path)
                XCTAssertNotNil(hand[.press], profile.path)
                if profile.path.hasSuffix("hand_interaction_ext") { continue }
                XCTAssertNotNil(hand[.grip], profile.path)
                XCTAssertNotNil(hand[.aim], profile.path)
                XCTAssertNotNil(hand[.trigger], profile.path)
                XCTAssertNotNil(hand[.haptic], profile.path)
            }
        }
    }
}
