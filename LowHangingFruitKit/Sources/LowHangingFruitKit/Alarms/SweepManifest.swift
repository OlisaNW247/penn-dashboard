import Foundation

/// What the app tells the Sweeper's notification extension about the alarms it
/// has armed. After a force-quit nothing in the app runs, so the extension (a
/// separate process, woken by the server's content-free alert push at ring - 15
/// min and ring - 3 min) has only this file to know which alarms exist, which
/// Canvas assignment each belongs to, and which pending requests to remove when
/// the work turns out to be handed in. The app rewrites it whenever it arms or
/// cancels; the extension only reads it.
public struct SweepManifest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    /// The pushes arrive at ring - 15 and ring - 3 minutes. An entry is "near"
    /// from 2 minutes after its ring time (a late delivery, or a phone clock a
    /// little ahead of the server's) to 20 minutes before it (the early push
    /// plus slack for the other direction of drift).
    public static let lookBehind: TimeInterval = 2 * 60
    public static let lookAhead: TimeInterval = 20 * 60

    public struct Entry: Codable, Sendable, Equatable, Hashable {
        /// The app's `Assignment.id`, which the inbox hands back to the ledger.
        public let itemID: String
        /// Planner reads are keyed by this; nil means the extension can never
        /// confirm the work and must leave the alarm alone.
        public let canvasAssignmentID: String?
        public let title: String
        /// The ring time.
        public let fireDate: Date
        public let alarmIDs: [UUID]
        public let requestIDs: [String]
        /// A DEBUG test hook: a probe entry is treated as submitted when the
        /// build honours probes, so the cancel path can be exercised on a
        /// phone without handing in real work.
        public let probe: Bool

        public init(itemID: String, canvasAssignmentID: String?, title: String, fireDate: Date,
                    alarmIDs: [UUID], requestIDs: [String], probe: Bool = false) {
            self.itemID = itemID
            self.canvasAssignmentID = canvasAssignmentID
            self.title = title
            self.fireDate = fireDate
            self.alarmIDs = alarmIDs
            self.requestIDs = requestIDs
            self.probe = probe
        }

        /// `probe` reads as false when the key is missing: a manifest written
        /// by a build that did not know the field must not fail to decode.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            itemID = try c.decode(String.self, forKey: .itemID)
            canvasAssignmentID = try c.decodeIfPresent(String.self, forKey: .canvasAssignmentID)
            title = try c.decode(String.self, forKey: .title)
            fireDate = try c.decode(Date.self, forKey: .fireDate)
            alarmIDs = try c.decode([UUID].self, forKey: .alarmIDs)
            requestIDs = try c.decode([String].self, forKey: .requestIDs)
            probe = try c.decodeIfPresent(Bool.self, forKey: .probe) ?? false
        }
    }

    public let version: Int
    public let writtenAt: Date
    public let canvasBaseURL: URL
    public let entries: [Entry]

    public init(version: Int = SweepManifest.currentVersion, writtenAt: Date, canvasBaseURL: URL, entries: [Entry]) {
        self.version = version
        self.writtenAt = writtenAt
        self.canvasBaseURL = canvasBaseURL
        self.entries = entries
    }

    /// Entries whose ring time is within `[now - lookBehind, now + lookAhead]`.
    public func entries(near now: Date) -> [Entry] {
        let lower = now.addingTimeInterval(-Self.lookBehind)
        let upper = now.addingTimeInterval(Self.lookAhead)
        return entries.filter { $0.fireDate >= lower && $0.fireDate <= upper }
    }
}
