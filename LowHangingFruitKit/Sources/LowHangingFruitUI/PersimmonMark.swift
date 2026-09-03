import SwiftUI

// MARK: – The mark
//
// This used to be a hand-drawn vector redraw of the app icon, built entirely
// from `Path`s and `Shape`s so the mark could scale cleanly from the 26pt
// suggestion chip up to 56pt elsewhere in the app. Four separate passes of
// that vector tried to get the calyx — the five-lobed, cream-seamed cap that
// is the one thing that makes this silhouette read as *a persimmon* rather
// than "an orange ball" — to survive down at 26–28pt, and every pass either
// collapsed the lobes into mud or blew the proportions in some other way.
// The actual brand artwork, drawn once by the product owner, already gets
// this right. Redrawing it a fifth time in code was the wrong problem to
// keep solving; this file now crops that artwork down to the mark and ships
// it as `Resources/persimmon.png` instead.
//
// What's in the PNG: just the fruit, its calyx, and the short stub of stem
// where the two meet. The source artwork is a full branch illustration —
// stem, a long bough, and two leaves — sitting on a flat cream plate. The
// branch and leaves are deliberately cropped away: they are fine detail at
// the icon's native resolution, but at the 26–56pt this mark actually ships
// at they'd thin down to an unreadable smear, which is the exact failure
// this file exists to avoid. A persimmon obviously has more plant attached
// to it than this; the crop keeps only the part that still reads as one at
// icon size.
//
// Getting rid of the cream plate behind the fruit was its own small trap.
// The wrong fix — a global colour key that turns every cream-ish pixel
// transparent — looks like the obvious approach and is exactly what breaks
// the calyx: the seams between the five lobes, and the seam between the
// calyx and the fruit underneath it, are drawn in that *same* cream, because
// they're meant to read as a thin painted outline, not as background peeking
// through. A global key punches straight through them and the lobes fuse
// into one shape, which is the one thing this mark cannot afford to lose.
// The asset was instead prepared with a flood fill seeded from the image's
// own border: only cream reachable from *outside* the illustration by a
// connected path of cream becomes transparent. The seams are enclosed by
// olive on every side, are never reachable from the border, and so they
// survive as the opaque cream they always were. The one place that needed a
// second pass on top of the plain border fill was each leaf's own cream
// vein — also fully enclosed, by leaf green rather than by the plate, and
// also not meant to survive once the leaf around it is cropped away; the
// prep script excludes it by checking what ink actually walls a pocket in,
// not just whether it's reachable from the edge. The silhouette's outer
// edge was antialiased by estimating, per edge pixel, how far its colour
// sits between the plate and the shape it borders and using that as a
// fractional alpha, then unpremultiplying — a hard binary cutout there
// leaves a pale cream fringe around the whole shape, which is invisible on
// the light background this was designed against and glows as a visible
// halo the moment it sits on the dark background in Dark Mode.
//
// Dark Mode otherwise needed nothing extra: the artwork is a warm orange and
// olive object with no background of its own left in it, and that sits
// legibly on the app's charcoal ground exactly as printed. The vector
// version's whole reason for per-scheme colour (`Color.dynamic`) was to keep
// the fruit and calyx from fighting a background that changed under them;
// a transparent PNG has no such fight to have.

extension Color {
    /// Calyx and leaves. The icon's muted olive. Still used by
    /// `BranchBackdrop`'s vector twigs and leaves, which have no bitmap
    /// equivalent and so still need a palette.
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

/// The persimmon: the brand artwork's fruit and calyx, cropped to a
/// transparent PNG (`Resources/persimmon.png`) and scaled to fill whatever
/// square it is given.
struct PersimmonMark: View {
    var size: CGFloat
    /// Drives the "picking" animation on the send button: 0 is at rest, 1 is
    /// fully detached and falling away.
    var detach: Double = 0

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            // `bundledImage` returns `Image?` precisely because a missing
            // resource must degrade to an empty mark, not a crash or a
            // visible placeholder box — see `TreeBackdrop.imageLayer` for the
            // same contract.
            if let mark = bundledImage("persimmon", ext: "png") {
                mark
                    .resizable()
                    .scaledToFit()
                    .frame(width: s, height: s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Detaching: the fruit shrinks a touch, drops, and tips
                    // over, the way something actually comes off a stem. The
                    // rotation is what sells it — a fruit that falls
                    // perfectly level reads as a sprite.
                    .scaleEffect(1 - 0.15 * detach)
                    .offset(y: s * 0.9 * detach)
                    .rotationEffect(.degrees(22 * detach))
                    .opacity(1 - detach)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
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
