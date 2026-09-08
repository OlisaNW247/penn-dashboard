import SwiftUI

/// The first thing a new user sees after the splash, and before the connect
/// checklist (`OnboardingView`). Three skippable screens that make the pitch
/// before the login ask arrives: the problem (Canvas rewards points as
/// heavily for a four-minute quiz as for a midterm, and those are exactly the
/// ones that get missed), what LHF actually does about it (surfaces the
/// low-hanging fruit before it closes), and — immediately before the
/// checklist opens on "Connect Canvas" — a plain description of how the app
/// works and what it does and doesn't touch, so "you log in on Canvas's own
/// page, there's no LHF server" is the last thing on screen when that ask
/// shows up.
///
/// Shown exactly once, gated on `AppState.hasSeenIntro` (never on
/// `hasCompletedOnboarding`, which the Settings reconnect buttons clear).
///
/// One visual idea carries across all three screens: a set of small
/// "assignment chip" shapes that start scattered and chaotic, gather into a
/// hanging column with the easiest few picked out in green, then settle into
/// a tidy list — literally dramatizing "go get the low hanging fruit." That
/// only works if the chips are the *same* nine views throughout, which is why
/// this file has no `TabView`. `.tabViewStyle(.page(...))` (what the old
/// three-pane intro used) renders every page as its own independent view
/// hierarchy under the hood, so "chip #4 on page 0" and "chip #4 on page 1"
/// would be two unrelated view instances with nothing to tell SwiftUI they're
/// the same element — `matchedGeometryEffect` has nothing to interpolate
/// between, and the chips would simply pop into their new positions when the
/// page changed. That failure is invisible in code review and in a preview,
/// and only shows up as a jump-cut on a real device. The fix is `ChipLayer`:
/// one persistent view, outside the pager, holding one `ForEach` over one
/// array of chip models with stable ids, never torn down. Only each chip's
/// *target frame* changes with `page` (via a `switch` between three mutually
/// exclusive layout functions, all tagged with the same `matchedGeometryEffect`
/// id), which is exactly the case that modifier exists for. Because the three
/// layout branches are mutually exclusive — never more than one mounted at a
/// time — there is never ambiguity about which instance drives the shared
/// geometry, so there's no need to hand-toggle `isSource` between them; the
/// default (`true` on whichever branch happens to exist) is already correct.
/// Paging itself is a plain `DragGesture` plus the Continue button, both
/// driving the same `@State private var page`, so the whole screen — chips,
/// pane text, dots — is one ordinary SwiftUI view tree animated by one
/// ordinary `withAnimation` transaction. That also removes the only iOS-only
/// API this file used to have (`PageTabViewStyle`), so there is nothing here
/// behind `#if os(iOS)` any more: `swift test` compiles this file for macOS
/// too, and it now does so unconditionally.
struct IntroView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var chipSpace

    /// Where the text column currently begins, fed by `TextTopKey` and handed
    /// to `ChipLayer` so no chip can be drawn on top of the copy. `.infinity`
    /// until the first layout pass reports a real value.
    @State private var textTopY: CGFloat = .infinity

    @State private var page = 0

    private static let pageCount = 3
    private var isLastPage: Bool { page == Self.pageCount - 1 }

    /// Extra clearance, beyond whatever the system safe area already reserves
    /// on the top edge, that the chip canvas must never draw above. The
    /// system safe area alone only guarantees clearing the Dynamic Island —
    /// it knows nothing about the skip bar drawn just below it, which is
    /// ordinary content, not a safe-area inset. Sized to comfortably clear
    /// "Skip" (12pt top padding plus a 14pt line) with margin to spare, so a
    /// chip can never render in the same row as the Dynamic Island *or* the
    /// Skip button. See the call site in `body` for why this has to be a
    /// `.padding` stacked with a *partial* `ignoresSafeArea`, not a single
    /// full-bleed frame.
    private static let chipCanvasTopInset: CGFloat = 44

    // MARK: Body

    var body: some View {
        ZStack {
            Color.v2Bg.ignoresSafeArea()

            // The chip layer sits behind the text column and is purely
            // decorative — VoiceOver never lands on it, and it never takes a
            // touch, so the drag gesture below is free to read the whole
            // screen without the chips getting in its way.
            // Ignoring only the horizontal and bottom safe areas — never the
            // top — means the GeometryReader inside ChipLayer is handed a
            // canvas that already starts below the notch or Dynamic Island;
            // stacking `chipCanvasTopInset` on top of that clears the skip
            // bar too, which sits inside the safe area and so isn't
            // accounted for by the safe area alone. Both bugs this fixes
            // (a chip clipped by the Island, a chip crowding Skip) came from
            // the previous bare `.ignoresSafeArea()` here, which bled the
            // chip canvas under everything with no reservation for either.
            // A future "simplification" back to full-bleed would silently
            // reopen both.
            ChipLayer(page: page, namespace: chipSpace, textTopY: textTopY)
                .padding(.top, Self.chipCanvasTopInset)
                .ignoresSafeArea(edges: [.horizontal, .bottom])
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                skipBar
                textColumn
                footer
            }
        }
        // Both halves of the collision measure themselves against this one
        // space: the text column reports its top edge into `TextTopKey`, and
        // `ChipLayer` converts that back into its own local coordinates.
        .coordinateSpace(name: lhfIntroSpace)
        .onPreferenceChange(TextTopKey.self) { textTopY = $0 }
        .frame(maxWidth: 480)
        // A plain horizontal swipe drives paging, in either direction, the
        // same way the old TabView let you drag both ways. `simultaneousGesture`
        // rather than `gesture` so this never steals the vertical scroll a
        // tall pane needs at large Dynamic Type sizes — it only acts once a
        // drag has ended and was clearly more horizontal than vertical.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > abs(dy) else { return }
                    setPage(page + (dx < 0 ? 1 : -1))
                }
        )
    }

    /// Skip lives in the corner rather than under the primary button so it's
    /// reachable from every screen without competing with "Get started" on
    /// the last one, where the two would do exactly the same thing.
    private var skipBar: some View {
        HStack {
            Spacer()
            Button {
                lhfHapticLight()
                state.completeIntro()
            } label: {
                Text("Skip")
                    .font(.lhfSans(14, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("skip the intro")
            .accessibilityHint("goes straight to setup")
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    // MARK: Text column

    /// All three screens' text lives here at once, cross-fading by opacity
    /// rather than being swapped structurally, which is what makes the
    /// transition a crossfade instead of a cut. Because they're stacked in
    /// one `ZStack`, the tallest of the three sets the stack's own height —
    /// which in practice pins every screen's text to the same bottom anchor
    /// rather than letting shorter screens sit lower still, and gives the
    /// crossfade a steady baseline to happen against instead of the text
    /// jumping vertically as the page changes.
    ///
    /// The `GeometryReader` + `ScrollView` + `minHeight` combination is
    /// carried over unchanged from the old file: a paged view won't scroll
    /// its own contents, so this is what keeps the copy reachable instead of
    /// clipped once Dynamic Type pushes it past the available height. The one
    /// change is `alignment: .bottom` instead of the old paired `Spacer`s —
    /// this screen wants its content sitting low, not centered.
    private var textColumn: some View {
        GeometryReader { proxy in
            ScrollView {
                ZStack(alignment: .bottomLeading) {
                    ForEach(0..<Self.pageCount, id: \.self) { index in
                        paneContent(for: index)
                            .opacity(index == page ? 1 : 0)
                            .allowsHitTesting(index == page)
                            .accessibilityHidden(index != page)
                    }
                }
                // Reports the top of the text block so the chips can stay
                // above it. This measures the whole `ZStack`, which is as
                // tall as the *longest* of the three screens rather than the
                // one currently visible, so the boundary is the same on every
                // page. That is deliberate: a boundary that moved as you
                // paged would make the chips jump on a page change, and being
                // conservative by the difference between the longest and
                // shortest copy costs a few points of unused canvas at worst.
                .background(
                    GeometryReader { textProxy in
                        Color.clear.preference(
                            key: TextTopKey.self,
                            value: textProxy.frame(in: .named(lhfIntroSpace)).minY
                        )
                    }
                )
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .frame(minHeight: proxy.size.height, alignment: .bottom)
            }
        }
    }

    @ViewBuilder
    private func paneContent(for index: Int) -> some View {
        switch index {
        case 0: screenOne
        case 1: screenTwo
        default: screenThree
        }
    }

    private var screenOne: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("We kept losing points on the easy stuff.")
                .font(.lhfSerif(34))
                .foregroundStyle(Color.v2Ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("We\u{2019}re two juniors at Penn, so we know what the week before an exam looks like. You study for days, you actually understand the material, and the grade still comes back lower than it should be. Not because of the exam. Because five classes and three clubs meant a reading quiz closed on Sunday night and you never saw it.")
                .font(.lhfSans(16))
                .foregroundStyle(Color.v2DateText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var screenTwo: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Go get the low hanging fruit.")
                .font(.lhfSerif(34))
                .foregroundStyle(Color.v2Ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("Locust is a class assistant that watches the assignments worth the least and forgotten the most. Check-ins, reading responses, the four-minute quiz. Those points are free and they add up faster than any midterm does. Grab them and the rest of your time is yours.")
                .font(.lhfSans(16))
                .foregroundStyle(Color.v2DateText)
                .fixedSize(horizontal: false, vertical: true)

            Text("We built the list we wished we\u{2019}d had.")
                .font(.lhfSerif(19))
                .foregroundStyle(Color.v2SpineGreen)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var screenThree: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How it works")
                .font(.lhfSans(13, weight: .semibold))
                .foregroundStyle(Color.v2CourseCode)

            VStack(alignment: .leading, spacing: 12) {
                listRow("Every assignment from Canvas and Gradescope in one list, ordered by what\u{2019}s due")
                listRow("A nudge when something\u{2019}s close and you haven\u{2019}t submitted")
                listRow("An assistant that answers questions about your classes")
                listRow("Your real grade in every class, and what each assignment is actually worth")
                listRow("You log in on Canvas\u{2019}s own page. No account to make, and there\u{2019}s no Locust server.")
            }

            Text("That\u{2019}s the whole app. Log in and it fills itself in.")
                .font(.lhfSans(15))
                .foregroundStyle(Color.v2Ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            previewLink
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // A baseline-aligned dot instead of a fixed-size icon frame, so
            // the row grows with the text rather than clipping around it.
            Circle()
                .fill(Color.v2SpineGreen)
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { _ in 4 }
                .accessibilityHidden(true)

            Text(text)
                .font(.lhfSans(15))
                .foregroundStyle(Color.v2Ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The reviewer's door. It used to live on the first pane, which stranded
    /// anyone who wanted it the moment they swiped past page one; it now
    /// lives on the last screen, next to "Get started", so it's still there
    /// once someone has read the whole pitch and decided they just want to
    /// look around.
    private var previewLink: some View {
        Button {
            lhfHapticLight()
            state.enterPreviewMode()
        } label: {
            Text("Preview with sample data")
                .font(.lhfSans(14, weight: .medium))
                .foregroundStyle(Color.v2DateText)
                .underline()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("preview the app with sample data")
        .accessibilityHint("explore a demo dashboard without logging in")
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 14) {
            dots

            Button {
                advance()
            } label: {
                Text(isLastPage ? "Get started" : "Continue")
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.v2Ink))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0..<Self.pageCount, id: \.self) { index in
                Circle()
                    .fill(index == page ? Color.v2Ink : Color.v2Ink.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Paging

    private func advance() {
        lhfHapticLight()
        guard !isLastPage else {
            state.completeIntro()
            return
        }
        setPage(page + 1)
    }

    private func setPage(_ target: Int) {
        let clamped = max(0, min(Self.pageCount - 1, target))
        guard clamped != page else { return }
        if reduceMotion {
            page = clamped
        } else {
            withAnimation(.easeInOut(duration: 0.28)) { page = clamped }
        }
    }
}

// MARK: - The text/chip boundary

/// The coordinate space the chip layer and the text column both measure
/// themselves in, so that the two can be compared at all.
private let lhfIntroSpace = "lhfIntroSpace"

/// Publishes the top edge of the text column so `ChipLayer` can keep every
/// chip above it.
///
/// Two earlier passes tried to stop chips landing on the headline by hand
/// tuning the fractions each layout positions against, and both regressed —
/// the second one worse than the first, putting three chips straight through
/// the headline and body of screen two. The reason neither could work is
/// structural: the text column is *bottom* anchored and sized by its own
/// content, so its top edge moves whenever the copy length, the Dynamic Type
/// size or the device changes, while the chip fractions stayed fixed.
/// Nothing connected the two, so any number that looked right in one
/// screenshot was wrong in the next.
///
/// Measuring where the text actually begins and clamping the chips to it
/// makes the overlap structurally impossible rather than merely unlikely,
/// which is what the preference key buys and why it is worth the
/// indirection. The tempting "simplification" here is to delete this and go
/// back to a tuned constant, because on any single screenshot a constant
/// looks identical. It is not identical: it is the bug, reintroduced.
private struct TextTopKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

// MARK: - Chips

/// One decorative "assignment" used only to dramatize the pitch on the intro
/// screens. It never touches real Canvas or Gradescope data, and it isn't
/// shown again once onboarding starts.
///
/// `id` doubles as a fixed "how reachable is this one" rank: 0 is the most
/// reachable of the nine, 8 the least. That ordering is what lets the three
/// layouts agree with each other without any extra bookkeeping — the three
/// lowest ids are the ones the hanging column turns green (screen two), and
/// they're the same three ids promoted to the top rows of the tidy list
/// (screen three). The metaphor is literal: the fruit nearest the ground is
/// both what you'd reach for first and, once picked, the top of your list.
private struct AssignmentChip: Identifiable {
    let id: Int
    let code: String
    let due: String

    /// Only the three "reachable" chips carry one, and it only ever renders
    /// in the page-2 list stage's top rows (see `chipView`'s `isRow` branch).
    /// Giving every chip a title would suggest pages 0 and 1 might grow one
    /// too, which they never do — those stages intentionally show nothing
    /// more than the same small `COURSE · Day` pill throughout.
    let title: String?

    init(id: Int, code: String, due: String, title: String? = nil) {
        self.id = id
        self.code = code
        self.due = due
        self.title = title
    }
}

/// See the note on `IntroView` for why this exists as one persistent layer
/// rather than living inside the pager: chip identity across the three
/// screens depends on it never being rebuilt.
private struct ChipLayer: View {
    let page: Int
    let namespace: Namespace.ID

    /// The text column's top edge, in `lhfIntroSpace`. `.infinity` until the
    /// first measurement lands, which simply means "nothing to avoid yet" —
    /// the clamp below is a no-op at that value, so the first frame renders
    /// exactly as it would have without this and then settles. See
    /// `TextTopKey`.
    let textTopY: CGFloat

    /// Breathing room between the lowest chip and the first line of text.
    /// Chips are positioned by their centre, so this has to cover half a
    /// chip's height plus the gap we actually want to see.
    private static let textClearance: CGFloat = 34

    fileprivate static let chips: [AssignmentChip] = [
        AssignmentChip(id: 0, code: "PHYS 151", due: "Fri", title: "Problem set 3"),
        AssignmentChip(id: 1, code: "PSYC 1010", due: "Mon", title: "Reading response 4"),
        AssignmentChip(id: 2, code: "CIS 1200", due: "Wed", title: "Lab check-in"),
        AssignmentChip(id: 3, code: "ECON 001", due: "Tue"),
        AssignmentChip(id: 4, code: "ENGL 016", due: "Thu"),
        AssignmentChip(id: 5, code: "MATH 114", due: "Fri"),
        AssignmentChip(id: 6, code: "HIST 020", due: "Mon"),
        AssignmentChip(id: 7, code: "STAT 111", due: "Wed"),
        AssignmentChip(id: 8, code: "SPAN 110", due: "Tue"),
    ]

    /// How many of the nine read as "reachable" — green in the column,
    /// promoted to real assignment rows in the final list. Kept as one
    /// constant so the two screens can't quietly disagree about which three
    /// that is.
    private static let reachableCount = 3

    var body: some View {
        GeometryReader { proxy in
            // `textTopY` arrives in `lhfIntroSpace`, but every `.position()`
            // below is in this layer's own local coordinates, which start
            // lower down (the layer is inset past the Dynamic Island and the
            // skip bar). Subtracting this layer's own origin in that shared
            // space converts one to the other. Without the conversion the
            // clamp would be wrong by exactly the inset, which is the kind of
            // off-by-a-safe-area that looks fine on the device you tested.
            let originY = proxy.frame(in: .named(lhfIntroSpace)).minY
            let maxY = max(0, textTopY - Self.textClearance - originY)
            ZStack {
                switch page {
                case 0: scattered(in: proxy.size, maxY: maxY)
                case 1: column(in: proxy.size, maxY: maxY)
                // Page 2's list is measured from the top and already ends
                // well clear of "How it works", so it needs no clamp; adding
                // one would only risk compressing a layout that is correct.
                default: list(in: proxy.size)
                }
            }
            // `.position()` pulls a view out of normal layout flow, so a
            // ZStack containing only positioned children reports almost no
            // size of its own. This frame is what keeps the ZStack (and so
            // the coordinate space every `.position()` call below is
            // computed against) actually equal to the full canvas the
            // GeometryReader was given, rather than collapsing to fit.
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    // MARK: Screen 1 — loose scatter

    /// Hand-placed rather than drawn from `Double.random`: a real RNG
    /// reshuffles on every redraw, and SwiftUI recomputes `body` far more
    /// often than the intro actually changes pages, which would make the
    /// "chaos" visibly jitter instead of holding still. Fixed fractions of
    /// the canvas size give the same restrained scatter every time, while
    /// still landing differently on an iPad than an iPhone SE because
    /// they're fractions of the available size, not fixed points.
    private func scattered(in size: CGSize, maxY: CGFloat) -> some View {
        ForEach(Self.chips) { chip in
            let placement = Self.scatterPlacement[chip.id] ?? (0.5, 0.3, 0)
            chipView(chip, isAccent: false, isRow: false)
                .rotationEffect(.degrees(placement.2))
                .matchedGeometryEffect(id: chip.id, in: namespace)
                .position(
                    x: placement.0 * size.width,
                    // Clamped, not scaled: squashing every chip's fraction to
                    // fit would flatten the scatter into a band and lose the
                    // looseness that is the whole point of this stage. Only
                    // the lowest one or two are ever affected, and they stop
                    // just above the headline rather than moving with it.
                    y: min(placement.1 * size.height, maxY)
                )
        }
    }

    /// (x fraction, y fraction, rotation in degrees) per chip id. A couple sit
    /// past 0 or past 1 on purpose, so they read as clipped by the screen
    /// edge rather than as a tidy grid — restrained chaos, not confetti.
    private static let scatterPlacement: [Int: (CGFloat, CGFloat, Double)] = [
        0: (0.18, 0.16, -11),
        // Was (0.66, 0.10, 8) — high and to the right, which put this chip
        // directly under "Skip" and made the button hard to read against it.
        // Moved lower and more central, clear of the top-right corner Skip
        // occupies.
        1: (0.50, 0.26, 8),
        2: (0.97, 0.24, 14),
        3: (0.02, 0.36, 9),
        4: (0.42, 0.06, -6),
        5: (0.80, 0.30, -10),
        6: (0.30, 0.42, 12),
        7: (0.58, 0.48, -5),
        8: (0.08, 0.52, 6),
    ]

    // MARK: Screen 2 — the hanging column

    /// One vertical column, ordered top-to-bottom from least reachable to
    /// most. Low-hanging fruit is literally the fruit nearest the ground, so
    /// the three lowest ids land at the bottom of the column, closest to the
    /// reader, and are the ones that turn green.
    /// The column used to step down from a fixed `size.height * 0.08` in
    /// fixed 34pt increments regardless of device height, which is what left
    /// a dead band under it on a tall phone: nine chips at 34pt apart run out
    /// of chips long before a Pro-sized screen runs out of room, and the
    /// text below is bottom-anchored (see `textColumn`), so the unused space
    /// landed as a gap between the two rather than at the top or bottom of
    /// the screen. Spacing the column across a fixed *fraction* of the
    /// canvas instead — roughly its top 4% down to its bottom 62% — means it
    /// always ends close to where the text begins, on an SE exactly as much
    /// as on a Pro Max, so column and text read as one composition instead
    /// of two unrelated blocks with a hole between them.
    private func column(in size: CGSize, maxY: CGFloat) -> some View {
        // Unlike the scatter, the column *is* rescaled to fit rather than
        // clamped. Clamping here would pile the bottom chips on top of each
        // other at the boundary, and the column's whole job is to read as an
        // evenly hanging line. Spreading the nine between a fixed top and
        // whatever room is actually left keeps the spacing even on any
        // device, and keeps the bottom of the column near the text instead of
        // leaving the dead band an earlier fixed 34pt step used to.
        let top = size.height * 0.04
        let bottom = min(size.height * 0.62, maxY)
        let step = max(0, bottom - top) / CGFloat(Self.chips.count - 1)
        return ForEach(Self.chips) { chip in
            let depthFromTop = Self.chips.count - 1 - chip.id
            let isAccent = chip.id < Self.reachableCount
            chipView(chip, isAccent: isAccent, isRow: false)
                .matchedGeometryEffect(id: chip.id, in: namespace)
                .position(
                    x: size.width * 0.5,
                    y: top + CGFloat(depthFromTop) * step
                )
        }
    }

    // MARK: Screen 3 — the tidy list

    /// The three chips that were green at the bottom of the column become the
    /// top rows here, rendered the way a real assignment row in the dashboard
    /// looks. The other six stack tighter and smaller underneath them, which
    /// is meant to read as "the list keeps going" rather than as more of the
    /// same three.
    private func list(in size: CGSize) -> some View {
        // The `y` per chip branches on whether it's a top row or a compact
        // one below, which is why that math lives in an ordinary function
        // (`listY`) instead of an `if`/`else` written directly inside this
        // closure: the closure passed to `ForEach` is `@ViewBuilder`, and a
        // plain value-computing `if`/`else` inside a result-builder body gets
        // rewritten as `buildEither` the same as a conditional *view* would,
        // which is not what an `if` assigning to a `CGFloat` means here. The
        // symptom was not "wrong `if`" but an unrelated-looking overload
        // error on `ForEach` itself, because the builder transform broke type
        // inference for the whole closure — a plain function call sidesteps
        // the builder entirely.
        ForEach(Self.chips) { chip in
            chipView(chip, isAccent: false, isRow: chip.id < Self.reachableCount)
                .matchedGeometryEffect(id: chip.id, in: namespace)
                .position(x: size.width * 0.5, y: listY(for: chip, in: size))
        }
    }

    /// Row spacing here is deliberately smaller than it once was. On a
    /// 4.7-inch device (375x667 — an iPhone SE, still a real target) the old
    /// constants (a 0.07 top fraction, 44pt per top row, 24pt per compact
    /// row) left too little of the screen for the "How it works" copy below,
    /// which is inside a `ScrollView` but still needs to be legible above
    /// the fold rather than fighting the chips for space. The three top rows
    /// stay at a spacing that clears their own rendered height (unchanged by
    /// the assignment title added in `chipView` — the title runs inline on
    /// the same line rather than adding a second line, specifically so this
    /// spacing didn't have to grow along with it); the six compact rows
    /// below are allowed to sit close enough to visibly overlap by a couple
    /// of points, which reads as a stack tailing off rather than as a
    /// mistake, and is what actually buys back the room.
    private static let listTopFraction: CGFloat = 0.045
    private static let listTopRowSpacing: CGFloat = 38
    private static let listCompactRowSpacing: CGFloat = 20

    private func listY(for chip: AssignmentChip, in size: CGSize) -> CGFloat {
        if chip.id < Self.reachableCount {
            return size.height * Self.listTopFraction + CGFloat(chip.id) * Self.listTopRowSpacing
        } else {
            let compactIndex = chip.id - Self.reachableCount
            return size.height * Self.listTopFraction
                + CGFloat(Self.reachableCount) * Self.listTopRowSpacing
                + CGFloat(compactIndex) * Self.listCompactRowSpacing
        }
    }

    // MARK: Chip presentation

    private func chipView(_ chip: AssignmentChip, isAccent: Bool, isRow: Bool) -> some View {
        HStack(spacing: 5) {
            // The title only ever shows up in the page-2 list stage's top
            // three rows (`isRow` is only ever `true` there — see `list`),
            // and it runs on the very same line as the code and day rather
            // than stacked above them: that's what makes the difference
            // between "a real assignment row" and "the same chip, bigger"
            // without changing the chip's rendered height at all, which
            // `listY` depends on to keep the three rows from overlapping.
            if isRow, let title = chip.title {
                Text(title)
                    .font(.lhfSans(13, weight: .semibold))
                Text("\u{00B7}")
                    .font(.lhfSans(13))
                    .opacity(0.5)
            }
            Text(chip.code)
                .font(.lhfSans(isRow ? 13 : 11, weight: .semibold))
            Text("\u{00B7}")
                .font(.lhfSans(isRow ? 13 : 11))
                .opacity(0.5)
            Text(chip.due)
                .font(.lhfSans(isRow ? 13 : 11, weight: .medium))
        }
        .foregroundStyle(isAccent ? Color.v2SpineGreen : Color.v2Ink.opacity(isRow ? 1 : 0.75))
        .padding(.horizontal, isRow ? 12 : 9)
        .padding(.vertical, isRow ? 9 : 5)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: isRow ? 11 : 8, style: .continuous)
                .fill(isAccent ? Color.v2SpineGreen.opacity(0.12) : Color.v2Card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: isRow ? 11 : 8, style: .continuous)
                .strokeBorder(isAccent ? Color.v2SpineGreen.opacity(0.45) : Color.v2Ink.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.v2CardShadow.opacity(isRow ? 0.08 : 0.04), radius: isRow ? 3 : 1, y: 1)
    }
}

#if DEBUG
#Preview {
    IntroView()
        .environmentObject(AppState())
        .frame(width: 393, height: 852)
}
#endif
