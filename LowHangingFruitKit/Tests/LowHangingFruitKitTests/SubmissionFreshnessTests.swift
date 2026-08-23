import Testing
import Foundation
@testable import LowHangingFruitKit

/// *When* the app last had a trustworthy answer about submission, as distinct
/// from what that answer was.
///
/// The flags alone collapse two very different situations into one word.
/// "Not submitted, confirmed a minute ago" is a reason to start working
/// tonight. "Not submitted, as far as we knew last Tuesday before the Canvas
/// session expired" is not — it might well be turned in already. The app shows
/// the same thing for both today, and the student has no way to tell which one
/// they are looking at.
///
/// These pin the timestamps down so the UI can eventually say "as of…", and so
/// the distinction can't quietly regress.
@MainActor
@Suite("Submission freshness")
struct SubmissionFreshnessTests {

    private func canvas(_ id: String, course: String = "CIS 1200") -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: course, title: "HW \(id)", dueAt: nil,
                   url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"))
    }

    private func gradescope(_ id: String, submitted: Bool) -> Assignment {
        Assignment(source: .gradescope, sourceID: id, kind: .assignment,
                   course: "CIS 1200", title: "PS \(id)", dueAt: nil,
                   url: nil, submitted: submitted)
    }

    private func row(_ store: AssignmentStore, _ id: String) -> StoredAssignment? {
        store.allRowsForTesting().first { $0.id == id }
    }

    @Test("a row nobody has asked about has no observation date")
    func neverObserved() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([canvas("1")], source: .canvas)

        let r = try #require(row(store, "canvas:1"))
        #expect(r.submissionObservedAt == nil)
        // Never observed is *unknown*, which is not the same as stale — the UI
        // has to be able to tell those apart.
        #expect(!r.hasFreshSubmissionState(within: 3600))
    }

    @Test("a Canvas refresh timestamps the answer, submitted or not")
    func canvasRefreshRecordsObservation() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([canvas("1"), canvas("2")], source: .canvas)
        let at = Date(timeIntervalSince1970: 1_700_000_000)

        // Only "1" came back as submitted. "2" was answered for too — the
        // answer was just "no", and that answer is exactly as much of an
        // observation as a yes.
        _ = store.applySubmissionState(submittedCanvasAssignmentIDs: ["1"], scores: [:], now: at)

        let submitted = try #require(row(store, "canvas:1"))
        let notSubmitted = try #require(row(store, "canvas:2"))
        #expect(submitted.canvasSubmitted)
        #expect(!notSubmitted.canvasSubmitted)
        #expect(submitted.canvasSubmissionObservedAt == at)
        #expect(notSubmitted.canvasSubmissionObservedAt == at)
    }

    @Test("a later refresh moves the observation date forward")
    func observationMovesForward() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([canvas("1")], source: .canvas)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = first.addingTimeInterval(3600)

        _ = store.applySubmissionState(submittedCanvasAssignmentIDs: ["1"], scores: [:], now: first)
        _ = store.applySubmissionState(submittedCanvasAssignmentIDs: [], scores: [:], now: second)

        let r = try #require(row(store, "canvas:1"))
        // The retraction self-heals *and* is timestamped: the student can see
        // that the app knows this is current, not a leftover.
        #expect(!r.canvasSubmitted)
        #expect(r.canvasSubmissionObservedAt == second)
    }

    @Test("a Gradescope scrape is itself the observation")
    func gradescopeScrapeRecordsObservation() throws {
        let store = try AssignmentStore(inMemory: true)
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        _ = store.reconcile([gradescope("9", submitted: true)], source: .gradescope, now: at)

        let r = try #require(row(store, "gradescope:9"))
        #expect(r.gradescopeSubmitted)
        #expect(r.gradescopeSubmissionObservedAt == at)
        #expect(r.hasFreshSubmissionState(now: at.addingTimeInterval(60), within: 3600))
        #expect(!r.hasFreshSubmissionState(now: at.addingTimeInterval(7200), within: 3600))
    }

    @Test("freshness reports the newest signal across platforms")
    func newestSignalWins() throws {
        let store = try AssignmentStore(inMemory: true)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = old.addingTimeInterval(86_400)

        // Same assignment known to both platforms: Gradescope scraped a day
        // ago, Canvas answered just now.
        _ = store.reconcile([gradescope("9", submitted: true)], source: .gradescope, now: old)
        _ = store.reconcile([canvas("1")], source: .canvas)
        _ = store.applySubmissionState(submittedCanvasAssignmentIDs: ["1"], scores: [:], now: recent)

        #expect(try #require(row(store, "gradescope:9")).submissionObservedAt == old)
        #expect(try #require(row(store, "canvas:1")).submissionObservedAt == recent)
    }

    @Test("observation dates survive a relaunch")
    func observationsPersist() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-fresh-\(UUID().uuidString).store")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let store = try AssignmentStore(url: url)
            _ = store.reconcile([canvas("1")], source: .canvas)
            _ = store.applySubmissionState(submittedCanvasAssignmentIDs: ["1"], scores: [:], now: at)
        }

        // The whole point: on a cold launch with no Canvas session, the app
        // still knows both what you turned in and how old that knowledge is.
        let reopened = try AssignmentStore(url: url)
        let r = try #require(row(reopened, "canvas:1"))
        #expect(r.canvasSubmitted)
        #expect(r.canvasSubmissionObservedAt == at)
    }

    @Test("rows written before observation dates existed read as unknown, not stale")
    func legacyRowsDegradeHonestly() throws {
        let store = try AssignmentStore(inMemory: true)
        // A row exactly as an older build left it: flag set, no timestamp.
        _ = store.reconcile([canvas("1")], source: .canvas)
        let r = try #require(row(store, "canvas:1"))
        r.canvasSubmitted = true

        #expect(r.canvasSubmitted)
        #expect(r.submissionObservedAt == nil)
        #expect(!r.hasFreshSubmissionState(within: .greatestFiniteMagnitude))
    }
}
