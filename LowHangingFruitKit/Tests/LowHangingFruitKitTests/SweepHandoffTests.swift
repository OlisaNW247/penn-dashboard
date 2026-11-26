import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The app's half of the force-quit check: the manifest it writes and the
/// inbox it folds. Everything goes through temp directories and the
/// `canvasConnected` seam; no test touches the real container, WebKit or the
/// Keychain.
@MainActor
@Suite("Sweep handoff")
struct SweepHandoffTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!

    private func canvasRow(_ id: String, linkedID: String? = nil) -> Assignment {
        Assignment(source: .canvas, sourceID: "event-assignment-\(id)", kind: .assignment, course: "STRW 0151",
                   title: "PSet \(id)", dueAt: now.addingTimeInterval(7200),
                   url: URL(string: "https://canvas.upenn.edu/courses/7/assignments/\(id)"), linkedID: linkedID)
    }

    private func gradescopeRow(linkedID: String?) -> Assignment {
        Assignment(source: .gradescope, sourceID: "gs-1", kind: .assignment, course: "STRW 0151",
                   title: "GS PSet", dueAt: now.addingTimeInterval(7200),
                   url: URL(string: "https://www.gradescope.com/courses/1/assignments/2"), linkedID: linkedID)
    }

    private func planned(_ row: Assignment, minutesAhead: Double = 10) -> PlannedAlarm {
        let fire = now.addingTimeInterval(minutesAhead * 60)
        return PlannedAlarm(id: UUID(), assignmentID: row.id, fireDate: fire, title: row.title, course: row.course,
                            dueAt: row.dueAt ?? fire, link: nil)
    }

    private func rig(_ rows: [Assignment]) throws -> (AppState, URL, UserDefaults, String) {
        let suite = "SweepHandoffTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = try AssignmentStore(inMemory: true)
        store.upsert(rows)
        let state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults)
        state.forceFixtureDataForTesting(false)
        state.structuredDefaults = defaults
        state.sweeperCountsDefaults = defaults
        state.submissionCanceller = { _, _ in }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (state, dir, defaults, suite)
    }

    @Test("the manifest lists one entry per planned alarm with its ids and Canvas id")
    func manifestFromPlan() async throws {
        let row = canvasRow("55")
        let (state, dir, _, suite) = try rig([row])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let p = planned(row)
        await state.writeSweepHandoff(plan: [p], wakeReachable: true, directory: dir,
                                      canvasConnected: true, now: now)
        let m = try #require(SweepFiles.loadManifest(in: dir))
        let e = try #require(m.entries.first)
        #expect(m.entries.count == 1)
        #expect(e.itemID == row.id && e.canvasAssignmentID == "55" && e.title == row.title)
        #expect(e.fireDate == p.fireDate && !e.probe)
        let ids = SubmissionObservation.ids(forAssignmentID: row.id, due: p.dueAt)
        #expect(Set(e.alarmIDs) == ids.alarmIDs.union([p.id]))
        #expect(e.requestIDs == ids.requestIDs)
        #expect(m.canvasBaseURL == state.canvasBaseURL)
    }

    @Test("a Gradescope row takes its Canvas twin's assignment id")
    func gradescopeTwin() async throws {
        let canvas = canvasRow("77")
        let gs = gradescopeRow(linkedID: canvas.id)
        let (state, dir, _, suite) = try rig([canvas, gs])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        await state.writeSweepHandoff(plan: [planned(gs)], wakeReachable: true, directory: dir,
                                      canvasConnected: true, now: now)
        #expect(SweepFiles.loadManifest(in: dir)?.entries.first?.canvasAssignmentID == "77")
    }

    @Test("a Gradescope row with no Canvas twin has no Canvas id")
    func gradescopeAlone() async throws {
        let gs = gradescopeRow(linkedID: nil)
        let (state, dir, _, suite) = try rig([gs])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        await state.writeSweepHandoff(plan: [planned(gs)], wakeReachable: true, directory: dir,
                                      canvasConnected: true, now: now)
        #expect(SweepFiles.loadManifest(in: dir)?.entries.first?.canvasAssignmentID == nil)
    }

    @Test("when no wake can reach the phone, the manifest is deleted")
    func unreachable() async throws {
        let row = canvasRow("55")
        let (state, dir, _, suite) = try rig([row])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        await state.writeSweepHandoff(plan: [planned(row)], wakeReachable: true, directory: dir,
                                      canvasConnected: true, now: now)
        #expect(SweepFiles.loadManifest(in: dir) != nil)
        await state.writeSweepHandoff(plan: [planned(row)], wakeReachable: false, directory: dir,
                                      canvasConnected: true, now: now)
        #expect(SweepFiles.loadManifest(in: dir) == nil)
    }

    @Test("not connected, or fixture data, writes nothing")
    func notConnected() async throws {
        let row = canvasRow("55")
        let (state, dir, _, suite) = try rig([row])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        await state.writeSweepHandoff(plan: [planned(row)], wakeReachable: true, directory: dir,
                                      canvasConnected: false, now: now)
        #expect(SweepFiles.loadManifest(in: dir) == nil)
        state.forceFixtureDataForTesting(true)
        await state.writeSweepHandoff(plan: [planned(row)], wakeReachable: true, directory: dir,
                                      canvasConnected: true, now: now)
        #expect(SweepFiles.loadManifest(in: dir) == nil)
    }

    @Test("the inbox fold marks the matching row done and drains the file")
    func inboxFold() async throws {
        let a = canvasRow("55"), b = canvasRow("56")
        let (state, dir, _, suite) = try rig([a, b])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        SweepFiles.appendToInbox([
            .init(itemID: a.id, canvasAssignmentID: "55", at: now),
            .init(itemID: "gs-only", canvasAssignmentID: nil, at: now),
        ], in: dir)
        state.foldSweepInbox(directory: dir, clearDelivered: false, now: now)
        #expect(state.structuredCompletedItemIDs == [a.id])
        #expect(SweepFiles.loadInbox(in: dir).records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(SweepFiles.inboxFilename).path))
    }

    @Test("an empty inbox changes nothing")
    func emptyInbox() throws {
        let (state, dir, _, suite) = try rig([canvasRow("55")])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        state.foldSweepInbox(directory: dir, clearDelivered: false, now: now)
        #expect(state.structuredCompletedItemIDs.isEmpty)
    }

    @Test("under fixture data the inbox is left in place, not drained")
    func fixtureLeavesInbox() throws {
        let a = canvasRow("55")
        let (state, dir, _, suite) = try rig([a])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        SweepFiles.appendToInbox([.init(itemID: a.id, canvasAssignmentID: "55", at: now)], in: dir)
        state.forceFixtureDataForTesting(true)
        state.foldSweepInbox(directory: dir, clearDelivered: false, now: now)
        #expect(SweepFiles.loadInbox(in: dir).records.count == 1)
        #expect(state.structuredCompletedItemIDs.isEmpty)
    }
}
