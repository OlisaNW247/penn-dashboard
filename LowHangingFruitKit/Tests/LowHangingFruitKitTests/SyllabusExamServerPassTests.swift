import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The syllabus exam pass when the server has already read the syllabus
/// (`CourseGradingProfile.examDates` in `courseKnowledge.gradingProfiles`):
/// its exams are filed, an exam the phone had already filed from its own
/// reading is updated where it is, and a class the server has nothing for
/// behaves as before. The rules themselves are in
/// `SyllabusExamServerRowsTests`; this is the part that touches the ledger
/// through `AppState`.
///
/// **Hermeticity.** Same as `SyllabusExamDashboardTests`: an in-memory
/// ledger, course material handed to the state directly, the pass driven by
/// the test with a fixed `now` (local Sunday, October 18, 2026, noon), every
/// shared preference put back, and every class code and course id unique to
/// this suite.
@MainActor
@Suite("Syllabus exam pass, server dates", .serialized)
struct SyllabusExamServerPassTests {
    private static let extractionVersionKey = "announcementExtractionVersionV1"
    private static let processedKey = "processedAnnouncementIDsV1"

    private static func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    private static let now = date(10, 18, 12)

    private func syllabus(_ course: String, id: String, text: String) -> CourseDocument {
        CourseDocument(
            courseID: id, course: course, kind: .syllabus, sourceID: "syllabus", title: "Syllabus",
            url: URL(string: "https://canvas.upenn.edu/courses/\(id)/assignments/syllabus"),
            text: text, updatedAt: nil, fetchedAt: Self.now
        )
    }

    private func profile(_ id: String, _ exams: [CourseGradingProfile.ExamDate]) -> CourseGradingProfile {
        CourseGradingProfile(courseID: id, weights: [], components: [], extractedAt: Self.now, examDates: exams)
    }

    private func exam(_ name: String, _ date: String?) -> CourseGradingProfile.ExamDate {
        CourseGradingProfile.ExamDate(name: name, date: date)
    }

    /// A state for one class (whose feed item is also what gives
    /// `canvasCourseIDs()` an id -> code entry), with the course material
    /// handed to it and every shared preference it touches put back.
    private func withState(
        course: String,
        courseID: String,
        knowledge: CourseKnowledgeBase = CourseKnowledgeBase(),
        _ body: @MainActor (AppState, AssignmentStore) async throws -> Void
    ) async throws {
        let shared = UserDefaults.lhf
        let keys = [Self.extractionVersionKey, Self.processedKey]
        let saved = keys.map { ($0, shared.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { shared.set(value, forKey: key) } else { shared.removeObject(forKey: key) }
            }
        }
        shared.set(2, forKey: Self.extractionVersionKey)
        shared.removeObject(forKey: Self.processedKey)

        let store = try AssignmentStore(inMemory: true)
        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        state.canvasItems = [Assignment(
            source: .canvas, sourceID: "event-assignment-99", kind: .assignment, course: course,
            title: "Seed", dueAt: nil,
            url: URL(string: "https://canvas.upenn.edu/courses/\(courseID)/assignments/99")
        )]
        state.setCourse(course, selected: true)
        defer {
            state.restoreCourse(course)
            state.setCourse(course, selected: true)
            state.coursePreferences.setCanvasCourseID(course, nil)
        }
        state.courseKnowledge = knowledge
        state.rebuildDashboardItemsForTesting(now: Self.now)
        try await body(state, store)
    }

    private func fileExams(_ state: AppState) async {
        await state.syncSyllabusExams(now: Self.now)
        state.rebuildDashboardItemsForTesting(now: Self.now)
    }

    private func syllabusRows(_ store: AssignmentStore) -> [Assignment] {
        store.assignments(source: .canvasAnnouncement).filter { $0.announcementOrigin == .syllabus }
    }

    private func cards(_ state: AppState, _ course: String) -> [Assignment] {
        (state.assignments + state.laterAssignments + state.assessments)
            .filter { $0.course == course && $0.title != "Seed" }
    }

    @Test("the server's exams are filed as cards even when the phone's reading of the material finds none")
    func serverExamsAreFiled() async throws {
        let course = "SRVPASS 9711"
        try await withState(
            course: course, courseID: "9711",
            knowledge: CourseKnowledgeBase(
                documents: [syllabus(course, id: "9711", text: "Grading: homework 40%, exams 60%.")],
                gradingProfiles: [profile("9711", [
                    exam("Midterm 1", "2026-10-23"),
                    exam("Final Exam", "2026-12-15"),
                    exam("Midterm 2", nil),
                ])]
            )
        ) { state, store in
            await fileExams(state)
            #expect(Set(syllabusRows(store).map(\.sourceID)) == ["syllabus-9711-midterm-1", "syllabus-9711-final"])
            #expect(Set(cards(state, course).map(\.title)) == ["Midterm 1", "Final Exam"])
            let midterm = try #require(cards(state, course).first { $0.title == "Midterm 1" })
            #expect(midterm.dueAt == Self.date(10, 23, 23, 59, 59))
            #expect(midterm.isFoundExam)
        }
    }

    @Test("a profile with no documents on the phone is enough for a pass")
    func profileAlone() async throws {
        let course = "SRVPASS 9712"
        try await withState(
            course: course, courseID: "9712",
            knowledge: CourseKnowledgeBase(gradingProfiles: [profile("9712", [exam("Final Exam", "2026-12-15")])])
        ) { state, store in
            await fileExams(state)
            #expect(syllabusRows(store).map(\.sourceID) == ["syllabus-9712-final"])
        }
    }

