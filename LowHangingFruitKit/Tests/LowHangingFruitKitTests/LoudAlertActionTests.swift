import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The loud alert's two buttons, "turned in" and "open in canvas" / "open in
/// gradescope": the categories, reading a tap back, and what the dashboard
/// does with it. Which requests carry which category is in `LoudAlertTests`,
/// beside the planner it drives.
///
/// **What these cannot show.** Nothing here touches the notification center
/// (`UNUserNotificationCenter.current()` traps in an unbundled test binary),
/// so that the delegate is really installed before launch finishes, that iOS
/// really shows the buttons on the lock screen, and that a tap on one really
/// reaches the dashboard are things only a device proves. The source-structure
/// tests below pin that the calls are *there*, not that they work.
@Suite("Loud alert buttons")
struct LoudAlertActionTests {

    // MARK: The categories

    private func categoriesByID() -> [String: UNNotificationCategory] {
        Dictionary(uniqueKeysWithValues: LoudAlertActions.categories().map { ($0.identifier, $0) })
    }

    /// The identifiers are pinned as literals, not through the constants: a
    /// category identifier is written into every pending request, so renaming
    /// one in a later build would orphan the alerts already scheduled under
    /// the old name, with no error to notice.
    @Test("Three categories with their fixed identifiers")
    func categoryIdentifiers() {
        #expect(Set(categoriesByID().keys) == ["loud.canvas", "loud.gradescope", "loud.turnedin"])
        #expect(LoudAlertActions.canvasCategoryID == "loud.canvas")
        #expect(LoudAlertActions.gradescopeCategoryID == "loud.gradescope")
        #expect(LoudAlertActions.turnedInOnlyCategoryID == "loud.turnedin")
        #expect(LoudAlertActions.turnedInActionID == "loud.action.turnedin")
        #expect(LoudAlertActions.openActionID == "loud.action.open")
    }

    @Test("The buttons say exactly \"turned in\", \"open in canvas\" and \"open in gradescope\"")
    func labels() throws {
        let categories = categoriesByID()
        let canvas = try #require(categories["loud.canvas"])
        let gradescope = try #require(categories["loud.gradescope"])
        let turnedInOnly = try #require(categories["loud.turnedin"])

        #expect(canvas.actions.map(\.identifier) == ["loud.action.turnedin", "loud.action.open"])
        #expect(canvas.actions.map(\.title) == ["turned in", "open in canvas"])
        #expect(gradescope.actions.map(\.identifier) == ["loud.action.turnedin", "loud.action.open"])
        #expect(gradescope.actions.map(\.title) == ["turned in", "open in gradescope"])
        #expect(turnedInOnly.actions.map(\.identifier) == ["loud.action.turnedin"])
        #expect(turnedInOnly.actions.map(\.title) == ["turned in"])
    }

    /// Both buttons open the app. Handling "turned in" in the background would
    /// run app code while it is not on screen, the path that has crashed on
    /// every wake in this project; see `LoudAlertActions.categories`.
    @Test("Every action opens the app and does nothing else")
    func everyActionIsForeground() {
        let actions = LoudAlertActions.categories().flatMap(\.actions)
        #expect(actions.count == 5)
        for action in actions {
            #expect(action.options == [.foreground], "\(action.identifier)")
        }
    }

    // MARK: Which item gets which

    private func assignment(
        _ source: Assignment.Source, _ sourceID: String, url: String?, linkedID: String? = nil
    ) -> Assignment {
        Assignment(source: source, sourceID: sourceID, kind: .assignment, course: "CIS 1200",
                   title: "HW", dueAt: Date(timeIntervalSince1970: 1_800_000_000),
                   url: url.flatMap(URL.init(string:)), linkedID: linkedID)
    }

