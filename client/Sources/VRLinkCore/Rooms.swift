// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Room definitions, play-space coordinate transforms, SteamVR chaperone
// serialization, and `rooms.json` persistence.

/// A horizontal coordinate frame defined by a 3D position and a yaw angle around `+y`
/// (`+x` right, `+y` up, `+z` back).
public struct FloorFrame {
    public var position: Vec3
    /// Yaw angle in radians around `+y` (`0` faces `-z`).
    public var yaw: Float

    public init(position: Vec3, yaw: Float) {
        self.position = position
        self.yaw = yaw
    }

    /// Creates a horizontal frame from `pose`'s position and horizontal heading, discarding pitch and roll.
    public init(pose: Pose) {
        position = pose.position
        yaw = FloorFrame.heading(of: pose)
    }

    /// Extracts the horizontal yaw angle from `pose`, falling back to its up vector when
    /// looking straight up or down.
    public static func heading(of pose: Pose) -> Float {
        var ahead = pose.forward
        if ahead.x * ahead.x + ahead.z * ahead.z < 0.01 { ahead = ahead.y > 0 ? pose.up * -1 : pose.up }
        return atan2(-ahead.x, -ahead.z)
    }

    public var pose: Pose { HeadPose(position: position, yaw: yaw).pose }

    /// Converts a 2D floor point (plus optional `up` height offset) from this frame into parent coordinates.
    public func world(_ point: Point2, up: Float = 0) -> Vec3 {
        let c = cos(yaw), s = sin(yaw)
        return Vec3(position.x + c * point.x + s * point.z, position.y + up, position.z - s * point.x + c * point.z)
    }

    /// Projects a 3D parent-space point onto this frame's horizontal `(x, z)` plane.
    public func local(_ point: Vec3) -> Point2 {
        let c = cos(yaw), s = sin(yaw), x = point.x - position.x, z = point.z - position.z
        return Point2(c * x - s * z, s * x + c * z)
    }
}

public struct Room: Codable, Equatable, Identifiable {
    /// UUID of the world anchor that fixes this room in physical space.
    public var id: UUID
    /// Room center on the anchor's horizontal `(x, z)` plane.
    public var center = Point2(0, 0)
    /// Forward yaw angle in radians relative to the anchor.
    public var facing: Float = 0
    /// Floor height in meters relative to the anchor.
    public var floor: Float = 0
    /// Boundary polygon vertices on the anchor's horizontal `(x, z)` plane.
    public var boundary: [Point2] = []
    /// Whether `boundary` forms a finished closed polygon rather than an in-progress polyline.
    public var closed = false

    public init(id: UUID) { self.id = id }

    /// Decodes optional fields with defaults so rooms saved by older builds still load.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        center = try values.decodeIfPresent(Point2.self, forKey: .center) ?? center
        facing = try values.decodeIfPresent(Float.self, forKey: .facing) ?? facing
        floor = try values.decodeIfPresent(Float.self, forKey: .floor) ?? floor
        boundary = try values.decodeIfPresent([Point2].self, forKey: .boundary) ?? boundary
        closed = try values.decodeIfPresent(Bool.self, forKey: .closed) ?? closed
    }

    /// Maximum horizontal distance in meters from a room's center that still selects the room when outside its boundary.
    public static let reach: Float = 2.5

    /// Returns `boundary` when it is closed and has at least three vertices.
    public var outline: [Point2]? { closed && boundary.count >= 3 ? boundary : nil }
}

/// Session-only center and forward yaw override in anchor coordinates after a recenter.
public struct Recentering: Equatable {
    public var center: Point2
    public var facing: Float
    public init(center: Point2, facing: Float) {
        self.center = center
        self.facing = facing
    }
}

/// A saved `Room` paired with the current tracking-space frame of its world anchor.
public struct PlacedRoom {
    public var room: Room
    public var anchor: FloorFrame

    public init(room: Room, anchor: FloorFrame) {
        self.room = room
        self.anchor = anchor
    }

    /// Room center on the floor in tracking space.
    public var center: Vec3 { anchor.world(room.center, up: room.floor) }
    /// Floor `y` coordinate in tracking space.
    public var floorHeight: Float { anchor.position.y + room.floor }
    /// Horizontal coordinate frame for the room (or its recentered override) in tracking space.
    public func frame(_ recentering: Recentering? = nil) -> FloorFrame {
        FloorFrame(position: anchor.world(recentering?.center ?? room.center, up: room.floor),
                   yaw: anchor.yaw + (recentering?.facing ?? room.facing))
    }

