import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// What the announcement tasks must never do to the student's ledger, found in
/// review of the commit that made them cards (2026-10-18):
///
///  1. A task announced twice for two different days is two tasks, and a live
///     one is never hidden behind a lapsed twin. A tick on one date is not a
///     tick on another.
///  2. (Aging no longer deletes a flagged announcement row: `AnnouncementDeletionTests`.)
///  3. (A truncated fetch is not a deletion: `AnnouncementDeletionTests`.)
///  4. A due date the student edited survives the row being hidden.
///  5. (A class that goes away during a read: `EdAnnouncementTaskTests`,
///     `SyllabusExamDashboardTests`.)
///
/// Rows are seeded straight into an in-memory ledger and the dashboard is
/// rebuilt at a fixed `now` (October 8, 2026, noon, local time), so nothing
/// depends on the day the tests run. Class codes are unique to this suite, and
/// the extraction-repair version is pinned so `AppState.init` does not purge
/// the seeded rows.
@MainActor
@Suite("Announcement tasks and the ledger", .serialized)
struct AnnouncementLedgerSafetyTests {
    private static let extractionVersionKey = "announcementExtractionVersionV1"
    private static let processedKey = "processedAnnouncementIDsV1"

    private static func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private static let now = date(10, 8, 12)

    private func withPinnedDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.lhf
        let keys = [Self.extractionVersionKey, Self.processedKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(2, forKey: Self.extractionVersionKey)
        defaults.removeObject(forKey: Self.processedKey)
        try body()
    }

    private func canvasFind(_ id: String, course: String, title: String, due: Date?, kind: Assignment.Kind = .assignment) -> Assignment {
        Assignment(
            source: .canvasAnnouncement,
            sourceID: AnnouncementRecord.findSourceID(announcementID: id, index: 0),
            kind: kind, course: course, title: title, dueAt: due,
            url: URL(string: "https://canvas.upenn.edu/courses/1/discussion_topics/\(id)")
        )
    }

    private func edFind(_ thread: String, course: String, title: String, due: Date?) -> Assignment {
        Assignment(
            source: .canvasAnnouncement,
            sourceID: AnnouncementRecord.edFindSourceID(courseID: "9701", threadID: thread, index: 0),
            kind: .assignment, course: course, title: title, dueAt: due,
            url: URL(string: "https://edstem.org/us/courses/1/discussion/\(thread)")
        )
    }

    private func makeState(_ seed: [Assignment], dueDateEditsDefaults: UserDefaults? = nil) throws -> (AppState, AssignmentStore) {
        let store = try AssignmentStore(inMemory: true)
        store.upsert(seed)
        let state = AppState(assignmentStore: store, dueDateEditsDefaults: dueDateEditsDefaults)
        state.forceFixtureDataForTesting(false)
        state.rebuildDashboardItemsForTesting(now: Self.now)
        return (state, store)
    }

    private func live(_ state: AppState, _ course: String) -> [Assignment] {
        (state.assignments + state.laterAssignments + state.assessments).filter { $0.course == course }
    }

    private func past(_ state: AppState, _ course: String) -> [Assignment] {
        state.lapsedAnnouncementItems.filter { $0.course == course }
    }

    // MARK: 1. Two days are two tasks

    /// Post 111 says "submit your weekly reflection" for the 6th; post 222, two
    /// weeks on, says it again for the 20th. They used to collapse (the title
    /// heuristic tolerates 21 days), the earlier one survived because it sorted
    /// first, and on the 7th it lapsed into prev with nothing live left behind.
    @Test("a task announced for the 6th and again for the 20th is two tasks: the 6th goes to prev and the 20th stays live, whichever source is which")
    func sameTitleTwoWeeksApart() throws {
        try withPinnedDefaults {
            let course = "ANSAFE 9701"
            for (first, second) in [("canvas", "ed"), ("ed", "canvas")] {
                @MainActor func find(_ source: String, id: String, due: Date) -> Assignment {
                    source == "canvas"
                        ? canvasFind(id, course: course, title: "Submit weekly reflection", due: due)
                        : edFind(id, course: course, title: "Submit weekly reflection", due: due)
                }
                let sixth = find(first, id: "111", due: Self.date(10, 6, 23, 59))
                let twentieth = find(second, id: "222", due: Self.date(10, 20, 23, 59))
                let (state, _) = try makeState([sixth, twentieth])

                #expect(live(state, course).map(\.dueAt) == [Self.date(10, 20, 23, 59)], "\(first) then \(second)")
                #expect(past(state, course).map(\.dueAt) == [Self.date(10, 6, 23, 59)])
            }
        }
    }

