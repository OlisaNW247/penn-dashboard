import Foundation

/// Shared constants for the App Group bridge between the main app and the
/// widget extension. Both processes read this file (via LowHangingFruitKit),
/// so it's the single source of truth for the group id and snapshot filename.
public enum WidgetSharing {
    /// The identifier iOS uses, and the one every entitlement carried before
    /// the Mac App Store build existed.
    static let bareAppGroupID = "group.com.lhf.lowhangingfruit"

    /// macOS requires an app group to begin with the team identifier. A
    /// sandboxed Mac app — which is what the Mac App Store demands — can only
    /// open the prefixed container; ask it for the bare id and it hands back
    /// nil, at which point the ledger silently degrades to memory and looks
    /// completely normal until a relaunch loses everything.
    ///
    /// The team id is the same one `project.yml` sets as `DEVELOPMENT_TEAM`.
    static let teamPrefixedAppGroupID = "24A3TDB277.group.com.lhf.lowhangingfruit"

    /// Which identifier this process should use.
    ///
    /// Pure and injectable because the interesting cases can't be reproduced on
    /// a dev Mac: the real inputs are a sandbox marker and a container probe.
    ///
    /// The sandbox check is doing load-bearing work. Probing the container
    /// alone cannot tell the two builds apart — an UNSANDBOXED macOS process
    /// resolves a container for practically any group id it asks about, with or
    /// without the entitlement (the same quirk `SharedDefaults.isTestRunner`
    /// exists to defend against). So an unsandboxed dev build would "resolve"
    /// the prefixed container too, silently move off the ledger it has been
    /// writing to, and read as data loss. Only a sandboxed process is offered
    /// the prefixed id at all.
    static func resolveAppGroupID(
        isTestRunner: Bool,
        isSandboxed: Bool,
        prefixedContainerResolves: () -> Bool
    ) -> String {
        // A test runner must never reach a real container — see
        // `SharedDefaults.isTestRunner` for what that cost us once already.
        guard !isTestRunner else { return bareAppGroupID }
        guard isSandboxed else { return bareAppGroupID }
        return prefixedContainerResolves() ? teamPrefixedAppGroupID : bareAppGroupID
    }

    #if os(macOS)
    /// Resolved once per process: the answer can't change while the app runs,
    /// and this sits on the path of every ledger and defaults read.
    public static let appGroupID: String = resolveAppGroupID(
        isTestRunner: SharedDefaults.isTestRunner,
        // Set by the system for every sandboxed macOS process, and absent
        // otherwise.
        isSandboxed: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
        prefixedContainerResolves: {
            FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: teamPrefixedAppGroupID) != nil
        }
    )
    #else
    public static let appGroupID = bareAppGroupID
    #endif

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
        // Test runners resolve the container on macOS despite having no
        // entitlement (see `SharedDefaults.isTestRunner`) — never let a test
        // overwrite the real widget's snapshot file.
        guard !SharedDefaults.isTestRunner else { return nil }
        return FileManager.default
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

    /// Matches the app's urgency spine palette (overdue/today/soon/later).
    public var spineHex: UInt32 {
        switch self {
        case .overdue: return 0xC8443A
        case .today: return 0xD98C2B
        case .soon: return 0x3A6EA5
        case .later: return 0x2E7D6B
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
