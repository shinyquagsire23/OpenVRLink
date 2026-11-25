// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Premultiplied 8-bit sRGB RGBA pixel buffer (`width * height * 4` bytes, top row first).
public struct PanelPicture {
    public let width: Int, height: Int
    public internal(set) var pixels: [UInt8]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }
}

/// Rasterizes Dear ImGui draw lists on the CPU into a `PanelPicture`.
///
/// The panel only draws a few hundred triangles and only re-rasterizes when its draw lists change, so rendering
/// on the CPU avoids maintaining separate ImGui backends for Metal and Vulkan, works in 2D windows before OpenXR
/// starts, and lets unit tests inspect pixel output directly. Axis-aligned solid rectangles and font glyphs skip
/// per-pixel barycentric interpolation.
struct PanelRasterizer {
    /// ImGui vertex with pixel coordinates, UV coordinates, and straight (unpremultiplied) packed RGBA color.
    struct Vertex {
        var x, y, u, v: Float
        var color: UInt32
    }

    /// 8-bit alpha coverage font atlas.
    let atlas: [UInt8]
    let atlasWidth: Int, atlasHeight: Int

    private func coverage(_ u: Float, _ v: Float) -> Int {
        let x = min(atlasWidth - 1, max(0, Int(u * Float(atlasWidth))))
        let y = min(atlasHeight - 1, max(0, Int(v * Float(atlasHeight))))
        return Int(atlas[y * atlasWidth + x])
    }

    /// Alpha-blends a straight RGBA color (`alpha` in `0...255`) over the premultiplied destination pixel at byte offset `at`.
    @inline(__always)
    private static func blend(_ pixels: UnsafeMutablePointer<UInt8>, _ at: Int, _ r: Int, _ g: Int, _ b: Int, _ alpha: Int) {
        if alpha <= 0 { return }
        if alpha >= 255 {
            pixels[at] = UInt8(r)
            pixels[at + 1] = UInt8(g)
            pixels[at + 2] = UInt8(b)
            pixels[at + 3] = 255
            return
        }
        let keep = 255 - alpha
        pixels[at] = UInt8((r * alpha + Int(pixels[at]) * keep + 127) / 255)
        pixels[at + 1] = UInt8((g * alpha + Int(pixels[at + 1]) * keep + 127) / 255)
        pixels[at + 2] = UInt8((b * alpha + Int(pixels[at + 2]) * keep + 127) / 255)
        pixels[at + 3] = UInt8(alpha + (Int(pixels[at + 3]) * keep + 127) / 255)
    }

    /// Draws `indices` (triangles of `vertices`) clipped to `clip` (left, top, right, bottom in pixels).
    func draw(_ vertices: UnsafeBufferPointer<Vertex>, _ indices: UnsafeBufferPointer<UInt16>, clip: (Float, Float, Float, Float),
              into picture: inout PanelPicture) {
        let width = picture.width, height = picture.height
        let left = max(0, Int(clip.0.rounded(.up))), top = max(0, Int(clip.1.rounded(.up)))
        let right = min(width, Int(clip.2.rounded(.up))), bottom = min(height, Int(clip.3.rounded(.up)))
        guard left < right, top < bottom else { return }
        picture.pixels.withUnsafeMutableBufferPointer { buffer in
            guard let pixels = buffer.baseAddress else { return }
            var at = 0
            while at + 2 < indices.count {
                let a = vertices[Int(indices[at])], b = vertices[Int(indices[at + 1])], c = vertices[Int(indices[at + 2])]
                // Fast path for two triangles (a, b, c) and (a, c, d) forming a single-color axis-aligned quad.
                if at + 5 < indices.count, indices[at + 3] == indices[at], indices[at + 4] == indices[at + 2] {
                    let d = vertices[Int(indices[at + 5])]
                    if a.color == b.color, b.color == c.color, c.color == d.color,
                       a.y == b.y, b.x == c.x, c.y == d.y, d.x == a.x, b.u == c.u, a.v == b.v, d.u == a.u, c.v == d.v {
                        rectangle(a, c, pixels, width, left, top, right, bottom)
                        at += 6
                        continue
                    }
                }
                triangle(a, b, c, pixels, width, left, top, right, bottom)
                at += 3
            }
        }
    }

