import Foundation
import Testing
@testable import LowHangingFruitKit

/// Covers `AssistantContextDocument.build(...)`, the pure text-document
/// builder that feeds Claude's system prompt for the in-app assistant.
///
/// The overriding property under test throughout is byte-stability: the
/// document is a prompt-cache prefix, so "renders the right facts" and
/// "renders them the same way every single time, regardless of input array
/// order or ambient locale/timezone" are equally load-bearing. Several tests
/// below exist purely to prove the second half, which is easy to get right
/// by accident on a single run and easy to break silently later (a `Set`
/// swapped in for an `Array`, a formatter left unpinned) without ever
/// failing a "does it read correctly" style test.
@Suite("Assistant context document")
struct AssistantContextDocumentTests {

    // MARK: - Fixtures

    /// Builds a `Date` from explicit UTC components, independent of
    /// whatever timezone the test runner's host happens to be in. Using
    /// `Date()` or a local-timezone `Calendar` here would make the fixtures
    /// themselves non-deterministic across machines, which is exactly the
    /// failure mode this whole suite exists to catch in the code under
    /// test — so the fixtures can't have it either.
    private static func utcDate(
        year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    /// Three courses, four work items (dated, tied-date, and undated), and
    /// three announcements (dated and undated) — enough variety that a
    /// broken sort comparator or a broken empty-section check has somewhere
    /// to show up, and enough items that reversing the arrays actually
    /// changes their incoming order.
    private static func sampleFacts() -> (
        courses: [AssistantContextDocument.CourseFacts],
        work: [AssistantContextDocument.WorkFacts],
        announcements: [AssistantContextDocument.AnnouncementFacts]
    ) {
        let courses = [
            AssistantContextDocument.CourseFacts(
                code: "PSYC 1010",
                displayName: nil,
                gradeCategories: []
            ),
            AssistantContextDocument.CourseFacts(
                code: "PHYS 0151",
                displayName: "Physics I",
                gradeCategories: [
                    AssistantContextDocument.GradeCategoryFacts(name: "Problem sets", weightPercent: 20, dropsLowest: true),
                    AssistantContextDocument.GradeCategoryFacts(name: "Final", weightPercent: 25, dropsLowest: false),
                    AssistantContextDocument.GradeCategoryFacts(name: "Labs", weightPercent: nil, dropsLowest: false),
                ]
            ),
            AssistantContextDocument.CourseFacts(
                code: "CIS 1210",
                displayName: nil,
                gradeCategories: []
            ),
        ]

        let work = [
            AssistantContextDocument.WorkFacts(
                course: "PHYS 0151", title: "Problem set 3",
                due: utcDate(year: 2026, month: 9, day: 4, hour: 23, minute: 59),
                isCompleted: false, nothingToSubmit: false, source: "canvas"
            ),
            AssistantContextDocument.WorkFacts(
                course: "CIS 1210", title: "HW1",
                due: utcDate(year: 2026, month: 9, day: 4, hour: 23, minute: 59),
                isCompleted: false, nothingToSubmit: false, source: "gradescope"
            ),
            AssistantContextDocument.WorkFacts(
                course: "PHYS 0151", title: "Lab 2",
                due: nil, isCompleted: true, nothingToSubmit: false, source: "canvas"
            ),
            AssistantContextDocument.WorkFacts(
                course: "", title: "Guest lecture",
                due: nil, isCompleted: false, nothingToSubmit: true, source: "canvas"
            ),
        ]

        let announcements = [
            AssistantContextDocument.AnnouncementFacts(
                course: "PHYS 0151", title: "Midterm room change",
                body: "Moved to Meyerson B1.",
                postedAt: utcDate(year: 2026, month: 8, day: 26)
            ),
            AssistantContextDocument.AnnouncementFacts(
                course: "CIS 1210", title: "Office hours added",
                body: "New Friday office hour, 2-3pm.",
                postedAt: utcDate(year: 2026, month: 8, day: 20)
            ),
            AssistantContextDocument.AnnouncementFacts(
                course: "CIS 1210", title: "Welcome",
                body: "Welcome to the course.",
                postedAt: nil
            ),
        ]

        return (courses, work, announcements)
    }

    /// Pulls the non-empty lines directly under a `"# HEADER"` line, up to
    /// the next `"# "` header or the end of the document — used to make
    /// assertions about relative order within a section without hardcoding
    /// the whole document's layout into every test.
    private static func section(_ header: String, in document: String) -> [String] {
        let lines = document.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: header) else { return [] }
        var result: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("# ") { break }
            if line.isEmpty { continue }
            result.append(line)
        }
        return result
    }

    // MARK: - Byte-stability

    @Test("Building twice from identical inputs returns byte-identical strings")
    func byteStability() {
        let (courses, work, announcements) = Self.sampleFacts()
        let first = AssistantContextDocument.build(courses: courses, work: work, announcements: announcements)
        let second = AssistantContextDocument.build(courses: courses, work: work, announcements: announcements)
        #expect(first == second)
    }

    // MARK: - Order-independence

    @Test("Reversing the input arrays produces an identical document")
    func orderIndependenceReversed() {
        let (courses, work, announcements) = Self.sampleFacts()
        let baseline = AssistantContextDocument.build(courses: courses, work: work, announcements: announcements)
        let reversed = AssistantContextDocument.build(
            courses: courses.reversed(),
            work: work.reversed(),
            announcements: announcements.reversed()
        )
        #expect(baseline == reversed)
    }

    @Test("Randomly shuffling the input arrays produces an identical document")
    func orderIndependenceShuffled() {
        let (courses, work, announcements) = Self.sampleFacts()
        let baseline = AssistantContextDocument.build(courses: courses, work: work, announcements: announcements)
        let shuffled = AssistantContextDocument.build(
            courses: courses.shuffled(),
            work: work.shuffled(),
            announcements: announcements.shuffled()
        )
        #expect(baseline == shuffled)
    }

    // MARK: - Undated work

    @Test("Undated work sorts after dated work and renders \"no due date\"")
    func undatedWorkSortsLast() {
        let dated = AssistantContextDocument.WorkFacts(
            course: "CIS 1210", title: "HW1",
            due: Self.utcDate(year: 2026, month: 9, day: 10),
            isCompleted: false, nothingToSubmit: false, source: "canvas"
        )
        let undated = AssistantContextDocument.WorkFacts(
            course: "CIS 1210", title: "Reading response",
            due: nil, isCompleted: false, nothingToSubmit: false, source: "reading"
        )
        let doc = AssistantContextDocument.build(courses: [], work: [undated, dated], announcements: [])
        let workLines = Self.section("# WORK", in: doc)

        #expect(workLines.count == 2)
        #expect(workLines.first?.contains("HW1") == true)
        #expect(workLines.last?.contains("Reading response") == true)
        #expect(workLines.last?.contains("no due date") == true)
    }

    // MARK: - Announcement truncation

    @Test("Announcement bodies over the limit are truncated and marked")
    func announcementBodyOverLimitIsTruncated() {
        let longBody = String(repeating: "a", count: AssistantContextDocument.announcementBodyLimit + 500)
        let announcements = [
            AssistantContextDocument.AnnouncementFacts(
                course: "PHYS 0151", title: "Long one", body: longBody,
                postedAt: Self.utcDate(year: 2026, month: 8, day: 26)
            ),
        ]
        let doc = AssistantContextDocument.build(courses: [], work: [], announcements: announcements)

        #expect(!doc.contains(longBody))
        #expect(doc.contains("…[truncated]"))
        let expectedPrefix = String(longBody.prefix(AssistantContextDocument.announcementBodyLimit))
        #expect(doc.contains("\(expectedPrefix)…[truncated]"))
    }

    @Test("Announcement bodies under the limit are left untouched")
    func announcementBodyUnderLimitIsUntouched() {
        let shortBody = "Moved to Meyerson B1."
        let announcements = [
            AssistantContextDocument.AnnouncementFacts(
                course: "PHYS 0151", title: "Room change", body: shortBody,
                postedAt: Self.utcDate(year: 2026, month: 8, day: 26)
            ),
        ]
        let doc = AssistantContextDocument.build(courses: [], work: [], announcements: announcements)

        #expect(doc.contains(shortBody))
        #expect(!doc.contains("…[truncated]"))
    }

    // MARK: - Empty sections

    @Test("All three sections are omitted when there are no facts of any kind")
    func allSectionsOmittedWhenEmpty() {
        let doc = AssistantContextDocument.build(courses: [], work: [], announcements: [])
        #expect(!doc.contains("# CLASSES"))
        #expect(!doc.contains("# WORK"))
        #expect(!doc.contains("# ANNOUNCEMENTS"))
        // The header itself always renders.
        #expect(doc.contains("# ASSISTANT CONTEXT"))
    }

    @Test("Only the sections with facts appear when some kinds are absent")
    func onlyPopulatedSectionsAppear() {
        let work = [
            AssistantContextDocument.WorkFacts(
                course: "CIS 1210", title: "HW1", due: nil,
                isCompleted: false, nothingToSubmit: false, source: "manual"
            ),
        ]
        let doc = AssistantContextDocument.build(courses: [], work: work, announcements: [])
        #expect(doc.contains("# WORK"))
        #expect(!doc.contains("# CLASSES"))
        #expect(!doc.contains("# ANNOUNCEMENTS"))
    }

    // MARK: - Syllabus-prose limitation

    @Test("The header states that syllabus prose is not included")
    func headerStatesSyllabusProseLimitation() {
        let doc = AssistantContextDocument.build(courses: [], work: [], announcements: [])
        #expect(doc.contains("Does NOT contain syllabus prose"))
        #expect(doc.contains("attendance"))
        #expect(doc.contains("office hours"))
    }

    // MARK: - UTC / locale independence

    @Test("Dates render as UTC ISO-8601, not in the device's timezone")
    func datesRenderInUTC() {
        // 23:59 UTC is deliberately late in the day: a formatter that leaked
        // the device's timezone would roll this onto the 3rd or the 5th
        // almost everywhere outside Europe, so the exact-string assertion
        // below fails loudly rather than passing by luck on a UTC machine.
        let due = Self.utcDate(year: 2026, month: 9, day: 4, hour: 23, minute: 59)
        let work = [
            AssistantContextDocument.WorkFacts(
                course: "PHYS 0151", title: "Problem set 3", due: due,
                isCompleted: false, nothingToSubmit: false, source: "canvas"
            ),
        ]

        let doc = AssistantContextDocument.build(courses: [], work: work, announcements: [])

        #expect(doc.contains("due 2026-09-04T23:59:00Z"))
    }

    @Test("Announcement dates render as plain UTC yyyy-MM-dd regardless of locale")
    func announcementDateRendersAsUTCDateOnly() {
        let announcements = [
            AssistantContextDocument.AnnouncementFacts(
                course: "PHYS 0151", title: "Midterm room change",
                body: "Moved to Meyerson B1.",
                postedAt: Self.utcDate(year: 2026, month: 8, day: 26, hour: 23, minute: 30)
            ),
        ]
        let doc = AssistantContextDocument.build(courses: [], work: [], announcements: announcements)
        #expect(doc.contains("(2026-08-26)"))
    }

    // MARK: - Grading rendering

    @Test("Grade categories render sorted, with weight percent, and drops-lowest called out")
    func gradeCategoriesRenderSortedWithWeights() {
        let course = AssistantContextDocument.CourseFacts(
            code: "PHYS 0151",
            displayName: "Physics I",
            gradeCategories: [
                AssistantContextDocument.GradeCategoryFacts(name: "Final", weightPercent: 25, dropsLowest: false),
                AssistantContextDocument.GradeCategoryFacts(name: "Problem sets", weightPercent: 20, dropsLowest: true),
                AssistantContextDocument.GradeCategoryFacts(name: "Labs", weightPercent: nil, dropsLowest: false),
            ]
        )
        let doc = AssistantContextDocument.build(courses: [course], work: [], announcements: [])

        #expect(doc.contains("## PHYS 0151 (shown as: Physics I)"))
        // Alphabetically sorted regardless of input order: Final, Labs, Problem sets.
        #expect(doc.contains("grading: Final 25%; Labs (weight not specified); Problem sets 20%"))
        #expect(doc.contains("drops lowest: Problem sets"))
    }

    @Test("A course with no extracted grade categories says so explicitly")
    func courseWithNoGradeCategoriesIsExplicit() {
        let course = AssistantContextDocument.CourseFacts(code: "PSYC 1010", displayName: nil, gradeCategories: [])
        let doc = AssistantContextDocument.build(courses: [course], work: [], announcements: [])
        #expect(doc.contains("## PSYC 1010"))
        #expect(doc.contains("grading: not extracted from a syllabus"))
    }

    // MARK: - Work item shape

    @Test("Work with an unknown course renders an explicit placeholder rather than an empty field")
    func workWithUnknownCourseRendersPlaceholder() {
        let work = [
            AssistantContextDocument.WorkFacts(
                course: "", title: "Guest lecture", due: nil,
                isCompleted: false, nothingToSubmit: true, source: "canvas"
            ),
        ]
        let doc = AssistantContextDocument.build(courses: [], work: work, announcements: [])
        #expect(doc.contains("(no course) | Guest lecture | no due date | nothing to submit | canvas"))
    }

    @Test("Completed work renders \"done\"; outstanding work renders \"outstanding\"")
    func workStatusRendersDoneOrOutstanding() {
        let work = [
            AssistantContextDocument.WorkFacts(
                course: "PHYS 0151", title: "Lab 2", due: nil,
                isCompleted: true, nothingToSubmit: false, source: "canvas"
            ),
            AssistantContextDocument.WorkFacts(
                course: "PHYS 0151", title: "Lab 3",
                due: Self.utcDate(year: 2026, month: 9, day: 20),
                isCompleted: false, nothingToSubmit: false, source: "canvas"
            ),
        ]
        let doc = AssistantContextDocument.build(courses: [], work: work, announcements: [])
        #expect(doc.contains("Lab 2 | no due date | done | canvas"))
        #expect(doc.contains("Lab 3 | due 2026-09-20T00:00:00Z | outstanding | canvas"))
    }
}
