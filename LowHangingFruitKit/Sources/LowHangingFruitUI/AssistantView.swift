import SwiftUI
import LowHangingFruitKit

// MARK: – the tree
//
// A chat over everything LHF already holds about the student's classes:
// syllabi, deadlines, announcements. "what's my phys attendance policy" →
// the answer, with the syllabus section it came from.
//
// ## The idea the screen is built on
//
// The app is called Low Hanging Fruit and its mark is a persimmon on a
// branch. This screen takes that literally: the backdrop is the whole tree —
// a rooted trunk and its full canopy — and the suggested questions sit as
// fruit-bearing chips over it, four of them, zigzagging down the page. That
// is not ornament — it is the only bit of the design doing real work,
// because the hardest problem with an assistant like this is not answering,
// it is that a student opening a blank chat box has no idea what it knows.
// Four answerable questions, sitting where the eye already is, are the
// affordance. A row of grey suggestion pills would have said the same thing
// and meant nothing.
//
// The tree itself used to be drawn — vectors, boughs, a full `Canvas` of
// `BranchGeometry` curves — specifically so the chips could hang from actual
// branch tips on short stems. Two things about that are now history rather
// than current fact, and it is worth being honest about both:
//
// The backdrop is now a bundled illustration (`TreeBackdrop`, `thetree.png`)
// rather than a drawing, supplied by the product owner in place of the
// hand-built vector tree. A raster has no queryable branch tips, so the
// chip layout stopped being tied to the backdrop's geometry the moment the
// backdrop became a picture — see `TreeGeometry` for what's left of the
// old branch-tip table now that nothing draws limbs to hang chips from.
//
// The stems are gone too, and for a reason that predates the illustration:
// a single bough with the suggestion chips at fixed depths down its length
// used to put every chip on one shared stem run, and because the chips are
// wide and left-anchored, a lower chip's stem ran *behind* every chip above
// it before re-emerging below it — three parallel strings threading through
// cards on a real device. Moving to four separate branch tips fixed that
// structurally, by giving each chip its own short stem with nowhere far
// enough to reach sideways. Now that there is no branch drawn at all, a stem
// would be pointing at nothing — a line drawn toward an attachment point
// that doesn't exist in the artwork reads as a rendering bug, not as
// craft — so the chips sit flush against the screen edges with no stem at
// all. `PersimmonMark` already draws its own short stem on the fruit itself,
// which is enough to say "this is hanging fruit" without a second one
// reaching for a branch that isn't there.
//
// Once a question is asked the tree does not go away — it fades from a
// scene-setting 0.5 down to a faint 0.10 and the transcript scrolls straight
// over the top of it. The tree is the room the conversation happens in, so
// the room stays.
//
// ## Why the answers do not look like chat bubbles
//
// The student's own message gets a bubble, because a bubble is a good way to
// say "you said this". The answer does not. It is set in the display serif on
// the bare paper background with a coloured spine down its left edge — the
// same spine language as the assignment cards, in the purple `RedesignTokens`
// reserves for *provenance*: things that came out of the student's own
// syllabus. An answer set as a grey chat bubble is a message from a chatbot.
// An answer set like the rest of the app's content is a fact about your
// classes, which is the thing being sold.
//
// The citation chips underneath exist for the same reason. An academic
// assistant that quietly invents an attendance policy is worse than none, so
// every answer names its sources and the student can go and check.

struct AssistantView: View {
    /// Course codes drive the suggested questions, so the fruit on the tree
    /// name classes the student actually takes.
    var courseCodes: [String] = []

    /// The rendered syllabus/deadline/announcement document, handed straight
    /// through into every `AssistantContext` this screen builds. Building it
    /// is somebody else's job — this view only carries it from init to
    /// `ask(_:)`, the same way it already carries `courseCodes`. Empty by
    /// default so every existing call site (`ContentView`, both `#Preview`s
    /// below) keeps compiling unchanged.
    var contextDocument: String = ""

