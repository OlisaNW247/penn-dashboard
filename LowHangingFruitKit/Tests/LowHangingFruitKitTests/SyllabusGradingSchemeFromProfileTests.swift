import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for `SyllabusGradingScheme.from(profile:)` — turning the
/// backend's syllabus extraction (`CourseGradingProfile`) into the same
/// on-device proposal type `SyllabusParser.parse` produces, gated by the
/// same honesty rules.
@Suite("SyllabusGradingScheme.from(profile:)")
struct SyllabusGradingSchemeFromProfileTests {
    private static func profile(weights: [CourseGradingProfile.Weight]) -> CourseGradingProfile {
        CourseGradingProfile(courseID: "1234", weights: weights, components: [], extractedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("two weights summing to 100 produces a high-confidence scheme")
    func twoWeightsSummingTo100IsHigh() throws {
        let profile = Self.profile(weights: [
            CourseGradingProfile.Weight(name: "Problem Sets", percent: 40),
            CourseGradingProfile.Weight(name: "Final", percent: 60),
        ])
        let scheme = try #require(SyllabusGradingScheme.from(profile: profile))
        #expect(scheme.confidence == .high)
        #expect(scheme.categories.count == 2)
        #expect(scheme.rawWeightSum == 100)
        #expect(scheme.cutoffs == nil)
        #expect(!scheme.mentionsCurve)
        #expect(scheme.categories.allSatisfy { $0.evidence == "from the syllabus, read by locust's server" })
    }

    @Test("three weights summing to 95 produces a medium-confidence scheme")
    func threeWeightsSummingTo95IsMedium() throws {
        let profile = Self.profile(weights: [
            CourseGradingProfile.Weight(name: "Problem Sets", percent: 30),
            CourseGradingProfile.Weight(name: "Midterm", percent: 30),
            CourseGradingProfile.Weight(name: "Final", percent: 35),
        ])
        let scheme = try #require(SyllabusGradingScheme.from(profile: profile))
        #expect(scheme.confidence == .medium)
        #expect(scheme.rawWeightSum == 95)
    }

    @Test("a single weight returns nil, the same gate SyllabusParser.parse applies")
    func singleWeightReturnsNil() {
        let profile = Self.profile(weights: [CourseGradingProfile.Weight(name: "Final", percent: 100)])
        #expect(SyllabusGradingScheme.from(profile: profile) == nil)
    }

    @Test("weights summing to 120 (outside the accepted band) return nil")
    func sumOutsideAcceptedBandReturnsNil() {
        let profile = Self.profile(weights: [
            CourseGradingProfile.Weight(name: "Problem Sets", percent: 60),
            CourseGradingProfile.Weight(name: "Final", percent: 60),
        ])
        #expect(SyllabusGradingScheme.from(profile: profile) == nil)
    }

    @Test("expected counts and drop rules carry through to the category")
    func expectedCountsAndDropsCarry() throws {
        let profile = Self.profile(weights: [
            CourseGradingProfile.Weight(name: "Problem Sets", percent: 40, expectedCount: 10, dropLowest: 2),
            CourseGradingProfile.Weight(name: "Final", percent: 60),
        ])
        let scheme = try #require(SyllabusGradingScheme.from(profile: profile))
        let psets = try #require(scheme.categories.first { $0.name == "Problem Sets" })
        #expect(psets.expectedItemCount == 10)
        #expect(psets.dropLowest == 2)

        let final = try #require(scheme.categories.first { $0.name == "Final" })
        // No drop rule stated for this weight -> defaults to 0, not left nil,
        // matching `SyllabusCategory.dropLowest`'s non-optional Int.
        #expect(final.dropLowest == 0)
        #expect(final.expectedItemCount == nil)
    }
}
