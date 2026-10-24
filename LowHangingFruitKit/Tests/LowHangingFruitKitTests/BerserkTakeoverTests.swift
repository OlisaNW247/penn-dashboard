import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The Berserk takeover screen: the pure rules that decide which alarm or buzz
/// gets the screen and what each choice does, the model that holds the
/// waiting signals, the delegate's parsing, and source scans of the wiring.
///
/// What these cannot show: that the screen really covers the window on a phone,
/// that AlarmKit's update stream delivers what `alertingUpdates` expects, and
/// that a buzz tapped on a cold launch reaches the model before the view
/// exists. The scans pin that the calls are there, not that they work. Nothing
/// here touches `AlarmManager`, the notification center, or `UserDefaults.lhf`.
private enum TakeoverFixtures {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static let canvasPage = "https://canvas.upenn.edu/courses/1/assignments/77"
    static let gradescopePage = "https://www.gradescope.com/courses/123/assignments/456"

    static func item(
        _ sourceID: String,
        source: Assignment.Source = .canvas,
        course: String = "CIS 1200",
        title: String? = nil,
        due: Date?,
        url: String? = nil,
        completed: Bool = false
    ) -> DashItem {
        DashItem(
            assignment: Assignment(source: source, sourceID: sourceID, kind: .assignment,
                                   course: course, title: title ?? "HW \(sourceID)", dueAt: due,
                                   url: url.flatMap(URL.init(string:))),
            dueOverride: nil, isCompleted: completed, completedAt: nil)
    }

    static func entry(_ signal: BerserkTakeoverSignal, _ arrivedAt: Date) -> PendingBerserkSignal {
        PendingBerserkSignal(signal: signal, arrivedAt: arrivedAt)
    }

    static func isDeposit(_ effect: BerserkTakeoverEffect) -> Bool {
        if case .deposit = effect { return true }
        return false
    }

    static func isStop(_ effect: BerserkTakeoverEffect) -> Bool {
        if case .stopAlarm = effect { return true }
        return false
    }

    /// The alarm id the plan would give `item`.
    static func alarmID(_ item: DashItem) -> UUID {
        BerserkAlarmPlan.alarmID(
            assignmentID: item.assignment.id,
            fireDate: (item.due ?? base).addingTimeInterval(-NotificationScheduler.loudAlertLead))
    }

    static func resolve(
        _ pending: [PendingBerserkSignal],
        items: [DashItem],
        alerting: Set<UUID> = [],
        now: Date = base,
        fixture: Bool = false
    ) -> BerserkTakeoverRules.Resolution {
        BerserkTakeoverRules.resolve(
            pending: pending, items: items, alerting: alerting, now: now,
            isUsingFixtureData: fixture, nameOverrides: [:])
    }

    static func takeover(
        id: String = "canvas:hw",
        link: PlannedAlarm.Link? = nil,
        source: BerserkTakeover.Source = .buzz
    ) -> BerserkTakeover {
        BerserkTakeover(assignmentID: id, course: "CIS 1200", title: "HW", due: base + 600,
                        link: link, source: source)
    }
}

@Suite("Berserk takeover: which signal gets the screen")
struct BerserkTakeoverResolveTests {
    private typealias F = TakeoverFixtures

    @Test("An alarm's id resolves to the item whose plan produced it, for every item")
    func alarmIdsMatchThePlan() {
        let now = F.base
        let items = [
            F.item("a", due: now + 3600),
            F.item("b", due: now + 7200),
            F.item("c", source: .gradescope, due: now + 9000, url: F.gradescopePage),
        ]
        let planned = BerserkAlarmPlan.alarms(for: items, now: now, nameOverrides: [:])
        let index = BerserkTakeoverRules.alarmIndex(items: items)
        #expect(planned.count == 3)
        // A superset since the Sweeper settings: the index holds every timing
        // and sound an alarm could have been scheduled with (2026-10-24).
        #expect(Set(planned.map(\.id)).isSubset(of: Set(index.keys)))
        for alarm in planned {
            #expect(index[alarm.id]?.assignment.id == alarm.assignmentID)
        }
    }

