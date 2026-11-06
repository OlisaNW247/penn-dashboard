import Foundation
import Testing
@testable import LowHangingFruitKit

/// The on-device answerer's pool carries cancellation (`WorkItem.isCancelled`,
/// set from an applied fact), so ask does not list a cancelled quiz as work
/// the student still has to do.
@Suite("On-device ask: cancelled items")
struct OnDeviceCancelledItemsTests {
    private typealias F = AssistantFixture

    private func item(_ id: String, _ title: String, day: Int, kind: Assignment.Kind = .assignment, cancelled: Bool = false) -> WorkItem {
        WorkItem(id: id, course: "CIS 2400", title: title, kind: kind, dueAt: F.at(day: day),
                 url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"), isCompleted: false, isCancelled: cancelled)
    }

    private func answer(_ question: String, _ items: [WorkItem]) -> String {
        let context = AskKnowledgeContext(
            userName: "", now: F.now, calendar: F.calendar, items: items,
            knowledge: CourseKnowledgeBase(courses: F.courses, documents: [], lastSyncedAt: F.now)
        )
        return ClassQuestionAnswerer(context: context).answer(question).text
    }

    @Test("a cancelled item is not listed as due, and is not the next quiz")
    func notListedAsOutstanding() {
        let items = [
            item("1", "Quiz Cancelled", day: 10, kind: .quiz, cancelled: true),
            item("2", "PSet Live", day: 11),
            item("3", "Quiz Live", day: 14, kind: .quiz),
        ]
        let due = answer("what's due this week", items)
        #expect(!due.contains("Quiz Cancelled"), "\(due)")
        #expect(due.contains("PSet Live"), "\(due)")
        let next = answer("when is the next quiz", items)
        #expect(!next.contains("Quiz Cancelled"), "\(next)")
        #expect(next.contains("Quiz Live"), "\(next)")
    }

    @Test("asking about a cancelled item by name says it was cancelled")
    func namedLookupSaysCancelled() {
        let text = answer("when is Quiz Cancelled due", [item("1", "Quiz Cancelled", day: 10, kind: .quiz, cancelled: true)])
        #expect(text.contains("Quiz Cancelled"), "\(text)")
        #expect(text.contains("cancelled"), "\(text)")
    }

    @Test("a cancelled item is not overdue work either")
    func notOverdue() {
        let late = WorkItem(id: "9", course: "CIS 2400", title: "Old Quiz", kind: .quiz, dueAt: F.at(day: 6),
                            url: nil, isCompleted: false, isCancelled: true)
        let text = answer("anything overdue?", [late])
        #expect(!text.contains("Old Quiz"), "\(text)")
    }
}
