import SwiftUI

/// The first thing a new user sees after the splash, and before the connect
/// checklist (`OnboardingView`). Three skippable screens that make the pitch
/// before the login ask arrives: the problem (Canvas rewards points as
/// heavily for a four-minute quiz as for a midterm, and those are exactly the
/// ones that get missed), what Smooth actually does about it (turns scattered
/// work into a clear class-to-assignment list), and — immediately before the
/// checklist opens on "Connect Canvas" — a compact overview of the four parts
/// of the app, using miniatures of the real dashboard, notification, assistant,
/// and Grade Watcher UI.
///
/// Shown exactly once, gated on `AppState.hasSeenIntro` (never on
/// `hasCompletedOnboarding`, which the Settings reconnect buttons clear).
///
/// One visual idea carries across the first two screens: a set of small
/// assignment chips starts scattered and chaotic, then resolves into explicit
/// `CLASS → Assignment` rows. The third screen replaces that illustration with
/// four slim feature snapshots. The morph between the first two screens
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

    @State private var page: Int = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-LHFIntroPage"),
           arguments.indices.contains(flag + 1),
           let requested = Int(arguments[flag + 1]) {
            return max(0, min(2, requested))
        }
        #endif
        return 0
    }()

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
                .opacity(page < 2 ? 1 : 0)
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
                finishIntro()
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

    /// The `GeometryReader` + `ScrollView` + `minHeight` combination is
    /// carried over unchanged from the old file: a paged view won't scroll
    /// its own contents, so this is what keeps the copy reachable instead of
    /// clipped once Dynamic Type pushes it past the available height. The one
    /// change is `alignment: .bottom` instead of the old paired `Spacer`s —
    /// this screen wants its content sitting low, not centered.
    private var textColumn: some View {
        GeometryReader { proxy in
            ScrollView {
                paneContent(for: page)
                .id(page)
                // Reports the top of the text block so the chips can stay
                // above it on the two illustrated pages.
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
                .frame(
                    minHeight: proxy.size.height,
                    alignment: page == 2 ? .center : .bottom
                )
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
        Text("We kept losing points on the easy stuff.")
            .font(.lhfSerif(34))
            .foregroundStyle(Color.v2Ink)
            .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var screenTwo: some View {
        Text("Go get the low hanging fruit.")
            .font(.lhfSerif(34))
            .foregroundStyle(Color.v2Ink)
            .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var screenThree: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How Smooth keeps you ahead.")
                .font(.lhfSerif(30))
                .foregroundStyle(Color.v2Ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                compactFeatureRow(label: "Dashboard", symbol: "rectangle.grid.1x2") {
                    VStack(spacing: 5) {
                        compactAssignment(course: "CIS 1200", title: "Homework 4", due: Date().addingTimeInterval(3 * 3_600))
                        compactAssignment(course: "MATH 1410", title: "Written assignment", due: Date().addingTimeInterval(3 * 86_400))
                    }
                }

                compactFeatureRow(label: "Reminders", symbol: "bell.badge") {
                    compactNotification
                }

                compactFeatureRow(label: "Ask", symbol: "sparkles") {
                    compactAskPrompt
                }

                compactFeatureRow(label: "Grades", symbol: "chart.line.uptrend.xyaxis") {
                    compactGrade
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactFeatureRow<Content: View>(
        label: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 24, height: 24)
                Text(label)
                    .font(.lhfSans(14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.v2Ink)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: Color.v2CardShadow.opacity(0.07), radius: 5, y: 2)
        .accessibilityElement(children: .combine)
    }

    /// A miniature of `AssignmentCardView`'s own recipe — pastel fill keyed
    /// off the due date, mono course code in that date's ink partner, the
    /// assignment title in `lhfAssignmentTitle`, compact due value at the
    /// trailing edge — rather than a bespoke illustration style. The point of
    /// this feature preview is "this is what your dashboard actually looks
    /// like," so it draws from the same due-date functions the real card
    /// does (`smoothTaskFill`, `smoothTaskTextAccent`, `smoothDueValue`)
    /// instead of a caller-chosen flat color and a hand-typed due string,
    /// which is also why there is no colored spine here any more — the real
    /// card doesn't have one either.
    private func compactAssignment(course: String, title: String, due: Date?) -> some View {
        let now = Date()
        let value = smoothDueValue(due, now: now)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(course.uppercased())
                    .font(.lhfMono(8.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(smoothTaskTextAccent(due, now: now))
                Text(title)
                    .font(.lhfAssignmentTitle(13))
                    .foregroundStyle(Color.smoothInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            Text(value.primary)
                .font(.lhfMono(11, weight: .medium))
                .foregroundStyle(Color.smoothInk)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(smoothTaskFill(due, now: now), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var compactNotification: some View {
        HStack(alignment: .top, spacing: 7) {
            SmoothAppMark(size: 29)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("SMOOTH")
                        .font(.lhfSans(9.5, weight: .semibold))
                        .tracking(0.6)
                    Spacer()
                    Text("now")
                        .font(.lhfSans(9.5))
                        .foregroundStyle(Color.v2DateText)
                }
                Text("CIS 1200 · Homework 4")
                    .font(.lhfSans(12, weight: .semibold))
                    .foregroundStyle(Color.v2Ink)
                Text("Unsubmitted · due in 2 hours")
                    .font(.lhfSans(10.5))
                    .foregroundStyle(Color.v2DateText)
            }
        }
        .padding(10)
        .background(Color.v2Bg.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var compactAskPrompt: some View {
        ZStack {
            LinearGradient(
                colors: [Color.smoothGrape.opacity(0.12), Color.smoothTeal.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HStack(spacing: 6) {
                SmoothStarMark(size: 25)
                Text("what is the attendance policy for this class?")
                    .font(.lhfSerif(13))
                    .foregroundStyle(Color.v2Ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(Color.v2Card, in: Capsule())
            .shadow(color: Color.v2CardShadow.opacity(0.13), radius: 4, y: 1)
        }
        .frame(height: 70)
        .clipped()
    }

    private var compactGrade: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ECON 0100")
                .font(.lhfSans(9, weight: .medium))
                .tracking(1)
                .foregroundStyle(Color.v2CourseCode)
            HStack(alignment: .center, spacing: 7) {
                Text("93.4%")
                    .font(.lhfSerif(26))
                    .foregroundStyle(Color.v2Ink)
                Text("▲ 1.8 this week")
                    .font(.lhfSans(9.5, weight: .semibold))
                    .foregroundStyle(Color.smoothTeal)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.v2RingTrack)
                    Capsule().fill(Color.smoothCobalt)
                        .frame(width: geo.size.width * 0.72)
                }
            }
            .frame(height: 5)
            Text("72% decided")
                .font(.lhfSans(9.5))
                .foregroundStyle(Color.v2RingSub)
        }
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
                    .fill(index == page ? Color.v2Ink : Color.v2DateText.opacity(0.45))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Paging

    private func advance() {
        lhfHapticLight()
        guard !isLastPage else {
            finishIntro()
            return
        }
        setPage(page + 1)
    }

    private func finishIntro() {
        if reduceMotion {
            state.completeIntro()
        } else {
            withAnimation(.easeInOut(duration: 0.24)) {
                state.completeIntro()
            }
        }
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
/// lowest ids are the ones the hanging column marks "reachable" (screen two,
/// `ChipLayer.reachableCount`), and they're the same three ids that land at
/// the top of the tidy list, since it's laid out in id order. Post-Smooth,
/// "reachable" isn't one fixed color any more — every chip keeps the ramp
/// tone it's cycled onto by id (`ChipLayer.tone(for:)`), the same tone on
/// both screens it appears on, and the reachable three are marked by
/// wearing their own tone harder (deeper fill, firmer border) rather than by
/// switching to a color borrowed from outside the ramp. The metaphor is
/// literal: the fruit nearest the ground is both what you'd reach for first
/// and, once picked, the top of your list.
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
/// rather than living inside the pager: chip identity across the first two
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
        AssignmentChip(id: 3, code: "ECON 001", due: "Tue", title: "Weekly quiz"),
        AssignmentChip(id: 4, code: "ENGL 016", due: "Thu", title: "Discussion post"),
        AssignmentChip(id: 5, code: "MATH 114", due: "Fri", title: "Problem set 6"),
        AssignmentChip(id: 6, code: "HIST 020", due: "Mon", title: "Primary source notes"),
        AssignmentChip(id: 7, code: "STAT 111", due: "Wed", title: "Lab check-in"),
        AssignmentChip(id: 8, code: "SPAN 110", due: "Tue", title: "Vocabulary quiz"),
    ]

    /// How many of the nine read as "reachable" — highlighted in the column,
    /// promoted to real assignment rows in the final list. Kept as one
    /// constant so the two screens can't quietly disagree about which three
    /// that is.
    private static let reachableCount = 3

    /// The Smooth due-date ramp, cycled by chip id rather than by due state —
    /// these nine chips are illustration, not real deadlines, so there is no
    /// `Date` to derive `smoothTaskAccent` from. Cycling by id instead of
    /// picking one flat color keeps every chip visually distinct, which is
    /// the whole point of a "scattered work" illustration, and keeps the
    /// same chip roughly the same hue across screens 1 and 2 — the two
    /// stages a `matchedGeometryEffect` id actually carries across.
    private static let ramp: [(fill: Color, ink: Color)] = [
        (.smoothTomato, .smoothTomatoInk),
        (.smoothMarigold, .smoothMarigoldInk),
        (.smoothLemon, .smoothLemonInk),
        (.smoothTeal, .smoothTealInk),
        (.smoothCobalt, .smoothCobaltInk),
        (.smoothGrape, .smoothGrapeInk),
    ]

    private static func tone(for chip: AssignmentChip) -> (fill: Color, ink: Color) {
        ramp[chip.id % ramp.count]
    }

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
                default: organized(in: proxy.size, maxY: maxY)
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

    // MARK: Screen 2 — class to assignment

    /// The same nine chips settle into an explicit class-to-assignment list.
    /// The arrow is the explanation: students can see immediately that Smooth
    /// turns scattered course obligations into named work, without a paragraph
    /// below the illustration having to narrate it.
    private func organized(in size: CGSize, maxY: CGFloat) -> some View {
        let top = size.height * 0.04
        let bottom = min(size.height * 0.78, maxY)
        let step = max(0, bottom - top) / CGFloat(Self.chips.count - 1)
        return ForEach(Self.chips) { chip in
            let isAccent = chip.id < Self.reachableCount
            assignmentRow(chip, isAccent: isAccent, width: min(350, size.width - 32))
                .matchedGeometryEffect(id: chip.id, in: namespace)
                .position(
                    x: size.width * 0.5,
                    y: top + CGFloat(chip.id) * step
                )
        }
    }

    // MARK: Chip presentation

    private func chipView(_ chip: AssignmentChip, isAccent: Bool, isRow: Bool) -> some View {
        let tone = Self.tone(for: chip)
        return HStack(spacing: 5) {
            Text(chip.code)
                .font(.lhfMono(isRow ? 13 : 11, weight: .semibold))
            Text("\u{00B7}")
                .font(.lhfSans(isRow ? 13 : 11))
                .opacity(0.5)
            Text(chip.due)
                .font(.lhfSans(isRow ? 13 : 11, weight: .medium))
        }
        .foregroundStyle(tone.ink)
        .padding(.horizontal, isRow ? 12 : 9)
        .padding(.vertical, isRow ? 9 : 5)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: isRow ? 11 : 8, style: .continuous)
                // The same opacity `smoothTaskFill` draws real dashboard
                // cards at, so a scattered chip reads as the same visual
                // family as the assignment cards it is foreshadowing.
                .fill(tone.fill.opacity(0.26))
        )
        .overlay(
            RoundedRectangle(cornerRadius: isRow ? 11 : 8, style: .continuous)
                .strokeBorder(tone.fill.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: Color.v2CardShadow.opacity(isRow ? 0.08 : 0.04), radius: isRow ? 3 : 1, y: 1)
    }

    /// `isAccent` (the three "reachable" chips) used to be the only source of
    /// color here — a plain grey row for six chips, a green one for three.
    /// Every row now carries its own ramp tone (see `Self.tone`), the same
    /// one it wore as a scattered chip on screen one, so the "reachable"
    /// three no longer need to borrow the one spare accent color to stand
    /// out — instead they keep their own hue but wear it harder (deeper
    /// fill, firmer border) than the rest of the list, which is what
    /// actually reads as "these are the ones," in the same palette the rest
    /// of the row is drawn from rather than a color borrowed from outside it.
    private func assignmentRow(_ chip: AssignmentChip, isAccent: Bool, width: CGFloat) -> some View {
        let tone = Self.tone(for: chip)
        return HStack(spacing: 10) {
            Text(chip.code)
                .font(.lhfMono(12, weight: .semibold))
                .foregroundStyle(tone.ink)
                .frame(width: 72, alignment: .trailing)

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.v2Ink.opacity(0.35))

            Text(chip.title ?? "Assignment")
                .font(.lhfAssignmentTitle(14))
                .foregroundStyle(Color.v2Ink)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(chip.due)
                .font(.lhfSans(11, weight: .medium))
                .foregroundStyle(Color.v2DateText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: width, alignment: .leading)
        .background(tone.fill.opacity(isAccent ? 0.30 : 0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(tone.fill.opacity(isAccent ? 0.55 : 0.22), lineWidth: isAccent ? 1.5 : 1)
        )
        .shadow(color: Color.v2CardShadow.opacity(0.06), radius: 2, y: 1)
    }

}

#if DEBUG
#Preview {
    IntroView()
        .environmentObject(AppState())
        .frame(width: 393, height: 852)
}
#endif
