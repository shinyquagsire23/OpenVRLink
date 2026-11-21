// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class FloorShapeTests: XCTestCase {
    /// A 2x2 square centered on the origin, oriented counterclockwise on the `(x, z)` plane.
    private let square = [Point2(-1, -1), Point2(1, -1), Point2(1, 1), Point2(-1, 1)]

    /// Returns true if any two non-adjacent edges of `polygon` intersect.
    private func crossesItself(_ polygon: [Point2]) -> Bool {
        for first in polygon.indices {
            for second in polygon.indices where second > first + 1 && !(first == 0 && second == polygon.count - 1) {
                if FloorShape.crossing(polygon[first], polygon[(first + 1) % polygon.count],
                                       polygon[second], polygon[(second + 1) % polygon.count]) != nil { return true }
            }
        }
        return false
    }

    func testAreaAndContainment() {
        XCTAssertEqual(FloorShape.signedArea(square), 4, accuracy: 1e-5)
        XCTAssertEqual(FloorShape.signedArea(square.reversed()), -4, accuracy: 1e-5)
        XCTAssertTrue(FloorShape.contains(square, Point2(0.5, -0.5)))
        XCTAssertFalse(FloorShape.contains(square, Point2(1.5, 0)))
        // Verify points in the concave notch of an L-shape report as outside.
        let ell = [Point2(0, 0), Point2(2, 0), Point2(2, 1), Point2(1, 1), Point2(1, 2), Point2(0, 2)]
        XCTAssertTrue(FloorShape.contains(ell, Point2(0.5, 1.5)))
        XCTAssertFalse(FloorShape.contains(ell, Point2(1.5, 1.5)))
    }

    func testFigureEightKeepsLargerLoop() {
        // A 2x2 square and a small loop meeting at a self-intersection near (1, 1).
        let eight = [Point2(-1, -1), Point2(1, -1), Point2(1, 1.5), Point2(1.5, 1), Point2(-1, 1)]
        XCTAssertTrue(crossesItself(eight))
        let simple = FloorShape.untangled(eight)
        XCTAssertFalse(crossesItself(simple))
        XCTAssertEqual(abs(FloorShape.signedArea(simple)), 4, accuracy: 0.01)
    }

    func testClosedStrokeFormsLoop() {
        // Almost a full circle, stopping ~10 cm short of the start point.
        let circle = FloorShape.circle(radius: 1.5, corners: 90)
        XCTAssertNil(FloorShape.loop(in: Array(circle[..<60]), joinWithin: 0.1), "two-thirds of a circle is not a closed loop")
        let nearly = Array(circle[..<90])
        let loop = try? XCTUnwrap(FloorShape.loop(in: nearly, joinWithin: 0.15))
        XCTAssertEqual(abs(FloorShape.signedArea(loop ?? [])), .pi * 1.5 * 1.5, accuracy: 0.1)
        // Overshooting so the stroke crosses itself trims both tails.
        let overshot = [Point2(2.5, -0.2)] + circle + [Point2(1.45, 0.05), Point2(2.5, 0.3)]
        let cut = try? XCTUnwrap(FloorShape.loop(in: overshot, joinWithin: 0.1))
        XCTAssertEqual(abs(FloorShape.signedArea(cut ?? [])), .pi * 1.5 * 1.5, accuracy: 0.1)
        XCTAssertFalse((cut ?? []).contains { $0.x > 2 })
        // Passing within `joinWithin` of the start and continuing without crossing still closes the loop.
        let beside = circle + [Point2(1.42, 0.02), Point2(1.0, 0.4)]
        let closed = try? XCTUnwrap(FloorShape.loop(in: beside, joinWithin: 0.1))
        XCTAssertEqual(abs(FloorShape.signedArea(closed ?? [])), .pi * 1.5 * 1.5, accuracy: 0.2)
    }

    func testThinScribbleIsRejected() {
        // A back-and-forth stroke 5 cm wide encloses less than the minimum area.
        let scribble = [Point2(0, 0), Point2(2, 0), Point2(2, 0.05), Point2(0, 0.05)]
        XCTAssertNil(FloorShape.loop(in: scribble, joinWithin: 0.1))
    }

    func testStrokeExitingAndReenteringExpandsBoundary() {
        // Exit through the right wall, loop around a 1x1 extension, and re-enter.
        let bump = [Point2(0.5, -0.5), Point2(2, -0.5), Point2(2, 0.5), Point2(0.5, 0.5)]
        let grown = try? XCTUnwrap(FloorShape.expanded(square, by: bump))
        XCTAssertEqual(abs(FloorShape.signedArea(grown ?? [])), 5, accuracy: 1e-3)
        XCTAssertTrue(FloorShape.contains(grown ?? [], Point2(1.5, 0)))
        XCTAssertTrue(FloorShape.contains(grown ?? [], Point2(-0.5, 0)))
        XCTAssertFalse(crossesItself(grown ?? []))
        // Reversing the stroke direction produces the same expanded area.
        let other = try? XCTUnwrap(FloorShape.expanded(square, by: bump.reversed()))
        XCTAssertEqual(abs(FloorShape.signedArea(other ?? [])), 5, accuracy: 1e-3)
        // Clockwise input polygons also expand properly.
        let clockwise = try? XCTUnwrap(FloorShape.expanded(square.reversed(), by: bump))
        XCTAssertEqual(abs(FloorShape.signedArea(clockwise ?? [])), 5, accuracy: 1e-3)
    }

    func testStrokeAroundCornerExpandsBoundary() {
        // Exit through the right wall and re-enter through the far wall around corner (1, 1).
        let round = [Point2(0.5, 0), Point2(2, 0), Point2(2, 2), Point2(0, 2), Point2(0, 0.5)]
        let grown = try? XCTUnwrap(FloorShape.expanded(square, by: round))
        // Total area equals the 2x2 square plus the 2x2 corner block minus their 1x1 overlap.
        XCTAssertEqual(abs(FloorShape.signedArea(grown ?? [])), 4 + 4 - 1, accuracy: 1e-3)
    }

    func testStrokeWithoutExitAndReentryReturnsNil() {
        XCTAssertNil(FloorShape.expanded(square, by: [Point2(0, 0), Point2(0.5, 0.5)]), "entirely inside")
        XCTAssertNil(FloorShape.expanded(square, by: [Point2(0, 0), Point2(3, 0)]), "exits without re-entering")
        XCTAssertNil(FloorShape.expanded(square, by: [Point2(-0.5, -3), Point2(-0.5, 3)].reversed()),
                     "straight line cutting across adds no enclosed exterior region")
    }

    func testStrokeWithTwoExcursionsAddsBoth() {
        let twice = [Point2(0.5, -0.8), Point2(1.5, -0.8), Point2(1.5, -0.4), Point2(0.5, -0.4),
                     Point2(0.5, 0.4), Point2(1.5, 0.4), Point2(1.5, 0.8), Point2(0.5, 0.8)]
        let grown = try? XCTUnwrap(FloorShape.expanded(square, by: twice))
        XCTAssertEqual(abs(FloorShape.signedArea(grown ?? [])), 4 + 0.2 + 0.2, accuracy: 1e-3)
        XCTAssertFalse(crossesItself(grown ?? []))
    }

    func testSimplifyingKeepsTheShape() {
        let circle = FloorShape.circle(radius: 2, corners: 400)
        let fewer = FloorShape.simplified(circle, tolerance: 0.02, closed: true)
        XCTAssertLessThan(fewer.count, 60)
        XCTAssertEqual(FloorShape.signedArea(fewer), .pi * 4, accuracy: 0.3)
        // Collinear points along a straight edge are dropped while corners are preserved.
        let wall = [Point2(0, 0), Point2(1, 0.001), Point2(2, 0), Point2(2, 2), Point2(0, 2)]
        XCTAssertEqual(FloorShape.simplified(wall, tolerance: 0.02, closed: true).count, 4)
    }

    func testTidiedOrientsPolygonCounterclockwise() {
        XCTAssertGreaterThan(FloorShape.signedArea(FloorShape.tidied(square.reversed())), 0)
    }

    func testNearestCornerAndEdge() {
        XCTAssertEqual(FloorShape.nearestCorner(of: square, to: Point2(0.95, 1.02), within: 0.1), 2)
        XCTAssertNil(FloorShape.nearestCorner(of: square, to: Point2(0, 0), within: 0.1))
        let edge = FloorShape.nearestEdge(of: square, closed: true, to: Point2(-1.03, 0.5), within: 0.1)
        XCTAssertEqual(edge?.index, 3)
        XCTAssertEqual(edge?.along ?? 0, 0.25, accuracy: 1e-4)
        XCTAssertNil(FloorShape.nearestEdge(of: square, closed: false, to: Point2(-1.03, 0.5), within: 0.1),
                     "open polylines do not connect the last point to the first")
    }

    func testCenteredPlayAreaRectangle() {
        let whole = FloorShape.centeredRectangle(in: square)
        XCTAssertEqual(whole.width, 2, accuracy: 0.05)
        XCTAssertEqual(whole.depth, 2, accuracy: 0.05)
        // When the origin is off-center in a 4x2 room, the nearer walls constrain the rectangle.
        let room = [Point2(-1, -0.5), Point2(3, -0.5), Point2(3, 1.5), Point2(-1, 1.5)]
        let held = FloorShape.centeredRectangle(in: room)
        XCTAssertEqual(held.width, 2, accuracy: 0.1)
        XCTAssertEqual(held.depth, 1, accuracy: 0.05)
        XCTAssertEqual(FloorShape.centeredRectangle(in: room.map { $0 + Point2(5, 0) }).width, 0, "origin is outside")
    }
}

