import Foundation
import Testing
@testable import LowHangingFruitKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func mkEntry(_ id: String, canvas: String? = nil, fire: Date = t0, probe: Bool = false,
                   alarms: [UUID] = [], requests: [String] = []) -> SweepManifest.Entry {
    .init(itemID: id, canvasAssignmentID: canvas, title: "t\(id)", fireDate: fire,
          alarmIDs: alarms, requestIDs: requests, probe: probe)
}

private func read(_ id: String, _ v: SubmissionRead.Verdict) -> SubmissionRead {
    SubmissionRead(assignmentID: id, readAt: t0, source: .planner, verdict: v)
}

@Suite("Sweep manifest window")
struct SweepManifestTests {
    @Test("entries(near:) keeps ring times from 2 min ago to 20 min ahead, inclusive")
    func window() {
        let m = SweepManifest(writtenAt: t0, canvasBaseURL: URL(string: "https://c.example")!, entries: [
            mkEntry("past", fire: t0.addingTimeInterval(-121)),
            mkEntry("edgePast", fire: t0.addingTimeInterval(-120)),
            mkEntry("now", fire: t0),
            mkEntry("edgeAhead", fire: t0.addingTimeInterval(1200)),
            mkEntry("far", fire: t0.addingTimeInterval(1201)),
        ])
        #expect(m.entries(near: t0).map(\.itemID) == ["edgePast", "now", "edgeAhead"])
        #expect(m.version == 1)
    }
}

@Suite("Sweep check")
struct SweepCheckTests {
    @Test("submitted, unsubmitted and unknown are told apart by the entry's own canvas id")
    func table() {
        let es = [mkEntry("a", canvas: "1"), mkEntry("b", canvas: "2"), mkEntry("c", canvas: "3"), mkEntry("d", canvas: nil)]
        let o = SweepCheck.decide(entries: es, reads: [read("1", .submitted), read("2", .unsubmitted), read("3", .unknown),
                                                       read("9", .submitted)], honourProbe: false)
        #expect(o.submitted.map(\.itemID) == ["a"])
        #expect(o.unsubmitted.map(\.itemID) == ["b"])
        #expect(o.unknown.map(\.itemID) == ["c", "d"])
    }

    @Test("nil reads make everything unknown and cancel nothing")
    func nilReads() {
        let a = UUID()
        let es = [mkEntry("a", canvas: "1", alarms: [a], requests: ["r"])]
        let o = SweepCheck.decide(entries: es, reads: nil, honourProbe: false)
        #expect(o.unknown.count == 1 && o.submitted.isEmpty && o.unsubmitted.isEmpty)
        #expect(o.alarmIDsToCancel.isEmpty && o.requestIDsToRemove.isEmpty && o.body == nil)
    }

    @Test("an unknown never cancels, even beside a submitted entry")
    func unknownNeverCancels() {
        let a = UUID(), b = UUID()
        let es = [mkEntry("a", canvas: "1", alarms: [a]), mkEntry("b", canvas: nil, alarms: [b])]
        let o = SweepCheck.decide(entries: es, reads: [read("1", .submitted)], honourProbe: false)
        #expect(o.alarmIDsToCancel == [a])
    }

    @Test("a cancelling read beats an unsubmitted one for the same id")
    func conflictingReads() {
        let o = SweepCheck.decide(entries: [mkEntry("a", canvas: "1")],
                                  reads: [read("1", .unsubmitted), read("1", .submitted)], honourProbe: false)
        #expect(o.submitted.count == 1 && o.unsubmitted.isEmpty)
    }

    @Test("probe entries count as submitted only when honoured")
    func probe() {
        let a = UUID()
        let es = [mkEntry("a", canvas: nil, probe: true, alarms: [a])]
        #expect(SweepCheck.decide(entries: es, reads: nil, honourProbe: true).alarmIDsToCancel == [a])
        #expect(SweepCheck.decide(entries: es, reads: nil, honourProbe: false).alarmIDsToCancel.isEmpty)
        #expect(SweepCheck.decide(entries: es, reads: [read("1", .unsubmitted)], honourProbe: false).submitted.isEmpty)
    }