    @StateObject private var conversation: AssistantConversation
    @State private var draft = ""
    @State private var detach: Double = 0
    /// Which suggestion chip, if any, is mid-pick — driving the fade on the
    /// other three chips and, together with `pickedDetach`, that one chip's
    /// own falling persimmon. `nil` at rest and reset in `conversation.clear()`
    /// so a second visit to the empty state never shows a chip already fallen.
    @State private var pickedIndex: Int?
    /// 0 at rest, 1 fully detached — the picked chip's `PersimmonMark` reads
    /// this the same way the send button's does.
    @State private var pickedDetach: Double = 0
    @FocusState private var composerFocused: Bool

    private let tree = TreeGeometry()

    /// Picks the responder once, at construction, rather than the view
    /// re-checking on every render: whether a key is saved shouldn't flip a
    /// conversation already under way from one backend to another mid-chat.
    /// A key saved after this screen opened takes effect the next time `ask`
    /// is opened, exactly like `AppState`'s own "toggle on AND key present"
    /// checks (see `refreshAnnouncementWatcher`) only take effect on the next
    /// sync, not retroactively on one in flight.
    init(courseCodes: [String] = [], contextDocument: String = "") {
        self.courseCodes = courseCodes
        self.contextDocument = contextDocument
        let apiKey = AnthropicKeyStore.load()
        let responder: AssistantResponder
        if apiKey.isEmpty {
            responder = ScriptedAssistantResponder()
        } else {
            responder = ClaudeAssistantResponder(apiKey: apiKey)
        }
        _conversation = StateObject(wrappedValue: AssistantConversation(responder: responder))
    }

    /// The tree is a *backdrop*, and these two values are both much lower
    /// than the ones the drawn version wanted.
    ///
    /// Those older numbers (0.5 fresh, 0.10 answering) were tuned for a
    /// sparse line drawing — a bough, a few leaves, mostly empty page. The
    /// illustration that replaced it is a dense, fully-painted object with
    /// saturated greens and browns edge to edge, and at 0.5 it stopped being
    /// a backdrop: on a device it competed with the suggestion chips sitting
    /// on top of it and turned the screen into two things fighting for the
    /// eye. Roughly halving it is not timidity, it is the same *apparent*
    /// weight arrived at from a much heavier drawing.
    ///
    /// The trap worth recording: the fix looks like it should be raising the
    /// chips' contrast so they win against the tree. That is backwards — it
    /// treats the backdrop as the thing to beat rather than the thing to
    /// recede, and it ends with an even louder page. Fade the tree instead.
    private var wash: Double { conversation.isFresh ? 0.22 : 0.07 }