final class RoomTests: XCTestCase {
    private func room(center: Point2 = Point2(0, 0), boundary: [Point2] = []) -> Room {
        var room = Room(id: UUID())
        room.center = center
        room.boundary = boundary
        room.closed = !boundary.isEmpty
        return room
    }

    private func assertEqual(_ a: Vec3, _ b: Vec3, accuracy: Float = 1e-4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }

    func testFloorFrameMatchesPose() {
        let frame = FloorFrame(position: Vec3(1, 0.2, -3), yaw: 0.7)
        let point = Point2(0.4, -1.1)
        // Local +z points backward (-forward), matching Vec3 conventions.
        let pose = frame.pose
        assertEqual(frame.world(point, up: 0.5), pose.position + pose.right * point.x + pose.up * 0.5 + pose.forward * -point.z)
        let back = frame.local(frame.world(point))
        XCTAssertEqual(back.x, point.x, accuracy: 1e-5)
        XCTAssertEqual(back.z, point.z, accuracy: 1e-5)
        XCTAssertEqual(FloorFrame(pose: pose).yaw, 0.7, accuracy: 1e-5)
        // Pitching downward preserves the horizontal heading.
        XCTAssertEqual(FloorFrame.heading(of: HeadPose(position: Vec3(0, 1, 0), yaw: -1.2, pitch: -0.9).pose), -1.2, accuracy: 1e-4)
    }

