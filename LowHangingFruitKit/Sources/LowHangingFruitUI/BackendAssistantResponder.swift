import Foundation
import LowHangingFruitKit

// MARK: – The one place LHF sends class data off-device
//
// Every other file in this Kit keeps the student's syllabi, deadlines and
// announcements on the phone. This one does not: `reply(to:context:)` POSTs
// `context.contextDocument` — the rendered syllabus/deadline/announcement
// text `AssistantContext` carries — plus the question being asked, to LHF's
// own backend (`backend/PROTOCOL.md`), which forwards it to a model through
// OpenRouter. This replaces the earlier design, where the same call went
// straight from the device to Anthropic using a key the student had to paste
// into Settings themselves; there is no student-supplied key anymore, and
// this file never touches `AnthropicKeyStore`.
//
// What travels and what doesn't is `backend/PROTOCOL.md`'s job to define,
// not this file's, but the short version its "Principles" section commits
// to: Canvas credentials never reach the server (this Kit fetches material
// with the student's own cookies and uploads only the extracted text);
// only course-level material is shared, never grades, completions,
// submission state, the student's name, or a transcript of past questions;
// identity is an anonymous Supabase user id, nothing more; and — the reason
// `fallback` exists on this type at all — offline, over quota, or with the
// backend down, `ask` keeps answering from the phone exactly as it does
// when no backend is configured in the first place. A student who never has
// a reachable backend (an unconfigured build, a test run, a dead network)
// is still fully on-device, every single time.
struct BackendAssistantResponder: AssistantResponder, Sendable {
    /// The backend call. Never constructed directly against a placeholder
    /// configuration — see `BackendServices.client`, which is `nil` exactly
    /// when this type shouldn't exist at all.
    let client: BackendClient

    /// Where an answer comes from when the backend can't produce one this
    /// turn: no reachable network, a dropped connection before any text
    /// arrived, the daily/monthly quota, or a malformed response. Injected
    /// (not a bare `OnDeviceAssistantResponder()` inside `reply`) so a test
    /// could hand this type a differently-configured fallback without
    /// touching its own logic, mirroring why `ClaudeAssistantResponder` took
    /// `session: URLSession` as a parameter rather than hard-coding
    /// `.shared`.
    let fallback: OnDeviceAssistantResponder

    init(client: BackendClient, fallback: OnDeviceAssistantResponder = OnDeviceAssistantResponder()) {
        self.client = client
        self.fallback = fallback
    }