    /// Fills an axis-aligned rectangle from top-left `a` to bottom-right `c` at pixel centers.
    private func rectangle(_ a: Vertex, _ c: Vertex, _ pixels: UnsafeMutablePointer<UInt8>, _ width: Int,
                           _ left: Int, _ top: Int, _ right: Int, _ bottom: Int) {
        let x0 = max(left, Int((min(a.x, c.x) - 0.5).rounded(.up))), x1 = min(right, Int((max(a.x, c.x) - 0.5).rounded(.up)))
        let y0 = max(top, Int((min(a.y, c.y) - 0.5).rounded(.up))), y1 = min(bottom, Int((max(a.y, c.y) - 0.5).rounded(.up)))
        guard x0 < x1, y0 < y1 else { return }
        let r = Int(a.color & 0xFF), g = Int(a.color >> 8 & 0xFF), b = Int(a.color >> 16 & 0xFF), alpha = Int(a.color >> 24)
        if a.u == c.u && a.v == c.v {
            // Uniform UV across the quad (for example, sampling the font atlas's solid white pixel for flat fills).
            let whole = alpha * coverage(a.u, a.v) / 255
            for y in y0..<y1 {
                var at = (y * width + x0) * 4
                for _ in x0..<x1 {
                    PanelRasterizer.blend(pixels, at, r, g, b, whole)
                    at += 4
                }
            }
            return
        }
        // Step through the font atlas across the glyph quad.
        let perX = (c.u - a.u) / (c.x - a.x), perY = (c.v - a.v) / (c.y - a.y)
        for y in y0..<y1 {
            let v = a.v + (Float(y) + 0.5 - a.y) * perY
            let row = min(atlasHeight - 1, max(0, Int(v * Float(atlasHeight)))) * atlasWidth
            var at = (y * width + x0) * 4
            for x in x0..<x1 {
                let u = a.u + (Float(x) + 0.5 - a.x) * perX
                let covered = Int(atlas[row + min(atlasWidth - 1, max(0, Int(u * Float(atlasWidth))))])
                if covered != 0 { PanelRasterizer.blend(pixels, at, r, g, b, alpha * covered / 255) }
                at += 4
            }
        }
    }

