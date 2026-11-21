// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import QuartzCore
import RealityKit
import SwiftUI
import VRLinkCore
import VRLinkVisionTracking
import simd

/// Shared state between the Room Setup immersive space and its floating toolbar window.
@MainActor
public final class RoomSetupControls: ObservableObject {
    public init() {}
    /// Whether the Room Setup immersive space is open.
    @Published public var open = false
    /// When true, boundaries are edited corner-by-corner (Advanced mode); when false, strokes paint boundaries (Basic mode).
    @Published public var advanced = false
    /// UUID of the room the user is currently standing in, enabling the "Remove Room" button.
    @Published public var roomHere: UUID?
    var add: (() -> Void)?
    var remove: (() -> Void)?

    public static let spaceID = "room-setup"
    public static let windowID = "room-setup-controls"
}

/// Manages the Room Setup immersive space for creating, positioning, and drawing boundaries for rooms.
///
/// Each room displays a center post with a forward-pointing flag at the top, a concentric floor
/// grid, and its boundary polygon. Users interact using hand pinches (gaze-targeted or direct)
/// or VR controllers (aimed with the trigger/grip or held directly against an element):
///
/// - Dragging the post moves the room center, scaling movement with distance when grabbed from afar.
/// - Dragging the flag rotates the room's forward direction toward the pointer.
/// - Pressing "Reset Floor Height" raises the floor halfway to the headset; holding a hand or
///   controller below the floor pushes it down to match the physical floor.
/// - Pinching or pulling the trigger on the floor edits the boundary. Basic mode paints strokes
///   that form a closed loop or expand an existing boundary; Advanced mode places and drags
///   individual polygon vertices and splits held edges. Both modes edit the same polygon.
///
/// Controllers aim along their aim pose. visionOS turns a controller's trigger into a
/// look-and-pinch of its own unless the app claims the controller, and Room Setup does not claim
/// it (so the trigger keeps working on the toolbar window); such a pinch counts as that
/// controller's trigger, aimed by the controller rather than by the eyes. Indirect hand pinches start on the floor at the initial
/// eye-gaze hit point and translate horizontally at `handTravelGain` times hand movement, ignoring
/// wrist rotation.
///
/// Digital Crown recenters only trigger anchor re-measurement because rooms are stored relative to
/// ARKit world anchors rather than the tracking origin.
@MainActor
public final class RoomSetupSpace {
    private let rooms: RoomTracker
    private let head: HeadTracking
    private let controllers: ControllerTracking
    private let hands: HandJoints
    private let controls: RoomSetupControls

    public private(set) var stopped = false
    /// Callbacks wired by `RoomSetupView` to dismiss the toolbar window and immersive space on exit.
    var closeControls: (() -> Void)?
    var closeSpace: (() -> Void)?

    public init(rooms: RoomTracker, head: HeadTracking, controllers: ControllerTracking, hands: HandJoints,
                controls: RoomSetupControls) {
        self.rooms = rooms
        self.head = head
        self.controllers = controllers
        self.hands = hands
        self.controls = controls
    }

    // MARK: Scene entities

    private let root = Entity()
    private var figures: [UUID: RoomFigure] = [:]
    private let catcher = Entity()
    private let paint = ModelEntity()
    private var pointers: [Pointer: PointerFigure] = [:]
    private var updates: EventSubscription?

    // MARK: Interaction state

    private var lastFrame: TimeInterval = 0
    /// Smoothed headset `y` coordinate in tracking space so post heights do not bob with small head movements.
    private var headHeight: Float?
    private var wearer: Pose?
    /// Room targeted by floor strokes (the room the user is standing in, or otherwise the closest room).
    private var active: PlacedRoom?
    private var presses: [Pointer: Press] = [:]
    private var triggerHeld: [Side: Bool] = [:]
    /// Most recent hand pointer ray endpoints and timestamp for rendering.
    private var handRays: [Pointer: (from: SIMD3<Float>, to: SIMD3<Float>, time: TimeInterval)] = [:]
    private var paintDrawn = 0

    /// Hold duration in seconds required to split a boundary edge into a new corner.
    private static let holdToSplit: TimeInterval = 0.3
    /// Horizontal movement multiplier applied to indirect hand drags on the floor.
    private static let handTravelGain: Float = 4
    /// Reference grab distance in meters for 1:1 movement; grabs beyond this scale proportionally up to `mostGain`.
    private static let armsLength: Float = 0.35
    private static let mostGain: Float = 8
    /// Maximum distance in meters outside an existing boundary where stroke endpoints snap across it.
    private static let snapToBoundary: Float = 0.1
    /// Minimum spacing in meters between consecutive points in a painted floor stroke.
    private static let strokeStep: Float = 0.03
    /// Distance in meters ahead of the user where newly created rooms are placed.
    private static let newRoomAhead: Float = 0.7
    /// Vertical offset below tracked controller grip or lowest hand joint used when pushing the floor down.
    private static let controllerReach: Float = 0.04, handReach: Float = 0.01
    /// Maximum horizontal distance in meters from the active room's center where hands or controllers can push the floor down.
    private static let pushWithin: Float = 3.5

