import SwiftUI

// MARK: – The tree
//
// The ask screen's backdrop used to be drawn: a rooted trunk, six boughs and
// a leaf canopy, built entirely out of `BranchGeometry` cubic Béziers so the
// suggestion chips could hang from an actual queryable branch tip
// (`point(at: 1.0)`). The product owner has since supplied a real
// illustration of the same idea — trunk, root flare, canopy, a few hanging
// fruit — and this file now just places that image rather than drawing one
// of its own.
//
// That trade loses something real, which is worth naming rather than
// glossing over: a raster has no branch tips to ask for. The old
// `TreeGeometry` derived every chip's hanging point from the limb that was
// actually drawn, so a control-point nudge to fix how a bough looked could
// never silently detach a chip from the wood — the two were the same
// number. There is no equivalent guarantee here; the four y-fractions below
// are eyeballed against the illustration and will drift out of register with
// it if the artwork is ever swapped for a differently-proportioned tree. See
// `SuggestionSlot` for what replaced the derivation.

/// Where a suggestion chip sits in the ask screen's content area, in unit
/// space (0…1 of the backdrop's frame, y increasing downward), plus which
/// side of the screen it hangs against.
///
/// This used to be called `TreeAnchor` and carry a full `CGPoint`, back when
/// each chip hung from a specific branch tip drawn by `TreeGeometry` and
/// needed both an x and a y to say where that tip was. The backdrop is now a
/// bundled illustration with no queryable branch tips, and the chips no
/// longer hang from a point on the tree at all — they sit flush against a
/// screen edge (see `AssistantView.hangingSuggestions`), so the only
/// position left to carry is how far down the page. Keeping the old name and
/// shape here — an `x` nobody reads, an `id`/`growsRight` pair called an
/// "anchor" when nothing is anchored to anything — would be a name that lies
/// about what the value means, which the project's own conventions rate as
/// worse than the churn of renaming.
struct SuggestionSlot: Identifiable {
    let id: Int
    /// How far down the content area this chip sits, as a fraction of its
    /// height.
    var y: CGFloat
    /// `true` for chips that sit against the left edge (fruit leading, text
    /// running right); `false` for the mirror image against the right edge.
    var growsRight: Bool
}

/// The table of where the four suggestion chips sit on the ask screen's
/// empty state. `TreeGeometry` used to also be the tree's entire vector
/// skeleton — trunk, root flare, six boughs, all built from `BranchGeometry`
/// — because the backdrop was drawn and the chip positions had to be read
/// back off the actual drawing. Now that the backdrop is a bundled image
/// (see `TreeBackdrop` below), none of that skeleton draws anything any
/// more, and keeping it around would be Bézier machinery describing a tree
/// this file no longer renders. What's left is only the layout table the ask
/// screen still needs.
struct TreeGeometry {
    /// The four chip slots, top to bottom, alternating sides — a zigzag down
    /// the page rather than a stack on one side, echoing the way the old
    /// branch tips alternated left and right up the trunk. The y-fractions
    /// are a plain, even spread (0.10, 0.32, 0.54, 0.76); they no longer need
    /// to line up with any particular drawn feature; they only need to sit
    /// over the canopy portion of the illustration rather than, say, the bare
    /// trunk or the roots.
    var slots: [SuggestionSlot] = [
        SuggestionSlot(id: 0, y: 0.10, growsRight: true),
        SuggestionSlot(id: 1, y: 0.32, growsRight: false),
        SuggestionSlot(id: 2, y: 0.54, growsRight: true),
        SuggestionSlot(id: 3, y: 0.76, growsRight: false),
    ]
}

/// The tree, drawn by placing the bundled illustration rather than by
/// vector shapes.
///
/// `wash` is the master opacity, exactly as it was for the drawn version:
/// the ask screen animates it from a present, scene-setting value down to a
/// faint one once the conversation is under way, so the tree recedes behind
/// the transcript instead of competing with it. What changed is only how the
/// tree itself gets to the screen.
struct TreeBackdrop: View {
    var geometry = TreeGeometry()
    var wash: Double = 0.5

    @Environment(\.colorScheme) private var colorScheme

    /// The illustration is bright — a full-colour canopy and trunk — against
    /// a light warm greige ground (`Color.v2Bg`, `0xF4F1EC`). At the very
    /// same numeric opacity it reads noticeably heavier sitting on the dark
    /// scheme's near-black ground (`0x1C1A17`), the way any bright image
    /// does against a darker field the eye is already adapted to. Backing
    /// the dark-mode wash off by roughly a fifth is a first estimate to
    /// compensate, reasoned from that contrast difference rather than
    /// measured — it has not been checked on an actual device yet, which
    /// this project's own history says matters (see `BranchBackdrop`'s
    /// `addLines` note: a rendering choice can look fine in a preview and
    /// only read as wrong on a screen). Treat this multiplier as a hook to
    /// adjust once someone has looked at both schemes side by side on
    /// hardware, not as a settled number.
    private var effectiveWash: Double {
        colorScheme == .dark ? wash * 0.8 : wash
    }

    var body: some View {
        GeometryReader { proxy in
            imageLayer
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The illustration itself, or nothing at all if the asset failed to
    /// load. `bundledImage` returns `Image?` precisely because a missing
    /// resource must degrade to an empty backdrop, not a crash or a visible
    /// placeholder box — the ask screen still has to work, chips and all,
    /// with no tree behind it.
    ///
    /// `.fit`, not `.fill`. The artwork is close to square (1190×1322) and
    /// the content area it sits in is a tall phone column, so filling meant
    /// scaling until the *height* matched and throwing away about a tenth of
    /// the width off each side — which is precisely where this tree keeps its
    /// outermost boughs and its widest root flare. The crop took the two
    /// things that make the silhouette read as a whole tree rather than as a
    /// trunk. Fitting shows all of it, at the cost of some empty ground above
    /// and below; on a backdrop this faint that emptiness costs nothing,
    /// where the missing branch tips cost the whole shape.
    @ViewBuilder
    private var imageLayer: some View {
        if let tree = bundledImage("thetree", ext: "png") {
            tree
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(effectiveWash)
        }
    }
}

#if DEBUG
#Preview("tree backdrop") {
    ZStack {
        Color.v2Bg
        TreeBackdrop(wash: 0.5)
    }
    .ignoresSafeArea()
}

#Preview("tree backdrop, faint") {
    ZStack {
        Color.v2Bg
        TreeBackdrop(wash: 0.12)
    }
    .ignoresSafeArea()
}
#endif
