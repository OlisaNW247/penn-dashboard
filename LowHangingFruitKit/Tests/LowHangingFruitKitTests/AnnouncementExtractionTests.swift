import Foundation
import Testing
@testable import LowHangingFruitKit

/// Covers both extraction backends.
///
/// `HeuristicAnnouncementExtractor` is exercised end-to-end through its
/// public `extract(from:now:)` — no network, no mocking needed, since it's
/// deterministic pattern matching over plain strings.
///
/// `ClaudeAnnouncementExtractor` is exercised only through its pure
/// `decodeExtraction(responseBody:now:)` seam — no test here ever constructs
/// a real extractor or makes a network call, matching the brief's
/// no-network constraint.
///
/// `AnthropicKeyStore` (UI target) gets no test in this file: it's a
/// line-for-line mirror of `ICSFeedURLStore`, whose Keychain save/load/clear
/// behavior is already covered elsewhere, and Keychain access inside a
/// sandboxed test runner is exactly the kind of environment-dependent
/// behavior this suite avoids (see `SharedDefaults.isTestRunner`'s doc
/// comment on the same theme, one layer down).
@Suite("Announcement extraction")
struct AnnouncementExtractionTests {

    // MARK: - Fixed "now": Tue 2026-09-01T15:00:00 America/New_York

    private static let timeZone = TimeZone(identifier: "America/New_York")!