    @Test("A Sweeper alarm with a non-default timing and sound still resolves to its item",
          arguments: [(20, SweeperSound.chime), (5, .pulse), (60, .system), (30, .smooth)])
    func nonDefaultSweeperAlarmsResolve(minutes: Int, sound: SweeperSound) {
        let now = F.base
        let items = [F.item("a", due: now + 3 * 3600), F.item("b", due: now + 4 * 3600)]
        let planned = BerserkAlarmPlan.alarms(
            for: items, now: now, nameOverrides: [:],
            lead: TimeInterval(minutes * 60), sound: sound)
        #expect(planned.count == 2)
        let index = BerserkTakeoverRules.alarmIndex(items: items)
        for alarm in planned {
            #expect(index[alarm.id]?.assignment.id == alarm.assignmentID)
        }
    }

    @Test("An item with no due date has no alarm id")
    func undatedHasNoAlarm() {
        #expect(BerserkTakeoverRules.alarmIndex(items: [F.item("x", due: nil)]).isEmpty)
    }

    @Test("A buzz resolves by the assignment id it carries")
    func buzzResolves() {
        let hw = F.item("hw", due: F.base + 600, url: F.canvasPage)
        let result = F.resolve([F.entry(.buzz("canvas:hw"), F.base)], items: [hw])
        #expect(result.current?.assignmentID == "canvas:hw")
        #expect(result.current?.source == .buzz)
        #expect(result.current?.link?.kind == .canvas)
        #expect(result.waiting.isEmpty)
    }

    @Test("A ringing alarm resolves to its item and carries the alarm id to stop")
    func alarmResolves() {
        let hw = F.item("hw", due: F.base + 600)
        let id = F.alarmID(hw)
        let result = F.resolve([F.entry(.alarm(id), F.base)], items: [hw], alerting: [id])
        #expect(result.current?.source == .alarm(id))
        #expect(result.current?.due == hw.due)
    }

    @Test("An alarm signal whose alarm is not ringing is dropped")
    func stoppedAlarmDropped() {
        let hw = F.item("hw", due: F.base + 600)
        let id = F.alarmID(hw)
        let result = F.resolve([F.entry(.alarm(id), F.base)], items: [hw], alerting: [])
        #expect(result.current == nil)
        #expect(result.waiting.isEmpty)
    }

    @Test("A ringing alarm that traces to no item is kept waiting, not dropped")
    func unknownAlarmKept() {
        let stray = UUID()
        let entry = PendingBerserkSignal(signal: .alarm(stray), arrivedAt: F.base)
        let result = F.resolve([entry], items: [], alerting: [stray])
        #expect(result.current == nil)
        #expect(result.waiting == [entry])
    }

    @Test("A buzz is kept 120 seconds and gone after; one whose item is unknown waits until then")
    func buzzLifetimeIsTwoMinutes() {
        #expect(BerserkTakeoverRules.buzzLifetime == 120)
        let hw = F.item("hw", due: F.base + 600)
        let entry = PendingBerserkSignal(signal: .buzz("canvas:hw"), arrivedAt: F.base)

        #expect(F.resolve([entry], items: [hw], now: F.base + 119).current != nil)
        #expect(F.resolve([entry], items: [hw], now: F.base + 120).current != nil)
        let late = F.resolve([entry], items: [hw], now: F.base + 121)
        #expect(late.current == nil)
        #expect(late.waiting.isEmpty)

        let unknown = F.resolve([entry], items: [], now: F.base + 119)
        #expect(unknown.current == nil)
        #expect(unknown.waiting == [entry])
        #expect(F.resolve([entry], items: [], now: F.base + 121).waiting.isEmpty)
    }

    @Test("A signal whose item is finished is dropped, alarm or buzz")
    func completedDropped() {
        let done = F.item("hw", due: F.base + 600, completed: true)
        let id = F.alarmID(done)
        let result = F.resolve(
            [F.entry(.alarm(id), F.base), F.entry(.buzz("canvas:hw"), F.base)],
            items: [done], alerting: [id])
        #expect(result.current == nil)
        #expect(result.waiting.isEmpty)
    }

    @Test("Fixture data (preview and demo) never takes over, whatever is ringing")
    func fixtureDataYieldsNothing() {
        let hw = F.item("hw", due: F.base + 600)
        let id = F.alarmID(hw)
        let result = F.resolve(
            [F.entry(.alarm(id), F.base), F.entry(.buzz("canvas:hw"), F.base)],
            items: [hw], alerting: [id], fixture: true)
        #expect(result == BerserkTakeoverRules.Resolution(current: nil, waiting: []))
    }

