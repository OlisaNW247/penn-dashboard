import Foundation
import CryptoKit

/// The times at which the server may send the phone a silent push so that
/// Canvas is asked, from the phone's own session, whether Sweeper work was
/// handed in (docs/SERVER_SWEEPER_DESIGN_2026-11-17.md §1, §4).
///
/// **What leaves the phone is a list of instants and a hash of that list.** No
/// assignment id, title, class or URL: a moment is "fire time minus 15 minutes"
/// and "fire time minus 3 minutes" for each armed alarm, truncated down to the
/// whole minute in UTC. The alarm itself stays armed on the phone exactly as
/// before; a push only adds a time at which the phone's own read runs (Marco,
/// 2026-11-18), so this plan can be wrong or missing and nothing rings late.
///
/// The wrong fix is sending the alarms' fire dates themselves: that is the
/// schedule of what the student has not handed in, minus nothing, and the
/// server needs only the instants at which to knock.
public enum SweeperWakePlan {
    /// Two reads before each ring: one early enough to cancel a last-minute
    /// hand-in at leisure, one late enough to catch one made at the very end.
    public static let defaultOffsets: [TimeInterval] = [15 * 60, 3 * 60]
    public static let defaultHorizon: TimeInterval = 48 * 3600
    public static let defaultCap = 24

    /// `fireDates` are the alarms' ring instants. Buzz-only work (an external
    /// tool, a row with no Canvas id) has no alarm and so no moment here: a
    /// planner read could never cancel it anyway.
    /// Output: whole-minute UTC
    /// instants, strictly after `now`, at most `horizon` ahead, ascending,
    /// deduplicated, the nearest `cap` of them.
    public static func moments(
        fromFireDates fireDates: [Date], now: Date,
        horizon: TimeInterval = defaultHorizon, cap: Int = defaultCap,
        offsets: [TimeInterval] = defaultOffsets
    ) -> [Date] {
        var seen = Set<Int64>()
        var out: [Date] = []
        let limit = now.addingTimeInterval(horizon)
        for fire in fireDates {
            for offset in offsets {
                let raw = fire.timeIntervalSince1970 - offset
                let whole = Int64((raw / 60).rounded(.down)) * 60
                let moment = Date(timeIntervalSince1970: TimeInterval(whole))
                guard moment > now, moment <= limit, seen.insert(whole).inserted else { continue }
                out.append(moment)
            }
        }
        out.sort()
        return Array(out.prefix(max(0, cap)))
    }

    /// The first 16 lowercase hex characters of SHA-256 over the sorted ISO 8601
    /// strings joined by "|". Equal lists hash equal whatever order they came
    /// in; the server stores it only to tell "changed" from "same".
    public static func planHash(_ moments: [Date]) -> String {
        let text = moments.sorted().map(iso).joined(separator: "|")
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }

    /// `yyyy-MM-ddTHH:mm:ssZ`, UTC, POSIX locale: the wire form of a moment.
    public static func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }
}