    @Test("request ids are de-duplicated in stable order, from submitted entries only")
    func requestIDs() {
        let es = [mkEntry("a", canvas: "1", requests: ["x", "y"]), mkEntry("b", canvas: "2", requests: ["y", "z"]),
                  mkEntry("c", canvas: "3", requests: ["w"])]
        let o = SweepCheck.decide(entries: es, reads: [read("1", .submitted), read("2", .submitted), read("3", .unsubmitted)],
                                  honourProbe: false)
        #expect(o.requestIDsToRemove == ["x", "y", "z"])
    }

    @Test("body copy")
    func body() {
        let one = [mkEntry("1", canvas: "1")]
        let two = [mkEntry("1", canvas: "1"), mkEntry("2", canvas: "2")]
        func b(_ es: [SweepManifest.Entry], _ rs: [SubmissionRead]?) -> String? {
            SweepCheck.decide(entries: es, reads: rs, honourProbe: false).body
        }
        #expect(b(one, [read("1", .unsubmitted)]) == "t1 · not turned in yet")
        #expect(b(two, [read("1", .unsubmitted), read("2", .unsubmitted)]) == "2 not turned in yet")
        #expect(b(one, [read("1", .submitted)]) == "t1 is in · alarm off")
        #expect(b(two, [read("1", .submitted), read("2", .submitted)]) == "2 turned in · alarms off")
        // Mixed: unsubmitted wins the text, the submitted one is still cancelled.
        let mixed = SweepCheck.decide(entries: two, reads: [read("1", .submitted), read("2", .unsubmitted)], honourProbe: false)
        #expect(mixed.body == "t2 · not turned in yet")
        #expect(mixed.submitted.count == 1)
        #expect(b(one, nil) == nil)
        #expect(b(one, [read("1", .unknown)]) == nil)
        #expect(b([], []) == nil)
    }
}