    private static func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func fixedNow() -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 1
        components.hour = 15
        components.minute = 0
        components.second = 0
        components.timeZone = timeZone
        return fixedCalendar().date(from: components)!
    }

    private static func endOfDay(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 23
        components.minute = 59
        components.second = 0
        components.timeZone = timeZone
        return fixedCalendar().date(from: components)!
    }

    private func extractor() -> HeuristicAnnouncementExtractor {
        HeuristicAnnouncementExtractor(calendar: Self.fixedCalendar(), timeZone: Self.timeZone)
    }

    private func announcement(body: String, title: String = "Announcement") -> AnnouncementSourceText {
        AnnouncementSourceText(
            announcementID: "1",
            courseCode: "ACCT 1010",
            title: title,
            body: body,
            postedAt: Self.fixedNow()
        )
    }

    // MARK: - Heuristic: weekday cue

    @Test("Weekday cue resolves to the next occurrence of that weekday")
    func weekdayCueResolvesToNextOccurrence() async throws {
        let body = "Please read chapter 3 before Friday's class"
        let results = try await extractor().extract(from: announcement(body: body), now: Self.fixedNow())

        #expect(results.count == 1)
        #expect(results.first?.dueAt == Self.endOfDay(year: 2026, month: 9, day: 4))
    }

    // MARK: - Heuristic: "tomorrow" cue

    @Test("\"Tomorrow\" resolves relative to now")
    func tomorrowCueResolvesRelativeToNow() async throws {
        let body = "Remember to submit Problem Set 1 by tomorrow"
        let results = try await extractor().extract(from: announcement(body: body), now: Self.fixedNow())

        #expect(results.count == 1)
        #expect(results.first?.dueAt == Self.endOfDay(year: 2026, month: 9, day: 2))
    }

    // MARK: - Heuristic: "today" cue, verb matched by stem

    @Test("\"Reading due today\" matches the read-stem verb and today cue")
    func readingDueTodayResolvesToSameDay() async throws {
        let body = "Reading due today"
        let results = try await extractor().extract(from: announcement(body: body), now: Self.fixedNow())

        #expect(results.count == 1)
        #expect(results.first?.dueAt == Self.endOfDay(year: 2026, month: 9, day: 1))
    }

    // MARK: - Heuristic: purely informational, no verb and no actionable content

    @Test("Purely informational announcements yield nothing")
    func informationalAnnouncementYieldsNothing() async throws {
        let body = "Office hours moved to 3pm"
        let results = try await extractor().extract(from: announcement(body: body), now: Self.fixedNow())

        #expect(results.isEmpty)
    }

    // MARK: - Heuristic: explicit date, month-name form

    @Test("Explicit \"due September 12\" resolves to that calendar date")
    func explicitDateResolvesToStatedDate() async throws {
        let body = "Please submit the essay due September 12"
        let results = try await extractor().extract(from: announcement(body: body), now: Self.fixedNow())

        #expect(results.count == 1)
        #expect(results.first?.dueAt == Self.endOfDay(year: 2026, month: 9, day: 12))
    }

    // MARK: - Heuristic: cap at 3 extractions

    @Test("An announcement with 5 actionable sentences yields at most 3")
    func capsExtractionsAtThree() async throws {
        let body = """
        Read chapter 1 by Monday. Submit homework 1 by Tuesday. Review your notes by Wednesday. Prepare slides by Thursday. Watch the lecture by Friday.
        """
        let results = try await extractor().extract(from: announcement(body: body), now: Self.fixedNow())

        #expect(results.count == 3)
    }

    // MARK: - Heuristic: undated result when no resolvable cue is present

    @Test("A bare \"due\" with no resolvable date leaves dueAt nil")
    func bareDueCueWithNoDateLeavesDueAtNil() async throws {
        let body = "Please submit your worksheet, it is due before class"
        let results = try await extractor().extract(from: announcement(body: body), now: Self.fixedNow())

        #expect(results.count == 1)
        #expect(results.first?.dueAt == nil)
    }

    // MARK: - Claude decode seam: success with two assignments, one undated

    @Test("decodeExtraction parses a tool_use block into ExtractedAssignments")
    func decodeExtractionParsesToolUseBlock() throws {
        let json = """
        {
          "id": "msg_01",
          "type": "message",
          "role": "assistant",
          "content": [
            {"type": "text", "text": "Here you go."},
            {
              "type": "tool_use",
              "id": "toolu_01",
              "name": "record_assignments",
              "input": {
                "assignments": [
                  {"title": "Read chapter 4", "due_iso8601": "2026-09-05T23:59:00-04:00"},
                  {"title": "Bring your laptop", "due_iso8601": null}
                ]
              }
            }
          ]
        }
        """
        let results = try ClaudeAnnouncementExtractor.decodeExtraction(
            responseBody: Data(json.utf8),
            now: Self.fixedNow()
        )

        #expect(results.count == 2)
        #expect(results[0].title == "Read chapter 4")
        #expect(results[0].dueAt != nil)
        #expect(results[1].title == "Bring your laptop")
        #expect(results[1].dueAt == nil)
    }

    // MARK: - Claude decode seam: no tool_use block

    @Test("decodeExtraction throws .noToolUse when no tool_use block is present")
    func decodeExtractionThrowsWhenNoToolUse() {
        let json = """
        {
          "id": "msg_01",
          "type": "message",
          "role": "assistant",
          "content": [
            {"type": "text", "text": "Nothing actionable here."}
          ]
        }
        """
        let body = Data(json.utf8)
        #expect(throws: ClaudeAnnouncementExtractor.ExtractionError.self) {
            try ClaudeAnnouncementExtractor.decodeExtraction(responseBody: body, now: Self.fixedNow())
        }

        do {
            _ = try ClaudeAnnouncementExtractor.decodeExtraction(responseBody: body, now: Self.fixedNow())
            Issue.record("Expected decodeExtraction to throw when no tool_use block is present")
        } catch let error as ClaudeAnnouncementExtractor.ExtractionError {
            guard case .noToolUse = error else {
                Issue.record("Expected .noToolUse, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ClaudeAnnouncementExtractor.ExtractionError, got \(error)")
        }
    }

    // MARK: - Claude decode seam: garbage input

    @Test("decodeExtraction throws .decodingFailed on garbage input")
    func decodeExtractionThrowsOnGarbageInput() {
        let garbage = Data("not json at all { [ }".utf8)

        #expect(throws: ClaudeAnnouncementExtractor.ExtractionError.self) {
            try ClaudeAnnouncementExtractor.decodeExtraction(responseBody: garbage, now: Self.fixedNow())
        }

        do {
            _ = try ClaudeAnnouncementExtractor.decodeExtraction(responseBody: garbage, now: Self.fixedNow())
            Issue.record("Expected decodeExtraction to throw on garbage input")
        } catch let error as ClaudeAnnouncementExtractor.ExtractionError {
            guard case .decodingFailed = error else {
                Issue.record("Expected .decodingFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ClaudeAnnouncementExtractor.ExtractionError, got \(error)")
        }
    }
}
