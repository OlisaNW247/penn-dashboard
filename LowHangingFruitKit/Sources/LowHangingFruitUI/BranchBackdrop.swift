import SwiftUI

// MARK: – The branch
//
// The backdrop of the ask screen: one bough sweeping in from the top right,
// with leaves and a couple of twigs, that the suggested questions hang from.
//
// The important design constraint is that the branch is not wallpaper. The
// suggestion chips have to hang from *it*, on stems that meet the wood where
// the wood actually is, or the whole conceit falls apart and it reads as a
// stock background image with some buttons on top. That means the branch has
// to be a curve the layout can ask questions of — "how far down are you at
// this x?" — rather than a picture.
//
// So the geometry lives in `BranchGeometry` as a plain cubic Bézier in unit
// space, and everything else (the tapered fill, the leaves, the twigs, and
// the stems in `AssistantView`) is derived from it. Change the control points
// and the leaves and the hanging fruit follow.
//
// The taper is the other reason this is a computed path and not a stroked
// one. `Path.stroke` gives a constant width, and a constant-width branch
// looks like a pipe. Walking the curve and offsetting by a width that decays
// toward the tip is a handful of lines and is the difference between "wood"
// and "tube".

/// The bough's centreline, in a unit square, plus the queries the layout needs.
///
/// x runs monotonically from right to left across the curve, which is what
/// makes `y(atX:)` single-valued and therefore answerable at all. If the
/// control points are ever changed so the branch doubles back on itself, that
/// lookup starts returning whichever of the crossings it happens to sample
/// first — so keep the x components ordered.
struct BranchGeometry {
    // Enters off the right edge (so it reads as continuing past the screen
    // rather than starting in mid-air) and exits off the left.
    var p0 = CGPoint(x: 1.12, y: 0.02)
    var p1 = CGPoint(x: 0.74, y: 0.21)
    var p2 = CGPoint(x: 0.38, y: 0.26)
    var p3 = CGPoint(x: -0.10, y: 0.44)

    /// Thickest half-width, as a fraction of the drawing's width, at the
    /// trunk end.
    var baseHalfWidth: CGFloat = 0.017

    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(
            x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
            y: a * p0.y + b * p1.y + c * p2.y + d * p3.y
        )
    }

    /// Unnormalised tangent — the Bézier's first derivative.
    func tangent(at t: CGFloat) -> CGVector {
        let u = 1 - t
        let a = 3 * u * u, b = 6 * u * t, c = 3 * t * t
        return CGVector(
            dx: a * (p1.x - p0.x) + b * (p2.x - p1.x) + c * (p3.x - p2.x),
            dy: a * (p1.y - p0.y) + b * (p2.y - p1.y) + c * (p3.y - p2.y)
        )
    }

    /// Half-width at `t`: fat at the trunk, drawn to a point at the tip. The
    /// exponent below 1 keeps it thick for most of its run and then tapers
    /// quickly, which is how a real bough narrows — a linear taper looks like
    /// a wedge.
    func halfWidth(at t: CGFloat) -> CGFloat {
        baseHalfWidth * pow(max(0, 1 - t), 0.62) + 0.0012
    }

    /// Where the branch sits vertically at a given horizontal position, both
    /// in unit space. Returns nil when `x` is off the ends of the curve.
    ///
    /// Solved by sampling rather than algebraically: a cubic has a closed-form
    /// root but three of them, and picking the right one is more code and more
    /// ways to be wrong than walking 240 samples of a curve that is already
    /// monotonic in x. This runs once per suggestion, not per frame.
    func unitY(atX x: CGFloat) -> CGFloat? {
        let steps = 240
        var previous = point(at: 0)
        guard x <= previous.x else { return nil }
        for i in 1...steps {
            let current = point(at: CGFloat(i) / CGFloat(steps))
            if x >= current.x && x <= previous.x {
                // Linear interpolation between the two straddling samples. Over
                // a 1/240th slice of a smooth curve the error is invisible.
                let span = previous.x - current.x
                let f = span < 0.00001 ? 0 : (previous.x - x) / span
                return previous.y + (current.y - previous.y) * f
            }
            previous = current
        }
        return nil
    }

    /// A filled outline of the bough, built by walking one edge out and the
    /// other back.
    func taperedPath(in rect: CGRect) -> Path {
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
        }
        let steps = 96
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let centre = map(point(at: t))
            let tan = tangent(at: t)
            // Scale the tangent into the drawing's aspect before normalising,
            // otherwise the normal is skewed wherever the rect is not square
            // and the branch develops a pinch.
            let dx = tan.dx * rect.width
            let dy = tan.dy * rect.height
            let len = max(0.00001, sqrt(dx * dx + dy * dy))
            let nx = -dy / len, ny = dx / len
            let hw = halfWidth(at: t) * rect.width
            left.append(CGPoint(x: centre.x + nx * hw, y: centre.y + ny * hw))
            right.append(CGPoint(x: centre.x - nx * hw, y: centre.y - ny * hw))
        }
        // One continuous subpath, built by hand.
        //
        // The obvious spelling — `addLines(left)` then `addLines(right)` — is
        // wrong, and wrong in a way that still draws something, which is why it
        // survived until a device screenshot. `Path.addLines` *moves* to its
        // first point rather than connecting from the current one, so those two
        // calls produce two separate open polylines instead of one outline.
        // Filling that gives two zero-area slivers: the branch rendered as a
        // pair of hairlines with the page showing between them, which at a
        // glance reads as a pale branch with dark edges rather than as nothing
        // at all. Walking the second edge with explicit `addLine(to:)` is what
        // makes the outline a single closed region the fill can actually take.
        var p = Path()
        guard let start = left.first else { return p }
        p.move(to: start)
        for point in left.dropFirst() { p.addLine(to: point) }
        for point in right.reversed() { p.addLine(to: point) }
        p.closeSubpath()
        return p
    }
}

