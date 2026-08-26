import XCTest
@testable import LowHangingFruitUI
import LowHangingFruitKit

/// Tests the pure scheduling logic (`plannedRequests`) without touching
/// `UNUserNotificationCenter`.
@MainActor
final class NotificationSchedulerTests: XCTestCase {

    private func item(_ id: String, due: Date?, completed: Bool = false) -> DashItem {
        let a = Assignment(source: .canvas, sourceID: id, kind: .assignment,
                           course: "CIS 2400", title: "HW \(id)", dueAt: due, url: nil)
        return DashItem(assignment: a, dueOverride: nil, isCompleted: completed, completedAt: nil)
    }

    func testFiltersIneligibleAndUsesDefaultOffsets() {
        let s = NotificationScheduler()   // defaults: [.h24, .h1], digest off
        let now = Date()
        let items = [
            item("1", due: now.addingTimeInterval(3 * 86_400)),                 // eligible → 2 reminders
            item("2", due: now.addingTimeInterval(-86_400)),                    // overdue → excluded
            item("3", due: nil),                                                // undated → excluded
            item("4", due: now.addingTimeInterval(30 * 86_400)),                // beyond 14d horizon → excluded
            item("5", due: now.addingTimeInterval(3 * 86_400), completed: true) // completed → excluded
        ]
        let reqs = s.plannedRequests(from: items, now: now)
        XCTAssertEqual(reqs.count, 2, "only the one eligible item should schedule, at 24h and 1h")
        XCTAssertTrue(reqs.allSatisfy { $0.identifier.hasPrefix("due:canvas:1:") })
        // Stable, unique identifiers per (assignment, offset).
        XCTAssertEqual(Set(reqs.map(\.identifier)).count, reqs.count)
    }

    func testSkipsOffsetsAlreadyInThePast() {
        let s = NotificationScheduler()
        let now = Date()
        // Due in 30 min: both the 24h-before and 1h-before reminders are already past.
        let reqs = s.plannedRequests(from: [item("x", due: now.addingTimeInterval(1800))], now: now)
        XCTAssertEqual(reqs.count, 0)
    }

    func testContentIsClassNameAndLeadPhraseOnly() {
        let s = NotificationScheduler()   // defaults: [.h24, .h1]
        let now = Date()
        let reqs = s.plannedRequests(from: [item("1", due: now.addingTimeInterval(3 * 86_400))], now: now)
        XCTAssertEqual(reqs.count, 2)

        // Owner's redesign: title is the class name, body is the lead phrase,
        // and NOTHING else — no urgency emoji, no assignment title, no date.
        for r in reqs {
            XCTAssertEqual(r.content.title, "CIS 2400")
        }
        XCTAssertEqual(Set(reqs.map(\.content.body)), ["Due in 24 hours", "Due in 1 hour"])
        let emoji: Set<Character> = ["🔴", "🟠", "🔵", "🟢"]
        for r in reqs {
            XCTAssertTrue((r.content.title + r.content.body).allSatisfy { !emoji.contains($0) },
                          "no urgency dot anywhere in the text: \(r.content.title) / \(r.content.body)")
        }
        // Urgency still shapes behavior even though it left the text:
        // the 1h-before reminder is time-sensitive; the 24h-before one is not.
        XCTAssertTrue(reqs.contains { $0.content.interruptionLevel == .timeSensitive })
        XCTAssertTrue(reqs.contains { $0.content.interruptionLevel == .active })
    }

    func testCapsAtMaxPending() {
        let s = NotificationScheduler()
        let now = Date()
        // 50 items × 2 offsets = 100 candidate reminders → capped.
        let items = (0..<50).map { item("\($0)", due: now.addingTimeInterval(Double(2 * 86_400 + $0 * 60))) }
        let reqs = s.plannedRequests(from: items, now: now)
        XCTAssertLessThanOrEqual(reqs.count, NotificationScheduler.maxPending)
        XCTAssertGreaterThan(reqs.count, 0)
    }
}
