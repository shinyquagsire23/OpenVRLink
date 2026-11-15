// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Eye gaze and face expression serialization for the SVL tracking stream
/// (docs/svl-tracking-input/eye-face.md). Sent alongside each pose update.

/// Face tracking state formatted for the host: 70 expression weights in
/// `XR_FB_face_tracking2` order (`0...1`), plus upper- and lower-face tracking confidences.
public struct FaceExpressions {
    public static let weightCount = 70
    public var weights: [Float]
    public var lowerFaceConfidence: Float
    public var upperFaceConfidence: Float

    public init(weights: [Float], lowerFaceConfidence: Float = 1, upperFaceConfidence: Float = 1) {
        precondition(weights.count == FaceExpressions.weightCount)
        self.weights = weights
        self.lowerFaceConfidence = lowerFaceConfidence
        self.upperFaceConfidence = upperFaceConfidence
    }
}

enum EyesAndFace {
    /// Expression format IDs in the eye/face message header.
    static let expressionsNone: UInt8 = 0
    static let expressionsFBFaceTracking2: UInt8 = 2
    /// Placeholder gaze vector sent by `vrlink` when eye tracking is unavailable.
    static let noGaze = Vec3(0, 0, 1)

    /// Builds an eye and face tracking message (class 3, type 0x11). `gaze` is the 3D fixation
    /// point in meters in head space (+X right, +Y up, +Z backward, so looking straight ahead at
    /// 1 m is `(0, 0, -1)`), or `nil` when eye tracking is unavailable. The host uses `gaze`
    /// both to steer foveated encoding and to set stereo convergence distance.
    static func message(gaze: Vec3?, face: FaceExpressions?) -> SVLElement {
        var out = Bytes()
        let direction = gaze ?? noGaze
        for value in [direction.x, direction.y, direction.z] { out.append(float: value) }
        out.append(face == nil ? expressionsNone : expressionsFBFaceTracking2)
        out.append(gaze == nil ? 0 : 1)                  // gaze valid
        out.append(face == nil ? 0 : UInt8(FaceExpressions.weightCount))
        out.append(zeros: 2)
        // Confidence fields are always present and set to zero when face tracking is absent.
        out.append(float: face?.lowerFaceConfidence ?? 0)
        out.append(float: face?.upperFaceConfidence ?? 0)
        if let face {
            for weight in face.weights { out.append(float: weight) }
            // vrlink 2.0.25 pads the payload with 8 trailing zero bytes after the weights.
            out.append(zeros: 8)
        }
        return SVLElement(.eyesAndFace, value: out)
    }
}
