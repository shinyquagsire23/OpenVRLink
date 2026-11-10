// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Where the eyes look and what the face is doing, as the host is told
/// (docs/svl-tracking-input/eye-face.md). One message rides with every pose.

/// Face tracking in the form the host takes: the 70 expression weights of
/// OpenXR's `XR_FB_face_tracking2`, in that extension's order, each 0...1,
/// and how sure the tracker is of the lower and the upper half of the face.
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
    /// The eye message (class 3, type 0x11). `gaze` is the point the eyes
    /// are fixed on, in meters in the head's own frame (x right, y up, z
    /// back): looking straight ahead at something one meter away is
    /// (0, 0, -1). The host aims its sharp foveal picture along it, and
    /// uses the distance to converge the two eyes' pictures. 
    /// Nil says there is no eye tracking.
    /// The expression format byte can be none, or FB face tracking 2's weights.
    static let expressionsNone: UInt8 = 0
    static let expressionsFBFaceTracking2: UInt8 = 2
    /// What vrlink sends as the gaze when it has none.
    static let noGaze = Vec3(0, 0, 1)

    static func message(gaze: Vec3?, face: FaceExpressions?) -> SVLElement {
        var out = Bytes()
        let direction = gaze ?? noGaze
        for value in [direction.x, direction.y, direction.z] { out.append(float: value) }
        out.append(face == nil ? expressionsNone : expressionsFBFaceTracking2)
        out.append(gaze == nil ? 0 : 1)                  // gaze valid
        out.append(face == nil ? 0 : UInt8(FaceExpressions.weightCount))
        out.append(zeros: 2)
        if let face {
            out.append(float: face.lowerFaceConfidence)
            out.append(float: face.upperFaceConfidence)
            for weight in face.weights { out.append(float: weight) }
        }
        return SVLElement(.eyesAndFace, value: out)
    }
}