    var body: some View {
        ZStack(alignment: .top) {
            Color.v2Bg.ignoresSafeArea()

            VStack(spacing: 0) {
                titleBlock
                    .padding(.horizontal, 22)

                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        TreeBackdrop(geometry: tree, wash: wash)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .animation(.easeInOut(duration: 0.55), value: conversation.isFresh)

                        if conversation.isFresh {
                            hangingSuggestions(in: geo.size)
                                .transition(.opacity.combined(with: .offset(y: -14)))
                        } else {
                            transcript
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: conversation.isFresh)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !conversation.isFresh {
                ToolbarItem(placement: .primaryAction) {
                    Button("new") {
                        withAnimation {
                            conversation.clear()
                            // Otherwise the next empty state opens with one
                            // chip already fallen and faded, from the last
                            // conversation's pick.
                            pickedIndex = nil
                            pickedDetach = 0
                        }
                    }
                    .font(.lhfSans(14, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
                }
            }
        }
    }

    // MARK: Title

    /// Present only on the empty state. Once there is a transcript the screen
    /// needs every point of height it can get, and the back button in the nav
    /// bar already says where you are.
    @ViewBuilder
    private var titleBlock: some View {
        if conversation.isFresh {
            VStack(alignment: .leading, spacing: 6) {
                Text("the tree")
                    .font(.lhfSerif(38))
                    .foregroundStyle(Color.v2Ink)
                Text("your syllabi, deadlines and announcements — in one place, in plain language.")
                    .font(.lhfSans(14))
                    .foregroundStyle(Color.v2DateText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 40)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }

    // MARK: The fruit on the tree

    /// The suggestions, positioned against `TreeGeometry.slots` — four
    /// fixed points down the page, alternating sides, with no branch tip or
    /// stem involved any more (see this file's header for why: the backdrop
    /// is a bundled illustration now, not a drawing with queryable limbs).
    /// `growsRight` on each slot says which screen edge the chip sits flush
    /// against: `true` docks it to the left with the fruit first and the
    /// text running right of it, `false` docks it to the right with the
    /// mirror image — text first, fruit trailing — so in both cases the
    /// fruit sits on the outer edge, away from the centre of the screen,
    /// the same visual role it had when it was the part nearest the wood.
    private func hangingSuggestions(in size: CGSize) -> some View {
        let pairs = Array(zip(suggestions, tree.slots).enumerated())
        // Every slot uses the same near-edge inset on both sides, so the
        // room available to grow toward the opposite edge is identical for
        // a left-docked and a right-docked chip; there is nothing left that
        // varies per chip, unlike the old tip-relative calculation.
        let width = Self.availableWidth(totalWidth: size.width)

        return ZStack(alignment: .topLeading) {
            ForEach(pairs, id: \.element.0.id) { index, pair in
                let (item, slot) = pair
                let boxX = slot.growsRight ? Self.edgeInset : size.width - Self.edgeInset - width
                let boxY = slot.y * size.height

                suggestionChip(item, index: index, growsRight: slot.growsRight, maxWidth: width)
                    .opacity(pickedIndex == nil || pickedIndex == index ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: pickedIndex)
                    .offset(x: boxX, y: boxY)
            }
        }
    }

    /// How wide a chip may grow before it would run into the screen edge
    /// opposite the one it's docked against. Both edges use the same inset,
    /// so this no longer depends on which slot is asking — it did back when
    /// width was measured from a branch tip's x-position toward whichever
    /// screen edge was farther away.
    private static func availableWidth(totalWidth: CGFloat) -> CGFloat {
        max(150, totalWidth - Self.edgeInset * 2)
    }

    /// Distance kept between a chip's docked edge (and, symmetrically, the
    /// opposite edge it must not run into) and the actual screen edge.
    private static let edgeInset: CGFloat = 20

    private func suggestionChip(_ item: Suggestion, index: Int, growsRight: Bool, maxWidth: CGFloat) -> some View {
        Button {
            pickSuggestion(index)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                let fruit = PersimmonMark(size: 26, detach: index == pickedIndex ? pickedDetach : 0)
                    .frame(width: 26, height: 26)
                let label = Text(item.prompt)
                    .font(.lhfSerif(16))
                    .foregroundStyle(Color.v2Ink)
                    .multilineTextAlignment(growsRight ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)

                if growsRight {
                    fruit
                    label
                } else {
                    label
                    fruit
                }
            }
            .padding(.leading, growsRight ? 12 : 15)
            .padding(.trailing, growsRight ? 15 : 12)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.v2Card)
                    .shadow(color: Color.v2CardShadow.opacity(0.13), radius: 6, y: 2)
            )
            .frame(maxWidth: maxWidth, alignment: growsRight ? .leading : .trailing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.prompt)
        .accessibilityHint("Asks this question")
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(conversation.messages) { message in
                        row(for: message).id(message.id)
                    }
                    // Anchor for the auto-scroll. Scrolling to the last
                    // *message* stops short while that message is still
                    // growing, which is exactly when you need the scroll.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onChange(of: conversation.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: conversation.messages.last?.text.count ?? 0) { _, _ in
                // Follow the text as it streams. Unanimated: animating every
                // word arrival fights the next one and the list judders.
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private static let bottomAnchor = "assistant-bottom"

    @ViewBuilder
    private func row(for message: AssistantMessage) -> some View {
        switch message.role {
        case .student:
            HStack {
                Spacer(minLength: 44)
                Text(message.text)
                    .font(.lhfSans(15))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .fill(Color.v2Ink)
                    )
            }
        case .assistant:
            answer(message)
        }
    }

    private func answer(_ message: AssistantMessage) -> some View {
        HStack(alignment: .top, spacing: 13) {
            // The provenance spine. Same vocabulary as the assignment cards.
            Capsule()
                .fill(Color.v2SpinePurple)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 12) {
                if message.text.isEmpty && message.isStreaming {
                    pickingIndicator
                } else {
                    Text(body(of: message))
                        .font(.lhfSerif(17))
                        .foregroundStyle(Color.v2Ink)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !message.citations.isEmpty && !message.isStreaming {
                    citations(message.citations)
                        .transition(.opacity)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.2), value: message.isStreaming)
    }

    /// Answer text, with inline markdown resolved — but only once the answer
    /// has finished arriving.
    ///
    /// Parsing mid-stream is the trap here: a half-delivered `*before*` is an
    /// unmatched asterisk, and the parser either renders the literal star or
    /// swallows text as an open emphasis run, so the paragraph flickers as it
    /// streams. Plain text while streaming and one parse at the end is stable,
    /// and it matters beyond the script — a real model emits markdown, and
    /// without this the student reads raw asterisks.
    private func body(of message: AssistantMessage) -> AttributedString {
        guard !message.isStreaming else {
            // U+258C, a half-block, standing in for a cursor.
            return AttributedString(message.text + "\u{258C}")
        }
        let parsed = try? AttributedString(
            markdown: message.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return parsed ?? AttributedString(message.text)
    }

    /// "picking…" — three dots that fill in sequence. Named after what the
    /// screen is pretending to do, which is worth more than a spinner.
    private var pickingIndicator: some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.v2SpinePurple)
                    .frame(width: 6, height: 6)
                    .opacity(0.35)
                    .modifier(PulseModifier(delay: Double(index) * 0.18))
            }
            Text("picking")
                .font(.lhfSans(13))
                .foregroundStyle(Color.v2CourseCode)
                .padding(.leading, 3)
        }
        .padding(.vertical, 4)
    }

    private func citations(_ list: [AssistantCitation]) -> some View {
        // Two chips fit side by side on every phone the app supports; three,
        // or one long one, do not. `ViewThatFits` picks without a custom flow
        // layout and without a horizontal scroller inside a vertical one.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) { ForEach(list) { citationChip($0) } }
            VStack(alignment: .leading, spacing: 7) { ForEach(list) { citationChip($0) } }
        }
    }

