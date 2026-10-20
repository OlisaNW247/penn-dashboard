import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Berserk mode: on iOS 26, with alarms allowed, the loud 10-minute alert is
/// one AlarmKit alarm per item instead of three buzzes.
///
/// Everything here is the pure half: the plan, the ids, the reconcile diff, the
/// delivery table, the planner's `loudAlertsAsAlarms` switch, the buttons, the
/// receive entry the App target's intents call, and the source-structure scans
/// of the App target (which `swift test` does not compile). The behaviour of a
/// reschedule against a fake AlarmKit and a fake notification center is in
/// `BerserkAlarmDeliveryTests`. Like the other loud-alert suites it runs on its
/// own `UserDefaults` suite and never touches `UNUserNotificationCenter.current()`
/// (it traps in an unbundled test binary), `AlarmManager`, the Keychain or
/// `UserDefaults.lhf`.
///
/// **What these cannot show.** That AlarmKit really rings through silent mode
/// and Focus, that the system accepts the intents the App target defines, that
/// the permission prompt appears, and that a stop or "turned in" press reaches
/// the dashboard are things only an iOS 26 device proves. The source-structure
/// tests pin that the calls are *there* (the App target is not compiled by
/// `swift test`), not that they work.
@MainActor
@Suite("Berserk alarm")
struct BerserkAlarmTests {

    private static let lead = NotificationScheduler.loudAlertLead
    private static let canvasPage = "https://canvas.upenn.edu/courses/1/assignments/77"
    private static let gradescopePage = "https://www.gradescope.com/courses/123/assignments/456"

    // MARK: The plan follows the buzzes' selection

    /// The mixed fixture the buzzes' own tests use to define "qualifies", plus
    /// eleven that do, so the cap bites. The alarm plan must name exactly the
    /// items the buzzes name, in the same nearest-first order.
    @Test("The alarm plan names exactly the items the buzzes name: the same exclusions and the same cap of 10")
    func planMatchesTheBuzzSelection() {
        withScheduler { scheduler, prefs, now in
            prefs.setNotificationsEnabled("MUTED 100", false)
            let taskID = UUID()
            var items: [DashItem] = (0..<11).map {
                item("CIS 1200", "q\($0)", due: now + 5 * 86_400 + Double($0) * 3600)
            }
            items += [
                item("CIS 1200", "done", due: now + 6 * 3600, completed: true),
                item("CIS 1200", "nosubmit", due: now + 6 * 3600, requiresNoSubmission: true),
                item("CIS 1200", "reading", due: now + 6 * 3600, kind: .event),
                occurrence("CIS 1200", taskID: taskID, due: now + 6 * 3600),
                foundExam("CIS 1200", due: now + 6 * 3600),
                item("MUTED 100", "muted", due: now + 6 * 3600),
                item("CIS 1200", "undated", due: nil),
            ]
            #expect(items.contains { $0.isFoundExam }, "the fixture's exam must really be a found exam")

            let buzzes = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            let buzzItems = loudItemIDsInOrder(buzzes)
            let alarms = scheduler.plannedAlarms(from: items, now: now, preferences: prefs)

            #expect(buzzItems.count == NotificationScheduler.maxLoudItems)
            #expect(alarms.map(\.assignmentID) == buzzItems)
            #expect(!alarms.map(\.assignmentID).contains("canvas:q10"), "the 11th nearest is past the cap")
        }
    }