    @Test("an exam filed from the phone's reading is updated in place when the server's date arrives: one row, one card, the tick stays")
    func serverDateUpdatesTheRowInPlace() async throws {
        let course = "SRVPASS 9713"
        let document = syllabus(course, id: "9713", text: "Midterm 1: Oct 23\nFinal Exam: Dec 15")
        try await withState(
            course: course, courseID: "9713", knowledge: CourseKnowledgeBase(documents: [document])
        ) { state, store in
            await fileExams(state)
            let first = syllabusRows(store)
            #expect(Set(first.map(\.sourceID)) == ["syllabus-9713-midterm-1", "syllabus-9713-final"])
            let midterm = try #require(first.first { $0.sourceID.hasSuffix("midterm-1") })
            #expect(midterm.dueAt == Self.date(10, 23, 23, 59, 59))
            store.setCompleted(ids: [midterm.id], at: Self.now)

            // The sync lands the server's profile: the midterm moved, and it
            // knows a second one the syllabus text never gave a date for.
            state.courseKnowledge = CourseKnowledgeBase(
                documents: [document],
                gradingProfiles: [profile("9713", [exam("Midterm 1", "2026-10-30"), exam("Midterm 2", "2026-11-20")])]
            )
            await fileExams(state)

            let after = syllabusRows(store)
            #expect(Set(after.map(\.sourceID)) == [
                "syllabus-9713-midterm-1", "syllabus-9713-midterm-2", "syllabus-9713-final",
            ])
            #expect(after.count == 3, "no exam is filed twice")
            #expect(after.first { $0.id == midterm.id }?.dueAt == Self.date(10, 30, 23, 59, 59))
            #expect(after.first { $0.sourceID.hasSuffix("final") }?.dueAt == Self.date(12, 15, 23, 59, 59))
            #expect(store.completionRecord().ids.contains(midterm.id))
        }
    }

    @Test("through the ledger: a confirmed phone reading stands against the server, and the phone's time is kept on a day they agree on")
    func reconciliationInTheLedger() async throws {
        let course = "SRVPASS 9716"
        let document = syllabus(
            course, id: "9716",
            text: "Midterm 1: Thursday, October 22, 7 pm\nMidterm 2: Nov 19, 6 pm\nFinal Exam: Dec 15"
        )
        try await withState(
            course: course, courseID: "9716",
            knowledge: CourseKnowledgeBase(
                documents: [document],
                gradingProfiles: [profile("9716", [
                    exam("Midterm 1", "2026-10-30"),
                    exam("Midterm 2", "2026-11-19"),
                    exam("Final Exam", "2026-12-17"),
                ])]
            )
        ) { state, store in
            await fileExams(state)
            await fileExams(state)
            let rows = syllabusRows(store)
            #expect(rows.count == 3, "no exam is filed twice")
            func due(_ suffix: String) -> Date? { rows.first { $0.sourceID.hasSuffix(suffix) }?.dueAt }
            // Weekday fits the phone's date: the phone stands, 7 pm and all.
            #expect(due("midterm-1") == Self.date(10, 22, 19, 0))
            // Same day: the server's row with the phone's 6 pm.
            #expect(due("midterm-2") == Self.date(11, 19, 18, 0))
            // No weekday to back the phone: the server wins.
            #expect(due("final") == Self.date(12, 17, 23, 59, 59))
        }
    }

    @Test("a second pass over the same profile and material adds no row and no card")
    func secondPassAddsNothing() async throws {
        let course = "SRVPASS 9714"
        try await withState(
            course: course, courseID: "9714",
            knowledge: CourseKnowledgeBase(
                documents: [syllabus(course, id: "9714", text: "Midterm 1: Oct 23")],
                gradingProfiles: [profile("9714", [exam("Midterm 1", "2026-10-30"), exam("Final Exam", "2026-12-15")])]
            )
        ) { state, store in
            await fileExams(state)
            let before = syllabusRows(store).map(\.id).sorted()
            await fileExams(state)
            await fileExams(state)
            #expect(syllabusRows(store).map(\.id).sorted() == before)
            #expect(before.count == 2)
            #expect(cards(state, course).count == 2)
        }
    }

    @Test("a profile for a site the app cannot name a class for, or with only undated exams, files nothing")
    func guards() async throws {
        let course = "SRVPASS 9715"
        try await withState(
            course: course, courseID: "9715",
            knowledge: CourseKnowledgeBase(gradingProfiles: [profile("9799", [exam("Midterm 1", "2026-10-23")])])
        ) { state, store in
            await fileExams(state)
            #expect(syllabusRows(store).isEmpty)
        }
        try await withState(
            course: course, courseID: "9715",
            knowledge: CourseKnowledgeBase(gradingProfiles: [profile("9715", [exam("Midterm 1", nil)])])
        ) { state, store in
            await fileExams(state)
            #expect(syllabusRows(store).isEmpty)
        }
        try await withState(
            course: course, courseID: "9715",
            knowledge: CourseKnowledgeBase(gradingProfiles: [profile("9715", [exam("Midterm 1", "2026-10-23")])])
        ) { state, store in
            state.forceFixtureDataForTesting(true)
            await fileExams(state)
            #expect(syllabusRows(store).isEmpty)
        }
    }
}