    /// Horizontal distance in meters from the room's center to `point`.
    public func distance(to point: Vec3) -> Float { (anchor.local(point) - room.center).length }

    /// Returns true if `point` lies inside the room's closed boundary polygon.
    public func encloses(_ point: Vec3) -> Bool {
        room.outline.map { FloorShape.contains($0, anchor.local(point)) } ?? false
    }

    /// Returns true if `point` is inside the room's boundary or within `Room.reach` of its center.
    public func isHere(_ point: Vec3) -> Bool { encloses(point) || distance(to: point) <= Room.reach }

    /// Picks the matching room with the closest center to `point`.
    public static func choose(at point: Vec3, among rooms: [PlacedRoom]) -> PlacedRoom? {
        rooms.filter { $0.isHere(point) }.min { $0.distance(to: point) < $1.distance(to: point) }
    }

    /// Computes a `Recentering` that places the play-space origin beneath `head` aligned with its heading.
    public func recentering(to head: Pose) -> Recentering {
        Recentering(center: anchor.local(head.position), facing: FloorFrame.heading(of: head) - anchor.yaw)
    }
}

/// Coordinate frame and floor boundary used for poses sent to the host.
public struct PlaySpace {
    /// Origin of the play space on the floor in tracking space.
    public var origin: Pose
    /// Boundary vertices in play-space coordinates, or empty when no boundary is active.
    public var boundary: [Point2]

    public init(origin: Pose, boundary: [Point2] = []) {
        self.origin = origin
        self.boundary = boundary
    }

    /// Identity play space aligned with the raw tracking origin and no boundary.
    public static let trackingSpace = PlaySpace(origin: FloorFrame(position: Vec3(0, 0, 0), yaw: 0).pose)

    /// Play space positioned at `frame` with no boundary.
    public init(_ frame: FloorFrame) { self.init(origin: frame.pose) }

    /// Builds a play space from `placed` and an optional `recentering`, keeping the boundary fixed in physical space.
    public init(_ placed: PlacedRoom, recentering: Recentering? = nil) {
        origin = placed.frame(recentering).pose
        // Compute boundary vertices in anchor coordinates so small anchor-pose jitter does not
        // perturb the values and trigger redundant chaperone updates.
        let center = recentering?.center ?? placed.room.center
        let within = FloorFrame(position: Vec3(center.x, 0, center.z), yaw: recentering?.facing ?? placed.room.facing)
        boundary = (placed.room.outline ?? []).map { within.local(Vec3($0.x, 0, $0.z)) }
    }

    // MARK: Tracking space -> play space

    public func entering(_ pose: Pose) -> Pose { origin.relative(pose) }

    /// Rotates a direction or velocity vector from tracking space into play-space coordinates.
    public func entering(direction v: Vec3) -> Vec3 {
        Vec3(v.dot(origin.right), v.dot(origin.up), -v.dot(origin.forward))
    }

    /// Converts a tracked pose into play space. Linear velocity rotates with the coordinate
    /// frame, while angular velocity is already in device-local coordinates.
    public func entering(_ tracked: TrackedPose) -> TrackedPose {
        var out = tracked
        out.pose = entering(tracked.pose)
        out.linearVelocity = entering(direction: tracked.linearVelocity)
        return out
    }

    public func entering(_ input: HandInput) -> HandInput {
        switch input {
        case .controller(var controller):
            controller.grip = entering(controller.grip)
            controller.aim = controller.aim.map { entering($0) }
            return .controller(controller)
        case .hand(var hand):
            hand.joints = hand.joints.map { entering($0) }
            if case .pinching(let ray, let pressed) = hand.systemPinch {
                hand.systemPinch = .pinching(ray: entering(ray), pressed: pressed)
            }
            return .hand(hand)
        }
    }

    // MARK: Play space -> tracking space

    public func leaving(_ pose: Pose) -> Pose { origin.placing(pose) }

    /// Converts a frame's rendered eye poses from play space back into tracking space.
    public func leaving(_ layout: FrameLayout) -> FrameLayout {
        var out = layout
        for index in out.views.indices { out.views[index].eye = leaving(out.views[index].eye) }
        return out
    }

