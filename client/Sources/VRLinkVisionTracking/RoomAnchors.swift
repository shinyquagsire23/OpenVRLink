// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import ARKit
import QuartzCore
import VRLinkCore
import simd

/// Manages ARKit `WorldAnchor` instances that keep saved rooms fixed in physical space.
///
/// Each room uses its `WorldAnchor` UUID as `Room.id`. World anchors persist across
/// tracking-origin resets, app launches, and headset reboots.
///
/// In headset testing (2026-11-20), ARKit's reported `WorldAnchor` transforms did not stay
/// aligned with the coordinate origin returned by `queryDeviceAnchor` for head tracking:
/// rooms shifted when opening immersive spaces or recentering with the Digital Crown. To
/// compensate, `RoomAnchors` places a reference marker `WorldAnchor` at the current head
/// position, where its true tracking-space transform is known. When polling `allAnchors`,
/// `RoomAnchors` computes the transform from the marker's reported pose to its true pose
/// and applies that correction to every anchor in the same snapshot. Whenever the tracking
/// origin may have moved (tracking startup, a >0.5 m head-pose jump, or a recenter), a new
/// marker is placed and anchor frames return `nil` until the marker resolves.
///
/// Because ARKit world tracking only runs while an immersive space is open, anchors can
/// only be queried, added, or removed inside one. Any reported anchor whose UUID is not in
/// `RoomStore` (including deleted rooms and leftover markers) is removed automatically.
public final class RoomAnchors {
    private let worldTracking: WorldTrackingProvider
    private let store: RoomStore
    private let lock = NSLock()
    private var known: [UUID: Known] = [:]
    /// Anchors currently being added before their rooms are written to `store`.
    private var arriving: Set<UUID> = []
    private var following: Task<Void, Never>?

    /// Active reference marker UUID and its known tracking-space transform when placed.
    private var marker: (id: UUID, truth: simd_float4x4)?
    /// Marker UUIDs currently active, being added, or being removed so orphan cleanup ignores them.
    private var markers: Set<UUID> = []
    /// Removed marker UUIDs and their removal timestamps. ARKit can continue reporting a removed
    /// marker briefly, so we keep it in `markers` until it disappears from `allAnchors` or `stall`
    /// seconds have elapsed so orphan cleanup doesn't try to remove it again.
    private var leaving: [UUID: TimeInterval] = [:]
    /// Transform from ARKit's reported anchor space into head-tracking space; `nil` while awaiting a new marker.
    private var correction: simd_float4x4?
    /// Timestamp (`CACurrentMediaTime`) when `correction` was first established after an origin change.
    private var corrected: TimeInterval = 0
    private var wantsMarker = true
    /// Start timestamp of an in-flight `placeMarker` call, if any.
    private var placingMarker: TimeInterval?
    /// Incremented whenever the tracking origin may have moved so in-flight markers from an older origin are discarded.
    private var epoch = 0
    /// Start timestamp and sequence number of the current `allAnchors` poll, if one is running.
    private var reading: (began: TimeInterval, turn: Int)?
    private var turn = 0
    /// Recently requested orphan removals and when each was issued.
    private var removing: [UUID: TimeInterval] = [:]
    /// Tracks how long anchor correction has been unavailable and when we last logged a warning.
    private var unsettled: (since: TimeInterval, said: TimeInterval)?
    /// Last logged tracking status per room UUID to avoid repeating unchanged log lines.
    private var said: [UUID: String] = [:]
    /// Timeout in seconds before abandoning a stalled ARKit call and retrying.
    private static let stall: TimeInterval = 3
    /// Marker UUID that produced the current `correction`.
    private var measured: UUID?
    private var markerPlaced: TimeInterval = 0
    /// Interval in seconds between periodic marker refreshes in case the tracking origin shifts silently,
    /// keeping the previous correction active until the new marker resolves.
    private static let refresh: TimeInterval = 5
    private var lastDevice: (position: SIMD3<Float>, tracked: Bool) = (SIMD3(repeating: 0), false)

    private struct Known {
        var frame: FloorFrame
        var tracked: Bool
        /// Timestamp (`CACurrentMediaTime`) when ARKit last reported this anchor.
        var reported: TimeInterval
    }

    /// Polling interval in seconds for `allAnchors`.
    private static let interval = 0.2
    /// Head-position delta in meters between polls that triggers a fresh marker measurement.
    private static let jump: Float = 0.5

