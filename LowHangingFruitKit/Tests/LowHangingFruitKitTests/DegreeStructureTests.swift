import Foundation
import Testing
import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Where the degree page is wired in, and that its fixture carries nothing
/// personal.
@Suite("Degree structure")
struct DegreeStructureTests {
    private func uiSource(_ filename: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI")
        return try String(contentsOf: sources.appendingPathComponent(filename), encoding: .utf8)
    }

    @Test("the profile row comes before the classes and is gated")
    func profileRowFirst() throws {
        let source = try uiSource("ProfileClassesSection.swift")
        let row = try #require(source.range(of: "degreeRow\n"))
        let loop = try #require(source.range(of: "ForEach(courses, id: \\.self)"))
        #expect(row.lowerBound < loop.lowerBound)
        #expect(source.contains("state.degreeFeatureAvailable"))
        #expect(source.contains("ContentView.DashRoute.degree"))
    }

    @Test("the route, its destination and the debug argument exist")
    func route() throws {
        let source = try uiSource("ContentView.swift")
        #expect(source.contains("case degree"))
        #expect(source.contains("DegreeProgressView()"))
        #expect(source.contains("-LHFShowDegree"))
    }

    @Test("the sample snapshot has a current audit and one what-if")
    func sample() {
        let snapshot = SampleData.degreeSnapshot()
        #expect(snapshot.current != nil)
        #expect(snapshot.whatIfs.count == 1)
        #expect(snapshot.whatIfs.first?.isWhatIf == true)
    }

    @Test("the sample snapshot's JSON has no gpa, grade or email keys")
    func sampleHasNothingPersonal() throws {
        let data = try JSONEncoder().encode(SampleData.degreeSnapshot())
        let text = try #require(String(data: data, encoding: .utf8)).lowercased()
        for word in ["gpa", "grade", "email"] {
            #expect(!text.contains("\"\(word)"), "\(word) key found")
        }
    }

    @Test("the ring and the profile row say the same thing")
    func ringMatchesSummary() throws {
        let audit = try #require(SampleData.degreeSnapshot().current)
        let ring = DegreeProgressMath.ring(for: audit)
        #expect(ring.fraction >= 0 && ring.fraction <= 1)
        let spoken = ring.caption.isEmpty ? ring.centre : "\(ring.centre) \(ring.caption)"
        #expect(DegreeProgressMath.profileSummary(audit) == spoken)
    }

    @Test("the ring follows Penn's percent when the audit has one")
    func ringPercent() {
        let audit = DegreeAudit(goals: DegreeGoals(), isWhatIf: false, percentComplete: 62.4,
                                degreeLabel: nil, catalogYearLabel: nil, blocks: [], courses: [],
                                fetchedAt: Date(timeIntervalSince1970: 0))
        let ring = DegreeProgressMath.ring(for: audit)
        #expect(abs(ring.fraction - 0.624) < 0.0001)
        #expect(ring.centre == "62%")
        #expect(DegreeProgressMath.profileSummary(audit) == "62%")
    }

    @Test("an empty synthetic block is skipped, a real one is kept")
    func emptyBlocks() {
        let empty = AuditBlock(id: "a", type: "CL_SYNTHETIC_BLOCK", value: "", title: "Exceptions Applied",
                               percentComplete: nil, rules: [])
        let major = AuditBlock(id: "b", type: "MAJOR", value: "", title: "Major", percentComplete: 0, rules: [])
        #expect(!DegreeProgressMath.isShown(empty))
        #expect(DegreeProgressMath.isShown(major))
    }

    @Test("the progress view switches degrees and reads Penn's credit sentence")
    func progressWiring() throws {
        let source = try uiSource("DegreeProgressView.swift")
        #expect(source.contains("selectDegree("))
        #expect(source.contains("PathAuditDecoder.creditTotals"))
    }

    @Test("neither view mentions the removed Degree Works machinery")
    func noOldMachinery() throws {
        for file in ["DegreeProgressView.swift", "DegreeWhatIfSheet.swift"] {
            let source = try uiSource(file)
            for name in ["DegreeGoalCatalog", "DegreeWorks", "pickCurrentGoals", "loadDegreeCatalog"] {
                #expect(!source.contains(name), "\(file) mentions \(name)")
            }
        }
    }
}