    @Test("An alarm and a buzz for one item collapse to the alarm; identical signals collapse to one")
    func duplicatesCollapse() {
        let hw = F.item("hw", due: F.base + 600)
        let id = F.alarmID(hw)
        let buzz = PendingBerserkSignal(signal: .buzz("canvas:hw"), arrivedAt: F.base)
        let alarm = PendingBerserkSignal(signal: .alarm(id), arrivedAt: F.base + 1)

        let both = F.resolve([buzz, alarm], items: [hw], alerting: [id])
        #expect(both.current?.source == .alarm(id))
        #expect(both.waiting.isEmpty)

        let reversed = F.resolve([alarm, buzz], items: [hw], alerting: [id])
        #expect(reversed.current?.source == .alarm(id))
        #expect(reversed.waiting.isEmpty)

        let twice = F.resolve([buzz, buzz], items: [hw])
        #expect(twice.current?.assignmentID == "canvas:hw")
        #expect(twice.waiting.isEmpty)

        let strayID = UUID()
        let stray = F.entry(.alarm(strayID), F.base)
        let strays = F.resolve([stray, stray], items: [], alerting: [strayID])
        #expect(strays.current == nil)
        #expect(strays.waiting == [stray])
    }

    @Test("The soonest due is shown; the others wait in arrival order; an undated one is last")
    func soonestFirstRestInArrivalOrder() {
        let a = F.item("a", due: F.base + 3600)
        let b = F.item("b", due: F.base + 7200)
        let c = F.item("c", due: F.base + 10_800)
        let undated = F.item("u", due: nil)
        let c1 = PendingBerserkSignal(signal: .buzz("canvas:c"), arrivedAt: F.base)
        let u1 = PendingBerserkSignal(signal: .buzz("canvas:u"), arrivedAt: F.base + 1)
        let a1 = PendingBerserkSignal(signal: .buzz("canvas:a"), arrivedAt: F.base + 2)
        let b1 = PendingBerserkSignal(signal: .buzz("canvas:b"), arrivedAt: F.base + 3)

        let result = F.resolve([c1, u1, a1, b1], items: [a, b, c, undated], now: F.base + 4)
        #expect(result.current?.assignmentID == "canvas:a")
        #expect(result.waiting == [c1, u1, b1])

        let onlyUndated = F.resolve([u1], items: [undated], now: F.base + 4)
        #expect(onlyUndated.current?.assignmentID == "canvas:u")
        #expect(onlyUndated.current?.due == nil)
    }

    @Test("Two items due at the same moment are told apart by assignment id")
    func tieBreak() {
        let due = F.base + 3600
        let x = F.item("x", due: due)
        let y = F.item("y", due: due)
        let pending: [PendingBerserkSignal] = [
            F.entry(.buzz("canvas:y"), F.base),
            F.entry(.buzz("canvas:x"), F.base),
        ]
        #expect(F.resolve(pending, items: [x, y]).current?.assignmentID == "canvas:x")
        #expect(F.resolve(pending, items: [y, x]).current?.assignmentID == "canvas:x")
    }

    @Test("The takeover reads like the alarm: trimmed title, class when blank, rename, the right page")
    func takeoverContent() {
        let canvas = F.item("cv", course: "CIS 1200", title: "  Problem Set 4  ", due: F.base + 600, url: F.canvasPage)
        let gradescope = F.item("gs", source: .gradescope, title: "Quiz", due: F.base + 600, url: F.gradescopePage)
        let manual = F.item("mine", source: .manual, title: "   ", due: F.base + 600)

        let c = BerserkTakeoverRules.takeover(for: canvas, source: .buzz, nameOverrides: [:])
        #expect(c.title == "Problem Set 4")
        #expect(c.link?.kind == .canvas)
        #expect(c.link?.url.absoluteString == F.canvasPage)
        #expect(c.assignmentID == "canvas:cv")

        let g = BerserkTakeoverRules.takeover(for: gradescope, source: .buzz, nameOverrides: [:])
        #expect(g.link?.kind == .gradescope)

        let m = BerserkTakeoverRules.takeover(for: manual, source: .buzz, nameOverrides: ["CIS 1200": "Programming"])
        #expect(m.link == nil)
        #expect(m.title == m.course)
        #expect(m.course == manual.assignment.displayCourse(overrides: ["CIS 1200": "Programming"]))

        // And the link is the one the alarm plan would give the same item.
        let planned = BerserkAlarmPlan.alarms(for: [canvas], now: F.base - 60, nameOverrides: [:])
        #expect(planned.first?.link == c.link)
        #expect(planned.first?.title == c.title)
    }
}

