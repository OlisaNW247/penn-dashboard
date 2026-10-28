import Testing
import Foundation
import SwiftData
@testable import LowHangingFruitKit

/// Collapsing two rows that carry one id must never lose a completion.
///
/// `StoredAssignment.absorb` used to merge the timestamps and submission flags
/// and then forget two things. It dropped `userCompleted`, so a tick recorded
/// "completed, when unknown" (no timestamp) was lost whenever the copy that
/// held it was the one deleted. And it kept whichever row was seen in the feed
/// last as the survivor, which is the bookkeeping row (`isCompletionOnly`)
/// whenever the completion was recorded after the last sync: that row carries
/// no title and no course, and it is hidden from every list, so the real
/// assignment disappeared from the dashboard and its completion with it
/// (hardening plan 2026-10-25, KCR-03 and DAT-13).
///
/// Every test here runs both orders of the pair, because the store resolves a
/// duplicate in whatever order the fetch happens to return rows, and a rule
/// that is only right in one order is a rule that works until it does not.
struct DuplicateRowCompletionTests {

    private let id = "canvas:dup"
    private let longAgo = Date(timeIntervalSince1970: 1_700_000_000)
    private let recently = Date(timeIntervalSince1970: 1_700_000_000 + 20 * 86_400)

    private func feedItem(title: String = "Problem set 4", course: String = "CIS 1200") -> Assignment {
        Assignment(source: .canvas, sourceID: "dup", kind: .assignment,
                   course: course, title: title,
                   dueAt: Date(timeIntervalSince1970: 1_700_000_000 + 30 * 86_400),
                   url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/dup"))
    }

    /// A real row seen in the feed once, long ago, with nothing ticked.
    private func realRow(title: String = "Problem set 4", seen: Date? = nil) -> StoredAssignment {
        StoredAssignment.make(from: feedItem(title: title), now: seen ?? longAgo)
    }

    /// The hidden row `setCompleted` writes when it has no row for an id yet:
    /// completed, timestamp unknown, created after the real row was last seen.
    private func bookkeepingRow() -> StoredAssignment {
        StoredAssignment.completionOnly(id: id, completedAt: nil, now: recently)!
    }

    private func tempStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-absorb-\(UUID().uuidString).store")
    }