    /// Vertical ray origin offset and maximum hit distance in meters for direct floor pinches.
    private static let directLift: Float = 0.05, directReach: Float = 0.2
    /// Controller sides currently tracked.
    private var controllersHeld: Set<Side> = []
    /// Where each tracked controller's grip is, to tell which one a pinch came from.
    private var grips: [Side: SIMD3<Float>] = [:]
    /// The pinch visionOS is making of each controller's trigger, while it lasts.
    private var triggerPinch: [Side: SpatialEventCollection.Event.ID] = [:]
    private var triggerPinchNoted = false

    private enum Pointer: Hashable {
        case controller(Side)
        case hand(SpatialEventCollection.Event.ID)
    }

    private struct Ray {
        var origin: SIMD3<Float>
        var direction: SIMD3<Float>

        /// Intersects the ray with a horizontal plane at `height`, returning `nil` if pointing upward or more than 20 m away.
        func floor(at height: Float) -> SIMD3<Float>? {
            guard direction.y < -0.02 else { return nil }
            let along = (height - origin.y) / direction.y
            guard along > 0, along < 20 else { return nil }
            return origin + direction * along
        }

        /// Returns the minimum distance between the ray and segment `a`–`b`, along with the ray parameter at closest approach.
        func approach(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> (gap: Float, along: Float) {
            let v = b - a, w = origin - a
            let across = dot(direction, v), size = dot(v, v), behind = dot(direction, w), beside = dot(v, w)
            let denominator = size - across * across
            var part: Float = 0
            if size > 1e-9 { part = denominator > 1e-9 ? (beside - across * behind) / denominator : beside / size }
            part = max(0, min(1, part))
            let nearest = a + v * part
            let along = max(0, dot(nearest - origin, direction))
            return (length(origin + direction * along - nearest), along)
        }
    }

    /// Pointer state for a single input sample, including its optional aim ray, 3D device position,
    /// and whether it is a direct touch.
    private struct Sample {
        var ray: Ray?
        var device: SIMD3<Float>
        var direct = false
    }

    private enum Action {
        case nothing
        case post(room: UUID, centerAtStart: Point2)
        case flag(room: UUID, targetAtStart: SIMD3<Float>)
        case corner(room: UUID, index: Int, offset: Point2)
        case sideHeld(room: UUID, side: Int, at: Point2)
        case stroke(room: UUID, points: [Point2])

        func concerns(_ id: UUID) -> Bool {
            switch self {
            case .nothing: return false
            case .post(let room, _), .flag(let room, _), .corner(let room, _, _), .sideHeld(let room, _, _), .stroke(let room, _):
                return room == id
            }
        }
    }

    private struct Press {
        var action = Action.nothing
        var deviceAtStart: SIMD3<Float>
        /// Initial floor hit point from eye gaze for an indirect hand pinch on the floor.
        var start: SIMD3<Float>?
        var gain: Float = 1
        var began: TimeInterval
    }

    // MARK: Lifecycle