    func reply(to prompt: String, context: AssistantContext) -> AsyncStream<AssistantChunk> {
        let client = client
        let fallback = fallback
        let request = Self.makeRequest(question: prompt, context: context)

        return AsyncStream { continuation in
            let task = Task {
                await Self.run(
                    request: request,
                    prompt: prompt,
                    context: context,
                    client: client,
                    fallback: fallback,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The actual network turn plus the on-device handoff. A `static`
    /// function taking every dependency as a parameter (no `self`), for the
    /// same reason the predecessor this was built from did the same: it
    /// keeps the pure parsing logic it calls out to
    /// (`AskStreamEvent.parse(line:)`, `SourcesBlockSplitter`,
    /// `makeRequest`) reachable and testable without this network-touching
    /// half getting dragged along.
    private static func run(
        request: AskRequest,
        prompt: String,
        context: AssistantContext,
        client: BackendClient,
        fallback: OnDeviceAssistantResponder,
        continuation: AsyncStream<AssistantChunk>.Continuation
    ) async {
        let bytes: URLSession.AsyncBytes
        do {
            bytes = try await client.askStream(request)
        } catch {
            // Nothing has streamed yet — `client.askStream` either failed to
            // authenticate, get a 2xx status, or open the connection at all,
            // which by construction happens before this function has had
            // any chance to yield a single character. Every failure reaching
            // here, not only the four `backend/PROTOCOL.md` calls out by
            // name (quota, transport, an unreachable/unconfigured backend,
            // an HTTP error), gets the same treatment: apologize once, then
            // let the on-device answerer finish the job, because
            // `BackendError.unauthorized`/`.decoding` leave the student in
            // exactly the same "no answer yet" spot as the others do, and
            // principle 5 in `backend/PROTOCOL.md` ("the on-device answerer
            // is the fallback") doesn't carve out an exception for them.
            if !Task.isCancelled {
                continuation.yield(.text(friendlyMessage(for: error) + "\n\n"))
                await forward(fallback.reply(to: prompt, context: context), to: continuation)
            }
            continuation.finish()
            return
        }

        var splitter = SourcesBlockSplitter()

        do {
            parsing: for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard let event = AskStreamEvent.parse(line: line) else { continue }
                switch event {
                case let .delta(text):
                    let visible = splitter.feed(text)
                    if !visible.isEmpty { continuation.yield(.text(visible)) }
                case .done:
                    break parsing
                case let .error(code, _):
                    // An error arriving mid-stream (a 200 that later gives
                    // up) is different from `client.askStream` throwing:
                    // some of the answer may already be on screen, so this
                    // does not hand off to `fallback` the way a pre-stream
                    // failure does — layering a whole second, differently-
                    // sourced answer under a partial one would read as two
                    // answers glued together, not one interrupted answer.
                    // A short apology appended to whatever already rendered
                    // is the same shape of outcome `ClaudeAssistantResponder`
                    // chose for a mid-stream connection drop, just phrased
                    // instead of silent.
                    continuation.yield(.text(midStreamErrorMessage(for: code)))
                    break parsing
                }
            }
        } catch {
            // The connection dropped mid-stream. Whatever text already made
            // it to `continuation.yield` above stays on screen — `stop()` in
            // `AssistantConversation` treats a cut-off answer as something
            // to keep, not discard, and a mid-stream network failure should
            // read the same way rather than as a wiped answer.
        }

        if !Task.isCancelled {
            let trailing = splitter.finish()
            if !trailing.isEmpty { continuation.yield(.text(trailing)) }
            if !splitter.citations.isEmpty {
                continuation.yield(.citations(splitter.citations))
            }
        }

        continuation.finish()
    }

    /// Drains `stream` onto `continuation`, chunk for chunk, stopping early
    /// if the outer stream has already been cancelled. The seam
    /// `run(...)`'s pre-stream failure branch uses to hand the rest of the
    /// answer to `fallback` without the caller (`AssistantView`) ever
    /// learning two different responders were involved in one reply.
    private static func forward(
        _ stream: AsyncStream<AssistantChunk>,
        to continuation: AsyncStream<AssistantChunk>.Continuation
    ) async {
        for await chunk in stream {
            if Task.isCancelled { break }
            continuation.yield(chunk)
        }
    }

    // MARK: - Request construction (pure — no network, fully unit-testable)

    /// The one seam every request-shape test in
    /// `BackendAssistantResponderTests` drives. Free of `client`/`fallback`
    /// so a test can call it directly without constructing a real
    /// responder — the same reason `ClaudeAssistantResponder
    /// .buildRequestBody` was `static`.
    static func makeRequest(question: String, context: AssistantContext) -> AskRequest {
        AskRequest(
            question: question,
            contextDocument: context.contextDocument,
            excerpts: retrievedExcerpts(question: question, context: context),
            askedAt: context.askedAt,
            courseIDs: context.knowledge.courses.map(\.courseID),
            history: []
        )
    }

    /// How many passages ride along with a question, and how long each may
    /// be. Four passages of ~700 characters is roughly a page: enough for a
    /// policy section and its exception, small enough that the per-turn
    /// part of the request stays cheap.
    static let excerptLimit = 4
    static let excerptCharacterLimit = 700

    /// The passages of the student's synced course materials that best match
    /// the question, rendered as a block for the `excerpts` field. Empty
    /// when nothing has been synced or nothing matches — the server's
    /// system prompt is told that policy text is then simply absent.
    ///
    /// Retrieval happens on-device rather than sending every synced document
    /// to the server on purpose: putting every syllabus in `contextDocument`
    /// would work, but it would change on every sync and re-bill the whole
    /// cached prefix server-side, and a four-course corpus is tens of
    /// thousands of tokens the question almost never needs. Three or four
    /// matched passages sent as `excerpts` cost a few hundred tokens and
    /// nothing in cache terms.
    static func retrievedExcerpts(question: String, context: AssistantContext) -> String {
        guard !context.knowledge.isEmpty else { return "" }
        let courses = context.knowledge.courses
        let parsed = QuestionParser.parse(question, courses: courses)
        let courseID = parsed.course.flatMap { course in
            courses.first(where: { CourseMatcher.sameCourse($0.code, as: course) })?.courseID
        }
        let preferredComponent = DocumentComponent.mentioned(in: question)
        let hits = CourseSearch(knowledge: context.knowledge).search(question, courseID: courseID, preferredComponent: preferredComponent, limit: excerptLimit)
        guard !hits.isEmpty else { return "" }
        // Labelled only for courses that are actually split (a lecture
        // syllabus and a lab syllabus sharing one Canvas site) so the model
        // can tell the two apart — see `DocumentComponent.courseIsSplit`.
        // Computed once per course, not per hit: classification reads every
        // document of the course.
        var splitByCourse: [String: Bool] = [:]
        for hit in hits where splitByCourse[hit.document.courseID] == nil {
            splitByCourse[hit.document.courseID] = DocumentComponent.courseIsSplit(context.knowledge.documents(for: hit.document.courseID))
        }
        let lines = hits.enumerated().map { index, hit -> String in
            let body = String(hit.passage.text.prefix(excerptCharacterLimit)).replacingOccurrences(of: "\n", with: " ")
            let labelled = hit.component != .general && (splitByCourse[hit.document.courseID] ?? false)
            let componentTag = labelled ? "[\(hit.component.label)] · " : ""
            return "[\(index + 1)] \(hit.document.course) · \(hit.document.kind.label) · \(componentTag)\"\(hit.document.title)\": \(body)"
        }
        return (["RETRIEVED EXCERPTS (from the student's synced course materials):"] + lines).joined(separator: "\n")
    }

    // MARK: - The `<sources>` splitter

    /// Splits the model's incrementally-arriving text into what's safe to
    /// show immediately and what belongs to the trailing `<sources>...
    /// </sources>` block, and parses that block into `AssistantCitation`s
    /// once it's complete.
    ///
    /// **The failure mode this exists to prevent:** a naive implementation
    /// forwards every character the model emits straight to the screen.
    /// Since the opening delimiter is plain text the model was merely
    /// instructed to produce, the student would see `<sou`, then `<sourc`,
    /// then `<sources>` itself, then the raw `COURSE|kind|detail` syntax,
    /// appear in the transcript for a moment before this code could ever
    /// recognize and retract it — a flicker of the assistant's internal
    /// formatting leaking through, then getting yanked back. Buffering any
    /// text that could still turn into the opening tag, and only releasing
    /// it once it's provably *not* going to become one, is what keeps that
    /// off the screen entirely instead of removing it after the fact.
    ///
    /// A struct, not a class: every `feed` call is a pure transformation of
    /// this value's own state into (new state, text safe to show now),
    /// which is what makes it directly unit-testable one chunk at a time
    /// without any streaming machinery in the test.
    ///
    /// Moved here unchanged from `ClaudeAssistantResponder` — the server
    /// passes model text through untouched (`backend/PROTOCOL.md`'s `ask`
    /// section) and is instructed to end with the same `<sources>
    /// COURSE|kind|detail;…</sources>` line the previous, direct-to-
    /// Anthropic path produced, so nothing about this splitter needed to
    /// change to keep working against the new backend.
    struct SourcesBlockSplitter: Sendable {
        private static let openTag = "<sources>"
        private static let closeTag = "</sources>"

        /// A prefix of `openTag` that arrived but hasn't yet been proven to
        /// continue into the full tag or to be ordinary text. Invariant:
        /// `openTag.hasPrefix(pending)` always holds.
        private var pending = ""
        /// Once the opening tag has fully matched, everything received is
        /// swallowed into here (never shown) until the closing tag is found.
        private var blockBuffer: String?

        private(set) var citations: [AssistantCitation] = []

        /// Feeds one chunk of newly-arrived text and returns the portion of
        /// it (plus anything still owed from a previous call) that is safe
        /// to display now.
        mutating func feed(_ chunk: String) -> String {
            if blockBuffer != nil {
                return consumeInsideBlock(chunk)
            }
            return consumeLookingForOpenTag(pending + chunk)
        }

        /// Called once the stream ends. Anything still sitting in `pending`
        /// at that point was a candidate opening tag that never got the
        /// chance to complete — the stream simply stopped mid-match — so it
        /// was never going to become the tag and belongs on screen after
        /// all, same as `a < b` never continuing into `<sources>` mid-chunk.
        /// A block that opened but never closed (a truncated/cancelled
        /// stream) is dropped rather than flushed: showing the raw
        /// `COURSE|kind|detail` syntax the delimiter exists to hide would be
        /// a worse outcome than showing nothing.
        mutating func finish() -> String {
            defer {
                pending = ""
                blockBuffer = nil
            }
            return blockBuffer == nil ? pending : ""
        }

        /// Scans `text` (already `pending` + new chunk, `pending` cleared by
        /// the caller's read of `feed`) a character at a time. `matchLen` at
        /// each position is how much of `openTag` this position agrees with:
        /// a full match hands the remainder off to `consumeInsideBlock`, a
        /// match that exactly exhausts what's left of `text` is buffered as
        /// the new `pending` (it might still complete on the next chunk),
        /// and anything else is a false start — advance by exactly one
        /// character and keep scanning, because a later `<` in the same
        /// chunk (`"a << sources>"`) can still be a real opening tag even
        /// though an earlier one wasn't.
        private mutating func consumeLookingForOpenTag(_ text: String) -> String {
            pending = ""
            var visible = ""
            var index = text.startIndex
            while index < text.endIndex {
                let remaining = text[index...]
                let matchLen = Self.commonPrefixCount(remaining, Self.openTag)

                if matchLen == Self.openTag.count {
                    let afterTag = text.index(index, offsetBy: Self.openTag.count)
                    blockBuffer = ""
                    visible += consumeInsideBlock(String(text[afterTag...]))
                    return visible
                }
                if matchLen > 0, matchLen == remaining.count {
                    // Whole remainder agrees with a prefix of the tag and
                    // ran out — genuinely ambiguous until more text arrives.
                    pending = String(remaining)
                    return visible
                }
                visible.append(text[index])
                index = text.index(after: index)
            }
            return visible
        }

        /// Inside an opening tag that has already fully matched. Looks for
        /// `closeTag` in the accumulated buffer; nothing here is ever
        /// returned as visible text, since everything between the tags is
        /// the citation syntax the student should never see.
        private mutating func consumeInsideBlock(_ chunk: String) -> String {
            let combined = (blockBuffer ?? "") + chunk
            guard let closeRange = combined.range(of: Self.closeTag) else {
                blockBuffer = combined
                return ""
            }
            let content = String(combined[combined.startIndex..<closeRange.lowerBound])
            citations = Self.parseCitations(content)
            blockBuffer = nil
            // Per the system prompt the model emits nothing after the
            // closing tag, but if it ever did, that text re-enters the
            // ordinary open-tag scan rather than being dropped silently.
            let rest = String(combined[closeRange.upperBound...])
            return rest.isEmpty ? "" : consumeLookingForOpenTag(rest)
        }

        /// How many leading elements two strings share. `Substring`/`String`
        /// compared directly rather than converted to `[Character]` first —
        /// both are already `Collection`s of `Character`, so this needs
        /// nothing beyond that shared conformance.
        private static func commonPrefixCount<A: StringProtocol, B: StringProtocol>(_ a: A, _ b: B) -> Int {
            var count = 0
            var aIndex = a.startIndex
            var bIndex = b.startIndex
            while aIndex < a.endIndex, bIndex < b.endIndex, a[aIndex] == b[bIndex] {
                count += 1
                aIndex = a.index(after: aIndex)
                bIndex = b.index(after: bIndex)
            }
            return count
        }

        /// Parses `"COURSE|kind|detail; COURSE|kind|detail"` into
        /// citations. An entry that doesn't split into exactly three
        /// pipe-separated, non-empty course/kind parts is skipped rather
        /// than crashing or half-populating a citation — the model produced
        /// this text freehand, not through a schema, so a malformed entry
        /// is an expected occasional shape, not a bug to trap on.
        static func parseCitations(_ raw: String) -> [AssistantCitation] {
            raw.split(separator: ";").compactMap { entry -> AssistantCitation? in
                let parts = entry.split(separator: "|", omittingEmptySubsequences: false)
                guard parts.count == 3 else { return nil }
                let course = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let kind = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !course.isEmpty, !kind.isEmpty else { return nil }
                return AssistantCitation(course: course, source: kind, detail: detail.isEmpty ? nil : detail)
            }
        }
    }

    // MARK: - Friendly error messages

    /// What to say instead of a raw status code or stack trace, and — for
    /// every case this can be reached with — followed immediately by the
    /// on-device answer, never left standing alone. Rewritten from
    /// `ClaudeAssistantResponder.friendlyMessage(for:)` to drop every
    /// mention of an API key: there is no student-managed credential left
    /// to point at, so a message like the old "check your api key in
    /// settings" would just be wrong now, not merely dated.
    static func friendlyMessage(for error: BackendError) -> String {
        switch error {
        case .notConfigured:
            return "ask isn't connected to a server yet — answering from your phone instead."
        case .unauthorized:
            return "couldn't verify your session with the server — answering from your phone instead."
        case let .http(status):
            return "couldn't reach the server (\(status)) — answering from your phone instead."
        case .quotaExceeded:
            return "you've hit today's question limit — answering from your phone instead."
        case .transport:
            return "couldn't reach the server — answering from your phone instead."
        case .decoding:
            return "something went wrong building the request — answering from your phone instead."
        }
    }

    /// `client.askStream` only ever throws `BackendError`, but the `catch`
    /// in `run(...)` is typed `Error` (Swift has no `catch` clause that
    /// narrows to one concrete error type while still binding it), so this
    /// overload does the narrowing once instead of every call site
    /// repeating an `as?` and a fallback case.
    private static func friendlyMessage(for error: Error) -> String {
        guard let backendError = error as? BackendError else { return friendlyMessage(for: .transport) }
        return friendlyMessage(for: backendError)
    }

    /// A short apology appended after whatever text already rendered when
    /// the stream itself reports an `error` event (`backend/PROTOCOL.md`'s
    /// `data: {"type":"error",...}`) rather than ending in `done`. Keyed off
    /// `code`, not the free-text `message` the server sends: `message` is
    /// meant for logs, and echoing server-authored text straight to the
    /// transcript is exactly the kind of thing this Kit avoids doing with
    /// any text it didn't compose itself.
    private static func midStreamErrorMessage(for code: String) -> String {
        switch code {
        case "quota_exceeded":
            return "\n\n(you've hit today's question limit for now.)"
        default:
            return "\n\n(something went wrong on the server's side.)"
        }
    }
}
