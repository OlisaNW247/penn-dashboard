import Foundation

/// The student's sample course load, as one JSON file in Application Support
/// beside `degree-audit.json` (`DegreeAuditStore`, whose shape this copies).
///
/// It differs from the audit's file in one way that matters. The audit is
/// Penn's and can be read again at any time, so that file is kept out of
/// backups. This one is something the student typed and Penn cannot give back:
/// excluding it from backup would mean a new phone restored from a backup comes
/// up without the plan they spent an evening on. So it is NOT excluded. It does
/// keep the same iOS file protection, because a course list is still the
/// student's own record. It is never put in iCloud sync, the App Group, the
/// laptop sync or the backend.
///
/// No dates are stored (the plan holds term codes and course codes only), so
/// there is no date strategy to agree on with a reader.
public struct DegreePlanStore: Sendable {
    private static let fileName = "degree-plan.json"

    public let fileURL: URL

    public static func `default`() -> DegreePlanStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return DegreePlanStore(directory: base.appendingPathComponent("LowHangingFruit", isDirectory: true))
    }

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
    }

    /// A missing file is `.empty`. A file that is there but does not decode is
    /// moved aside to `degree-plan.json.corrupt-<unix>` (never overwritten, so
    /// a bad write can be looked at, and the student's words are not thrown
    /// away) and `.empty` is returned.
    public func load(now: Date = Date()) -> DegreePlan {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        if let plan = try? JSONDecoder().decode(DegreePlan.self, from: data) { return plan }
        let fileManager = FileManager.default
        let stamp = Int(now.timeIntervalSince1970)
        var destination = fileURL.appendingPathExtension("corrupt-\(stamp)")
        var attempt = 1
        while fileManager.fileExists(atPath: destination.path) {
            attempt += 1
            destination = fileURL.appendingPathExtension("corrupt-\(stamp)-\(attempt)")
        }
        try? fileManager.moveItem(at: fileURL, to: destination)
        return .empty
    }

    public func save(_ plan: DegreePlan) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(plan)
        try data.write(to: fileURL, options: .atomic)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path)
        #endif
    }

    /// Removes the file and any quarantined copies; disconnecting Canvas calls
    /// this through `clearDegreeData`, because the plan is part of the degree
    /// data that login unlocked.
    public func clear() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: fileURL)
        let directory = fileURL.deletingLastPathComponent()
        let prefix = Self.fileName + ".corrupt-"
        if let names = try? fileManager.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasPrefix(prefix) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}