    private func citationChip(_ citation: AssistantCitation) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.v2SpinePurple.opacity(0.55))
                .frame(width: 5, height: 5)
            Text(citation.course.lowercased())
                .font(.lhfSans(11, weight: .medium))
                .foregroundStyle(Color.v2DateText)
            Text(citation.detail.map { "\(citation.source) · \($0)" } ?? citation.source)
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2CourseCode)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.v2Ink.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 11) {
            TextField("ask about your classes…", text: $draft, axis: .vertical)
                .font(.lhfSerif(16))
                .foregroundStyle(Color.v2Ink)
                .lineLimit(1...4)
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit { ask(draft) }
                .padding(.horizontal, 17)
                .padding(.vertical, 12)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.v2Card)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.v2Divider, lineWidth: 1)
                        )
                )

            sendButton
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
            // A soft fade rather than a hard bar, so the tree and the
            // transcript pass underneath instead of being cut off by a line.
            LinearGradient(
                colors: [Color.v2Bg.opacity(0), Color.v2Bg.opacity(0.92), Color.v2Bg],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    /// The send control is the fruit, and pressing it picks it: the persimmon
    /// detaches, tips, and falls out of the button while a fresh one fades in
    /// behind. It is a half-second of nonsense that makes the app's own name
    /// into the verb for sending a question, which is worth the fifteen lines.
    private var sendButton: some View {
        Button {
            if conversation.isResponding {
                conversation.stop()
            } else {
                ask(draft)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.v2Card)
                    .overlay(Circle().strokeBorder(Color.v2Divider, lineWidth: 1))
                    .shadow(color: Color.v2CardShadow.opacity(0.14), radius: 5, y: 2)

                if conversation.isResponding {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.v2Ink)
                        .frame(width: 13, height: 13)
                } else {
                    PersimmonMark(size: 28, detach: detach)
                        .frame(width: 28, height: 28)
                        // Unsendable state: dimmed rather than hidden, so the
                        // target never moves under the thumb. The first pass
                        // took this to 0.9 grayscale at 45% opacity and the
                        // fruit went to a pale blob that read as a broken
                        // image. The first correction, 0.45 grayscale at 62%
                        // opacity, still didn't back off far enough — on a
                        // device it read as a pale beige blob, a missing
                        // asset rather than unripe fruit. This second
                        // correction backs off further again, to 0.2
                        // grayscale at 78% opacity, which is the point it
                        // reads as fruit that just isn't ripe yet.
                        .grayscale(canSend ? 0 : 0.2)
                        .opacity(canSend ? 1 : 0.78)
                }
            }
            .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !conversation.isResponding)
        .accessibilityLabel(conversation.isResponding ? "stop" : "send")
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Sending

    private func ask(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        withAnimation(.easeIn(duration: 0.34)) { detach = 1 }
        Task {
            try? await Task.sleep(nanoseconds: 340_000_000)
            detach = 0
        }

        draft = ""
        composerFocused = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            conversation.send(
                trimmed,
                context: AssistantContext(courseCodes: courseCodes, contextDocument: contextDocument)
            )
        }
    }

    /// Tapping a suggestion picks its fruit rather than quietly filling the
    /// composer: that chip's own `PersimmonMark` runs the detach animation
    /// the send button uses, the other three chips fade out over the same
    /// beat so the picked one is the last thing left on screen, and the
    /// actual send — `ask(_:)`, which is what calls `conversation.send` — is
    /// delayed just long enough for the fall to read before the transcript
    /// replaces the empty state under it. Any longer than this and the
    /// screen would feel unresponsive; any shorter and the fall never
    /// finishes before the tree it's falling in front of disappears.
    private func pickSuggestion(_ index: Int) {
        guard pickedIndex == nil, suggestions.indices.contains(index) else { return }
        let prompt = suggestions[index].prompt
        pickedIndex = index
        withAnimation(.easeIn(duration: 0.34)) { pickedDetach = 1 }
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            ask(prompt)
        }
    }

    // MARK: Suggestions

    struct Suggestion: Identifiable {
        let id = UUID()
        var prompt: String
    }

    /// Built against the student's real classes where possible, because "what's
    /// my PHYS 0151 attendance policy" is a question they might actually have
    /// and "what's my attendance policy" is not.
    ///
    /// There is no x-position carried here at all — that was this list's job
    /// back when every chip hung off a branch tip and had to stay in its own
    /// lane to avoid crossing the chips above it. Now that the backdrop is a
    /// bundled illustration with no branch tips to hang from, each suggestion
    /// is simply paired by index with a slot in `TreeGeometry.slots` (see
    /// `hangingSuggestions`), which docks it flush against a screen edge
    /// instead of a point on the tree; there is no lane to keep and nothing
    /// left to tune.
    private var suggestions: [Suggestion] {
        let codes = courseCodes.isEmpty ? ScriptedAssistantResponder.placeholderCodes : courseCodes
        func code(_ index: Int) -> String { codes[index % codes.count].lowercased() }
        return [
            Suggestion(prompt: "what's my \(code(0)) attendance policy?"),
            Suggestion(prompt: "when's my next exam?"),
            Suggestion(prompt: "what am i actually missing right now?"),
            Suggestion(prompt: "how much is the \(code(1)) final worth?"),
        ]
    }

}

/// A dot that fades up and back on a loop, offset by `delay` so a row of them
/// reads as a wave rather than a blink.
private struct PulseModifier: ViewModifier {
    var delay: Double
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0.28)
            .animation(
                .easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(delay),
                value: on
            )
            .onAppear { on = true }
    }
}

#if DEBUG
#Preview("ask — empty") {
    NavigationStack {
        AssistantView(courseCodes: ["PHYS 0151", "PSYC 1010", "ACCT 1010", "CIS 1200"])
    }
}

#Preview("ask — dark") {
    NavigationStack {
        AssistantView(courseCodes: ["PHYS 0151", "PSYC 1010", "ACCT 1010", "CIS 1200"])
    }
    .preferredColorScheme(.dark)
}
#endif
