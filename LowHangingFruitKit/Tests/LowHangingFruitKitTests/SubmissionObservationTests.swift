import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Submission observation cancellations")
struct SubmissionObservationTests {
    let due = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ sourceID: String, url: String? = nil, linkedID: String? = nil, due: Date?) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: sourceID, kind: .assignment, course: "CIS 1200",
                                   title: "HW", dueAt: due, url: url.flatMap(URL.init(string:)), linkedID: linkedID),
            dueOverride: nil, isCompleted: false, completedAt: nil)
    }

    func expectedRequests(_ id: String) -> Set<String> {
        Set(LeadOffset.allCases.map { "due:\(id):\($0.rawValue)" })
            .union((1...NotificationScheduler.loudAlertCount).map { "loud:\(id):\($0)" })
    }

    func expectedAlarms(_ id: String, due: Date) -> Set<UUID> {
        var out = Set<UUID>()
        for m in NotificationScheduler.sweeperMinuteOptions {
            for s in SweeperSound.allCases {
                out.insert(BerserkAlarmPlan.alarmID(
                    assignmentID: id, fireDate: due.addingTimeInterval(-Double(m * 60)), sound: s))
            }
        }
        return out
    }

    @Test("One id yields exactly its request ids and alarm ids")
    func oneItem() {
        let a = item("a", due: due), b = item("b", due: due)
        let r = SubmissionObservation.cancellations(submittedAssignmentIDs: [a.id], items: [a, b])
        #expect(Set(r.requestIDs) == expectedRequests(a.id))
        #expect(r.requestIDs.count == LeadOffset.allCases.count + NotificationScheduler.loudAlertCount)
        #expect(r.alarmIDs == expectedAlarms(a.id, due: due))
        #expect(r.alarmIDs.count == NotificationScheduler.sweeperMinuteOptions.count * SweeperSound.allCases.count)
        #expect(r.requestIDs.allSatisfy { !$0.contains(b.id) })
    }

    @Test("ids(forAssignmentID:due:) equals cancellations for a single item")
    func idsMatchCancellations() {
        let a = item("a", due: due)
        let c = SubmissionObservation.cancellations(submittedAssignmentIDs: [a.id], items: [a])
        let i = SubmissionObservation.ids(forAssignmentID: a.id, due: a.due)
        #expect(i.requestIDs == c.requestIDs)
        #expect(i.alarmIDs == c.alarmIDs)
        #expect(SubmissionObservation.ids(forAssignmentID: a.id, due: nil).alarmIDs.isEmpty)
    }

    @Test("Two ids yield both, and nothing else's")
    func twoItems() {
        let a = item("a", due: due), b = item("b", due: due), c = item("c", due: due)
        let r = SubmissionObservation.cancellations(submittedAssignmentIDs: [a.id, b.id], items: [a, b, c])
        #expect(Set(r.requestIDs) == expectedRequests(a.id).union(expectedRequests(b.id)))
        #expect(r.alarmIDs == expectedAlarms(a.id, due: due).union(expectedAlarms(b.id, due: due)))
    }

    @Test("A match through linkedID or the Canvas assignment id")
    func twinsAndCanvasID() {
        let linked = item("a", linkedID: "gradescope:zz", due: due)
        let r1 = SubmissionObservation.cancellations(submittedAssignmentIDs: ["gradescope:zz"], items: [linked])
        #expect(Set(r1.requestIDs) == expectedRequests(linked.id))

        let canvas = item("b", url: "https://canvas.example.edu/courses/1/assignments/777", due: due)
        #expect(canvas.assignment.canvasAssignmentID == "777")
        let r2 = SubmissionObservation.cancellations(submittedAssignmentIDs: ["777"], items: [canvas, linked])
        #expect(Set(r2.requestIDs) == expectedRequests(canvas.id))
    }

    @Test("No due date yields request ids only; no match yields nothing")
    func undatedAndNoMatch() {
        let undated = item("a", due: nil)
        let r = SubmissionObservation.cancellations(submittedAssignmentIDs: [undated.id], items: [undated])
        #expect(r.requestIDs.count == LeadOffset.allCases.count + NotificationScheduler.loudAlertCount)
        #expect(r.alarmIDs.isEmpty)
        let none = SubmissionObservation.cancellations(submittedAssignmentIDs: ["nope"], items: [undated])
        #expect(none.requestIDs.isEmpty && none.alarmIDs.isEmpty)
    }

    @Test("The three fallback buzzes are cancelled too, exactly loudAlertCount per matched item")
    func loudBuzzes() {
        let a = item("a", due: due), b = item("b", due: due)
        let r = SubmissionObservation.cancellations(submittedAssignmentIDs: [a.id], items: [a, b])
        let loud = r.requestIDs.filter { $0.hasPrefix("loud:") }
        #expect(loud.count == NotificationScheduler.loudAlertCount)
        #expect(Set(loud) == Set(NotificationScheduler.loudIdentifiers(forAssignmentID: a.id)))
        #expect(loud.allSatisfy { !$0.contains(b.id) })
    }

    @Test("The request id prefix is the scheduler's own")
    func prefix() {
        #expect(NotificationScheduler.requestIdentifierPrefix == "due:")
    }
}
