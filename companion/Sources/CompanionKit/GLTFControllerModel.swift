// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Converts a glTF controller asset into a SteamVR render model directory containing per-component Wavefront
/// OBJ/MTL meshes, a base color texture, and a component animation JSON file.
///
/// Input glTFs follow the node and animation layout of Samsung's Galaxy XR controller models. Moving parts
/// live under nodes named `Trigger`, `Grip`, `ThumbStick`, `UpperButton`, `LowerButton`, and `MenuButton`,
/// while any remaining meshes are merged into `body`. Component animations are read from `Trigger_Press`,
/// `Grip_Press`, `UpperButton_Press`, `LowerButton_Press`, `SystemButton_Press`, and
/// `ThumbStick_{Left,Right,Up,Down}`, converting rotation channels into `rotate` motions around the node's
/// pivot, translation channels into `translate` motions, and the thumbstick tilt channels into a `joystick`
/// motion.
///
/// OpenVRLink reports these controllers to SteamVR using the Oculus Touch profile, so the generated JSON
/// binds animations to Oculus Touch input paths and transforms geometry into SteamVR's Quest 2 controller
/// space. By default `place` maps the glTF origin to `openxr_grip`.
public enum GLTFControllerModel {
    public struct Unusable: Error, CustomStringConvertible {
        public let description: String
        init(_ what: String) { description = "cannot convert controller model: \(what)" }
    }

    public enum Side: String, Sendable { case left, right }

    /// Rigid transform with `rotation` stored as a unit `(x, y, z, w)` quaternion and `translation` in meters.
    public struct Transform: Equatable, Sendable {
        public var rotation: [Double] = [0, 0, 0, 1], translation: [Double] = [0, 0, 0]
        public init(rotation: [Double] = [0, 0, 0, 1], translation: [Double] = [0, 0, 0]) {
            self.rotation = rotation
            self.translation = translation
        }

        /// Creates a transform from extrinsic XYZ Euler angles in degrees and a translation in meters.
        public init(degrees: [Double], translation: [Double]) {
            var turn = [0.0, 0, 0, 1]
            for axis in 0..<3 {
                let half = degrees[axis] * .pi / 360
                var step = [0.0, 0, 0, cos(half)]
                step[axis] = sin(half)
                turn = multiply(step, turn)
            }
            self.init(rotation: turn, translation: translation)
        }

        func turned(_ v: [Double]) -> [Double] { rotate(v, by: rotation) }
        func applied(to v: [Double]) -> [Double] { add(turned(v), translation) }
        /// Composes `self * inner` (applies `inner` first, then `self`).
        func after(_ inner: Transform) -> Transform {
            Transform(rotation: multiply(rotation, inner.rotation), translation: applied(to: inner.translation))
        }
    }

    /// Transform of the `openxr_grip` component in SteamVR's Quest 2 Touch render model.
    public static func questGrip(_ side: Side) -> Transform {
        Transform(degrees: [20.6, 0, 0], translation: [side == .left ? 0.007 : -0.007, -0.00182941, 0.1019482])
    }

    /// Returns the transform that places the Galaxy XR controller glTF into SteamVR's Quest 2 controller space.
    ///
    /// On the client, `HeadsetQuirks.GripOffset.towardQuest` shifts Samsung's reported grip pose by +5 mm X,
    /// +5 mm Y, +56 mm Z, and +15 deg pitch on the left hand (mirrored on the right) to match Quest Touch
    /// controllers. Samsung's glTF is authored around the unadjusted runtime pose, so we start from `questGrip`
    /// and apply the inverse of that translation and pitch offset.
    ///
    /// Finally, we apply the inverse of `galaxyXRGrip` because the runtime's grip pose sits 8 mm outboard along
    /// X (measured from the handle mesh) and 14 mm forward along -Z (tuned visually so touching the physical
    /// controllers together lines up in VR), rather than at the glTF origin.
    public static func galaxyXRPlace(_ side: Side) -> Transform {
        let back = Transform(degrees: [-15, 0, 0], translation: [0, 0, 0])
        let moved = [side == .left ? 0.005 : -0.005, 0.005, 0.056]
        let reported = questGrip(side).after(Transform(rotation: back.rotation, translation: scale(back.turned(moved), -1)))
        return reported.after(Transform(translation: scale(galaxyXRGrip(side), -1)))
    }

