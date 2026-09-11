import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for `GradeSiteExclusion.isAutomaticallyExcluded` — deciding
/// whether a Canvas site is a zero-credit or pass/fail *component* of a
/// course (PHYS 0151's lab) that Grade Watcher should default to leaving
/// out of the student's overall grade.
@Suite("GradeSiteExclusion")
struct GradeSiteExclusionTests {
    private static let labSummary = CourseSummary(courseID: "2", code: "PHYS 0151", name: "PHYS 0151-151 Lab", url: nil, section: "151")
    private static let lectureSummary = CourseSummary(courseID: "1", code: "PHYS 0151", name: "PHYS 0151-401 Physics I", url: nil, section: "401")

    private static func catalog(labCredits: Double?, lectureCredits: Double? = 1.5) -> CourseCatalogEntry {
        CourseCatalogEntry(
            courseID: "1",
            catalogCode: "PHYS-0151",
            title: "Physics I",
            components: [
                CatalogComponent(activity: "LEC", credits: lectureCredits, sectionIDs: ["PHYS-0151-401"]),
                CatalogComponent(activity: "LAB", credits: labCredits, sectionIDs: ["PHYS-0151-151"]),
            ]
        )
    }

    private static func profile(labGradingBasis: String?) -> CourseGradingProfile {
        CourseGradingProfile(
            courseID: "1",
            weights: [],
            components: [CourseGradingProfile.Component(name: "Lab", gradingBasis: labGradingBasis, creditUnits: nil)],
            extractedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("the real PHYS lab: no section in the site name, resolved by the name to the catalog's zero-credit LAB component")
    func sectionlessLabSiteResolvesByName() {
        let sectionless = CourseSummary(courseID: "2", code: "PHYS 0151", name: "PHYS 0151 202630 Physics Laboratory", url: nil, section: nil)
        #expect(GradeSiteExclusion.isAutomaticallyExcluded(
            summary: sectionless, siblingSiteCount: 2, catalog: Self.catalog(labCredits: 0), profile: nil
        ))
        #expect(!GradeSiteExclusion.isAutomaticallyExcluded(
            summary: sectionless, siblingSiteCount: 2, catalog: Self.catalog(labCredits: 0.5), profile: nil
        ))
    }

    @Test("a course with only one Canvas site is never excluded, regardless of credits")
    func singleSiteNeverExcluded() {
        // Even a zero-credit-looking component shouldn't be excluded when
        // there is no sibling site — the course with one site *is* the
        // class.
        let excluded = GradeSiteExclusion.isAutomaticallyExcluded(
            summary: Self.labSummary,
            siblingSiteCount: 1,
            catalog: Self.catalog(labCredits: 0),
            profile: nil
        )
        #expect(!excluded)
    }

    @Test("a zero-credit lab section is excluded")
    func zeroCreditLabExcluded() {
        let excluded = GradeSiteExclusion.isAutomaticallyExcluded(
            summary: Self.labSummary,
            siblingSiteCount: 2,
            catalog: Self.catalog(labCredits: 0),
            profile: nil
        )
        #expect(excluded)
    }

    @Test("a 1.5-credit lecture section is not excluded")
    func lectureSectionNotExcluded() {
        let excluded = GradeSiteExclusion.isAutomaticallyExcluded(
            summary: Self.lectureSummary,
            siblingSiteCount: 2,
            catalog: Self.catalog(labCredits: 0),
            profile: nil
        )
        #expect(!excluded)
    }

    @Test("a pass/fail grading basis on the matched lab profile component is excluded")
    func passFailBasisExcluded() {
        // Catalog credits for the lab are unknown (nil), so rule 1 doesn't
        // fire — this isolates rule 2, the profile-basis match.
        let excluded = GradeSiteExclusion.isAutomaticallyExcluded(
            summary: Self.labSummary,
            siblingSiteCount: 2,
            catalog: Self.catalog(labCredits: nil),
            profile: Self.profile(labGradingBasis: "Pass/Fail")
        )
        #expect(excluded)
    }

    @Test("an unrelated grading basis on the profile component is not excluded")
    func unrelatedBasisNotExcluded() {
        let excluded = GradeSiteExclusion.isAutomaticallyExcluded(
            summary: Self.labSummary,
            siblingSiteCount: 2,
            catalog: Self.catalog(labCredits: nil),
            profile: Self.profile(labGradingBasis: "Letter grade")
        )
        #expect(!excluded)
    }

    @Test("falls back to the site's own name when no catalog component resolves")
    func siteNameFallback() {
        // No catalog entry at all, so `component(forSectionID:)` can never
        // resolve — the only signal left is the site's own name plus the
        // syllabus profile's independent lab/pass-fail match.
        let excluded = GradeSiteExclusion.isAutomaticallyExcluded(
            summary: Self.labSummary,
            siblingSiteCount: 2,
            catalog: nil,
            profile: Self.profile(labGradingBasis: "Satisfactory/Unsatisfactory")
        )
        #expect(excluded)
    }

    @Test("the site-name fallback does not fire when the profile has no matching lab component")
    func siteNameFallbackRequiresProfileMatch() {
        let excluded = GradeSiteExclusion.isAutomaticallyExcluded(
            summary: Self.labSummary,
            siblingSiteCount: 2,
            catalog: nil,
            profile: nil
        )
        #expect(!excluded)
    }
}
