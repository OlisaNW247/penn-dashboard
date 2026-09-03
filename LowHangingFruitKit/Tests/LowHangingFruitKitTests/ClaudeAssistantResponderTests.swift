import Foundation
import Testing
@testable import LowHangingFruitUI

/// Covers `ClaudeAssistantResponder`'s pure seams only — SSE line parsing,
/// the `<sources>` splitter, and request-body construction. Nothing here
/// constructs a real responder or touches `URLSession`: the brief this was
/// built from is explicit that no test in this suite may make a network
/// call, matching how `AnnouncementExtractionTests` drives
/// `ClaudeAnnouncementExtractor` through `decodeExtraction(responseBody:now:)`
/// alone rather than `extract(from:now:)`.
///
/// `AnthropicKeyStore` and the responder-selection branch in
/// `AssistantView.init` get no test here for the same reason
/// `AnnouncementExtractionTests` gives `AnthropicKeyStore` a pass: Keychain
/// access inside a sandboxed test runner is exactly the kind of
/// environment-dependent behavior this suite avoids, and the store itself is
/// already a line-for-line mirror of `ICSFeedURLStore`.
@Suite("Claude assistant responder")
struct ClaudeAssistantResponderTests {

    // MARK: - SSE line parsing

    @Suite("SSE line parsing")
    struct SSELineParsing {
        @Test("a content_block_delta text_delta line yields its text")
        func textDeltaYieldsText() {
            let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Two absences"}}"#
            #expect(ClaudeAssistantResponder.parseSSELine(line) == .textDelta("Two absences"))
        }

        @Test("a message_delta line yields its stop_reason")
        func messageDeltaYieldsStopReason() {
            let line = #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":42}}"#
            #expect(ClaudeAssistantResponder.parseSSELine(line) == .stopReason("end_turn"))
        }

        @Test("a message_stop line yields messageStop")
        func messageStopYieldsMessageStop() {
            let line = #"data: {"type":"message_stop"}"#
            #expect(ClaudeAssistantResponder.parseSSELine(line) == .messageStop)
        }

        @Test("unrecognized event types are ignored, not treated as an error", arguments: [
            #"data: {"type":"message_start","message":{"id":"msg_1"}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"ping"}"#,
            #"data: {"type":"some_future_event_this_client_has_never_heard_of"}"#,
        ])
        func unknownEventTypesAreIgnored(line: String) {
            #expect(ClaudeAssistantResponder.parseSSELine(line) == nil)
        }

        @Test("a non-data line is ignored")
        func nonDataLineIsIgnored() {
            #expect(ClaudeAssistantResponder.parseSSELine("event: content_block_delta") == nil)
            #expect(ClaudeAssistantResponder.parseSSELine("") == nil)
        }

        @Test("a malformed, non-JSON data line is ignored rather than crashing")
        func malformedDataLineIsIgnored() {
            #expect(ClaudeAssistantResponder.parseSSELine("data: this is not json") == nil)
            #expect(ClaudeAssistantResponder.parseSSELine("data: {\"type\": \"content_block_delta\", \"delta\":") == nil)
        }

        @Test("a content_block_delta whose inner delta isn't text_delta is ignored")
        func nonTextDeltaContentBlockIsIgnored() {
            // Anthropic's other content-block delta shape, input_json_delta,
            // belongs to tool use, which this responder never asks for.
            let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#
            #expect(ClaudeAssistantResponder.parseSSELine(line) == nil)
        }
    }

    // MARK: - The <sources> splitter

    @Suite("Sources block splitter")
    struct SourcesSplitting {
        @Test("text with no sources block passes through unchanged")
        func noBlockPassesThroughUnchanged() {
            var splitter = ClaudeAssistantResponder.SourcesBlockSplitter()
            let visible = splitter.feed("Two absences cost you nothing.") + splitter.finish()
            #expect(visible == "Two absences cost you nothing.")
            #expect(splitter.citations.isEmpty)
        }

