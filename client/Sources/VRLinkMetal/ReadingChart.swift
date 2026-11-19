// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import VRLinkCore
import VRLinkVideoToolbox

/// Generates grayscale letter charts over a multi-scale noise background for
/// `VergenceTest`. The background texture and high-contrast letter groups give
/// the user's eyes fine binocular detail to fuse and hold fixation at the chart's depth.
public enum ReadingChart {
    /// Unambiguous uppercase letters and digits used to build random 3-character groups.
    private static let letters = Array("ACDEFHKLNPRTUVXYZ234679")

    /// Generates three rows of 3-character groups with 3, 4, and 5 groups per row.
    public static func randomLines<G: RandomNumberGenerator>(using generator: inout G) -> [String] {
        [3, 4, 5].map { groups in
            (0..<groups).map { _ in String((0..<3).map { _ in letters.randomElement(using: &generator)! }) }
                .joined(separator: " ")
        }
    }

    /// Renders the chart as a grayscale `CGImage`.
    public static func image(heading: String, lines: [String], footing: String, width: Int = 1024, height: Int = 512,
                             seed: UInt64 = 1) -> CGImage? {
        drawn(heading: heading, lines: lines, footing: footing, width: width, height: height, seed: seed)?.makeImage()
    }

    /// Renders `heading` at the top, `lines` in descending font sizes in the center,
    /// and `footing` at the bottom into an 8-bit grayscale bitmap context.
    private static func drawn(heading: String, lines: [String], footing: String, width: Int, height: Int,
                              seed: UInt64) -> CGContext? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let gray = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        // Fill two octaves of dark block noise so both foveal and peripheral vision have binocular fusion cues.
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 56)
        }
        for (cell, share) in [(32, 2), (8, 4)] {
            for top in stride(from: 0, to: height, by: cell) {
                for left in stride(from: 0, to: width, by: cell) {
                    let shade = Int(next()) / share
                    for y in top..<min(height, top + cell) {
                        for x in left..<min(width, left + cell) {
                            gray[y * width + x] = UInt8(min(120, (cell == 32 ? 20 : Int(gray[y * width + x])) + shade / 2))
                        }
                    }
                }
            }
        }
        // Draw a bright border to frame the chart against a black background.
        context.setStrokeColor(gray: 0.9, alpha: 1)
        context.setLineWidth(6)
        context.stroke(CGRect(x: 3, y: 3, width: width - 6, height: height - 6))

        // Core Graphics uses a bottom-left origin while row 0 of `gray` is at the top.
        context.setFillColor(gray: 0.95, alpha: 1)
        func write(_ text: String, size: CGFloat, middle: CGFloat) {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
                                           y: middle - bounds.height / 2 - bounds.minY)
            CTLineDraw(line, context)
        }
        let tall = CGFloat(height)
        write(heading, size: tall * 0.07, middle: tall * 0.9)
        var middle = tall * 0.7, size = tall * 0.17
        for line in lines {
            write(line, size: size, middle: middle)
            middle -= size * 1.25
            size *= 0.7
        }
        write(footing, size: tall * 0.06, middle: tall * 0.08)
        return context
    }

    /// Wraps the rendered chart in a full-range biplanar NV12 `DecodedFrame`
    /// (neutral chroma) so `QuadRenderer` can sample it like a decoded video frame.
    /// Returns `nil` if pixel buffer allocation fails.
    public static func frame(heading: String, lines: [String], footing: String, width: Int = 1024, height: Int = 512,
                             seed: UInt64 = 1) -> DecodedFrame? {
        guard let context = drawn(heading: heading, lines: lines, footing: footing, width: width, height: height, seed: seed),
              let gray = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        // Copy grayscale pixels into the luma plane and fill the CbCr plane with neutral 128.
        var made: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                           kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            attributes as CFDictionary, &made)
        guard let image = made else { return nil }
        CVPixelBufferLockBaseAddress(image, [])
        if let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            for row in 0..<min(height, CVPixelBufferGetHeightOfPlane(image, 0)) {
                memcpy(luma + row * stride, gray + row * width, min(width, stride))
            }
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(image, 1) {
            memset(chroma, 128, CVPixelBufferGetHeightOfPlane(image, 1) * CVPixelBufferGetBytesPerRowOfPlane(image, 1))
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return DecodedFrame(frameID: 0, images: [image], layout: .empty)
    }
}