    private func removeStore(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private func writeRawRows(_ rows: [StoredAssignment], to url: URL) throws {
        let container = try ModelContainer(
            for: StoredAssignment.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        for row in rows { context.insert(row) }
        try context.save()
    }

    // MARK: absorb, in both orders

    @MainActor
    @Test("a completion with no timestamp survives being absorbed, in either order")
    func untimedCompletionSurvivesBothOrders() {
        // Real row absorbing the bookkeeping row, then the other way round.
        let realFirst = realRow()
        realFirst.absorb(bookkeepingRow())
        #expect(realFirst.userCompleted)
        #expect(realFirst.isCompletedByUser, "the tick is the one thing a collapse must not cost")

        let bookkeepingFirst = bookkeepingRow()
        bookkeepingFirst.absorb(realRow())
        #expect(bookkeepingFirst.userCompleted)
        #expect(bookkeepingFirst.isCompletedByUser)
    }

    @MainActor
    @Test("two real copies: either one's tick wins, in either order")
    func tickOnEitherRealCopySurvives() {
        func ticked() -> StoredAssignment {
            let row = realRow(title: "Ticked copy")
            row.userCompleted = true   // "completed, when unknown": no completedAt
            return row
        }
        let survivorIsTicked = ticked()
        survivorIsTicked.absorb(realRow(title: "Untouched copy", seen: recently))
        #expect(survivorIsTicked.isCompletedByUser)

        let survivorIsUntouched = realRow(title: "Untouched copy", seen: recently)
        survivorIsUntouched.absorb(ticked())
        #expect(survivorIsUntouched.isCompletedByUser)
    }

    @MainActor
    @Test("the merged row is a bookkeeping row only when both copies were")
    func completionOnlyIsAnd() {
        let real = realRow()
        real.absorb(bookkeepingRow())
        #expect(!real.isCompletionOnly, "a real feed row must stay visible once a bookkeeping twin is folded in")

        let bookkeeping = bookkeepingRow()
        bookkeeping.absorb(realRow())
        #expect(!bookkeeping.isCompletionOnly, "and the real row's visibility cannot depend on which copy was kept")

        let twins = bookkeepingRow()
        twins.absorb(bookkeepingRow())
        #expect(twins.isCompletionOnly, "two bookkeeping rows are still only bookkeeping")
    }

    @MainActor
    @Test("display fields come from the real row, in either order")
    func displayFieldsComeFromTheRealRow() {
        let real = realRow(title: "Problem set 4")
        real.absorb(bookkeepingRow())
        #expect(real.title == "Problem set 4")
        #expect(real.course == "CIS 1200")

        let bookkeeping = bookkeepingRow()
        #expect(bookkeeping.title.isEmpty, "the fixture really is the blank row it is meant to be")
        bookkeeping.absorb(realRow(title: "Problem set 4"))
        #expect(bookkeeping.title == "Problem set 4")
        #expect(bookkeeping.course == "CIS 1200")
        #expect(bookkeeping.dueAt != nil)
        #expect(bookkeeping.urlString != nil)
    }

    // MARK: The observation dates travel with the flags

    @MainActor
    @Test("the later observation of each platform's submission wins, in either order")
    func observedAtTakesTheLaterOfTheTwo() {
        let early = Date(timeIntervalSince1970: 1_700_100_000)
        let middle = early.addingTimeInterval(3_600)
        let late = early.addingTimeInterval(7_200)

        func older() -> StoredAssignment {
            let row = realRow()
            row.canvasSubmitted = true
            row.canvasSubmissionObservedAt = early
            return row
        }
        func newer() -> StoredAssignment {
            let row = realRow(seen: recently)
            row.canvasSubmissionObservedAt = late
            row.gradescopeSubmissionObservedAt = middle
            return row
        }
        func onlyOneSide() -> StoredAssignment {
            let row = realRow(seen: recently)
            row.gradescopeSubmissionObservedAt = early
            return row
        }

        let a = older(); a.absorb(newer())
        let b = newer(); b.absorb(older())
        for merged in [a, b] {
            #expect(merged.canvasSubmissionObservedAt == late)
            #expect(merged.gradescopeSubmissionObservedAt == middle)
            #expect(merged.canvasSubmitted)
        }

        // A date on only one copy survives whichever copy that is.
        let c = older(); c.absorb(onlyOneSide())
        let d = onlyOneSide(); d.absorb(older())
        for merged in [c, d] {
            #expect(merged.canvasSubmissionObservedAt == early)
            #expect(merged.gradescopeSubmissionObservedAt == early)
        }
    }

    @MainActor
    @Test("a known score, an existing pairing and an archived term stay with self when both rows have one, as the doc comment says")
    func bothKnownValuesStayWithSelf() {
        let spring = Term(year: 2026, season: .spring)
        let fall = Term(year: 2025, season: .fall)
        func row(earned: Double, link: String, term: Term) -> StoredAssignment {
            let r = realRow()
            r.scoreEarned = earned
            r.scoreMax = 100
            r.linkedID = link
            r.pairingConfirmedAt = longAgo
            r.setArchivedTerm(term)
            return r
        }
        let mine = row(earned: 90, link: "gradescope:mine", term: spring)
        mine.absorb(row(earned: 70, link: "gradescope:theirs", term: fall))
        #expect(mine.scoreEarned == 90)
        #expect(mine.linkedID == "gradescope:mine")
        #expect(mine.archivedTerm == spring)

        // And a value on only one side is kept from either.
        let bare = realRow()
        bare.absorb(row(earned: 70, link: "gradescope:theirs", term: fall))
        #expect(bare.scoreEarned == 70)
        #expect(bare.linkedID == "gradescope:theirs")
    }

    // MARK: Which copy wins

    @MainActor
    @Test("exactly one of two copies outranks the other, however close they are")
    func outranksIsAStrictOrder() {
        // A real row beats bookkeeping even though bookkeeping is newer.
        let real = realRow()
        let bookkeeping = bookkeepingRow()
        #expect(real.outranks(bookkeeping))
        #expect(!bookkeeping.outranks(real))

        // Between two real rows, the one seen in the feed last.
        let stale = realRow(title: "Stale", seen: longAgo)
        let fresh = realRow(title: "Fresh", seen: recently)
        #expect(fresh.outranks(stale))
        #expect(!stale.outranks(fresh))

        // A tie on everything the old rule looked at is broken by content, so
        // the answer does not depend on which row the fetch returned first.
        let a = realRow(title: "A copy", seen: recently)
        let b = realRow(title: "B copy", seen: recently)
        #expect(a.outranks(b) != b.outranks(a))

        // Even byte-identical copies are ordered, so one of them is always
        // the survivor rather than neither.
        let twinX = realRow(title: "Same", seen: recently)
        let twinY = realRow(title: "Same", seen: recently)
        #expect(twinX.outranks(twinY) != twinY.outranks(twinX))
    }

    // MARK: Through the store, in both fetch orders

    /// The scenario that made the assignment disappear: the completion was
    /// recorded (a hidden row, stamped now) after the feed row was last seen,
    /// so the old "seen last wins" rule kept the blank, hidden copy.
    @MainActor
    @Test("a newer hidden completion row cannot hide the real assignment", arguments: [true, false])
    func storeKeepsTheRealRowVisible(realLoadsFirst: Bool) throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }
        try writeRawRows(realLoadsFirst ? [realRow(), bookkeepingRow()] : [bookkeepingRow(), realRow()], to: url)

        let store = try AssignmentStore(url: url)
        #expect(store.rowCount() == 1)
        let shown = try #require(store.currentAssignments().first, "the real assignment must still be on the dashboard")
        #expect(shown.title == "Problem set 4")
        #expect(store.completionRecordOrFail().ids == [id], "and still ticked")
    }

    @MainActor
    @Test("a tie between two real copies resolves to the same row in either fetch order")
    func tieResolvesTheSameWayInEitherOrder() throws {
        func survivorTitle(loadingFirst first: String, then second: String) throws -> String {
            let url = tempStoreURL()
            defer { removeStore(at: url) }
            try writeRawRows([realRow(title: first, seen: recently), realRow(title: second, seen: recently)], to: url)
            let store = try AssignmentStore(url: url)
            #expect(store.rowCount() == 1)
            return try #require(store.currentAssignments().first).title
        }
        let oneWay = try survivorTitle(loadingFirst: "A copy", then: "B copy")
        let otherWay = try survivorTitle(loadingFirst: "B copy", then: "A copy")
        #expect(oneWay == otherWay, "two devices sweeping the same pair must keep the same copy, or each deletes the other's")
    }
}
