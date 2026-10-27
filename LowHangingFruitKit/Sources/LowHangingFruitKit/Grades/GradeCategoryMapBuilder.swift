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

        // First match wins if a syllabus ever repeats a category id. The
        // matcher emits one match per syllabus category, so a scheme with a
        // repeated id (the server-profile path used to allow it) yields two
        // matches under one key, and `uniqueKeysWithValues` traps on that.
        let matchBySyllabusID = Dictionary(
            (match?.matches ?? []).map { ($0.syllabusCategoryID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Ids are derived from names, and two different names can slug the
        // same ("Quiz (EC)" / "Quiz - EC"). A bare `"map:" + slug` would then
        // give two categories one id, and everything downstream that keys on
        // the id (`GradeEngine`'s lookups, the regrouper, a student's saved
        // edits) would collapse or trap. The first holder of a slug keeps the
        // bare id, so a name that doesn't collide stays exactly where a
        // student's persisted edit and a saved server mapping already point.
        let normalized = scheme.normalizedCategories
        let ids = disambiguatedIDs(normalized.map { "map:" + GradeCategoryMap.slug($0.name) })

        let categories: [GradeCategoryMap.Category] = normalized.enumerated().map { index, syllabusCategory in
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
                id: ids[index],
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
        // Canvas lets a course carry two groups whose names slug the same
        // ("Homework" and "homework", "Quiz (EC)" and "Quiz - EC", or a
        // recycled site with two "Assignments" groups). With a bare
        // `"map:" + slug` they shared one id and `GradeEngine` trapped on the
        // duplicate key at every launch, because the sync computes a grade
        // for every course whether or not the grades screen is open. A
        // name that doesn't collide keeps the id a student's saved edits and
        // a server mapping are keyed on. Among groups that do collide, the
        // one with the LOWEST Canvas group id keeps the bare id and every
        // other is suffixed with its own Canvas group id. The winner is
        // chosen by id and not by position because a fetch order is not a
        // key: nothing between the Canvas response and here sorts, so with
        // position deciding, two groups with the same Canvas position and
        // case-insensitively equal names could swap between fetches and a
        // weight override saved on the bare id would jump to the other
        // group. The wrong fix is dropping the later group: that silently
        // loses the weight and items it carries, which is worse than a
        // duplicate-looking row.
        let ids = disambiguatedIDs(
            canvasCategories.map { "map:" + GradeCategoryMap.slug($0.name) },
            holdsBareID: { a, b in
                Self.canvasGroupID(canvasCategories[a].id, precedes: canvasCategories[b].id)
            },
            tag: { index, _ in canvasCategories[index].id }
        )
        let categories: [GradeCategoryMap.Category] = canvasCategories.enumerated().map { index, canvas in
            GradeCategoryMap.Category(
                id: ids[index],
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
    ///   `canvasGroupIDs`. Where two scheme names slug the same the later
    ///   one's id is disambiguated (see `disambiguatedIDs`).
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

        // Same collision rule as `suggested`: two scheme names that slug the
        // same must not share an id, and the first holder keeps the bare one.
        let ids = disambiguatedIDs(normalized.map { "map:" + GradeCategoryMap.slug($0.name) })

        var schemeByKey: [String: SyllabusCategory] = [:]
        // The id a mapping category's claims are recorded under: the LAST
        // scheme category with that `categoryKey`, exactly as `schemeByKey`
        // itself has always been overwritten. Two scheme categories can share
        // a key with different slugs ("Quiz" / "Quizzes"), and before ids were
        // disambiguated the claim already went to the later one. Keeping that
        // keeps this hotfix from changing behaviour for any input that never
        // collided on an id.
        var claimIDByKey: [String: String] = [:]
        for (index, syllabusCategory) in normalized.enumerated() {
            let key = TitleNormalizer.categoryKey(syllabusCategory.name)
            schemeByKey[key] = syllabusCategory
            claimIDByKey[key] = ids[index]
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
            guard let id = claimIDByKey[TitleNormalizer.categoryKey(syllabusCategory.name)] else { continue }
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

        let categories: [GradeCategoryMap.Category] = normalized.enumerated().map { index, syllabusCategory in
            let id = ids[index]
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

    /// Canvas group ids are numeric strings, so compare them as numbers
    /// ("9" before "10"), and fall back to string order only so the answer is
    /// still deterministic for an id that isn't a number. Numeric ids sort
    /// ahead of non-numeric ones, which keeps this a strict total order: a
    /// rule that compared numerically only when BOTH parse would not be
    /// transitive on a mixed set, and "lowest id wins" would then depend on
    /// input order again, the thing it exists to remove.
    private static func canvasGroupID(_ a: String, precedes b: String) -> Bool {
        switch (Int(a), Int(b)) {
        case let (x?, y?): return x < y
        case (_?, nil):    return true
        case (nil, _?):    return false
        case (nil, nil):   return a < b
        }
    }

    /// Turns a list of candidate ids, in order, into a list of distinct ones.
    /// The first occurrence of a base keeps it unchanged; each later
    /// occurrence becomes `base + "-" + tag(index, occurrence)`, where
    /// `occurrence` is 1-based (so the second holder of a slug gets `-2` by
    /// default). Only a collision ever changes an id, because a category id
    /// is persisted (a student's edits, a pooled server mapping, a confirmed
    /// syllabus) and one that doesn't collide must not move.
    ///
    /// `holdsBareID` overrides who keeps the bare id among equal bases:
    /// `holdsBareID(a, b)` is true when the entry at index `a` should hold it
    /// ahead of the one at `b` (a tie goes to the earlier index). The default,
    /// the first occurrence, is right when the input order is itself
    /// persisted (a syllabus's category order); it is wrong for a list whose
    /// order is just whatever a network response happened to carry.
    ///
    /// A candidate is also checked against every base in the list, not just
    /// against ids already handed out: a later category can legitimately own
    /// the bare id a suffixed one would land on (`"map:homework-2"` is both
    /// the second "Homework" and the only "Homework 2"), and the bare id
    /// always belongs to whoever's name produced it. A clash bumps the
    /// candidate rather than the bare id.
    static func disambiguatedIDs(
        _ bases: [String],
        holdsBareID: ((_ a: Int, _ b: Int) -> Bool)? = nil,
        tag: (_ index: Int, _ occurrence: Int) -> String = { _, occurrence in String(occurrence) }
    ) -> [String] {
        let reserved = Set(bases)
        var holder: [String: Int] = [:]
        for (index, base) in bases.enumerated() {
            if let current = holder[base] {
                if let holdsBareID, holdsBareID(index, current) { holder[base] = index }
            } else {
                holder[base] = index
            }
        }
        var used: Set<String> = []
        var occurrences: [String: Int] = [:]
        var result: [String] = []
        result.reserveCapacity(bases.count)
        for (index, base) in bases.enumerated() {
            let occurrence = (occurrences[base] ?? 0) + 1
            occurrences[base] = occurrence
            if holder[base] == index {
                used.insert(base)
                result.append(base)
                continue
            }
            let stem = base + "-" + tag(index, occurrence)
            var candidate = stem
            var bump = 2
            while reserved.contains(candidate) || used.contains(candidate) {
                candidate = stem + "-" + String(bump)
                bump += 1
            }
            used.insert(candidate)
            result.append(candidate)
        }
        return result
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