@Suite("Berserk takeover: what a choice does")
struct BerserkTakeoverEffectTests {
    private typealias F = TakeoverFixtures
    private static let page = URL(string: F.canvasPage)!
    private static let link = PlannedAlarm.Link(kind: .canvas, url: page)

    private static func takeovers() -> [(name: String, takeover: BerserkTakeover)] {
        let alarmID = UUID()
        return [
            ("alarm + link", F.takeover(link: link, source: .alarm(alarmID))),
            ("alarm, no link", F.takeover(link: nil, source: .alarm(alarmID))),
            ("buzz + link", F.takeover(link: link, source: .buzz)),
            ("buzz, no link", F.takeover(link: nil, source: .buzz)),
        ]
    }

    @Test("\"turned in\" is the only choice that deposits a \"turned in\"")
    func onlyTurnedInDeposits() {
        for (name, takeover) in Self.takeovers() {
            let deposit = BerserkTakeoverEffect.deposit(.turnedIn(takeover.assignmentID))
            #expect(BerserkTakeoverRules.effects(for: .turnedIn, takeover: takeover).contains(deposit), "\(name)")
            for choice in [BerserkTakeoverChoice.open, .notYet] {
                let effects = BerserkTakeoverRules.effects(for: choice, takeover: takeover)
                #expect(!effects.contains(deposit), "\(name) \(choice)")
                #expect(!effects.contains(where: F.isDeposit), "\(name) \(choice) deposits nothing")
            }
        }
    }

    @Test("\"open\" with a page opens that page and silences nothing else; without one it is \"not yet\"")
    func openChoice() {
        let withLink = F.takeover(link: Self.link, source: .buzz)
        #expect(BerserkTakeoverRules.effects(for: .open, takeover: withLink)
                == [.openURL(Self.page), .dismiss])

        let without = F.takeover(link: nil, source: .buzz)
        #expect(BerserkTakeoverRules.effects(for: .open, takeover: without)
                == BerserkTakeoverRules.effects(for: .notYet, takeover: without))
        let alarmWithout = F.takeover(link: nil, source: .alarm(UUID()))
        #expect(BerserkTakeoverRules.effects(for: .open, takeover: alarmWithout)
                == BerserkTakeoverRules.effects(for: .notYet, takeover: alarmWithout))
    }

    @Test("The alarm is stopped only for an alarm-sourced takeover, and only that alarm")
    func stopOnlyForAlarms() {
        let id = UUID()
        for choice in [BerserkTakeoverChoice.turnedIn, .open, .notYet] {
            let fromAlarm = BerserkTakeoverRules.effects(
                for: choice, takeover: F.takeover(link: Self.link, source: .alarm(id)))
            #expect(fromAlarm.first == .stopAlarm(id), "\(choice)")

            let fromBuzz = BerserkTakeoverRules.effects(
                for: choice, takeover: F.takeover(link: Self.link, source: .buzz))
            #expect(!fromBuzz.contains(where: F.isStop), "\(choice)")
        }
    }

    @Test("Every choice ends with dismiss, and \"not yet\" completes nothing")
    func everyChoiceDismisses() {
        for (name, takeover) in Self.takeovers() {
            for choice in [BerserkTakeoverChoice.turnedIn, .open, .notYet] {
                #expect(BerserkTakeoverRules.effects(for: choice, takeover: takeover).last == .dismiss,
                        "\(name) \(choice)")
            }
            #expect(BerserkTakeoverRules.effects(for: .notYet, takeover: takeover).contains(
                .silenceBuzzes(takeover.assignmentID)), "\(name)")
        }
    }
}

@Suite("Berserk takeover: when the screen goes on its own")
struct BerserkTakeoverDismissTests {
    private typealias F = TakeoverFixtures

