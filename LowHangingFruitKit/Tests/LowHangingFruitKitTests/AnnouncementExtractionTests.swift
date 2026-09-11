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
/// The user-supplied-key path this comment used to describe
/// (`AnthropicKeyStore`, UI target) is gone: the AI backend is LHF's own
/// server now, reached through `BackendAnnouncementExtractor` (UI target),
/// which gets no test in this file for the same reason a real
/// `ClaudeAnnouncementExtractor` never does — it's a network call, and this
/// suite's whole point is exercising the pure, no-network seams.
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

    private static func time(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        components.timeZone = timeZone
        return fixedCalendar().date(from: components)!
    }

    // MARK: - Second fixed "now", for the class-meeting fixture corpus below:
    // Wed 2026-09-02T10:00:00 America/New_York. Kept separate from
    // `fixedNow()` above (Tue 2026-09-01T15:00:00) rather than replacing it,
    // so every pre-existing test's date math is untouched by this rewrite —
    // only the new class-meeting-aware tests need a "now" that lines up with
    // the LEC/LAB fixture below.

    private static func classFixtureNow() -> Date {
        time(year: 2026, month: 9, day: 2, hour: 10, minute: 0)
    }

    /// LEC Tue/Thu 10:15–11:44 (weekday 3 and 5 in `Calendar`'s Sunday=1
    /// numbering, minutes-after-midnight 615–704), LAB Mon 15:30–17:29
    /// (weekday 2, minutes 930–1049).
    private static func classFixtureMeetings() -> [ClassMeeting] {
        [
            ClassMeeting(sectionID: "001", activity: "LEC", weekday: 3, startMinutes: 615, endMinutes: 704),
            ClassMeeting(sectionID: "001", activity: "LEC", weekday: 5, startMinutes: 615, endMinutes: 704),
            ClassMeeting(sectionID: "201", activity: "LAB", weekday: 2, startMinutes: 930, endMinutes: 1049),
        ]
    }

    // `timeZone:` is gone from `HeuristicAnnouncementExtractor.init` — the
    // calendar this suite passes in already carries the right `timeZone`
    // (`fixedCalendar()` sets it), so the old second argument was always
    // redundant with what `calendar` itself specified. `meetings` is new,
    // defaulted to `[]` so every pre-existing call to `extractor()` is
    // unchanged.
    private func extractor(meetings: [ClassMeeting] = []) -> HeuristicAnnouncementExtractor {
        HeuristicAnnouncementExtractor(calendar: Self.fixedCalendar(), meetings: meetings)
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

    // MARK: - The bug this rewrite fixes: "the slides discussed today have
    // been posted" must never become a graded item due 11:59 PM.

    @Test("\"Thursday Slides (9/3) Posted\" / slides discussed today have been posted — informational, no extraction")
    func slidesPostedAnnouncementYieldsNothing() async throws {
        let body = "The slides discussed today have been posted."
        let results = try await extractor(meetings: Self.classFixtureMeetings())
            .extract(from: announcement(body: body, title: "Thursday Slides (9/3) Posted"), now: Self.classFixtureNow())
        #expect(results.isEmpty)
    }

    @Test("\"Recording is up\" — informational, no extraction")
    func recordingUpYieldsNothing() async throws {
        let body = "Today's recording is available on Canvas."
        let results = try await extractor().extract(from: announcement(body: body, title: "Recording is up"), now: Self.classFixtureNow())
        #expect(results.isEmpty)
    }

    @Test("\"Office hours moved\" — informational, no extraction")
    func officeHoursMovedYieldsNothing() async throws {
        let body = "Office hours are moved to 3pm on Thursday this week."
        let results = try await extractor().extract(from: announcement(body: body, title: "Office hours moved"), now: Self.classFixtureNow())
        #expect(results.isEmpty)
    }

    @Test("\"HW2\" / Homework 2 is due Friday at 11:59pm — a bare \"is due\" with no verb still extracts as a submission")
    func bareIsDueExtractsAsSubmission() async throws {
        let body = "Homework 2 is due Friday at 11:59pm on Gradescope."
        let results = try await extractor().extract(from: announcement(body: body, title: "HW2"), now: Self.classFixtureNow())
        #expect(results.count == 1)
        #expect(results.first?.kind == .submission)
        #expect(results.first?.dueAt == Self.time(year: 2026, month: 9, day: 4, hour: 23, minute: 59))
    }

    @Test("\"Reading\" / please read chapter 3 before class on Thursday — resolves to the LEC start time")
    func readBeforeClassResolvesToLectureStart() async throws {
        let body = "Please read chapter 3 before class on Thursday."
        let results = try await extractor(meetings: Self.classFixtureMeetings())
            .extract(from: announcement(body: body, title: "Reading"), now: Self.classFixtureNow())
        #expect(results.count == 1)
        #expect(results.first?.kind == .preparation)
        #expect(results.first?.dueAt == Self.time(year: 2026, month: 9, day: 3, hour: 10, minute: 15))
    }

    @Test("\"Exam\" / bring a calculator to Tuesday's exam — \"exam\" counts as a class-session noun, resolves to LEC start")
    func bringCalculatorToExamResolvesToLectureStart() async throws {
        let body = "Bring a calculator to Tuesday's exam."
        let results = try await extractor(meetings: Self.classFixtureMeetings())
            .extract(from: announcement(body: body, title: "Exam"), now: Self.classFixtureNow())
        #expect(results.count == 1)
        #expect(results.first?.kind == .preparation)
        #expect(results.first?.dueAt == Self.time(year: 2026, month: 9, day: 8, hour: 10, minute: 15))
    }

    @Test("\"Slides\" / \"I posted the slides for today\" — first person, and \"post\" isn't a recognized verb either way")
    func firstPersonPostedYieldsNothing() async throws {
        let body = "I posted the slides for today."
        let results = try await extractor().extract(from: announcement(body: body, title: "Slides"), now: Self.classFixtureNow())
        #expect(results.isEmpty)
    }

    @Test("\"Quiz\" / complete the syllabus quiz on Canvas by tonight — \"complete\" counts because \"quiz\" is nearby")
    func completeQuizByTonightExtractsAsSubmission() async throws {
        let body = "Complete the syllabus quiz on Canvas by tonight."
        let results = try await extractor().extract(from: announcement(body: body, title: "Quiz"), now: Self.classFixtureNow())
        #expect(results.count == 1)
        #expect(results.first?.kind == .submission)
        #expect(results.first?.dueAt == Self.time(year: 2026, month: 9, day: 2, hour: 23, minute: 59))
    }

    // Deviation, documented per the brief: "Read pp. 40-55 for Monday" names
    // a weekday but no class-session noun ("class", "lecture", "exam",
    // "midterm", …), and Monday's only meeting in the fixture is the LAB, not
    // a LEC. The brief explicitly allows either the LAB start (15:30) or
    // end-of-day here and asks for the choice to be documented: this
    // implementation resolves a bare weekday with no class-session noun to
    // end-of-day always (see `HeuristicAnnouncementExtractor
    // .classEventNouns`'s doc comment) — a bare "for Monday" is deliberately
    // treated as less certain than "before class on Thursday" or "Tuesday's
    // exam," which name the event explicitly.
    @Test("\"Reading 2\" / read pp. 40-55 for Monday — no class-session noun, resolves to end of day, not the LAB start")
    func readForMondayWithNoClassNounResolvesToEndOfDay() async throws {
        let body = "Read pp. 40-55 for Monday."
        let results = try await extractor(meetings: Self.classFixtureMeetings())
            .extract(from: announcement(body: body, title: "Reading 2"), now: Self.classFixtureNow())
        #expect(results.count == 1)
        #expect(results.first?.kind == .preparation)
        #expect(results.first?.dueAt == Self.time(year: 2026, month: 9, day: 7, hour: 23, minute: 59))
    }

    @Test("\"Discussion\" / we will cover chapter 4 on Thursday — first person, \"cover\" isn't a recognized verb either way")
    func firstPersonCoverYieldsNothing() async throws {
        let body = "We will cover chapter 4 on Thursday."
        let results = try await extractor().extract(from: announcement(body: body, title: "Discussion"), now: Self.classFixtureNow())
        #expect(results.isEmpty)
    }

    @Test("\"Survey\" / please fill out the course survey by Friday — extracts as a submission")
    func fillOutSurveyExtractsAsSubmission() async throws {
        let body = "Please fill out the course survey by Friday."
        let results = try await extractor().extract(from: announcement(body: body, title: "Survey"), now: Self.classFixtureNow())
        #expect(results.count == 1)
        #expect(results.first?.kind == .submission)
        #expect(results.first?.dueAt == Self.time(year: 2026, month: 9, day: 4, hour: 23, minute: 59))
    }

    @Test("\"Study\" / make sure to review before the midterm on Thursday — \"midterm\" counts as a class-session noun")
    func reviewBeforeMidtermResolvesToLectureStart() async throws {
        let body = "Make sure to review the practice problems before the midterm on Thursday."
        let results = try await extractor(meetings: Self.classFixtureMeetings())
            .extract(from: announcement(body: body, title: "Study"), now: Self.classFixtureNow())
        #expect(results.count == 1)
        #expect(results.first?.kind == .preparation)
        #expect(results.first?.dueAt == Self.time(year: 2026, month: 9, day: 3, hour: 10, minute: 15))
    }

    // Deviation, documented per the brief: the brief offers a choice for this
    // fixture ("the second clause: .preparation (review) Friday end of day —
    // or [] if you split on ';' and the first clause is informational").
    // `splitSentences` was deliberately NOT changed to split on `;` (see its
    // updated doc comment) — a semicolon-joined clause pair is kept as one
    // sentence so an informational half can't be quietly separated from an
    // actionable half by a splitter this file's own bug fix doesn't
    // otherwise need. Because of that, `isLikelyInformational` sees the
    // whole run-on "Grades have been released; please review them by
    // Friday" as its one "first sentence," which matches the
    // grades-released informational pattern, so the entire announcement —
    // including the actionable second half — is skipped. This is the "or
    // []" branch the brief names.
    @Test("passive-with-cue run-on: grades released; please review by Friday — whole announcement is skipped as informational")
    func passiveWithCueRunOnIsSkippedAsInformational() async throws {
        let body = "Grades have been released; please review them by Friday."
        let results = try await extractor().extract(from: announcement(body: body, title: "Notice"), now: Self.classFixtureNow())
        #expect(results.isEmpty)
    }

    // MARK: - isLikelyInformational

    @Test("isLikelyInformational is true for a posting-verb title")
    func isLikelyInformationalTrueForPostingTitle() {
        #expect(HeuristicAnnouncementExtractor.isLikelyInformational(title: "Recording is up", body: "See Canvas."))
    }

    @Test("isLikelyInformational is true for \"no class\"")
    func isLikelyInformationalTrueForNoClass() {
        #expect(HeuristicAnnouncementExtractor.isLikelyInformational(title: "Notice", body: "No class today."))
    }

    @Test("isLikelyInformational is true for \"office hours cancelled\"")
    func isLikelyInformationalTrueForOfficeHoursCancelled() {
        #expect(HeuristicAnnouncementExtractor.isLikelyInformational(title: "Notice", body: "Office hours are cancelled this week."))
    }

    @Test("isLikelyInformational is true for \"class is cancelled\"")
    func isLikelyInformationalTrueForClassCancelled() {
        #expect(HeuristicAnnouncementExtractor.isLikelyInformational(title: "Notice", body: "Class is cancelled tomorrow."))
    }

    @Test("isLikelyInformational is false for an actionable directive")
    func isLikelyInformationalFalseForDirective() {
        #expect(!HeuristicAnnouncementExtractor.isLikelyInformational(title: "Notice", body: "Please submit your essay by Friday."))
    }

    @Test("isLikelyInformational is false for unrelated text mentioning \"room\"")
    func isLikelyInformationalFalseForUnrelatedRoomMention() {
        #expect(!HeuristicAnnouncementExtractor.isLikelyInformational(title: "Notice", body: "Room 106 is a great room to study in."))
    }

    // MARK: - isStudentDirected

    @Test("isStudentDirected is true for a bare imperative")
    func isStudentDirectedTrueForImperative() {
        #expect(HeuristicAnnouncementExtractor.isStudentDirected("Read chapter 3 before Friday"))
    }

    @Test("isStudentDirected is true for \"please <verb>\"")
    func isStudentDirectedTrueForPlease() {
        #expect(HeuristicAnnouncementExtractor.isStudentDirected("Please submit the essay by Friday"))
    }

    @Test("isStudentDirected is true for \"you should <verb>\"")
    func isStudentDirectedTrueForYouShould() {
        #expect(HeuristicAnnouncementExtractor.isStudentDirected("You should submit the form by Friday"))
    }

    @Test("isStudentDirected is false for passive voice")
    func isStudentDirectedFalseForPassive() {
        #expect(!HeuristicAnnouncementExtractor.isStudentDirected("The slides have been posted for today"))
    }

    @Test("isStudentDirected is false for first person, present tense")
    func isStudentDirectedFalseForFirstPerson() {
        #expect(!HeuristicAnnouncementExtractor.isStudentDirected("I posted the slides for today"))
    }

    @Test("isStudentDirected is false for first person even with a real submission verb")
    func isStudentDirectedFalseForFirstPersonWithRealVerb() {
        // "upload" is deliberately picked here, not e.g. "submit": it's both
        // an unconditional `isSubmissionVerb` and one of the verbs
        // `isFirstPerson` watches for, so this exercises the actual
        // first-person rejection path rather than just happening to return
        // false because no other rule matched.
        #expect(!HeuristicAnnouncementExtractor.isStudentDirected("We will upload the grades by Friday"))
    }

    // MARK: - taskKind

    @Test("taskKind is .submission for an unconditional submission verb")
    func taskKindSubmissionVerb() {
        #expect(HeuristicAnnouncementExtractor.taskKind(of: "Submit the essay by Friday") == .submission)
    }

    @Test("taskKind is .preparation for an unconditional preparation verb")
    func taskKindPreparationVerb() {
        #expect(HeuristicAnnouncementExtractor.taskKind(of: "Read chapter 3 before Friday") == .preparation)
    }

    @Test("taskKind is .submission for a bare \"is due\" with no verb")
    func taskKindBareIsDue() {
        #expect(HeuristicAnnouncementExtractor.taskKind(of: "Homework 2 is due Friday") == .submission)
    }

    @Test("taskKind is nil when neither a recognized verb nor \"due\" is present")
    func taskKindNilWithNoVerbOrDue() {
        #expect(HeuristicAnnouncementExtractor.taskKind(of: "The lecture was interesting today") == nil)
    }
}
