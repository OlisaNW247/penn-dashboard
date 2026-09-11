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

    /// A map built from the server's pooled `map-categories` mapping for a
    /// course whose syllabus grading scheme is `scheme` — the shared-backend
    /// twin of `suggested`, which builds the same shape from a syllabus
    /// matched locally. Pure reshaping, same as `suggested`'s own contract:
    /// the SERVER's answer is a suggestion the student confirms in the UI,
    /// never a second opinion this function itself renders. Every id and
    /// name the mapping carries is re-validated against this device's own
    /// `scheme`/`canvasCategories` rather than trusted outright — the
    /// server's own sanitizer (`_shared/categoryMap.ts`) already enforces
    /// "every id is one the request listed" and "an invented name is
    /// dropped," but trusting a value that traveled through a jsonb column
    /// to still mean what it meant when it was written is exactly the
    /// mistake CLAUDE.md's jsonb-drift trap describes, one hop later.
    ///
    /// - A `GradeCategoryMap.Category` is emitted for every one of
    ///   `scheme.normalizedCategories`, in scheme order, with the same id
    ///   (`"map:" + slug(name)`), name, weight and drop-lowest `suggested`
    ///   would use, and `.sharedProfile` provenance throughout. A category
    ///   `mapping` never mentions is still emitted, with empty
    ///   `canvasGroupIDs`.
    /// - A `mapping` category is matched to a scheme category by
    ///   `TitleNormalizer.categoryKey` equality; one that matches nothing is
    ///   dropped whole, so its ids claim nothing.
    /// - Group and item ids are otherwise "first mapping category (in
    ///   `mapping.categories`' own order) to claim it wins," and only ids
    ///   this device's own `canvasCategories` actually has — an id the
    ///   pooled mapping names that no longer exists on Canvas is silently
    ///   dropped rather than resurrected.
    /// - `excludedItemIDs` is `mapping.excludedItemIDs` filtered to known
    ///   item ids, minus any id a category also claimed via its own
    ///   `itemIDs` — that tie goes to the category, since being assigned
    ///   somewhere is a stronger, more specific fact than "excluded," and an
    ///   item can't sensibly be both. `exclusionReasons` carries
    ///   `mapping.reasons[id]` only for ids that stay excluded.
    /// - `expectedCount` precedence per category: the syllabus's own
    ///   `expectedItemCount`, then the matched mapping category's
    ///   `expectedCount`, then `defaultExpectedCount(forCategoryName:)`,
    ///   then 1 for an attendance/participation name — the exact same chain
    ///   `suggested` uses, just with the pooled mapping's count slotted in
    ///   as the middle fallback.
    public static func fromSharedMapping(
        _ mapping: SharedCategoryMapping,
        scheme: SyllabusGradingScheme,
        canvasCategories: [GradeCategory]
    ) -> GradeCategoryMap {
        let normalized = scheme.normalizedCategories
        let knownGroupIDs = Set(canvasCategories.map(\.id))
        let knownItemIDs = Set(canvasCategories.flatMap { $0.items.map(\.id) })

        var schemeByKey: [String: SyllabusCategory] = [:]
        for syllabusCategory in normalized {
            schemeByKey[TitleNormalizer.categoryKey(syllabusCategory.name)] = syllabusCategory
        }

        func categoryID(for syllabusCategory: SyllabusCategory) -> String {
            "map:" + GradeCategoryMap.slug(syllabusCategory.name)
        }

        // Only a mapping category that names a real scheme category gets to
        // claim anything — one that matches nothing is dropped whole, the
        // same "an invented name is dropped, category and all" rule the
        // server's own sanitizer already applies one hop earlier.
        // A duplicate name (two mapping entries both called "Quizzes") keeps
        // only the first: letting the second claim ids it can never emit
        // would reserve those ids away from a later category for nothing.
        var seenKeys: Set<String> = []
        let matched: [(scheme: SyllabusCategory, mapping: SharedCategoryMapping.Category)] = mapping.categories.compactMap { candidate in
            let key = TitleNormalizer.categoryKey(candidate.name)
            guard let syllabusCategory = schemeByKey[key], seenKeys.insert(key).inserted else { return nil }
            return (syllabusCategory, candidate)
        }

        // First-claim-wins for group and item ids, evaluated in `mapping`'s
        // own array order, and only ever against ids this device's Canvas
        // actually has.
        var groupClaims: [String: String] = [:]
        var itemClaims: [String: String] = [:]
        for (syllabusCategory, mappingCategory) in matched {
            let id = categoryID(for: syllabusCategory)
            for groupID in mappingCategory.canvasGroupIDs where knownGroupIDs.contains(groupID) {
                if groupClaims[groupID] == nil { groupClaims[groupID] = id }
            }
            for itemID in mappingCategory.itemIDs where knownItemIDs.contains(itemID) {
                if itemClaims[itemID] == nil { itemClaims[itemID] = id }
            }
        }

        // The first mapping category matched to each scheme category, kept
        // only for `expectedCount` — group/item CLAIMS above already used
        // every matched entry, not just the first, but `expectedCount` isn't
        // a claimed id, so "first match wins" is the simplest well-defined
        // answer for the (expected to be rare) case of a duplicate name.
        var firstMatchByKey: [String: SharedCategoryMapping.Category] = [:]
        for (syllabusCategory, mappingCategory) in matched {
            let key = TitleNormalizer.categoryKey(syllabusCategory.name)
            if firstMatchByKey[key] == nil { firstMatchByKey[key] = mappingCategory }
        }

        let categories: [GradeCategoryMap.Category] = normalized.map { syllabusCategory in
            let id = categoryID(for: syllabusCategory)
            let key = TitleNormalizer.categoryKey(syllabusCategory.name)
            let mappingCategory = firstMatchByKey[key]

            let groupIDs = (mappingCategory?.canvasGroupIDs ?? []).filter {
                knownGroupIDs.contains($0) && groupClaims[$0] == id
            }

            let expected = syllabusCategory.expectedItemCount
                ?? mappingCategory?.expectedCount
                ?? defaultExpectedCount(forCategoryName: syllabusCategory.name)
                ?? (GradeItemClassifier.isAttendanceCategoryName(syllabusCategory.name) ? 1 : nil)

            return GradeCategoryMap.Category(
                id: id,
                name: syllabusCategory.name,
                weightPercent: syllabusCategory.weightPercent,
                expectedCount: expected,
                dropLowest: syllabusCategory.dropLowest,
                canvasGroupIDs: groupIDs,
                provenance: .sharedProfile
            )
        }

        var map = GradeCategoryMap(categories: categories, provenance: .sharedProfile)
        map.itemAssignments = itemClaims

        // The excluded/assigned tie goes to the category: an id a category
        // also claimed via `itemIDs` is not excluded even if `mapping` also
        // listed it in `excludedItemIDs` — being assigned somewhere is a
        // more specific, stronger fact than "excluded," and an item can't
        // sensibly be both at once.
        let excluded = mapping.excludedItemIDs.filter { knownItemIDs.contains($0) && itemClaims[$0] == nil }
        map.excludedItemIDs = Set(excluded)
        for id in excluded {
            if let reason = mapping.reasons[id] {
                map.exclusionReasons[id] = reason
            }
        }

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