    @Test("shouldDismiss: a silent alarm or a finished item ends it; a buzz otherwise stays")
    func table() {
        let id = UUID()
        let open = F.item("hw", due: F.base + 600)
        let done = F.item("hw", due: F.base + 600, completed: true)
        let alarm = F.takeover(source: .alarm(id))
        let buzz = F.takeover(source: .buzz)

        #expect(!BerserkTakeoverRules.shouldDismiss(alarm, alerting: [id], items: [open]))
        #expect(BerserkTakeoverRules.shouldDismiss(alarm, alerting: [], items: [open]))
        #expect(BerserkTakeoverRules.shouldDismiss(alarm, alerting: [id], items: [done]))
        #expect(!BerserkTakeoverRules.shouldDismiss(buzz, alerting: [], items: [open]))
        #expect(!BerserkTakeoverRules.shouldDismiss(buzz, alerting: [], items: []),
                "an item not on the list yet is not a finished one")
        #expect(BerserkTakeoverRules.shouldDismiss(buzz, alerting: [], items: [done]))
    }

    @Test("The countdown label: due now at or past the time, minutes, then hours")
    func countdownLabel() {
        let now = F.base
        #expect(BerserkTakeoverRules.countdownLabel(due: nil, now: now) == "due now")
        #expect(BerserkTakeoverRules.countdownLabel(due: now, now: now) == "due now")
        #expect(BerserkTakeoverRules.countdownLabel(due: now - 5, now: now) == "due now")
        #expect(BerserkTakeoverRules.countdownLabel(due: now + 1, now: now) == "due in 1 min")
        #expect(BerserkTakeoverRules.countdownLabel(due: now + 9 * 60, now: now) == "due in 9 min")
        #expect(BerserkTakeoverRules.countdownLabel(due: now + 9 * 60 - 1, now: now) == "due in 9 min")
        #expect(BerserkTakeoverRules.countdownLabel(due: now + 3600, now: now) == "due in 1 h")
        #expect(BerserkTakeoverRules.countdownLabel(due: now + 3600 + 300, now: now) == "due in 1 h 5 min")
    }
}

@Suite("Berserk takeover: reading a loud buzz")
struct BerserkSignalParsingTests {
    @Test("The three loud categories yield the item id")
    func loudCategories() {
        for category in [LoudAlertActions.canvasCategoryID,
                         LoudAlertActions.gradescopeCategoryID,
                         LoudAlertActions.turnedInOnlyCategoryID] {
            #expect(LoudAlertActions.berserkSignalAssignmentID(
                categoryID: category,
                userInfo: [LoudAlertActions.assignmentIDKey: "canvas:hw"]) == "canvas:hw", "\(category)")
        }
    }

    @Test("An empty or missing id, a non-string id, or a foreign category yields nil")
    func rejected() {
        let canvas = LoudAlertActions.canvasCategoryID
        #expect(LoudAlertActions.berserkSignalAssignmentID(
            categoryID: canvas, userInfo: [LoudAlertActions.assignmentIDKey: ""]) == nil)
        #expect(LoudAlertActions.berserkSignalAssignmentID(categoryID: canvas, userInfo: [:]) == nil)
        #expect(LoudAlertActions.berserkSignalAssignmentID(
            categoryID: canvas, userInfo: [LoudAlertActions.assignmentIDKey: 7]) == nil)
        #expect(LoudAlertActions.berserkSignalAssignmentID(
            categoryID: "", userInfo: [LoudAlertActions.assignmentIDKey: "canvas:hw"]) == nil)
        #expect(LoudAlertActions.berserkSignalAssignmentID(
            categoryID: "reminder", userInfo: [LoudAlertActions.assignmentIDKey: "canvas:hw"]) == nil)
    }

    @Test("The default tap is still not a button action")
    func defaultTapIsNotAnAction() {
        #expect(LoudAlertActions.action(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [LoudAlertActions.assignmentIDKey: "canvas:hw",
                       LoudAlertActions.linkURLKey: "https://canvas.upenn.edu/x"]) == nil)
    }
}

@MainActor
@Suite("Berserk takeover: the model")
struct BerserkTakeoverModelTests {
    private typealias F = TakeoverFixtures

    @Test("note appends once: an identical pending signal is not added twice")
    func noteDeduplicates() {
        let model = BerserkTakeoverModel()
        model.note(.buzz("canvas:hw"), at: F.base)
        model.note(.buzz("canvas:hw"), at: F.base + 5)
        model.noteAlerting([], at: F.base)
        #expect(model.pending == [F.entry(.buzz("canvas:hw"), F.base)])

        let id = UUID()
        model.noteAlerting([id, id], at: F.base)
        #expect(model.pending.count == 2)
    }

    @Test("note ignores what is already on screen")
    func noteIgnoresTheShownOne() {
        let model = BerserkTakeoverModel()
        let id = UUID()
        model.apply(BerserkTakeoverRules.Resolution(current: F.takeover(source: .alarm(id)), waiting: []))
        model.note(.alarm(id), at: F.base)
        model.note(.buzz("canvas:hw"), at: F.base)
        #expect(model.pending.isEmpty)
    }