@Suite("Sweep inbox and files")
struct SweepFilesTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("appending de-duplicates by item id keeping the earliest time")
    func inboxDedup() {
        let early = t0, late = t0.addingTimeInterval(60)
        let i = SweepInbox().appending([.init(itemID: "a", canvasAssignmentID: "1", at: late)])
            .appending([.init(itemID: "a", canvasAssignmentID: "1", at: early), .init(itemID: "b", canvasAssignmentID: nil, at: late),
                        .init(itemID: "b", canvasAssignmentID: nil, at: early)])
        #expect(i.records.map(\.itemID) == ["a", "b"])
        #expect(i.records.map(\.at) == [early, early])
    }

    @Test("manifest round-trips, and delete removes it")
    func manifestRoundTrip() {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let m = SweepManifest(writtenAt: t0, canvasBaseURL: URL(string: "https://c.example")!,
                              entries: [mkEntry("a", canvas: "1", probe: true, alarms: [UUID()], requests: ["r"])])
        #expect(SweepFiles.loadManifest(in: d) == nil)
        #expect(SweepFiles.saveManifest(m, in: d))
        #expect(SweepFiles.loadManifest(in: d) == m)
        SweepFiles.deleteManifest(in: d)
        #expect(SweepFiles.loadManifest(in: d) == nil)
    }

    @Test("inbox appends across calls, drain returns and removes")
    func inboxDrain() {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        #expect(SweepFiles.loadInbox(in: d).records.isEmpty)
        SweepFiles.appendToInbox([.init(itemID: "a", canvasAssignmentID: "1", at: t0)], in: d)
        SweepFiles.appendToInbox([.init(itemID: "b", canvasAssignmentID: nil, at: t0), .init(itemID: "a", canvasAssignmentID: "1", at: t0)], in: d)
        let drained = SweepFiles.drainInbox(in: d)
        #expect(drained.records.map(\.itemID) == ["a", "b"])
        #expect(SweepFiles.loadInbox(in: d).records.isEmpty)
    }

    @Test("a record appended after a drain survives it")
    func appendAfterDrain() {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        SweepFiles.appendToInbox([.init(itemID: "a", canvasAssignmentID: "1", at: t0)], in: d)
        #expect(SweepFiles.drainInbox(in: d).records.map(\.itemID) == ["a"])
        SweepFiles.appendToInbox([.init(itemID: "b", canvasAssignmentID: "2", at: t0)], in: d)
        #expect(SweepFiles.drainInbox(in: d).records.map(\.itemID) == ["b"])
        #expect(SweepFiles.drainInbox(in: d).records.isEmpty)
        // No drain leftovers are kept.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: d.path))?.isEmpty == true)
    }

    @Test("an entry written without a probe key decodes with probe false")
    func probeDefaults() throws {
        let json = """
        {"itemID":"a","title":"t","fireDate":"2026-11-18T15:00:00Z","alarmIDs":[],"requestIDs":[]}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let e = try d.decode(SweepManifest.Entry.self, from: Data(json.utf8))
        #expect(e.probe == false && e.canvasAssignmentID == nil)
    }

    @Test("corrupt files read as nil or empty, and no directory never throws")
    func corrupt() throws {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        try Data("not json".utf8).write(to: d.appendingPathComponent(SweepFiles.manifestFilename))
        try Data("{".utf8).write(to: d.appendingPathComponent(SweepFiles.inboxFilename))
        #expect(SweepFiles.loadManifest(in: d) == nil)
        #expect(SweepFiles.loadInbox(in: d).records.isEmpty)
        #expect(SweepFiles.loadManifest(in: nil) == nil)
        #expect(SweepFiles.drainInbox(in: nil).records.isEmpty)
    }

    @Test("under a test runner the default directory is nil")
    func defaultIsNil() {
        #expect(SweepFiles.defaultDirectory() == nil)
    }
}

@Suite("Sweep cookie mirror")
struct SweepCookieMirrorTests {
    private func cookie(_ name: String, domain: String, expires: Date? = nil) -> HTTPCookie {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "v-\(name)", .domain: domain, .path: "/", .secure: "TRUE"]
        if let expires { p[.expires] = expires }
        return HTTPCookie(properties: p)!
    }

    @Test("encode keeps matching domains only, and decode restores them")
    func roundTrip() {
        // Foundation caps an HTTPCookie expiry at roughly 400 days out, so stay inside that.
        let exp = Date(timeIntervalSinceNow: 30 * 86400).addingTimeInterval(0).rounded()
        let cs = [cookie("a", domain: "canvas.upenn.edu", expires: exp), cookie("b", domain: ".upenn.edu"),
                  cookie("c", domain: "evil-upenn.edu"), cookie("d", domain: "other.com"),
                  cookie("e", domain: "sso.canvas.upenn.edu")]
        let out = SweepCookieMirror.decode(SweepCookieMirror.encode(cs, host: "canvas.upenn.edu"))
        #expect(out.map(\.name) == ["a", "b"])
        #expect(out[0].value == "v-a" && out[0].isSecure && out[0].path == "/")
        #expect(out[0].expiresDate == exp)
        #expect(out[1].expiresDate == nil)
    }

    @Test("garbage decodes to nothing; keychain calls are inert under tests")
    func inert() {
        #expect(SweepCookieMirror.decode(Data("nope".utf8)).isEmpty)
        SweepCookieMirror.save(cookies: [cookie("a", domain: "canvas.upenn.edu")], host: "canvas.upenn.edu")
        #expect(SweepCookieMirror.load(host: "canvas.upenn.edu").isEmpty)
        SweepCookieMirror.deleteAll()
    }
}

private extension Date {
    /// Whole seconds: cookie expiry survives a round trip at that resolution.
    func rounded() -> Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}
