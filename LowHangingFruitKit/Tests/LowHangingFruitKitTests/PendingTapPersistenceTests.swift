import Testing
import Foundation
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// A "turned in" tap survives the process that received it (hardening plan
/// 2026-10-25, B10: NOT-09 and DAT-18).
///
/// The inbox was a memory-only queue. A tap that arrived and was not drained
/// before the process ended (a launch that crashed before the dashboard bound,
/// an alarm button pressed in a background launch that iOS then suspended) was
/// lost: the card stayed open and the buzzing carried on for work the student
/// had said was handed in. Each test here that says "relaunch" builds a second
/// inbox over the same scratch defaults suite, which is all a new process has
/// of the first one.
///
/// Every inbox gets its own scratch suite. The shared domain is never touched:
/// a pending tap written there would be read by another suite's inbox.
struct PendingTapPersistenceTests {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private func date(_ secondsAfterT0: TimeInterval) -> Date { t0.addingTimeInterval(secondsAfterT0) }

    private let page = "https://canvas.upenn.edu/courses/1/assignments/2"

    /// A scratch defaults suite for the length of `body`.
    @MainActor
    private func withScratchDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "lhf.pending-taps.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    // MARK: Surviving a kill

    @MainActor
    @Test("a tap that was never drained is waiting for the next process, in the order it arrived")
    func undrainedTapsSurviveARelaunch() {
        withScratchDefaults { defaults in
            let first = NotificationActionInbox(defaults: defaults)
            first.deposit(.turnedIn("canvas:a"), arrivedAt: date(0))
            first.deposit(.turnedIn("canvas:b"), arrivedAt: date(1))
            // The process dies here: nothing drained.

            let relaunched = NotificationActionInbox(defaults: defaults)
            #expect(relaunched.queue.map(\.action) == [.turnedIn("canvas:a"), .turnedIn("canvas:b")])
            #expect(relaunched.queue.map(\.arrivedAt) == [date(0), date(1)], "stamped when it was tapped, not when it was found")
            #expect(relaunched.drain(isDashboardBound: true, now: date(500))
                    == [.turnedIn("canvas:a"), .turnedIn("canvas:b")],
                    "and a turned-in tap is acted on whatever its age")
        }
    }

    @MainActor
    @Test("draining takes the taps off disk with them, so a relaunch cannot act on them twice")
    func drainClearsThePersistedCopy() {
        withScratchDefaults { defaults in
            let inbox = NotificationActionInbox(defaults: defaults)
            inbox.deposit(.turnedIn("canvas:a"), arrivedAt: date(0))
            #expect(defaults.data(forKey: NotificationActionInbox.persistedTapsKey) != nil)

            #expect(inbox.drain(isDashboardBound: true, now: date(1)) == [.turnedIn("canvas:a")])
            #expect(defaults.data(forKey: NotificationActionInbox.persistedTapsKey) == nil, "nothing left behind")
            #expect(NotificationActionInbox(defaults: defaults).queue.isEmpty)
        }
    }

    @MainActor
    @Test("an undrained inbox, asked before the dashboard is bound, keeps its taps on disk as well")
    func unboundDrainLeavesDiskAlone() {
        withScratchDefaults { defaults in
            let inbox = NotificationActionInbox(defaults: defaults)
            inbox.deposit(.turnedIn("canvas:a"), arrivedAt: date(0))

            #expect(inbox.drain(isDashboardBound: false, now: date(1)).isEmpty)
            #expect(NotificationActionInbox(defaults: defaults).queue.map(\.action) == [.turnedIn("canvas:a")])
        }
    }

    @MainActor
    @Test("an \"open this page\" is not kept: it is a courtesy that expires, and it carries a URL")
    func openTapsAreNotPersisted() throws {
        let url = try #require(URL(string: page))
        try withScratchDefaults { defaults in
            let inbox = NotificationActionInbox(defaults: defaults)
            inbox.deposit(.open(url), arrivedAt: date(0))
            inbox.deposit(.turnedIn("canvas:a"), arrivedAt: date(1))
            #expect(inbox.queue.count == 2, "both are queued in this process")

            let relaunched = NotificationActionInbox(defaults: defaults)
            #expect(relaunched.queue.map(\.action) == [.turnedIn("canvas:a")])
            let raw = try #require(defaults.data(forKey: NotificationActionInbox.persistedTapsKey))
            #expect(!String(decoding: raw, as: UTF8.self).contains("canvas.upenn.edu"), "no page URL in defaults")
        }
    }

    @MainActor
    @Test("a stored list that cannot be read is ignored, not fatal")
    func garbageIsIgnored() {
        withScratchDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: NotificationActionInbox.persistedTapsKey)
            let inbox = NotificationActionInbox(defaults: defaults)
            #expect(inbox.queue.isEmpty)
            inbox.deposit(.turnedIn("canvas:a"), arrivedAt: date(0))
            #expect(NotificationActionInbox(defaults: defaults).queue.map(\.action) == [.turnedIn("canvas:a")],
                    "the next tap overwrites the bad value")
        }
    }

    // MARK: Foreground

    @MainActor
    @Test("looking again picks up a tap another process wrote, without duplicating the ones already queued")
    func refreshTakesInWhatIsNew() {
        withScratchDefaults { defaults in
            let inbox = NotificationActionInbox(defaults: defaults)
            inbox.deposit(.turnedIn("canvas:a"), arrivedAt: date(0))

            // Another process of the same app group records one, then this one
            // writes its own: the file holds both, as a shared list would.
            let other = NotificationActionInbox(defaults: defaults)
            other.deposit(.turnedIn("canvas:b"), arrivedAt: date(5))
            #expect(other.queue.map(\.action) == [.turnedIn("canvas:a"), .turnedIn("canvas:b")])

            inbox.refreshFromDisk()
            #expect(inbox.queue.map(\.action) == [.turnedIn("canvas:a"), .turnedIn("canvas:b")])

            inbox.refreshFromDisk()
            #expect(inbox.queue.count == 2, "a second look finds nothing new")
        }
    }

    @MainActor
    @Test("looking again leaves an in-memory \"open\" where it is")
    func refreshKeepsMemoryOnlyActions() throws {
        let url = try #require(URL(string: page))
        withScratchDefaults { defaults in
            let inbox = NotificationActionInbox(defaults: defaults)
            inbox.deposit(.open(url), arrivedAt: date(0))
            inbox.deposit(.turnedIn("canvas:a"), arrivedAt: date(1))
            inbox.refreshFromDisk()
            #expect(inbox.queue.map(\.action) == [.open(url), .turnedIn("canvas:a")])
        }
    }

    // MARK: The router's own path

    @MainActor
    @Test("an alarm's \"turned in\" press is kept for the next process; its \"stop\" queues nothing")
    func alarmPressesAreKept() throws {
        try withScratchDefaults { defaults in
            let inbox = NotificationActionInbox(defaults: defaults)

            let turnedIn = NotificationResponseRouter.receiveAlarmAction(
                .turnedIn, assignmentID: "canvas:a", url: page, into: inbox, at: date(0))
            #expect(turnedIn)
            #expect(NotificationActionInbox(defaults: defaults).queue.map(\.action) == [.turnedIn("canvas:a")])

            let stop = NotificationResponseRouter.receiveAlarmAction(
                .stop, assignmentID: "canvas:a", url: "", into: inbox, at: date(1))
            #expect(!stop)
        }
    }

    // MARK: A throwaway inbox stays in memory

    @MainActor
    @Test("an inbox built without defaults keeps nothing between instances")
    func memoryOnlyInboxWritesNothing() {
        let inbox = NotificationActionInbox()
        inbox.deposit(.turnedIn("canvas:a"), arrivedAt: date(0))
        #expect(NotificationActionInbox().queue.isEmpty)
        _ = inbox.drain(isDashboardBound: true, now: date(1))
    }

    // MARK: Where it is wired (source structure)

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)   // .../Tests/LowHangingFruitKitTests/<this>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/LowHangingFruitUI/\(name)")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.path) is not there, so nothing could be checked")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the app's shared inbox is the persisting one, and a test run's is not")
    func sharedInboxPersistsOutsideTests() throws {
        let flat = try source("NotificationResponseRouter.swift")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        #expect(flat.contains("static let shared = NotificationActionInbox( defaults: SharedDefaults.isTestRunner ? nil : .lhf,"),
                "the shared inbox must persist, or a lock-screen tap is lost with its process")
    }
}
