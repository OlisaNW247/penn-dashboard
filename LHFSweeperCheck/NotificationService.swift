import Foundation
import UserNotifications
import LowHangingFruitKit
#if canImport(AlarmKit)
import AlarmKit
#endif

// The Sweeper's force-quit check. The server sends a content-free alert push
// shortly before each ring (`lhf: "sweep"`, `mutable-content: 1`); iOS runs
// this extension for it even when the app was force-quit. It reads the manifest
// the app left in the App Group, asks Canvas's planner with the cookies the app
// mirrored into the shared Keychain, cancels the alarms of work that is handed
// in, and rewrites the notification text.
//
// Rule that outranks every other here: an unknown never cancels anything. No
// cookies, a network failure, a planner answer that is not complete, an item
// the planner did not list: every one of these leaves the alarm armed
// (`SweepCheck`). Nothing may make the Sweeper quieter by accident.
//
// Isolation: nothing in this file is main-actor isolated, deliberately. The
// extension's callbacks arrive on its own queue, and Swift 6 checks a
// main-actor closure's isolation at run time, so one that slipped in would
// kill the process on entry (CLAUDE.md, the `decidedText` and background-
// refresh traps).

/// Hands the content to iOS exactly once, whichever of the check finishing and
/// `serviceExtensionTimeWillExpire` gets there first.
private final class OnceDeliverer: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?

    init(_ handler: @escaping (UNNotificationContent) -> Void) { self.handler = handler }

    func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let h = handler
        handler = nil
        lock.unlock()
        h?(content)
    }
}

private struct ContentBox: @unchecked Sendable {
    let content: UNNotificationContent
}

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var deliverer: OnceDeliverer?
    private var original: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let content = request.content
        let deliverer = OnceDeliverer(contentHandler)
        lock.lock()
        self.deliverer = deliverer
        self.original = content
        lock.unlock()

        guard content.userInfo["lhf"] as? String == "sweep" else {
            deliverer.deliver(content)
            return
        }
        let box = ContentBox(content: content)
        Task.detached {
            let result = await Self.check(original: box.content, now: Date())
            deliverer.deliver(result)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let d = deliverer
        let c = original
        lock.unlock()
        if let c { d?.deliver(c) }
    }

    // MARK: The check

    private static func check(original: UNNotificationContent, now: Date) async -> UNNotificationContent {
        let started = Date()
        guard let manifest = SweepFiles.loadManifest() else {
            log("manifest missing", now: now)
            return original
        }
        let entries = manifest.entries(near: now)
        guard !entries.isEmpty else {
            log("entries 0 of \(manifest.entries.count)", now: now)
            return original
        }

        // 2. Cookies. None means no read was possible: every entry unknown.
        let cookies = SweepCookieMirror.load(host: manifest.canvasBaseURL.host ?? "")
        var reads: [SubmissionRead]?
        var plannerNote = "planner skipped"
        if !cookies.isEmpty {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 18
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            let client = CanvasStructuredSourcesClient(
                baseURL: manifest.canvasBaseURL, cookies: cookies, session: URLSession(configuration: config))
            let window = LastHourPoll.window(now: now)
            let result = await client.fetchPlannerWindow(start: window.start, end: window.end)
            plannerNote = "completed \(result.completed) rateLimited \(result.rateLimited) "
                + "sessionExpired \(result.sessionExpired) items \(result.items.count)"
            // The app's own rule (`applyPlannerWindow`): an incomplete answer
            // is believed in nothing, not even its submitted items.
            if result.completed && !result.rateLimited && !result.sessionExpired {
                reads = SubmissionRead.verdicts(fromPlanner: result.items, readAt: now)
            }
        }

        #if DEBUG
        let honourProbe = true
        #else
        let honourProbe = false
        #endif
        let outcome = SweepCheck.decide(entries: entries, reads: reads, honourProbe: honourProbe)

        var alarmNote = "alarmkit n/a"
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), !outcome.alarmIDsToCancel.isEmpty {
            alarmNote = cancelAlarms(outcome.alarmIDsToCancel)
        }
        #endif

        if !outcome.requestIDsToRemove.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: outcome.requestIDsToRemove)
        }

        if !outcome.submitted.isEmpty {
            SweepFiles.appendToInbox(outcome.submitted.map {
                SweepInbox.Record(itemID: $0.itemID, canvasAssignmentID: $0.canvasAssignmentID, at: now)
            })
        }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log("entries \(entries.count) cookies \(!cookies.isEmpty) \(plannerNote) | submitted \(outcome.submitted.count) "
            + "unsubmitted \(outcome.unsubmitted.count) unknown \(outcome.unknown.count) | "
            + "cancel ids \(outcome.alarmIDsToCancel.count) \(alarmNote) | removed requests "
            + "\(outcome.requestIDsToRemove.count) | \(ms) ms", now: now)

        guard let mutable = original.mutableCopy() as? UNMutableNotificationContent else { return original }
        if let body = outcome.body { mutable.body = body }
        mutable.interruptionLevel = .passive
        return mutable
    }

    #if canImport(AlarmKit)
    /// The same pair the app's own stop uses (`BerserkAlarmScheduler+Alerting`):
    /// stop a ringing alarm, then cancel it so it is not left in the list.
    /// The cancel's error is kept, because whether an extension may do this at
    /// all is the thing the device test exists to find out.
    @available(iOS 26.0, *)
    private static func cancelAlarms(_ ids: Set<UUID>) -> String {
        // `ids` is every id the item could have been armed under (each lead
        // time and sound), and at most one or two of them exist. Cancelling
        // the rest would log a not-found error per id and bury the one error
        // the device test is looking for (an extension refused outright), so
        // only the ids AlarmKit says it holds are cancelled. If reading the
        // list itself fails, every id is tried: a refusal must still show.
        let held = try? Set(AlarmManager.shared.alarms.map(\.id)).intersection(ids)
        let before = held.map { String($0.count) } ?? "err"
        var errors = Set<String>()
        for id in held ?? ids {
            try? AlarmManager.shared.stop(id: id)
            do { try AlarmManager.shared.cancel(id: id) } catch { errors.insert(String(describing: error)) }
        }
        let after = (try? AlarmManager.shared.alarms.map(\.id).filter(ids.contains).count).map(String.init) ?? "err"
        return "cancels \(ids.count) held before \(before) after \(after)"
            + (errors.isEmpty ? "" : " errors \(errors.joined(separator: "; "))")
    }
    #endif

    private static func log(_ line: String, now: Date) {
        #if DEBUG
        SweepDebugLog.append("extension \(line)", now: now)
        #endif
    }
}
