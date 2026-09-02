import SwiftUI

// MARK: – The mark
//
// The app icon is a persimmon hanging off a branch, and that drawing is the
// only piece of brand LHF has. This file turns it into a *vector* the UI can
// use at any size, rather than shipping another PNG.
//
// Why redraw it instead of bundling the icon asset:
//
//  - The icon is a 1024pt raster on an opaque cream plate. Dropped into a
//    56pt button it is soft, and its baked-in background fights the warm
//    greige surface it sits on. A path has neither problem.
//  - It has to work in Dark Mode. Every color here goes through
//    `Color.dynamic(light:dark:)` like the rest of `RedesignTokens`, so the
//    fruit warms up and the leaves lift on a charcoal background instead of
//    turning into a dark smudge.
//  - The same mark appears at 22pt (send button), 34pt (hanging suggestion)
//    and 56pt (the dashboard button). One drawing that scales is the only way
//    those stay recognisably the same object.
//
// The one thing a vector must not do is carry all its detail down to 22pt.
// The calyx — five separate olive lobes — becomes mud somewhere around 30pt,
// so `detail` drops it for a single soft crown below that threshold. That is
// a deliberate redraw at small size, not a scaling artifact.

extension Color {
    /// Persimmon flesh. The icon's orange, warmed very slightly in dark mode
    /// so it still reads as fruit rather than as a warning colour.
    static let lhfFruit      = Color.dynamic(light: 0xE0702B, dark: 0xEC8340)
    /// The shaded lower-right cheek. Same hue, driven down in value.
    static let lhfFruitShade = Color.dynamic(light: 0xC55A1C, dark: 0xCC6A2A)
    /// The specular on the upper-left. Near-white in light, but in dark mode a
    /// white highlight blows out, so it is only a lift of the base orange.
    static let lhfFruitLight = Color.dynamic(light: 0xF2A063, dark: 0xF6B37E)
    /// Calyx and leaves. The icon's muted olive.
    static let lhfLeaf       = Color.dynamic(light: 0x5E6B3F, dark: 0x87975C)
    /// Leaf underside / vein, one step down from `lhfLeaf`.
    static let lhfLeafDeep   = Color.dynamic(light: 0x47522F, dark: 0x6B7A48)
    /// Woody branch. Inverted hard for dark mode: near-black wood disappears
    /// on a near-black ground, so the dark value is a pale weathered grey-brown
    /// as if lit from the front.
    ///
    /// The light value is a mid russet rather than the icon's near-black, and
    /// that is a correction made from a device screenshot, not a preference.
    /// The bough is drawn at half opacity over #F4F1EC; blending the icon's
    /// 0x3A3226 at that alpha lands on roughly #979189, which is concrete. A
    /// warmer, lighter, more saturated brown is what survives the blend still
    /// looking like wood — the colour has to be picked for what it becomes at
    /// the opacity it is actually drawn at, not for what it looks like at 100%.
    static let lhfBark       = Color.dynamic(light: 0x6B4A2A, dark: 0xA2937B)
}

/// The persimmon, drawn to fill whatever square it is given.
///
/// `size` is the intended edge length. It is used only to choose the level of
/// detail — the drawing itself is resolution-independent and laid out from the
/// geometry, so this stays honest if the frame ends up a little different.
struct PersimmonMark: View {
    var size: CGFloat
    /// Drives the "picking" animation on the send button: 0 is at rest, 1 is
    /// fully detached and falling away.
    var detach: Double = 0

