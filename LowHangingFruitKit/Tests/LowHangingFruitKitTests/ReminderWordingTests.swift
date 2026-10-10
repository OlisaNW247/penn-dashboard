import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// A due-date reminder used to say only the class and how long was left
/// ("PHYS 0151 / Due in 1 hour"). With two things due in one class the same
/// evening that is two identical notifications, so the body now leads with
/// the assignment's name. These pin the wording rule, which is a pure string
/// function (`NotificationScheduler.reminderBody`).
@Suite("Reminder wording")
struct ReminderWordingTests {
    @Test("The body is the assignment's name, then the lead phrase")
    func nameThenLeadPhrase() {
        #expect(
            NotificationScheduler.reminderBody(assignmentTitle: "Problem Set 4", headline: "Due in 1 hour")
                == "Problem Set 4. Due in 1 hour"
        )
    }

    @Test("Every offered lead time keeps its own phrase after the name")
    func everyLeadTime() {
        for offset in LeadOffset.offered {
            let body = NotificationScheduler.reminderBody(assignmentTitle: "Lab 3", headline: offset.headline)
            #expect(body == "Lab 3. \(offset.headline)")
        }
    }

    @Test("A name that already ends in punctuation is not given a second full stop",
          arguments: ["Read ch. 3.", "Ready for the quiz?", "Submit now!", "Part 1:"])
    func noDoubledPunctuation(title: String) {
        let body = NotificationScheduler.reminderBody(assignmentTitle: title, headline: "Due in 3 hours")
        #expect(body == "\(title) Due in 3 hours")
        #expect(!body.contains(".."))
    }

    @Test("Surrounding whitespace in a name is dropped")
    func trimsWhitespace() {
        #expect(
            NotificationScheduler.reminderBody(assignmentTitle: "  Essay draft \n", headline: "Due in 2 days")
                == "Essay draft. Due in 2 days"
        )
    }

    @Test("A blank name leaves the lead phrase alone, as every reminder read before")
    func blankName() {
        #expect(NotificationScheduler.reminderBody(assignmentTitle: "", headline: "Due in 1 hour") == "Due in 1 hour")
        #expect(NotificationScheduler.reminderBody(assignmentTitle: "   ", headline: "Due in 1 hour") == "Due in 1 hour")
    }

    @Test("A long name is cut at a word boundary so the lead phrase still shows")
    func longNameIsCut() {
        let title = "Homework 3: Dynamic Programming and Greedy Algorithms (Written Portion, Sections 001 through 004)"
        let body = NotificationScheduler.reminderBody(assignmentTitle: title, headline: "Due in 1 hour")

        #expect(body.hasSuffix("\u{2026} Due in 1 hour"), "ellipsis, one space, lead phrase: \(body)")
        let shown = String(body.dropLast("\u{2026} Due in 1 hour".count))
        #expect(shown.count <= NotificationScheduler.reminderTitleLimit)
        #expect(title.hasPrefix(shown))
        // Cut between words: the next character of the original is a space.
        let next = title[title.index(title.startIndex, offsetBy: shown.count)]
        #expect(next == " ")
    }

    @Test("A name exactly at the limit is shown whole")
    func nameAtTheLimit() {
        let title = String(repeating: "a", count: NotificationScheduler.reminderTitleLimit)
        #expect(
            NotificationScheduler.reminderBody(assignmentTitle: title, headline: "Due in 1 hour")
                == "\(title). Due in 1 hour"
        )
    }

    @Test("One unbroken run longer than the limit is cut at the limit, not dropped")
    func unbrokenRun() {
        let title = String(repeating: "x", count: NotificationScheduler.reminderTitleLimit + 20)
        let body = NotificationScheduler.reminderBody(assignmentTitle: title, headline: "Due in 1 hour")
        #expect(body == String(repeating: "x", count: NotificationScheduler.reminderTitleLimit) + "\u{2026} Due in 1 hour")
    }
}
