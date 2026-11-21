// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import Foundation
import QuartzCore
import VRLinkAppleSession
import VRLinkCore
import VRLinkVisionTracking

/// Selects the active room for a streaming session and updates `Connection.playSpace`
/// so outgoing poses and the SteamVR boundary stay aligned with that room.
///
/// Room selection runs once per session after the streaming immersive space opens and
/// ARKit begins tracking the headset. A room matches if the user is inside its boundary
/// or within 2.5 m of its center; if multiple rooms match, the room with the closest
/// center is chosen. When no room matches, streaming uses the raw tracking origin with
/// no boundary.
///
/// Recentering (either from a SteamVR host request or by holding the Digital Crown)
/// moves the play-space origin beneath the user and aligns forward with their heading
/// for the rest of the session, while keeping the room boundary fixed in physical space.
///
/// All state is accessed on the main thread except `hostAskedToRecenter()`.
public final class RoomTracker {
    public let store: RoomStore
    public let anchors: RoomAnchors
    public let planes = FloorPlanes()
    private let connection: Connection
    private let head: HeadTracking

    private enum Choice {
        /// Waiting to choose a room; `since` records when head tracking first became valid this session.
        case undecided(since: TimeInterval?)
        case room(UUID)
        case noRoom
    }
    private var choice = Choice.noRoom
    /// Temporary session-only recenter offset within the active room.
    private var recentering: Recentering?
    /// Temporary session-only recenter frame in tracking space when playing without a room.
    private var originWithoutRoom: FloorFrame?
    /// Timestamp of a Digital Crown recenter while waiting for `RoomAnchors` to re-measure against the new origin.
    private var crownRecentered: TimeInterval?
    private var wasImmersed = false
    private let lock = NSLock()
    private var hostAsked = false
    private var timer: Timer?

    /// Minimum wait (once all saved rooms are reported) and maximum timeout in seconds before finalizing room selection.
    private static let shortestWait: TimeInterval = 0.5, longestWait: TimeInterval = 4

    public init(connection: Connection, head: HeadTracking) {
        self.connection = connection
        self.head = head
        store = RoomStore()
        anchors = RoomAnchors(head: head, store: store)
        anchors.start()
        connection.onRecenterRequested = { [weak self] in self?.hostAskedToRecenter() }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Resets room selection and recenter state at the start of a new streaming session.
    public func sessionBegins() {
        choice = .undecided(since: nil)
        recentering = nil
        originWithoutRoom = nil
        crownRecentered = nil
        connection.playSpace = .trackingSpace
    }

    /// Handles a Digital Crown world recenter.
    public func worldRecentered() {
        // Re-measure world anchors against the new tracking origin in any immersive space, including Room Setup.
        anchors.originMoved()
        guard connection.active else { return }
        crownRecentered = CACurrentMediaTime()
    }

    /// Records a recenter request from the SteamVR host. Safe to call from any thread.
    public func hostAskedToRecenter() {
        lock.lock()
        hostAsked = true
        lock.unlock()
    }

    private func tick() {
        lock.lock()
        let asked = hostAsked
        hostAsked = false
        lock.unlock()
        // Entering an immersive space resets the tracking origin, so re-measure world anchors.
        if connection.immersed != wasImmersed {
            wasImmersed = connection.immersed
            if wasImmersed { anchors.originMoved() }
        }
        // Only update `Connection.playSpace` during an active stream with valid head tracking.
        let now = CACurrentMediaTime()
        guard connection.active, let device = head.anchor(at: now), device.isTracked else { return }
        let wearer = HeadTracking.pose(device.originFromAnchorTransform)

        if case .undecided(let since) = choice {
            let began = since ?? now
            let waited = now - began
            // Wait until ARKit has reported on every saved room and measured the anchor offset
            // (up to `longestWait`) so a closer room is not missed.
            let heardOfAll = store.rooms.allSatisfy { anchors.hasHeard(of: $0.id) }
            let ready = (anchors.settled && heardOfAll && waited >= RoomTracker.shortestWait) || waited >= RoomTracker.longestWait
            if ready, let chosen = PlacedRoom.choose(at: wearer.position, among: anchors.placedRooms()) {
                choice = .room(chosen.room.id)
                Log.note(String(format: "rooms: selected room %@ (%.1f m from center, %@)",
                                chosen.room.id.uuidString, chosen.distance(to: wearer.position),
                                chosen.room.outline == nil ? "no boundary" : "with boundary"))
            } else if ready {
                choice = .noRoom
                Log.note("rooms: no matching room among \(store.rooms.count) saved; using tracking origin")
            } else {
                choice = .undecided(since: began)
            }
        }

        var space = PlaySpace.trackingSpace
        switch choice {
        case .undecided:
            break
        case .noRoom:
            if asked {
                originWithoutRoom = FloorFrame(position: Vec3(wearer.position.x, 0, wearer.position.z),
                                               yaw: FloorFrame.heading(of: wearer))
                Log.note("rooms: applied host recenter relative to tracking origin")
            }
            // Holding the Digital Crown already shifted the tracking origin, so clear any manual host recenter.
            if crownRecentered != nil {
                crownRecentered = nil
                originWithoutRoom = nil
            }
            if let originWithoutRoom { space = PlaySpace(originWithoutRoom) }
        case .room(let id):
            guard let room = store.room(id), let anchor = anchors.frame(of: id) else {
                // Anchor temporarily untracked; keep the last `playSpace` and defer any host recenter until tracking resumes.
                if asked { hostAskedToRecenter() }
                return
            }
            let placed = PlacedRoom(room: room, anchor: anchor)
            if asked {
                recentering = placed.recentering(to: wearer)
                Log.note("rooms: applied host recenter in active room")
            }
            // Once `RoomAnchors` has re-measured the room anchor against the post-crown tracking
            // origin, align the play space with the user.
            if let pressed = crownRecentered, (anchors.settledAt ?? 0) > pressed {
                crownRecentered = nil
                recentering = placed.recentering(to: wearer)
                Log.note("rooms: applied Digital Crown recenter in active room")
            }
            space = PlaySpace(placed, recentering: recentering)
        }
        connection.playSpace = space
    }
}
#endif
