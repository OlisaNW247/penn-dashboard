import SwiftUI
import LowHangingFruitKit

/// Questions and source-backed answers about the student’s classes.
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
    @State private var sendPulse: Double = 0
    @State private var greetingIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    #if os(iOS)
    /// Dictation is iOS-only (on-device recognition, see `VoiceDictationRules`).
    @StateObject private var dictation = VoiceDictationController()
    /// The field's text at the moment listening began. The transcript is the
    /// recogniser's whole result so far, so each update is merged onto this
    /// and not onto the field's current text, which would repeat the words.
    @State private var draftBeforeListening = ""
    @Environment(\.scenePhase) private var scenePhase
    #endif


    /// Picks the responder once, at construction, rather than the view
    /// re-checking on every render: whether a backend is configured shouldn't
    /// flip a conversation already under way from one backend to another
    /// mid-chat. A backend that becomes configured after this screen opened
    /// takes effect the next time `ask` is opened, exactly like `AppState`'s
    /// own "toggle on AND backend present" checks (see
    /// `refreshAnnouncementWatcher`) only take effect on the next sync, not
    /// retroactively on one in flight.
    /// Synced course materials and the dashboard's work items, both read by
    /// the responders through `AssistantContext`. Defaulted so previews and
    /// the existing call sites compile unchanged.
    var knowledge: CourseKnowledgeBase = .empty
    var work: [WorkItem] = []
    var userName: String = ""
    /// The student's Canvas host (`AppState.canvasBaseURL.host`), the one
    /// place besides Ed Discussion a link in an answer may open
    /// (`AnswerLinkPolicy`). `nil` in previews, where only Ed passes.
    var canvasHost: String? = nil

    /// Without a configured backend (`BackendServices.client` is `nil` —
    /// true for every student who hasn't been enrolled against LHF's server,
    /// and always true under tests) the on-device answerer takes the
    /// conversation: exact answers from the dashboard's own items, retrieval
    /// over synced course materials, no network. With a backend,
    /// `BackendAssistantResponder` does — and gets the same retrieved
    /// passages in its per-turn request, falling back to the on-device
    /// answerer itself if the server call fails. The scripted stand-in is
    /// used only when there is nothing at all to answer from (previews).
    init(
        courseCodes: [String] = [],
        contextDocument: String = "",
        knowledge: CourseKnowledgeBase = .empty,
        work: [WorkItem] = [],
        userName: String = "",
        canvasHost: String? = nil,
        allowBackend: Bool = true,
        preferScripted: Bool = false
    ) {
        self.courseCodes = courseCodes
        self.contextDocument = contextDocument
        self.knowledge = knowledge
        self.work = work
        self.userName = userName
        self.canvasHost = canvasHost
        let responder: AssistantResponder
        if allowBackend, !preferScripted, let client = BackendServices.client, !(knowledge.isEmpty && work.isEmpty) {
            responder = BackendAssistantResponder(client: client, fallback: OnDeviceAssistantResponder())
        } else if preferScripted || (knowledge.isEmpty && work.isEmpty) {
            responder = ScriptedAssistantResponder()
        } else {
            responder = OnDeviceAssistantResponder()
        }
        _conversation = StateObject(wrappedValue: AssistantConversation(responder: responder))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.v2Bg.ignoresSafeArea()

            VStack(spacing: 0) {
                titleBlock
                    .padding(.horizontal, 22)

                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        if conversation.isFresh && !composerFocused {
                            suggestedQuestions
                                .transition(.opacity.combined(with: .offset(y: -14)))
                        } else if !conversation.isFresh {
                            transcript
                                .transition(.opacity)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .clipped()
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        // Gives the on-device sentence embedding a head start before the
        // student's first question — see `SentenceEmbeddingProvider`'s doc
        // comment for the two-minute frozen-cursor bug this and
        // `AppState.init`'s matching call guard against. `warmUp()` is
        // idempotent, so opening this screen twice in one launch (or after
        // `AppState.init` already called it) costs nothing.
        .task { SentenceEmbeddingProvider.shared.warmUp() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: conversation.isFresh)
        .task(id: conversation.isFresh && !composerFocused && !reduceMotion) {
            guard conversation.isFresh && !composerFocused && !reduceMotion else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(7)) } catch { return }
                withAnimation(.easeInOut(duration: 0.35)) { greetingIndex = (greetingIndex + 1) % 3 }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !conversation.isFresh {
                ToolbarItem(placement: .primaryAction) {
                    Button("New chat") {
                        withAnimation {
                            conversation.clear()

                        }
                    }
                    .font(.lhfSans(14, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
                }
            }
        }
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            if conversation.isFresh { SmoothStarMark(size: 36).accessibilityHidden(true) }
            Text(conversation.isFresh ? greeting : "Ask about classes")
                .font(.lhfSans(conversation.isFresh ? 32 : 22, weight: .regular))
                .foregroundStyle(Color.v2Ink)
                .id(conversation.isFresh ? greetingIndex : -1)
                .transition(.opacity)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private var greeting: String {
        AssistantPresentation.greeting(index: greetingIndex, date: Date())
    }

    private var suggestedQuestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(suggestions.prefix(3).enumerated()), id: \.offset) { index, item in
                    Button { ask(item.prompt) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: ["calendar", "clock", "text.book.closed"][index])
                                .foregroundStyle(Color.smoothCobaltInk)
                                .frame(width: 24)
                            Text(item.prompt)
                                .font(.lhfSans(16, weight: .regular))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.v2DateText)
                        }
                        .foregroundStyle(Color.v2Ink)
                        .padding(.vertical, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < 2 { Divider().overlay(Color.v2Divider) }
                }
            }
            .padding(.horizontal, 22)
        }
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
                        .font(.lhfSans(17, weight: .regular))
                        .foregroundStyle(Color.v2Ink)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        // Only the answer's own links are filtered; the chips
                        // below keep the system default (`AnswerLinkPolicy`).
                        .environment(\.openURL, AnswerLinkPolicy.openURLAction(canvasHost: canvasHost))
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
        return AssistantPresentation.answer(message.text)
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
            Text("Thinking…")
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

    /// A chip without a URL is the plain text it has always been. One with a
    /// URL is a `Link` to the source, marked by a small arrow and no extra
    /// words (the chip already says what it is). The capsule keeps its size;
    /// only the hit area grows, to 44pt tall, the same floor the card's own
    /// "open in canvas" link uses. `Link`, not a tap gesture, for the reason
    /// `AssignmentCardView` gives: a real control is accessible as a link and
    /// claims the touch cleanly.
    @ViewBuilder
    private func citationChip(_ citation: AssistantCitation) -> some View {
        let linked = citation.url != nil
        let capsule = HStack(spacing: 5) {
            Circle()
                .fill(Color.v2SpinePurple.opacity(0.55))
                .frame(width: 5, height: 5)
            Text(citation.course.lowercased())
                .font(.lhfSans(11, weight: .medium))
                .foregroundStyle(Color.v2DateText)
            Text(citation.detail.map { "\(citation.source) · \($0)" } ?? citation.source)
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2CourseCode)
            if linked {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.v2CourseCode)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.v2Ink.opacity(0.05)))

        if let url = citation.url {
            Link(destination: url) {
                capsule
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("opens the source")
        } else {
            capsule.accessibilityElement(children: .combine)
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 11) {
            HStack(spacing: 8) {
                TextField("Ask about classes…", text: $draft, axis: .vertical)
                    .font(.lhfSans(16, weight: .regular))
                    .foregroundStyle(Color.v2Ink)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit { ask(draft) }
                    .padding(.vertical, 12)
                #if os(iOS)
                micButton
                #endif
            }
            // The vertical padding sits on the field, not the row, so the
            // 44pt mic does not make the capsule taller than it was; the
            // trailing inset shrinks when the mic is there so its hit area
            // does not widen the capsule's right edge.
            .padding(.leading, 17)
            .padding(.trailing, composerTrailingInset)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.v2Card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.v2Divider, lineWidth: 1)
                    )
            )
            #if os(iOS)
            // Words only ever land in the field; nothing here sends them.
            .onChange(of: dictation.transcript) { _, t in draft = VoiceDictationRules.merged(draft: draftBeforeListening, transcript: t) }
            // Taken when listening actually begins, not at the tap: the first
            // tap may go through a permission prompt and the draft can change.
            .onChange(of: dictation.isListening) { _, on in if on { draftBeforeListening = draft } }
            // Typing while listening would be overwritten by the next partial.
            .onChange(of: composerFocused) { _, focused in if focused && dictation.isListening { dictation.stop() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { dictation.stop() } }
            .onDisappear { dictation.stop() }
            #endif

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

    private var composerTrailingInset: CGFloat {
        #if os(iOS)
        return dictation.availability == .hidden ? 17 : 6
        #else
        return 17
        #endif
    }

    #if os(iOS)
    /// Absent entirely when the phone cannot recognise speech on-device.
    /// Tapping starts listening and tapping again stops; the dictated words
    /// stream into the field and the student sends them as usual.
    @ViewBuilder
    private var micButton: some View {
        if dictation.availability != .hidden {
            Button {
                if !dictation.isListening { composerFocused = false }
                dictation.toggle()
            } label: {
                Image(systemName: dictation.isListening ? "waveform" : "mic")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(dictation.isListening ? Color.smoothTomato : Color.v2DateText)
                    .symbolEffect(.variableColor.iterative, isActive: dictation.isListening)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(conversation.isResponding)
            .accessibilityLabel(dictation.isListening ? "stop listening" : "dictate")
        }
    }
    #endif

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
                    SmoothStarMark(size: 34)
                        .overlay {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(Color.smoothInk)
                        }
                        .scaleEffect(sendPulse > 0 ? 0.72 : 1)
                        .rotationEffect(.degrees(sendPulse * 12))
                        .grayscale(canSend ? 0 : 0.35)
                        .opacity(canSend ? 0.9 : 0.58)
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

        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { sendPulse = 1 }
        Task {
            try? await Task.sleep(nanoseconds: 340_000_000)
            sendPulse = 0
        }

        #if os(iOS)
        if dictation.isListening { dictation.stop() }
        #endif
        draft = ""
        composerFocused = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            conversation.send(
                trimmed,
                context: AssistantContext(
                    courseCodes: courseCodes,
                    contextDocument: contextDocument,
                    timeZone: .current,
                    knowledge: knowledge,
                    work: work,
                    userName: userName
                )
            )
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
            Suggestion(prompt: "What’s due this week?"),
            Suggestion(prompt: "When’s my next exam?"),
            Suggestion(prompt: "What’s the attendance policy for \(code(0))?"),
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