    func setup(_ content: inout RealityViewContent) {
        controls.open = true
        controls.add = { [weak self] in self?.addRoom() }
        controls.remove = { [weak self] in self?.removeRoomHere() }
        rooms.planes.start()
        // Entering an immersive space resets the tracking origin, so re-measure world anchors.
        rooms.anchors.originMoved()

        // Large invisible collision plane beneath the active floor so indirect eye-gaze pinches
        // on empty floor still deliver gesture events.
        catcher.components.set(InputTargetComponent())
        catcher.components.set(CollisionComponent(shapes: [.generateBox(width: 60, height: 0.02, depth: 60)]))
        catcher.isEnabled = false
        root.addChild(catcher)
        paint.isEnabled = false
        root.addChild(paint)
        content.add(root)
        updates = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.everyFrame() }
        }
        Log.note("room setup: opened with \(rooms.store.rooms.count) saved room(s)")
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        updates?.cancel()
        updates = nil
        root.removeFromParent()
        rooms.planes.stop()
        rooms.store.flush()
        controls.open = false
        controls.roomHere = nil
        controls.add = nil
        controls.remove = nil
        closeControls?()
        // Dismiss the immersive space as well if `stop()` was triggered by backgrounding the app.
        closeSpace?()
        Log.note("room setup: closed")
    }

    func worldRecentered() { rooms.worldRecentered() }

    // MARK: Rooms

    private func change(_ id: UUID, _ edit: (inout Room) -> Void) {
        guard var room = rooms.store.room(id) else { return }
        edit(&room)
        rooms.store.put(room)
    }

    private func placed(_ id: UUID) -> PlacedRoom? {
        guard let room = rooms.store.room(id), let anchor = rooms.anchors.frame(of: id) else { return nil }
        return PlacedRoom(room: room, anchor: anchor)
    }

    private func addRoom() {
        guard let wearer else { return }
        let facing = FloorFrame.heading(of: wearer)
        let ahead = FloorFrame(position: wearer.position, yaw: facing).world(Point2(0, -RoomSetupSpace.newRoomAhead))
        // Initialize the floor height from ARKit plane detection beneath the headset, defaulting to 0.
        let floor = rooms.planes.height(below: wearer.position) ?? 0
        Task {
            let room = await rooms.anchors.addRoom(at: Vec3(ahead.x, floor, ahead.z)) { $0.facing = facing }
            Log.note(room.map { String(format: "room setup: added room %@ with floor at %.2f m", $0.id.uuidString, floor) }
                     ?? "room setup: failed to add room")
        }
    }

    private func removeRoomHere() {
        guard let id = controls.roomHere else { return }
        presses = presses.filter { !$0.value.action.concerns(id) }
        Task {
            await rooms.anchors.removeRoom(id)
            Log.note("room setup: removed room \(id.uuidString)")
        }
    }

    private func resetFloor(_ id: UUID) {
        guard let placed = placed(id), let headHeight else { return }
        // Raise the floor halfway toward the headset so the user can push it back down to the physical floor.
        let raised = placed.floorHeight + (headHeight - placed.floorHeight) / 2
        change(id) { $0.floor = raised - placed.anchor.position.y }
        Log.note(String(format: "room setup: reset floor of %@ to %.2f m", id.uuidString, raised))
    }

    /// Lowers the active room's floor when a hand or controller stays below it for `pushHold`
    /// seconds, using the shallowest depth over that window so single-frame tracking spikes do
    /// not sink the floor.
    private func pushFloor(heldControllers: [ControllerState?], now: TimeInterval) {
        guard let active else {
            pushes = []
            return
        }
        var lowest: [SIMD3<Float>] = []
        for controller in heldControllers.compactMap({ $0 }) {
            lowest.append(controller.grip.pose.position.simd - SIMD3(0, RoomSetupSpace.controllerReach, 0))
        }
        for hand in hands.hands().compactMap({ $0 }) {
            if let joint = hand.joints.min(by: { $0.position.y < $1.position.y }) {
                lowest.append(joint.position.simd - SIMD3(0, RoomSetupSpace.handReach, 0))
            }
        }
        let floor = active.floorHeight
        let pushing = lowest.filter { $0.y < floor && $0.y > floor - 1 && active.distance(to: $0.vec) < RoomSetupSpace.pushWithin }
        guard let deepest = pushing.map(\.y).min(), pushes.first?.room ?? active.room.id == active.room.id else {
            pushes = []
            return
        }
        pushes.append((active.room.id, deepest, now))
        guard let first = pushes.first, now - first.time >= RoomSetupSpace.pushHold else { return }
        pushes.removeAll { now - $0.time > RoomSetupSpace.pushHold }
        guard let shallowest = pushes.map(\.height).max(), shallowest < floor else { return }
        change(active.room.id) { $0.floor = shallowest - active.anchor.position.y }
    }

    /// Recent sub-floor depths for the active room used to debounce floor lowering.
    private var pushes: [(room: UUID, height: Float, time: TimeInterval)] = []
    private static let pushHold: TimeInterval = 0.15

    // MARK: Per-frame update

    private func everyFrame() {
        guard !stopped else { return }
        let now = CACurrentMediaTime()
        let step = Float(min(0.1, max(0, now - lastFrame)))
        lastFrame = now
        if let device = head.anchor(at: now), device.isTracked {
            let pose = HeadTracking.pose(device.originFromAnchorTransform)
            wearer = pose
            headHeight = headHeight.map { $0 + (pose.position.y - $0) * min(1, step / 0.7) } ?? pose.position.y
        }
        let all = rooms.anchors.placedRooms()
        let here = wearer.flatMap { PlacedRoom.choose(at: $0.position, among: all) }
        active = here ?? wearer.flatMap { wearer in all.min { $0.distance(to: wearer.position) < $1.distance(to: wearer.position) } }
        if controls.roomHere != here?.room.id { controls.roomHere = here?.room.id }

        let held = controllers.states(clackSwitching: false, head: nil)
        pushFloor(heldControllers: held, now: now)
        followControllers(held, now: now)
        // Split an edge once held for `holdToSplit` even if the hand remains completely stationary.
        for (pointer, press) in presses {
            if case .sideHeld = press.action, now - press.began >= RoomSetupSpace.holdToSplit { split(pointer, toward: nil) }
        }
        draw(rooms.anchors.placedRooms(), now: now)
    }

    private func draw(_ all: [PlacedRoom], now: TimeInterval) {
        for id in figures.keys where !all.contains(where: { $0.room.id == id }) {
            figures[id]?.remove()
            figures[id] = nil
        }
        for placed in all {
            let figure = figures[placed.room.id] ?? {
                let made = RoomFigure(parent: root)
                figures[placed.room.id] = made
                return made
            }()
            figure.show(placed, headHeight: headHeight ?? placed.floorHeight + 1.5, wearer: wearer, advanced: controls.advanced,
                        active: placed.room.id == active?.room.id)
        }
        // Keep the floor hit-target plane positioned just beneath the active room's floor.
        if let active = all.first(where: { $0.room.id == active?.room.id }), let wearer {
            catcher.isEnabled = true
            catcher.position = SIMD3(wearer.position.x, active.floorHeight - 0.012, wearer.position.z)
        } else {
            catcher.isEnabled = false
        }
        drawPaint(all)
        for (pointer, ray) in handRays where now - ray.time > 0.2 || presses[pointer] == nil { handRays[pointer] = nil }
        for (pointer, ray) in handRays { figure(for: pointer).show(from: ray.from, to: ray.to, brush: !controls.advanced) }
        for (pointer, figure) in pointers {
            if case .hand = pointer, handRays[pointer] == nil { figure.hide() }
        }
    }

    /// Updates the preview mesh for an in-progress painted boundary stroke.
    private func drawPaint(_ all: [PlacedRoom]) {
        var stroke: (room: UUID, points: [Point2])?
        for press in presses.values {
            if case .stroke(let room, let points) = press.action { stroke = (room, points) }
        }
        guard let stroke, let placed = all.first(where: { $0.room.id == stroke.room }) else {
            paint.isEnabled = false
            paintDrawn = 0
            return
        }
        paint.isEnabled = true
        paint.position = SIMD3(placed.anchor.position.x, placed.floorHeight + RoomLook.lift * 2, placed.anchor.position.z)
        paint.orientation = simd_quatf(angle: placed.anchor.yaw, axis: SIMD3(0, 1, 0))
        guard stroke.points.count != paintDrawn else { return }
        paintDrawn = stroke.points.count
        var mesh = FlatMesh()
        mesh.path(stroke.points, closed: false, width: RoomLook.brushRadius * 2)
        paint.model = mesh.resource().map { ModelComponent(mesh: $0, materials: [RoomLook.paint]) }
    }

    private func figure(for pointer: Pointer) -> PointerFigure {
        if let figure = pointers[pointer] { return figure }
        let figure = PointerFigure(parent: root)
        pointers[pointer] = figure
        return figure
    }

    // MARK: Controllers

    private func followControllers(_ held: [ControllerState?], now: TimeInterval) {
        controllersHeld = Set(Side.allCases.filter { held[$0.rawValue] != nil })
        for side in Side.allCases {
            let pointer = Pointer.controller(side)
            guard let state = held[side.rawValue] else {
                if triggerHeld[side] == true { end(pointer) }
                triggerHeld[side] = false
                triggerPinch[side] = nil
                grips[side] = nil
                pointers[pointer]?.hide()
                continue
            }
            let aim = state.aim ?? state.grip.pose
            let ray = Ray(origin: aim.position.simd, direction: simd_normalize(aim.forward.simd))
            let sample = Sample(ray: ray, device: state.grip.pose.position.simd)
            grips[side] = sample.device
            // Accept the trigger (read directly, or as the pinch visionOS makes of it) or the
            // grip squeeze, with hysteresis on release.
            let was = triggerHeld[side] ?? false
            let down = state.squeeze > 0.5 || state.trigger > (was ? 0.3 : 0.6) || triggerPinch[side] != nil
            triggerHeld[side] = down
            if down, !was { begin(pointer, sample, now: now) } else if down { drag(pointer, sample, now: now) } else if was { end(pointer) }
            // Extend the laser to the active floor hit point, or 2 m forward if not aiming at the floor.
            let floor = active.flatMap { ray.floor(at: $0.floorHeight) }
            figure(for: pointer).show(from: ray.origin, to: floor ?? ray.origin + ray.direction * 2,
                                      brush: floor == nil ? nil : !controls.advanced)
        }
    }

    // MARK: Hands

    /// Processes spatial pinch gesture events, using `toWorld` to convert local gesture coordinates into scene space.
    func pinched(_ events: SpatialEventCollection, toWorld: (Point3D) -> SIMD3<Float>) {
        guard !stopped else { return }
        let now = CACurrentMediaTime()
        for event in events {
            let pointer = Pointer.hand(event.id)
            // A pinch from a hand holding a tracked controller is that controller's trigger
            // (`followControllers` acts on it); one right at the hand is the grip being mistaken
            // for a pinch, and is ignored.
            if presses[pointer] == nil, let side = controller(making: event, toWorld: toWorld) {
                if event.phase == .active, event.kind != .directPinch {
                    if !triggerPinchNoted {
                        triggerPinchNoted = true
                        Log.note("room setup: taking a \(event.kind) from the \(side) controller as its trigger")
                    }
                    triggerPinch[side] = event.id
                } else if triggerPinch[side] == event.id {
                    triggerPinch[side] = nil
                }
                continue
            }
            guard event.kind == .indirectPinch || event.kind == .directPinch else { continue }
            guard event.phase == .active else {
                if presses[pointer] != nil { end(pointer) }
                continue
            }
            let location = toWorld(event.location3D)
            let direct = event.kind == .directPinch
            // Use the touch location for direct pinches and the hand's input-device pose for indirect pinches.
            let device = direct ? location : event.inputDevicePose.map { toWorld($0.pose3D.position) } ?? location
            var sample = Sample(ray: nil, device: device, direct: direct)
            if presses[pointer] != nil {
                drag(pointer, sample, now: now)
            } else if direct {
                // Cast straight down from just above a direct pinch to hit nearby controls or the floor.
                sample.ray = Ray(origin: location + SIMD3(0, RoomSetupSpace.directLift, 0), direction: SIMD3(0, -1, 0))
                begin(pointer, sample, now: now)
            } else if let gaze = event.selectionRay {
                let origin = toWorld(gaze.origin)
                let pointing = toWorld(gaze.origin + gaze.direction) - origin
                guard length(pointing) > 0 else { continue }
                sample.ray = Ray(origin: origin, direction: simd_normalize(pointing))
                begin(pointer, sample, now: now)
            }
        }
    }

    /// The tracked controller an event came from, if it came from a hand holding one. An event
    /// that does not say which hand goes to the controller nearest its input device, or to the
    /// only one held.
    private func controller(making event: SpatialEventCollection.Event, toWorld: (Point3D) -> SIMD3<Float>) -> Side? {
        if let made = triggerPinch.first(where: { $0.value == event.id }) { return made.key }
        switch event.chirality {
        case .left: return controllersHeld.contains(.left) ? .left : nil
        case .right: return controllersHeld.contains(.right) ? .right : nil
        default: break
        }
        guard controllersHeld.count > 1 else { return controllersHeld.first }
        guard let device = event.inputDevicePose.map({ toWorld($0.pose3D.position) }) else { return .right }
        return controllersHeld.min { length((grips[$0] ?? .zero) - device) < length((grips[$1] ?? .zero) - device) }
    }

    /// Computes the current pointer ray: controller rays come directly from `sample`, direct
    /// pinches cast straight down from the finger, and indirect floor pinches cast down onto
    /// the amplified floor cursor.
    private func ray(_ sample: Sample, _ press: Press) -> Ray? {
        if let ray = sample.ray { return ray }
        if sample.direct { return Ray(origin: sample.device + SIMD3(0, RoomSetupSpace.directLift, 0), direction: SIMD3(0, -1, 0)) }
        guard let start = press.start else { return nil }
        let moved = sample.device - press.deviceAtStart
        let point = start + SIMD3(moved.x, 0, moved.z) * RoomSetupSpace.handTravelGain
        return Ray(origin: point + SIMD3(0, 1, 0), direction: SIMD3(0, -1, 0))
    }

    // MARK: Pointer interaction

    private func begin(_ pointer: Pointer, _ sample: Sample, now: TimeInterval) {
        var press = Press(deviceAtStart: sample.device, began: now)
        defer { presses[pointer] = press }
        guard let ray = sample.ray else { return }
        /// Hit-test tolerance that scales slightly with ray distance to account for angular aiming error.
        func within(_ gap: Float, _ along: Float, _ reach: Float) -> Bool { gap < max(reach, along * 0.03) }

        for (id, figure) in figures where figure.buttonHit(by: ray.origin, ray.direction, near: sample.direct ? sample.device : nil, wearer: wearer) {
            resetFloor(id)
            return
        }
        // Pick whichever of the flag or center post the ray hits closest.
        var taken: (room: UUID, flag: Bool, at: SIMD3<Float>, along: Float)?
        for (id, figure) in figures {
            let flag = ray.approach(figure.flagMiddle, figure.flagMiddle)
            if within(flag.gap, flag.along, 0.1) || length(sample.device - figure.flagMiddle) < 0.12, flag.along < (taken?.along ?? .infinity) {
                taken = (id, true, figure.flagMiddle, flag.along)
            }
            let post = ray.approach(figure.base, figure.top)
            if within(post.gap, post.along, 0.06), post.along < (taken?.along ?? .infinity) - 0.05 {
                taken = (id, false, ray.origin + ray.direction * post.along, post.along)
            }
            // Also allow grabbing the post directly when a hand or controller is right next to it.
            let reached = max(figure.base.y, min(figure.top.y, sample.device.y))
            let beside = SIMD3(figure.base.x, reached, figure.base.z)
            if taken == nil, length(sample.device - beside) < 0.1 { taken = (id, false, beside, 0) }
        }
        if let taken, let figure = figures[taken.room], let room = rooms.store.room(taken.room) {
            press.gain = max(1, min(RoomSetupSpace.mostGain, length(taken.at - sample.device) / RoomSetupSpace.armsLength))
            press.action = taken.flag ? .flag(room: taken.room, targetAtStart: figure.flagTip)
                                      : .post(room: taken.room, centerAtStart: room.center)
            return
        }

        // Fall back to interacting with the active room's floor.
        guard let active, let hit = ray.floor(at: active.floorHeight) else { return }
        if sample.direct, length(hit - ray.origin) > RoomSetupSpace.directReach { return }
        if case .hand = pointer, !sample.direct, length(hit - sample.device) > 0.01 {
            press.start = hit
        }
        let id = active.room.id, at = active.anchor.local(hit.vec), boundary = active.room.boundary
        guard controls.advanced else {
            press.action = .stroke(room: id, points: [at])
            return
        }
        let reach = max(0.08, length(hit - ray.origin) * 0.035)
        if let corner = FloorShape.nearestCorner(of: boundary, to: at, within: reach) {
            if corner == 0, !active.room.closed, boundary.count >= 3 {
                // Selecting the first corner again closes an in-progress polygon.
                change(id) { $0.closed = true }
            } else {
                press.action = .corner(room: id, index: corner, offset: boundary[corner] - at)
            }
        } else if let side = FloorShape.nearestEdge(of: boundary, closed: active.room.closed, to: at, within: reach * 0.7) {
            let from = boundary[side.index], to = boundary[(side.index + 1) % boundary.count]
            press.action = .sideHeld(room: id, side: side.index, at: from + (to - from) * side.along)
        } else if !active.room.closed {
            // Append a new corner and drag it until release.
            change(id) { $0.boundary.append(at) }
            press.action = .corner(room: id, index: boundary.count, offset: Point2(0, 0))
        }
    }

    /// Inserts a new corner on a held boundary edge and transitions the press into dragging that corner.
    private func split(_ pointer: Pointer, toward point: Point2?) {
        guard let press = presses[pointer], case .sideHeld(let id, let side, let at) = press.action else { return }
        change(id) { room in
            guard side < room.boundary.count else { return }
            room.boundary.insert(at, at: side + 1)
        }
        presses[pointer]?.action = .corner(room: id, index: side + 1, offset: point.map { at - $0 } ?? Point2(0, 0))
    }

    private func drag(_ pointer: Pointer, _ sample: Sample, now: TimeInterval) {
        guard let press = presses[pointer] else { return }
        let moved = (sample.device - press.deviceAtStart) * press.gain
        let pointing = ray(sample, press)
        /// Intersects the pointer ray with `placed`'s floor and returns the hit in anchor coordinates.
        func onFloor(_ placed: PlacedRoom) -> Point2? {
            guard let pointing, let hit = pointing.floor(at: placed.floorHeight) else { return nil }
            if case .hand = pointer { handRays[pointer] = (sample.device, hit, now) }
            return placed.anchor.local(hit.vec)
        }
        switch press.action {
        case .nothing:
            break
        case .post(let id, let start):
            guard let placed = placed(id) else { return }
            let from = placed.anchor.world(start)
            change(id) { $0.center = placed.anchor.local(Vec3(from.x + moved.x, 0, from.z + moved.z)) }
        case .flag(let id, let start):
            guard let placed = placed(id) else { return }
            let center = placed.center
            let toward = SIMD2(start.x + moved.x - center.x, start.z + moved.z - center.z)
            guard length(toward) > 0.03 else { return }
            change(id) { $0.facing = atan2(-toward.x, -toward.y) - placed.anchor.yaw }
        case .corner(let id, let index, let offset):
            guard let placed = placed(id), let at = onFloor(placed) else { return }
            change(id) { room in
                if index < room.boundary.count { room.boundary[index] = at + offset }
            }
        case .sideHeld(let id, _, _):
            guard let placed = placed(id) else { return }
            let at = onFloor(placed)
            if now - press.began >= RoomSetupSpace.holdToSplit { split(pointer, toward: at) }
        case .stroke(let id, var points):
            guard let placed = placed(id), let at = onFloor(placed), let last = points.last else { return }
            guard (at - last).length >= RoomSetupSpace.strokeStep else { return }
            points.append(at)
            presses[pointer]?.action = .stroke(room: id, points: points)
        }
    }

    private func end(_ pointer: Pointer) {
        guard let press = presses.removeValue(forKey: pointer) else { return }
        handRays[pointer] = nil
        guard case .stroke(let id, let points) = press.action, let room = rooms.store.room(id) else { return }
        if let outline = room.outline {
            // Expand the existing boundary to include any exterior area enclosed by the stroke.
            guard let grown = FloorShape.expanded(outline, by: points, snap: RoomSetupSpace.snapToBoundary) else { return }
            change(id) { $0.boundary = FloorShape.tidied(grown) }
            Log.note("room setup: expanded boundary of \(id.uuidString)")
        } else if let loop = FloorShape.loop(in: points, joinWithin: RoomLook.brushRadius * 2) {
            // When no boundary exists yet, create one if the stroke forms a closed loop.
            change(id) { room in
                room.boundary = FloorShape.tidied(loop)
                room.closed = true
            }
            Log.note("room setup: drew boundary of \(id.uuidString)")
        }
    }
}

