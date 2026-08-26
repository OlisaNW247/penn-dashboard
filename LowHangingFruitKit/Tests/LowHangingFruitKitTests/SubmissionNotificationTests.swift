import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Coverage for the pure planning behind "Turned in ✓" notifications
/// (`AppState.submissionNotifications`) — no `UNUserNotificationCenter`
/// involved, matching how `NotificationSchedulerTests` /
/// `GradeChangeNotificationTests` cover their own pure planning helpers.
@MainActor
@Suite("Turned-in notifications")
struct SubmissionNotificationTests {

    private func canvasItem(id: String, title: String, course: String = "CIS 3200") -> Assignment {
        Assignment(
            source: .canvas,
            sourceID: "event-assignment-\(id)@canvas.upenn.edu",
            kind: .assignment,
            course: course,
            title: title,
            dueAt: Date(),
            url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)")
        )
    }

    @Test("a newly submitted id with a matching item announces its title and course")
    func matchingItemAnnouncesTitle() {
        let items = [canvasItem(id: "501", title: "Problem Set 4", course: "CIS 3200")]
        let notifications = AppState.submissionNotifications(
            newIDs: ["501"],
            previous: ["100"],
            items: items
        )
        #expect(notifications.count == 1)
        #expect(notifications[0].title == "Turned in ✓")
        #expect(notifications[0].body.contains("Problem Set 4"))
        #expect(notifications[0].body.contains("CIS 3200"))
    }

    @Test("a newly submitted id with no matching item gets a generic body")
    func unmatchedIDGetsGenericBody() {
        let notifications = AppState.submissionNotifications(
            newIDs: ["999"],
            previous: ["100"],
            items: [canvasItem(id: "501", title: "Problem Set 4")]
        )
        #expect(notifications.count == 1)
        #expect(notifications[0].title == "Turned in ✓")
        #expect(notifications[0].body == "An assignment was turned in.")
    }

    @Test("an empty previous set is a cold-start baseline and announces nothing")
    func emptyPreviousIsBaselineAndSilent() {
        let items = [canvasItem(id: "501", title: "Problem Set 4")]
        let notifications = AppState.submissionNotifications(
            newIDs: ["501", "502", "503"],
            previous: [],
            items: items
        )
        #expect(notifications.isEmpty)
    }

    @Test("more than five new submissions in one pass is a bulk sync artifact and is silently skipped")
    func bulkArrivalIsSkipped() {
        let items = (1...6).map { canvasItem(id: "\($0)", title: "Item \($0)") }
        let newIDs = Set(items.compactMap(\.canvasAssignmentID))
        #expect(newIDs.count == 6)
        let notifications = AppState.submissionNotifications(
            newIDs: newIDs,
            previous: ["already-here"],
            items: items
        )
        #expect(notifications.isEmpty)
    }

    @Test("exactly five new submissions in one pass still announces all of them")
    func exactlyFiveIsStillAnnounced() {
        let items = (1...5).map { canvasItem(id: "\($0)", title: "Item \($0)") }
        let newIDs = Set(items.compactMap(\.canvasAssignmentID))
        #expect(newIDs.count == 5)
        let notifications = AppState.submissionNotifications(
            newIDs: newIDs,
            previous: ["already-here"],
            items: items
        )
        #expect(notifications.count == 5)
    }

    @Test("an id already present before this pass is never re-announced")
    func alreadySeenIDIsNotReAnnounced() {
        let items = [canvasItem(id: "501", title: "Problem Set 4")]
        // "501" was already submitted before this refresh, so it must not be
        // in newIDs at all — mirroring how updateSubmissionState computes
        // `newlySubmitted` as a subtraction, not a re-check of `previous`.
        let notifications = AppState.submissionNotifications(
            newIDs: [],
            previous: ["501"],
            items: items
        )
        #expect(notifications.isEmpty)
    }
}