    @Test("apply shows the resolved takeover when none is showing")
    func applyShows() {
        let model = BerserkTakeoverModel()
        let waiting = PendingBerserkSignal(signal: .buzz("canvas:other"), arrivedAt: F.base)
        model.apply(BerserkTakeoverRules.Resolution(current: F.takeover(), waiting: [waiting]))
        #expect(model.current == F.takeover())
        #expect(model.pending == [waiting])
    }

    @Test("apply never replaces a takeover that is on screen, and keeps the candidate it would have shown")
    func applyDoesNotReplace() {
        let model = BerserkTakeoverModel()
        let shown = F.takeover(id: "canvas:shown")
        model.apply(BerserkTakeoverRules.Resolution(current: shown, waiting: []))

        model.note(.buzz("canvas:next"), at: F.base)
        let next = F.takeover(id: "canvas:next")
        model.apply(BerserkTakeoverRules.Resolution(current: next, waiting: []))

        #expect(model.current == shown)
        #expect(model.pending == [F.entry(.buzz("canvas:next"), F.base)],
                "the signal that would have been shown is still waiting")
    }

    @Test("dismiss clears the screen, and a buzz for the same item a moment later does not bring it back")
    func dismissClears() {
        let model = BerserkTakeoverModel()
        model.apply(BerserkTakeoverRules.Resolution(current: F.takeover(), waiting: []))
        model.dismiss(at: F.base)
        #expect(model.current == nil)

        model.note(.buzz("canvas:hw"), at: F.base + 3)
        #expect(model.pending.isEmpty, "the second of the three buzzes")
        model.note(.buzz("canvas:hw"), at: F.base + 121)
        #expect(model.pending.count == 1, "but a later one is a new alert")
    }

    @Test("A dismissed alarm is not noted again")
    func dismissedAlarmStaysAway() {
        let model = BerserkTakeoverModel()
        let id = UUID()
        model.apply(BerserkTakeoverRules.Resolution(current: F.takeover(source: .alarm(id)), waiting: []))
        model.dismiss(at: F.base)
        model.noteAlerting([id], at: F.base + 1)
        #expect(model.pending.isEmpty)
    }
}

@Suite("Berserk takeover: where it is wired (source structure)")
struct BerserkTakeoverWiringTests {
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)     // .../Tests/LowHangingFruitKitTests/<this>
            .deletingLastPathComponent()    // .../Tests/LowHangingFruitKitTests
            .deletingLastPathComponent()    // .../Tests
            .deletingLastPathComponent()    // .../LowHangingFruitKit
    }

    private func uiSource(_ filename: String) throws -> String {
        let url = packageRoot().appendingPathComponent("Sources/LowHangingFruitUI/\(filename)")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.path) is not there, so nothing could be checked")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("RootView puts the takeover host on the main content")
    func rootViewHostsTheTakeover() throws {
        #expect(try uiSource("RootView.swift").contains(".berserkTakeoverHost("))
    }

    @Test("Both delegate callbacks tell the takeover about a loud buzz")
    func delegateNotesBuzzes() throws {
        let source = try uiSource("NotificationResponseRouter.swift")
        let calls = source.components(separatedBy: "LoudAlertActions.berserkSignalAssignmentID(").count - 1
        #expect(calls >= 2)
        #expect(source.contains("UNNotificationDefaultActionIdentifier"))
        // The default-tap branch comes before the button parsing.
        let defaultTap = try #require(source.range(of: "response.actionIdentifier == UNNotificationDefaultActionIdentifier"))
        let buttons = try #require(source.range(of: "guard let action = LoudAlertActions.action("))
        #expect(defaultTap.lowerBound < buttons.lowerBound)
    }

    @Test("The scheduler counts the item lists the dashboard hands it")
    func schedulerCountsReschedules() throws {
        #expect(try uiSource("NotificationScheduler.swift").contains("rescheduleGeneration += 1"))
    }

    @Test("The AlarmKit half reads the alarm updates, inside the iOS 26 conditional")
    func alertingExtension() throws {
        let source = try uiSource("BerserkAlarmScheduler+Alerting.swift")
        #expect(source.contains("alarmUpdates"))
        #expect(source.hasPrefix("#if canImport(AlarmKit) && os(iOS)"))
        #expect(source.contains("@available(iOS 26.0, *)"))
        #expect(source.contains("#endif"))
    }
}
