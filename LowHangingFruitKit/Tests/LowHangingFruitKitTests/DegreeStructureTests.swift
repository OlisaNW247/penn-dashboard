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

    @Test("the ring reads credits when the degree block says them")
    func ringCredits() throws {
        let audit = try #require(SampleData.degreeSnapshot().current)
        let ring = DegreeProgressMath.ring(for: audit)
        #expect(ring.caption == "of 40 cu")
        #expect(ring.centre == "31")
        #expect(ring.fraction > 0 && ring.fraction <= 1)
    }
}
