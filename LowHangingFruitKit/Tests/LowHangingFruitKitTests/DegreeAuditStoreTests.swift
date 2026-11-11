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

    @Test("whatIfs are capped at five on save, most recent first kept")
    func cap() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DegreeAuditStore(directory: directory)
        let many = (0..<8).map { audit("M\($0)") }
        try store.save(DegreeSnapshot(current: nil, whatIfs: many, lastShape: []))
        let back = store.load()
        #expect(back.whatIfs.count == 5)
        #expect(back.whatIfs.map { $0.goals.majors[0] } == ["M0", "M1", "M2", "M3", "M4"])
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
}