    func testRoomSelectionPicksClosestMatchingCenter() {
        let anchor = FloorFrame(position: Vec3(0, 0, 0), yaw: 0)
        let near = PlacedRoom(room: room(center: Point2(1, 0)), anchor: anchor)
        let far = PlacedRoom(room: room(center: Point2(-2, 0)), anchor: anchor)
        XCTAssertEqual(PlacedRoom.choose(at: Vec3(0, 1.6, 0), among: [far, near])?.room.id, near.room.id)
        XCTAssertNil(PlacedRoom.choose(at: Vec3(0, 1.6, 9), among: [far, near]), "more than 2.5 m from either center")
        // Standing inside a large room's boundary matches even beyond 2.5 m from its center.
        let hall = PlacedRoom(room: room(center: Point2(0, 0), boundary: FloorShape.circle(radius: 6)), anchor: anchor)
        XCTAssertEqual(PlacedRoom.choose(at: Vec3(0, 1.6, 5), among: [hall])?.room.id, hall.room.id)
        // When matching multiple rooms, the room with the closer center wins.
        let closet = PlacedRoom(room: room(center: Point2(0, 4.5)), anchor: anchor)
        XCTAssertEqual(PlacedRoom.choose(at: Vec3(0, 1.6, 4), among: [hall, closet])?.room.id, closet.room.id)
        // An unclosed boundary does not enclose points.
        var open = room(center: Point2(0, 0), boundary: FloorShape.circle(radius: 6))
        open.closed = false
        XCTAssertNil(PlacedRoom.choose(at: Vec3(0, 1.6, 5), among: [PlacedRoom(room: open, anchor: anchor)]))
    }