    @Test("copies of one task within a day still collapse to one card")
    func sameDayStillCollapses() throws {
        try withPinnedDefaults {
            let course = "ANSAFE 9702"
            let due = Self.date(10, 12, 23, 59)
            let (state, _) = try makeState([
                canvasFind("121", course: course, title: "Submit weekly reflection", due: due),
                edFind("122", course: course, title: "Submit weekly reflection", due: due.addingTimeInterval(3600)),
            ])
            #expect(live(state, course).count == 1)
            #expect(live(state, course).first?.announcementOrigin == .canvas)
        }
    }

    @Test("when one of two same-day copies has already gone by, the live copy is the card, not the lapsed one")
    func liveTwinOutlastsLapsedTwin() throws {
        try withPinnedDefaults {
            let course = "ANSAFE 9703"
            // 8 a.m. and 8 p.m. on the day, and it is noon: the first has lapsed, the second has not.
            // Canvas would win the tie, and the lapse is decided after the duplicate check.
            let morning = canvasFind("131", course: course, title: "Submit PS3", due: Self.date(10, 8, 8))
            let evening = edFind("132", course: course, title: "Submit PS3", due: Self.date(10, 8, 20))
            let (state, _) = try makeState([morning, evening])

            #expect(live(state, course).map(\.id) == [evening.id])
            #expect(past(state, course).isEmpty, "the lapsed copy is a duplicate of the live one, not a second entry in prev")
        }
    }

