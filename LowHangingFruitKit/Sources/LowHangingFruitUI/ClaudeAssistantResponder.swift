import Foundation

// MARK: – The one place LHF sends class data off-device
//
// Every other file in this Kit keeps the student's syllabi, deadlines and
// announcements on the phone. This one does not: `reply(to:context:)` POSTs
// `context.contextDocument` — the rendered syllabus/deadline/announcement
// text `AssistantContext` carries — to Anthropic's Messages API, along with
// the question being asked. That only happens because the student typed
// their own Anthropic API key into Settings (`SettingsPage.swift`'s
// "announcement watcher" section is where that field already lives — see
// `AnthropicKeyStore`) and `AssistantView` only constructs this type when
// `AnthropicKeyStore.load()` is non-empty. No key, no network call, no data
// leaves the device; the scripted responder answers instead.
//
// The key itself is a bearer credential — anyone holding it can spend the
// student's own Anthropic balance with no further proof of identity — which
// is why `AnthropicKeyStore` is Keychain-backed
// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) rather than
// `UserDefaults`, exactly like `SessionCookieStore`'s Canvas cookies and
// `ICSFeedURLStore`'s token-bearing feed URL. Nothing in this file may widen
// that: never log the key, never log the question, never log
// `contextDocument`. A crash log or a debug print of any of the three is a
// credential leak or a transcript of a private conversation about someone's
// grades, and neither belongs anywhere persistent.

/// Calls Anthropic's Messages API with streaming enabled and turns the
/// Server-Sent Events wire format into the `AssistantChunk`s the existing
/// `ask` screen already knows how to render — the whole point of the
/// `AssistantResponder` protocol is that the view never has to learn this
/// type exists.
struct ClaudeAssistantResponder: AssistantResponder, Sendable {
    /// The student's own Anthropic API key, loaded by the caller from
    /// `AnthropicKeyStore` — this type never touches the Keychain itself, so
    /// it stays trivially testable (hand it any string) and has exactly one
    /// job.
    let apiKey: String

    /// Injectable for the same reason `ClaudeAnnouncementExtractor` takes
    /// one: nothing in this file's own tests constructs a real session (the
    /// brief this was built from is explicit that no test may touch the
    /// network), but a real streaming call needs *some* session, and hanging
    /// the default off `.shared` rather than hard-coding it keeps the door
    /// open for a future test double without another signature change.
    let session: URLSession

    static let model = "claude-opus-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let maxTokens = 2048

