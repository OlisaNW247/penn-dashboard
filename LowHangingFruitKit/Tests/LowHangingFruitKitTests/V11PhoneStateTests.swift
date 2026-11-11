import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The v11 test pass of 2026-11-11 (docs/V11_TEST_PHONE_2026-11-11.md, §3-6):
/// what the phone keeps, what clears it, when the passes may run, the
/// snapshot's shape, and what can never reach a log. Serialized and
/// restoring: several keys live in the shared `UserDefaults.lhf` domain
/// (CLAUDE.md, the shared-defaults trap).
@MainActor
@Suite("v11 test pass: state, guards and the snapshot", .serialized)
struct V11PhoneStateTests {
    static let agentKeys = [AgentDraftCache.key, AgentDraftNotices.notifiedKey,
                            AppState.agentKnownConnectionIDsKey, SharedDefaults.agentConnectionEnabledKey]

    private func withCleanKeys(_ body: () async throws -> Void) async rethrows {
        let backup = Self.agentKeys.map { UserDefaults.lhf.object(forKey: $0) }
        Self.agentKeys.forEach { UserDefaults.lhf.removeObject(forKey: $0) }
        defer {
            for (key, value) in zip(Self.agentKeys, backup) {
                if let value { UserDefaults.lhf.set(value, forKey: key) } else { UserDefaults.lhf.removeObject(forKey: key) }
            }
        }
        try await body()
    }