    /// Position of Samsung's reported OpenXR grip pose in the Galaxy XR glTF's local coordinates.
    public static func galaxyXRGrip(_ side: Side) -> [Double] { [side == .left ? -0.008 : 0.008, 0, -0.014] }

    struct Part {
        let component: String, file: String
        var positions: [[Double]] = [], normals: [[Double]] = [], coordinates: [[Double]] = [], triangles: [[Int]] = []
    }

    /// Converts a glTF controller asset and returns output files with paths relative to the model directory.
    public static func convert(gltf: Data, files: [String: Data], side: Side, name: String, place: Transform? = nil) throws -> [(path: String, data: Data)] {
        guard let text = String(data: gltf, encoding: .utf8), let document = try? JSON(parsing: text) else { throw Unusable("invalid glTF JSON") }
        let nodes = document["nodes"]?.array ?? [], accessors = document["accessors"]?.array ?? []
        let views = document["bufferViews"]?.array ?? [], meshes = document["meshes"]?.array ?? []
        let buffers = try (document["buffers"]?.array ?? []).map { buffer -> Data in
            guard let uri = buffer["uri"]?.string, let data = files[uri] else { throw Unusable("missing buffer") }
            return data
        }
        guard !nodes.isEmpty, !meshes.isEmpty else { throw Unusable("no meshes in glTF") }
        let place = place ?? questGrip(side)

        func number(_ value: JSON?) -> Double? { value?.number.flatMap(Double.init) }
        func numbers(_ value: JSON?) -> [Double]? { value?.array?.compactMap { number($0) } }
        func index(_ value: JSON?) -> Int? { number(value).map { Int($0) } }

        /// Reads an accessor's scalar or vector components as `Double`s, returning `width` components per element.
        func read(_ accessor: Int?) throws -> (values: [Double], width: Int) {
            guard let accessor, accessors.indices.contains(accessor) else { throw Unusable("missing accessor") }
            let described = accessors[accessor]
            guard let view = index(described["bufferView"]), views.indices.contains(view), let buffer = index(views[view]["buffer"]),
                  buffers.indices.contains(buffer), let count = index(described["count"]), let type = described["type"]?.string,
                  let width = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][type], let kind = index(described["componentType"]),
                  let size = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][kind]
            else { throw Unusable("unsupported accessor format") }
            let data = buffers[buffer]
            let start = (index(views[view]["byteOffset"]) ?? 0) + (index(described["byteOffset"]) ?? 0)
            let stride = index(views[view]["byteStride"]) ?? size * width
            guard count >= 0, start >= 0, stride >= size * width, count == 0 || start + (count - 1) * stride + size * width <= data.count else {
                throw Unusable("accessor out of buffer bounds")
            }
            var values: [Double] = []
            values.reserveCapacity(count * width)
            data.withUnsafeBytes { bytes in
                for element in 0..<count {
                    for part in 0..<width {
                        let at = start + element * stride + part * size
                        switch kind {
                        case 5126: values.append(Double(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self)))))
                        case 5125: values.append(Double(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))))
                        case 5123: values.append(Double(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt16.self))))
                        case 5122: values.append(Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: Int16.self))))
                        case 5121: values.append(Double(bytes[at]))
                        default: values.append(Double(Int8(bitPattern: bytes[at])))
                        }
                    }
                }
            }
            return (values, width)
        }
        func vectors(_ accessor: Int?) throws -> [[Double]] {
            let (values, width) = try read(accessor)
            return stride(from: 0, to: values.count, by: width).map { Array(values[$0..<($0 + width)]) }
        }

        // Compute each node's rest transform in model space.
        var parents = [Int?](repeating: nil, count: nodes.count)
        for (parent, node) in nodes.enumerated() {
            for child in node["children"]?.array ?? [] {
                if let child = index(child), nodes.indices.contains(child) { parents[child] = parent }
            }
        }
        func local(_ node: Int) -> Transform {
            Transform(rotation: numbers(nodes[node]["rotation"]).flatMap { $0.count == 4 ? $0 : nil } ?? [0, 0, 0, 1],
                      translation: numbers(nodes[node]["translation"]).flatMap { $0.count == 3 ? $0 : nil } ?? [0, 0, 0])
        }
        func world(_ node: Int?, depth: Int = 0) -> Transform {
            guard let node, depth < 64 else { return Transform() }
            return world(parents[node], depth: depth + 1).after(local(node))
        }

        // Map animated glTF node names to SteamVR render-model component and file names.
        let controls: [(node: String, component: String, file: String)] = [
            ("Trigger", "trigger", "trigger"), ("Grip", "button_grip", "grip"), ("ThumbStick", "thumbstick", "thumbstick"),
            ("UpperButton", side == .left ? "button_y" : "button_b", side == .left ? "button_y" : "button_b"),
            ("LowerButton", side == .left ? "button_x" : "button_a", side == .left ? "button_x" : "button_a"),
            ("MenuButton", "button_enter", "button_menu"),
        ]
        func named(_ name: String) -> Int? { nodes.firstIndex { $0["name"]?.string == name } }
        func control(of node: Int) -> Int? {
            var at: Int? = node, depth = 0
            while let here = at, depth < 64 {
                if let name = nodes[here]["name"]?.string, let found = controls.firstIndex(where: { $0.node == name }) { return found }
                at = parents[here]
                depth += 1
            }
            return nil
        }

        // Skip fully transparent materials such as the unlit status LED overlay.
        let hidden = Set((document["materials"]?.array ?? []).enumerated().compactMap { index, material -> Int? in
            let factor = numbers(material["pbrMetallicRoughness"]?["baseColorFactor"])
            return material["alphaMode"]?.string != nil && factor?.count == 4 && factor?[3] == 0 ? index : nil
        })

        var body = Part(component: "body", file: "body")
        var parts = controls.map { Part(component: $0.component, file: $0.file) }
        for (node, described) in nodes.enumerated() {
            guard let mesh = index(described["mesh"]), meshes.indices.contains(mesh) else { continue }
            let placed = place.after(world(node))
            let which = control(of: node)
            for primitive in meshes[mesh]["primitives"]?.array ?? [] {
                if let material = index(primitive["material"]), hidden.contains(material) { continue }
                guard (index(primitive["mode"]) ?? 4) == 4 else { continue }
                let positions = try vectors(index(primitive["attributes"]?["POSITION"]))
                let normals = try index(primitive["attributes"]?["NORMAL"]).map { try vectors($0) } ?? []
                let coordinates = try index(primitive["attributes"]?["TEXCOORD_0"]).map { try vectors($0) } ?? []
                let indices = try index(primitive["indices"]).map { try read($0).values.map { Int($0) } } ?? Array(positions.indices)
                guard indices.allSatisfy(positions.indices.contains) else { throw Unusable("mesh index out of bounds") }
                func add(to part: inout Part) {
                    let base = part.positions.count
                    for vertex in positions.indices {
                        part.positions.append(placed.applied(to: positions[vertex]))
                        part.normals.append(normals.count == positions.count ? placed.turned(normals[vertex]) : [0, 1, 0])
                        // Flip V from glTF's top-left UV origin to Wavefront OBJ's bottom-left origin.
                        part.coordinates.append(coordinates.count == positions.count ? [coordinates[vertex][0], 1 - coordinates[vertex][1]] : [0, 0])
                    }
                    for triangle in stride(from: 0, to: indices.count - 2, by: 3) {
                        part.triangles.append([base + indices[triangle], base + indices[triangle + 1], base + indices[triangle + 2]])
                    }
                }
                if let which { add(to: &parts[which]) } else { add(to: &body) }
            }
        }
        guard !body.positions.isEmpty else { throw Unusable("no controller body mesh found") }

        // Extract each animation's net rotation, translation, and pivot in model space.
        struct Motion { var turn: [Double]; var slide: [Double]; var pivot: [Double] }
        var motions: [String: Motion] = [:]
        for animation in document["animations"]?.array ?? [] {
            guard let name = animation["name"]?.string else { continue }
            let samplers = animation["samplers"]?.array ?? []
            var target: Int?, firstTurn: [Double]?, lastTurn: [Double]?, firstPlace: [Double]?, lastPlace: [Double]?
            for channel in animation["channels"]?.array ?? [] {
                guard let node = index(channel["target"]?["node"]), nodes.indices.contains(node), let sampler = index(channel["sampler"]),
                      samplers.indices.contains(sampler), let path = channel["target"]?["path"]?.string else { continue }
                // Ignore CUBICSPLINE samplers (which pack in/out tangents around each keyframe); controller animations are linear.
                guard samplers[sampler]["interpolation"]?.string != "CUBICSPLINE" else { continue }
                let values = try vectors(index(samplers[sampler]["output"]))
                guard let first = values.first, let last = values.last else { continue }
                target = node
                if path == "rotation", first.count == 4 { (firstTurn, lastTurn) = (first, last) }
                if path == "translation", first.count == 3 { (firstPlace, lastPlace) = (first, last) }
            }
            guard let target else { continue }
            let outside = place.after(world(parents[target]))
            let rest = local(target)
            let turn = multiply(lastTurn ?? rest.rotation, conjugate(firstTurn ?? rest.rotation))
            // Conjugate the local rotation delta into model space.
            let seen = multiply(multiply(outside.rotation, turn), conjugate(outside.rotation))
            let slide = outside.turned(subtract(lastPlace ?? rest.translation, firstPlace ?? rest.translation))
            motions[name] = Motion(turn: seen, slide: slide, pivot: outside.applied(to: firstPlace ?? rest.translation))
        }
        func motion(_ names: String...) -> Motion? { names.lazy.compactMap { motions[$0] }.first }
        func degrees(_ turn: [Double]) -> Double { 2 * atan2(length(Array(turn[0..<3])), abs(turn[3])) * 180 / .pi }
        /// Returns the unit rotation axis oriented for a positive rotation angle.
        func axis(_ turn: [Double]) -> [Double] { normalized(scale(Array(turn[0..<3]), turn[3] < 0 ? -1 : 1)) }
        func list(_ values: [Double]) -> JSON { .array(values.map { JSON.number(short($0)) }) }
        func local(_ origin: [Double], _ turn: [Double] = [0, 0, 0]) -> JSON {
            .object(["origin": list(origin), "rotate_xyz": list(turn)])
        }
        func center(of part: Part) -> [Double] {
            scale(part.positions.reduce([0, 0, 0], add), 1 / Double(max(part.positions.count, 1)))
        }

        var components: [(key: String, value: JSON)] = [("body", .object(["filename": .string("\(name)_body.obj"), "component_local": local([0, 0, 0])]))]
        for (index, part) in parts.enumerated() where !part.positions.isEmpty {
            let file = JSON.string("\(name)_\(part.file).obj")
            var described: [(key: String, value: JSON)] = [("filename", file)]
            switch controls[index].node {
            case "Trigger", "Grip":
                let trigger = controls[index].node == "Trigger"
                if let pressed = motion(trigger ? "Trigger_Press" : "Grip_Press") {
                    var how: [(key: String, value: JSON)] = [("controller_axis", .number(trigger ? "1" : "2")), ("controller_axis_component", .number("0")),
                                                              ("trigger_path", .string(trigger ? "/input/trigger" : "/input/grip"))]
                    if degrees(pressed.turn) > 0.5 {
                        how = [("type", .string("rotate"))] + how + [("value_mapping", list([0, degrees(pressed.turn)])), ("pivot", list(pressed.pivot)),
                                                                     ("axis", list(axis(pressed.turn)))]
                    } else {
                        how = [("type", .string("translate"))] + how + [("value_mapping", list([0, length(pressed.slide)])), ("axis", list(normalized(pressed.slide)))]
                    }
                    described.append(("motion", .object(how)))
                }
            case "ThumbStick":
                // Derive the thumbstick shaft axis (+Y) from the cross product of the two tilt axes, oriented from
                // the pivot toward the cap center. SteamVR tilts a `joystick` component around the local Z axis for
                // X deflection (`joystick_rotation_x`) and around the local X axis for Y deflection
                // (`joystick_rotation_y`), so we construct a local frame with +Y along the shaft and +Z toward the
                // user instead of relying on the sign of Samsung's animation clips ("ThumbStick_Up" tilts backward).
                if let left = motion("ThumbStick_Left"), let forward = motion("ThumbStick_Up_ThumbStick", "ThumbStick_Up") {
                    var y = normalized(cross(axis(left.turn), axis(forward.turn)))
                    let out = subtract(center(of: part), left.pivot)
                    if y[0] * out[0] + y[1] * out[1] + y[2] * out[2] < 0 { y = scale(y, -1) }
                    let z = normalized(subtract([0, 0, 1], scale(y, y[2])))
                    let x = cross(y, z)
                    let reach = max(degrees(left.turn), degrees(forward.turn))
                    described.append(("motion", .object([
                        ("type", .string("joystick")), ("controller_axis", .number("0")), ("component_path", .string("/input/joystick")),
                        ("center", list(left.pivot)), ("rotate_xyz", list(eulerDegrees(x: x, y: y, z: z))),
                        ("joystick_rotation_x", list([reach, -reach])), ("joystick_rotation_y", list([reach, -reach])),
                        ("press_translate", list(scale(y, -0.0008))),
                    ])))
                }
            default:
                let button = controls[index].node
                let path = button == "MenuButton" ? "/input/system/click" : "/input/\(part.component.suffix(1))/click"
                if let pressed = motion(button == "MenuButton" ? "SystemButton_Press" : "\(button)_Press", "\(button)_Press"), length(pressed.slide) > 0.00005 {
                    described.append(("motion", .object([
                        ("type", .string("translate")), ("pressed_path", .string(path)),
                        ("controller_button", .number(button == "MenuButton" ? "0" : button == "UpperButton" ? "1" : "2")),
                        ("value_mapping", list([0, length(pressed.slide)])), ("axis", list(normalized(pressed.slide))),
                    ])))
                }
            }
            described.append(("component_local", local(center(of: part))))
            components.append((part.component, .object(described)))
        }
        // Standard attachment pose components copied from SteamVR's Quest 2 Touch model.
        let mirror: Double = side == .left ? 1 : -1
        let places: [(String, [Double], [Double])] = [
            ("base", [-0.0034, -0.0034, 0.1491], [-0.4, 180, 0]), ("tip", [0.016694, -0.02522, 0.024687], [-37.4, 0, 0]),
            ("openxr_aim", [0.007, -0.03894766, 0.00949694], [-39.4, 0, 0]), ("openxr_grip", [0.007, -0.00182941, 0.1019482], [20.6, 0, 0]),
            ("openxr_handmodel", [-0.01125, -0.00182941, 0.1019482], [-39.4, 0, 0]), ("handgrip", [0, 0.003, 0.097], [5.037, 0, 0]),
            ("grip", [0, 0.003, 0.097], [5.037, 0, 0]),
        ]
        for (key, origin, turn) in places { components.append((key, .object(["component_local": local([origin[0] * mirror, origin[1], origin[2]], turn)]))) }

        var out: [(path: String, data: Data)] = []
        let material = "newmtl controller\nKa 1.000000 1.000000 1.000000\nKd 1.000000 1.000000 1.000000\nKs 0.000000 0.000000 0.000000\nd 1.000000\nillum 1\nmap_Kd \(name).png\n"
        func wavefront(_ pieces: [Part], as file: String) {
            var text = "mtllib \(file).mtl\no \(file)\n"
            for piece in pieces {
                for v in piece.positions { text += "v \(fixed(v[0])) \(fixed(v[1])) \(fixed(v[2]))\n" }
            }
            for piece in pieces {
                for t in piece.coordinates { text += "vt \(fixed(t[0])) \(fixed(t[1]))\n" }
            }
            for piece in pieces {
                for n in piece.normals { text += "vn \(fixed(n[0])) \(fixed(n[1])) \(fixed(n[2]))\n" }
            }
            text += "usemtl controller\ns 1\n"
            var base = 1
            for piece in pieces {
                for t in piece.triangles {
                    let (a, b, c) = (t[0] + base, t[1] + base, t[2] + base)
                    text += "f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n"
                }
                base += piece.positions.count
            }
            out.append(("\(file).obj", Data(text.utf8)))
            out.append(("\(file).mtl", Data(material.utf8)))
        }
        let present = parts.filter { !$0.positions.isEmpty }
        wavefront([body] + present, as: name)
        wavefront([body], as: "\(name)_body")
        for part in present { wavefront([part], as: "\(name)_\(part.file)") }
        // Copy the first opaque material's PNG base-color texture.
        let color = (document["materials"]?.array ?? []).enumerated().lazy.filter { !hidden.contains($0.offset) }
            .compactMap { index($0.element["pbrMetallicRoughness"]?["baseColorTexture"]?["index"]) }.first
        if let color, let source = index(document["textures"]?.array?[safe: color]?["source"]),
           let uri = document["images"]?.array?[safe: source]?["uri"]?.string, uri.lowercased().hasSuffix(".png"), let image = files[uri] {
            out.append(("\(name).png", image))
        }
        out.append(("\(name).json", Data(JSON.object([("components", .object(components))]).text.utf8)))
        return out
    }

    /// Returns relative file names referenced by buffer and image URIs in `gltf`.
    public static func references(of gltf: Data) -> [String] {
        guard let text = String(data: gltf, encoding: .utf8), let document = try? JSON(parsing: text) else { return [] }
        return ((document["buffers"]?.array ?? []) + (document["images"]?.array ?? [])).compactMap { $0["uri"]?.string }
            .filter { !$0.hasPrefix("data:") && !$0.contains("/") && !$0.contains("\\") && !$0.contains("..") }
    }

    /// Decomposes orthonormal basis vectors into extrinsic XYZ Euler angles in degrees (`R = Rz * Ry * Rx`).
    static func eulerDegrees(x: [Double], y: [Double], z: [Double]) -> [Double] {
        let pitch = -asin(max(-1, min(1, x[2])))
        return [atan2(y[2], z[2]), pitch, atan2(x[1], x[0])].map { $0 * 180 / .pi }
    }

    private static func fixed(_ value: Double) -> String {
        let scaled = (value * 1_000_000).rounded(), whole = Int(abs(scaled)) / 1_000_000, rest = Int(abs(scaled)) % 1_000_000
        let digits = String(rest)
        return (scaled < 0 ? "-" : "") + "\(whole)." + String(repeating: "0", count: 6 - digits.count) + digits
    }

    private static func short(_ value: Double) -> String {
        var text = fixed(value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private func add(_ a: [Double], _ b: [Double]) -> [Double] { [a[0] + b[0], a[1] + b[1], a[2] + b[2]] }
private func subtract(_ a: [Double], _ b: [Double]) -> [Double] { [a[0] - b[0], a[1] - b[1], a[2] - b[2]] }
private func scale(_ a: [Double], _ by: Double) -> [Double] { a.map { $0 * by } }
private func cross(_ a: [Double], _ b: [Double]) -> [Double] { [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]] }
private func length(_ a: [Double]) -> Double { (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).squareRoot() }
private func normalized(_ a: [Double]) -> [Double] {
    let size = length(a)
    return size > 1e-12 ? scale(a, 1 / size) : [0, 1, 0]
}
private func conjugate(_ q: [Double]) -> [Double] { [-q[0], -q[1], -q[2], q[3]] }
/// Hamilton product `a * b` (applies rotation `b` followed by `a`).
private func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
    [a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
     a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
     a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
     a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]]
}
private func rotate(_ v: [Double], by q: [Double]) -> [Double] {
    let u = [q[0], q[1], q[2]], t = scale(cross(u, v), 2)
    return add(add(v, scale(t, q[3])), cross(u, t))
}