    /// Rasterizes a general triangle, interpolating vertex color and UV coordinates at pixel centers.
    private func triangle(_ a: Vertex, _ b: Vertex, _ c: Vertex, _ pixels: UnsafeMutablePointer<UInt8>, _ width: Int,
                          _ left: Int, _ top: Int, _ right: Int, _ bottom: Int) {
        let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        guard area != 0 else { return }
        // Bounding box of pixel centers, inclusive of edges (the top-left tie-breaking bias below handles shared edges).
        let x0 = max(left, Int((min(a.x, b.x, c.x) - 0.5).rounded(.up))), x1 = min(right, Int((max(a.x, b.x, c.x) - 0.5).rounded(.down)) + 1)
        let y0 = max(top, Int((min(a.y, b.y, c.y) - 0.5).rounded(.up))), y1 = min(bottom, Int((max(a.y, b.y, c.y) - 0.5).rounded(.down)) + 1)
        guard x0 < x1, y0 < y1 else { return }
        let scale = 1 / area
        let plain = a.u == b.u && b.u == c.u && a.v == b.v && b.v == c.v
        let plainCoverage = plain ? coverage(a.u, a.v) : 255
        let same = a.color == b.color && b.color == c.color
        func channels(_ color: UInt32) -> (Float, Float, Float, Float) {
            (Float(color & 0xFF), Float(color >> 8 & 0xFF), Float(color >> 16 & 0xFF), Float(color >> 24))
        }
        let ca = channels(a.color), cb = channels(b.color), cc = channels(c.color)
        // Apply the top-left fill rule so shared triangle edges are blended once. A pixel center on an edge is
        // included only on top or left edges; multiplying by `scale` normalizes winding.
        func bias(_ fromX: Float, _ fromY: Float, _ toX: Float, _ toY: Float) -> Float {
            let dx = (toX - fromX) * scale, dy = (toY - fromY) * scale
            return (dy < 0 || (dy == 0 && dx > 0)) ? 0 : -1e-7
        }
        let biasA = bias(b.x, b.y, c.x, c.y), biasB = bias(c.x, c.y, a.x, a.y), biasC = bias(a.x, a.y, b.x, b.y)
        // Per-pixel step of each barycentric weight along +X.
        let stepA = (b.y - c.y) * scale, stepB = (c.y - a.y) * scale, stepC = (a.y - b.y) * scale
        @inline(__always) func weights(_ px: Float, _ py: Float) -> (Float, Float, Float) {
            (((b.x - px) * (c.y - py) - (b.y - py) * (c.x - px)) * scale, ((c.x - px) * (a.y - py) - (c.y - py) * (a.x - px)) * scale,
             ((a.x - px) * (b.y - py) - (a.y - py) * (b.x - px)) * scale)
        }
        @inline(__always) func inside(_ x: Int, _ py: Float) -> Bool {
            let w = weights(Float(x) + 0.5, py)
            return w.0 + biasA >= 0 && w.1 + biasB >= 0 && w.2 + biasC >= 0
        }
        let flatAlpha = Int(ca.3) * plainCoverage / 255
        for y in y0..<y1 {
            let py = Float(y) + 0.5
            // Estimate the horizontal span of covered pixels from the edge weights at `x0` (padded by one pixel
            // on each side), then refine the endpoints with the exact edge test.
            var first = x0, last = x1 - 1
            let start = weights(Float(x0) + 0.5, py)
            for (weight, step) in [(start.0, stepA), (start.1, stepB), (start.2, stepC)] {
                if step > 0 {
                    let from = -weight / step
                    if from > 1 { first = max(first, x0 + Int(min(from, Float(x1 - x0))) - 1) }
                } else if step < 0 {
                    let until = weight / -step
                    if until < Float(x1 - x0) { last = min(last, x0 + Int(max(until, -1)) + 1) }
                }
            }
            while first <= last, !inside(first, py) { first += 1 }
            while last >= first, !inside(last, py) { last -= 1 }
            guard first <= last else { continue }
            var at = (y * width + first) * 4
            if same && plain {
                for _ in first...last {
                    PanelRasterizer.blend(pixels, at, Int(ca.0), Int(ca.1), Int(ca.2), flatAlpha)
                    at += 4
                }
                continue
            }
            for x in first...last {
                let (wa, wb, wc) = weights(Float(x) + 0.5, py)
                var covered = plainCoverage
                if !plain { covered = coverage(wa * a.u + wb * b.u + wc * c.u, wa * a.v + wb * b.v + wc * c.v) }
                if same {
                    PanelRasterizer.blend(pixels, at, Int(ca.0), Int(ca.1), Int(ca.2), Int(ca.3) * covered / 255)
                } else {
                    let alpha = wa * ca.3 + wb * cb.3 + wc * cc.3
                    PanelRasterizer.blend(pixels, at, Int(wa * ca.0 + wb * cb.0 + wc * cc.0 + 0.5),
                                          Int(wa * ca.1 + wb * cb.1 + wc * cc.1 + 0.5),
                                          Int(wa * ca.2 + wb * cb.2 + wc * cc.2 + 0.5), Int(alpha + 0.5) * covered / 255)
                }
                at += 4
            }
        }
    }
}