private extension Vec3 {
    var simd: SIMD3<Float> { SIMD3(x, y, z) }
}

private extension SIMD3 where Scalar == Float {
    var vec: Vec3 { Vec3(x, y, z) }
}

/// RealityKit entities representing a single room in Room Setup.
@MainActor
private final class RoomFigure {
    /// Positioned at the room center on the floor (unrotated): holds the post, label, and reset button.
    private let stand = Entity()
    /// Positioned at the room center and rotated to `room.facing`: holds the floor grid and flag.
    private let turning = Entity()
    /// Positioned and rotated to the room's world anchor on the floor: holds the boundary polygon and corners.
    private let outline = Entity()
    private let post = ModelEntity(mesh: .generateCylinder(height: 1, radius: RoomLook.postRadius), materials: [RoomLook.post])
    private let flag = ModelEntity()
    private let label = Entity()
    private let button = Entity()
    private let edges = ModelEntity()
    private var corners: [ModelEntity] = []
    private var drawn: (boundary: [Point2], closed: Bool, advanced: Bool)?
    private var rings: ModelEntity?
    private var shownActive: Bool?

    /// World-space hit-test positions updated on each call to `show`.
    private(set) var base = SIMD3<Float>(repeating: 0), top = SIMD3<Float>(repeating: 0)
    private(set) var flagMiddle = SIMD3<Float>(repeating: 0), flagTip = SIMD3<Float>(repeating: 0)
    private var buttonMiddle = SIMD3<Float>(repeating: 0)