    public init(head: HeadTracking, store: RoomStore) {
        worldTracking = head.worldTracking
        self.store = store
    }

    /// Starts polling ARKit world anchors. Safe to call multiple times.
    public func start() {
        guard following == nil else { return }
        following = Task { [weak self] in
            while !Task.isCancelled {
                self?.readUnlessReading()
                try? await Task.sleep(for: .seconds(RoomAnchors.interval))
            }
        }
    }

    /// Invalidates the current anchor correction when the tracking origin may have moved.
    public func originMoved() {
        lock.lock()
        forgetCorrection()
        lock.unlock()
    }

    /// Must be called with `lock` held.
    private func forgetCorrection() {
        wantsMarker = true
        correction = nil
        epoch += 1
    }

    /// Starts an `allAnchors` poll unless one is already running within `stall` seconds,
    /// preventing a hung ARKit call from stalling future polls.
    private func readUnlessReading() {
        let now = CACurrentMediaTime()
        lock.lock()
        if let reading {
            guard now - reading.began > RoomAnchors.stall else {
                lock.unlock()
                return
            }
            Log.note("rooms: ARKit allAnchors timed out after \(Int(RoomAnchors.stall)) s; retrying")
        }
        turn += 1
        let mine = turn
        reading = (now, mine)
        lock.unlock()
        Task { [weak self] in
            await self?.read()
            guard let self else { return }
            self.lock.lock()
            if self.reading?.turn == mine { self.reading = nil }
            self.lock.unlock()
        }
    }

