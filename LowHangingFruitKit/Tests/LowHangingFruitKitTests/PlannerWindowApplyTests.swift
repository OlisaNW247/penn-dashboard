import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// `AppState.applyPlannerWindow` and `pollPlannerWindowIfInsideTheHour`: a
/// confirmed submitted read from a complete planner window marks the card done
/// the way the full structured run does (the additive set) and calls the
/// canceller; nothing partial, rate-limited or expired is believed.
@MainActor
@Suite("Planner window apply")
struct PlannerWindowApplyTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func feedRow(_ assignmentID: String) -> Assignment {
        Assignment(
            source: .canvas, sourceID: "event-assignment-\(assignmentID)", kind: .assignment,
            course: "STRW 0151", title: "PSet \(assignmentID)", dueAt: date("2026-11-18T16:00:00Z"),
            url: URL(string: "https://canvas.upenn.edu/courses/7/assignments/\(assignmentID)"))
    }

    private final class Seen: @unchecked Sendable {
        var calls: [(Set<String>, WakeSource)] = []
    }

    private struct Rig {
        let state: AppState
        let seen: Seen
        let counts: UserDefaults
        let suite: String
    }

    private func rig() throws -> Rig {
        let suite = "PlannerWindowApplyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = try AssignmentStore(inMemory: true)
        store.upsert([feedRow("55"), feedRow("56")])
        let state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults)
        state.forceFixtureDataForTesting(false)
        state.structuredDefaults = defaults
        state.sweeperCountsDefaults = defaults
        let seen = Seen()
        state.submissionCanceller = { ids, source in seen.calls.append((ids, source)) }
        return Rig(state: state, seen: seen, counts: defaults, suite: suite)
    }

    private func item(_ assignmentID: String, submitted: Bool?, markedComplete: Bool = false) -> CanvasPlannerItem {
        CanvasPlannerItem(plannableType: "assignment", plannableID: assignmentID, markedComplete: markedComplete,
                          submitted: submitted, assignmentID: assignmentID)
    }

    private func settle(_ r: Rig, expecting calls: Int) async {
        for _ in 0..<200 where r.seen.calls.count < calls { await Task.yield() }
    }

    @Test("A submitted item lands in the structured set and reaches the canceller with .poll")
    func submittedApplied() async throws {
        let r = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        let reads = r.state.applyPlannerWindow(
            PlannerWindowResult(items: [item("55", submitted: true), item("56", submitted: false)], completed: true), now: now)
        await settle(r, expecting: 1)

        #expect(reads.map(\.verdict) == [.submitted, .unsubmitted])
        let ledgerID = feedRow("55").id
        #expect(r.state.structuredCompletedItemIDs == [ledgerID])
        let call = try #require(r.seen.calls.first)
        #expect(call.1 == .poll)
        #expect(call.0.contains(ledgerID) && call.0.contains("55"))
        #expect(!call.0.contains("56") && !call.0.contains(feedRow("56").id))
        #expect(r.state.structuredDismissedItemIDs.isEmpty && r.state.structuredDueOverrides.isEmpty)
    }

    @Test("A Planner tick counts as submitted")
    func tick() async throws {
        let r = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        r.state.applyPlannerWindow(
            PlannerWindowResult(items: [item("56", submitted: nil, markedComplete: true)], completed: true), now: now)
        #expect(r.state.structuredCompletedItemIDs == [feedRow("56").id])
    }

    @Test("A partial, rate-limited or expired answer applies nothing and counts an unknown read",
          arguments: [(false, false, false), (true, true, false), (true, false, true)])
    func notBelieved(completed: Bool, rateLimited: Bool, expired: Bool) async throws {
        let r = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        let reads = r.state.applyPlannerWindow(
            PlannerWindowResult(items: [item("55", submitted: true)], completed: completed,
                                rateLimited: rateLimited, sessionExpired: expired), now: now)
        await Task.yield()
        #expect(r.state.structuredCompletedItemIDs.isEmpty)
        #expect(r.seen.calls.isEmpty)
        #expect(reads.allSatisfy { $0.verdict == .unknown })
        #expect(SweeperCounts.snapshot(defaults: r.counts)[SweeperCounts.readsUnknown] == 1)
    }

    @Test("An unsubmitted or unknown read changes nothing")
    func notSubmitted() async throws {
        let r = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        r.state.applyPlannerWindow(
            PlannerWindowResult(items: [item("55", submitted: false), item("56", submitted: nil)], completed: true), now: now)
        await Task.yield()
        #expect(r.state.structuredCompletedItemIDs.isEmpty)
        #expect(r.seen.calls.isEmpty)
    }

    @Test("An item already in the set is not cancelled again; a student's un-tick is not overridden")
    func idempotent() async throws {
        let r = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        let window = PlannerWindowResult(items: [item("55", submitted: true)], completed: true)
        r.state.applyPlannerWindow(window, now: now)
        r.state.applyPlannerWindow(window, now: now)
        await settle(r, expecting: 1)
        await Task.yield()
        #expect(r.seen.calls.count == 1)

        let r2 = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: r2.suite) }
        r2.state.structuredCompletionOverrides = [feedRow("55").id]
        r2.state.applyPlannerWindow(window, now: now)
        await Task.yield()
        #expect(r2.seen.calls.isEmpty)
    }

    @Test("Fixture data applies nothing")
    func fixture() async throws {
        let r = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        r.state.forceFixtureDataForTesting(true)
        let reads = r.state.applyPlannerWindow(
            PlannerWindowResult(items: [item("55", submitted: true)], completed: true), now: now)
        #expect(reads.isEmpty && r.state.structuredCompletedItemIDs.isEmpty)
    }

    @Test("The shared poll reads only inside the hour, and a read counts a poll")
    func insideTheHour() async throws {
        let r = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        let asked = Seen()
        r.state.plannerWindowFetchForTesting = { _, _ in
            asked.calls.append(([], .poll))
            return PlannerWindowResult(items: [], completed: true)
        }
        let outside = await r.state.pollPlannerWindowIfInsideTheHour(nextRing: now.addingTimeInterval(7200), source: .launch, now: now)
        let none = await r.state.pollPlannerWindowIfInsideTheHour(nextRing: nil, source: .launch, now: now)
        #expect(!outside && !none && asked.calls.isEmpty)
        let inside = await r.state.pollPlannerWindowIfInsideTheHour(nextRing: now.addingTimeInterval(1800), source: .foreground, now: now)
        #expect(inside && asked.calls.count == 1)
        #expect(SweeperCounts.snapshot(defaults: r.counts)[SweeperCounts.polls] == 1)
        #expect(r.state.lastPlannerWindowResult?.completed == true)
    }
}