    private static let buttonSize = SIMD2<Float>(0.36, 0.08)
    /// Vertical offset of the flag below the top of the center post.
    private static let flagDrop: Float = 0.02

    init(parent: Entity) {
        post.components.set(InputTargetComponent())
        post.components.set(CollisionComponent(shapes: [.generateBox(width: 0.1, height: 1, depth: 0.1)]))
        stand.addChild(post)

        label.addChild(RoomLook.words("room center", height: 0.05))
        label.components.set(BillboardComponent())
        stand.addChild(label)

        let size = RoomFigure.buttonSize
        button.addChild(ModelEntity(mesh: .generatePlane(width: size.x, height: size.y, cornerRadius: size.y / 2),
                                    materials: [RoomLook.plate]))
        let words = RoomLook.words("Reset Floor Height", height: 0.03)
        words.position.z += 0.003
        button.addChild(words)
        // Rotate the button manually in `show` instead of using `BillboardComponent` so its collision shape rotates too.
        button.components.set(InputTargetComponent())
        button.components.set(CollisionComponent(shapes: [.generateBox(width: size.x, height: size.y, depth: 0.02)]))
        stand.addChild(button)

        if let web = RoomLook.webMesh {
            let rings = ModelEntity(mesh: web, materials: [RoomLook.web])
            rings.position.y = RoomLook.lift
            turning.addChild(rings)
            self.rings = rings
        }
        if let mesh = RoomLook.flagMesh { flag.model = ModelComponent(mesh: mesh, materials: [RoomLook.flag]) }
        flag.components.set(InputTargetComponent())
        flag.components.set(CollisionComponent(shapes: [.generateBox(width: 0.06, height: 0.14, depth: 0.22)
            .offsetBy(translation: RoomLook.flagMiddle)]))
        turning.addChild(flag)

        outline.addChild(edges)
        for entity in [stand, turning, outline] { parent.addChild(entity) }
    }