    /// Whether anchor transforms have been calibrated since the last tracking-origin change.
    public var settled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return correction != nil
    }

    /// Timestamp (`CACurrentMediaTime`) when anchor transforms were calibrated after the last origin change, or `nil` while pending.
    public var settledAt: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return correction == nil ? nil : corrected
    }

    private func read() async {
        guard worldTracking.state == .running else { return }
        let now = CACurrentMediaTime()
        let device = worldTracking.queryDeviceAnchor(atTimestamp: now)
        let tracked = device?.isTracked ?? false
        let position = device.map { simd_make_float3($0.originFromAnchorTransform.columns.3) } ?? SIMD3(repeating: 0)
        lock.lock()
        // Re-measure anchors when head tracking starts in an immersive space or jumps abruptly.
        if tracked, !lastDevice.tracked || simd_distance(position, lastDevice.position) > RoomAnchors.jump {
            forgetCorrection()
        }
        lastDevice = (position, tracked)
        if now - markerPlaced > RoomAnchors.refresh { wantsMarker = true }
        if let began = placingMarker, now - began > RoomAnchors.stall {
            Log.note("rooms: ARKit addAnchor for marker timed out after \(Int(RoomAnchors.stall)) s; retrying")
            placingMarker = nil
            wantsMarker = true
        }
        let place = tracked && wantsMarker && placingMarker == nil
        if place {
            placingMarker = now
            wantsMarker = false
        }
        let placedIn = epoch
        lock.unlock()
        guard tracked else { return }
        if place, let device {
            let position = device.originFromAnchorTransform.columns.3
            Task { [weak self] in await self?.placeMarker(at: position, began: now, epoch: placedIn) }
        }

        guard let all = await worldTracking.allAnchors else { return }
        var orphans: [UUID] = []
        lock.lock()
        if let marker, measured != marker.id, let reported = all.first(where: { $0.id == marker.id }), reported.isTracked {
            let found = marker.truth * reported.originFromAnchorTransform.inverse
            // Log when the initial correction is established or shifts noticeably.
            let change = correction.map { simd_distance($0.columns.3, found.columns.3) } ?? .infinity
            if change > 0.03 {
                let shift = found.columns.3
                Log.note(String(format: "rooms: anchor transforms offset from tracking origin by (%.2f, %.2f, %.2f) m and %.0f deg",
                                shift.x, shift.y, shift.z, FloorFrame(pose: HeadTracking.pose(found)).yaw * 180 / .pi))
            }
            if correction == nil { corrected = CACurrentMediaTime() }
            correction = found
            measured = marker.id
        }
        // Log prolonged delays waiting for the marker so missing rooms are easy to diagnose.
        if correction != nil {
            unsettled = nil
        } else if unsettled == nil {
            unsettled = (now, now)
        } else if let waiting = unsettled, now - waiting.said > RoomAnchors.stall {
            unsettled?.said = now
            let state = marker.map { marker in
                all.first { $0.id == marker.id }.map { $0.isTracked ? "reported" : "reported but not tracked" } ?? "not reported yet"
            } ?? "not placed yet"
            Log.note(String(format: "rooms: waiting %.0f s for anchor marker (%@, %d anchor(s) reported)",
                            now - waiting.since, state, all.count))
        }
        if store.readable {
            for room in store.rooms {
                let state = all.first { $0.id == room.id }.map { $0.isTracked ? "tracked" : "reported but not tracked" } ?? "not reported"
                if said[room.id] != state {
                    said[room.id] = state
                    Log.note("rooms: room \(room.id) anchor is \(state)")
                }
            }
        }
        if let correction {
            for anchor in all where !markers.contains(anchor.id) {
                let frame = FloorFrame(pose: HeadTracking.pose(correction * anchor.originFromAnchorTransform))
                known[anchor.id] = Known(frame: frame, tracked: anchor.isTracked, reported: now)
            }
            let listed = Set(all.map(\.id))
            for id in known.keys where !listed.contains(id) && !arriving.contains(id) { known[id] = nil }
        }
        // Stop tracking removed markers once ARKit drops them from `allAnchors` or `stall` seconds pass.
        let stillListed = Set(all.map(\.id))
        for (id, since) in leaving where !stillListed.contains(id) || now - since > RoomAnchors.stall {
            leaving[id] = nil
            markers.remove(id)
        }
        // Remove anchors belonging to deleted rooms or stale markers from previous runs.
        if store.readable {
            let rooms = Set(store.rooms.map(\.id))
            orphans = all.map(\.id).filter {
                !rooms.contains($0) && !arriving.contains($0) && !markers.contains($0) && now - (removing[$0] ?? 0) > RoomAnchors.stall
            }
            removing = removing.filter { now - $0.value <= RoomAnchors.stall }
            for id in orphans { removing[id] = now }
        }
        lock.unlock()
        for id in orphans {
            Log.note("rooms: removing unused world anchor \(id)")
            Task { [worldTracking] in try? await worldTracking.removeAnchor(forID: id) }
        }
    }

    /// Places a new reference marker at `position` and removes the previous marker.
    private func placeMarker(at position: SIMD4<Float>, began: TimeInterval, epoch placedIn: Int) async {
        var truth = matrix_identity_float4x4
        truth.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        let anchor = WorldAnchor(originFromAnchorTransform: truth)
        lock.lock()
        let old = marker?.id
        markers.insert(anchor.id)
        lock.unlock()
        var placed = true
        do {
            try await worldTracking.addAnchor(anchor)
        } catch {
            placed = false
            Log.note("rooms: failed to add marker anchor: \(error)")
        }
        lock.lock()
        if placingMarker == began { placingMarker = nil }
        // Discard the marker if the tracking origin moved while `addAnchor` was in flight.
        let stale = placed && epoch != placedIn
        if placed, !stale {
            marker = (anchor.id, truth)
            markerPlaced = CACurrentMediaTime()
        } else {
            // Retry on the next poll.
            wantsMarker = true
        }
        // Only remove `old` if another task has not already replaced it.
        let gone = stale ? anchor.id : (placed && old != marker?.id ? old : nil)
        lock.unlock()
        if !placed {
            lock.lock()
            markers.remove(anchor.id)
            lock.unlock()
        }
        if let gone {
            try? await worldTracking.removeAnchor(forID: gone)
            lock.lock()
            leaving[gone] = CACurrentMediaTime()
            lock.unlock()
        }
    }

    /// Returns the current tracking-space frame of room anchor `id`, or `nil` if ARKit is
    /// not tracking it or the marker correction is still pending.
    public func frame(of id: UUID) -> FloorFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard correction != nil || arriving.contains(id), let anchor = known[id], anchor.tracked else { return nil }
        return anchor.frame
    }

    /// Returns true if ARKit has reported anchor `id` since app launch, whether currently tracked or not.
    public func hasHeard(of id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return known[id] != nil
    }

    /// Returns all saved rooms whose world anchors are currently tracked.
    public func placedRooms() -> [PlacedRoom] {
        store.rooms.compactMap { room in frame(of: room.id).map { PlacedRoom(room: room, anchor: $0) } }
    }

    /// Creates a world anchor at `position` (level, facing `-z` in tracking space) and saves the new room.
    public func addRoom(at position: Vec3, _ prepare: (inout Room) -> Void = { _ in }) async -> Room? {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        let anchor = WorldAnchor(originFromAnchorTransform: transform)
        var room = Room(id: anchor.id)
        prepare(&room)
        lock.lock()
        arriving.insert(anchor.id)
        // Populate `known` immediately so the room is usable before the next `allAnchors` poll.
        let now = CACurrentMediaTime()
        known[anchor.id] = Known(frame: FloorFrame(position: position, yaw: 0), tracked: true, reported: now)
        lock.unlock()
        defer {
            lock.lock()
            arriving.remove(anchor.id)
            lock.unlock()
        }
        do {
            try await worldTracking.addAnchor(anchor)
        } catch {
            Log.note("rooms: failed to add world anchor: \(error)")
            lock.lock()
            known[anchor.id] = nil
            lock.unlock()
            return nil
        }
        // Save the room before clearing `arriving` so the poll loop never mistakes it for an orphan.
        store.put(room)
        return room
    }

    public func removeRoom(_ id: UUID) async {
        store.remove(id)
        lock.lock()
        known[id] = nil
        lock.unlock()
        do {
            try await worldTracking.removeAnchor(forID: id)
        } catch {
            // If world tracking is inactive, orphan cleanup will remove the anchor next time an immersive space opens.
            Log.note("rooms: failed to remove world anchor: \(error)")
        }
    }

    /// Deletes all saved rooms and removes all ARKit world anchors created by the app.
    public func removeEverything() async {
        store.removeAll()
        lock.lock()
        known = [:]
        // Reset marker state since `removeAllAnchors` removes the marker too.
        marker = nil
        measured = nil
        markers = []
        forgetCorrection()
        lock.unlock()
        do {
            try await worldTracking.removeAllAnchors()
        } catch {
            Log.note("rooms: failed to remove all world anchors: \(error)")
        }
    }
}

