import Foundation
import Testing
import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Covers `BackendAssistantResponder`'s pure seams only — the `<sources>`
/// splitter, `AskStreamEvent` line parsing, request construction, and the
/// friendly error strings. Nothing here constructs a real `BackendClient`
/// or touches `URLSession`, matching the ban this suite's predecessor
/// (`ClaudeAssistantResponderTests`) operated under and the reasoning
/// `AnnouncementExtractionTests` gives for the same restriction on
/// `ClaudeAnnouncementExtractor`.
///
/// `BackendConfiguration`, `BackendIdentityStore` and `BackendSession` get no
/// test here for the same reason `AnthropicKeyStore` never got one:
/// Keychain access and `UserDefaults.standard` launch-argument reads inside a
/// sandboxed test runner are exactly the kind of environment-dependent
/// behavior this suite avoids, and `SharedDefaults.isTestRunner` already
/// guarantees `BackendConfiguration.current` is `nil` for every test process
/// regardless.
@Suite("Backend assistant responder")
struct BackendAssistantResponderTests {

    // MARK: - The <sources> splitter
    //
    // Moved verbatim from `ClaudeAssistantResponderTests` — the splitter's
    // behavior didn't change when it moved from `ClaudeAssistantResponder`
    // to `BackendAssistantResponder`, only its address.

    @Suite("Sources block splitter")
    struct SourcesSplitting {
        @Test("text with no sources block passes through unchanged")
        func noBlockPassesThroughUnchanged() {
            var splitter = BackendAssistantResponder.SourcesBlockSplitter()
            let visible = splitter.feed("Two absences cost you nothing.") + splitter.finish()
            #expect(visible == "Two absences cost you nothing.")
            #expect(splitter.citations.isEmpty)
        }