    @Test("A Canvas link wins, even beside a Gradescope one")
    func canvasWins() {
        let pair = assignment(.canvas, "1", url: "https://canvas.upenn.edu/courses/1/assignments/77",
                              linkedID: "gradescope:course-123-assignment-456")
        let buttons = LoudAlertActions.buttons(for: pair)
        #expect(buttons.categoryID == LoudAlertActions.canvasCategoryID)
        #expect(buttons.url?.absoluteString == "https://canvas.upenn.edu/courses/1/assignments/77")
    }

    @Test("With no Canvas link but a Gradescope one, the button is Gradescope's")
    func gradescopeAlone() {
        let onlyGradescope = assignment(.gradescope, "course-123-assignment-456", url: nil)
        let buttons = LoudAlertActions.buttons(for: onlyGradescope)
        #expect(buttons.categoryID == LoudAlertActions.gradescopeCategoryID)
        #expect(buttons.url?.absoluteString == "https://www.gradescope.com/courses/123/assignments/456")
    }

    @Test("Neither link, only \"turned in\": manual work, and a Canvas item whose stored URL is unusable")
    func neitherLink() {
        let manual = assignment(.manual, "mine", url: nil)
        #expect(LoudAlertActions.buttons(for: manual).categoryID == LoudAlertActions.turnedInOnlyCategoryID)
        #expect(LoudAlertActions.buttons(for: manual).url == nil)

        // `sourceLinks` drops anything that is not https with a host.
        let plainHTTP = assignment(.canvas, "2", url: "http://canvas.upenn.edu/courses/1/assignments/77")
        #expect(LoudAlertActions.buttons(for: plainHTTP).categoryID == LoudAlertActions.turnedInOnlyCategoryID)
        #expect(LoudAlertActions.buttons(for: plainHTTP).url == nil)
    }

    /// An Ed link is the card's "open in ed". The owner asked for three
    /// labels, none of them Ed's, so the item is offered "turned in" alone
    /// rather than an "open in canvas" that would open Ed.
    @Test("A task found in an Ed post is offered \"turned in\" only, never \"open in canvas\"")
    func edPostGetsNoOpenButton() {
        let ed = Assignment(source: .canvasAnnouncement, sourceID: AnnouncementRecord.edFindSourcePrefix + "1",
                            kind: .assignment, course: "CIS 1200", title: "HW",
                            dueAt: Date(timeIntervalSince1970: 1_800_000_000),
                            url: URL(string: "https://edstem.org/us/courses/1/discussion/2"))
        #expect(ed.announcementOrigin == .ed)
        #expect(ed.sourceLinks.first?.label == SourceLink.edLabel, "the fixture must be an Ed link")
        #expect(LoudAlertActions.buttons(for: ed).categoryID == LoudAlertActions.turnedInOnlyCategoryID)
        #expect(LoudAlertActions.buttons(for: ed).url == nil)
    }

    // MARK: Reading a tap

    private let page = "https://canvas.upenn.edu/courses/1/assignments/77"

