import SwiftUI
import LowHangingFruitKit

/// The full grade report for one watched class (docs/grades.md §13, then
/// rebuilt minimal — numbers and tables, three one-tap drill-down levels,
/// no sentences).
///
/// Layout, top to bottom: a headline (number, decided bar, one status line),
/// an optional one-row "suggested mapping" / "syllabus weights found" nudge,
/// a categories table whose rows expand to their items (which open
/// `GradeItemEditorSheet`), a collapsed "targets" disclosure, and a collapsed
/// "how" disclosure. Everything the old report said in prose now lives
/// behind a tap:
///
/// - `landingSection` (floor/pace/ceiling tiles + their caption) is gone
///   outright — the same three numbers are recoverable from `targetsSection`
///   (`rangeText` gives floor/ceiling; `requiredAverage` per band already
///   answers "what would I need," which is the question the tiles existed
///   to set up).
/// - `targetSection`'s segmented picker + `requirementLine` sentence →
///   `targetsSection` lists every real target band at once, each reduced to
///   `targetText`'s one word/short phrase, no picker needed.
/// - `remainingSection` (`statLine`s for upcoming/pending/open-share, plus
///   `store.countGaps` sentences) → the categories table's own "decided"
///   column (`scoredCount/expectedCount`) already says what's left per
///   category; the syllabus-gap sentences are dropped rather than
///   relocated (informational only, not on the kept-capability list).
/// - `caveats` (differs-from-canvas sentence + last-refreshed) →
///   `howSection`'s differs-from-canvas line and last-refreshed line.
/// - `syllabusSection` (`suggestedSchemeBody`/`attachedSyllabusBody`, both
///   full paragraphs) → the one-row suggestion nudge above, plus a one-line
///   "syllabus: attached · N categories" / "syllabus: none" fact in
///   `howSection`; reviewing or attaching a syllabus is the toolbar menu's
///   "syllabus" item, which opens the same `SyllabusSetupView` as before.
/// - the flat, read-only category list → the categories table below, backed
///   by the same `GradeCategoryMapEditor` (now a toolbar sheet, "edit
///   categories") for restructuring.
/// - the card-menu duplicate (counts-toward-grade toggle, mode picker) and
///   the Watch button → both now live only in `reportMenu`.
/// - the card's `suggestedMatchesDisclosure`/`unmatchedDisclosure`
///   (Gradescope fuzzy-match review, docs/grades.md §5 item 4) → one
///   suggestion-nudge row per candidate match, same use/skip pattern as the
///   mapping/scheme rows (`suggestionsSection`), plus a one-line unmatched
///   count in `howSection`.
///
/// `ReportSection`/`LandingTile` are deleted along with the sections that
/// used them — nothing else in the UI module references them (a stale
/// doc-comment mention in `GradeCategoryMapEditor.swift` aside, which is out
/// of this change's scope to touch).
struct GradeReportView: View {
    @ObservedObject var store: GradeWatcherStore
    let courseID: String
    let courseName: String
    /// "lecture" / "lab" / "recitation" when this course code has several
    /// Canvas sites (`AppState.gradeSiteLabel`), else nil. Defaults to nil so
    /// `ContentView`'s existing call site -- which doesn't know about site
    /// labels and is out of this change's scope -- keeps compiling unchanged;
    /// `GradeCourseCardView`'s call site passes its own `siteLabel` through.
    let siteLabel: String?

    /// Read only for `state.courseKnowledge.syllabusText(forCourseID:)`, so
    /// `SyllabusSetupView` can offer the syllabus text this phone already
    /// synced as a candidate before it ever hits Canvas live. Both of this
    /// view's call sites (`ContentView`'s `.report` case and
    /// `GradeCourseCardView`'s `NavigationLink`) already sit under an
    /// ancestor `.environmentObject(state)`, so this resolves without
    /// widening either init.
    @EnvironmentObject private var state: AppState

    @State private var showSyllabusSetup = false
    @State private var showCategoryEditor = false
    @State private var showResetConfirmation = false
    @State private var expandedCategoryID: String?
    @State private var editingItem: GradeItem?
    /// "syllabus weights found" is a suggestion, not a stored decision --
    /// skipping it just hides the row for the rest of this view's lifetime,
    /// unlike the shared-mapping row's "skip", which calls
    /// `declineSharedMapping` and persists.
    @State private var hideSuggestedScheme = false
    /// Gradescope fuzzy-match suggestions skipped for this view instance --
    /// keyed by `SuggestedMatch.itemID` (the Canvas item id), same
    /// view-local-only "skip" as `hideSuggestedScheme` since there's no
    /// store-level decline for a fuzzy match.
    @State private var skippedGradescopeMatchIDs: Set<String> = []

