import Foundation

/// The device test's readout for the force-quit check: the last 50 lines, in
/// the App Group's defaults, written by the notification extension and the
/// widget (both separate processes) and read back with `devicectl`. Callers
/// compile it into DEBUG builds only. A line holds counts, flags and times,
/// never a cookie name or value and never a title.
public enum SweepDebugLog {
    public static let key = "debugSweepCheckLogV1"
    public static let limit = 50

    public static func append(_ line: String, now: Date = Date(), defaults: UserDefaults? = nil) {
        guard !SharedDefaults.isTestRunner || defaults != nil else { return }
        guard let defaults = defaults ?? UserDefaults(suiteName: WidgetSharing.appGroupID) else { return }
        var lines = defaults.stringArray(forKey: key) ?? []
        lines.append("\(ISO8601DateFormatter().string(from: now)) \(line)")
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        defaults.set(lines, forKey: key)
    }
}