/// The full backdrop: bough, twigs and leaves, drawn to fill its frame.
///
/// `wash` is the master opacity. The ask screen animates it from a present,
/// scene-setting 0.5 down to a faint 0.12 the moment the first question is
/// asked, so the conversation reads over the top of the tree instead of
/// fighting it.
struct BranchBackdrop: View {
    var geometry = BranchGeometry()
    var wash: Double = 0.5

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let bark = Color.lhfBark

            context.opacity = wash
            context.fill(geometry.taperedPath(in: rect), with: .color(bark))

            for twig in Self.twigs {
                context.fill(twig.path(from: geometry, in: rect), with: .color(bark))
            }
            for leaf in Self.leaves {
                draw(leaf, in: &context, rect: rect)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ leaf: LeafPlacement, in context: inout GraphicsContext, rect: CGRect) {
        let anchor = geometry.point(at: leaf.t)
        let origin = CGPoint(x: rect.minX + anchor.x * rect.width,
                             y: rect.minY + anchor.y * rect.height)
        let length = leaf.length * rect.width
        let width = length * 0.46

        // Leaves are drawn in their own upright box and then rotated into
        // place, which keeps the shape itself trivial.
        let box = CGRect(x: -width / 2, y: -length, width: width, height: length)
        var blade = Path()
        blade.move(to: CGPoint(x: box.midX, y: box.maxY))
        blade.addQuadCurve(to: CGPoint(x: box.midX, y: box.minY),
                           control: CGPoint(x: box.minX - width * 0.05, y: box.midY))
        blade.addQuadCurve(to: CGPoint(x: box.midX, y: box.maxY),
                           control: CGPoint(x: box.maxX + width * 0.05, y: box.midY))
        blade.closeSubpath()

        var vein = Path()
        vein.move(to: CGPoint(x: box.midX, y: box.maxY - length * 0.06))
        vein.addLine(to: CGPoint(x: box.midX, y: box.minY + length * 0.10))

        context.drawLayer { layer in
            layer.translateBy(x: origin.x, y: origin.y)
            layer.rotate(by: .degrees(leaf.angle))
            layer.fill(blade, with: .color(leaf.dark ? .lhfLeafDeep : .lhfLeaf))
            layer.stroke(vein, with: .color(.lhfBark.opacity(0.35)),
                         lineWidth: max(0.6, length * 0.018))
        }
    }

    /// Leaves hang off both sides at irregular intervals. The angles are set
    /// by hand rather than from the tangent: leaves that all sit at a uniform
    /// angle to the bough look like a fern, and real ones catch the light at
    /// whatever angle they grew.
    private static let leaves: [LeafPlacement] = [
        LeafPlacement(t: 0.14, angle: 128, length: 0.20, dark: false),
        LeafPlacement(t: 0.27, angle: -142, length: 0.17, dark: true),
        LeafPlacement(t: 0.43, angle: 116, length: 0.21, dark: false),
        LeafPlacement(t: 0.58, angle: -128, length: 0.16, dark: true),
        LeafPlacement(t: 0.72, angle: 138, length: 0.18, dark: false),
        LeafPlacement(t: 0.88, angle: -150, length: 0.13, dark: true),
    ]

    /// Two short offshoots, each a straight tapered spur from a point on the
    /// bough. Enough to break the single-arc silhouette.
    private static let twigs: [Twig] = [
        Twig(t: 0.30, angle: -58, length: 0.115, halfWidth: 0.0050),
        Twig(t: 0.62, angle: 34, length: 0.085, halfWidth: 0.0038),
    ]

    struct LeafPlacement {
        var t: CGFloat
        var angle: Double
        var length: CGFloat
        var dark: Bool
    }

    struct Twig {
        var t: CGFloat
        var angle: Double
        var length: CGFloat
        var halfWidth: CGFloat

        func path(from geometry: BranchGeometry, in rect: CGRect) -> Path {
            let anchor = geometry.point(at: t)
            let radians = angle * .pi / 180

            // Sprout from the *edge* of the bough on the side the spur points,
            // not from its centreline. Starting at the centre put half of each
            // wedge inside the branch, and because the wedge is symmetric the
            // far half emerged through the opposite side — on device the two
            // twigs read as splinters driven through the wood rather than as
            // offshoots. Pushing the origin out by the bough's own half-width
            // at that t is what makes them grow out of it.
            let offset = geometry.halfWidth(at: t) * rect.width * 0.8
            let origin = CGPoint(
                x: rect.minX + anchor.x * rect.width + cos(radians) * offset,
                y: rect.minY + anchor.y * rect.height + sin(radians) * offset
            )
            let len = length * rect.width
            let tip = CGPoint(x: origin.x + cos(radians) * len,
                              y: origin.y + sin(radians) * len)
            let hw = halfWidth * rect.width
            // Perpendicular to the spur, so the wedge is symmetric about it.
            let nx = -sin(radians) * hw, ny = cos(radians) * hw
            var p = Path()
            p.move(to: CGPoint(x: origin.x + nx, y: origin.y + ny))
            p.addLine(to: tip)
            p.addLine(to: CGPoint(x: origin.x - nx, y: origin.y - ny))
            p.closeSubpath()
            return p
        }
    }
}

#if DEBUG
#Preview("branch backdrop") {
    ZStack {
        Color.v2Bg
        BranchBackdrop(wash: 0.5)
        BranchBackdrop(wash: 0.12).offset(y: 300)
    }
    .ignoresSafeArea()
}
#endif
