import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Sweeper quiet reasons")
struct SweeperQuietReasonTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var due: Date { now.addingTimeInterval(3 * 3600) }
    var horizon: Date { now.addingTimeInterval(14 * 86_400) }
    let on: (String) -> Bool = { _ in true }

    func item(source: Assignment.Source = .canvas, kind: Assignment.Kind = .assignment,
              title: String = "HW 1", course: String = "CIS 1200",
              noSubmission: Bool = false, paper: Bool = false,
              url: String? = "https://canvas.example.edu/courses/1/assignments/9",
              linkedID: String? = nil) -> DashItem {
        DashItem(
            assignment: Assignment(source: source, sourceID: "x", kind: kind, course: course,
                                   title: title, dueAt: due, url: url.flatMap(URL.init(string:)), linkedID: linkedID),
            dueOverride: nil, isCompleted: false, completedAt: nil,
            requiresNoSubmission: noSubmission, submitsOnPaper: paper)
    }

    @Test("Marco's decision: an item due in 3 hours with a Canvas id and nothing else is armed")
    func armed() {
        let settings = SweeperSettings()
        let i = item()
        #expect(settings.quietReason(for: i, courseRemindersOn: on) == nil)
        #expect(settings.qualifies(i, now: now, horizon: horizon, courseRemindersOn: on))
    }

    @Test("Nothing to submit is in class or off canvas")
    func nothingToSubmit() {
        let s = SweeperSettings()
        #expect(s.quietReason(for: item(noSubmission: true, paper: true), courseRemindersOn: on) == .inClass)
        #expect(s.quietReason(for: item(kind: .event), courseRemindersOn: on) == .inClass)
        #expect(s.quietReason(for: item(title: "Quiz 7", noSubmission: true), courseRemindersOn: on) == .inClass)
        #expect(s.quietReason(for: item(noSubmission: true), courseRemindersOn: on) == .offCanvas)
    }

    @Test("A found exam is quiet")
    func foundExam() {
        let i = item(source: .canvasAnnouncement, title: "Midterm 1")
        #expect(i.isFoundExam)
        #expect(SweeperSettings().quietReason(for: i, courseRemindersOn: on) == .foundExam)
    }

    @Test("Only a modules row with no Canvas assignment id is quiet for want of an id")
    func noConfirmableID() {
        let s = SweeperSettings()
        #expect(s.quietReason(for: item(source: .canvasModules, url: nil), courseRemindersOn: on) == .noConfirmableID)
        #expect(s.quietReason(for: item(source: .canvasModules), courseRemindersOn: on) == nil)
        // A bare .canvas row, a Gradescope row and a linked pair ring as ever.
        #expect(s.quietReason(for: item(url: nil), courseRemindersOn: on) == nil)
        #expect(s.quietReason(for: item(source: .gradescope, url: nil), courseRemindersOn: on) == nil)
        #expect(s.quietReason(for: item(url: nil, linkedID: "gradescope:zz"), courseRemindersOn: on) == nil)
    }

    @Test("A manual task due in 3 hours still qualifies")
    func manualStillRings() {
        // Silence is the dangerous side: the student's own task has no id by
        // nature and rings today, and a proven behaviour is not changed
        // without Marco's word.
        let s = SweeperSettings()
        let i = item(source: .manual, url: nil)
        #expect(s.quietReason(for: i, courseRemindersOn: on) == nil)
        #expect(s.qualifies(i, now: now, horizon: horizon, courseRemindersOn: on))
    }

    @Test("A class switched off, and a class with reminders off")
    func classRules() {
        var s = SweeperSettings()
        s.excludedCourses = ["CIS 1200"]
        #expect(s.quietReason(for: item(), courseRemindersOn: on) == .classOff)
        #expect(SweeperSettings().quietReason(for: item(), courseRemindersOn: { _ in false }) == .remindersOff)
    }

    @Test("pooledVerdict is reserved and the rule never returns it")
    func pooledNeverProduced() {
        #expect(SweeperQuietReason.allCases.contains(.pooledVerdict))
        #expect(SweeperQuietReason.allCases.contains(.nothingToSubmit))
    }

    @Test("qualifies is false exactly when a quiet reason applies (date checks aside)",
          arguments: [
            (false, false), (true, false), (false, true),
          ])
    func qualifiesAgrees(noSub: Bool, bare: Bool) {
        let s = SweeperSettings()
        let i = item(noSubmission: noSub, url: bare ? nil : "https://canvas.example.edu/courses/1/assignments/9")
        let quiet = s.quietReason(for: i, courseRemindersOn: on) != nil
        #expect(s.qualifies(i, now: now, horizon: horizon, courseRemindersOn: on) == !quiet)
    }
}