    // MARK: SteamVR chaperone serialization

    /// Wall height in meters used by `vrlink` in chaperone JSON.
    static let wallHeight = "2.43"

    /// Serializes the boundary as SteamVR `chaperone_info` JSON (docs/svl-values/vte-id-table.md),
    /// emitting one wall quad per polygon edge and setting `play_area` to the largest
    /// origin-centered rectangle inside the polygon. Standing and seated origins are zero because
    /// outgoing poses are already transformed into play space. When `boundary` is empty, emits the
    /// four degenerate walls sent by `vrlink`.
    public func chaperone(universe: UInt32) -> String {
        func number(_ value: Float) -> String { String(format: "%.4f", value) }
        var corners = boundary
        // `vrlink` orders wall corners counterclockwise on the `(x, z)` plane.
        if FloorShape.signedArea(corners) < 0 { corners.reverse() }
        var walls: [String] = []
        for (index, a) in corners.enumerated() where corners.count >= 3 {
            let b = corners[(index + 1) % corners.count], top = PlaySpace.wallHeight
            walls.append("[[\(number(a.x)),0,\(number(a.z))],[\(number(a.x)),\(top),\(number(a.z))],"
                         + "[\(number(b.x)),\(top),\(number(b.z))],[\(number(b.x)),0,\(number(b.z))]]")
        }
        var area = "[0,0]"
        if walls.isEmpty {
            walls = Array(repeating: "[[0,0,0],[0,\(PlaySpace.wallHeight),0],[0,\(PlaySpace.wallHeight),0],[0,0,0]]", count: 4)
        } else {
            let rectangle = FloorShape.centeredRectangle(in: corners)
            area = "[\(number(rectangle.width)),\(number(rectangle.depth))]"
        }
        let pose = #"{"translation":[0,0,0],"yaw":0}"#
        return #"{"jsonid":"chaperone_info","universes":[{"collision_bounds":["# + walls.joined(separator: ",")
            + #"],"play_area":"# + area + #","seated":"# + pose + #","setup_standing2":"# + pose
            + #","standing":"# + pose + #","time":"Thu Jan  1 00:00:00 1970","universeID":"#
            + String(universe) + #"}],"version":5}"#
    }
}

/// Thread-safe store that persists `Room` definitions to `rooms.json` in the data directory.
public final class RoomStore {
    private let lock = NSLock()
    private var kept: [Room]
    private let file: URL
    private let saving = DispatchQueue(label: "rooms", qos: .utility)

    public init(file: URL = DataDirectory.url.appendingPathComponent("rooms.json")) {
        self.file = file
        let data = try? Data(contentsOf: file)
        let read = data.flatMap { try? JSONDecoder().decode([Room].self, from: $0) }
        kept = read ?? []
        readable = data == nil || read != nil
    }

    /// False if `rooms.json` exists on disk but failed to decode, preventing callers from
    /// treating a corrupt file as an empty room list and deleting world anchors.
    public let readable: Bool

    public var rooms: [Room] {
        lock.lock()
        defer { lock.unlock() }
        return kept
    }

    public func room(_ id: UUID) -> Room? { rooms.first { $0.id == id } }

    /// Inserts `room` or replaces an existing room with the same `id`.
    public func put(_ room: Room) {
        change { rooms in
            if let index = rooms.firstIndex(where: { $0.id == room.id }) { rooms[index] = room } else { rooms.append(room) }
        }
    }

    public func remove(_ id: UUID) { change { $0.removeAll { $0.id == id } } }

    public func removeAll() { change { $0 = [] } }

    private func change(_ edit: (inout [Room]) -> Void) {
        lock.lock()
        let before = kept
        edit(&kept)
        let schedule = kept != before && !writeDue
        if schedule { writeDue = true }
        lock.unlock()
        // Coalesce rapid updates (such as dragging a boundary corner) into a single disk write.
        if schedule { saving.asyncAfter(deadline: .now() + RoomStore.writeDelay) { self.write() } }
    }

    private var writeDue = false
    private static let writeDelay = 0.25

    private func write() {
        lock.lock()
        let rooms = kept, due = writeDue
        writeDue = false
        lock.unlock()
        guard due else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(rooms).write(to: file, options: .atomic)
    }

    /// Synchronously flushes any pending changes to disk.
    public func flush() { saving.sync { write() } }
}