    private func info(id: Any? = "canvas:hw", url: Any? = "https://canvas.upenn.edu/courses/1/assignments/77")
        -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [:]
        if let id { info[LoudAlertActions.assignmentIDKey] = id }
        if let url { info[LoudAlertActions.linkURLKey] = url }
        return info
    }

    @Test("\"turned in\" yields .turnedIn(id) and \"open\" yields .open(url)")
    func parsesBothButtons() throws {
        #expect(LoudAlertActions.action(actionIdentifier: "loud.action.turnedin", userInfo: info())
                == .turnedIn("canvas:hw"))
        #expect(LoudAlertActions.action(actionIdentifier: "loud.action.open", userInfo: info())
                == .open(try #require(URL(string: page))))
    }

    @Test("A request's own userInfo reads back to the same actions")
    func roundTrip() throws {
        let url = try #require(URL(string: page))
        let built = LoudAlertActions.userInfo(assignmentID: "canvas:hw", url: url)
        #expect(LoudAlertActions.action(actionIdentifier: LoudAlertActions.turnedInActionID, userInfo: built)
                == .turnedIn("canvas:hw"))
        #expect(LoudAlertActions.action(actionIdentifier: LoudAlertActions.openActionID, userInfo: built)
                == .open(url))
        // No link: "turned in" still works, "open" has nothing to open.
        let bare = LoudAlertActions.userInfo(assignmentID: "manual:mine", url: nil)
        #expect(LoudAlertActions.action(actionIdentifier: LoudAlertActions.turnedInActionID, userInfo: bare)
                == .turnedIn("manual:mine"))
        #expect(LoudAlertActions.action(actionIdentifier: LoudAlertActions.openActionID, userInfo: bare) == nil)
    }

    @Test("The default tap, the dismiss action and an unknown identifier yield nothing")
    func ignoredIdentifiers() {
        let full = info()
        #expect(LoudAlertActions.action(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: full) == nil)
        #expect(LoudAlertActions.action(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: full) == nil)
        #expect(LoudAlertActions.action(actionIdentifier: "loud.action.something-new", userInfo: full) == nil)
        #expect(LoudAlertActions.action(actionIdentifier: "", userInfo: full) == nil)
    }

    @Test("Missing or garbled userInfo yields nothing")
    func damagedPayloads() {
        let turnedIn = LoudAlertActions.turnedInActionID
        let open = LoudAlertActions.openActionID

        #expect(LoudAlertActions.action(actionIdentifier: turnedIn, userInfo: [:]) == nil)
        #expect(LoudAlertActions.action(actionIdentifier: open, userInfo: [:]) == nil)

        #expect(LoudAlertActions.action(actionIdentifier: turnedIn, userInfo: info(id: nil)) == nil)
        #expect(LoudAlertActions.action(actionIdentifier: turnedIn, userInfo: info(id: 42)) == nil)
        #expect(LoudAlertActions.action(actionIdentifier: turnedIn, userInfo: info(id: "")) == nil)
        #expect(LoudAlertActions.action(actionIdentifier: turnedIn, userInfo: info(id: ["canvas:hw"])) == nil)

        #expect(LoudAlertActions.action(actionIdentifier: open, userInfo: info(url: nil)) == nil)
        #expect(LoudAlertActions.action(actionIdentifier: open, userInfo: info(url: 42)) == nil)
        #expect(LoudAlertActions.action(actionIdentifier: open, userInfo: info(url: "")) == nil)
        #expect(LoudAlertActions.action(actionIdentifier: open, userInfo: info(url: "not a url")) == nil)
        #expect(LoudAlertActions.action(actionIdentifier: open, userInfo: info(url: "/courses/1/assignments/77")) == nil)
    }

    /// https only, the rule `Assignment.sourceLinks` applies when it makes the
    /// link: plain `http` is refused along with everything else.
    @Test("A link that is not https with a host yields nothing, plain http included")
    func unsafeLinks() {
        for raw in [
            "javascript:alert(1)", "file:///etc/passwd", "ftp://canvas.upenn.edu/x",
            "mailto:someone@upenn.edu", "smooth://open", "https://", "https:///courses/1",
            "http://canvas.upenn.edu/courses/1", "HTTP://CANVAS.UPENN.EDU/courses/1",
        ] {
            #expect(LoudAlertActions.action(actionIdentifier: LoudAlertActions.openActionID,
                                            userInfo: info(url: raw)) == nil, "\(raw)")
        }
        for raw in ["https://canvas.upenn.edu/courses/1", "HTTPS://CANVAS.UPENN.EDU/courses/1"] {
            #expect(LoudAlertActions.action(actionIdentifier: LoudAlertActions.openActionID,
                                            userInfo: info(url: raw)) != nil, "\(raw)")
        }
    }

    // MARK: What the dashboard does with it

    private func item(_ id: String, done: Bool = false) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: .assignment, course: "CIS 1200",
                                   title: "HW \(id)", dueAt: Date(timeIntervalSince1970: 1_800_000_000), url: nil),
            dueOverride: nil, isCompleted: done, completedAt: done ? Date() : nil
        )
    }

    @Test("\"turned in\" on an active item completes it, picking the one whose id matches")
    func completesTheMatchingActiveItem() {
        let items = [item("a"), item("b"), item("c")]
        let disposition = LoudAlertActions.disposition(
            for: .turnedIn("canvas:b"), items: items, isPreviewMode: false)
        #expect(disposition == .complete(items[1]))
    }

    @Test("\"turned in\" on an unknown id completes nothing and still clears")
    func unknownItem() {
        let items = [item("a")]
        #expect(LoudAlertActions.disposition(for: .turnedIn("canvas:gone"), items: items, isPreviewMode: false)
                == .clearOnly("canvas:gone"))
        #expect(LoudAlertActions.disposition(for: .turnedIn("canvas:a"), items: [], isPreviewMode: false)
                == .clearOnly("canvas:a"), "an empty dashboard is an unknown id too")
    }

    @Test("\"turned in\" on an item that is already done completes nothing and still clears")
    func alreadyDone() {
        let items = [item("a", done: true)]
        #expect(LoudAlertActions.disposition(for: .turnedIn("canvas:a"), items: items, isPreviewMode: false)
                == .clearOnly("canvas:a"))
    }

    @Test("\"open\" opens the page")
    func opens() throws {
        let url = try #require(URL(string: page))
        #expect(LoudAlertActions.disposition(for: .open(url), items: [item("a")], isPreviewMode: false) == .open(url))
    }

    @Test("In preview mode every action is dropped")
    func previewDropsEverything() throws {
        let url = try #require(URL(string: page))
        let items = [item("a")]
        #expect(LoudAlertActions.disposition(for: .turnedIn("canvas:a"), items: items, isPreviewMode: true) == .drop)
        #expect(LoudAlertActions.disposition(for: .turnedIn("canvas:gone"), items: items, isPreviewMode: true) == .drop)
        #expect(LoudAlertActions.disposition(for: .open(url), items: items, isPreviewMode: true) == .drop)
    }

    @Test("A batch is judged in order: a second \"turned in\" for the same item finds it already ticked")
    func batchTicksOnce() {
        let items = [item("a"), item("b")]
        let ds = LoudAlertActions.dispositions(
            for: [.turnedIn("canvas:a"), .turnedIn("canvas:b"), .turnedIn("canvas:a")],
            items: items, isPreviewMode: false)
        #expect(ds == [.complete(items[0]), .complete(items[1]), .clearOnly("canvas:a")])
    }

    @Test("A batch keeps its order across kinds, and preview mode drops all of it")
    func batchMixedAndPreview() throws {
        let url = try #require(URL(string: page))
        let items = [item("a")]
        let actions: [LoudAlertAction] = [.open(url), .turnedIn("canvas:a"), .turnedIn("canvas:gone")]
        #expect(LoudAlertActions.dispositions(for: actions, items: items, isPreviewMode: false)
                == [.open(url), .complete(items[0]), .clearOnly("canvas:gone")])
        #expect(LoudAlertActions.dispositions(for: actions, items: items, isPreviewMode: true)
                == [.drop, .drop, .drop])
        #expect(LoudAlertActions.dispositions(for: [], items: items, isPreviewMode: false).isEmpty)
    }

    /// The dashboard re-plans once per batch, and only when a "turned in" was
    /// in it; "open" alone must not cancel and re-add sixty reminders.
    @Test("Only a \"turned in\" calls for a re-plan, whether or not there was a card to tick")
    func replanRule() throws {
        let url = try #require(URL(string: page))
        #expect(LoudAlertDisposition.complete(item("a")).needsReplan)
        #expect(LoudAlertDisposition.clearOnly("canvas:a").needsReplan)
        #expect(!LoudAlertDisposition.open(url).needsReplan)
        #expect(!LoudAlertDisposition.drop.needsReplan)
    }

    // MARK: Staleness

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func pending(_ action: LoudAlertAction, ageSeconds: TimeInterval) -> PendingLoudAlertAction {
        PendingLoudAlertAction(action: action, arrivedAt: t0.addingTimeInterval(-ageSeconds))
    }

    /// Injected `now`, so none of this waits for a clock.
    @Test("An \"open\" older than two minutes expires; a fresh one, and one exactly two minutes old, do not")
    func staleOpenExpires() throws {
        let url = try #require(URL(string: page))
        #expect(LoudAlertActions.openLifetime == 120)
        let queue = [
            pending(.open(url), ageSeconds: 0),
            pending(.open(url), ageSeconds: 120),
            pending(.open(url), ageSeconds: 121),
            pending(.open(url), ageSeconds: 3 * 86_400),
        ]
        #expect(LoudAlertActions.unexpired(queue, now: t0) == [.open(url), .open(url)])
    }

    @Test("A \"turned in\" never expires, however old, and the order is kept")
    func turnedInNeverExpires() throws {
        let url = try #require(URL(string: page))
        let queue = [
            pending(.turnedIn("canvas:old"), ageSeconds: 30 * 86_400),
            pending(.open(url), ageSeconds: 3 * 86_400),
            pending(.turnedIn("canvas:new"), ageSeconds: 1),
            pending(.open(url), ageSeconds: 5),
        ]
        #expect(LoudAlertActions.unexpired(queue, now: t0)
                == [.turnedIn("canvas:old"), .turnedIn("canvas:new"), .open(url)])
    }

    // MARK: Silencing at the tap

    @Test("\"turned in\" silences all three of the item's notifications at the tap; \"open\" silences none")
    func silencing() throws {
        #expect(LoudAlertActions.identifiersToSilence(for: .turnedIn("canvas:hw"))
                == ["loud:canvas:hw:1", "loud:canvas:hw:2", "loud:canvas:hw:3"])
        #expect(LoudAlertActions.identifiersToSilence(for: .open(try #require(URL(string: page)))).isEmpty)
    }

    // MARK: The foreground presentation

    @Test("A notification still shows as a banner, with sound, and in the list while the app is open")
    func foregroundPresentation() {
        #expect(NotificationResponseDelegate.foregroundPresentation == [.banner, .sound, .list])
    }

    // MARK: The inbox

    private func date(_ secondsAfterT0: TimeInterval) -> Date { t0.addingTimeInterval(secondsAfterT0) }

    /// A second tap must never overwrite the first. Each test builds its own
    /// inbox: the shared one is the app's, and a test must not leave an action
    /// waiting in it.
    @MainActor
    @Test("Taps queue up in order and none overwrites another")
    func inboxIsFIFO() {
        let inbox = NotificationActionInbox()
        #expect(inbox.queue.isEmpty)

        inbox.deposit(.turnedIn("canvas:a"), arrivedAt: date(0))
        inbox.deposit(.turnedIn("canvas:b"), arrivedAt: date(1))
        inbox.deposit(.turnedIn("canvas:c"), arrivedAt: date(2))
        #expect(inbox.queue.count == 3)

        #expect(inbox.drain(isDashboardBound: true, now: date(3))
                == [.turnedIn("canvas:a"), .turnedIn("canvas:b"), .turnedIn("canvas:c")])
    }

    @MainActor
    @Test("A drained action is gone, so a dashboard that appears twice cannot act twice")
    func drainEmpties() {
        let inbox = NotificationActionInbox()
        inbox.deposit(.turnedIn("canvas:a"), arrivedAt: date(0))
        #expect(inbox.drain(isDashboardBound: true, now: date(1)) == [.turnedIn("canvas:a")])
        #expect(inbox.queue.isEmpty)
        #expect(inbox.drain(isDashboardBound: true, now: date(2)).isEmpty)
    }

    /// The race this exists for: a tap that lands after the view's first
    /// render but before `.onAppear` binds the view model. Drained then, it
    /// would find an empty `vm.items`, complete nothing, and re-plan every
    /// reminder away.
    @MainActor
    @Test("Nothing is taken before the dashboard is bound; what waited is taken, whole, once it is")
    func drainWaitsForTheBind() {
        let inbox = NotificationActionInbox()
        inbox.deposit(.turnedIn("canvas:a"), arrivedAt: date(0))
        inbox.deposit(.turnedIn("canvas:b"), arrivedAt: date(1))

        #expect(inbox.drain(isDashboardBound: false, now: date(2)).isEmpty)
        #expect(inbox.drain(isDashboardBound: false, now: date(3)).isEmpty, "asking again changes nothing")
        #expect(inbox.queue.count == 2, "left exactly as it was")

        #expect(inbox.drain(isDashboardBound: true, now: date(4))
                == [.turnedIn("canvas:a"), .turnedIn("canvas:b")])
        #expect(inbox.queue.isEmpty)
    }

    @MainActor
    @Test("Draining drops a stale \"open\" but keeps a \"turned in\" of any age")
    func drainAppliesTheLifetime() throws {
        let url = try #require(URL(string: page))
        let inbox = NotificationActionInbox()
        inbox.deposit(.open(url), arrivedAt: date(0))
        inbox.deposit(.turnedIn("canvas:a"), arrivedAt: date(0))
        inbox.deposit(.open(url), arrivedAt: date(1_000))

        #expect(inbox.drain(isDashboardBound: true, now: date(1_010))
                == [.turnedIn("canvas:a"), .open(url)])
        #expect(inbox.queue.isEmpty, "the expired one is gone too, not left to be asked about again")
    }

    // MARK: Where it is wired (source structure)

    /// SwiftUI and `UNUserNotificationCenter` cannot run under the package
    /// test runner, so these scan source text, the same seam
    /// `VisualStructureTests` and `PreviewModeTests` use. Substrings, not
    /// positions or indentation. A file that cannot be found is a failure, not
    /// a pass: a scan that silently returns guards nothing.
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)     // .../Tests/LowHangingFruitKitTests/<this>
            .deletingLastPathComponent()    // .../Tests/LowHangingFruitKitTests
            .deletingLastPathComponent()    // .../Tests
            .deletingLastPathComponent()    // .../LowHangingFruitKit
    }

    private func read(_ url: URL) throws -> String {
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.path) is not there, so nothing could be checked")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func uiSource(_ filename: String) throws -> String {
        try read(packageRoot().appendingPathComponent("Sources/LowHangingFruitUI/\(filename)"))
    }

    /// The delegate has to be in place before launch finishes, because a tap
    /// on a button can be what launches the app; `LHFApp.init()` is the one
    /// place that is true, on both platforms. This lives in the App target,
    /// which `swift test` does not compile, so this scan is the only guard.
    @Test("LHFApp.init installs the router, ahead of any platform-specific block")
    func appInstallsTheRouterAtLaunch() throws {
        let source = try read(packageRoot().deletingLastPathComponent().appendingPathComponent("App/LHFApp.swift"))

        let initStart = try #require(source.range(of: "init() {"))
        let bodyStart = try #require(source.range(of: "var body: some Scene", range: initStart.upperBound..<source.endIndex))
        let initBody = source[initStart.upperBound..<bodyStart.lowerBound]

        let install = try #require(initBody.range(of: "NotificationResponseRouter.install()"))
        // Both platforms: the call comes before the first `#if`, not inside the
        // iOS-only background-refresh block.
        if let firstConditional = initBody.range(of: "#if") {
            #expect(install.lowerBound < firstConditional.lowerBound,
                    "install() must not sit inside a platform conditional")
        }
    }

    @Test("The scheduler assigns the shared delegate everywhere and the old private one is gone")
    func schedulerUsesTheSharedDelegate() throws {
        let source = try uiSource("NotificationScheduler.swift")

        #expect(!source.contains("ForegroundPresentationDelegate"))
        let assignments = source.split(separator: "\n").filter { $0.contains(".delegate =") }
        #expect(!assignments.isEmpty, "the scheduler still assigns a delegate where it did")
        #expect(assignments.allSatisfy { $0.contains("NotificationResponseDelegate.shared") },
                "a second delegate object would let a reschedule replace the one that routes taps")
    }

    /// The text between the bind and the end of `.onAppear` is where the
    /// dashboard becomes ready, so the flag must be set there, before the
    /// first drain. (The old version of this test looked for the call after
    /// the first `vm.bind`, which is true of any file, since the function's
    /// own declaration comes later.)
    @Test("ContentView sets the bound flag between the bind and the first drain, inside .onAppear")
    func dashboardDrainsOnlyAfterBinding() throws {
        let source = try uiSource("ContentView.swift")

        let bind = try #require(source.range(of: "vm.bind(to: state)"))
        let afterBind = source[bind.upperBound...]
        // `.onAppear`'s closure ends where the next modifier, `.task`, starts.
        let onAppearEnd = try #require(afterBind.range(of: ".task {"))
        let tail = afterBind[..<onAppearEnd.lowerBound]

        let flag = try #require(tail.range(of: "isDashboardBound = true"))
        let drain = try #require(tail.range(of: "takeLoudAlertActions()"))
        #expect(flag.lowerBound < drain.lowerBound)

        // Preview mode binds sample data and does the same.
        let beforeBind = source[..<bind.lowerBound]
        let previewStart = try #require(beforeBind.range(of: "if state.isPreviewMode {", options: .backwards))
        let preview = beforeBind[previewStart.upperBound...]
        let loaded = try #require(preview.range(of: "vm.loadSampleData()"))
        let previewFlag = try #require(preview.range(of: "isDashboardBound = true"))
        let previewDrain = try #require(preview.range(of: "takeLoudAlertActions()"))
        #expect(loaded.lowerBound < previewFlag.lowerBound)
        #expect(previewFlag.lowerBound < previewDrain.lowerBound)

        // And the drain itself is gated on the flag, wherever it is called from.
        #expect(source.contains("actionInbox.drain(isDashboardBound: isDashboardBound"))
        #expect(source.contains(".onChange(of: actionInbox.queue)"))
    }

    /// Once per batch, after every action has been carried out: a re-plan per
    /// action is a cancel-and-re-add of up to sixty reminders each time.
    @Test("ContentView re-plans once, after the whole batch, and only when a \"turned in\" was in it")
    func dashboardReplansOncePerBatch() throws {
        let source = try uiSource("ContentView.swift")
        let start = try #require(source.range(of: "private func takeLoudAlertActions()"))
        let end = try #require(source.range(of: "// MARK: Canvas session banner", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]

        #expect(body.components(separatedBy: "rescheduleNotifications()").count - 1 == 1)
        let loop = try #require(body.range(of: "for disposition in dispositions"))
        let gate = try #require(body.range(of: "dispositions.contains(where: \\.needsReplan)"))
        let replan = try #require(body.range(of: "rescheduleNotifications()"))
        #expect(loop.lowerBound < gate.lowerBound)
        #expect(gate.lowerBound < replan.lowerBound)
    }

    @Test("The delegate silences a tapped \"turned in\" item at the tap, through the center it was handed")
    func delegateSilencesAtTheTap() throws {
        let source = try uiSource("NotificationResponseRouter.swift")
        #expect(source.contains("LoudAlertActions.identifiersToSilence(for: action)"))
        #expect(source.contains("center.removePendingNotificationRequests(withIdentifiers:"))
        #expect(source.contains("center.removeDeliveredNotifications(withIdentifiers:"))
    }
}