    func remove() {
        for entity in [stand, turning, outline] { entity.removeFromParent() }
    }

    func show(_ placed: PlacedRoom, headHeight: Float, wearer: Pose?, advanced: Bool, active: Bool) {
        // Highlight the active room in color and render inactive rooms in gray.
        if shownActive != active {
            shownActive = active
            drawn = nil
            post.model?.materials = [active ? RoomLook.post : RoomLook.idle]
            flag.model?.materials = [active ? RoomLook.flag : RoomLook.idle]
            rings?.model?.materials = [active ? RoomLook.web : RoomLook.idle]
        }
        let center = placed.center, frame = placed.frame()
        base = SIMD3(center.x, center.y, center.z)
        // Size the post to two-thirds of the headset's height above this room's floor.
        let height = max(0.3, (headHeight - center.y) * 2 / 3)
        top = base + SIMD3(0, height, 0)
        let turn = simd_quatf(angle: frame.yaw, axis: SIMD3(0, 1, 0))
        stand.position = base
        turning.position = base
        turning.orientation = turn
        post.scale = SIMD3(1, height, 1)
        post.position = SIMD3(0, height / 2, 0)
        label.position = SIMD3(0, height + 0.1, 0)
        flag.position = SIMD3(0, height - RoomFigure.flagDrop, 0)
        flagMiddle = base + SIMD3(0, height - RoomFigure.flagDrop, 0) + turn.act(RoomLook.flagMiddle)
        flagTip = base + SIMD3(0, height - RoomFigure.flagDrop, 0) + turn.act(RoomLook.flagTip)

        // Place the reset button to the right of the post from the user's viewpoint.
        var right = SIMD3<Float>(1, 0, 0)
        if let wearer {
            let away = SIMD3(center.x - wearer.position.x, 0, center.z - wearer.position.z)
            if length(away) > 0.05 { right = simd_normalize(cross(away, SIMD3(0, 1, 0))) }
        }
        button.position = right * 0.3 + SIMD3(0, height * 0.75, 0)
        buttonMiddle = base + button.position
        if let wearer {
            let toward = SIMD3(wearer.position.x, wearer.position.y, wearer.position.z) - buttonMiddle
            if length(toward) > 0.05 {
                let normal = simd_normalize(toward)
                var across = cross(SIMD3<Float>(0, 1, 0), normal)
                across = length(across) > 0.01 ? simd_normalize(across) : SIMD3(1, 0, 0)
                button.orientation = simd_quatf(simd_float3x3(columns: (across, cross(normal, across), normal)))
            }
        }

        outline.position = SIMD3(placed.anchor.position.x, placed.floorHeight + RoomLook.lift, placed.anchor.position.z)
        outline.orientation = simd_quatf(angle: placed.anchor.yaw, axis: SIMD3(0, 1, 0))
        let room = placed.room
        if let drawn, drawn.boundary == room.boundary, drawn.closed == room.closed, drawn.advanced == advanced { return }
        drawn = (room.boundary, room.closed, advanced)
        var mesh = FlatMesh()
        mesh.path(room.boundary, closed: room.closed, width: RoomLook.boundaryLine)
        if let resource = mesh.resource() {
            edges.model = ModelComponent(mesh: resource, materials: [active ? RoomLook.boundary : RoomLook.idle])
        } else {
            edges.model = nil
        }
        // Show draggable corner spheres in Advanced mode or while placing an unclosed polygon.
        let shown = advanced || !room.closed ? room.boundary : []
        while corners.count > shown.count { corners.removeLast().removeFromParent() }
        while corners.count < shown.count {
            let corner = ModelEntity(mesh: .generateSphere(radius: RoomLook.cornerRadius), materials: [RoomLook.corner])
            outline.addChild(corner)
            corners.append(corner)
        }
        for (index, point) in shown.enumerated() {
            let first = index == 0 && !room.closed
            corners[index].position = SIMD3(point.x, 0, point.z)
            corners[index].scale = SIMD3(repeating: first ? 1.5 : 1)
            corners[index].model?.materials = [!active ? RoomLook.idle : first ? RoomLook.firstCorner : RoomLook.corner]
        }
    }