    // MARK: - The frozen instruction block
    //
    // A `let` constant, never string-interpolated. Prompt caching is a
    // *prefix* match across the rendered request — Anthropic renders
    // `tools` → `system` → `messages` in that order, and any byte that
    // differs anywhere in that prefix invalidates the cache from that byte
    // on. `contextDocument` (the expensive, syllabus-sized part) is cached
    // by putting it in the system block *after* this one, so this block
    // must itself be byte-identical turn over turn and student over
    // student — the instant it were built with `"...for \(courseCode)..."`
    // or similar, every request would again share nothing with the last one
    // and the cache breakpoint below would have nothing to break on top of.
    private static let systemInstructions = """
    You are the "ask" assistant inside Low Hanging Fruit, a Penn student's \
    personal academic dashboard. You will be given a document containing \
    everything the app currently holds about the student's classes — \
    syllabi, deadlines, announcements — followed by the student's question.

    Answer only from that document. Do not use outside knowledge of Penn, \
    these courses, or their policies, and do not guess at a number, date or \
    rule the document doesn't state. If the document doesn't answer the \
    question, say plainly that you don't have that, and suggest what you do \
    have that's close.

    Write the way a classmate who actually read the syllabus would: the \
    answer up front, the exception or caveat second, no restating the \
    question, no "As an AI" framing.

    If your answer relies on specific facts from the document, end it with \
    a line of its own — nothing else on that line, nothing after it — in \
    exactly this form:
    <sources>COURSE|kind|detail; COURSE|kind|detail</sources>
    COURSE is the course code as it appears in the document, such as \
    "PHYS 0151". kind is one short lowercase word: syllabus, canvas, or \
    announcement. detail is a few words locating the fact, such as \
    "\u{a7}4 attendance, p.2". Separate multiple sources with "; ". If \
    nothing in your answer traces back to a specific cited fact, omit the \
    <sources> block entirely — never emit an empty or invented one.
    """

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func reply(to prompt: String, context: AssistantContext) -> AsyncStream<AssistantChunk> {
        let apiKey = apiKey
        let session = session
        let requestBody = Self.buildRequestBody(question: prompt, context: context)

        return AsyncStream { continuation in
            let task = Task {
                await Self.run(
                    requestBody: requestBody,
                    apiKey: apiKey,
                    session: session,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The actual network turn. A `static` function taking every dependency
    /// as a parameter (no `self`) for the same reason
    /// `ClaudeAnnouncementExtractor.decodeExtraction` is `static` — it keeps
    /// the *parsing* logic it calls out to (`parseSSELine`,
    /// `SourcesBlockSplitter`) reachable and testable without this
    /// network-touching half getting dragged along.
    private static func run(
        requestBody: MessagesRequestBody,
        apiKey: String,
        session: URLSession,
        continuation: AsyncStream<AssistantChunk>.Continuation
    ) async {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Pairs with `fallbacks: "default"` in the body below — Anthropic
        // rejects the request with a 400 if either is present without the
        // other, so the two must always change together.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            // An `Encodable` struct built entirely from `String`/`Int`/`Bool`
            // fields cannot actually fail to encode; this branch exists so
            // the function has no silent way to drop the request instead of
            // reporting something, not because it's expected to run.
            continuation.yield(.text(friendlyMessage(for: .decodingFailed)))
            continuation.finish()
            return
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if !Task.isCancelled {
                continuation.yield(.text(friendlyMessage(for: .transport)))
            }
            continuation.finish()
            return
        }

        guard let http = response as? HTTPURLResponse else {
            continuation.yield(.text(friendlyMessage(for: .transport)))
            continuation.finish()
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            continuation.yield(.text(friendlyMessage(for: .http(http.statusCode))))
            continuation.finish()
            return
        }

        var splitter = SourcesBlockSplitter()
        var stopReason: String?

        do {
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard let event = parseSSELine(line) else { continue }
                switch event {
                case let .textDelta(text):
                    let visible = splitter.feed(text)
                    if !visible.isEmpty { continuation.yield(.text(visible)) }
                case let .stopReason(reason):
                    stopReason = reason
                case .messageStop:
                    break
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

            // A refusal is HTTP 200 with a stop reason, not an error status
            // — Anthropic's own docs on `stop_reason` describe it that way,
            // and it is easy to miss because every other failure mode in
            // this file (bad key, rate limit, dropped connection) shows up
            // as something obviously wrong. With `fallbacks: "default"` set
            // above, the API has already retried the turn against another
            // model server-side before giving up, so a refusal reaching
            // here means the whole fallback chain declined — there is
            // nothing left to retry, only something to tell the student.
            if stopReason == "refusal" {
                continuation.yield(.text(refusalMessage))
            }
        }

        continuation.finish()
    }

    // MARK: - Request construction (pure — no network, fully unit-testable)

    /// The one seam every request-shape test in
    /// `ClaudeAssistantResponderTests` drives. Free of `apiKey`/`session` so
    /// a test can call it directly without constructing a real responder.
    static func buildRequestBody(question: String, context: AssistantContext) -> MessagesRequestBody {
        MessagesRequestBody(
            model: model,
            maxTokens: maxTokens,
            stream: true,
            fallbacks: "default",
            outputConfig: OutputConfig(effort: "low"),
            system: [
                // Block 0: the frozen instructions above — no cache marker.
                // It's small, so caching it buys nothing, and giving it one
                // would only add a second cache write to bill on the first
                // turn of every conversation for no benefit.
                SystemBlock(text: systemInstructions, cacheControl: nil),
                // Block 1: the syllabus/deadline/announcement document —
                // the cache breakpoint. See `AssistantContext.contextDocument`
                // and `AssistantContext.askedAt`'s doc comments for the full
                // reasoning; the short version is that this string is
                // identical on every turn of a conversation and expensive,
                // which is exactly what `cache_control` is for.
                SystemBlock(text: context.contextDocument, cacheControl: CacheControl()),
            ],
            messages: [
                ChatTurn(role: "user", content: userContent(question: question, askedAt: context.askedAt)),
            ]
        )
    }

    /// The current-date line plus the question, joined the same way
    /// `ClaudeAnnouncementExtractor.userContent(for:now:)` joins its context
    /// lines ahead of its body.
    ///
    /// This is the wrong-fix callout the brief asked for: the tempting place
    /// to put "today is 2026-09-02" is inside `contextDocument`, right next
    /// to the syllabus text it would read naturally alongside. That is
    /// exactly what must not happen — `contextDocument` sits *before* the
    /// cache breakpoint (it *is* the cache breakpoint), so a date string
    /// that changes daily (and, since `askedAt` carries a timestamp, on
    /// every single request) baked into it would invalidate the cached
    /// prefix on every turn, silently taking the cache hit rate to zero
    /// while looking, from the code, like caching was wired up correctly.
    /// The date belongs in the per-turn user message, which is never
    /// cached and costs nothing to vary.
    static func userContent(question: String, askedAt: Date) -> String {
        let iso = ISO8601DateFormatter()
        return "Current date: \(iso.string(from: askedAt))\n\n\(question)"
    }

    // MARK: - SSE parsing (pure — no network, fully unit-testable)

    /// The handful of Anthropic streaming events this responder acts on,
    /// reduced from the full wire shape. `usage`, `model`, content-block
    /// indices and the rest are real fields on the actual API but nothing
    /// downstream of this parser reads them, so they are never decoded at
    /// all rather than carried in unread properties.
    enum StreamEvent: Sendable, Equatable {
        case textDelta(String)
        case stopReason(String)
        case messageStop
    }

    /// Parses one line of the incoming byte stream.
    ///
    /// Anthropic's SSE format pairs an `event: <name>` line with a
    /// `data: <json>` line for each event, but the JSON body repeats the
    /// same name in its own `"type"` field (`"content_block_delta"`,
    /// `"message_delta"`, …), so the `event:` line is redundant for a parser
    /// that only reads `data:` — this one ignores it outright, which has the
    /// convenient side effect that blank keep-alive lines and any other line
    /// shape are silently skipped too, with no separate "is this a line I
    /// even recognize" branch needed.
    ///
    /// Returns `nil` — never throws, never crashes — for anything that
    /// isn't a `data:` line carrying decodable JSON, and for every event
    /// type this responder doesn't act on (`message_start`,
    /// `content_block_start`, `content_block_stop`, `ping`, and whatever
    /// Anthropic adds next; the streaming guide is explicit that clients
    /// should ignore event types they don't recognize rather than fail on
    /// them, since new ones are additive).
    static func parseSSELine(_ line: String) -> StreamEvent? {
        guard line.hasPrefix("data: ") else { return nil }
        let json = line.dropFirst("data: ".count)
        guard let data = json.data(using: .utf8) else { return nil }
        guard let envelope = try? JSONDecoder().decode(SSEEventEnvelope.self, from: data) else { return nil }

        switch envelope.type {
        case "content_block_delta":
            guard let delta = envelope.delta, delta.type == "text_delta", let text = delta.text else { return nil }
            return .textDelta(text)
        case "message_delta":
            guard let reason = envelope.delta?.stopReason else { return nil }
            return .stopReason(reason)
        case "message_stop":
            return .messageStop
        default:
            return nil
        }
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

    // MARK: - Errors

    /// Mirrors `ClaudeAnnouncementExtractor.ExtractionError`'s shape:
    /// `Sendable`, `Equatable`, and — for the HTTP case — carrying only the
    /// status code, never the URL or response body, so a stray log line
    /// downstream can never leak either.
    ///
    /// Unlike that extractor, nothing here ever `throw`s one of these:
    /// `AssistantResponder.reply` returns a non-throwing `AsyncStream`
    /// because the screen has no error-presentation path of its own, only a
    /// transcript to append text to. So this enum's only job is to select a
    /// student-facing sentence via `friendlyMessage(for:)` — an assistant
    /// that fails silently into an empty stream is indistinguishable from
    /// one that's still thinking, which is worse than a short apology.
    enum ResponderError: Error, Sendable, Equatable {
        case http(Int)
        case transport
        case decodingFailed
    }

    static func friendlyMessage(for error: ResponderError) -> String {
        switch error {
        case let .http(status):
            return "couldn't reach claude (\(status)) — check your api key in settings."
        case .transport:
            return "couldn't reach claude — check your connection and try again."
        case .decodingFailed:
            return "couldn't reach claude — something went wrong building the request."
        }
    }

    private static let refusalMessage =
        "claude didn't answer that one. try rephrasing the question, or ask something else about your classes."
}

// MARK: - Request Codable shapes
//
// Hand-written to mirror the exact JSON Anthropic's Messages API expects,
// the same choice `ClaudeAnnouncementExtractor`'s request structs make and
// for the same reason: a typo in one of these property names is a compile
// error, where the same typo in a `[String: Any]` dictionary key is a
// runtime bug that only shows up against a live call.

struct MessagesRequestBody: Encodable {
    let model: String
    let maxTokens: Int
    let stream: Bool
    /// Server-side refusal fallback — Anthropic retries the turn against
    /// another model if the first one declines, before ever reaching this
    /// client. Must travel together with the `anthropic-beta:
    /// server-side-fallback-2026-07-01` request header; either one without
    /// the other is a 400.
    let fallbacks: String
    let outputConfig: OutputConfig
    let system: [SystemBlock]
    let messages: [ChatTurn]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case stream
        case fallbacks
        case outputConfig = "output_config"
        case system
        case messages
    }

    // Deliberately absent from this struct, not merely left `nil`:
    // `thinking` (this model's thinking is adaptive by default;
    // `budget_tokens` is a 400 on it) and `temperature`/`top_p`/`top_k`
    // (removed on this model, also a 400). A field that doesn't exist on
    // the type can't be reintroduced by a well-meaning future edit that
    // sees a `nil` and "fixes" it.
}

/// Retrieval-style Q&A over a supplied document is latency-sensitive, which
/// is what `effort: "low"` buys — the field lives inside `output_config`,
/// never at the top level of the request.
struct OutputConfig: Encodable {
    let effort: String
}

struct SystemBlock: Encodable {
    let type = "text"
    let text: String
    /// `nil` on every block except the context document — encoding a `nil`
    /// optional property omits the key entirely (Swift's synthesized
    /// `Encodable` conformance calls `encodeIfPresent` for `Optional`
    /// properties), which is what keeps `cache_control` off the first
    /// system block without a second, hand-written encode(to:).
    let cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case cacheControl = "cache_control"
    }
}

/// `"ephemeral"` is the only cache lifetime Anthropic currently offers, so
/// there is nothing to parameterize here.
struct CacheControl: Encodable {
    let type = "ephemeral"
}

struct ChatTurn: Encodable {
    let role: String
    let content: String
}

// MARK: - Streaming response Decodable shapes

/// One `data:` line's JSON payload, reduced to the fields
/// `parseSSELine(_:)` reads. `type` distinguishes
/// `content_block_delta`/`message_delta`/`message_stop`/everything-else;
/// `delta` is present with different inner shapes depending on which of
/// those it is, hence both of `DeltaPayload`'s fields are optional rather
/// than this being modeled as several separate response types — one
/// `Decodable` shape handles every event type this parser sees.
struct SSEEventEnvelope: Decodable {
    let type: String
    let delta: DeltaPayload?
}

struct DeltaPayload: Decodable {
    /// Present (`"text_delta"`) on a `content_block_delta`'s inner delta,
    /// absent on a `message_delta`'s.
    let type: String?
    /// Present on a `text_delta`.
    let text: String?
    /// Present on a `message_delta`'s inner delta.
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case stopReason = "stop_reason"
    }
}
