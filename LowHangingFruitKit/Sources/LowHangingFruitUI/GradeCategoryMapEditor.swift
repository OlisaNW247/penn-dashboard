import SwiftUI
import LowHangingFruitKit

/// The "Categories" section body inside `GradeReportView` -- renders and
/// edits `store.effectiveCategoryMap(courseID:)`, the layer that says "these
/// Canvas assignment groups are really one syllabus category," "this item
/// doesn't belong to any category," and "ignore this placeholder" (see
/// `GradeCategoryMap`'s doc comment for the PHYS 0151 case this exists to
/// fix: attendance's 100 points sitting inside "Problem Sets," "HomeWorks"
/// really being "Problem Sets" + "Worksheets," "Midterm 3" having no Canvas
/// group at all, and "Imported Assignments" being junk nobody asked for).
///
/// This view owns its own item-editor sheet and its own rename/add/reset
/// alerts -- it's meant to be dropped into `ReportSection { GradeCategoryMapEditor(...) }`
/// as a self-contained block, not wired up piece by piece by its caller.
/// `GradeCourseCardView`'s expanded breakdown deliberately does NOT use this
/// view: the card stays read-mostly and keeps rendering `GradeCategoryRow`
/// straight off `breakdown.categories`, because a card glanced at from a
/// list is not where a student should be restructuring a class's grading
/// categories.
struct GradeCategoryMapEditor: View {
    @ObservedObject var store: GradeWatcherStore
    let courseID: String

    @State private var editingItem: GradeItem?
    @State private var renamingCategoryID: String?
    @State private var renameText: String = ""
    @State private var isAddingCategory = false
    @State private var newCategoryName: String = ""
    @State private var newCategoryWeightText: String = ""
    @State private var showResetConfirmation = false

