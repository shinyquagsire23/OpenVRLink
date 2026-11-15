// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import AVKit
import CoreImage
import QuartzCore
import RealityKit
import SwiftUI
import VRLinkAppleFace
import VRLinkCore

/// Manages the two SwiftUI attachments required to drive the Spatial Persona
/// camera inside an immersive space, following the layout used by the ALVR
/// visionOS client so visionOS tracks the camera anchor reliably:
///
/// - `"persona_camera"`: an empty view with `.cameraAnchor(isActive: true)`
///   placed at the scene root and updated every frame (`placePersonaCameraEntity`).
/// - `"camera_view"`: starts capture from inside the space and optionally
///   displays the annotated camera feed two meters in front of the initial origin.
enum PersonaAttachments {
    static let anchor = "persona_camera", cameraView = "camera_view"

    /// Adds both attachment entities to `content` and returns the camera anchor entity for per-frame updates.
    @MainActor
    static func add(to content: inout RealityViewContent, from attachments: RealityViewAttachments,
                    settings: VRLinkCore.Settings) -> Entity? {
        let anchor = attachments.entity(for: PersonaAttachments.anchor)
        if let anchor {
            anchor.isEnabled = true
            anchor.name = "persona_camera_ent"
            content.add(anchor)
        }
        if settings.faceFromCamera, let view = attachments.entity(for: PersonaAttachments.cameraView) {
            view.isEnabled = true
            view.name = "camera_view_ent"
            view.position = [0, 1, -2]
            content.add(view)
        }
        return anchor
    }
}

/// Positions the Persona camera anchor one meter in front of the user's head
/// with matching orientation. When no other camera is active, visionOS lets
/// the Persona camera lag behind its anchor; toggling `isEnabled` every two
/// frames forces it to snap to the latest pose (matching the ALVR workaround).
@MainActor
func placePersonaCameraEntity(_ entity: Entity, originFromDevice: simd_float4x4, tick: Int) {
    let ahead = originFromDevice.columns.3 - originFromDevice.columns.2
    entity.position = [ahead.x, ahead.y, ahead.z]
    entity.orientation = simd_quatf(originFromDevice)
    entity.isEnabled = (tick / 2) % 2 == 1
}

/// Holds the latest landmark-annotated camera frame for `PersonaCameraView`.
private final class PersonaPicture: ObservableObject {
    @Published var image: CGImage?
}

/// Starts the Persona camera when the view appears inside an immersive space.
/// When `showPicture` is enabled, renders the live feed overlaid with colored
/// landmark dots (green eyes, red pupils, blue brows, yellow lips, white nose)
/// and a red border when no face is detected.
struct PersonaCameraView: View {
    let persona: PersonaTracking
    let wanted: Bool
    let showPicture: Bool
    /// Optional user face calibration to apply in this space.
    let faceCalibration: FaceCalibration?
    /// Active face calibration state whose instructions are shown above the camera preview.
    var asking: FaceCalibrationRun? = nil
    /// Checked right before starting capture. SwiftUI can recreate this view
    /// while the immersive space is closing, and capture must not restart then.
    var mayStart: () -> Bool = { true }
    @StateObject private var picture = PersonaPicture()

    /// Preview update rate in Hz (the camera captures at 30 fps).
    private static let rate = 10.0

    var body: some View {
        VStack(spacing: 24) {
            if let asking { Instructions(run: asking) }
            if showPicture, let image = picture.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 900)
            }
        }
        .task {
            guard wanted, mayStart() else { return }
            persona.camera.faceCalibration = faceCalibration
            if showPicture {
                let context = CIContext()
                var last: TimeInterval = 0
                persona.camera.onPicture = { [picture] buffer, landmarks in
                    let now = CACurrentMediaTime()
                    guard now - last >= 1 / PersonaCameraView.rate else { return }
                    last = now
                    let image = CIImage(cvPixelBuffer: buffer)
                    guard let plain = context.createCGImage(image, from: image.extent),
                          let marked = PersonaCameraView.mark(plain, landmarks)
                    else { return }
                    DispatchQueue.main.async { picture.image = marked }
                }
            }
            persona.camera.start()
        }
        .onDisappear { persona.camera.onPicture = nil }
    }

    /// Displays the current prompt and progress status during face calibration.
    private struct Instructions: View {
        @ObservedObject var run: FaceCalibrationRun
        var body: some View {
            VStack(spacing: 12) {
                Text(run.prompt).font(.system(size: 64, weight: .bold))
                Text(run.status).font(.system(size: 36))
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(width: 900)
            .glassBackgroundEffect()
        }
    }

    private static func mark(_ picture: CGImage, _ landmarks: [(name: String, points: [LandmarkPoint])]) -> CGImage? {
        let width = picture.width / 2, height = picture.height / 2          // half size is plenty
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        canvas.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        let colors: [String: [CGFloat]] = ["eyes": [0, 1, 0], "pupils": [1, 0, 0], "brows": [0.3, 0.5, 1],
                                            "lips": [1, 1, 0], "nose": [1, 1, 1]]
        let dot = CGFloat(max(3, width / 160))
        for group in landmarks {
            let c = colors[group.name] ?? [1, 1, 1]
            canvas.setFillColor(red: c[0], green: c[1], blue: c[2], alpha: 1)
            for point in group.points {
                // Landmarks and this canvas both count up from the bottom-left corner.
                canvas.fillEllipse(in: CGRect(x: CGFloat(point.x) * CGFloat(width) - dot / 2,
                                              y: CGFloat(point.y) * CGFloat(height) - dot / 2, width: dot, height: dot))
            }
        }
        if landmarks.allSatisfy({ $0.points.isEmpty }) {
            canvas.setStrokeColor(red: 1, green: 0, blue: 0, alpha: 1)
            canvas.setLineWidth(dot * 3)
            canvas.stroke(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return canvas.makeImage()
    }
}
#endif