    /// Returns true if the pointer ray intersects the reset button or a direct pinch is within reach of its face.
    func buttonHit(by origin: SIMD3<Float>, _ direction: SIMD3<Float>, near device: SIMD3<Float>?, wearer: Pose?) -> Bool {
        guard let wearer else { return false }
        let facing = SIMD3(wearer.position.x, wearer.position.y, wearer.position.z) - buttonMiddle
        guard length(facing) > 0.01 else { return false }
        let normal = simd_normalize(facing)
        var across = cross(SIMD3<Float>(0, 1, 0), normal)
        guard length(across) > 0.01 else { return false }
        across = simd_normalize(across)
        let up = cross(normal, across), slack: Float = 0.02
        func onPlate(_ off: SIMD3<Float>) -> Bool {
            abs(dot(off, across)) < RoomFigure.buttonSize.x / 2 + slack && abs(dot(off, up)) < RoomFigure.buttonSize.y / 2 + slack
        }
        // Direct pinch within a few centimeters of the button face.
        if let device { return onPlate(device - buttonMiddle) && abs(dot(device - buttonMiddle, normal)) < 0.06 }
        let closing = dot(direction, normal)
        guard abs(closing) > 1e-4 else { return false }
        let along = dot(buttonMiddle - origin, normal) / closing
        return along > 0 && onPlate(origin + direction * along - buttonMiddle)
    }
}

