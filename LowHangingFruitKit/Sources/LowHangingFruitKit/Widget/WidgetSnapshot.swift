import Foundation

/// Shared constants for the App Group bridge between the main app and the
/// widget extension. Both processes read this file (via LowHangingFruitKit),
/// so it's the single source of truth for the group id and snapshot filename.
public enum WidgetSharing {
    public static let appGroupID = "group.com.lhf.lowhangingfruit"
    static let snapshotFilename = "widget-snapshot.json"
}

/// One row of the widget's "next due" list. Deliberately a small subset of
/// `Assignment` — just enough to render a widget, so the JSON blob stays
/// cheap to write on every dashboard rebuild and cheap to read on every
/// widget timeline refresh.
public struct WidgetItem: Codable, Hashable, Sendable {
    public let title: String
    public let course: String
    public let dueAt: Date?

    public init(title: String, course: String, dueAt: Date?) {
        self.title = title
        self.course = course
        self.dueAt = dueAt
    }
}

/// The full payload the app writes and the widget reads. `generatedAt` lets a
/// future version show "as of" staleness if a refresh silently fails.
public struct WidgetSnapshot: Codable, Hashable, Sendable {
    public let items: [WidgetItem]
    public let generatedAt: Date

    public init(items: [WidgetItem], generatedAt: Date) {
        self.items = items
        self.generatedAt = generatedAt
    }

    public static let empty = WidgetSnapshot(items: [], generatedAt: .distantPast)
}

/// Reads and writes the widget snapshot to the shared App Group container.
/// Every operation is nil-safe / non-throwing by design: the widget extension
/// runs as a separate process and must never crash because the app hasn't
/// written yet, the App Group isn't configured, or the file is briefly mid-write.
public enum WidgetSnapshotStore {
    private static func fileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetSharing.appGroupID)?
            .appendingPathComponent(WidgetSharing.snapshotFilename)
    }

    /// Writes the snapshot atomically. Silently does nothing if the App Group
    /// container is unavailable or encoding fails — the widget just keeps
    /// showing its last-known (or empty) state.
    public static func write(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL() else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Reads the last-written snapshot, or nil if none exists yet, the App
    /// Group isn't configured, or the file can't be decoded.
    public static func read() -> WidgetSnapshot? {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }
}

/// The widget's own copy of the app's due-date urgency banding. Intentionally
/// duplicated (not shared code) — the widget extension target can't import
/// LowHangingFruitUI, so these thresholds and colors are kept in sync BY HAND
/// with `DueState` in RedesignTokens.swift. If those thresholds change, update
/// both.
public enum WidgetUrgency: String, Codable, Sendable {
    case overdue
    case today
    case soon
    case later

    public init(due: Date?, now: Date = Date()) {
        guard let due else { self = .later; return }
        let s = due.timeIntervalSince(now)
        if s < 0 { self = .overdue }
        else if s < 86_400 { self = .today }
        else if s < 86_400 * 4 { self = .soon }
        else { self = .later }
    }

    /// Matches the app's urgency spine palette (overdue/today/soon/later) on a
    /// light background. Kept in sync with RedesignTokens' `v2Spine*` light values.
    public var spineHex: UInt32 {
        switch self {
        case .overdue: return 0xC8443A
        case .today: return 0xD98C2B
        case .soon: return 0x3A6EA5
        case .later: return 0x2E7D6B
        }
    }

    /// The brightened spine colors for a dark background — matches the tokens'
    /// `v2Spine*` dark values so the widget's dark mode agrees with the app.
    public var spineHexDark: UInt32 {
        switch self {
        case .overdue: return 0xE5675C
        case .today: return 0xE8A34A
        case .soon: return 0x6B9BD1
        case .later: return 0x4CA891
        }
    }

    public var emoji: String {
        switch self {
        case .overdue: return "🔴"
        case .today: return "🟠"
        case .soon: return "🔵"
        case .later: return "🟢"
        }
    }
}
