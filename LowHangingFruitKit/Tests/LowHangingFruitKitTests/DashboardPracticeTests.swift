import Testing
import Foundation
import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Dashboard practice")
struct DashboardPracticeTests {
    @Test("Complete moves to prev, undo returns to todo, and sync gates exit")
    func practiceFlow() {
        var practice = DashboardPracticeProgress()
        #expect(practice.step == .todo)
        #expect(!practice.canContinue(syncReady: true))
        practice.complete()
        #expect(practice.step == .previous)
        #expect(!practice.canContinue(syncReady: true))
        practice.undo()
        #expect(practice.step == .feature(.lists))
        #expect(!practice.canContinue(syncReady: true))
        for feature in DashboardPracticeProgress.Feature.allCases {
            #expect(practice.step == .feature(feature))
            #expect(!practice.canContinue(syncReady: true))
            practice.next()
        }
        #expect(practice.step == .ready)
        #expect(!practice.canContinue(syncReady: false))
        #expect(practice.canContinue(syncReady: true))
    }

    @Test("Out-of-order and repeated gesture callbacks cannot skip or replay a step")
    func repeatedGestures() {
        var practice = DashboardPracticeProgress()
        practice.undo()
        #expect(practice.step == .todo)
        practice.complete()
        practice.complete()
        #expect(practice.step == .previous)
        practice.undo()
        practice.complete()
        practice.undo()
        #expect(practice.step == .feature(.lists))
        #expect(DashboardPracticeProgress().step == .todo)
    }
    @Test("Feature explanations start right after undo and support going back, never past the first")
    func featureNavigation() {
        var practice = DashboardPracticeProgress()
        practice.next()
        #expect(practice.step == .todo)
        practice.complete()
        practice.next()
        #expect(practice.step == .previous)
        practice.undo()
        #expect(practice.step == .feature(.lists))
        practice.next()
        practice.back()
        #expect(practice.step == .feature(.lists))
        practice.back()
        #expect(practice.step == .feature(.lists))
    }


    @Test("skip lands on ready from any step and stays there")
    func skipFromAnywhere() {
        var a = DashboardPracticeProgress()
        a.skip(); #expect(a.step == .ready)
        var b = DashboardPracticeProgress(); b.complete()
        b.skip(); #expect(b.step == .ready)
        var c = DashboardPracticeProgress(); c.complete(); c.undo()
        c.next(); c.next()
        #expect(c.step == .feature(.add))
        c.skip(); #expect(c.step == .ready)
        c.skip(); #expect(c.step == .ready)
        #expect(!c.canContinue(syncReady: false))
        #expect(c.canContinue(syncReady: true))
    }

    private func assignment(_ id: String, _ course: String, days: Double, now: Date) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment, course: course, title: id,
                   dueAt: now.addingTimeInterval(days * 86_400), url: nil)
    }

    @Test("practice cards come from upcoming work, one per course first, soonest first")
    func practiceFromAssignments() {
        let now = Date()
        let list = [
            assignment("a", "MATH 1", days: -1, now: now),
            assignment("b", "MATH 1", days: 1, now: now),
            assignment("c", "MATH 1", days: 2, now: now),
            assignment("d", "ART 2", days: 3, now: now),
            assignment("e", "BIO 3", days: -2, now: now),
            assignment("f", "BIO 3", days: 5, now: now),
        ]
        let items = PracticeCards.items(from: list, now: now)
        #expect(items.count == 3)
        #expect(Set(items.map { $0.assignment.course }).count == 3)
        #expect(items.allSatisfy { ($0.assignment.dueAt ?? .distantPast) >= now })
        let dues = items.compactMap { $0.assignment.dueAt }
        #expect(dues == dues.sorted())
    }

    @Test("with nothing upcoming the practice cards are three generic ones")
    func practiceFallback() {
        let items = PracticeCards.items(from: [], now: Date())
        #expect(items.count == 3)
        #expect(Set(items.map { $0.assignment.course }).count == 3)
        #expect(items.allSatisfy { !$0.assignment.course.contains("CIS") })
    }
}
