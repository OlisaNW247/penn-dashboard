import Foundation

/// JSON files in the App Group container through which the app and the
/// Sweeper's notification extension talk. Nothing throws to the caller: the
/// extension must never crash because the app has not written yet, and a
/// missing or corrupt file simply reads as nil / empty.
///
/// Under `SharedDefaults.isTestRunner` the default directory is nil, because
/// an unsandboxed macOS test run resolves the App Group container without the
/// entitlement and would otherwise write into the real Mac app's container
/// (see the widget snapshot store, which guards the same way). Tests pass a
/// temporary directory explicitly.
public enum SweepFiles {
    public static let manifestFilename = "sweeper-manifest-v1.json"
    public static let inboxFilename = "sweeper-inbox-v1.json"

    public static func defaultDirectory() -> URL? {
        guard !SharedDefaults.isTestRunner else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetSharing.appGroupID)
    }

    // MARK: Manifest

    public static func loadManifest(in directory: URL? = defaultDirectory()) -> SweepManifest? {
        read(SweepManifest.self, named: manifestFilename, in: directory)
    }

    @discardableResult
    public static func saveManifest(_ manifest: SweepManifest, in directory: URL? = defaultDirectory()) -> Bool {
        write(manifest, named: manifestFilename, in: directory)
    }

    public static func deleteManifest(in directory: URL? = defaultDirectory()) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(manifestFilename))
    }

    // MARK: Inbox

    public static func loadInbox(in directory: URL? = defaultDirectory()) -> SweepInbox {
        read(SweepInbox.self, named: inboxFilename, in: directory) ?? SweepInbox()
    }

    @discardableResult
    public static func appendToInbox(_ records: [SweepInbox.Record], in directory: URL? = defaultDirectory()) -> Bool {
        guard directory != nil else { return false }
        return write(loadInbox(in: directory).appending(records), named: inboxFilename, in: directory)
    }

    /// Returns the inbox and removes it, by renaming the file to a private
    /// name first and reading that. Rename is atomic, so a record appended
    /// during the drain either lands in the file before the rename (and is
    /// drained) or creates a fresh file afterwards (and waits for the next
    /// drain); load-then-remove would lose one appended in between. Chosen over
    /// `NSFileCoordinator` because it needs no cooperation from the extension
    /// side and cannot block either process. The one remaining window is two
    /// appenders racing each other (a read-modify-write), which is the
    /// extension alone: it runs one check at a time per push, and a lost append
    /// only means the app reads Canvas itself on its next sync.
    public static func drainInbox(in directory: URL? = defaultDirectory()) -> SweepInbox {
        guard let directory else { return SweepInbox() }
        let live = directory.appendingPathComponent(inboxFilename)
        let taken = directory.appendingPathComponent("\(inboxFilename).draining-\(UUID().uuidString)")
        guard (try? FileManager.default.moveItem(at: live, to: taken)) != nil else { return SweepInbox() }
        defer { try? FileManager.default.removeItem(at: taken) }
        guard let data = try? Data(contentsOf: taken),
              let inbox = try? decoder().decode(SweepInbox.self, from: data) else { return SweepInbox() }
        return inbox
    }

    // MARK: Plumbing

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func read<T: Decodable>(_ type: T.Type, named name: String, in directory: URL?) -> T? {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? decoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, named name: String, in directory: URL?) -> Bool {
        guard let directory, let data = try? encoder().encode(value) else { return false }
        return (try? data.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil
    }
}
