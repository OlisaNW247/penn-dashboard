import SwiftUI

/// Smooth's app mark: the same full-bleed square artwork the App Store icon
/// ships from (`Resources/smooth-mark.png`, a teal field with the black "S"
/// glyph), clipped in-app to the rounded-square shape iOS itself applies to
/// the home-screen icon so a mark dropped into a notification mock-up or the
/// intro's feature list reads as "the app icon," not as a random square photo.
/// 22.37% of the edge is Apple's own icon corner ratio (HIG's "squircle"),
/// not a rounder or squarer number chosen to taste — matching it is what
/// makes the in-app mark and the real home-screen icon look like the same
/// object at every size this ships at.
///
/// **This applies its own `.frame(width:height:)` on `size`, unlike
/// `PersimmonMark`.** `PersimmonMark`'s `GeometryReader`-based body was built
/// for a mark that had to fill an already-bounded slot cleanly (and its
/// `size:` argument famously does *not* constrain it — see that file's doc
/// comment and the CLAUDE.md trap it left behind). `SmoothAppMark` is built
/// the other way on purpose: the artwork is a plain square, there is no
/// aspect-fit ambiguity to resolve, and every call site benefits more from
/// "pass a size, get exactly that size" than from another view that expands
/// to fill its parent and relies on the caller to also apply a frame. Sizing
/// itself, here, at the source, is what keeps this file from becoming the
/// next entry in that same trap.
struct SmoothAppMark: View {
    var size: CGFloat

    /// Apple's icon corner radius is roughly 22.37% of the icon's edge
    /// length — the ratio behind the "squircle" HIG icons are drawn to,
    /// not a rounder or squarer number chosen to taste.
    private static let cornerRadiusFraction: CGFloat = 0.2237

    private var corner: CGFloat { size * Self.cornerRadiusFraction }

    var body: some View {
        Group {
            if let mark = bundledImage("smooth-mark", ext: "png") {
                mark
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                // A missing bundled resource must degrade to something
                // legible, not a crash or a blank hole where the app's own
                // identity mark should be — this is the one spot in the app
                // that stands in for "what app is this," so unlike
                // `PersimmonMark` (which is free to render nothing) this
                // mark draws a plain branded placeholder instead.
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.smoothCobalt)
                    .overlay(
                        Text("S")
                            .font(.lhfSerif(size * 0.56))
                            .foregroundStyle(Color.smoothPaper)
                    )
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("smooth mark at every size it ships at") {
    VStack(spacing: 28) {
        HStack(alignment: .bottom, spacing: 26) {
            ForEach([29, 34, 52, 64, 96] as [CGFloat], id: \.self) { s in
                VStack(spacing: 8) {
                    SmoothAppMark(size: s)
                    Text("\(Int(s))")
                        .font(.lhfSans(10))
                        .foregroundStyle(Color.v2CourseCode)
                }
            }
        }
        SmoothAppMark(size: 120)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.v2Bg)
}
#endif
