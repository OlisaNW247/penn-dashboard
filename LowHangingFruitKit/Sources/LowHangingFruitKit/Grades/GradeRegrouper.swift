import Foundation

/// Rebuilds `GradeEngine`'s category list from a `GradeCategoryMap` instead
/// of straight off Canvas's assignment groups.
///
/// This is a pure reshuffle — it never invents a score, never drops a point
/// that wasn't explicitly excluded, and never silently discards a Canvas
/// group the map doesn't mention. A Canvas group with no home in the map
/// still comes out the other end, just carrying weight 0 (so it shows up in
/// the UI as "needs a home" instead of vanishing), because the whole promise
/// of the ledger tiers elsewhere in this app — nothing the student's data
/// says is ever silently lost — applies here too: a category map that's
/// wrong or incomplete must fail LOUD (an unmapped-groups list, a 0% weight
/// bucket), never quiet.
public enum GradeRegrouper {
    public struct Output: Sendable, Hashable {
        /// One `GradeCategory` per map category (in the map's own order),
        /// followed by one per Canvas group the map didn't claim (in the
        /// order those groups appeared in `canvasCategories`) — so nothing
        /// Canvas reported disappears from the category list.
        public let categories: [GradeCategory]
        /// Canvas group ids left over after every map category's
        /// `canvasGroupIDs` claimed what it could — the same ids that got
        /// their own zero-weight entry in `categories` above.
        public let unmappedGroupIDs: [String]
        /// Items whose category came from `GradeCategoryMap.itemAssignments`
        /// rather than from their Canvas group's fold — e.g. an attendance
        /// item pulled out of "Problem Sets" into "Attendance/Participation".
        public let movedItemIDs: Set<String>
        /// Items the map removed from the math entirely.
        public let excludedItemIDs: Set<String>
        /// Map category id → the display names of the Canvas groups folded
        /// into it, in `canvasGroupIDs` order — feeds
        /// `GradeExplanation.CategoryLine.groupsText`.
        public let groupNamesByCategoryID: [String: [String]]
    }

    public static func apply(_ map: GradeCategoryMap, to canvasCategories: [GradeCategory]) -> Output {
        let canvasByID = Dictionary(uniqueKeysWithValues: canvasCategories.map { ($0.id, $0) })

        // A Canvas group can be folded into at most one map category — the
        // map is the one place that decides this, so if a group somehow
        // appears in two categories' `canvasGroupIDs` (a malformed map), the
        // first category in `map.categories` order wins and the group is
        // simply absent from the second's fold, rather than the item being
        // double-counted in both.
        var groupIDToCategoryID: [String: String] = [:]
        for category in map.categories {
            for groupID in category.canvasGroupIDs where groupIDToCategoryID[groupID] == nil {
                groupIDToCategoryID[groupID] = category.id
            }
        }

        var itemsByCategoryID: [String: [GradeItem]] = [:]
        for category in map.categories { itemsByCategoryID[category.id] = [] }

        // Every Canvas group the map never claimed is registered up front,
        // items or not. Registering a group only when one of its items
        // reached the passthrough branch below looked equivalent and was
        // not: "Imported Assignments" on the real PHYS 0151 site is an
        // empty group early in the term, and an empty unclaimed group then
        // vanished from the output entirely -- no zero-weight entry, no
        // `unmappedGroupIDs` mention, nothing for the editor's "needs a
        // home" list to show. The contract above is that the map's
        // silence about a group is always visible; a group with nothing
        // in it yet is exactly the one a student has had no chance to
        // notice, so it is the one that most needs to be listed.
        var unmappedGroupItems: [String: [GradeItem]] = [:]
        var unmappedGroupOrder: [String] = []
        for canvasCategory in canvasCategories where groupIDToCategoryID[canvasCategory.id] == nil {
            unmappedGroupItems[canvasCategory.id] = []
            unmappedGroupOrder.append(canvasCategory.id)
        }

        var movedItemIDs: Set<String> = []
        var excludedItemIDs: Set<String> = []

        for canvasCategory in canvasCategories {
            for item in canvasCategory.items {
                if map.excludedItemIDs.contains(item.id) {
                    excludedItemIDs.insert(item.id)
                    continue
                }

                if let assignedCategoryID = map.itemAssignments[item.id],
                   itemsByCategoryID[assignedCategoryID] != nil {
                    itemsByCategoryID[assignedCategoryID, default: []].append(item)
                    movedItemIDs.insert(item.id)
                    continue
                }

                if let categoryID = groupIDToCategoryID[canvasCategory.id] {
                    itemsByCategoryID[categoryID, default: []].append(item)
                    continue
                }

                // Neither the map's group fold nor an item-level exception
                // claims this item's group — it stays in the passthrough
                // category (registered above) named for its original Canvas
                // group.
                unmappedGroupItems[canvasCategory.id, default: []].append(item)
            }
        }

        // A folded category keeps Canvas's own drop rules from the groups it
        // absorbed. `never_drop` ids are a union: Canvas pinning an item in
        // any group means the professor said that item always counts, and a
        // fold cannot unsay it. `drop_highest` is forwarded only when exactly
        // one group was folded: two groups with different drop-highest rules
        // merged into one syllabus category is a question the syllabus
        // answers with its own drop rule, not one to settle by picking a
        // group at random. Every course goes through this fold now (a course
        // with no syllabus is mirrored one-to-one), so forgetting these
        // fields here silently changed grades that used them — docs/grades.md
        // Decision 6 says the rules are honoured regardless of source.
        let mappedCategories: [GradeCategory] = map.categories.map { category in
            let folded = category.canvasGroupIDs.compactMap { canvasByID[$0] }
            let neverDrop = folded.reduce(into: Set<String>()) { $0.formUnion($1.neverDropIDs) }
            let dropHighest = folded.count == 1 ? folded[0].dropHighest : 0
            return GradeCategory(
                id: category.id,
                name: category.name,
                weight: category.weightPercent,
                dropLowest: category.dropLowest,
                dropHighest: dropHighest,
                neverDropIDs: neverDrop,
                items: itemsByCategoryID[category.id] ?? []
            )
        }

        // An unmapped group keeps Canvas's own drop rules (they're a fact
        // about that group, unrelated to whether the map has an opinion
        // about it) but is forced to weight 0 — the map's silence about a
        // group is not the same as Canvas's own weight for it, and treating
        // it as still counting would let un-reviewed Canvas structure sneak
        // back into a grade the student thought they'd corrected.
        let unmappedCategories: [GradeCategory] = unmappedGroupOrder.compactMap { groupID -> GradeCategory? in
            guard let original = canvasByID[groupID] else { return nil }
            return GradeCategory(
                id: original.id,
                name: original.name,
                weight: 0,
                dropLowest: original.dropLowest,
                dropHighest: original.dropHighest,
                neverDropIDs: original.neverDropIDs,
                items: unmappedGroupItems[groupID] ?? []
            )
        }

        let groupNamesByCategoryID: [String: [String]] = Dictionary(
            uniqueKeysWithValues: map.categories.map { category in
                (category.id, category.canvasGroupIDs.compactMap { canvasByID[$0]?.name })
            }
        )

        return Output(
            categories: mappedCategories + unmappedCategories,
            unmappedGroupIDs: unmappedGroupOrder,
            movedItemIDs: movedItemIDs,
            excludedItemIDs: excludedItemIDs,
            groupNamesByCategoryID: groupNamesByCategoryID
        )
    }
}
