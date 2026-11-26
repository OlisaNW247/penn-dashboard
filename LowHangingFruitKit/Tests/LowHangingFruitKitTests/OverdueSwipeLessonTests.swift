import Foundation
import Testing
import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Overdue swipe lesson")
struct OverdueSwipeLessonTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func item(_ id: String, due: Date?, override: Date? = nil, done: Bool = false) -> DashItem {
        let a = Assignment(source: .canvas, sourceID: id, kind: .assignment, course: "BIO 101",
                           title: id, dueAt: due, url: nil)
        return DashItem(assignment: a, dueOverride: override, isCompleted: done, completedAt: nil)
    }

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/LowHangingFruitUI/\(name)"), encoding: .utf8)
    }

    @Test("five days exactly qualifies, a minute short does not, the most overdue wins")
    func boundary() {
        #expect(OverdueSwipeLesson.candidate(in: [item("a", due: now - 5 * day)], now: now)?.id != nil)
        #expect(OverdueSwipeLesson.candidate(in: [item("a", due: now - 5 * day + 60)], now: now) == nil)
        let picked = OverdueSwipeLesson.candidate(in: [item("six", due: now - 6 * day), item("ten", due: now - 10 * day)], now: now)
        #expect(picked?.assignment.sourceID == "ten")
    }

    @Test("completed, undated and moved-forward items are excluded; the override decides")
    func excluded() {
        #expect(OverdueSwipeLesson.candidate(in: [item("a", due: now - 9 * day, done: true)], now: now) == nil)
        #expect(OverdueSwipeLesson.candidate(in: [item("a", due: nil)], now: now) == nil)
        #expect(OverdueSwipeLesson.candidate(in: [item("a", due: now - 10 * day, override: now + day)], now: now) == nil)
        #expect(OverdueSwipeLesson.candidate(in: [item("a", due: now + day, override: now - 6 * day)], now: now) != nil)
    }

    @Test("whole days, floored")
    func days() {
        #expect(OverdueSwipeLesson.overdueDays(of: item("a", due: now - 5 * day), now: now) == 5)
        #expect(OverdueSwipeLesson.overdueDays(of: item("a", due: now - 5 * day - 23 * 3600), now: now) == 5)
        #expect(OverdueSwipeLesson.overdueDays(of: item("a", due: now - 6 * day), now: now) == 6)
    }

    @Test("shouldShow is true only for a candidate, unshown, real data, no reconnect")
    func truthTable() {
        #expect(OverdueSwipeLesson.shouldShow(hasCandidate: true, alreadyShown: false, usingFixtureData: false, reconnecting: false))
        #expect(!OverdueSwipeLesson.shouldShow(hasCandidate: false, alreadyShown: false, usingFixtureData: false, reconnecting: false))
        #expect(!OverdueSwipeLesson.shouldShow(hasCandidate: true, alreadyShown: true, usingFixtureData: false, reconnecting: false))
        #expect(!OverdueSwipeLesson.shouldShow(hasCandidate: true, alreadyShown: false, usingFixtureData: true, reconnecting: false))
        #expect(!OverdueSwipeLesson.shouldShow(hasCandidate: true, alreadyShown: false, usingFixtureData: false, reconnecting: true))
    }

    @Test("the store remembers once")
    func store() {
        let name = "OverdueSwipeLessonTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OverdueSwipeLessonStore(defaults: defaults)
        #expect(!store.hasShown)
        store.markShown()
        #expect(store.hasShown)
        #expect(OverdueSwipeLessonStore.key == "overdueSwipeLessonShownV1")
    }

    @Test("the forced pick")
    func forced() {
        let fallback = OverdueSwipeLesson.forcedCandidate(in: [], now: now)
        #expect((fallback.due ?? now) <= now - 5 * day)
        let items = [item("done", due: now, done: true), item("first", due: now + day), item("second", due: now)]
        #expect(OverdueSwipeLesson.forcedCandidate(in: items, now: now).assignment.sourceID == "first")
    }

    @Test("wiring: the dashboard, the onboarding mark, and the lesson's own limits")
    func wiring() throws {
        let content = try source("ContentView.swift")
        #expect(content.contains("OverdueSwipeLesson.shouldShow("))
        let cover = try #require(content.range(of: "private func overdueLessonCover"))
        // R-I2: the key is written when the cover appears, never at decision.
        #expect(!content[..<cover.lowerBound].contains("store.markShown()"))
        #expect(content[cover.upperBound...].contains(".onAppear"))
        #expect(content[cover.upperBound...].contains("OverdueSwipeLessonStore().markShown()"))
        #expect(content[cover.upperBound...].contains("vm.commitCompletion(item)"))
        #expect(try source("OnboardingView.swift").contains("OverdueSwipeLessonStore().markShown()"))
        let lesson = try source("OverdueSwipeLesson.swift")
        #expect(lesson.contains("swipe right to clear it"))
        #expect(lesson.contains("not now"))
        #expect(!lesson.contains("markCompleted("))
        #expect(!lesson.contains("assignmentStore"))
    }

    @Test("the view's copy is lowercase")
    func lowercase() throws {
        let lesson = try source("OverdueSwipeLesson.swift")
        let view = try #require(lesson.range(of: "struct OverdueSwipeLessonView"))
        let text = String(lesson[view.lowerBound...])
        for needle in ["Text(\"", "Button(\"", "Label(\"", "? \""] {
            var rest = text[...]
            while let r = rest.range(of: needle) {
                let next = rest[r.upperBound...].first
                #expect(next.map { !$0.isUppercase } ?? true)
                rest = rest[r.upperBound...]
            }
        }
    }
}
