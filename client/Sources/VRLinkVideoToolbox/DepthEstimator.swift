// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreVideo
import Foundation
import VRLinkCore

/// `StereoDepthEstimator` specialized for VideoToolbox `DecodedFrame` buffers, using `pair(from:width:)` for CPU
/// luma extraction when no GPU `measure` callback is supplied.
public typealias DepthEstimator = StereoDepthEstimator<DecodedFrame>

extension StereoDepthEstimator where Frame == DecodedFrame {
    public convenience init(width: Int = 384, most: Double = 30, measure: Measure? = nil) {
        self.init(width: width, most: most, measure: measure) { frame, width, done in
            done(DepthEstimator.pair(from: frame, width: width))
        }
    }

    /// Returns `(bytesPerPixel, msbOffset)` for uncompressed biplanar YCbCr formats
    /// whose luma plane can be read directly on the CPU, or `nil` for compressed formats.
    private static func brightness(in format: OSType) -> (bytes: Int, taking: Int)? {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return (1, 0)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return (2, 1)       // 10-bit P010 stores samples in the upper bits of a 16-bit little-endian word, so byte 1 holds the top 8 bits
        default:
            return nil          // lossless-compressed hardware decoder formats cannot be read as linear CPU rows
        }
    }

    /// Downsamples both eyes of `frame` onto a shared `width`-pixel tangent grid by
    /// reading uncompressed luma planes on the CPU. Returns `nil` if the frame
    /// lacks parallel stereo views or uses GPU-only compressed pixel buffers (handled by `StereoShrink`).
    public static func pair(from frame: DecodedFrame, width: Int) -> StereoPair? {
        guard let plan = StereoPlan(layout: frame.layout, width: width) else { return nil }
        let window = plan.window, height = plan.height, perTangent = plan.perTangent, perTangentDown = plan.perTangentDown

        var pictures: [LumaPicture] = []
        for (view, covered) in zip(frame.layout.views, plan.covered) {
            var picture = LumaPicture(width: width, height: height)
            let columns = covered.x, rows = covered.y
            // Base peripheral tiles precede foveal insets in `view.tiles`; keeping the first tile
            // that covers each pixel ensures both eyes sample matching resolution layers.
            var filled = [Bool](repeating: false, count: width * height)
            for tile in view.tiles {
                guard frame.images.indices.contains(tile.picture) else { return nil }
                let image = frame.images[tile.picture]
                guard let kind = brightness(in: CVPixelBufferGetPixelFormatType(image)) else { return nil }
                CVPixelBufferLockBaseAddress(image, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return nil }
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
                let sourceWidth = CVPixelBufferGetWidthOfPlane(image, 0), sourceHeight = CVPixelBufferGetHeightOfPlane(image, 0)
                // Compute integer pixel bounds of this tile within the source luma plane.
                let tileLeft = tile.left * Float(sourceWidth), tileTop = tile.top * Float(sourceHeight)
                let tileWide = (tile.right - tile.left) * Float(sourceWidth), tileTall = (tile.bottom - tile.top) * Float(sourceHeight)
                let firstX = max(0, Int(tileLeft.rounded(.up))), lastX = min(sourceWidth, Int((tileLeft + tileWide).rounded(.down))) - 1
                let firstY = max(0, Int(tileTop.rounded(.up))), lastY = min(sourceHeight, Int((tileTop + tileTall).rounded(.down))) - 1
                guard lastX >= firstX, lastY >= firstY else { continue }
                // Average a 2x2 grid of source samples spaced across each output pixel's footprint.
                let stepX = tileWide / ((tile.frustum.right - tile.frustum.left) * perTangent)
                let stepY = tileTall / ((tile.frustum.up - tile.frustum.down) * perTangentDown)
                let tileColumns = max(columns.lowerBound, Int(((tile.frustum.left - window.left) * perTangent).rounded(.up)))
                    ..< min(columns.upperBound, Int(((tile.frustum.right - window.left) * perTangent).rounded(.up)))
                let tileRows = max(rows.lowerBound, Int(((window.up - tile.frustum.up) * perTangentDown).rounded(.up)))
                    ..< min(rows.upperBound, Int(((window.up - tile.frustum.down) * perTangentDown).rounded(.up)))
                guard !tileColumns.isEmpty, !tileRows.isEmpty else { continue }
                // Precompute the two horizontal source byte offsets for each output column.
                let sourceColumns = tileColumns.map { column -> (Int, Int) in
                    let tangent = window.left + (Float(column) + 0.5) / perTangent
                    let x = tileLeft + (tangent - tile.frustum.left) / (tile.frustum.right - tile.frustum.left) * tileWide
                    return (max(firstX, min(lastX, Int(x - stepX / 4))) * kind.bytes + kind.taking,
                            max(firstX, min(lastX, Int(x + stepX / 4))) * kind.bytes + kind.taking)
                }
                for row in tileRows {
                    let tangent = window.up - (Float(row) + 0.5) / perTangentDown
                    let y = tileTop + (tile.frustum.up - tangent) / (tile.frustum.up - tile.frustum.down) * tileTall
                    let upper = bytes + max(firstY, min(lastY, Int(y - stepY / 4))) * rowBytes
                    let lower = bytes + max(firstY, min(lastY, Int(y + stepY / 4))) * rowBytes
                    for (index, column) in tileColumns.enumerated() where !filled[row * width + column] {
                        let (a, b) = sourceColumns[index]
                        picture.pixels[row * width + column]
                            = UInt8((Int(upper[a]) + Int(upper[b]) + Int(lower[a]) + Int(lower[b]) + 2) / 4)
                        filled[row * width + column] = true
                    }
                }
            }
            pictures.append(picture)
        }
        return plan.pair(left: pictures[0], right: pictures[1])
    }
}
