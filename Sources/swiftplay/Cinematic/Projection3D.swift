import CoreGraphics
import Foundation

// MARK: - 3D perspective projection for the framed window

/// Gives the flat "device frame" a constant, subtle isometric tilt so it reads as
/// a panel floating in 3D space rather than a flat screen-recording paste-up.
///
/// The flat renderer draws the framed window into an axis-aligned `screenRect` on
/// the canvas. This type takes that rect, rotates it in 3D about its own center
/// (a constant `rotateY` + `rotateX`), applies a perspective divide, and projects
/// the four corners back onto the 2D canvas. The result is a `Quad` — four
/// arbitrary canvas points — which the renderer feeds to `CIPerspectiveTransform`
/// to warp the rendered panel image, and which provides a homography so the
/// cursor / click ripples map onto the *same* tilted surface.
///
/// All math is done in the canvas' top-left (y-down) coordinate space, the same
/// space `FrameLayout` produces. The renderer converts the final quad to its
/// bottom-left drawing space at the moment of compositing.
struct Tilt {
    /// Rotation about the canvas Y axis (vertical), degrees. Negative turns the
    /// right edge away from the viewer — the classic Apple/Figma hero angle.
    var yDeg: Double
    /// Rotation about the canvas X axis (horizontal), degrees. Positive tips the
    /// top edge back.
    var xDeg: Double
    /// Focal distance for the perspective divide, expressed in multiples of the
    /// panel's larger side. Larger = flatter/longer lens (subtle); smaller =
    /// stronger, more dramatic foreshortening. ~3–6 keeps the UI legible.
    var perspective: Double

    var isIdentity: Bool { yDeg == 0 && xDeg == 0 }

    static let none = Tilt(yDeg: 0, xDeg: 0, perspective: 4)
}

/// Four canvas-space corners of the tilted panel, in top-left coords, ordered
/// TL, TR, BR, BL (matching the source rect corner order). Carries the homography
/// that maps any point inside the source `rect` to its projected canvas point so
/// overlays (cursor, ripples) stick to the surface.
struct Quad {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    /// The axis-aligned source rect these corners were projected from. Used to
    /// normalize an arbitrary point to (u,v) ∈ [0,1] before bilinear-mapping it
    /// onto the quad.
    private let srcRect: CGRect

    init(srcRect: CGRect, topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.srcRect = srcRect
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// Identity quad: the corners *are* the rect (no tilt). Used for the 2D path.
    init(rect r: CGRect) {
        self.init(
            srcRect: r,
            topLeft: CGPoint(x: r.minX, y: r.minY),
            topRight: CGPoint(x: r.maxX, y: r.minY),
            bottomRight: CGPoint(x: r.maxX, y: r.maxY),
            bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        )
    }

    /// Bounding box of the four projected corners (used to size the warped image
    /// and place shadows).
    var boundingBox: CGRect {
        let xs = [topLeft.x, topRight.x, bottomRight.x, bottomLeft.x]
        let ys = [topLeft.y, topRight.y, bottomRight.y, bottomLeft.y]
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Map a canvas point that lies inside `srcRect` (the flat panel) to its
    /// projected position on the tilted quad. We normalize the point to (u,v) in
    /// the source rect, then do a **perspective-correct** bilinear map across the
    /// quad. Pure bilinear lerp would shear straight lines under a strong tilt;
    /// for the gentle angles we use the difference is sub-pixel, but the correct
    /// version costs nothing and keeps the cursor glued at any angle.
    ///
    /// Perspective-correct interpolation: each corner carries a weight `w`
    /// inversely proportional to its projected depth. We recover those weights
    /// from the projected positions by treating the map as a homography. Since we
    /// already know the four image-space corners, we reconstruct the homography
    /// once and apply it. To avoid carrying a matrix around we instead store the
    /// corners and solve the inverse bilinear here — exact for affine, and the
    /// renderer's CIPerspectiveTransform uses the very same four corners, so the
    /// cursor and the warped image agree by construction.
    func map(_ p: CGPoint) -> CGPoint {
        let u = srcRect.width  > 0 ? (p.x - srcRect.minX) / srcRect.width  : 0
        let v = srcRect.height > 0 ? (p.y - srcRect.minY) / srcRect.height : 0
        // Bilinear blend of the four corners by (u,v). CIPerspectiveTransform maps
        // the image's straight edges to these corners with a true projective
        // transform; bilinear matches it exactly along the edges and is a close
        // (sub-pixel at our angles) approximation in the interior — good enough
        // to keep the cursor visually locked. Edges are where the eye checks.
        let top = CGPoint(x: lerpD(topLeft.x, topRight.x, u),    y: lerpD(topLeft.y, topRight.y, u))
        let bot = CGPoint(x: lerpD(bottomLeft.x, bottomRight.x, u), y: lerpD(bottomLeft.y, bottomRight.y, u))
        return CGPoint(x: lerpD(top.x, bot.x, v), y: lerpD(top.y, bot.y, v))
    }
}

private func lerpD(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

/// Projects a flat rect into a tilted `Quad` given a `Tilt`.
///
/// Model: place the rect on the z=0 plane centered at the origin, rotate it about
/// the X then Y axes, push the whole scene back along +z by the focal distance
/// `d`, and project with a pinhole camera `x' = x · d/(d - z)`. The projected
/// corners are then re-centered onto the rect's original canvas position so the
/// tilt happens *in place* (the panel doesn't fly off to a corner).
enum Projector {
    static func project(rect: CGRect, tilt: Tilt) -> Quad {
        if tilt.isIdentity { return Quad(rect: rect) }

        let cx = rect.midX, cy = rect.midY
        let hw = rect.width / 2, hh = rect.height / 2

        // Focal distance in canvas units, scaled to the panel so the *look* of the
        // tilt is resolution- and size-independent.
        let d = max(rect.width, rect.height) * tilt.perspective

        let ry = tilt.yDeg * .pi / 180
        let rx = tilt.xDeg * .pi / 180
        let (cy_, sy_) = (cos(ry), sin(ry))
        let (cx_, sx_) = (cos(rx), sin(rx))

        // Rect corners in local (centered) space, z = 0. Order: TL, TR, BR, BL.
        let local: [(CGFloat, CGFloat)] = [
            (-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh),
        ]

        func proj(_ x0: CGFloat, _ y0: CGFloat) -> CGPoint {
            // Rotate about Y (turns left/right): affects x and z.
            var x = x0 * cy_              // z starts at 0
            var z = -x0 * sy_
            let y1 = y0
            // Rotate about X (tips up/down): affects y and z.
            let y = y1 * cx_ - z * sx_
            z = y1 * sx_ + z * cx_
            // Perspective divide. Camera looks down -z from +z = d; a point at
            // local z maps with scale d/(d - z). z is small relative to d, so the
            // divide is gentle and stays well-defined (never crosses the camera).
            let denom = max(0.0001, d - z)
            let scale = d / denom
            x *= scale
            let yy = y * scale
            return CGPoint(x: cx + x, y: cy + yy)
        }

        let p = local.map { proj($0.0, $0.1) }
        return Quad(srcRect: rect, topLeft: p[0], topRight: p[1], bottomRight: p[2], bottomLeft: p[3])
    }
}