/// Tracks horizontal floor planes via ARKit `PlaneDetectionProvider` to initialize new room
/// floor heights. Prompts for world-sensing permission on first run.
public final class FloorPlanes {
    public init() {}

    /// Recreated on each `start()` because a stopped `ARKitSession` / provider cannot be restarted.
    private var session: ARKitSession?
    private let lock = NSLock()
    private var floors: [UUID: PlaneAnchor] = [:]
    private var following: Task<Void, Never>?

    public func start() {
        guard PlaneDetectionProvider.isSupported, following == nil else { return }
        let session = ARKitSession(), provider = PlaneDetectionProvider(alignments: [.horizontal])
        self.session = session
        following = Task { [weak self] in
            do {
                try await session.run([provider])
            } catch {
                Log.note("rooms: plane detection unavailable, defaulting floor height to tracking origin: \(error)")
                return
            }
            for await update in provider.anchorUpdates {
                guard let self else { return }
                self.lock.lock()
                let isFloor = update.event != .removed && update.anchor.classification == .floor
                self.floors[update.anchor.id] = isFloor ? update.anchor : nil
                self.lock.unlock()
            }
        }
    }

    public func stop() {
        following?.cancel()
        following = nil
        session?.stop()
        session = nil
        lock.lock()
        floors = [:]
        lock.unlock()
    }

    /// Returns the floor `y` coordinate beneath `point`, preferring the highest floor plane
    /// whose extent contains `point` and falling back to the horizontally closest floor plane.
    public func height(below point: Vec3) -> Float? {
        lock.lock()
        let planes = Array(floors.values)
        lock.unlock()
        var under: Float?, nearest: (height: Float, distance: Float)?
        for plane in planes {
            let extent = plane.geometry.extent
            let originFromExtent = plane.originFromAnchorTransform * extent.anchorFromExtentTransform
            let height = originFromExtent.columns.3.y
            guard height < point.y - 0.3 else { continue }
            // Plane extents span `width` along local x and `height` along whichever remaining local axis is horizontal.
            let local = originFromExtent.inverse * SIMD4(point.x, height, point.z, 1)
            let along = abs(originFromExtent.columns.1.y) > abs(originFromExtent.columns.2.y) ? local.z : local.y
            let outside = max(abs(local.x) - extent.width / 2, abs(along) - extent.height / 2)
            if outside <= 0 { under = max(under ?? -.infinity, height) }
            if outside < (nearest?.distance ?? .infinity) { nearest = (height, outside) }
        }
        return under ?? nearest?.height
    }
}
#endif
