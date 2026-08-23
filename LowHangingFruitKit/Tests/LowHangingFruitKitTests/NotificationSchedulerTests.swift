import XCTest
@testable import LowHangingFruitUI
import LowHangingFruitKit

/// Tests the pure scheduling logic (`plannedRequests`) without touching
/// `UNUserNotificationCenter`.
///
/// These cover the *global* layer only — the behaviour every course inherits
/// when nobody has configured anything. The per-course layer that sits on top of
/// it (mutes, overrides, the recurring switch, and the round-robin budget) is in
/// `PerCourseNotificationTests`.
///
/// Every test builds its scheduler on a throwaway defaults suite and hands the
/// planner an empty preferences store over the same suite. Both are deliberate:
/// `UserDefaults.lhf` resolves to the process-wide standard domain in a test
/// run, so a scheduler reading it would inherit whatever reminder settings — and
/// whatever `coursePreferences` blob — an earlier suite happened to leave
/// behind, and "defaults: [.h24, .h1]" below would be a hope rather than a fact.
@MainActor
final class NotificationSchedulerTests: XCTestCase {

    /// Runs `body` with a scheduler on its own defaults suite plus the empty
    /// per-course store the planner should consult, then destroys the suite.
    ///
    /// A closure rather than a `makeScheduler()` paired with `tearDown`: XCTest
    /// calls `tearDown` from a nonisolated context, so tracking the suite names
    /// on a `@MainActor` test case to clean up there is a concurrency warning
    /// waiting to happen. Cleaning up in a `defer` inside the isolated test body
    /// has neither that problem nor the one where a `fatalError` mid-test skips
    /// the teardown entirely.
    private func withScheduler(_ body: (NotificationScheduler, CoursePreferencesStore) -> Void) {
        let name = "lhf.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            return XCTFail("could not open a scratch defaults suite")
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        body(NotificationScheduler(defaults: defaults), CoursePreferencesStore(defaults: defaults))
    }

    private func item(_ id: String, due: Date?, completed: Bool = false) -> DashItem {
        let a = Assignment(source: .canvas, sourceID: id, kind: .assignment,
                           course: "CIS 2400", title: "HW \(id)", dueAt: due, url: nil)
        return DashItem(assignment: a, dueOverride: nil, isCompleted: completed, completedAt: nil)
    }

    func testFiltersIneligibleAndUsesDefaultOffsets() {
        withScheduler { s, prefs in    // defaults: [.h24, .h1], digest off
            let now = Date()
            let items = [
                item("1", due: now.addingTimeInterval(3 * 86_400)),                 // eligible → 2 reminders
                item("2", due: now.addingTimeInterval(-86_400)),                    // overdue → excluded
                item("3", due: nil),                                                // undated → excluded
                item("4", due: now.addingTimeInterval(30 * 86_400)),                // beyond 14d horizon → excluded
                item("5", due: now.addingTimeInterval(3 * 86_400), completed: true) // completed → excluded
            ]
            let reqs = s.plannedRequests(from: items, now: now, preferences: prefs)
            XCTAssertEqual(reqs.count, 2, "only the one eligible item should schedule, at 24h and 1h")
            XCTAssertTrue(reqs.allSatisfy { $0.identifier.hasPrefix("due:canvas:1:") })
            // Stable, unique identifiers per (assignment, offset).
            XCTAssertEqual(Set(reqs.map(\.identifier)).count, reqs.count)
        }
    }

    func testSkipsOffsetsAlreadyInThePast() {
        withScheduler { s, prefs in
            let now = Date()
            // Due in 30 min: both the 24h-before and 1h-before reminders are already past.
            let reqs = s.plannedRequests(from: [item("x", due: now.addingTimeInterval(1800))],
                                         now: now, preferences: prefs)
            XCTAssertEqual(reqs.count, 0)
        }
    }

    func testTitlesCarryUrgencyEmojiAndInterruptionLevel() {
        withScheduler { s, prefs in    // defaults: [.h24, .h1]
            let now = Date()
            // Due in 3 days → a 24h-before (soon/🔵) and a 1h-before (today/🟠) reminder.
            let reqs = s.plannedRequests(from: [item("1", due: now.addingTimeInterval(3 * 86_400))],
                                         now: now, preferences: prefs)
            XCTAssertEqual(reqs.count, 2)

            let dots: Set<Character> = ["🔴", "🟠", "🔵", "🟢"]
            for r in reqs {
                guard let first = r.content.title.first else { return XCTFail("empty title") }
                XCTAssertTrue(dots.contains(first), "title should lead with an urgency dot: \(r.content.title)")
            }
            // The 1h-before reminder is time-sensitive; the 24h-before one is not.
            XCTAssertTrue(reqs.contains { $0.content.interruptionLevel == .timeSensitive })
            XCTAssertTrue(reqs.contains { $0.content.interruptionLevel == .active })
        }
    }

    func testCapsAtMaxPending() {
        withScheduler { s, prefs in
            let now = Date()
            // 50 items × 2 offsets = 100 candidate reminders → capped.
            let items = (0..<50).map { item("\($0)", due: now.addingTimeInterval(Double(2 * 86_400 + $0 * 60))) }
            let reqs = s.plannedRequests(from: items, now: now, preferences: prefs)
            XCTAssertLessThanOrEqual(reqs.count, NotificationScheduler.maxPending)
            XCTAssertGreaterThan(reqs.count, 0)
        }
    }
}