    func testPlaySpaceRoundTripsPosesAndFrames() {
        var kept = room(center: Point2(1, 2))
        kept.floor = 0.1
        kept.facing = .pi / 2          // rotated to face along -x
        let placed = PlacedRoom(room: kept, anchor: FloorFrame(position: Vec3(10, 0.5, 0), yaw: 0))
        let space = PlaySpace(placed)
        // Stand 1 m ahead of the room center (along -x), 1.5 m above its floor, facing forward.
        let head = HeadPose(position: Vec3(10, 2.1, 2), yaw: .pi / 2).pose
        let inRoom = space.entering(head)
        assertEqual(inRoom.position, Vec3(0, 1.5, -1))
        assertEqual(inRoom.forward, Vec3(0, 0, -1))
        assertEqual(space.leaving(inRoom).position, head.position)
        assertEqual(space.leaving(inRoom).right, head.right)
        // Moving along -x in tracking space maps to forward (-z) in the rotated room.
        var tracked = TrackedPose(pose: head)
        tracked.linearVelocity = Vec3(-2, 0, 0)
        tracked.angularVelocity = Vec3(0.1, 0.2, 0.3)
        assertEqual(space.entering(tracked).linearVelocity, Vec3(0, 0, -2))
        assertEqual(space.entering(tracked).angularVelocity, Vec3(0.1, 0.2, 0.3))
        // Frame eye poses convert back to tracking space.
        let layout = FrameLayout(views: [.init(eye: inRoom, tiles: [])], eyePixels: (1, 1))
        assertEqual(space.leaving(layout).views[0].eye.position, head.position)
    }

    func testHandsAndControllersTransformIntoPlaySpace() {
        let space = PlaySpace(FloorFrame(position: Vec3(0, 0, -2), yaw: .pi))
        var controller = ControllerState(grip: TrackedPose(pose: HeadPose(position: Vec3(0.3, 1, -3)).pose))
        controller.aim = controller.grip.pose
        guard case .controller(let moved) = space.entering(.controller(controller)) else { return XCTFail("not a controller") }
        assertEqual(moved.grip.pose.position, Vec3(-0.3, 1, 1))
        assertEqual(moved.aim?.forward ?? Vec3(0, 0, 0), Vec3(0, 0, 1))
        var hand = TrackedHand.flat(wrist: HeadPose(position: Vec3(0.3, 1, -3)).pose, side: .left)
        hand.systemPinch = .pinching(ray: HeadPose(position: Vec3(0, 1.6, -2)).pose, pressed: true)
        guard case .hand(let inRoom) = space.entering(.hand(hand)) else { return XCTFail("not a hand") }
        assertEqual(inRoom.joints[1].position, Vec3(-0.3, 1, 1))
        guard case .pinching(let ray, true) = inRoom.systemPinch else { return XCTFail("no pinch") }
        assertEqual(ray.position, Vec3(0, 1.6, 0))
    }

