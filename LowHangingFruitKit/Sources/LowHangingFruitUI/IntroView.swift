import SwiftUI

/// The first thing a new user sees after the splash, and before the connect
/// checklist (`OnboardingView`). Three skippable panes that say what the app is
/// for — because the checklist opens on "Connect Canvas", and asking a stranger
/// to type their Penn SSO password into an embedded web view inside two taps,
/// having explained nothing, is a lot to ask.
///
/// Pane order is deliberate. The privacy pane is *last*, immediately before the
/// checklist, so "the app never sees your password" is the sentence still on
/// screen when the login ask arrives — the app's strongest argument sitting
/// next to the moment it's needed, instead of buried in Settings behind it.
///
/// Shown exactly once, gated on `AppState.hasSeenIntro` (never on
/// `hasCompletedOnboarding`, which the Settings reconnect buttons clear).
struct IntroView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var page = 0

    // MARK: Content

    /// Each pane runs the same beat: name the problem (`lead`), answer it
    /// (`title` / `body` / `points`), then say what that buys you (`closer`).
    /// Across the three panes those beats add up to the actual pitch — the
    /// scattered-deadline problem, how LHF takes it off your hands, and the
    /// point of all of it, which is getting your time back.
    private struct Pane {
        let symbol: String
        let lead: String
        let title: String
        let body: String
        let points: [String]
        var closer: String? = nil
    }

    private static let panes: [Pane] = [
        Pane(
            symbol: "list.bullet.rectangle",
            lead: "Canvas in one tab, Gradescope in another, the rest in your head.",
            title: "Everything you owe.\nOne list.",
            body: "Both sources merged into a single list, in the order things are actually due.",
            points: [
                "An assignment posted in both places shows up once.",
                "Nothing to cross-check. Nothing to miss.",
            ]
        ),
        Pane(
            symbol: "checkmark.circle",
            lead: "Keeping track of it all shouldn’t be a second job.",
            title: "It notices when\nyou’re done.",
            body: "Submit on Canvas and LHF files the assignment for you. It watches your grades too, and tells you the moment one posts.",
            points: [
                "Finished work moves itself out of the way.",
                "Nothing to tick off. Nothing to refresh.",
            ],
            closer: "So you can stop checking, and trust the list instead."
        ),
        Pane(
            symbol: "lock.shield",
            lead: "And it asks for nothing in return.",
            title: "No account.\nNo server.\nNo tracking.",
            body: "You log in to Canvas itself, on Canvas’s own page. LHF never sees your password.",
            points: [
                "There’s no LHF account to create.",
                "Your classes, grades, and deadlines stay on this phone.",
            ],
            closer: "That’s the whole point: school takes up less of your life, so you get to go live it."
        ),
    ]

    private var isLastPage: Bool { page == Self.panes.count - 1 }

    // MARK: Body

    var body: some View {
        ZStack {
            Color.v2Bg.ignoresSafeArea()

            VStack(spacing: 0) {
                skipBar
                pager
                footer
            }
            .frame(maxWidth: 480)
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 620)
#endif
    }

    /// Skip lives in the corner rather than under the primary button so it's
    /// reachable from every pane without competing with "Get started" on the
    /// last one, where the two would do exactly the same thing.
    private var skipBar: some View {
        HStack {
            Spacer()
            Button {
                lhfHapticLight()
                state.completeIntro()
            } label: {
                Text("skip")
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

    @ViewBuilder
    private var pager: some View {
#if os(iOS)
        // `.page` is iOS-only (`PageTabViewStyle` isn't available on macOS),
        // hence the split. Dots are drawn by hand in `footer` so they sit with
        // the button rather than floating over the pane's own content.
        TabView(selection: $page) {
            ForEach(Array(Self.panes.enumerated()), id: \.offset) { index, pane in
                paneView(pane, isFirst: index == 0)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
#else
        // macOS builds (what `swift test` compiles) get the same panes one at a
        // time, driven by the same Continue button — just without the swipe.
        paneView(Self.panes[page], isFirst: page == 0)
#endif
    }

    private func paneView(_ pane: Pane, isFirst: Bool) -> some View {
        // Each pane scrolls on its own: a paged TabView won't scroll its
        // contents, so at the largest accessibility text sizes this is what
        // keeps the copy reachable instead of clipped.
        //
        // The `minHeight` is what makes the two cases share one layout: at
        // ordinary text sizes the content is shorter than the pane, so the
        // `Spacer`s split the slack and the copy sits centered; once Dynamic
        // Type pushes it past the pane height the spacers collapse to their
        // minimums and it simply scrolls.
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Spacer(minLength: 12)

                    Image(systemName: pane.symbol)
                        .font(.lhfSans(34, weight: .medium))
                        .foregroundStyle(Color.v2SpineGreen)
                        .accessibilityHidden(true)

                    Text(pane.lead)
                        .font(.lhfSans(14))
                        .foregroundStyle(Color.v2CourseCode)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(pane.title)
                        .font(.lhfSerif(38))
                        .foregroundStyle(Color.v2Ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(pane.body)
                        .font(.lhfSans(16))
                        .foregroundStyle(Color.v2DateText)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(pane.points, id: \.self) { point in
                            pointRow(point)
                        }
                    }
                    .padding(.top, 2)

                    if let closer = pane.closer {
                        Text(closer)
                            .font(.lhfSerif(20))
                            .foregroundStyle(Color.v2SpineGreen)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }

                    if isFirst {
                        previewLink
                            .padding(.top, 8)
                    }

                    Spacer(minLength: 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .frame(minHeight: proxy.size.height, alignment: .leading)
            }
        }
    }

    private func pointRow(_ point: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // A baseline-aligned dot instead of a fixed-size icon frame, so the
            // row grows with the text rather than clipping around it.
            Circle()
                .fill(Color.v2SpineGreen)
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { _ in 4 }
                .accessibilityHidden(true)

            Text(point)
                .font(.lhfSans(15))
                .foregroundStyle(Color.v2Ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The reviewer's door. On the old checklist this was the smallest text on
    /// the busiest screen; here it's the only secondary action on the pane, and
    /// it arrives before the login ask rather than under it.
    private var previewLink: some View {
        Button {
            lhfHapticLight()
            state.enterPreviewMode()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("just exploring?")
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.v2CourseCode)
                Text("preview with sample data")
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.v2Ink)
                    .underline()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .shadow(color: Color.v2CardShadow.opacity(0.06), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("preview the app with sample data")
        .accessibilityHint("explore a demo dashboard without logging in")
    }

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
            ForEach(0..<Self.panes.count, id: \.self) { index in
                Circle()
                    .fill(index == page ? Color.v2Ink : Color.v2Ink.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private func advance() {
        lhfHapticLight()
        guard !isLastPage else {
            state.completeIntro()
            return
        }
        if reduceMotion {
            page += 1
        } else {
            withAnimation(.easeInOut(duration: 0.28)) { page += 1 }
        }
    }
}

#if DEBUG
#Preview {
    IntroView()
        .environmentObject(AppState())
        .frame(width: 393, height: 852)
}
#endif