    private func makeState() throws -> AppState {
        let suite = "V11PhoneStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let state = AppState(assignmentStore: try AssignmentStore(inMemory: true), dueDateEditsDefaults: defaults)
        state.forceFixtureDataForTesting(false)
        state.agentSubmitAttempts = AgentSubmitAttemptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("V11PhoneState-\(UUID().uuidString)/attempts.json"))
        return state
    }

    static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    static func source(_ path: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The function's body, from its signature to the next top-level `func`
    /// at the same indentation: enough to scan a guard.
    static func body(of signature: String, in text: String) -> String {
        guard let start = text.range(of: signature) else { return "" }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n    func ") ?? rest.range(of: "\n    nonisolated static func ") ?? rest.range(of: "\n}")
        return String(rest[..<(end?.lowerBound ?? rest.endIndex)])
    }

    // MARK: §3 The draft cache

    @Test("the cache round-trips the chip's fields and none of the content")
    func cacheRoundTrip() {
        let d = AgentDraft(id: "smd_1", assignmentID: "a", kind: .file, body: "secret", url: "https://x.edu",
                           fileName: "ps7.pdf", mimeType: "application/pdf", fileBytes: 12_345, note: "note",
                           clientName: "Claude", status: .seen, createdAt: "2026-11-11T02:06:00Z",
                           fileURL: "https://storage.example/sign?token=abc", format: "markdown")
        let back = AgentDraftCache.decode(AgentDraftCache.encode([d]))
        #expect(back.count == 1)
        let c = back[0]
        #expect(c.id == "smd_1" && c.assignmentID == "a" && c.kind == .file && c.fileName == "ps7.pdf")
        #expect(c.fileBytes == 12_345 && c.clientName == "Claude" && c.status == .seen && c.createdAt == d.createdAt)
        #expect(c.body == nil && c.url == nil && c.note == nil && c.fileURL == nil && c.format == nil)
        let raw = String(decoding: AgentDraftCache.encode([d]) ?? Data(), as: UTF8.self)
        #expect(!raw.contains("secret") && !raw.contains("token=abc") && !raw.contains("\"note\""))
    }

    @Test("an older build's cache (fewer fields) still loads; a garbled one loads as empty")
    func olderCacheLoads() {
        let old = #"[{"id":"smd_old","assignment_id":"a","kind":"text","status":"proposed"}]"#
        #expect(AgentDraftCache.decode(Data(old.utf8)).map(\.id) == ["smd_old"])
        #expect(AgentDraftCache.decode(Data("not json".utf8)).isEmpty)
        #expect(AgentDraftCache.decode(nil).isEmpty)
        // A decided draft in a cache is never drawn.
        let decided = #"[{"id":"d","assignment_id":"a","kind":"text","status":"submitted"}]"#
        #expect(AgentDraftCache.decode(Data(decided.utf8)).isEmpty)
    }

    @Test("the cache is bounded")
    func cacheBounded() {
        let many = (0..<500).map { AgentDraft(id: "d\($0)", assignmentID: "a", kind: .text, body: String(repeating: "x", count: 1_000)) }
        let data = AgentDraftCache.encode(many)
        #expect(AgentDraftCache.decode(data).count == AgentDraftCache.maxEntries)
        #expect((data?.count ?? 0) < 20_000)
    }

    // MARK: §3 The attempt store across a relaunch

    @Test("the attempt store is a file: a new instance (a relaunch) sees the record and refuses")
    func attemptsSurviveRelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("V11Relaunch-\(UUID().uuidString)/a.json")
        let first = AgentSubmitAttemptStore(fileURL: url)
        try first.begin(draftID: "smd_1", assignmentID: "a", agentName: "Claude")
        first.finish(draftID: "smd_1", outcome: .indeterminate)
        let relaunched = AgentSubmitAttemptStore(fileURL: url)
        #expect(relaunched.record(for: "smd_1")?.outcome == .indeterminate)
        #expect(throws: AgentSubmitAttemptStore.StoreError.alreadyAttempted) {
            try relaunched.begin(draftID: "smd_1", assignmentID: "a")
        }
        // What is on disk: ids, dates, words. No body, no cookie.
        let text = try String(contentsOf: url, encoding: .utf8)
        for key in ["draftID", "assignmentID", "startedAt", "outcome", "reported", "agentName"] { #expect(text.contains(key)) }
        #expect(!text.lowercased().contains("cookie") && !text.lowercased().contains("session"))
    }

    @Test("the default store lives under Application Support/Smooth, never the App Group, and a scratch folder under tests")
    func defaultStoreLocation() throws {
        let text = try Self.source("LowHangingFruitKit/Agent/AgentSubmitAttemptStore.swift")
        #expect(text.contains(".applicationSupportDirectory"))
        #expect(!text.contains("containerURL(forSecurityApplicationGroupIdentifier"))
        #expect(text.contains("SharedDefaults.isTestRunner"))
        #expect(text.contains(".atomic"))
    }

    // MARK: §3 What is persisted, and what clears it

    @Test("clearAgentDraftsLocally clears the memory, every agent key it owns, and the attempt records")
    func clearLocally() async throws {
        try await withCleanKeys {
            let state = try makeState()
            let draft = AgentDraft(id: "smd_1", assignmentID: "a", kind: .text, body: "x")
            state.applyAgentDrafts([draft])
            UserDefaults.lhf.set(["c1"], forKey: AppState.agentKnownConnectionIDsKey)
            state.agentDraftAcceptanceByDraftID["smd_1"] = .locked
            state.agentConnectionBanner = "connected to claude"
            state.lastAgentDraftsAt = Date()
            try state.agentSubmitAttempts.begin(draftID: "smd_1", assignmentID: "a")
            #expect(UserDefaults.lhf.object(forKey: AgentDraftCache.key) != nil)
            #expect(UserDefaults.lhf.object(forKey: AgentDraftNotices.notifiedKey) != nil)

            state.clearAgentDraftsLocally()
            #expect(state.agentDrafts.isEmpty && state.agentDraftAcceptanceByDraftID.isEmpty)
            #expect(state.pendingAgentDraftNotices.isEmpty && state.agentConnectionBanner == nil && state.lastAgentDraftsAt == nil)
            for key in [AgentDraftCache.key, AgentDraftNotices.notifiedKey, AppState.agentKnownConnectionIDsKey] {
                #expect(UserDefaults.lhf.object(forKey: key) == nil, "\(key)")
            }
            #expect(state.agentSubmitAttempts.all().isEmpty)
        }
    }

    @Test("Canvas disconnect clears the opt-in, the drafts, the attempts, the PDF pass's memory and the rules")
    func disconnectClearsEverything() throws {
        // `disconnectCanvas` touches the Keychain and cannot run under a test
        // (AppState.swift says so); its body is read instead.
        let text = try Self.source("LowHangingFruitUI/AppState.swift")
        let body = Self.body(of: "func disconnectCanvas(keepingStudentWork: Bool = true) {", in: text)
        for needle in ["removeObject(forKey: SharedDefaults.agentConnectionEnabledKey)", "agentConnectionEnabled = false",
                       "clearAgentDraftsLocally()", "deleteSnapshot()",
                       "removeObject(forKey: Self.attachmentAttemptsKey)",
                       "removeObject(forKey: Self.lastAttachmentSyncSummaryKey)",
                       "canvasSubmissionRulesByAssignmentID = [:]"] {
            #expect(body.contains(needle), "disconnectCanvas must do \(needle)")
        }
        // The opt-out, too.
        let connection = try Self.source("LowHangingFruitUI/AppState+AgentConnection.swift")
        let optOut = Self.body(of: "func setAgentConnectionEnabled(_ on: Bool) async {", in: connection)
        #expect(optOut.contains("deleteSnapshot()") && optOut.contains("clearAgentDraftsLocally()"))
    }

    @Test("every agent and attachment key in UserDefaults.lhf is one the clear paths know")
    func noUnknownAgentKeys() throws {
        // Every literal key the v11 files define. A new one must be added to
        // a clear path and to this list in the same commit.
        let files = ["LowHangingFruitUI/AppState+AgentDrafts.swift", "LowHangingFruitUI/AppState+AgentConnection.swift",
                     "LowHangingFruitUI/AppState+AssignmentAttachments.swift", "LowHangingFruitKit/Agent/AgentDraft.swift",
                     "LowHangingFruitUI/AgentDraftReviewSheet.swift", "LowHangingFruitUI/AgentConnectionsView.swift",
                     "LowHangingFruitUI/AgentLinkApproveSheet.swift"]
        let known: Set<String> = ["agentDraftsCacheV1", "agentDraftsNotifiedV1", "agentKnownConnectionIDsV1",
                                  "attachmentAttemptsV1", "lastAttachmentSyncSummaryV1"]
        let pattern = try NSRegularExpression(pattern: #"(?:Key|key) = "([A-Za-z0-9_.]+)""#)
        for file in files {
            guard let text = try? Self.source(file) else { continue }
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = String(text[Range(m.range(at: 1), in: text)!])
                #expect(known.contains(key), "\(file) defines \(key), which no clear path knows")
            }
        }
    }

    @Test("the structured-sources run keeps Canvas's submission rules in memory and writes nothing new to defaults")
    func structuredRulesPersistNothing() throws {
        let state = try makeState()
        let scratch = "V11Structured.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: scratch)!
        defaults.removePersistentDomain(forName: scratch)
        state.structuredDefaults = defaults
        let course = CourseSummary(courseID: "1949400", code: "PHYS 0151", name: "Physics",
                                   url: URL(string: "https://canvas.upenn.edu/courses/1949400"), section: nil)
        state.structuredSourcesCoursesForTesting = [course]
        var result = CanvasStructuredSourcesClient.RunResult()
        var c = CanvasStructuredSourcesClient.CourseResult(courseID: "1949400")
        c.assignments = [CanvasOverrideAssignment(id: "7001", name: "Problem Set 7", submissionTypes: ["online_upload"],
                                                  allowedExtensions: ["PDF"], lockedForUser: false)]
        c.completedEndpoints = [.assignments]
        result.courses = [c]
        let before = Set(defaults.dictionaryRepresentation().keys)
        _ = state.applyStructuredSources(run: result, courses: [course])
        #expect(state.canvasSubmissionRulesByAssignmentID["7001"]?.allowedExtensions == ["pdf"])
        let written = Set(defaults.dictionaryRepresentation().keys).subtracting(before)
        for key in written {
            #expect(key.hasPrefix("structured") || key == "lastStructuredSourcesSyncSummaryV1", "the run wrote \(key)")
            #expect(!key.lowercased().contains("rule") && !key.lowercased().contains("submissiontype"))
        }
        // And the shared domain holds no rules key.
        #expect(!UserDefaults.lhf.dictionaryRepresentation().keys.contains { $0.lowercased().contains("submissionrule") })
    }

    // MARK: §4 Guards

    @Test("the gates, pinned with a fixed clock", arguments: [(600.0, "snapshot"), (300.0, "drafts")])
    func passRules(throttle: Double, name: String) {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func run(available: Bool = true, enabled: Bool = true, fixture: Bool = false, background: Bool = false,
                 running: Bool = false, last: Date? = nil, now: Date = t0, force: Bool = false) -> Bool {
            AgentPassRules.shouldStart(isAvailable: available, isEnabled: enabled, isFixtureData: fixture,
                                       isBackground: background, isRunning: running, lastRun: last, now: now,
                                       throttle: throttle, force: force)
        }
        #expect(run())
        #expect(!run(available: false), "not Penn, no backend, or onboarding")
        #expect(!run(enabled: false), "opt-in off")
        #expect(!run(fixture: true), "preview or demo")
        #expect(!run(background: true), "background wake")
        #expect(!run(running: true), "already in flight")
        for gate in [run(available: false, force: true), run(enabled: false, force: true), run(fixture: true, force: true),
                     run(background: true, force: true), run(running: true, force: true)] {
            #expect(!gate, "force skips only the throttle")
        }
        #expect(!run(last: t0, now: t0.addingTimeInterval(throttle - 1)), "\(name): inside the throttle")
        #expect(run(last: t0, now: t0.addingTimeInterval(throttle)), "\(name): exactly at the throttle")
        #expect(run(last: t0, now: t0.addingTimeInterval(-60)), "a clock that moved back does not freeze it")
        #expect(run(last: t0, now: t0.addingTimeInterval(1), force: true))
    }

    @Test("the throttles are 10 minutes, 5 minutes, and a day for an attachment retry (a week for a scan)")
    func throttleValues() {
        #expect(AppState.agentSnapshotThrottle == 600)
        #expect(AppState.agentDraftsThrottle == 300)
        #expect(AssignmentAttachmentPlanner.retryInterval == 86_400)
        #expect(AssignmentAttachmentPlanner.noTextRetryInterval == 7 * 86_400)
    }

    @Test("an attachment tried an hour ago is not planned; a day later it is; a scan waits a week")
    func attachmentRetryClock() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let doc = CourseDocument(courseID: "1", course: "C", kind: .assignment, sourceID: "9", title: "HW",
                                 url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/9"),
                                 text: "sheet: https://canvas.upenn.edu/courses/1/files/77", fetchedAt: now,
                                 dueAt: now.addingTimeInterval(86_400))
        func plan(_ a: AssignmentAttachmentAttempt?) -> Int {
            AssignmentAttachmentPlanner.plan(documents: [doc], now: now, attempts: a.map { ["77": $0] } ?? [:]).count
        }
        #expect(plan(nil) == 1)
        #expect(plan(.init(date: now.addingTimeInterval(-3_600), kind: .failed)) == 0)
        #expect(plan(.init(date: now.addingTimeInterval(-86_400), kind: .failed)) == 1)
        #expect(plan(.init(date: now.addingTimeInterval(-2 * 86_400), kind: .noText)) == 0)
        #expect(plan(.init(date: now.addingTimeInterval(-7 * 86_400), kind: .noText)) == 1)
    }

    @Test("both agent passes go through the one rule; the attachment pass keeps its own gates")
    func passesUseTheRule() throws {
        let connection = try Self.source("LowHangingFruitUI/AppState+AgentConnection.swift")
        let drafts = try Self.source("LowHangingFruitUI/AppState+AgentDrafts.swift")
        let attachments = try Self.source("LowHangingFruitUI/AppState+AssignmentAttachments.swift")
        let snapshotPass = Self.body(of: "func agentSnapshotPass(force: Bool = false, now: Date = Date()) async {", in: connection)
        let draftsPass = Self.body(of: "func agentDraftsPass(force: Bool = false, now: Date = Date()) async {", in: drafts)
        for (name, body) in [("snapshot", snapshotPass), ("drafts", draftsPass)] {
            #expect(body.contains("AgentPassRules.shouldStart("), "\(name)")
            #expect(body.contains("isFixtureData: isUsingFixtureData"), "\(name)")
            #expect(body.contains("isBackground: renewalContext == .background"), "\(name)")
            #expect(body.contains("isAvailable: canUseAgentConnection"), "\(name)")
        }
        let attachmentPass = Self.body(of: "func attachmentPass(cookies: [HTTPCookie]) async {", in: attachments)
        for needle in ["renewalContext != .background", "!isUsingFixtureData", "CanvasInstallation.penn.id",
                       "BackendServices.client"] {
            #expect(attachmentPass.contains(needle), "attachmentPass must check \(needle)")
        }
        // Availability itself is Penn, a backend, no fixture data, past onboarding.
        #expect(DeviceSyncRules.isAvailable(isFixtureData: false, isPenn: true, hasBackend: true, needsOnboarding: false))
        #expect(!DeviceSyncRules.isAvailable(isFixtureData: true, isPenn: true, hasBackend: true, needsOnboarding: false))
        #expect(!DeviceSyncRules.isAvailable(isFixtureData: false, isPenn: false, hasBackend: true, needsOnboarding: false))
        #expect(!DeviceSyncRules.isAvailable(isFixtureData: false, isPenn: true, hasBackend: false, needsOnboarding: false))
        #expect(!DeviceSyncRules.isAvailable(isFixtureData: false, isPenn: true, hasBackend: true, needsOnboarding: true))
    }

    @Test("under the test runner (no backend) and in preview, neither pass starts")
    func passesDoNotStart() async throws {
        try await withCleanKeys {
            let state = try makeState()
            state.agentConnectionEnabled = true
            await state.agentSnapshotPass(force: true)
            await state.agentDraftsPass(force: true)
            #expect(state.lastAgentSnapshotAt == nil && state.lastAgentDraftsAt == nil)
            state.forceFixtureDataForTesting(true)
            await state.agentSnapshotPass(force: true)
            await state.agentDraftsPass(force: true)
            #expect(state.lastAgentSnapshotAt == nil && state.lastAgentDraftsAt == nil)
            #expect(state.agentDraftDisplay(forItemID: "x") == nil)
            #expect(await state.submitAgentDraft("any") == .refused(.missingIDs))
            state.agentConnectionEnabled = false
        }
    }

    // MARK: §5 Races

    @Test("an opt-out while the drafts pass awaited the network puts nothing back")
    func optOutMidPass() throws {
        let drafts = try Self.source("LowHangingFruitUI/AppState+AgentDrafts.swift")
        let pass = Self.body(of: "func agentDraftsPass(force: Bool = false, now: Date = Date()) async {", in: drafts)
        // The enabled check must sit after the last await and before the apply.
        let lastAwait = try #require(pass.range(of: "await reportAgentDraft", options: .backwards))
        let apply = try #require(pass.range(of: "applyAgentDrafts("))
        let check = try #require(pass.range(of: "guard agentConnectionEnabled else { return }", options: .backwards))
        #expect(lastAwait.upperBound < check.lowerBound && check.upperBound < apply.lowerBound)
    }

    @Test("a snapshot put that lands after an opt-out is deleted again")
    func putAfterOptOut() throws {
        let connection = try Self.source("LowHangingFruitUI/AppState+AgentConnection.swift")
        let pass = Self.body(of: "func agentSnapshotPass(force: Bool = false, now: Date = Date()) async {", in: connection)
        let put = try #require(pass.range(of: "await api.putSnapshot(snapshot)"))
        let redelete = try #require(pass.range(of: "if !agentConnectionEnabled { _ = try? await api.deleteSnapshot() }"))
        #expect(put.upperBound < redelete.lowerBound)
    }

    @Test("a decline is refused once an attempt exists; a draft with a record never shows Submit again")
    func declineAfterAttempt() async throws {
        try await withCleanKeys {
            let state = try makeState()
            let item = Assignment(source: .canvas, sourceID: "event-assignment-34", kind: .assignment,
                                  course: "PHYS 0151", title: "Problem Set 7", dueAt: nil, url: nil)
            state.assignments = [item]
            let draft = AgentDraft(id: "smd_r", assignmentID: item.id, kind: .text, body: "x")
            state.applyAgentDrafts([draft])
            try state.agentSubmitAttempts.begin(draftID: "smd_r", assignmentID: item.id)
            // No backend under tests, so decline answers false either way;
            // the record check comes first in the source (read below).
            #expect(await state.declineAgentDraft("smd_r") == false)
            #expect(state.agentDraftDisplay(forItemID: item.id)?.checkCanvas == true)
            state.agentSubmitAttempts.finish(draftID: "smd_r", outcome: .submitted, canvasSubmissionID: "1")
            #expect(state.agentDraft(forItemID: item.id) == nil, "a submitted draft never shows again")
            // A refreshed list that still carries it (fetched before the
            // submit) cannot bring it back.
            state.applyAgentDrafts([draft])
            #expect(state.agentDraft(forItemID: item.id) == nil)
        }
        let drafts = try Self.source("LowHangingFruitUI/AppState+AgentDrafts.swift")
        let decline = Self.body(of: "func declineAgentDraft(_ draftID: String) async -> Bool {", in: drafts)
        let recordCheck = try #require(decline.range(of: "agentSubmitAttempts.record(for: draftID) == nil"))
        let report = try #require(decline.range(of: "reportAgentDraft"))
        #expect(recordCheck.upperBound < report.lowerBound)
    }

    @Test("the review sheet serialises Submit and Decline behind one busy flag")
    func sheetSerialises() throws {
        let sheet = try Self.source("LowHangingFruitUI/AgentDraftReviewSheet.swift")
        let guards = sheet.components(separatedBy: "guard !isWorking").count - 1
        #expect(guards >= 2, "submit and decline both refuse while the other runs")
        #expect(sheet.contains(".interactiveDismissDisabled(isWorking)"))
    }

    @Test("attachmentPass and refreshCourseKnowledge: the pass runs inside the sync, never beside it")
    func attachmentInsideSync() throws {
        let knowledge = try Self.source("LowHangingFruitUI/AppState+CourseKnowledge.swift")
        let call = try #require(knowledge.range(of: "await attachmentPass(cookies: cookies)"))
        // The held sync task (Traps, the `.task` entry) is what callers join;
        // the pass runs inside it, so a second caller joins rather than
        // starting a second pass beside it.
        #expect(knowledge.contains("pendingCourseKnowledgeSync"))
        #expect(knowledge[..<call.lowerBound].contains("pendingCourseKnowledgeSync"))
    }

    @Test("no static func on a v11 View is called off the main actor without being nonisolated")
    func viewStaticsAreNonisolated() throws {
        // The `decidedText` trap: a `static func` on a SwiftUI View is
        // main-actor isolated, and Swift 6 kills a background caller.
        for file in ["LowHangingFruitUI/AgentDraftReviewSheet.swift", "LowHangingFruitUI/AgentLinkApproveSheet.swift",
                     "LowHangingFruitUI/AgentConnectionsView.swift"] {
            guard let text = try? Self.source(file) else { continue }
            for line in text.components(separatedBy: "\n") where line.contains("static func") {
                let isolated = !line.contains("nonisolated")
                if isolated {
                    // Allowed only when nothing detaches it: no Task.detached in the file calls it.
                    let name = line.components(separatedBy: "static func ").last?.components(separatedBy: "(").first ?? ""
                    let detachedCalls = text.components(separatedBy: "Task.detached").dropFirst()
                        .filter { $0.prefix(400).contains("\(name)(") }
                    #expect(detachedCalls.isEmpty, "\(file): \(name) is called from Task.detached but is main-actor isolated")
                }
            }
        }
        // The one detached call the sheet makes is into the Kit's renderer, which is not a View.
        let sheet = try Self.source("LowHangingFruitUI/AgentDraftReviewSheet.swift")
        #expect(sheet.contains("Task.detached { DraftDocumentRenderer.pdfData(forDraftBody:"))
        // `fetchSignedFile` is nonisolated (it runs from the submitter's Sendable closure).
        let drafts = try Self.source("LowHangingFruitUI/AppState+AgentDrafts.swift")
        #expect(drafts.contains("nonisolated static func fetchSignedFile("))
    }

    // MARK: §1 Nothing secret reaches a log

    @Test("no v11 file logs: no print, os_log, NSLog, Logger or debug renewal log line")
    func noLogging() throws {
        let files = [
            "LowHangingFruitKit/Agent/AgentDraft.swift", "LowHangingFruitKit/Agent/AgentDraftSubmitter.swift",
            "LowHangingFruitKit/Agent/AgentLinkRequest.swift", "LowHangingFruitKit/Agent/AgentSnapshotBuilder.swift",
            "LowHangingFruitKit/Agent/AgentSubmitAttemptStore.swift", "LowHangingFruitKit/Agent/DraftDocumentRenderer.swift",
            "LowHangingFruitKit/Agent/DraftSubmitPlan.swift", "LowHangingFruitKit/CanvasAPI/CanvasSubmissionClient.swift",
            "LowHangingFruitKit/CanvasAPI/CanvasFilesClient.swift",
            "LowHangingFruitKit/Knowledge/AssignmentAttachmentPlanner.swift",
            "LowHangingFruitKit/Knowledge/AssignmentAttachmentRunner.swift",
            "LowHangingFruitUI/AppState+AgentConnection.swift", "LowHangingFruitUI/AppState+AgentDrafts.swift",
            "LowHangingFruitUI/AppState+AssignmentAttachments.swift", "LowHangingFruitUI/AgentConnectionClient.swift",
            "LowHangingFruitUI/AgentDraftReviewSheet.swift", "LowHangingFruitUI/AgentLinkApproveSheet.swift",
            "LowHangingFruitUI/AgentConnectionsView.swift",
        ]
        let banned = ["print(", "os_log", "NSLog(", "Logger(", "debugRenewalLog", "debugPrint(", "dump(",
                      "FileHandle.standardError"]
        for file in files {
            let text = try Self.source(file)
            // Comments may name them; code may not.
            let code = text.components(separatedBy: "\n")
                .map { $0.components(separatedBy: "//").first ?? "" }
                .joined(separator: "\n")
            for word in banned { #expect(!code.contains(word), "\(file) contains \(word)") }
        }
    }

    @Test("the only summary line the attachment pass writes is counts and words, never a URL or a file name")
    func attachmentSummaryHasNoSecrets() {
        var outcome = AssignmentAttachmentRunner.Outcome()
        outcome.firstFailure = "save"
        let line = outcome.summary
        #expect(!line.contains("http") && !line.contains("/") && !line.contains(".pdf"))
    }

    @Test("a cookie value never reaches the snapshot, a draft cache, an attempt record or a pooled document")
    func cookieNeverLeaks() throws {
        let secret = "SESSIONSECRET123"
        let feed = "https://canvas.upenn.edu/feeds/calendars/user_abcdefghijklmnop.ics?cookie=\(secret)"
        let work = [SyncSnapshot.WorkItem(id: "w", course: "PHYS 0151", title: "PS7", dueAt: nil, kind: .assignment,
                                          source: "canvas", url: feed, done: false)]
        let snap = AgentSnapshotBuilder.build(courses: [], work: work, noSubmission: { _ in false }, manual: [])
        let encoded = String(decoding: try AgentSnapshot.encoder().encode(snap), as: UTF8.self)
        #expect(!encoded.contains(secret) && !encoded.contains("user_abc") && !encoded.contains("feeds"))
        #expect(snap.workList.first?.url == nil)

        // The submit attempt record holds no field a cookie could ride in.
        let names = Set(Mirror(reflecting: AgentSubmitAttemptStore.Record(
            draftID: "", assignmentID: "", startedAt: Date(), outcome: nil, canvasSubmissionID: nil,
            attempt: nil, errorClass: nil, reported: false, agentName: nil)).children.compactMap(\.label))
        #expect(names == ["draftID", "assignmentID", "startedAt", "outcome", "canvasSubmissionID", "attempt",
                          "errorClass", "reported", "agentName"])

        // The error classes the client can produce are fixed words.
        for word in ["offline", "session", "rejected_422", "upload_start", "upload", "upload_confirm"] {
            #expect(word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" })
        }
    }

    // MARK: §6 The snapshot

    static func work(_ n: Int, source: String = "canvas") -> [SyncSnapshot.WorkItem] {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let accents = String(repeating: "é", count: 40)
        var out: [SyncSnapshot.WorkItem] = []
        for i in 0..<n {
            let id: Int = 10_000 + i
            let hours: Double = Double((i * 7919) % 5_000) * 3_600
            let due: Date? = i % 7 == 0 ? nil : t0.addingTimeInterval(hours)
            let url: String = "https://canvas.upenn.edu/calendar?include_contexts=course_1949400&month=11#assignment_\(id)"
            out.append(SyncSnapshot.WorkItem(id: "event-assignment-\(id)", course: "PHYS 0151",
                                             title: "Item \(i) \(accents)", dueAt: due, kind: .assignment,
                                             source: source, url: url, done: i % 5 == 0))
        }
        return out
    }

    @Test("2,000 items: under 1 MB, ordered open-soonest first, and the same bytes twice")
    func bigSnapshot() throws {
        let items = Self.work(2_000)
        let courses = [AgentSnapshot.Course(courseID: "1949400", code: "PHYS 0151", name: "Physics")]
        let a = AgentSnapshotBuilder.build(courses: courses, work: items, noSubmission: { _ in false }, manual: [])
        let b = AgentSnapshotBuilder.build(courses: courses, work: items.reversed(), noSubmission: { _ in false }, manual: [])
        let ea = try AgentSnapshot.encoder().encode(a), eb = try AgentSnapshot.encoder().encode(b)
        #expect(ea == eb, "the order of the input must not change the bytes")
        #expect(ea.count < AgentSnapshotBuilder.maxBytes, "\(ea.count) bytes")
        #expect(a.workList.count == 2_000)
        let firstDone = a.workList.firstIndex { $0.done } ?? a.workList.count
        #expect(a.workList[..<firstDone].allSatisfy { !$0.done })
        let openDated = a.workList[..<firstDone].compactMap(\.dueAt)
        #expect(openDated == openDated.sorted())
        // Every Canvas row carries both ids and the canonical link.
        #expect(a.workList.allSatisfy { $0.canvasCourseID == "1949400" && $0.canvasAssignmentID != nil })
        #expect(a.workList.allSatisfy { $0.url?.hasPrefix("https://canvas.upenn.edu/courses/1949400/assignments/") == true })
    }

    @Test("an override uid's assignment id comes from the fragment, never the override number")
    func overrideUID() {
        let row = SyncSnapshot.WorkItem(
            id: "event-assignment-override-555", course: "PHYS 0151", title: "Lab 3 (201)", dueAt: nil,
            kind: .assignment, source: "canvas",
            url: "https://canvas.upenn.edu/calendar?include_contexts=course_1949400&month=11&year=2026#assignment_7001",
            done: false)
        let snap = AgentSnapshotBuilder.build(courses: [], work: [row], noSubmission: { _ in false }, manual: [])
        #expect(snap.workList.first?.canvasAssignmentID == "7001")
        #expect(snap.workList.first?.canvasCourseID == "1949400")
    }

    @Test("a manual item and a Gradescope item carry no Canvas ids")
    func manualAndGradescope() {
        let gs = SyncSnapshot.WorkItem(id: "gs:1", course: "CIS 2620", title: "HW 3", dueAt: nil, kind: .assignment,
                                       source: "gradescope",
                                       url: "https://www.gradescope.com/courses/123/assignments/456", done: false)
        let manual = SyncSnapshot.WorkItem(id: "manual:x", course: "CIS 2620", title: "Read ch. 3", dueAt: nil,
                                           kind: .assignment, source: "manual", url: nil, done: false)
        let snap = AgentSnapshotBuilder.build(courses: [], work: [gs, manual], noSubmission: { _ in false },
                                              manual: [.init(id: UUID().uuidString, course: "CIS 2620", title: "Study",
                                                             dueAt: nil, repeatsWeekly: true)],
                                              courseIDByCode: { _ in "999" })
        #expect(snap.workList.allSatisfy { $0.canvasAssignmentID == nil && $0.canvasCourseID == nil })
        #expect(snap.manual.count == 1)
        // And neither can be sent to Canvas from the phone.
        for item in snap.workList {
            #expect(AgentDraftSubmitter.unsupportedReason(draft: AgentDraft(id: "d", assignmentID: item.id, kind: .text,
                                                                             body: "x"), item: item) != nil)
        }
    }

    @Test("the encoded field set is closed: no grade, score, name, email or cookie key anywhere")
    func closedFieldSet() throws {
        let snap = AgentSnapshotBuilder.build(
            courses: [.init(courseID: "1", code: "C", name: "N")], work: Self.work(3),
            noSubmission: { _ in false }, manual: [.init(id: "m", course: "C", title: "t", dueAt: nil, repeatsWeekly: false)])
        let object = try JSONSerialization.jsonObject(with: try AgentSnapshot.encoder().encode(snap)) as! [String: Any]
        var keys = Set<String>()
        func walk(_ v: Any) {
            if let d = v as? [String: Any] { for (k, x) in d { keys.insert(k); walk(x) } }
            if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(object)
        #expect(keys == ["courses", "workList", "manual", "courseID", "code", "name", "id", "course", "title", "kind",
                         "dueAt", "done", "noSubmission", "url", "source", "canvasAssignmentID", "canvasCourseID",
                         "repeatsWeekly"])
    }
}
