import Foundation

/// The record that makes a second Canvas submission of the same draft
/// impossible (docs/AGENT_CONNECTION_PLAN_V11_2026-11-07.md, "The card": "An
/// attempt row is written before the POST").
///
/// **The rule.** `begin` is called before the first POST to Canvas, and the
/// POST does not go out unless it returned. Once a draft has a record it is
/// never submitted again, whatever the server, the network or a relaunch
/// says afterwards. That includes a definite failure: the draft is then
/// marked `failed` on the server and the student asks the agent for a new
/// one. Re-submitting a "failed" draft would be safe in theory (Canvas said
/// no), but a rule with exceptions is a rule that eventually double-submits
/// someone's work, and the agent can always write another draft.
///
/// **Why its own file, not the ledger or defaults.** The ledger's schema is
/// not where a new model goes (CLAUDE.md, Traps: "A new SwiftData model goes
/// in its own store file"), and `UserDefaults` writes reach disk on the
/// system's schedule, not before `set` returns: a process killed in the
/// second between the write and the POST could come back with no record and
/// a submission in Canvas. A small JSON file written `.atomic` is on disk
/// when `begin` returns. It lives under Application Support, not the App
/// Group: nothing outside the app process reads it.
///
/// It holds draft ids, assignment ids, dates, the outcome word and Canvas's
/// submission id: no content, no cookie, no token.
public final class AgentSubmitAttemptStore: @unchecked Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// Canvas created the submission.
        case submitted
        /// Canvas definitely created nothing.
        case failed
        /// A POST went out and the answer never came: check Canvas.
        case indeterminate
    }

    public struct Record: Codable, Equatable, Sendable {
        public var draftID: String
        public var assignmentID: String
        public var startedAt: Date
        public var outcome: Outcome?
        public var canvasSubmissionID: String?
        public var attempt: Int?
        public var errorClass: String?
        /// The server acknowledged the outcome (`draft` answered, or said the
        /// draft is already decided). Until then the drafts pass re-sends the
        /// status report: a report retry, never a submission retry.
        public var reported: Bool
    }

    public enum StoreError: Error, Equatable {
        case alreadyAttempted
        case writeFailed
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Application Support/Smooth/agent-submit-attempts.json, or a scratch
    /// directory under the test runner (an unsandboxed `swift test` would
    /// otherwise write into the real Mac app's folder; CLAUDE.md, Traps).
    public static func makeDefault() -> AgentSubmitAttemptStore {
        let fm = FileManager.default
        let base: URL
        if SharedDefaults.isTestRunner {
            base = fm.temporaryDirectory.appendingPathComponent("LHFTestAttempts-\(UUID().uuidString)", isDirectory: true)
        } else {
            base = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory)
                .appendingPathComponent("Smooth", isDirectory: true)
        }
        return AgentSubmitAttemptStore(fileURL: base.appendingPathComponent("agent-submit-attempts.json"))
    }

    public func record(for draftID: String) -> Record? {
        lock.lock(); defer { lock.unlock() }
        return readAll()[draftID]
    }

    public func all() -> [Record] {
        lock.lock(); defer { lock.unlock() }
        return Array(readAll().values)
    }

    /// Writes the record, on disk, or throws. Throws `alreadyAttempted` when
    /// the draft has one, which is the never-twice rule's teeth.
    public func begin(draftID: String, assignmentID: String, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        // An unreadable file is not an empty one: it may hold this draft's
        // record, so nothing is submitted until it reads again.
        guard var records = readAllStrict() else { throw StoreError.writeFailed }
        guard records[draftID] == nil else { throw StoreError.alreadyAttempted }
        records[draftID] = Record(draftID: draftID, assignmentID: assignmentID, startedAt: now,
                                  outcome: nil, canvasSubmissionID: nil, attempt: nil,
                                  errorClass: nil, reported: false)
        guard write(records) else { throw StoreError.writeFailed }
    }

    /// Records what happened. Never removes the record.
    public func finish(draftID: String, outcome: Outcome, canvasSubmissionID: String? = nil,
                       attempt: Int? = nil, errorClass: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var records = readAll()
        guard var record = records[draftID] else { return }
        record.outcome = outcome
        record.canvasSubmissionID = canvasSubmissionID
        record.attempt = attempt
        record.errorClass = errorClass
        records[draftID] = record
        _ = write(records)
    }

    public func markReported(draftID: String) {
        lock.lock(); defer { lock.unlock() }
        var records = readAll()
        guard records[draftID] != nil else { return }
        records[draftID]?.reported = true
        _ = write(records)
    }

    /// Disconnecting Canvas: the server deletes every draft at the same time,
    /// so there is nothing left these records could protect.
    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: File

    private func readAll() -> [String: Record] { readAllStrict() ?? [:] }

    /// Nil when the file exists and cannot be read or decoded; empty when
    /// there is no file at all.
    private func readAllStrict() -> [String: Record]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode([String: Record].self, from: data)
    }

    private func write(_ records: [String: Record]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records) else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: fileURL, options: [.atomic])
            #endif
            return true
        } catch {
            return false
        }
    }
}