    func testRecenterMovesOriginWithoutMovingPhysicalWalls() {
        let walls = [Point2(-2, -2), Point2(2, -2), Point2(2, 2), Point2(-2, 2)]
        let placed = PlacedRoom(room: room(boundary: walls), anchor: FloorFrame(position: Vec3(5, 0, 5), yaw: 0.3))
        // Recenter 1 m off-center with a 90-degree yaw turn.
        let corner = placed.anchor.world(walls[2])
        let before = PlaySpace(placed)
        let head = HeadPose(position: placed.anchor.world(Point2(1, 0), up: 1.6), yaw: 0.3 + .pi / 2).pose
        let recentering = placed.recentering(to: head)
        let after = PlaySpace(placed, recentering: recentering)
        XCTAssertNotEqual(before.boundary, after.boundary)
        // Boundary corners remain at the same tracking-space coordinates after recentering.
        for space in [before, after] {
            let again = space.leaving(Pose(position: Vec3(space.boundary[2].x, 0, space.boundary[2].z),
                                           right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1)))
            assertEqual(again.position, corner, accuracy: 1e-3)
        }
        // The head sits directly above the recentered origin facing -z.
        let inRoom = after.entering(head)
        assertEqual(inRoom.position, Vec3(0, 1.6, 0), accuracy: 1e-3)
        assertEqual(inRoom.forward, Vec3(0, 0, -1), accuracy: 1e-3)
    }

    func testChaperoneJSONSerialization() throws {
        let none = PlaySpace.trackingSpace.chaperone(universe: 7)
        XCTAssertTrue(none.contains(#""play_area":[0,0]"#))
        XCTAssertTrue(none.contains(#""universeID":7"#))
        let square = [Point2(-1, -1.5), Point2(1, -1.5), Point2(1, 1.5), Point2(-1, 1.5)]
        for corners in [square, square.reversed()] {
            let text = PlaySpace(origin: PlaySpace.trackingSpace.origin, boundary: corners).chaperone(universe: 9)
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let universe = try XCTUnwrap((parsed["universes"] as? [[String: Any]])?.first)
            let walls = try XCTUnwrap(universe["collision_bounds"] as? [[[Double]]])
            XCTAssertEqual(walls.count, 4)
            // Each wall quad lists [corner i floor, corner i top, corner i+1 top, corner i+1 floor].
            XCTAssertEqual(walls[0], [[-1, 0, -1.5], [-1, 2.43, -1.5], [1, 2.43, -1.5], [1, 0, -1.5]])
            XCTAssertEqual(walls[3][3], walls[0][0], "last wall ends at first wall's starting corner")
            let area = try XCTUnwrap(universe["play_area"] as? [Double])
            XCTAssertEqual(area[0], 2, accuracy: 0.1)
            XCTAssertEqual(area[1], 3, accuracy: 0.1)
        }
    }

    func testRoomStorePersistence() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rooms-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = RoomStore(file: file)
        var kept = room(center: Point2(1, 2), boundary: [Point2(0, 0), Point2(1, 0), Point2(0, 1)])
        kept.floor = -0.02
        kept.facing = 1.5
        store.put(kept)
        store.put(room())
        kept.floor = -0.05
        store.put(kept)
        store.flush()
        let again = RoomStore(file: file)
        XCTAssertEqual(again.rooms.count, 2)
        XCTAssertEqual(again.room(kept.id), kept)
        again.remove(kept.id)
        again.flush()
        XCTAssertEqual(RoomStore(file: file).rooms.count, 1)
        again.removeAll()
        again.flush()
        XCTAssertTrue(RoomStore(file: file).rooms.isEmpty)
    }
}

final class FloorShapeSnapTests: XCTestCase {
    private let square = [Point2(-1, -1), Point2(1, -1), Point2(1, 1), Point2(-1, 1)]

    func testStrokeEndpointsNearBoundarySnapAcrossIt() {
        // Extension drawn from 6 cm outside the right wall to 8 cm outside it without crossing.
        let bump = [Point2(1.06, -0.5), Point2(2, -0.5), Point2(2, 0.5), Point2(1.08, 0.5)]
        XCTAssertNil(FloorShape.expanded(square, by: bump), "does not touch boundary when snap is 0")
        let grown = FloorShape.expanded(square, by: bump, snap: 0.1)
        XCTAssertEqual(abs(FloorShape.signedArea(grown ?? [])), 5, accuracy: 0.02)
        XCTAssertTrue(FloorShape.contains(grown ?? [], Point2(1.5, 0)))
        // Endpoints beyond the snap distance are ignored.
        let apart = bump.map { $0 + Point2(0.2, 0) }
        XCTAssertNil(FloorShape.expanded(square, by: apart, snap: 0.1))
        // One endpoint inside the polygon and the other within snap distance outside.
        let half = [Point2(0.5, -0.5), Point2(2, -0.5), Point2(2, 0.5), Point2(1.05, 0.5)]
        XCTAssertEqual(abs(FloorShape.signedArea(FloorShape.expanded(square, by: half, snap: 0.1) ?? [])), 5, accuracy: 0.02)
    }
}
