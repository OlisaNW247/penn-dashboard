import Foundation

/// Turns a syllabus (plus its Canvas match) — or, failing that, Canvas's own
/// assignment groups — into a `GradeCategoryMap`, so every course goes
/// through the SAME downstream code path (`GradeRegrouper` → `GradeEngine`)
/// regardless of whether a syllabus exists yet.
public enum GradeCategoryMapBuilder {
    /// A suggested map from a syllabus scheme and its Canvas match. `nil`
    /// exactly when there is no scheme to build from — everything else here
    /// is a pure reshaping of what `SyllabusMatcher.match` already decided,
    /// never a second opinion about which Canvas group belongs where.
    public static func suggested(
        scheme: SyllabusGradingScheme?,
        match: SyllabusMatcher.Result?,
        canvasCategories: [GradeCategory],
        provenance: GradeCategoryMap.Provenance
    ) -> GradeCategoryMap? {
        guard let scheme else { return nil }

        let matchBySyllabusID = Dictionary(
            uniqueKeysWithValues: (match?.matches ?? []).map { ($0.syllabusCategoryID, $0) }
        )

        let categories: [GradeCategoryMap.Category] = scheme.normalizedCategories.map { syllabusCategory in
            // Only an APPLIED match's groups count here — a fuzzy proposal
            // the student hasn't confirmed must not silently start counting
            // toward the grade just because a map got built around it.
            let appliedGroupIDs = matchBySyllabusID[syllabusCategory.id]
                .map { $0.isApplied ? $0.canvasCategoryIDs : [] } ?? []

            // Precedence: what the syllabus explicitly said, then the
            // singular-exam-name default ("Midterm 1" implies exactly one),
            // then — since the syllabus text itself doesn't usually spell out
            // "there will be 1 attendance category" the way it does for
            // problem sets — an attendance/participation category defaults
            // to 1 too, so `semesterDecidedFraction` has something to divide
            // by the moment Canvas's attendance tool posts its one item,
            // instead of reading as permanently "unknown."
            let expected = syllabusCategory.expectedItemCount
                ?? defaultExpectedCount(forCategoryName: syllabusCategory.name)
                ?? (GradeItemClassifier.isAttendanceCategoryName(syllabusCategory.name) ? 1 : nil)

            return GradeCategoryMap.Category(
                id: "map:" + GradeCategoryMap.slug(syllabusCategory.name),
                name: syllabusCategory.name,
                weightPercent: syllabusCategory.weightPercent,
                expectedCount: expected,
                dropLowest: syllabusCategory.dropLowest,
                canvasGroupIDs: appliedGroupIDs,
                provenance: provenance
            )
        }

        // Unmatched Canvas groups are simply absent from every category
        // above — `GradeRegrouper` is what turns that absence into a visible
        // zero-weight "needs a home" entry, so this function doesn't need to
        // do anything special for them itself.
        var map = GradeCategoryMap(categories: categories, provenance: provenance)
        applyAutoAssignments(to: &map, canvasCategories: canvasCategories)
        return map
    }

    /// A map that mirrors Canvas's groups one-to-one, carrying Canvas's own
    /// weights — for a course with no syllabus attached, so the UI (editing
    /// weights, seeing what's excluded) has exactly one data shape to render
    /// whether or not a syllabus exists. `courseUsesWeights` mirrors
    /// `GradeEngine.Input.courseUsesWeights`'s own rule for when a group's
    /// weight means anything (docs/grades.md §1): when false, every category
    /// gets weight 0 here for the same reason `GradeEngine.tally` does — a
    /// weight Canvas doesn't apply is garbage, not a real number to carry
    /// forward. Callers deciding whether a points-mode course should be
    /// wrapped in a category map at all (rather than left on the map-free
    /// path) is a decision this function deliberately doesn't make.
    public static func mirroringCanvas(_ canvasCategories: [GradeCategory], courseUsesWeights: Bool) -> GradeCategoryMap {
        let categories: [GradeCategoryMap.Category] = canvasCategories.map { canvas in
            GradeCategoryMap.Category(
                id: "map:" + GradeCategoryMap.slug(canvas.name),
                name: canvas.name,
                weightPercent: courseUsesWeights ? (canvas.weight ?? 0) : 0,
                dropLowest: canvas.dropLowest,
                canvasGroupIDs: [canvas.id],
                provenance: .canvas
            )
        }
        var map = GradeCategoryMap(categories: categories, provenance: .canvas)
        applyAutoAssignments(to: &map, canvasCategories: canvasCategories)
        return map
    }

    /// 1 for a singular exam-like name ("Midterm", "Midterm 1", "Final",
    /// "Exam 2", "Test") — a syllabus rarely bothers to say "there will be
    /// one final," but the name itself already promises exactly one. `nil`
    /// for anything else (including plurals like "Midterms" or "Exams",
    /// which don't make that promise): the syllabus's own stated count, or no
    /// count at all, is what other categories fall back to.
    public static func defaultExpectedCount(forCategoryName name: String) -> Int? {
        let pattern = #"^(midterm|exam|final|test)( \d+)?$"#
        guard name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        return 1
    }

    /// Shared tail of both builders: fold `GradeItemClassifier`'s automatic
    /// attendance/placeholder handling into a freshly-built map. Uses
    /// `formUnion`/only-if-absent merges (mirroring `autoAssignments`'s own
    /// contract of only ever adding entries for items neither list already
    /// covers) even though a brand-new map is always empty at this point, so
    /// this stays correct if a future caller ever re-runs it against a map
    /// that already carries some assignments.
    private static func applyAutoAssignments(to map: inout GradeCategoryMap, canvasCategories: [GradeCategory]) {
        let auto = GradeItemClassifier.autoAssignments(canvasCategories: canvasCategories, map: map)
        for (itemID, categoryID) in auto.itemAssignments {
            map.itemAssignments[itemID] = categoryID
        }
        map.excludedItemIDs.formUnion(auto.excludedItemIDs)
        for (itemID, reason) in auto.reasons {
            map.exclusionReasons[itemID] = reason
        }
    }
}
