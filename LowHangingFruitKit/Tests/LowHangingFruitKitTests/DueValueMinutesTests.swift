import Foundation
import Testing
@testable import LowHangingFruitUI

/// The card's date column and the spoken/menu-bar due text, inside the last
/// hour. Both used to say "1h" for anything under an hour, so an item due in
/// 8 minutes looked like it had an hour left.
///
/// Only the minute/hour boundary is under test here; everything from an hour
/// up must read exactly as it always did (the "unchanged" tests pin that).
/// The day and weekday forms depend on the calendar and are not touched.
@Suite("Due value inside the last hour")
struct DueValueMinutesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ secondsFromNow: TimeInterval) -> (String, String?) {
        let value = smoothDueValue(now.addingTimeInterval(secondsFromNow), now: now)
        return (value.primary, value.secondary)
    }

    // MARK: Card, upcoming

    @Test("30 seconds left reads 1m, never 0m")
    func thirtySeconds() {
        #expect(card(30).0 == "1m")
        #expect(card(30).1 == nil)
    }

    @Test("due right now reads 1m")
    func dueNow() {
        #expect(card(0).0 == "1m")
    }

    @Test("8 minutes left reads 8m")
    func eightMinutes() {
        #expect(card(8 * 60).0 == "8m")
        #expect(card(8 * 60 + 59).0 == "8m", "partial minutes round down")
    }

    @Test("59 minutes left reads 59m, even at 59:59")
    func fiftyNineMinutes() {
        #expect(card(59 * 60).0 == "59m")
        #expect(card(59 * 60 + 59).0 == "59m")
    }

    @Test("an hour or more reads exactly as it did")
    func atAndAboveAnHour() {
        #expect(card(60 * 60).0 == "1h")
        #expect(card(60 * 60 + 59).0 == "1h")
        #expect(card(5 * 3_600).0 == "5h")
        #expect(card(23 * 3_600 + 59 * 60).0 == "23h")
        #expect(card(5 * 3_600).1 == nil)
    }

    // MARK: Card, late

    @Test("30 seconds late reads 1m late, never 0m")
    func thirtySecondsLate() {
        #expect(card(-30).0 == "1m")
        #expect(card(-30).1 == "late")
    }

    @Test("8 minutes late reads 8m late")
    func eightMinutesLate() {
        #expect(card(-8 * 60).0 == "8m")
        #expect(card(-8 * 60).1 == "late")
    }

    @Test("59 minutes late reads 59m late")
    func fiftyNineMinutesLate() {
        #expect(card(-59 * 60).0 == "59m")
        #expect(card(-(59 * 60 + 59)).0 == "59m")
        #expect(card(-59 * 60).1 == "late")
    }

    @Test("an hour or more late reads exactly as it did")
    func atAndAboveAnHourLate() {
        #expect(card(-60 * 60).0 == "1h")
        #expect(card(-60 * 60).1 == "late")
        #expect(card(-3 * 3_600).0 == "3h")
        #expect(card(-23 * 3_600).0 == "23h")
        #expect(card(-23 * 3_600).1 == "late")
    }

    // MARK: Spoken / menu-bar text

    @Test("dueText counts minutes inside the last hour and hours from 60 minutes")
    func dueTextBoundary() {
        func text(_ seconds: TimeInterval) -> String {
            dueText(now.addingTimeInterval(seconds), now: now)
        }
        #expect(text(30) == "1m left")
        #expect(text(8 * 60) == "8m left")
        #expect(text(59 * 60) == "59m left")
        #expect(text(60 * 60) == "1h left")
        #expect(text(5 * 3_600) == "5h left")

        #expect(text(-30) == "1m late")
        #expect(text(-8 * 60) == "8m late")
        #expect(text(-59 * 60) == "59m late")
        #expect(text(-60 * 60) == "1h late")
        #expect(text(-3 * 3_600) == "3h late")
        #expect(dueText(nil, now: now) == "no due date")
    }

    @Test("the spoken label says it is the due time, and keeps the adjusted mark")
    func accessibilityLabel() {
        let soon = now.addingTimeInterval(8 * 60)
        #expect(dueAccessibilityLabel(soon, now: now) == "due, 8m left")
        #expect(dueAccessibilityLabel(now.addingTimeInterval(5 * 3_600), now: now) == "due, 5h left")
        #expect(dueAccessibilityLabel(now.addingTimeInterval(-3 * 3_600), now: now) == "due, 3h late")
        #expect(dueAccessibilityLabel(soon, adjusted: true, now: now) == "due, 8m left, adjusted")
        #expect(dueAccessibilityLabel(nil, now: now) == "no due date")
    }
}