    private var map: GradeCategoryMap { store.effectiveCategoryMap(courseID: courseID) }
    private var breakdown: GradeBreakdown? { store.breakdown(courseID: courseID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(map.categories) { category in
                categoryBlock(category)
            }

            if !unmappedGroups.isEmpty {
                needsAHomeBlock
            }

            if !excludedItems.isEmpty {
                notCountedBlock
            }

            footer
        }
        .sheet(item: $editingItem) { item in
            GradeItemEditorSheet(
                store: store,
                courseID: courseID,
                item: item,
                currentOverride: store.itemOverrides(courseID: courseID)[item.id]
            )
        }
        .alert("rename category", isPresented: renamingBinding) {
            TextField("name", text: $renameText)
            Button("save") { commitRename() }
            Button("cancel", role: .cancel) { renamingCategoryID = nil }
        }
        .alert("add a category", isPresented: $isAddingCategory) {
            TextField("name", text: $newCategoryName)
            TextField("weight %", text: $newCategoryWeightText)
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
            Button("add") { commitAddCategory() }
            Button("cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "reset all category edits for this class?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("reset categories", role: .destructive) {
                store.resetCategoryMapEdits(courseID: courseID)
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("this puts every canvas group and item back where canvas put it, and removes any category you added or renamed. scores and syllabus attachment are unaffected.")
        }
    }

    // MARK: - One map category

    @ViewBuilder
    private func categoryBlock(_ category: GradeCategoryMap.Category) -> some View {
        let items = itemsForCategory(category)
        VStack(alignment: .leading, spacing: 8) {
            // `GradeRegrouper` always emits one `GradeCategory` per map
            // category (even one with zero Canvas groups, like a syllabus's
            // "Midterm 3" that hasn't happened yet), so `result` is expected
            // to exist whenever a snapshot exists at all; the bare fallback
            // below only matters for a course with no snapshot yet, same as
            // every other section on this screen guarding on `breakdown`.
            if let result = breakdown?.categories.first(where: { $0.id == category.id }) {
                GradeCategoryRow(
                    store: store,
                    courseID: courseID,
                    category: result,
                    hasGradescopeEarlyScore: hasGradescopeEarlyScore(items)
                )
            } else {
                HStack {
                    Text(category.name)
                        .font(.lhfSans(13, weight: .medium))
                        .foregroundStyle(Color.v2Ink)
                    Spacer()
                    Text("\(formatPoints(category.weightPercent))%")
                        .font(.lhfSans(13, weight: .semibold))
                        .foregroundStyle(Color.v2Ink)
                }
            }

            if !category.canvasGroupIDs.isEmpty {
                groupChipsRow(category)
            }

            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.item.id) { entry in
                        itemRow(entry.item, category: category, isMoved: entry.isMoved)
                    }
                }
                .padding(.top, 2)
            }
        }
        .contextMenu {
            Button("rename") {
                renameText = category.name
                renamingCategoryID = category.id
            }
            Button("delete category", role: .destructive) {
                store.removeCategory(courseID: courseID, categoryID: category.id)
            }
        }
    }

    /// This category's Canvas group folds, each its own chip -- tapping one
    /// opens a "move to …" menu rather than a disclosure, since the whole
    /// point of the chip is to let a wrongly-folded group be moved, not just
    /// be looked at (docs/grades.md — "HomeWorks" wrongly swallowing
    /// "Problem Sets" is exactly the case this exists to let a student undo).
    private func groupChipsRow(_ category: GradeCategoryMap.Category) -> some View {
        HStack(spacing: 6) {
            ForEach(category.canvasGroupIDs, id: \.self) { groupID in
                Menu {
                    ForEach(otherCategories(than: category.id)) { target in
                        Button(target.name) {
                            store.assignGroup(courseID: courseID, groupID: groupID, toCategory: target.id)
                        }
                    }
                    Button("unmapped") {
                        store.assignGroup(courseID: courseID, groupID: groupID, toCategory: nil)
                    }
                } label: {
                    Chip(text: groupName(for: groupID), color: .v2CourseCode)
                }
                .accessibilityLabel("move \(groupName(for: groupID)) to a different category")
            }
        }
    }

    // MARK: - One item row

    /// One item: name, "score / possible," whatever badges apply, and a
    /// trailing "…" menu to move it to a different category or take it out
    /// of the math entirely. Tapping the name/score opens
    /// `GradeItemEditorSheet` to correct the number itself -- same sheet,
    /// same override, as the old flat category list used.
    private func itemRow(_ item: GradeItem, category: GradeCategoryMap.Category, isMoved: Bool) -> some View {
        let override = store.itemOverrides(courseID: courseID)[item.id]
        return HStack(alignment: .top, spacing: 8) {
            Button {
                editingItem = item
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.lhfSans(11.5))
                            .foregroundStyle(Color.v2Ink)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 4) {
                            if isMoved {
                                itemBadge("moved here")
                            }
                            if item.isExcused {
                                itemBadge("excused")
                            }
                            if override?.score != nil || override?.pointsPossible != nil {
                                itemBadge("you edited")
                            }
                            if item.scoreSource == .gradescopeEarly {
                                GradeSourceBadge(source: .gradescopeEarly)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    Text(itemScoreText(item, override: override))
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2RingSub)
                }
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(otherCategories(than: category.id)) { target in
                    Button("move to \(target.name.lowercased())") {
                        store.assignItem(courseID: courseID, itemID: item.id, toCategory: target.id)
                    }
                }
                // Excluding here is the MAP's own classification
                // (`GradeCategoryMap.excludedItemIDs`, via `setItemExcluded`)
                // -- distinct from the score-level "doesn't count" toggle in
                // `GradeItemEditorSheet`, which is a `GradeItemOverride` the
                // student can also reach by tapping the row. An excluded
                // item drops out of `itemsForCategory` immediately and
                // reappears in the "not counted" block below with a reason,
                // so there's no complementary "counts" action to offer here
                // -- that lives on the "not counted" row itself.
                Button("doesn\u{2019}t count") {
                    store.setItemExcluded(courseID: courseID, itemID: item.id, true)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Color.v2CourseCode)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("options for \(item.name)")
        }
        .accessibilityElement(children: .combine)
    }

    private func itemScoreText(_ item: GradeItem, override: GradeItemOverride?) -> String {
        let score = override?.score ?? item.score
        let possible = override?.pointsPossible ?? item.pointsPossible
        guard let score else { return "\u{2014}" }
        return "\(formatPoints(score)) / \(formatPoints(possible))"
    }

    /// Matches the dashboard's "nothing to submit" caveat register, same as
    /// `GradeExplanationView`'s category badges and the old flat item list's.
    private func itemBadge(_ text: String) -> some View {
        Text(text)
            .font(.lhfSans(9, weight: .semibold))
            .foregroundStyle(Color.v2CourseCode)
    }

    // MARK: - Needs a home (unmapped Canvas groups)

    private var unmappedGroups: [GradeCategory] {
        store.unmappedGroups(courseID: courseID)
    }

    private var needsAHomeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("needs a home".uppercased())
                .font(.lhfSans(9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.v2SpineAmber)
            Text("these canvas groups aren\u{2019}t in your syllabus\u{2019}s categories, so they count 0% until you place them.")
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2DateText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(unmappedGroups) { group in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.lhfSans(12, weight: .medium))
                                .foregroundStyle(Color.v2Ink)
                            Text("\(group.items.count) \(group.items.count == 1 ? "item" : "items")")
                                .font(.lhfSans(10.5))
                                .foregroundStyle(Color.v2RingSub)
                        }
                        Spacer()
                        Menu {
                            ForEach(map.categories) { category in
                                Button(category.name) {
                                    store.assignGroup(courseID: courseID, groupID: group.id, toCategory: category.id)
                                }
                            }
                        } label: {
                            Label("put in \u{2026}", systemImage: "tray.and.arrow.down")
                                .font(.lhfSans(10.5, weight: .medium))
                                .foregroundStyle(Color.v2SpineBlue)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Not counted (excluded items)

    private var excludedItems: [(item: GradeItem, reason: String)] {
        store.excludedItems(courseID: courseID)
    }

    private var notCountedBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("not counted".uppercased())
                .font(.lhfSans(9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.v2CourseCode)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(excludedItems, id: \.item.id) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.item.name)
                                .font(.lhfSans(11.5))
                                .foregroundStyle(Color.v2Ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(entry.reason)
                                .font(.lhfSans(10, weight: .semibold))
                                .foregroundStyle(Color.v2CourseCode)
                        }
                        Spacer()
                        Button("count it") {
                            store.setItemExcluded(courseID: courseID, itemID: entry.item.id, false)
                        }
                        .font(.lhfSans(11, weight: .semibold))
                        .foregroundStyle(Color.v2SpineBlue)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Footer (add / reset)

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                newCategoryName = ""
                newCategoryWeightText = ""
                isAddingCategory = true
            } label: {
                Label("add a category", systemImage: "plus.circle")
                    .font(.lhfSans(11, weight: .medium))
                    .foregroundStyle(Color.v2SpineBlue)
            }
            .buttonStyle(.plain)

            // Only shown once there's actually something to reset -- an
            // untouched map (`store.hasCategoryMapEdits`) has nothing for
            // this button to undo, and offering it anyway would read as a
            // standing threat over a course the student hasn't corrected.
            if store.hasCategoryMapEdits(courseID: courseID) {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("reset categories", systemImage: "arrow.uturn.backward")
                        .font(.lhfSans(11, weight: .medium))
                        .foregroundStyle(Color.v2SpineRed)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Helpers

    private func otherCategories(than categoryID: String) -> [GradeCategoryMap.Category] {
        map.categories.filter { $0.id != categoryID }
    }

    private func groupName(for groupID: String) -> String {
        store.gradeCategories(courseID: courseID).first(where: { $0.id == groupID })?.name ?? groupID
    }

    /// Reassembles one map category's item list from the pieces the store
    /// exposes: `GradeCategoryMap` records folds (`canvasGroupIDs`) and
    /// exceptions (`itemAssignments`), but `store.items(courseID:categoryID:)`
    /// is keyed by CANVAS group id, not map category id, so there is no
    /// single store call that already returns "every item in this map
    /// category." This mirrors `GradeRegrouper.apply`'s own precedence rule
    /// exactly (itemAssignments wins over the group fold, exclusions drop
    /// the item entirely) so the editor's item list can never disagree with
    /// what the engine actually computed from the same map.
    private func itemsForCategory(_ category: GradeCategoryMap.Category) -> [(item: GradeItem, isMoved: Bool)] {
        var seen = Set<String>()
        var result: [(item: GradeItem, isMoved: Bool)] = []

        for groupID in category.canvasGroupIDs {
            for item in store.items(courseID: courseID, categoryID: groupID) {
                guard !map.excludedItemIDs.contains(item.id) else { continue }
                if let assigned = map.itemAssignments[item.id], assigned != category.id { continue }
                guard seen.insert(item.id).inserted else { continue }
                result.append((item, map.itemAssignments[item.id] == category.id))
            }
        }

        // Items moved in from a group that ISN'T part of this category's own
        // fold (the attendance-item case: pulled out of "Problem Sets" into
        // "Attendance/Participation").
        let movedFromElsewhere = map.itemAssignments.filter { $0.value == category.id && !seen.contains($0.key) }
        if !movedFromElsewhere.isEmpty {
            let allItems = store.gradeCategories(courseID: courseID).flatMap(\.items)
            for itemID in movedFromElsewhere.keys {
                guard !map.excludedItemIDs.contains(itemID),
                      let item = allItems.first(where: { $0.id == itemID })
                else { continue }
                seen.insert(itemID)
                result.append((item, true))
            }
        }

        return result
    }

    /// Same rule `GradeReportView`'s old flat list and `GradeCourseCardView`'s
    /// card use: a category counts as carrying a Gradescope-early score when
    /// any scored, kept item in it came from that overlay.
    private func hasGradescopeEarlyScore(_ items: [(item: GradeItem, isMoved: Bool)]) -> Bool {
        items.contains { entry in
            !entry.item.isExcused && !entry.item.omitFromFinalGrade
                && entry.item.score != nil
                && entry.item.scoreSource == .gradescopeEarly
        }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(
            get: { renamingCategoryID != nil },
            set: { isPresented in if !isPresented { renamingCategoryID = nil } }
        )
    }

    private func commitRename() {
        defer { renamingCategoryID = nil }
        guard let categoryID = renamingCategoryID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.renameCategory(courseID: courseID, categoryID: categoryID, name: trimmed)
    }

    private func commitAddCategory() {
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let weightText = newCategoryWeightText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let weight = Double(weightText), weight >= 0 else { return }
        _ = store.addCategory(courseID: courseID, name: name, weightPercent: weight)
        newCategoryName = ""
        newCategoryWeightText = ""
    }
}