    /// Below this the five calyx lobes stop being five separate shapes and
    /// start being a green smear, so they collapse into one crown.
    private var wantsFullCalyx: Bool { size >= 30 }
    /// The specular highlight is a light shape on a light shape; under about
    /// 26pt it is a single pale pixel doing nothing but muddying the orange.
    private var wantsHighlight: Bool { size >= 26 }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                fruitBody(s)
                if wantsHighlight { highlight(s) }
                calyx(s)
                stem(s)
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Detaching: the fruit shrinks a touch, drops, and tips over, the
            // way something actually comes off a stem. The rotation is what
            // sells it — a fruit that falls perfectly level reads as a sprite.
            .scaleEffect(1 - 0.15 * detach)
            .offset(y: s * 0.9 * detach)
            .rotationEffect(.degrees(22 * detach))
            .opacity(1 - detach)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    // A persimmon is squat — appreciably wider than it is tall — and sits low
    // in its box because the calyx and stem occupy the top. Both numbers come
    // off the icon rather than from a circle.
    private func fruitBody(_ s: CGFloat) -> some View {
        Ellipse()
            .fill(
                // Light falls from the upper left, so the gradient runs on that
                // diagonal rather than straight down.
                LinearGradient(
                    colors: [.lhfFruit, .lhfFruitShade],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: s * 0.78, height: s * 0.66)
            .offset(y: s * 0.13)
    }

    private func highlight(_ s: CGFloat) -> some View {
        Ellipse()
            .fill(Color.lhfFruitLight)
            .frame(width: s * 0.26, height: s * 0.17)
            .rotationEffect(.degrees(-28))
            .offset(x: -s * 0.16, y: s * 0.02)
            .blur(radius: s * 0.045)
            .opacity(0.75)
    }

    /// The five-lobed cap. Each lobe is the same teardrop rotated around the
    /// top of the fruit; the real one is irregular, so the lobes are given
    /// slightly different lengths to keep it from looking machine-stamped.
    @ViewBuilder
    private func calyx(_ s: CGFloat) -> some View {
        if wantsFullCalyx {
            ZStack {
                ForEach(Array(Self.lobeAngles.enumerated()), id: \.offset) { index, angle in
                    Lobe()
                        .fill(index.isMultiple(of: 2) ? Color.lhfLeaf : Color.lhfLeafDeep)
                        .frame(width: s * 0.30, height: s * Self.lobeLengths[index])
                        .offset(y: -s * 0.09)
                        .rotationEffect(.degrees(angle), anchor: .center)
                }
            }
            .offset(y: -s * 0.04)
        } else {
            // Small-size redraw: one soft crown that reads as "leafy top" at a
            // glance. Five lobes here would be noise.
            Ellipse()
                .fill(Color.lhfLeaf)
                .frame(width: s * 0.42, height: s * 0.20)
                .offset(y: -s * 0.14)
        }
    }

    private func stem(_ s: CGFloat) -> some View {
        Capsule()
            .fill(Color.lhfBark)
            .frame(width: s * 0.075, height: s * 0.17)
            .offset(y: -s * 0.30)
    }

    private static let lobeAngles: [Double] = [0, 72, 144, 216, 288]
    private static let lobeLengths: [CGFloat] = [0.34, 0.30, 0.33, 0.29, 0.32]
}

/// One calyx lobe: a teardrop, wide and round at the base (where it meets the
/// fruit) and drawn to a point at the tip. Two mirrored quadratic curves.
private struct Lobe: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let tip = CGPoint(x: rect.midX, y: rect.minY)
        let base = CGPoint(x: rect.midX, y: rect.maxY)
        p.move(to: base)
        p.addQuadCurve(to: tip, control: CGPoint(x: rect.midX - w * 0.42, y: rect.minY + h * 0.42))
        p.addQuadCurve(to: base, control: CGPoint(x: rect.midX + w * 0.42, y: rect.minY + h * 0.42))
        p.closeSubpath()
        return p
    }
}

#if DEBUG
#Preview("persimmon at every size it ships at") {
    VStack(spacing: 28) {
        HStack(alignment: .bottom, spacing: 26) {
            ForEach([22, 34, 56, 96] as [CGFloat], id: \.self) { s in
                VStack(spacing: 8) {
                    PersimmonMark(size: s).frame(width: s, height: s)
                    Text("\(Int(s))")
                        .font(.lhfSans(10))
                        .foregroundStyle(Color.v2CourseCode)
                }
            }
        }
        PersimmonMark(size: 120).frame(width: 120, height: 120)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.v2Bg)
}
#endif