    @Test("An alarm rings at due minus 10 minutes, honouring a due-date override")
    func fireDate() {
        withScheduler { scheduler, prefs, now in
            let due = now + 3 * 3600
            let overridden = now + 9 * 3600
            let items = [
                item("CIS 1200", "plain", due: due),
                item("CIS 1200", "moved", due: now - 86_400, override: overridden),
            ]
            let alarms = scheduler.plannedAlarms(from: items, now: now, preferences: prefs)
            #expect(Dictionary(uniqueKeysWithValues: alarms.map { ($0.assignmentID, $0.fireDate) })
                    == ["canvas:plain": due - Self.lead, "canvas:moved": overridden - Self.lead])
        }
    }

    /// `loudAlerts` keeps an item for up to 6 seconds past its first buzz,
    /// because the second and third are still ahead. An alarm has only one
    /// time: past it, there is nothing to schedule. The item must still get no
    /// plain 10-minute reminder, as with the buzzes.
    @Test("An alarm time already past plans nothing, and the item still gets no plain 10-minute reminder")
    func pastAlarmTimeIsSkipped() {
        withScheduler(leadTimes: [.m10]) { scheduler, prefs, now in
            let due = now + 2 * 3600
            let justAfterTheAlarmTime = due - Self.lead + 1
            let items = [item("CIS 1200", "hw", due: due)]

            #expect(scheduler.plannedAlarms(from: items, now: justAfterTheAlarmTime, preferences: prefs).isEmpty)
            #expect(scheduler.plannedAlarms(from: items, now: due - Self.lead - 1, preferences: prefs).count == 1,
                    "one second before, it is still planned")

            let requests = scheduler.plannedRequests(
                from: items, now: justAfterTheAlarmTime, preferences: prefs, loudAlertsAsAlarms: true)
            #expect(requests.isEmpty, "no buzz, and no plain \"10 minutes before\" either")
        }
    }

    @Test("The title is the assignment's name, cut by the reminders' own rule, with no lead phrase")
    func title() {
        withScheduler { scheduler, prefs, now in
            let long = "Homework 3: Dynamic Programming and Greedy Algorithms (Written Portion, Sections 001-004) "
                + "with extra words"
            prefs.setDisplayName("CIS 1200", to: "Programming")
            let items = [
                item("CIS 1200", "short", due: now + 2 * 3600, title: "  Problem Set 4  "),
                item("CIS 1200", "long", due: now + 3 * 3600, title: long),
                item("CIS 1200", "blank", due: now + 4 * 3600, title: "   "),
            ]
            let alarms = scheduler.plannedAlarms(from: items, now: now, preferences: prefs)
            let byID = Dictionary(uniqueKeysWithValues: alarms.map { ($0.assignmentID, $0.title) })

            #expect(byID["canvas:short"] == "Problem Set 4")
            #expect(byID["canvas:long"] == NotificationScheduler.reminderName(long))
            #expect(byID["canvas:long"]?.hasSuffix("\u{2026}") == true)
            #expect((byID["canvas:long"]?.count ?? .max) <= NotificationScheduler.reminderTitleLimit + 1)
            #expect(alarms.allSatisfy { !$0.title.contains("Due in") && !$0.title.contains("10 minutes") })
            // Never untitled: a blank name falls back to the class as the card shows it.
            #expect(byID["canvas:blank"] == "Programming")
        }
    }

    /// `reminderBody` now calls `reminderName`; the notification's wording must
    /// not have moved with it.
    @Test("Factoring out the name rule leaves every reminder body as it was")
    func reminderBodyUnchanged() {
        #expect(NotificationScheduler.reminderBody(assignmentTitle: "Problem Set 4", headline: "Due in 1 hour")
                == "Problem Set 4. Due in 1 hour")
        #expect(NotificationScheduler.reminderBody(assignmentTitle: "Read ch. 3.", headline: "Due in 1 hour")
                == "Read ch. 3. Due in 1 hour")
        #expect(NotificationScheduler.reminderBody(assignmentTitle: "  ", headline: "Due in 1 hour")
                == "Due in 1 hour")
        let long = String(repeating: "word ", count: 40)
        #expect(NotificationScheduler.reminderBody(assignmentTitle: long, headline: "Due in 1 hour")
                == NotificationScheduler.reminderName(long) + " Due in 1 hour")
    }

    @Test("With the loud-alert switch off there are no alarms")
    func switchOff() {
        withScheduler { scheduler, prefs, now in
            scheduler.setLoudAlertEnabled(false)
            #expect(scheduler.plannedAlarms(
                from: [item("CIS 1200", "hw", due: now + 3 * 3600)], now: now, preferences: prefs).isEmpty)
        }
    }

    // MARK: Ids

    private let fire = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("The same assignment and fire date always give the same id")
    func idIsStable() {
        #expect(BerserkAlarmPlan.alarmID(assignmentID: "canvas:hw", fireDate: fire)
                == BerserkAlarmPlan.alarmID(assignmentID: "canvas:hw", fireDate: fire))
        // A fire date that differs only below a millisecond is the same alarm.
        #expect(BerserkAlarmPlan.alarmID(assignmentID: "canvas:hw", fireDate: fire)
                == BerserkAlarmPlan.alarmID(assignmentID: "canvas:hw", fireDate: fire.addingTimeInterval(0.0001)))
    }

    @Test("A moved due date or a different assignment gives a different id")
    func idChanges() {
        let base = BerserkAlarmPlan.alarmID(assignmentID: "canvas:hw", fireDate: fire)
        #expect(base != BerserkAlarmPlan.alarmID(assignmentID: "canvas:hw", fireDate: fire.addingTimeInterval(60)))
        #expect(base != BerserkAlarmPlan.alarmID(assignmentID: "canvas:hw", fireDate: fire.addingTimeInterval(0.5)))
        #expect(base != BerserkAlarmPlan.alarmID(assignmentID: "canvas:hw2", fireDate: fire))
        // The length prefix keeps an id from running into the date.
        #expect(BerserkAlarmPlan.alarmID(assignmentID: "a", fireDate: Date(timeIntervalSince1970: 11))
                != BerserkAlarmPlan.alarmID(assignmentID: "a1", fireDate: Date(timeIntervalSince1970: 1)))
    }

    @Test("The id is a well-formed UUID: version 8 (custom, RFC 9562), variant 10xx")
    func idIsWellFormed() {
        for n in 0..<50 {
            let id = BerserkAlarmPlan.alarmID(assignmentID: "canvas:hw\(n)", fireDate: fire.addingTimeInterval(Double(n)))
            let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
            #expect(bytes.count == 16)
            #expect(bytes[6] >> 4 == 8, "version nibble")
            #expect(bytes[8] >> 6 == 0b10, "variant bits")
            #expect(UUID(uuidString: id.uuidString) == id)
        }
    }

    @Test("A planned alarm's id is the derived one")
    func plannedIDIsDerived() {
        withScheduler { scheduler, prefs, now in
            let due = now + 3 * 3600
            let alarm = scheduler.plannedAlarms(
                from: [item("CIS 1200", "hw", due: due)], now: now, preferences: prefs).first
            #expect(alarm?.id == BerserkAlarmPlan.alarmID(assignmentID: "canvas:hw", fireDate: due - Self.lead))
        }
    }

    // MARK: Reconcile

    private func planned(_ id: String, at offset: TimeInterval = 0) -> PlannedAlarm {
        let fireDate = fire.addingTimeInterval(offset)
        return PlannedAlarm(id: BerserkAlarmPlan.alarmID(assignmentID: id, fireDate: fireDate),
                            assignmentID: id, fireDate: fireDate, title: id,
                            course: "CIS 1200",
                            dueAt: fireDate.addingTimeInterval(NotificationScheduler.loudAlertLead),
                            link: nil)
    }

    @Test("Nothing desired and nothing existing: nothing to do")
    func reconcileEmpty() {
        #expect(BerserkAlarmPlan.reconcile(desired: [], existingIDs: [])
                == BerserkAlarmDiff(toCancel: [], toSchedule: []))
    }

    @Test("All new: schedule them all, cancel nothing")
    func reconcileAllNew() {
        let a = planned("a"), b = planned("b")
        #expect(BerserkAlarmPlan.reconcile(desired: [a, b], existingIDs: [])
                == BerserkAlarmDiff(toCancel: [], toSchedule: [a, b]))
    }

    @Test("Already scheduled: left alone, so a reschedule is idempotent")
    func reconcileIdempotent() {
        let a = planned("a"), b = planned("b")
        #expect(BerserkAlarmPlan.reconcile(desired: [a, b], existingIDs: [b.id, a.id])
                == BerserkAlarmDiff(toCancel: [], toSchedule: []))
    }

    @Test("Stale: an alarm nobody wants any more is cancelled (finished, no longer qualifying, switch off)")
    func reconcileStale() {
        let a = planned("a"), gone = planned("gone")
        #expect(BerserkAlarmPlan.reconcile(desired: [a], existingIDs: [gone.id, a.id])
                == BerserkAlarmDiff(toCancel: [gone.id], toSchedule: []))
        #expect(BerserkAlarmPlan.reconcile(desired: [], existingIDs: [gone.id, a.id])
                == BerserkAlarmDiff(toCancel: [gone.id, a.id], toSchedule: []))
    }

    @Test("A moved due date cancels the old alarm and schedules the new one")
    func reconcileMoved() {
        let before = planned("a", at: 0), after = planned("a", at: 3600)
        #expect(before.id != after.id)
        #expect(BerserkAlarmPlan.reconcile(desired: [after], existingIDs: [before.id])
                == BerserkAlarmDiff(toCancel: [before.id], toSchedule: [after]))
    }

    @Test("A mix, with duplicates collapsed and the input order kept")
    func reconcileMixed() {
        let keep = planned("keep"), add1 = planned("add1"), add2 = planned("add2")
        let stale1 = planned("stale1"), stale2 = planned("stale2")
        let diff = BerserkAlarmPlan.reconcile(
            desired: [add1, keep, add2, add1],
            existingIDs: [stale2.id, keep.id, stale1.id, stale2.id])
        #expect(diff.toCancel == [stale2.id, stale1.id])
        #expect(diff.toSchedule == [add1, add2])
    }

    // MARK: Delivery decision

    @Test("Alarms only when AlarmKit is available and authorized; every other cell is the buzzes")
    func deliveryTable() {
        let states: [BerserkAlarmAuthorization] = [.authorized, .denied, .notDetermined, .failed]
        for available in [true, false] {
            for state in states {
                let expected: LoudAlertDelivery = (available && state == .authorized) ? .alarms : .buzzes
                #expect(BerserkAlarmPlan.delivery(alarmKitAvailable: available, authorization: state) == expected,
                        "available \(available), \(state)")
            }
        }
    }

    // MARK: plannedRequests with the buzzes left out

    /// A request reduced to what it says, so two plans can be compared for
    /// being the same notifications and not merely the same count.
    private func signature(_ request: UNNotificationRequest) -> String {
        var parts = [request.identifier, request.content.title, request.content.body,
                     request.content.threadIdentifier, "\(request.content.interruptionLevel.rawValue)",
                     request.content.categoryIdentifier]
        if let calendar = request.trigger as? UNCalendarNotificationTrigger {
            parts.append("\(calendar.dateComponents)")
        }
        if let interval = request.trigger as? UNTimeIntervalNotificationTrigger {
            parts.append("\(interval.timeInterval)")
        }
        return parts.joined(separator: "|")
    }

    @Test("Alarm mode omits exactly the loud buzzes and changes no other request")
    func alarmModeOmitsExactlyTheBuzzes() {
        // The busy fixture of the budget test: 65 requests wanted for 60 slots.
        withScheduler { scheduler, prefs, now in
            let courses = ["CIS 1200", "MATH 1400", "PHYS 0150"]
            let items = (0..<25).map {
                item(courses[$0 % 3], "i\($0)", due: now + 2 * 3600 + Double($0) * 5400)
            }
            let today = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            let off = scheduler.plannedRequests(
                from: items, now: now, preferences: prefs, loudAlertsAsAlarms: false)
            let on = scheduler.plannedRequests(
                from: items, now: now, preferences: prefs, loudAlertsAsAlarms: true)

            #expect(today.map(signature) == off.map(signature), "false is today's output")
            #expect(today.count == NotificationScheduler.maxPending)

            let withoutBuzzes = today.filter { !$0.identifier.hasPrefix("loud:") }
            #expect(!withoutBuzzes.isEmpty)
            #expect(on.map(signature) == withoutBuzzes.map(signature),
                    "exactly the buzzes are gone, every other request is as it was")
            #expect(on.allSatisfy { !$0.identifier.hasPrefix("loud:") })
            #expect(on.count == NotificationScheduler.maxPending - 30,
                    "the freed slots are not handed to other reminders")
        }
    }

    @Test("Alarm mode still leaves out the plain 10-minute reminder of an item that has the alarm")
    func alarmModeKeepsThePlainReminderOut() {
        withScheduler(leadTimes: [.m10, .h1]) { scheduler, prefs, now in
            let items = [
                item("CIS 1200", "hw", due: now + 5 * 3600),
                // Not covered by the alert, so it keeps its plain reminder.
                item("CIS 1200", "reading", due: now + 5 * 3600, kind: .event),
            ]
            let ids = Set(scheduler.plannedRequests(
                from: items, now: now, preferences: prefs, loudAlertsAsAlarms: true).map(\.identifier))
            #expect(ids == ["due:canvas:hw:3600", "due:canvas:reading:3600", "due:canvas:reading:600"])
        }
    }

    // MARK: Buttons

    private func planAlarm(for item: DashItem, now: Date) -> PlannedAlarm? {
        BerserkAlarmPlan.alarms(for: [item], now: now, nameOverrides: [:]).first
    }

    @Test("Stop says the link's label, or \"stop\" with no link; the secondary always says \"turned in\"")
    func buttonLabelsPerLinkKind() throws {
        let now = Date(), due = now + 3 * 3600
        let canvas = try #require(planAlarm(for: linked(.canvas, "cv", url: Self.canvasPage, due: due), now: now))
        let gradescope = try #require(planAlarm(
            for: linked(.gradescope, "course-123-assignment-456", url: Self.gradescopePage, due: due), now: now))
        let pair = try #require(planAlarm(
            for: linked(.canvas, "pr", url: Self.canvasPage, linkedID: "gradescope:course-123-assignment-456", due: due),
            now: now))
        let manual = try #require(planAlarm(for: linked(.manual, "mine", url: nil, due: due), now: now))
        let ed = try #require(planAlarm(
            for: DashItem(assignment: Assignment(
                source: .canvasAnnouncement, sourceID: AnnouncementRecord.edFindSourcePrefix + "1",
                kind: .assignment, course: "CIS 1200", title: "HW", dueAt: due,
                url: URL(string: "https://edstem.org/us/courses/1/discussion/2")),
                dueOverride: nil, isCompleted: false, completedAt: nil), now: now))

        #expect(canvas.stopLabel == "open in canvas")
        #expect(canvas.link?.kind == .canvas)
        #expect(canvas.link?.url.absoluteString == Self.canvasPage)

        #expect(gradescope.stopLabel == "open in gradescope")
        #expect(gradescope.link?.kind == .gradescope)
        #expect(gradescope.link?.url.absoluteString == Self.gradescopePage)

        #expect(pair.stopLabel == "open in canvas", "a Canvas link wins beside a Gradescope one")

        #expect(manual.stopLabel == "stop")
        #expect(manual.link == nil)
        #expect(ed.stopLabel == "stop", "no \"open in canvas\" for a link that opens Ed")
        #expect(ed.link == nil)

        for alarm in [canvas, gradescope, pair, manual, ed] {
            #expect(alarm.secondaryLabel == "turned in")
        }
    }

    /// AlarmKit may run the stop intent on a swipe-away or the side button, so
    /// stop must never be able to mean "turned in".
    @Test("Stop is never \"turned in\", in its label or in what it does")
    func stopIsNeverTurnedIn() throws {
        let now = Date(), due = now + 3 * 3600
        let items = [
            linked(.canvas, "cv", url: Self.canvasPage, due: due),
            linked(.gradescope, "course-123-assignment-456", url: Self.gradescopePage, due: due),
            linked(.manual, "mine", url: nil, due: due),
        ]
        for item in items {
            let planned = try #require(planAlarm(for: item, now: now))
            #expect(planned.stopLabel != LoudAlertActions.turnedInTitle)
            #expect(planned.stopLabel != planned.secondaryLabel)
        }

        // Whatever stop is handed, valid link or garbage or an id, it never
        // yields a "turned in".
        for url in [Self.canvasPage, "", "not a url", "http://canvas.upenn.edu/x", "javascript:alert(1)"] {
            let action = BerserkAlarmPlan.action(for: .stop, assignmentID: "canvas:cv", url: url)
            if case .turnedIn? = action { Issue.record("stop produced .turnedIn for \(url)") }
        }
        #expect(BerserkAlarmPlan.action(for: .stop, assignmentID: "canvas:cv", url: Self.canvasPage)
                == .open(try #require(URL(string: Self.canvasPage))))
        #expect(BerserkAlarmPlan.action(for: .turnedIn, assignmentID: "canvas:cv", url: Self.canvasPage)
                == .turnedIn("canvas:cv"))
    }

    // MARK: The receive entry

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    @Test("A stop press with a good link queues an \"open\", stamped when it was pressed")
    func receiveStop() throws {
        let inbox = NotificationActionInbox()
        let queued = NotificationResponseRouter.receiveAlarmAction(
            .stop, assignmentID: "canvas:hw", url: Self.canvasPage, into: inbox, at: date(5))
        #expect(queued)
        #expect(inbox.queue == [PendingLoudAlertAction(
            action: .open(try #require(URL(string: Self.canvasPage))), arrivedAt: date(5))])
    }

    @Test("A turned-in press queues a \"turned in\" for the item")
    func receiveTurnedIn() {
        let inbox = NotificationActionInbox()
        let queued = NotificationResponseRouter.receiveAlarmAction(
            .turnedIn, assignmentID: "canvas:hw", url: "", into: inbox, at: date(1))
        #expect(queued)
        #expect(inbox.queue == [PendingLoudAlertAction(action: .turnedIn("canvas:hw"), arrivedAt: date(1))])
    }

    @Test("A stop press whose URL is not https with a host queues nothing")
    func receiveRejectsUnsafeURLs() {
        let inbox = NotificationActionInbox()
        for raw in ["", "not a url", "http://canvas.upenn.edu/courses/1", "javascript:alert(1)",
                    "file:///etc/passwd", "https://", "/courses/1/assignments/77"] {
            let queued = NotificationResponseRouter.receiveAlarmAction(
                .stop, assignmentID: "canvas:hw", url: raw, into: inbox, at: date(0))
            #expect(!queued, "\(raw)")
        }
        #expect(inbox.queue.isEmpty)
    }

    @Test("A turned-in press with no item id queues nothing; a stop never queues a \"turned in\"")
    func receiveEdges() {
        let inbox = NotificationActionInbox()
        #expect(!NotificationResponseRouter.receiveAlarmAction(
            .turnedIn, assignmentID: "", url: Self.canvasPage, into: inbox, at: date(0)))
        _ = NotificationResponseRouter.receiveAlarmAction(
            .stop, assignmentID: "canvas:hw", url: Self.canvasPage, into: inbox, at: date(0))
        #expect(inbox.queue.allSatisfy { if case .turnedIn = $0.action { return false } else { return true } })
    }

    /// The dashboard's own rule for an alarm's "open" is the notification's:
    /// it expires after two minutes. A "turned in" never does.
    @Test("An alarm's presses age like a notification's: open expires, turned in does not")
    func receivedPressesAge() {
        let inbox = NotificationActionInbox()
        NotificationResponseRouter.receiveAlarmAction(
            .stop, assignmentID: "canvas:hw", url: Self.canvasPage, into: inbox, at: date(0))
        NotificationResponseRouter.receiveAlarmAction(
            .turnedIn, assignmentID: "canvas:hw", url: "", into: inbox, at: date(0))
        #expect(inbox.drain(isDashboardBound: true, now: date(1_000)) == [.turnedIn("canvas:hw")])
    }

    // MARK: Where it is wired (source structure)

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)     // .../Tests/LowHangingFruitKitTests/<this>
            .deletingLastPathComponent()    // .../Tests/LowHangingFruitKitTests
            .deletingLastPathComponent()    // .../Tests
            .deletingLastPathComponent()    // .../LowHangingFruitKit
    }

    private func repoRoot() -> URL { packageRoot().deletingLastPathComponent() }

    /// A file that cannot be found is a failure, not a pass: a scan that
    /// silently returns guards nothing.
    private func read(_ url: URL) throws -> String {
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.path) is not there, so nothing could be checked")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func uiSource(_ filename: String) throws -> String {
        try read(packageRoot().appendingPathComponent("Sources/LowHangingFruitUI/\(filename)"))
    }

    /// The App target is not compiled by `swift test`, so these scans are the
    /// only guard on it. Substrings, not positions or indentation.
    @Test("LHFApp.swift defines both intents, which open the app, inside the iOS-only guard")
    func appDefinesBothIntents() throws {
        let source = try read(repoRoot().appendingPathComponent("App/LHFApp.swift"))

        let guardStart = try #require(source.range(of: "#if canImport(AlarmKit) && os(iOS)\n\n// MARK: - Berserk alarm buttons"))
        let tail = source[guardStart.lowerBound...]
        #expect(tail.contains("#endif"))

        let stopStart = try #require(tail.range(of: "struct BerserkStopAlarmIntent: LiveActivityIntent"))
        let turnedInStart = try #require(tail.range(of: "struct BerserkTurnedInAlarmIntent: LiveActivityIntent"))
        #expect(stopStart.lowerBound < turnedInStart.lowerBound)
        let stop = tail[stopStart.lowerBound..<turnedInStart.lowerBound]
        let turnedIn = tail[turnedInStart.lowerBound...]

        #expect(tail[..<stopStart.lowerBound].hasSuffix("@available(iOS 26.0, *)\n"))
        #expect(tail[..<turnedInStart.lowerBound].hasSuffix("@available(iOS 26.0, *)\n"))
        for (name, body) in [("stop", stop), ("turned in", turnedIn)] {
            #expect(body.contains("supportedModes") && body.contains(".foreground"),
                    "\(name): the intent must open the app")
            #expect(body.contains("AlarmManager.shared.stop(id:"), "\(name): each stops its own alarm")
            #expect(body.contains("@MainActor"), "\(name)")
            #expect(body.contains("NotificationResponseRouter.receiveAlarmAction("), "\(name)")
        }

        // The mapping, once more where it is wired: stop reports a stop, and
        // only the secondary reports "turned in".
        #expect(stop.contains("receiveAlarmAction(.stop"))
        #expect(!stop.contains(".turnedIn"))
        #expect(turnedIn.contains("receiveAlarmAction(.turnedIn"))
        #expect(!turnedIn.contains("receiveAlarmAction(.stop"))
    }

    @Test("LHFApp.init sets the intent factory inside an iOS 26 check, after the router is installed")
    func appSetsTheFactory() throws {
        let source = try read(repoRoot().appendingPathComponent("App/LHFApp.swift"))
        let initStart = try #require(source.range(of: "init() {"))
        let bodyStart = try #require(source.range(of: "var body: some Scene", range: initStart.upperBound..<source.endIndex))
        let initBody = source[initStart.upperBound..<bodyStart.lowerBound]

        let install = try #require(initBody.range(of: "NotificationResponseRouter.install()"))
        let check = try #require(initBody.range(of: "#available(iOS 26"))
        let factory = try #require(initBody.range(of: "BerserkAlarmIntents.factory ="))
        #expect(install.lowerBound < check.lowerBound)
        #expect(check.lowerBound < factory.lowerBound)
        #expect(initBody.contains("BerserkStopAlarmIntent(") && initBody.contains("BerserkTurnedInAlarmIntent("))

        // And the guard around it keeps the Mac build from seeing AlarmKit.
        let guardStart = try #require(initBody.range(of: "#if canImport(AlarmKit) && os(iOS)"))
        #expect(guardStart.lowerBound < check.lowerBound)
    }

    @Test("The usage description is non-empty in both App/Info.plist and project.yml's app target, and the same")
    func usageDescriptionInBothPlaces() throws {
        let plistData = try Data(contentsOf: repoRoot().appendingPathComponent("App/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let fromPlist = try #require(plist["NSAlarmKitUsageDescription"] as? String)
        #expect(!fromPlist.trimmingCharacters(in: .whitespaces).isEmpty)

        let yml = try read(repoRoot().appendingPathComponent("project.yml"))
        let key = try #require(yml.range(of: "NSAlarmKitUsageDescription:"))
        let widgetTarget = try #require(yml.range(of: "\n  LHFWidgetExtension:"))
        #expect(key.lowerBound < widgetTarget.lowerBound, "it belongs to the app target, not the widget's")
        let line = yml[key.upperBound...].prefix(while: { $0 != "\n" })
        let fromYML = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        #expect(!fromYML.isEmpty)
        #expect(fromYML == fromPlist)
        #expect(fromPlist == "The Smooth Sweeper rings an alarm 10 minutes before work you haven't turned in.")
    }

    /// The pinned mapping of the factory's arguments. Both ids are plain
    /// `String`s by the time they reach an intent, so swapping them compiles:
    /// the stop would then be handed the item id as its alarm id (stopping
    /// nothing, and leaving the alarm ringing) and the item would be looked up
    /// by the alarm's UUID (completing nothing). Whitespace is collapsed so a
    /// reflow cannot fail the scan.
    @Test("The factory passes the alarm id and the item id to the intents' own parameters, not swapped")
    func factoryArgumentMapping() throws {
        let source = try read(repoRoot().appendingPathComponent("App/LHFApp.swift"))
        let flat = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        #expect(flat.contains("BerserkAlarmIntents.factory = { button, alarmID, assignmentID, url in"))
        #expect(flat.contains(
            "BerserkStopAlarmIntent(alarmID: alarmID.uuidString, assignmentID: assignmentID, url: url?.absoluteString ?? \"\")"))
        #expect(flat.contains(
            "BerserkTurnedInAlarmIntent(alarmID: alarmID.uuidString, assignmentID: assignmentID)"))
        #expect(!flat.contains("alarmID: assignmentID"))
        #expect(!flat.contains("assignmentID: alarmID"))

        // And each intent reads them back the same way round: its alarm id
        // is parsed as the alarm's UUID, its item id is the one deposited.
        #expect(flat.contains("UUID(uuidString: alarmID)"))
        #expect(!flat.contains("UUID(uuidString: assignmentID)"))
        #expect(flat.contains("receiveAlarmAction(.stop, assignmentID: assignmentID, url: url)"))
        #expect(flat.contains("receiveAlarmAction(.turnedIn, assignmentID: assignmentID, url: \"\")"))
    }

    @Test("ContentView registers the fixture-data probe from AppState and takes the alarms back on entering preview")
    func contentViewWiring() throws {
        let source = try uiSource("ContentView.swift")
        #expect(source.contains("scheduler.fixtureDataProbe = { [state] in state.isUsingFixtureData }"))
        let previewStart = try #require(source.range(of: "if state.isPreviewMode {"))
        let bind = try #require(source.range(of: "vm.bind(to: state)", range: previewStart.upperBound..<source.endIndex))
        #expect(source[previewStart.upperBound..<bind.lowerBound].contains("scheduler.cancelAlarms()"))
    }

    /// The fixture rule reads `AppState.isUsingFixtureData`, so that has to
    /// keep covering both things the rule exists for.
    @Test("AppState.isUsingFixtureData covers preview mode and the DEBUG demo launch")
    func fixtureDataCoversPreviewAndDemo() throws {
        let source = try uiSource("AppState.swift")
        let start = try #require(source.range(of: "var isUsingFixtureData: Bool {"))
        let body = source[start.lowerBound...].prefix(600)
        #expect(body.contains("if isPreviewMode { return true }"))
        #expect(body.contains("-LHFDemoData"))
    }

    // MARK: The custom alarm sound

    @Test("The custom sound is used when its file is in the bundle, the default otherwise")
    func soundChoice() {
        #expect(BerserkAlarmPlan.alarmSoundName(fileExists: true) == "berserk-alarm.caf")
        #expect(BerserkAlarmPlan.alarmSoundName(fileExists: false) == nil)
        // The name the glue looks the file up by is the name it hands AlarmKit.
        #expect("\(BerserkAlarmPlan.alarmSoundResource).\(BerserkAlarmPlan.alarmSoundExtension)"
                == BerserkAlarmPlan.alarmSoundFileName)
    }

    @Test("App/berserk-alarm.caf exists, is not empty, and is a CAF file")
    func soundFileIsThere() throws {
        let url = repoRoot().appendingPathComponent("App/\(BerserkAlarmPlan.alarmSoundFileName)")
        let data = try #require(try? Data(contentsOf: url), "\(url.path) is not there")
        #expect(data.count > 0)
        #expect(data.prefix(4) == Data("caff".utf8), "not a Core Audio Format file")
    }

    /// Read as a property list, not as text, so a reflow or a renamed id cannot
    /// fool it, and tied to the right target by what the target *is* (the
    /// application product, not the widget extension) rather than by an id or
    /// a name that a regenerated project would change. Follows the chain the
    /// build follows: the target's Resources phase lists a build file whose
    /// file reference is the sound, which the App group holds.
    @Test("project.pbxproj lists the sound in the app target's Resources phase, and not in the widget's")
    func soundIsInTheAppTargetsResources() throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("LowHangingFruit.xcodeproj/project.pbxproj"))
        let root = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try #require(root["objects"] as? [String: [String: Any]])

        let refs = objects.filter { $0.value["isa"] as? String == "PBXFileReference"
            && $0.value["path"] as? String == BerserkAlarmPlan.alarmSoundFileName }
        #expect(refs.count == 1, "exactly one file reference for the sound")
        let refID = try #require(refs.keys.first)
        #expect(refID.count == 24 && refID.allSatisfy(\.isHexDigit))

        let buildFiles = objects.filter { $0.value["isa"] as? String == "PBXBuildFile"
            && $0.value["fileRef"] as? String == refID }
        #expect(buildFiles.count == 1, "exactly one build file for it")
        let buildFileID = try #require(buildFiles.keys.first)

        // The App group holds the file reference.
        let holders = objects.filter { $0.value["isa"] as? String == "PBXGroup"
            && ($0.value["children"] as? [String])?.contains(refID) == true }
        #expect(holders.count == 1)
        #expect(holders.values.first?["path"] as? String == "App")

        func resourceFiles(ofProductType productType: String) throws -> [String] {
            let targets = objects.values.filter {
                $0["isa"] as? String == "PBXNativeTarget" && $0["productType"] as? String == productType }
            #expect(targets.count == 1, "\(productType)")
            let phases = try #require((targets.first?["buildPhases"] as? [String])?.compactMap { objects[$0] })
            let resources = phases.filter { $0["isa"] as? String == "PBXResourcesBuildPhase" }
            #expect(resources.count == 1, "\(productType)")
            return resources.first?["files"] as? [String] ?? []
        }
        #expect(try resourceFiles(ofProductType: "com.apple.product-type.application").contains(buildFileID))
        #expect(try !resourceFiles(ofProductType: "com.apple.product-type.app-extension").contains(buildFileID),
                "the widget extension must not carry the sound")
    }

    @Test("The alarm glue asks the main bundle for the sound and passes the choice to the configuration")
    func soundGlue() throws {
        let source = try uiSource("BerserkAlarmScheduler.swift")
        #expect(source.contains("Bundle.main.url(forResource: BerserkAlarmPlan.alarmSoundResource"))
        #expect(source.contains("BerserkAlarmPlan.alarmSoundName(fileExists: file != nil)"))
        #expect(source.contains("sound: Self.sound())"))
        #expect(!source.contains("Bundle.module"), "a package resource bundle is not where AlarmKit looks")
        // The notifications keep their own sound.
        let scheduler = try uiSource("NotificationScheduler.swift")
        #expect(!scheduler.contains("berserk-alarm") && !scheduler.contains("alarmSoundName"))
    }

    /// AlarmKit is an iOS 26 framework, and `swift test` compiles the macOS
    /// slice with an iOS 17 floor: every file that names it must be behind the
    /// guard, or the test build breaks.
    @Test("Only the guarded files import AlarmKit or AppIntents")
    func alarmKitIsGuarded() throws {
        let sources = packageRoot().appendingPathComponent("Sources/LowHangingFruitUI")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var importers: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("import AlarmKit") || text.contains("import AppIntents") {
                importers.append(url.lastPathComponent)
                #expect(text.hasPrefix("#if canImport(AlarmKit) && os(iOS)"), "\(url.lastPathComponent)")
                #expect(text.contains("@available(iOS 26.0, *)"), "\(url.lastPathComponent)")
            }
        }
        // Two files since 2026-10-20: the scheduler and its alerting extension
        // (`BerserkAlarmScheduler+Alerting.swift`). A set, because the
        // enumerator's order is not stable.
        #expect(Set(importers) == ["BerserkAlarmScheduler.swift", "BerserkAlarmScheduler+Alerting.swift"])
    }

    // MARK: - Fixture

    private func withScratchDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "lhf.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not open a scratch defaults suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func withScheduler(
        _ body: (NotificationScheduler, CoursePreferencesStore, Date) throws -> Void
    ) rethrows {
        try withScratchDefaults { defaults in
            try body(NotificationScheduler(defaults: defaults),
                     CoursePreferencesStore(defaults: defaults), Date())
        }
    }

    private func withScheduler(
        leadTimes: Set<LeadOffset>,
        _ body: (NotificationScheduler, CoursePreferencesStore, Date) throws -> Void
    ) rethrows {
        try withScratchDefaults { defaults in
            let scheduler = NotificationScheduler(defaults: defaults)
            for offset in LeadOffset.allCases {
                scheduler.setOffset(offset, on: leadTimes.contains(offset))
            }
            try body(scheduler, CoursePreferencesStore(defaults: defaults), Date())
        }
    }

    private func item(
        _ course: String, _ id: String, due: Date?,
        title: String? = nil,
        kind: Assignment.Kind = .assignment,
        completed: Bool = false,
        requiresNoSubmission: Bool = false,
        override: Date? = nil
    ) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: kind,
                                   course: course, title: title ?? "HW \(id)", dueAt: due, url: nil),
            dueOverride: override, isCompleted: completed, completedAt: nil,
            requiresNoSubmission: requiresNoSubmission
        )
    }

    private func occurrence(_ course: String, taskID: UUID, due: Date) -> DashItem {
        DashItem(
            assignment: Assignment(
                source: .canvasSuggestion,
                sourceID: RecurringTask.occurrenceSourceID(taskID: taskID, due: due),
                kind: .assignment, course: course, title: "Weekly reading",
                dueAt: due, url: nil
            ),
            dueOverride: nil, isCompleted: false, completedAt: nil
        )
    }

    /// An exam announced in prose: filed as a submission, but a sitting.
    private func foundExam(_ course: String, due: Date) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvasAnnouncement, sourceID: "announcement-7-0", kind: .assignment,
                                   course: course, title: "Midterm 1", dueAt: due, url: nil),
            dueOverride: nil, isCompleted: false, completedAt: nil
        )
    }

    private func linked(
        _ source: Assignment.Source, _ sourceID: String, url: String?,
        linkedID: String? = nil, due: Date
    ) -> DashItem {
        DashItem(
            assignment: Assignment(source: source, sourceID: sourceID, kind: .assignment,
                                   course: "CIS 1200", title: "HW \(sourceID)", dueAt: due,
                                   url: url.flatMap(URL.init(string:)), linkedID: linkedID),
            dueOverride: nil, isCompleted: false, completedAt: nil
        )
    }

    /// The `Assignment.id` of every item with a loud request, in the order the
    /// plan lists them (nearest first), recovered from `loud:<id>:<n>`.
    private func loudItemIDsInOrder(_ requests: [UNNotificationRequest]) -> [String] {
        var seen: [String] = []
        for request in requests where request.identifier.hasPrefix("loud:") {
            let body = request.identifier.dropFirst("loud:".count)
            let id = String(body.prefix(upTo: body.lastIndex(of: ":") ?? body.endIndex))
            if !seen.contains(id) { seen.append(id) }
        }
        return seen
    }
}
