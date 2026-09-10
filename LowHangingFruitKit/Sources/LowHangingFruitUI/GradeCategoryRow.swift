import SwiftUI
import LowHangingFruitKit

/// One category row inside an expanded `GradeCourseCardView`: name, effective
/// weight (or "\u{2014}" in points mode), earned/possible on scored work, the
/// weight's source badge, and the always-available manual-weight edit
/// affordance (docs/grades.md §6 — manual editing is the only fallback when
/// Canvas has no weights, so it's never gated behind a mode check).
struct GradeCategoryRow: View {
    @ObservedObject var store: GradeWatcherStore
    let courseID: String
    let category: GradeBreakdown.CategoryResult
    /// True when any scored, kept (post-drop) item in this category came from
    /// the Gradescope early overlay — drives the "Gradescope early" source
    /// badge next to the category's numbers (docs/grades.md §6 "Per-number
    /// source badges"). Computed by the caller from the underlying
    /// `GradeCategory.items`, which `GradeBreakdown.CategoryResult` doesn't
    /// carry per-item provenance for.
    let hasGradescopeEarlyScore: Bool

    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isFieldFocused: Bool

    @State private var isEditingExpectedCount = false
    @State private var expectedCountText = ""
    @FocusState private var isExpectedCountFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.name)
                        .font(.lhfSans(13, weight: .medium))
                        .foregroundStyle(Color.v2Ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(gradedText)
                        .font(.lhfSans(10.5))
                        .foregroundStyle(Color.v2RingSub)
                        .fixedSize(horizontal: false, vertical: true)
                    // Present once a `GradeCategoryMap` folded more than one
                    // Canvas assignment group into this category (docs/
                    // grades.md — "HomeWorks" ← "Problem Sets" +
                    // "Worksheets"). The card stays read-mostly for the fold
                    // itself (see `GradeCategoryMapEditor` for the editing
                    // affordances); this is just enough context that the
                    // card's own numbers don't read as unexplained.
                    if let groupsText {
                        Text(groupsText)
                            .font(.lhfSans(9.5))
                            .foregroundStyle(Color.v2RingSub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if hasGradescopeEarlyScore {
                        GradeSourceBadge(source: .gradescopeEarly)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(weightText)
                        .font(.lhfSans(13, weight: .semibold))
                        .foregroundStyle(Color.v2Ink)
                    if let source = category.weightSource {
                        GradeSourceBadge(source: source)
                    }
                }
            }

            editingControls
            expectedCountControls
        }
        .accessibilityElement(children: .combine)
    }

    private var weightText: String {
        category.effectiveWeight.map { "\(formatPoints($0))%" } ?? "\u{2014}"
    }

    /// "from canvas groups: problem sets, worksheets" -- nil when there's no
    /// map, or the map category maps one-to-one onto a single Canvas group.
    /// Built the same way `GradeExplanation.CategoryLine.groupsText` is, kept
    /// as a separate copy since the Kit doesn't hand the UI a pre-worded
    /// string for `GradeBreakdown.CategoryResult` (only `GradeExplanation`
    /// gets one, and this row is shown with or without the explanation panel
    /// open).
    private var groupsText: String? {
        category.canvasGroupNames.isEmpty
            ? nil
            : "from canvas groups: " + category.canvasGroupNames.map { $0.lowercased() }.joined(separator: ", ")
    }

    /// "2 of 3 posted graded" — mirrors `GradeExplanation.CategoryLine`'s
    /// wording (the report's explanation panel says the same thing about the
    /// same category) rather than the old "X/Y pts scored · A/B items" phrasing,
    /// so a student reading the card and the report isn't asked to reconcile
    /// two different vocabularies for one number.
    private var gradedText: String {
        "\(category.scoredCount) of \(category.totalCount) posted graded"
    }

    @ViewBuilder
    private var editingControls: some View {
        if isEditing {
            HStack(spacing: 8) {
                TextField("weight %", text: $editText)
#if os(iOS)
                    .keyboardType(.decimalPad)
#endif
                    .font(.lhfSans(12))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 90)
                    .focused($isFieldFocused)
                    .accessibilityLabel("manual weight percent for \(category.name)")

                Button(action: save) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.v2SpineGreen)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("save weight")

                Button {
                    isEditing = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.v2RingSub)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("cancel editing weight")
            }
        } else {
            HStack(spacing: 14) {
                Button {
                    editText = category.effectiveWeight.map(formatPoints) ?? ""
                    isEditing = true
                    isFieldFocused = true
                } label: {
                    Label("edit weight", systemImage: "pencil")
                        .font(.lhfSans(10.5, weight: .medium))
                        .foregroundStyle(Color.v2SpineBlue)
                }
                .buttonStyle(.plain)

                if category.weightSource == .manual {
                    Button {
                        store.setManualWeight(courseID: courseID, categoryID: category.id, weight: nil)
                    } label: {
                        Label("reset to canvas", systemImage: "arrow.uturn.backward")
                            .font(.lhfSans(10.5, weight: .medium))
                            .foregroundStyle(Color.v2RingSub)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func save() {
        defer { isEditing = false }
        guard let value = Double(editText), value >= 0 else { return }
        store.setManualWeight(courseID: courseID, categoryID: category.id, weight: value)
    }

    // MARK: - Expected item count this semester (docs/grades.md — the
    // syllabus-informed "N% of the semester decided" fix). `totalCount` only
    // ever counts what Canvas has already posted, so a syllabus (or a hand-
    // typed guess) is the only source for "how many will there eventually
    // be" -- the number `GradeBreakdown.CategoryResult.semesterDecidedFraction`
    // is extrapolated against.

    @ViewBuilder
    private var expectedCountControls: some View {
        HStack(spacing: 8) {
            Text("expected this semester")
                .font(.lhfSans(10.5))
                .foregroundStyle(Color.v2RingSub)

            if isEditingExpectedCount {
                // `.numberPad` has no return key (same reason the weight
                // editor above it uses an explicit save button rather than
                // `.onSubmit`), so committing needs its own tap target.
                TextField("count", text: $expectedCountText)
#if os(iOS)
                    .keyboardType(.numberPad)
#endif
                    .font(.lhfSans(12))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 50)
                    .focused($isExpectedCountFieldFocused)
                    .accessibilityLabel("expected item count this semester for \(category.name)")

                Button(action: saveExpectedCount) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.v2SpineGreen)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("save expected count")

                Button {
                    isEditingExpectedCount = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.v2RingSub)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("cancel editing expected count")
            } else {
                Button {
                    expectedCountText = store.effectiveExpectedCounts(courseID: courseID)[category.id].map(String.init) ?? ""
                    isEditingExpectedCount = true
                    isExpectedCountFieldFocused = true
                } label: {
                    Label(expectedCountValueText, systemImage: "pencil")
                        .font(.lhfSans(11, weight: .medium))
                        .foregroundStyle(Color.v2SpineBlue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("edit expected item count this semester for \(category.name)")

                if let badge = expectedCountSourceBadge {
                    Text(badge)
                        .font(.lhfSans(9, weight: .semibold))
                        .foregroundStyle(Color.v2CourseCode)
                }

                // Only a manually-entered count can be "reset" -- a syllabus-
                // sourced count already came from the source of truth, so
                // there's nothing above it to fall back to; detaching the
                // syllabus itself (not this row) is how that goes away.
                if isManualExpectedCount {
                    Button {
                        store.setExpectedCount(courseID: courseID, categoryID: category.id, count: nil)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.v2RingSub)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("reset expected item count for \(category.name)")
                }
            }
        }
    }

    private var isManualExpectedCount: Bool {
        store.manualExpectedCounts(courseID: courseID)[category.id] != nil
    }

    /// "syllabus" only applies when nothing manual has overridden it -- a
    /// manual edit always wins display-wise, same as `effectiveExpectedCounts`
    /// itself prefers the manual value.
    private var expectedCountSourceBadge: String? {
        if isManualExpectedCount { return "you edited" }
        if store.syllabusExpectedCounts(courseID: courseID)[category.id] != nil { return "syllabus" }
        return nil
    }

    private var expectedCountValueText: String {
        store.effectiveExpectedCounts(courseID: courseID)[category.id].map(String.init) ?? "\u{2014}"
    }

    private func saveExpectedCount() {
        defer { isEditingExpectedCount = false }
        guard let value = Int(expectedCountText), value >= 0 else { return }
        store.setExpectedCount(courseID: courseID, categoryID: category.id, count: value)
    }
}