        @Test("a well-formed block is stripped from the visible text and parsed into citations")
        func wellFormedBlockIsStrippedAndParsed() {
            var splitter = ClaudeAssistantResponder.SourcesBlockSplitter()
            let input = "Two absences cost you nothing.\n<sources>PHYS 0151|syllabus|\u{a7}4 attendance, p.2</sources>"
            let visible = splitter.feed(input) + splitter.finish()

            #expect(visible == "Two absences cost you nothing.\n")
            #expect(splitter.citations == [
                AssistantCitation(course: "PHYS 0151", source: "syllabus", detail: "\u{a7}4 attendance, p.2"),
            ])
        }

        @Test("multiple sources, one malformed, is skipped without dropping the valid ones")
        func malformedEntryIsSkipped() {
            let raw = "PHYS 0151|syllabus|p.2; this-entry-has-no-pipes-at-all; PSYC 1010|canvas|"
            let citations = ClaudeAssistantResponder.SourcesBlockSplitter.parseCitations(raw)

            #expect(citations == [
                AssistantCitation(course: "PHYS 0151", source: "syllabus", detail: "p.2"),
                AssistantCitation(course: "PSYC 1010", source: "canvas", detail: nil),
            ])
        }

        @Test("an entry with an empty course or kind is skipped")
        func emptyCourseOrKindIsSkipped() {
            let raw = "|syllabus|p.2; PHYS 0151||p.2"
            #expect(ClaudeAssistantResponder.SourcesBlockSplitter.parseCitations(raw).isEmpty)
        }

        @Test("a block split across several deltas is still handled correctly")
        func blockSplitAcrossDeltasIsHandled() {
            var splitter = ClaudeAssistantResponder.SourcesBlockSplitter()
            var visible = ""
            visible += splitter.feed("Labs are stricter than lecture. ")
            visible += splitter.feed("<sour")
            visible += splitter.feed("ces>PHYS 0151|syllabus|")
            visible += splitter.feed("p.2</sour")
            visible += splitter.feed("ces>")
            visible += splitter.finish()

            #expect(visible == "Labs are stricter than lecture. ")
            #expect(splitter.citations == [
                AssistantCitation(course: "PHYS 0151", source: "syllabus", detail: "p.2"),
            ])
        }

        @Test("the block is omitted entirely when the model cites nothing")
        func noBlockMeansNoCitations() {
            var splitter = ClaudeAssistantResponder.SourcesBlockSplitter()
            let visible = splitter.feed("I don't have that in your syllabus.") + splitter.finish()
            #expect(visible == "I don't have that in your syllabus.")
            #expect(splitter.citations.isEmpty)
        }

        // MARK: Partial-tag buffering — the flicker this type exists to prevent

        @Test("a lone partial opening tag emits nothing visible yet")
        func partialOpenTagEmitsNothingYet() {
            var splitter = ClaudeAssistantResponder.SourcesBlockSplitter()
            #expect(splitter.feed("<sou") == "")
        }

        @Test("a '<' that turns out to be ordinary prose eventually emits in full")
        func ordinaryLessThanEventuallyEmits() {
            var splitter = ClaudeAssistantResponder.SourcesBlockSplitter()
            // The '<' arrives at the very end of a chunk, with nothing yet
            // to disambiguate it — it must be buffered, not shown, and not
            // discarded either.
            let first = splitter.feed("2 is fewer than 3, i.e. 2 <")
            #expect(first == "2 is fewer than 3, i.e. 2 ")

            // The next chunk proves it was never going to become <sources>;
            // the buffered '<' must now surface, immediately followed by
            // whatever came after it in the same chunk.
            let second = splitter.feed(" 3.")
            #expect(second == "< 3.")

            #expect(first + second == "2 is fewer than 3, i.e. 2 < 3.")
            #expect(splitter.citations.isEmpty)
        }

        @Test("a stream that ends mid-candidate flushes the buffered text as prose")
        func unfinishedCandidateFlushesOnFinish() {
            var splitter = ClaudeAssistantResponder.SourcesBlockSplitter()
            let mid = splitter.feed("the cutoff is <sour")
            #expect(mid == "the cutoff is ")
            #expect(splitter.finish() == "<sour")
        }
    }

    // MARK: - Request body construction

    @Suite("Request body construction")
    struct RequestBodyConstruction {
        private static func encodedDictionary(
            question: String = "what's my phys attendance policy?",
            context: AssistantContext = AssistantContext(
                courseCodes: ["PHYS 0151"],
                contextDocument: "PHYS 0151 syllabus: two absences are free..."
            )
        ) throws -> [String: Any] {
            let body = ClaudeAssistantResponder.buildRequestBody(question: question, context: context)
            let data = try JSONEncoder().encode(body)
            let object = try JSONSerialization.jsonObject(with: data)
            return try #require(object as? [String: Any])
        }

        @Test("model is the exact, undated string")
        func modelIsExact() throws {
            let dict = try Self.encodedDictionary()
            #expect(dict["model"] as? String == "claude-opus-5")
        }

        @Test("stream is true")
        func streamIsTrue() throws {
            let dict = try Self.encodedDictionary()
            #expect(dict["stream"] as? Bool == true)
        }

        @Test("fallbacks is the scalar \"default\"")
        func fallbacksIsDefault() throws {
            let dict = try Self.encodedDictionary()
            #expect(dict["fallbacks"] as? String == "default")
        }

        @Test("output_config.effort is \"low\", and effort is nested, not top-level")
        func effortIsLowAndNested() throws {
            let dict = try Self.encodedDictionary()
            #expect(dict["effort"] == nil)
            let outputConfig = try #require(dict["output_config"] as? [String: Any])
            #expect(outputConfig["effort"] as? String == "low")
        }

        @Test("no thinking key is ever sent")
        func noThinkingKey() throws {
            let dict = try Self.encodedDictionary()
            #expect(dict.keys.contains("thinking") == false)
        }

        @Test("no temperature, top_p, or top_k key is ever sent")
        func noSamplingKeys() throws {
            let dict = try Self.encodedDictionary()
            #expect(dict.keys.contains("temperature") == false)
            #expect(dict.keys.contains("top_p") == false)
            #expect(dict.keys.contains("top_k") == false)
        }

        @Test("cache_control sits on the second system block only")
        func cacheControlOnSecondBlockOnly() throws {
            let dict = try Self.encodedDictionary()
            let system = try #require(dict["system"] as? [[String: Any]])
            #expect(system.count == 2)
            #expect(system[0].keys.contains("cache_control") == false)
            #expect(system[1].keys.contains("cache_control") == true)
        }

        @Test("the second system block carries the context document verbatim")
        func secondBlockCarriesContextDocument() throws {
            let dict = try Self.encodedDictionary(context: AssistantContext(
                courseCodes: ["PHYS 0151"],
                contextDocument: "the exact document text"
            ))
            let system = try #require(dict["system"] as? [[String: Any]])
            #expect(system[1]["text"] as? String == "the exact document text")
        }

        @Test("the first system block is the frozen instruction constant, not built per-request")
        func firstBlockIsFrozenAcrossDifferentContexts() throws {
            let contextA = AssistantContext(courseCodes: ["PHYS 0151"], contextDocument: "doc A")
            let contextB = AssistantContext(courseCodes: ["CIS 1200"], contextDocument: "doc B")
            let dictA = try Self.encodedDictionary(question: "question one", context: contextA)
            let dictB = try Self.encodedDictionary(question: "question two", context: contextB)

            let systemA = try #require(dictA["system"] as? [[String: Any]])
            let systemB = try #require(dictB["system"] as? [[String: Any]])
            #expect(systemA[0]["text"] as? String == systemB[0]["text"] as? String)
        }

        @Test("the user message carries the current date ahead of the question, not the cached document")
        func userMessageCarriesDateAndQuestion() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let askedAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))!
            let context = AssistantContext(
                courseCodes: ["PHYS 0151"],
                contextDocument: "the syllabus",
                askedAt: askedAt
            )
            let dict = try Self.encodedDictionary(question: "when's my next exam?", context: context)
            let messages = try #require(dict["messages"] as? [[String: Any]])
            let content = try #require(messages.first?["content"] as? String)

            #expect(content.contains("2026-09-02"))
            #expect(content.hasSuffix("when's my next exam?"))

            // The date must never leak into the cached document itself —
            // that's the whole point of carrying `askedAt` separately.
            let system = try #require(dict["system"] as? [[String: Any]])
            #expect((system[1]["text"] as? String)?.contains("2026-09-02") == false)
        }
    }

    // MARK: - Friendly error messages

    @Suite("Friendly error messages")
    struct FriendlyErrorMessages {
        @Test("an HTTP failure names only the status code")
        func httpFailureNamesStatusCode() {
            let message = ClaudeAssistantResponder.friendlyMessage(for: .http(401))
            #expect(message.contains("401"))
            #expect(message.contains("api key"))
        }

        @Test("http error messages never carry the endpoint URL")
        func httpFailureNamesNoURL() {
            let message = ClaudeAssistantResponder.friendlyMessage(for: .http(500))
            #expect(!message.contains("api.anthropic.com"))
        }
    }
}
