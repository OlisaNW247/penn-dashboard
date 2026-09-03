import SwiftUI
import LowHangingFruitKit

// MARK: – ask
//
// A chat over everything LHF already holds about the student's classes:
// syllabi, deadlines, announcements. "what's my phys attendance policy" →
// the answer, with the syllabus section it came from.
//
// ## The idea the screen is built on
//
// The app is called Low Hanging Fruit and its mark is a persimmon on a
// branch. This screen takes that literally: the bough is drawn across the
// top, and the suggested questions hang off it as fruit you pick. That is
// not ornament — it is the only bit of the design doing real work, because
// the hardest problem with an assistant like this is not answering, it is
// that a student opening a blank chat box has no idea what it knows. Four
// answerable questions, hanging where the eye already is, are the affordance.
// A row of grey suggestion pills would have said the same thing and meant
// nothing.
//
// Once a question is asked the branch does not go away — it fades from a
// scene-setting 0.5 to a faint 0.12 and the transcript scrolls straight over
// the top of it. The tree is the room the conversation happens in, so the
// room stays.
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
    /// Course codes drive the suggested questions, so the fruit on the branch
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
    @FocusState private var composerFocused: Bool

    private let branch = BranchGeometry()

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

    /// The bough is at full strength only until the first question. Both
    /// values are chosen against the warm greige ground: 0.5 is present
    /// without competing with the serif, and 0.12 survives behind body text
    /// without ever making a line of it harder to read.
    private var wash: Double { conversation.isFresh ? 0.5 : 0.16 }

    var body: some View {
        ZStack(alignment: .top) {
            Color.v2Bg.ignoresSafeArea()

            VStack(spacing: 0) {
                titleBlock
                    .padding(.horizontal, 22)

                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        BranchBackdrop(geometry: branch, wash: wash)
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
                        withAnimation { conversation.clear() }
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
                Text("ask")
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

    // MARK: The fruit on the branch

    /// The suggestions, hung from the bough on stems that meet the wood where
    /// the wood actually is — `BranchGeometry.unitY(atX:)` is what makes that
    /// exact rather than eyeballed, and what keeps it exact if the curve is
    /// ever retuned.
    ///
    /// Each one is staggered horizontally as well as vertically. A tidy left
    /// column would read as a list that happens to have a tree behind it;
    /// what sells the metaphor is that they are at different depths, the way
    /// fruit is.
    private func hangingSuggestions(in size: CGSize) -> some View {
        let items = suggestions
        return ZStack(alignment: .topLeading) {
            // Stems first, so the chips sit on top of where they terminate.
            Canvas { context, _ in
                for (index, item) in items.enumerated() {
                    let x = item.unitX * size.width
                    guard let unitY = branch.unitY(atX: item.unitX) else { continue }
                    let top = unitY * size.height
                    let bottom = Self.chipYFractions[index] * size.height
                    var stem = Path()
                    stem.move(to: CGPoint(x: x, y: top))
                    // A slight bow, because a stem under load is not a
                    // plumb line.
                    stem.addQuadCurve(
                        to: CGPoint(x: x, y: bottom),
                        control: CGPoint(x: x + (index.isMultiple(of: 2) ? 7 : -7),
                                         y: (top + bottom) / 2)
                    )
                    // Longer drops are drawn fainter. All four at one weight
                    // turned the left gutter into a thicket on device — the
                    // stems competed with the chips they were supposed to be
                    // serving. Fading with length keeps the nearest one crisp
                    // and lets the deep ones recede.
                    let depth = Double(index) / Double(max(1, items.count - 1))
                    context.stroke(
                        stem,
                        with: .color(.lhfBark.opacity(0.44 - 0.16 * depth)),
                        lineWidth: 1.5 - 0.35 * depth
                    )
                }
            }

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                suggestionChip(item, maxWidth: size.width - item.unitX * size.width - 14 + 25)
                    .offset(
                        // Pull the chip left by its own leading padding plus
                        // half the fruit, so the *fruit* lands on the stem
                        // rather than the chip's corner.
                        x: item.unitX * size.width - 25,
                        y: Self.chipYFractions[index] * size.height
                    )
            }
        }
    }

    private func suggestionChip(_ item: Suggestion, maxWidth: CGFloat) -> some View {
        Button {
            ask(item.prompt)
        } label: {
            HStack(spacing: 9) {
                PersimmonMark(size: 26)
                    .frame(width: 26, height: 26)
                Text(item.prompt)
                    .font(.lhfSerif(16))
                    .foregroundStyle(Color.v2Ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 12)
            .padding(.trailing, 15)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.v2Card)
                    .shadow(color: Color.v2CardShadow.opacity(0.13), radius: 6, y: 2)
            )
            .frame(maxWidth: max(150, maxWidth), alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.prompt)
        .accessibilityHint("Asks this question")
    }

    /// Vertical positions as fractions of the canvas, not absolute points, so
    /// the arrangement holds its proportions from an SE to a 16 Pro Max
    /// instead of bunching up or running off the bottom.
    private static let chipYFractions: [CGFloat] = [0.40, 0.55, 0.70, 0.85]

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
            // A soft fade rather than a hard bar, so the branch and the
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
                        // took this to 0.9 grayscale at 45% and the fruit went
                        // to a pale blob that read as a broken image — an
                        // empty composer should look like unripe fruit, not
                        // like a missing asset, so it keeps most of its colour.
                        .grayscale(canSend ? 0 : 0.45)
                        .opacity(canSend ? 1 : 0.62)
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

    // MARK: Suggestions

    struct Suggestion: Identifiable {
        let id = UUID()
        var prompt: String
        /// Horizontal anchor in unit space — where on the bough it hangs.
        var unitX: CGFloat
    }

    /// Built against the student's real classes where possible, because "what's
    /// my PHYS 0151 attendance policy" is a question they might actually have
    /// and "what's my attendance policy" is not.
    ///
    /// The x positions increase down the list. They were staggered freely at
    /// first, which looked more organic in the abstract and much worse on a
    /// device: a chip set left of the one above it sends its stem back across
    /// every chip in between, and since the chips are wide the result was a
    /// tangle. Monotonic left-to-right keeps each stem in its own lane while
    /// still reading as fruit at different depths.
    private var suggestions: [Suggestion] {
        let codes = courseCodes.isEmpty ? ScriptedAssistantResponder.placeholderCodes : courseCodes
        func code(_ index: Int) -> String { codes[index % codes.count].lowercased() }
        return [
            Suggestion(prompt: "what's my \(code(0)) attendance policy?", unitX: 0.11),
            Suggestion(prompt: "when's my next exam?", unitX: 0.22),
            Suggestion(prompt: "what am i actually missing right now?", unitX: 0.31),
            Suggestion(prompt: "how much is the \(code(1)) final worth?", unitX: 0.40),
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
