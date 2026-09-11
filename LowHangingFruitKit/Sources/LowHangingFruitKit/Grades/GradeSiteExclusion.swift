import Foundation

/// Decides whether a Canvas site should be left out of Grade Watcher by
/// default because it's a zero-credit or pass/fail *component* of a course
/// rather than the site that actually carries the grade — the case this
/// exists for is PHYS 0151, whose 1.0 CU lecture and 0.5 CU pass/fail lab
/// are two separate Canvas sites sharing one course code, and where
/// including the lab's assignments in the student's overall grade would be
/// simply wrong, not just unhelpful.
///
/// This is a *default*, not a lock: it decides what Grade Watcher suggests
/// the first time it sees a site, not a permanent ban a student can't
/// override in `CoursePreferences`. Nothing here writes to the ledger or to
/// preferences — it's a pure predicate over synced catalog/profile data, so
/// the caller (the UI's per-course settings, outside this Kit) is free to
/// call it once at first sight of a course and let the student flip it
/// however they like afterward.
public enum GradeSiteExclusion {
    /// A pass/fail (or satisfactory/unsatisfactory) grading basis, as the
    /// syllabus extraction's free-text `gradingBasis` might phrase it.
    /// Deliberately narrow: "credit/no credit," "audit," and other bases
    /// that don't map cleanly to "doesn't carry the numeric grade" are left
    /// alone rather than guessed at, because a false positive here silently
    /// drops real graded work from a student's average — the failure mode
    /// this whole type exists to prevent, not cause.
    private static let passFailBasis = try? NSRegularExpression(
        pattern: #"pass.?fail|\bp/f\b|satisfactory|s/u\b"#,
        options: [.caseInsensitive]
    )

    /// The words that identify a `CatalogComponent.activity` /
    /// `CourseGradingProfile.Component.name` / site name as this kind of
    /// component. Keyed by the registrar's own activity codes
    /// (`ClassMeeting.activity`'s vocabulary) so the same lookup drives
    /// both the profile-component match and the site-name fallback.
    private static let activityWords: [String: [String]] = [
        "LAB": ["lab", "laboratory"],
        "REC": ["recitation"],
        "LEC": ["lecture"],
    ]

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        let lower = haystack.lowercased()
        return needles.contains { lower.contains($0) }
    }

    /// The syllabus profile's component that talks about the given
    /// registrar activity (e.g. a "LAB" activity matching a profile
    /// component named "Lab" or "Laboratory Sessions"), if any.
    private static func profileComponent(forActivity activity: String, in profile: CourseGradingProfile) -> CourseGradingProfile.Component? {
        guard let words = activityWords[activity.uppercased()] else { return nil }
        return profile.components.first { containsAny($0.name, words) }
    }

    /// True when this Canvas site is a component that does not carry the
    /// course grade.
    ///
    /// - Parameter siblingSiteCount: the number of Canvas sites for this
    ///   course code, including this one. A course with only one site *is*
    ///   the whole class regardless of how few credits the registrar lists
    ///   for it — Penn has genuinely small full courses — so exclusion is
    ///   only ever a statement about *one component among several*, never
    ///   about a standalone course being "too small to count."
    public static func isAutomaticallyExcluded(
        summary: CourseSummary,
        siblingSiteCount: Int,
        catalog: CourseCatalogEntry?,
        profile: CourseGradingProfile?
    ) -> Bool {
        guard siblingSiteCount >= 2 else { return false }

        // Resolve this site's own registrar component, the same way
        // `DocumentComponent.siteIdentityComponent(for:in:)` builds the
        // lookup key: the catalog's own code spelling plus a dash plus
        // this site's section token, e.g. "PHYS-0151" + "-" + "151".
        let component: CatalogComponent? = {
            guard let catalog else { return nil }
            if let section = summary.section {
                // Suffix match rather than an exact key, exactly as
                // `siteIdentityComponent` does: the registrar's section ids
                // are "PHYS-0151-402" while a code can be spelled with a
                // space or a dash depending on which side produced it, and
                // the section token is the part that identifies the site.
                if let bySection = catalog.components.first(where: { c in
                    c.sectionIDs.contains { $0.hasSuffix("-\(section)") }
                }) {
                    return bySection
                }
            }
            // The real PHYS 0151 lab site is named
            // "PHYS 0151 202630 Physics Laboratory" — no section token at
            // all, because the lab is one Canvas site for every lab section.
            // Its registrar component is still knowable from the name: a
            // site that calls itself a lab or a recitation is that activity's
            // site, and the catalog says what that activity is worth. This
            // is the branch that fires for the case that motivated the rule.
            let nameWords = summary.name
            if containsAny(nameWords, activityWords["LAB"] ?? []) {
                return catalog.components.first { $0.activity.uppercased() == "LAB" }
            }
            if containsAny(nameWords, activityWords["REC"] ?? []) {
                return catalog.components.first { $0.activity.uppercased() == "REC" }
            }
            return nil
        }()

        // Rule 1: the registrar itself says this component carries no
        // course units. This is the strongest signal available — it comes
        // straight from the catalog, not from an LLM's reading of a
        // syllabus — so it's checked first and on its own is sufficient.
        if let credits = component?.credits, credits == 0 {
            return true
        }

        // Rule 2: the syllabus extraction says this component's activity is
        // graded pass/fail (or satisfactory/unsatisfactory). Requires both
        // a resolved registrar activity *and* a profile component whose
        // name plausibly refers to that same activity — matching on
        // `gradingBasis` alone, without first tying it to this site's own
        // component, would risk pulling in an unrelated pass/fail piece of
        // the syllabus (e.g. a pass/fail final project) and mislabeling
        // this site because of it.
        if let component, let profile,
           let matchedProfileComponent = profileComponent(forActivity: component.activity, in: profile),
           let basis = matchedProfileComponent.gradingBasis,
           matches(passFailBasis, basis) {
            return true
        }

        // Fallback: no registrar component resolved at all (an older
        // catalog sync, or a section the registrar's component list
        // doesn't cover), but the site's own name says "lab" and the
        // syllabus extraction independently has a pass/fail lab component.
        // Two independent signals agreeing is the bar here precisely
        // because neither one alone is trustworthy in this branch: a site
        // name alone is just a label a professor chose, and a lab
        // component elsewhere in the syllabus doesn't prove *this* site is
        // it.
        if component == nil, let profile {
            let siteNameSaysLab = containsAny(summary.name, activityWords["LAB"] ?? [])
            if siteNameSaysLab,
               let labComponent = profileComponent(forActivity: "LAB", in: profile),
               let basis = labComponent.gradingBasis,
               matches(passFailBasis, basis) {
                return true
            }
        }

        return false
    }
}