        @Test("a well-formed block is stripped from the visible text and parsed into citations")
        func wellFormedBlockIsStrippedAndParsed() {
            var splitter = BackendAssistantResponder.SourcesBlockSplitter()
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
            let citations = BackendAssistantResponder.SourcesBlockSplitter.parseCitations(raw)

            #expect(citations == [
                AssistantCitation(course: "PHYS 0151", source: "syllabus", detail: "p.2"),
                AssistantCitation(course: "PSYC 1010", source: "canvas", detail: nil),
            ])
        }

        @Test("an entry with an empty course or kind is skipped")
        func emptyCourseOrKindIsSkipped() {
            let raw = "|syllabus|p.2; PHYS 0151||p.2"
            #expect(BackendAssistantResponder.SourcesBlockSplitter.parseCitations(raw).isEmpty)
        }

        @Test("a block split across several deltas is still handled correctly")
        func blockSplitAcrossDeltasIsHandled() {
            var splitter = BackendAssistantResponder.SourcesBlockSplitter()
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
            var splitter = BackendAssistantResponder.SourcesBlockSplitter()
            let visible = splitter.feed("I don't have that in your syllabus.") + splitter.finish()
            #expect(visible == "I don't have that in your syllabus.")
            #expect(splitter.citations.isEmpty)
        }

        // MARK: Partial-tag buffering — the flicker this type exists to prevent

        @Test("a lone partial opening tag emits nothing visible yet")
        func partialOpenTagEmitsNothingYet() {
            var splitter = BackendAssistantResponder.SourcesBlockSplitter()
            #expect(splitter.feed("<sou") == "")
        }

        @Test("a '<' that turns out to be ordinary prose eventually emits in full")
        func ordinaryLessThanEventuallyEmits() {
            var splitter = BackendAssistantResponder.SourcesBlockSplitter()
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
            var splitter = BackendAssistantResponder.SourcesBlockSplitter()
            let mid = splitter.feed("the cutoff is <sour")
            #expect(mid == "the cutoff is ")
            #expect(splitter.finish() == "<sour")
        }
    }

    // MARK: - AskStreamEvent line parsing

    @Suite("Ask stream event parsing")
    struct AskStreamEventParsing {
        @Test("a delta line yields its text")
        func deltaYieldsText() {
            let line = #"data: {"type":"delta","text":"Two absences"}"#
            guard case let .delta(text)? = AskStreamEvent.parse(line: line) else {
                Issue.record("expected .delta")
                return
            }
            #expect(text == "Two absences")
        }

        @Test("a done line yields its usage")
        func doneYieldsUsage() {
            let line = #"data: {"type":"done","usage":{"promptTokens":120,"completionTokens":40,"cachedTokens":80}}"#
            guard case let .done(promptTokens, completionTokens, cachedTokens)? = AskStreamEvent.parse(line: line) else {
                Issue.record("expected .done")
                return
            }
            #expect(promptTokens == 120)
            #expect(completionTokens == 40)
            #expect(cachedTokens == 80)
        }

        @Test("an error line yields its code and message")
        func errorYieldsCodeAndMessage() {
            let line = #"data: {"type":"error","code":"quota_exceeded","message":"daily limit reached"}"#
            guard case let .error(code, message)? = AskStreamEvent.parse(line: line) else {
                Issue.record("expected .error")
                return
            }
            #expect(code == "quota_exceeded")
            #expect(message == "daily limit reached")
        }

        @Test("a comment line (SSE keep-alive) is ignored, not treated as an error")
        func commentLineIsIgnored() {
            #expect(AskStreamEvent.parse(line: ": keep-alive") == nil)
        }

        @Test("a blank line is ignored")
        func blankLineIsIgnored() {
            #expect(AskStreamEvent.parse(line: "") == nil)
        }

        @Test("a malformed, non-JSON data line is ignored rather than crashing")
        func malformedDataLineIsIgnored() {
            #expect(AskStreamEvent.parse(line: "data: this is not json") == nil)
        }

        @Test("an unrecognized event type is ignored, not treated as an error")
        func unknownEventTypeIsIgnored() {
            #expect(AskStreamEvent.parse(line: #"data: {"type":"some_future_event_this_client_has_never_heard_of"}"#) == nil)
        }
    }

    // MARK: - Ask request construction

    @Suite("Ask request construction")
    struct AskRequestConstruction {
        @Test("the question is carried verbatim")
        func questionCarriedVerbatim() {
            let context = AssistantContext(courseCodes: ["PHYS 0151"], contextDocument: "doc")
            let request = BackendAssistantResponder.makeRequest(
                question: "what's my phys attendance policy?",
                context: context
            )
            #expect(request.question == "what's my phys attendance policy?")
        }

        @Test("askedAt is carried on the request, never embedded in the context document")
        func askedAtCarriedNotEmbedded() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let askedAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))!
            let context = AssistantContext(
                courseCodes: ["PHYS 0151"],
                contextDocument: "the syllabus",
                askedAt: askedAt
            )
            let request = BackendAssistantResponder.makeRequest(question: "when's my next exam?", context: context)

            #expect(request.askedAt == askedAt)
            #expect(!request.contextDocument.contains("2026"))
        }

        @Test("the context document is carried verbatim")
        func contextDocumentCarriedVerbatim() {
            let context = AssistantContext(courseCodes: ["PHYS 0151"], contextDocument: "the exact document text")
            let request = BackendAssistantResponder.makeRequest(question: "q", context: context)
            #expect(request.contextDocument == "the exact document text")
        }

        @Test("courseIDs come from the knowledge base's courses, not courseCodes")
        func courseIDsFromKnowledge() {
            var context = AssistantContext(courseCodes: ["CIS 2400", "ECON 1", "MGMT 1010"])
            context.knowledge = AssistantFixture.knowledge
            let request = BackendAssistantResponder.makeRequest(question: "q", context: context)
            #expect(request.courseIDs == AssistantFixture.knowledge.courses.map(\.courseID))
        }

        @Test("excerpts are empty when the knowledge base is empty")
        func excerptsEmptyWhenKnowledgeEmpty() {
            let context = AssistantContext(courseCodes: ["PHYS 0151"], contextDocument: "doc")
            let request = BackendAssistantResponder.makeRequest(
                question: "what's my attendance policy?",
                context: context
            )
            #expect(request.excerpts.isEmpty)
        }

        @Test("history is always empty")
        func historyIsEmpty() {
            let context = AssistantContext(courseCodes: ["PHYS 0151"], contextDocument: "doc")
            let request = BackendAssistantResponder.makeRequest(question: "q", context: context)
            #expect(request.history.isEmpty)
        }
    }

    // MARK: - Friendly error messages

    @Suite("Friendly error messages")
    struct FriendlyErrorMessages {
        @Test("no friendly message ever mentions an API key or Anthropic", arguments: [
            BackendError.notConfigured,
            BackendError.unauthorized,
            BackendError.http(401),
            BackendError.http(500),
            BackendError.quotaExceeded(resetAt: nil),
            BackendError.transport,
            BackendError.decoding,
        ])
        func noMessageMentionsKeyOrAnthropic(error: BackendError) {
            let message = BackendAssistantResponder.friendlyMessage(for: error).lowercased()
            #expect(!message.contains("key"))
            #expect(!message.contains("anthropic"))
        }

        @Test("the quota message tells the student they'll be answered from their phone")
        func quotaMessageMentionsThePhone() {
            let message = BackendAssistantResponder.friendlyMessage(for: .quotaExceeded(resetAt: nil))
            #expect(message.contains("phone"))
        }

        @Test("an HTTP failure names only the status code, never the endpoint")
        func httpFailureNamesOnlyStatusCode() {
            let message = BackendAssistantResponder.friendlyMessage(for: .http(503))
            #expect(message.contains("503"))
            #expect(!message.contains("supabase"))
            #expect(!message.contains("functions/v1"))
        }
    }
}
