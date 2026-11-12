import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree audit store")
struct DegreeAuditStoreTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("degree-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func audit(_ tag: String) -> DegreeAudit {
        let rule = AuditRule(
            id: "\(tag).0", label: "CIS 1200", ruleType: "Course", percentComplete: 100, status: .met, needCourses: 1,
            needCredits: 1, appliedCount: 1, appliedCredits: 1,
            applied: [AuditCourse(code: "CIS 1200", title: "t", credits: 1, termCode: "202430", isInProgress: false, isTransfer: false)],
            advice: [AdviceCourse(code: "CIS 3200", title: nil, credits: nil)], adviceText: "x", children: [])
        return DegreeAudit(
            goals: DegreeGoals(degree: "BSE", majors: [tag]), isWhatIf: false, percentComplete: 10,
            degreeLabel: "d", catalogYearLabel: "c",
            blocks: [AuditBlock(id: tag, type: "MAJOR", value: tag, title: tag, percentComplete: 100, rules: [rule])],
            courses: [], fetchedAt: Self.now)
    }

    @Test("round trip keeps everything, with a missing file reading as empty")
    func roundTrip() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DegreeAuditStore(directory: directory)
        #expect(store.load() == .empty)
        let degree = StudentDegree(raw: ["degc": "BSE", "coll": "EU", "levl": "UG", "major": "CSCI", "program": "EU_BSE"])
        let snapshot = DegreeSnapshot(
            current: audit("CIS"), whatIfs: [audit("MATH")],
            degrees: [degree], selectedDegreeID: degree.id,
            programs: [PathProgramListing(code: "MATH-MIN", title: "Mathematics Minor")],
            dictionaries: PathDictionaries(majors: ["CSCI": "Computer Science"]),
            lastShape: ["audit: a, b"])
        try store.save(snapshot)
        #expect(store.fileURL.lastPathComponent == "degree-audit.json")
        #expect(store.load() == snapshot)
    }

    @Test("history round-trips, and a snapshot without the key decodes with none")
    func history() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DegreeAuditStore(directory: directory)
        let snapshot = DegreeSnapshot(history: ["202610": ["CIS 1200", "MATH 1400"], "202630": ["CIS 1210"]])
        try store.save(snapshot)
        #expect(store.load().history == snapshot.history)
        let decoder = JSONDecoder()
        let bare = try decoder.decode(DegreeSnapshot.self, from: Data(#"{"whatIfs":[]}"#.utf8))
        #expect(bare.history.isEmpty)
    }

    @Test("a file written before the Path@Penn rewrite still decodes")
    func oldFormat() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DegreeAuditStore(directory: directory)
        let old = #"{"whatIfs":[],"catalog":{"majors":[{"key":"CIS","description":"cs"}]},"lastShape":["a"]}"#
        try Data(old.utf8).write(to: store.fileURL)
        let back = store.load()
        #expect(back.lastShape == ["a"])
        #expect(back.degrees.isEmpty)
        #expect(back.selectedDegreeID == nil)
        #expect(back.programs.isEmpty)
        #expect(back.dictionaries == nil)
        // Not quarantined: the file is still where it was.
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("whatIfs are capped at eight on save, most recent first kept")
    func cap() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DegreeAuditStore(directory: directory)
        let many = (0..<11).map { audit("M\($0)") }
        try store.save(DegreeSnapshot(current: nil, whatIfs: many, lastShape: []))
        let back = store.load()
        #expect(DegreeAuditStore.maxWhatIfs == 8)
        #expect(back.whatIfs.count == 8)
        #expect(back.whatIfs.map { $0.goals.majors[0] } == ["M0", "M1", "M2", "M3", "M4", "M5", "M6", "M7"])
    }

    @Test("option scores survive the store, and a file without the key decodes with none")
    func optionScores() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DegreeAuditStore(directory: directory)
        let score = DegreeOptionScore(fraction: 0.42, open: 7, readAt: Self.now)
        let snapshot = DegreeSnapshot(optionScores: [DegreeOptions.scoreKey(degreeID: "d1", programCode: "FNCS-BS"): score])
        try store.save(snapshot)
        let back = store.load()
        #expect(back.optionScores["d1|FNCS-BS"] == score)
        #expect(back == snapshot)
        let bare = try JSONDecoder().decode(DegreeSnapshot.self, from: Data(#"{"whatIfs":[]}"#.utf8))
        #expect(bare.optionScores.isEmpty)
    }

    @Test("an undecodable file is moved aside, never overwritten, and reads as empty")
    func lossy() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DegreeAuditStore(directory: directory)
        try Data("{ not a snapshot".utf8).write(to: store.fileURL)
        #expect(store.load(now: Self.now) == .empty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        let moved = directory.appendingPathComponent("degree-audit.json.corrupt-1800000000")
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(try String(contentsOf: moved, encoding: .utf8) == "{ not a snapshot")
    }

    @Test("clear removes the file and any quarantined copies, and nothing else")
    func clear() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DegreeAuditStore(directory: directory)
        try store.save(DegreeSnapshot(current: audit("CIS")))
        try Data("x".utf8).write(to: directory.appendingPathComponent("degree-audit.json.corrupt-1"))
        let other = directory.appendingPathComponent("keep.txt")
        try Data("k".utf8).write(to: other)
        store.clear()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("degree-audit.json.corrupt-1").path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(store.load() == .empty)
    }

    @Test("the default store lives under LowHangingFruit/")
    func defaultLocation() {
        let url = DegreeAuditStore.default().fileURL
        #expect(url.lastPathComponent == "degree-audit.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "LowHangingFruit")
    }

    // MARK: Shelves

    @Test("selecting shelves the old degree's audit and what-ifs and restores the new one's")
    func selectingShelves() {
        let snapshot = DegreeSnapshot(
            current: audit("A"), whatIfs: [audit("AW")],
            selectedDegreeID: "a",
            shelved: ["b": DegreeShelf(audit: audit("B"), whatIfs: [audit("BW")])])
        let moved = snapshot.selecting("b", from: "a")
        #expect(moved.selectedDegreeID == "b")
        #expect(moved.current == audit("B"))
        #expect(moved.whatIfs == [audit("BW")])
        #expect(moved.shelved["a"] == DegreeShelf(audit: audit("A"), whatIfs: [audit("AW")]))
        #expect(moved.shelved["b"] == nil)
    }

    @Test("switching A to B and back returns the original audit and what-ifs")
    func roundTripSwitch() {
        let snapshot = DegreeSnapshot(
            current: audit("A"), whatIfs: [audit("AW")], selectedDegreeID: "a")
        let there = snapshot.selecting("b", from: "a")
        #expect(there.current == nil)
        #expect(there.whatIfs.isEmpty)
        let back = there.selecting("a", from: "b")
        #expect(back.current == snapshot.current)
        #expect(back.whatIfs == snapshot.whatIfs)
        #expect(back.selectedDegreeID == "a")
    }

    @Test("selecting the selected degree changes nothing")
    func selectingSame() {
        let snapshot = DegreeSnapshot(
            current: audit("A"), whatIfs: [audit("AW")], selectedDegreeID: "a",
            shelved: ["b": DegreeShelf(audit: audit("B"))])
        #expect(snapshot.selecting("a", from: "a") == snapshot)
    }

    @Test("pruning drops unknown degrees and the selected one's shelf")
    func pruning() {
        let snapshot = DegreeSnapshot(
            current: audit("A"), selectedDegreeID: "a",
            shelved: [
                "a": DegreeShelf(audit: audit("stale")),
                "b": DegreeShelf(audit: audit("B")),
                "gone": DegreeShelf(audit: audit("G")),
            ])
        let pruned = snapshot.pruningShelves(keeping: ["a", "b"], selected: "a")
        #expect(Set(pruned.shelved.keys) == ["b"])
        #expect(pruned.current == audit("A"))
    }

    @Test("shelves survive the store, whatIfs on a shelf are capped, and an old file has none")
    func shelvesPersist() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DegreeAuditStore(directory: directory)
        let many = (0..<11).map { audit("W\($0)") }
        let snapshot = DegreeSnapshot(
            current: audit("A"), selectedDegreeID: "a",
            shelved: ["b": DegreeShelf(audit: audit("B"), whatIfs: many)])
        try store.save(snapshot)
        let back = store.load()
        #expect(back.shelved["b"]?.audit == audit("B"))
        #expect(back.shelved["b"]?.whatIfs.count == DegreeAuditStore.maxWhatIfs)
        #expect(back.shelved["b"]?.whatIfs.map { $0.goals.majors[0] } == ["W0", "W1", "W2", "W3", "W4", "W5", "W6", "W7"])
        let decoder = JSONDecoder()
        let bare = try decoder.decode(DegreeSnapshot.self, from: Data(#"{"whatIfs":[]}"#.utf8))
        #expect(bare.shelved.isEmpty)
    }
}