    init(store: GradeWatcherStore, courseID: String, courseName: String, siteLabel: String? = nil) {
        self.store = store
        self.courseID = courseID
        self.courseName = courseName
        self.siteLabel = siteLabel
    }

    private var breakdown: GradeBreakdown? { store.breakdown(courseID: courseID) }
    private var projection: GradeProjection? { store.projection(courseID: courseID) }
    private var cutoffs: GradeCutoffs { store.cutoffs(courseID: courseID) }

    private var titleText: String {
        guard let siteLabel, !siteLabel.isEmpty else { return courseName }
        return "\(courseName) \u{00b7} \(siteLabel)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let breakdown, let projection {
                    headlineSection(breakdown)
                    suggestionsSection
                    categoriesSection(breakdown)
                    targetsSection(projection)
                    howSection(breakdown)
                } else {
                    emptyState
                }
            }
            .padding(16)
        }
        .background(Color.v2Bg)
        .navigationTitle(titleText)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar { reportMenu }
        .confirmationDialog(
            "reset all edits for this class?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("reset all edits", role: .destructive) { resetAllEdits() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("this clears every score you corrected, expected item count, grading mode choice, and manual weight for this class. canvas\u{2019}s own numbers are unaffected.")
        }
        .sheet(isPresented: $showSyllabusSetup) {
            SyllabusSetupView(
                store: store,
                courseID: courseID,
                courseName: courseName,
                syncedSyllabusText: state.courseKnowledge.syllabusText(forCourseID: courseID)
            )
        }
        .sheet(isPresented: $showCategoryEditor) {
            NavigationStack {
                ScrollView {
                    GradeCategoryMapEditor(store: store, courseID: courseID)
                        .padding(16)
                }
                .background(Color.v2Bg)
                .navigationTitle("categories")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
            }
        }
        .sheet(item: $editingItem) { item in
            GradeItemEditorSheet(
                store: store,
                courseID: courseID,
                item: item,
                currentOverride: store.itemOverrides(courseID: courseID)[item.id]
            )
        }
    }

    // MARK: - Toolbar

    /// Every action the old card menu and report menu offered separately,
    /// now in one place: watch, count/exclude, grading mode, edit
    /// categories, syllabus, reset edits.
    @ToolbarContentBuilder
    private var reportMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    store.setWatching(!store.isWatching(courseID), courseID: courseID)
                } label: {
                    Text(store.isWatching(courseID) ? "unwatch" : "watch")
                }

                Button {
                    store.setCourseExcluded(courseID: courseID, !store.isCourseExcluded(courseID: courseID))
                } label: {
                    Text(store.isCourseExcluded(courseID: courseID) ? "count it" : "don\u{2019}t count")
                }

                Picker("mode", selection: Binding(
                    get: { store.modeOverride(courseID: courseID) },
                    set: { store.setModeOverride(courseID: courseID, mode: $0) }
                )) {
                    Text("as canvas says").tag(GradingMode?.none)
                    Text("weighted").tag(GradingMode?.some(.weighted))
                    Text("points").tag(GradingMode?.some(.points))
                }

                Button {
                    showCategoryEditor = true
                } label: {
                    Text("edit categories")
                }

                Button {
                    showSyllabusSetup = true
                } label: {
                    Text("syllabus")
                }

                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Text("reset edits")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("grade options for \(courseName)")
        }
    }

    /// Clears every student-authored edit for this course, using only the
    /// existing per-item/per-category setters (`nil` clears each one) --
    /// there's no bulk-clear entry point on the store, so this iterates the
    /// override/expected-count/weight dictionaries it already exposes rather
    /// than needing a new one. Syllabus attachment and Gradescope match
    /// confirmations are untouched: those aren't corrections to a Canvas
    /// number, they're the student's own source documents, and "reset my
    /// edits" shouldn't be read as "forget my syllabus."
    private func resetAllEdits() {
        for itemID in store.itemOverrides(courseID: courseID).keys {
            store.setItemOverride(courseID: courseID, itemID: itemID, override: nil)
        }
        for categoryID in store.manualExpectedCounts(courseID: courseID).keys {
            store.setExpectedCount(courseID: courseID, categoryID: categoryID, count: nil)
        }
        store.setModeOverride(courseID: courseID, mode: nil)
        for categoryID in store.manualWeights(courseID: courseID).keys {
            store.setManualWeight(courseID: courseID, categoryID: categoryID, weight: nil)
        }
    }

    // MARK: - Headline

    private func headlineSection(_ breakdown: GradeBreakdown) -> some View {
        let headline = GradeCourseCardView.headlineText(for: breakdown)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(headline.primary)
                    .font(.lhfSerif(44))
                    .foregroundStyle(Color.v2Ink)
                if let secondary = headline.secondary {
                    Text(secondary)
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2DateText)
                }
            }
            decidedBar(breakdown)
            Text(GradeCourseCardView.statusText(for: breakdown))
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2DateText)
        }
    }

    /// Same 3pt, unlabeled bar as the card (`GradeCourseCardView.decidedBar`)
    /// -- kept as its own copy rather than shared because the card's version
    /// is `private` to its own file, and this one-screen's-worth of geometry
    /// isn't worth a new shared view over.
    private func decidedBar(_ breakdown: GradeBreakdown) -> some View {
        let fraction = min(max(GradeCourseCardView.decidedFraction(for: breakdown), 0), 1)
        let isSemesterKnown = breakdown.semesterDecidedFraction != nil
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.v2RingTrack)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.v2SpineBlue)
                    .opacity(isSemesterKnown ? 1 : 0.5)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }

    // MARK: - Suggestions (server-pooled mapping, syllabus-derived scheme,
    // Gradescope fuzzy matches)

    @ViewBuilder
    private var suggestionsSection: some View {
        if store.sharedMappingSuggestion(courseID: courseID) != nil {
            suggestionRow(
                title: "suggested mapping",
                onUse: { store.acceptSharedMapping(courseID: courseID) },
                onSkip: { store.declineSharedMapping(courseID: courseID) }
            )
        }
        if !hideSuggestedScheme,
           store.syllabus(courseID: courseID) == nil,
           store.suggestedScheme(courseID: courseID) != nil {
            suggestionRow(
                title: "syllabus weights found",
                onUse: { store.applySuggestedScheme(courseID: courseID) },
                onSkip: { hideSuggestedScheme = true }
            )
        }
        // Lower-confidence Gradescope name matches (docs/grades.md §5 item 4)
        // -- re-homed here from the old card's `suggestedMatchesDisclosure`
        // as one row per candidate, same use/skip pattern as the two rows
        // above. "skip" is view-local (`skippedGradescopeMatchIDs`), same as
        // the syllabus-scheme row: there's no store-level "decline" for a
        // fuzzy match, only confirm-or-ignore.
        ForEach(unskippedSuggestedGradescopeMatches, id: \.itemID) { match in
            suggestionRow(
                title: Self.gradescopeMatchText(gradescopeName: match.gradescopeTitle, canvasName: match.itemName),
                onUse: { store.confirmSuggestedMatch(courseID: courseID, match: match) },
                onSkip: { skippedGradescopeMatchIDs.insert(match.itemID) }
            )
        }
    }

    private var unskippedSuggestedGradescopeMatches: [GradescopeOverlay.SuggestedMatch] {
        store.suggestedGradescopeMatches(courseID: courseID)
            .filter { !skippedGradescopeMatchIDs.contains($0.itemID) }
    }

    private func suggestionRow(title: String, onUse: @escaping () -> Void, onSkip: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2Ink)
                .lineLimit(1)
            Spacer()
            Button("use", action: onUse)
                .controlSize(.small)
            Button("skip", action: onSkip)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// "gradescope: hw 1 → homework 1" — the old card's
    /// `"\u{201c}\(match.gradescopeTitle)\u{201d} \u{2192} \(match.itemName)"`
    /// row, reduced to fit the one-row nudge pattern. Budgeted at ≤40
    /// characters by truncating each name rather than by word count (an
    /// assignment title is a proper noun a student needs to recognize, not a
    /// sentence this codebase gets to choose the wording of, so the usual
    /// six-word budget doesn't apply -- see `GradeMinimalCopyTests`).
    nonisolated static func gradescopeMatchText(gradescopeName: String, canvasName: String) -> String {
        let maxNameLength = 12
        return "gradescope: \(truncatedName(gradescopeName, maxLength: maxNameLength)) \u{2192} \(truncatedName(canvasName, maxLength: maxNameLength))"
    }

    /// "problem set 1…" -- truncates to `maxLength` characters INCLUDING the
    /// ellipsis, so a caller doing its own character-budget arithmetic (like
    /// `gradescopeMatchText`) can rely on the result never exceeding
    /// `maxLength`.
    private static func truncatedName(_ name: String, maxLength: Int) -> String {
        guard name.count > maxLength else { return name }
        return "\(name.prefix(maxLength - 1))\u{2026}"
    }

    // MARK: - Categories table

    private func categoriesSection(_ breakdown: GradeBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("category")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("weight")
                    .frame(width: 44, alignment: .trailing)
                Text("so far")
                    .frame(width: 50, alignment: .trailing)
                Text("decided")
                    .frame(width: 56, alignment: .trailing)
            }
            .font(.lhfSans(9, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(Color.v2CourseCode)
            .textCase(.uppercase)

            Divider()

            ForEach(breakdown.categories) { category in
                VStack(alignment: .leading, spacing: 0) {
                    categoryRow(category, term: breakdown.term)
                    if expandedCategoryID == category.id {
                        itemsList(category)
                    }
                }
            }
        }
    }

    private func categoryRow(_ category: GradeBreakdown.CategoryResult, term: GradeCountPredictor.Term?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedCategoryID = expandedCategoryID == category.id ? nil : category.id
            }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text(category.name)
                        .lineLimit(1)
                    if category.isUnmapped {
                        Circle()
                            .fill(Color.v2SpinePurple)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(category.effectiveWeight.map(formatPercent) ?? "\u{2014}")
                    .frame(width: 44, alignment: .trailing)
                Text(category.percent.map(formatPercent) ?? "\u{2014}")
                    .frame(width: 50, alignment: .trailing)
                Text(decidedColumnText(category, term: term))
                    .frame(width: 56, alignment: .trailing)
            }
            .font(.lhfSans(12))
            .foregroundStyle(Color.v2Ink)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    /// "N/M" against what's posted, or "wk W/T" against the term's length
    /// for an attendance category — a syllabus's 12 labs decide the same way
    /// every week regardless of how many have posted, so counting weeks
    /// elapsed is the honest "decided" reading for attendance rather than
    /// posted-item count.
    private func decidedColumnText(_ category: GradeBreakdown.CategoryResult, term: GradeCountPredictor.Term?) -> String {
        if category.isAttendance, let term {
            let elapsed = max(1, Int(term.elapsedWeeks(at: Date()).rounded(.up)))
            let total = Int(term.weeks.rounded())
            return "wk \(elapsed)/\(total)"
        }
        return "\(category.scoredCount)/\(category.expectedCount ?? category.totalCount)"
    }

    private func itemsList(_ category: GradeBreakdown.CategoryResult) -> some View {
        let allItems = store.items(courseID: courseID, categoryID: category.id)
        let kept = allItems.filter { !category.excludedItemIDs.contains($0.id) }
        let excluded = allItems.filter { category.excludedItemIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(kept) { item in
                itemRow(item, category: category)
            }
            ForEach(excluded) { item in
                itemRow(item, category: category)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func itemRow(_ item: GradeItem, category: GradeBreakdown.CategoryResult) -> some View {
        let isExcluded = category.excludedItemIDs.contains(item.id)
        let isDropped = category.droppedItemIDs.contains(item.id)
        return Button {
            editingItem = item
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isExcluded ? Color.v2CourseCode : dotColor(item))
                    .frame(width: 6, height: 6)
                Text(item.name)
                    .font(.lhfSans(12))
                    .foregroundStyle(isExcluded ? Color.v2CourseCode : Color.v2Ink)
                    .strikethrough(isDropped)
                    .lineLimit(1)
                Spacer()
                Text(isExcluded ? "\u{00d7}" : scoreText(item))
                    .font(.lhfSans(12))
                    .foregroundStyle(isExcluded ? Color.v2CourseCode : Color.v2RingSub)
                    .strikethrough(isDropped)
            }
            .padding(.leading, 12)
        }
        .buttonStyle(.plain)
    }

    /// v2Ink once it's scored; otherwise v2SpineBlue when it's already past
    /// due (or has no due date at all -- nothing to wait on), v2CourseCode
    /// while it's still upcoming.
    private func dotColor(_ item: GradeItem) -> Color {
        if item.score != nil { return .v2Ink }
        if let due = item.dueAt, due > Date() { return .v2CourseCode }
        return .v2SpineBlue
    }

    private func scoreText(_ item: GradeItem) -> String {
        if item.isExcused { return "excused" }
        let earned = item.score.map(formatPoints) ?? "\u{2014}"
        return "\(earned)/\(formatPoints(item.pointsPossible))"
    }

    // MARK: - Targets

    @ViewBuilder
    private func targetsSection(_ projection: GradeProjection) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.rangeText(floor: projection.floorPercent, ceiling: projection.ceilingPercent))
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
                ForEach(cutoffs.targetBands, id: \.letter) { band in
                    HStack {
                        Text(band.letter)
                            .font(.lhfSans(12, weight: .medium))
                            .foregroundStyle(Color.v2Ink)
                        Spacer()
                        Text(Self.targetText(projection.requiredAverage(for: band.minPercent)))
                            .font(.lhfSans(12))
                            .foregroundStyle(Color.v2DateText)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("targets")
                .font(.lhfSans(12, weight: .medium))
        }
    }

    /// "reached" / "need 94% avg" / "out of reach" / "nothing left" — one
    /// word or short phrase per `GradeProjection.Requirement` case, replacing
    /// the old `requirementLine` sentence.
    nonisolated static func targetText(_ requirement: GradeProjection.Requirement) -> String {
        switch requirement {
        case .alreadyReached:
            return "reached"
        case let .need(percent):
            return "need \(formatPercent(percent)) avg"
        case .unreachable:
            return "out of reach"
        case .nothingLeft:
            return "nothing left"
        }
    }

    /// "floor 61% · ceiling 97%" — the two banked/best-case numbers the old
    /// `landingSection` tiles showed, as one line above the target bands.
    nonisolated static func rangeText(floor: Double, ceiling: Double) -> String {
        "floor \(formatPercent(floor)) \u{00b7} ceiling \(formatPercent(ceiling))"
    }

    // MARK: - How this is calculated

    @ViewBuilder
    private func howSection(_ breakdown: GradeBreakdown) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let explanation = store.explanation(courseID: courseID) {
                    GradeExplanationView(explanation: explanation)
                }
                if let siteLabel, !siteLabel.isEmpty {
                    Text("\(siteLabel) site")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2RingSub)
                }
                Text(syllabusLineText)
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
                if store.differsFromCanvas(courseID: courseID, currentPercent: breakdown.currentPercent),
                   let canvasScore = store.canvasComputedScore(courseID: courseID) {
                    Text("differs from canvas \u{00b7} \(formatPercent(canvasScore))")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2RingSub)
                }
                if unmatchedGradescopeCount > 0 {
                    Text("\(unmatchedGradescopeCount) gradescope scores unmatched")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2RingSub)
                }
                Text("last refreshed \(relativeTimeString(store.lastRefreshed))")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
            }
            .padding(.top, 6)
        } label: {
            Text("how")
                .font(.lhfSans(12, weight: .medium))
        }
    }

    /// Gradescope scores that named an assignment but never made it into this
    /// course's math (docs/grades.md §4) -- no candidate, ambiguous, or a
    /// duplicate of an already-filled item. Never counted; the old card's
    /// `unmatchedDisclosure` listed each one, this is just the count.
    private var unmatchedGradescopeCount: Int {
        store.unmatchedGradescopeScores(courseID: courseID).count
    }

    /// "syllabus: attached · 7 categories" / "syllabus: none" — the fact the
    /// old `syllabusSection` spent a paragraph on, minus the paragraph.
    private var syllabusLineText: String {
        guard let attached = store.syllabus(courseID: courseID) else { return "syllabus: none" }
        let count = attached.scheme.normalizedCategories.count
        return "syllabus: attached \u{00b7} \(count) categor\(count == 1 ? "y" : "ies")"
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("no grades for this class yet.")
                .font(.lhfSerif(17))
                .foregroundStyle(Color.v2DateText)
            Text("once canvas has scored something, the full report shows up here.")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2RingSub)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