/// Renders a pointer's laser ray and floor cursor ring.
@MainActor
private final class PointerFigure {
    private let beam = ModelEntity(mesh: .generateCylinder(height: 1, radius: 0.002), materials: [RoomLook.ray])
    private let landing = ModelEntity()

    init(parent: Entity) {
        if let mesh = RoomLook.brushMesh { landing.model = ModelComponent(mesh: mesh, materials: [RoomLook.ray]) }
        parent.addChild(beam)
        parent.addChild(landing)
        hide()
    }

    func hide() {
        beam.isEnabled = false
        landing.isEnabled = false
    }

    /// Updates the ray from `from` to `to`. `brush` selects full brush radius (`true`),
    /// small corner cursor (`false`), or hidden (`nil`).
    func show(from: SIMD3<Float>, to: SIMD3<Float>, brush: Bool?) {
        let span = to - from, reach = length(span)
        guard reach > 0.01 else { return hide() }
        beam.isEnabled = true
        beam.position = (from + to) / 2
        beam.orientation = simd_quatf(from: SIMD3(0, 1, 0), to: span / reach)
        beam.scale = SIMD3(1, reach, 1)
        landing.isEnabled = brush != nil
        landing.position = to + SIMD3(0, RoomLook.lift * 3, 0)
        landing.scale = SIMD3(repeating: brush == true ? 1 : 0.4)
    }
}

/// SwiftUI view hosting the Room Setup `RealityView`.
public struct RoomSetupView: View {
    let space: RoomSetupSpace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    public init(space: RoomSetupSpace) { self.space = space }

    public var body: some View {
        RealityView { content in
            space.closeControls = { dismissWindow(id: RoomSetupControls.windowID) }
            space.closeSpace = { Task { await dismissImmersiveSpace() } }
            space.setup(&content)
        }
        .gesture(SpatialEventGesture(coordinateSpace: .local).targetedToAnyEntity()
            .onChanged { value in space.pinched(value.gestureValue) { value.convert($0, from: .local, to: .scene) } }
            .onEnded { value in space.pinched(value.gestureValue) { value.convert($0, from: .local, to: .scene) } })
        // Clean up if the system dismisses the immersive space externally (e.g. Digital Crown).
        .onChange(of: scenePhase) {
            if scenePhase == .background { space.stop() }
        }
        .onDisappear { space.stop() }
        // Rooms are tied to world anchors rather than the tracking origin, so only re-measure anchors on recenter.
        .onWorldRecenter { phase in
            if phase == .ended { space.worldRecentered() }
        }
    }
}

/// Compact borderless toolbar window for Room Setup.
public struct RoomSetupControlsView: View {
    @ObservedObject var controls: RoomSetupControls
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    public init(controls: RoomSetupControls) { self.controls = controls }

    public var body: some View {
        HStack(spacing: 24) {
            Toggle("Basic/Advanced", isOn: $controls.advanced)
                .toggleStyle(.switch)
                .fixedSize()
            Button("Add Room") { controls.add?() }
                .fixedSize()
            if controls.roomHere != nil {
                Button("Remove Room") { controls.remove?() }
                    .fixedSize()
            }
            Button("Done") {
                Task { await dismissImmersiveSpace() }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        // Size tightly to the HStack so the window resizes smoothly when "Remove Room" appears or disappears.
        .fixedSize()
        // Dismiss immediately if reopened by window restoration while Room Setup is inactive.
        .onAppear {
            if !controls.open { dismissWindow(id: RoomSetupControls.windowID) }
        }
        .onChange(of: controls.open) {
            if !controls.open { dismissWindow(id: RoomSetupControls.windowID) }
        }
    }
}
#endif
