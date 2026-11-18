import Foundation

/// Where a check for a submission started. A fixed set, so a line can never
/// carry anything else.
enum WakeSource: String, Sendable {
    case foreground, launch, poll, bg, push, grades, gradescope, structured
}

#if DEBUG
/// Owner-only trail of Sweeper wakes and checks, modelled on
/// `DebugRenewalLog`: capped at 50 lines in `UserDefaults.lhf`
/// (`debugWakeLogV1`), read off a phone with `devicectl`. One line is time,
/// source, outcome, milliseconds and two counts. `outcome` is a static word
/// from a fixed set the caller owns; it is never a title, id or URL, and this
/// file never interpolates one. The defaults domain is a parameter so a test
/// can write to a scratch suite and never to the shared one (the
/// shared-defaults trap).
enum DebugWakeLog {
    static let key = "debugWakeLogV1"
    static let cap = 50

    static func record(
        source: WakeSource, outcome: String, duration: TimeInterval,
        cancelledRequests: Int, cancelledAlarms: Int,
        defaults: UserDefaults = .lhf, now: Date = Date()
    ) {
        let ms = Int((duration * 1000).rounded())
        let line = "\(iso.string(from: now)) \(source.rawValue) \(outcome) \(ms)ms cancelled \(cancelledRequests) request(s) \(cancelledAlarms) alarm(s)"
        var entries = defaults.stringArray(forKey: key) ?? []
        entries.append(line)
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
        defaults.set(entries, forKey: key)
    }

    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
}
#endif

/// Plain counts of what the Sweeper did, kept in `UserDefaults.lhf`
/// (`sweeperCountsV1`) in Release and DEBUG alike. Counts only: no id, title
/// or URL can reach it because every key is one of the names below.
enum SweeperCounts {
    static let storeKey = "sweeperCountsV1"
    static let armed = "armed"
    static let cancelledAtObservation = "cancelledAtObservation"
    static let readsUnknown = "readsUnknown"
    static let polls = "polls"
    static let pollsBackedOff = "pollsBackedOff"
    static let wakesBG = "wakesBG"
    static let wakesPush = "wakesPush"
    static let momentsSent = "momentsSent"

    /// "cancelledAtObservation.<source>", where source is a `WakeSource` word
    /// or "grades" / "gradescope".
    static func cancelledKey(_ source: String) -> String { "\(cancelledAtObservation).\(source)" }

    static func increment(_ key: String, by amount: Int = 1, defaults: UserDefaults = .lhf) {
        var counts = snapshot(defaults: defaults)
        counts[key, default: 0] += amount
        defaults.set(counts, forKey: storeKey)
    }

    static func snapshot(defaults: UserDefaults = .lhf) -> [String: Int] {
        (defaults.dictionary(forKey: storeKey) as? [String: Int]) ?? [:]
    }
}