    @Test("lapsed rows are offered to the duplicate check last, and the default order is unchanged")
    func lapsedOrder() {
        func item(_ sourceID: String, due: Date?) -> Assignment {
            Assignment(source: .canvasAnnouncement, sourceID: sourceID, kind: .assignment, course: "ANSAFE 9704",
                       title: "T", dueAt: due, url: nil)
        }
        let early = item("announcement-1-0", due: Self.date(10, 8, 8))
        let late = item("announcement-2-0", due: Self.date(10, 8, 20))
        let undated = item("announcement-3-0", due: nil)

        #expect(AppState.announcementDedupOrder([undated, late, early]).map(\.id)
            == [early.id, late.id, undated.id])
        #expect(AppState.announcementDedupOrder([undated, late, early], lapsed: [early.id]).map(\.id)
            == [late.id, undated.id, early.id])
    }

    // MARK: 1. A tick is about one date

    @Test("a tick on the 6th does not complete the 20th")
    func tickDoesNotCrossDates() throws {
        try withPinnedDefaults {
            let course = "ANSAFE 9705"
            let sixth = edFind("141", course: course, title: "Submit weekly reflection", due: Self.date(10, 6, 23, 59))
            let twentieth = canvasFind("142", course: course, title: "Submit weekly reflection", due: Self.date(10, 20, 23, 59))
            let (state, _) = try makeState([sixth, twentieth])
            defer { state.markActive(sixth) }

            state.markCompleted(sixth)
            state.rebuildDashboardItemsForTesting(now: Self.now)

            #expect(state.isCompleted(sixth))
            #expect(!state.isCompleted(twentieth), "the 20th has not been done")
            #expect(live(state, course).map(\.id) == [twentieth.id])
        }
    }

    @Test("a tick on a copy of the same day's task follows onto the one that is shown; across more than a day it does not")
    func completionFollowsRule() {
        func twin(hidden: Date?, survivor: Date?) -> AppState.AnnouncementTwin {
            AppState.AnnouncementTwin(hiddenID: "a", survivorID: "b", hiddenDue: hidden, survivorDue: survivor)
        }
        let day = Self.date(10, 20, 12)
        #expect(AppState.completionFollows(from: twin(hidden: day, survivor: day)))
        #expect(AppState.completionFollows(from: twin(hidden: day, survivor: day.addingTimeInterval(25 * 3600))))
        #expect(!AppState.completionFollows(from: twin(hidden: day, survivor: day.addingTimeInterval(27 * 3600))))
        #expect(!AppState.completionFollows(from: twin(hidden: Self.date(10, 6, 12), survivor: day)))
        // Either side undated: a tick on a task that never had a day is about the task.
        #expect(AppState.completionFollows(from: twin(hidden: nil, survivor: day)))
        #expect(AppState.completionFollows(from: twin(hidden: day, survivor: nil)))
    }

    @Test("a tick on an announcement's copy does not complete a Canvas assignment due two weeks from it, though the two read as the same title")
    func tickDoesNotCrossToAFeedItem() throws {
        try withPinnedDefaults {
            let course = "ANSAFE 9708"
            let announced = canvasFind("171", course: course, title: "Submit Problem Set 3", due: Self.date(10, 6, 23, 59))
            let (state, _) = try makeState([announced])
            defer { state.markActive(announced) }
            state.markCompleted(announced)

            let feed = Assignment(
                source: .canvas, sourceID: "event-assignment-9708", kind: .assignment, course: course,
                title: "Problem Set 3", dueAt: Self.date(10, 20, 23, 59),
                url: URL(string: "https://canvas.upenn.edu/courses/9708/assignments/9708")
            )
            state.canvasItems = [feed]
            state.rebuildDashboardItemsForTesting(now: Self.now)

            #expect(!state.isCompleted(feed), "the problem set due the 20th is not done because the announcement for the 6th was")
            #expect(live(state, course).map(\.id) == [feed.id])
        }
    }

    @Test("a tick on the syllabus's exam does not follow it to the date an announcement moves it to; a tick within a day does")
    func tickDoesNotCrossAReschedule() throws {
        try withPinnedDefaults {
            let course = "ANSAFE 9706"
            let syllabus = Assignment(
                source: .canvasAnnouncement,
                sourceID: AnnouncementRecord.syllabusFindSourceID(courseID: "9706", examKey: "midterm-1"),
                kind: .event, course: course, title: "Midterm 1", dueAt: Self.date(10, 23, 23, 59), url: nil
            )
            let (state, store) = try makeState([syllabus])
            defer { state.markActive(syllabus) }
            state.markCompleted(syllabus)

            // The announcement moves the exam a week: one card, the new date, not done.
            let moved = canvasFind("151", course: course, title: "Midterm 1", due: Self.date(10, 30, 14))
            defer { state.markActive(moved) }
            store.upsert([moved])
            state.applyAnnouncementLedgerChange()
            state.rebuildDashboardItemsForTesting(now: Self.now)

            #expect(live(state, course).map(\.id) == [moved.id])
            #expect(!state.isCompleted(moved), "done for the 23rd is not done for the 30th")
            #expect(state.isCompleted(syllabus), "and the tick on the 23rd is still the student's")
        }
    }

    // MARK: 4. An edited date outlives the row being hidden

    @Test("a due date the student edited is kept while its row is hidden, and goes only when the row leaves the ledger")
    func editSurvivesHiding() throws {
        try withPinnedDefaults {
            let suite = "ansafe-edits-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let course = "ANSAFE 9707"
            let edited = canvasFind("161", course: course, title: "Submit the survey", due: Self.date(10, 12, 12))
            let other = canvasFind("162", course: course, title: "Upload the memo", due: Self.date(10, 13, 12))
            let (state, store) = try makeState([edited, other], dueDateEditsDefaults: defaults)

            let moved = Self.date(10, 15, 12)
            state.setDueDateEdit(moved, for: edited)
            #expect(state.editedDueDate(for: edited) == moved)

            // Its post is deleted in Canvas: the row is flagged and the card goes.
            store.markGoneFromFeed(ids: [edited.id])
            state.applyAnnouncementLedgerChange()
            state.rebuildDashboardItemsForTesting(now: Self.now)
            #expect(live(state, course).map(\.id) == [other.id], "hidden")
            #expect(state.editedDueDate(for: edited) == moved, "but the edit is the student's, and the post may come back")

            // The post comes back and the card is back with its edit.
            store.markPresentInFeed(ids: [edited.id])
            state.applyAnnouncementLedgerChange()
            state.rebuildDashboardItemsForTesting(now: Self.now)
            #expect(Set(live(state, course).map(\.id)) == [edited.id, other.id])
            #expect(state.editedDueDate(for: edited) == moved)

            // Only a row that has left the ledger loses its edit.
            store.delete(ids: [edited.id])
            state.applyAnnouncementLedgerChange()
            state.rebuildDashboardItemsForTesting(now: Self.now)
            #expect(state.editedDueDate(for: edited) == nil)
        }
    }
}
