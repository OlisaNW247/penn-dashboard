import SwiftUI
import LowHangingFruitKit

/// The full grade report for one watched class (docs/grades.md §13).
///
/// The card answers "what's my grade." This answers the questions that
/// actually change what a student does next: where can this still land, what
/// would I need on the rest, and how much of the course hasn't happened yet.
///
/// Every number here is arithmetic over scores that already exist — the
/// projections are floor/ceiling/pace, not guesses — and everything derived
/// from a syllabus is labeled as such.
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

    @State private var targetPercent: Double?
    @State private var showSyllabusSetup = false
    @State private var expandedCategoryIDs: Set<String> = []
    @State private var editingItem: GradeItem?
    @State private var showResetConfirmation = false

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
            VStack(alignment: .leading, spacing: 18) {
                if let breakdown, let projection {
                    headline(breakdown)
                    explanationSection
                    landingSection(projection)
                    targetSection(projection)
                    remainingSection(breakdown, projection)
                    categoriesSection(breakdown)
                    syllabusSection
                    caveats(breakdown)
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

    /// Same grade-options menu as the card (`GradeCourseCardView.cardMenu`),
    /// plus a class-wide "reset all edits" the card doesn't have room for.
    /// Kept as its own copy rather than factored out: the card's version is
    /// a plain `Menu` view, this one is a `ToolbarContent` builder, and the
    /// two SwiftUI result-builder contexts don't share a body type.
    @ToolbarContentBuilder
    private var reportMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle("counts toward my grade", isOn: Binding(
                    get: { !store.isCourseExcluded(courseID: courseID) },
                    set: { countsNow in store.setCourseExcluded(courseID: courseID, !countsNow) }
                ))

                Picker("grading", selection: Binding(
                    get: { store.modeOverride(courseID: courseID) },
                    set: { store.setModeOverride(courseID: courseID, mode: $0) }
                )) {
                    Text("as canvas says").tag(GradingMode?.none)
                    Text("weighted by category").tag(GradingMode?.some(.weighted))
                    Text("points").tag(GradingMode?.some(.points))
                }

                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Text("reset all edits for this class")
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

    @ViewBuilder
    private func headline(_ breakdown: GradeBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let percent = breakdown.currentPercent {
                    Text(formatPercent(percent))
                        .font(.lhfSerif(40))
                        .foregroundStyle(Color.v2Ink)
                    if let letter = cutoffs.letter(forPercent: percent) {
                        Text(letter)
                            .font(.lhfSerif(20))
                            .foregroundStyle(Color.v2DateText)
                    }
                } else {
                    Text("no scores yet")
                        .font(.lhfSerif(26))
                        .foregroundStyle(Color.v2DateText)
                }
                Spacer()
            }

            Text(cutoffs.isCustom
                 ? "letter from your syllabus\u{2019}s cutoffs"
                 : "letter estimated \u{00b7} standard cutoffs")
                .font(.lhfSans(10.5))
                .foregroundStyle(Color.v2RingSub)

            decidedBar(breakdown)
        }
    }

    /// Same "decided" rule as the card (`GradeCourseCardView.decidedFraction`/
    /// `.decidedText`) -- reused rather than reimplemented so this headline
    /// and the card can never end up saying two different things about the
    /// same course's "how much is decided."
    private func decidedBar(_ breakdown: GradeBreakdown) -> some View {
        let fraction = min(max(GradeCourseCardView.decidedFraction(for: breakdown), 0), 1)
        let isSemesterKnown = breakdown.semesterDecidedFraction != nil
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.v2RingTrack)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.v2SpineBlue)
                        .opacity(isSemesterKnown ? 1 : 0.5)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
            Text(GradeCourseCardView.decidedText(for: breakdown))
                .font(.lhfSans(10.5))
                .foregroundStyle(Color.v2RingSub)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GradeCourseCardView.decidedText(for: breakdown))
    }

    // MARK: - How this is calculated

    @ViewBuilder
    private var explanationSection: some View {
        if let explanation = store.explanation(courseID: courseID) {
            ReportSection(title: "How this is calculated") {
                GradeExplanationView(explanation: explanation)
            }
        }
    }

    // MARK: - Where you land

    private func landingSection(_ projection: GradeProjection) -> some View {
        ReportSection(title: "Where you land") {
            if projection.isDecided {
                Text("everything is graded. this is your final grade.")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2DateText)
            } else {
                HStack(spacing: 10) {
                    LandingTile(
                        label: "If you stop now",
                        value: formatPercent(projection.floorPercent),
                        caption: "score 0 on the rest",
                        color: .v2SpineRed
                    )
                    LandingTile(
                        label: "At this pace",
                        value: projection.pacePercent.map(formatPercent) ?? "-",
                        caption: "rest goes like so far",
                        color: .v2SpineBlue
                    )
                    LandingTile(
                        label: "Best case",
                        value: formatPercent(projection.ceilingPercent),
                        caption: "100% on the rest",
                        color: .v2SpineGreen
                    )
                }
                Text("projections, not predictions. they assume the professor grades what\u{2019}s listed and nothing gets curved.")
                    .font(.lhfSans(10))
                    .foregroundStyle(Color.v2RingSub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - What you'd need

    @ViewBuilder
    private func targetSection(_ projection: GradeProjection) -> some View {
        if !projection.isDecided {
            ReportSection(title: "What you\u{2019}d need") {
                let bands = cutoffs.targetBands.prefix(6)
                let selected = targetPercent ?? defaultTarget(projection)

                Picker("target", selection: Binding(
                    get: { selected },
                    set: { targetPercent = $0 }
                )) {
                    ForEach(Array(bands), id: \.letter) { band in
                        Text(band.letter).tag(band.minPercent)
                    }
                }
                .pickerStyle(.segmented)

                requirementLine(projection.requiredAverage(for: selected), target: selected)
            }
        }
    }

    /// Aim one band above where the course currently sits — the question a
    /// student actually asks is "can I still pull this up," not "how do I keep
    /// the grade I already have."
    private func defaultTarget(_ projection: GradeProjection) -> Double {
        let current = breakdown?.currentPercent ?? projection.floorPercent
        let next = cutoffs.nextBandUp(fromPercent: current)?.minPercent
        return next ?? cutoffs.targetBands.first?.minPercent ?? 90
    }

    /// "an A" / "a B+" — letter grades that start with a vowel sound need the
    /// other article, and "a A" in the headline sentence reads as a bug.
    private func article(for letter: String) -> String {
        "AEF".contains(letter.prefix(1)) ? "an" : "a"
    }

    @ViewBuilder
    private func requirementLine(_ requirement: GradeProjection.Requirement, target: Double) -> some View {
        let letter = cutoffs.band(forPercent: target)?.letter ?? formatPercent(target)
        switch requirement {
        case .alreadyReached:
            Text("\(article(for: letter).capitalized) \(letter) is already locked in. even a zero on everything left keeps it.")
                .font(.lhfSans(13))
                .foregroundStyle(Color.v2SpineGreen)
                .fixedSize(horizontal: false, vertical: true)
        case let .need(percent):
            VStack(alignment: .leading, spacing: 3) {
                Text(formatPercent(percent))
                    .font(.lhfSerif(28))
                    .foregroundStyle(Color.v2Ink)
                Text("average on everything still open, to finish with \(article(for: letter)) \(letter).")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2DateText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .unreachable(shortfall):
            Text(String(format: "%@ %@ is out of reach. even 100%% on everything left finishes about %.1f points short.",
                        article(for: letter).capitalized, letter, abs(shortfall)))
                .font(.lhfSans(13))
                .foregroundStyle(Color.v2DueAmber)
                .fixedSize(horizontal: false, vertical: true)
        case .nothingLeft:
            Text("nothing left to score. the grade is final.")
                .font(.lhfSans(13))
                .foregroundStyle(Color.v2DateText)
        }
    }

    // MARK: - What's left

    private func remainingSection(_ breakdown: GradeBreakdown, _ projection: GradeProjection) -> some View {
        ReportSection(title: "What\u{2019}s left") {
            VStack(alignment: .leading, spacing: 6) {
                statLine(
                    "\(projection.upcomingItemCount)",
                    label: projection.upcomingItemCount == 1 ? "assignment still to come" : "assignments still to come"
                )
                if breakdown.pendingGradingCount > 0 {
                    statLine(
                        "\(breakdown.pendingGradingCount)",
                        label: "past due, waiting on a grade",
                        color: .v2SpineAmber
                    )
                }
                statLine(
                    "\(Int((projection.openShare * 100).rounded()))%",
                    label: "of your final grade still open"
                )

                ForEach(store.countGaps(courseID: courseID)) { gap in
                    Text("your syllabus lists \(gap.expected) \(gap.categoryName.lowercased()); canvas shows \(gap.listedInCanvas). \(gap.missing) probably \(gap.missing == 1 ? "hasn\u{2019}t" : "haven\u{2019}t") been posted yet.")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2RingSub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func statLine(_ value: String, label: String, color: Color = .v2Ink) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.lhfSerif(17))
                .foregroundStyle(color)
            Text(label)
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2DateText)
            Spacer()
        }
    }

    // MARK: - Categories

    private func categoriesSection(_ breakdown: GradeBreakdown) -> some View {
        ReportSection(title: breakdown.mode == .weighted ? "Categories" : "Points") {
            VStack(spacing: 8) {
                ForEach(breakdown.categories) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        GradeCategoryRow(
                            store: store,
                            courseID: courseID,
                            category: category,
                            hasGradescopeEarlyScore: hasGradescopeEarlyScore(for: category)
                        )
                        itemsDisclosure(for: category)
                    }
                }
            }
        }
    }

    /// `CategoryResult` doesn't carry per-item provenance, so this looks the
    /// category back up in the overlay-applied list — same approach as the card.
    private func hasGradescopeEarlyScore(for category: GradeBreakdown.CategoryResult) -> Bool {
        guard let live = store.gradeCategories(courseID: courseID).first(where: { $0.id == category.id }) else {
            return false
        }
        return live.items.contains { item in
            !item.isExcused && !item.omitFromFinalGrade
                && item.score != nil
                && item.scoreSource == .gradescopeEarly
                && !category.droppedItemIDs.contains(item.id)
        }
    }

    // MARK: - Category items (tap to correct one score)

    @ViewBuilder
    private func itemsDisclosure(for category: GradeBreakdown.CategoryResult) -> some View {
        let items = store.items(courseID: courseID, categoryID: category.id)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        toggleCategoryExpanded(category.id)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expandedCategoryIDs.contains(category.id) ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text("\(items.count) \(items.count == 1 ? "item" : "items")")
                            .font(.lhfSans(10.5, weight: .medium))
                    }
                    .foregroundStyle(Color.v2SpineBlue)
                }
                .buttonStyle(.plain)

                if expandedCategoryIDs.contains(category.id) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            itemRow(item)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func toggleCategoryExpanded(_ categoryID: String) {
        if expandedCategoryIDs.contains(categoryID) {
            expandedCategoryIDs.remove(categoryID)
        } else {
            expandedCategoryIDs.insert(categoryID)
        }
    }

    /// One item row: name, "score / possible" (canvas's own numbers, or the
    /// override's when the student corrected one), and whatever badges apply.
    /// Tapping opens `GradeItemEditorSheet` to correct or clear the override.
    private func itemRow(_ item: GradeItem) -> some View {
        let override = store.itemOverrides(courseID: courseID)[item.id]
        return Button {
            editingItem = item
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.lhfSans(11.5))
                        .foregroundStyle(Color.v2Ink)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        if item.isExcused {
                            itemBadge("excused")
                        }
                        if override?.isExcluded == true {
                            itemBadge("excluded")
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
        .accessibilityLabel("\(item.name), \(itemScoreText(item, override: override))")
    }

    private func itemScoreText(_ item: GradeItem, override: GradeItemOverride?) -> String {
        let score = override?.score ?? item.score
        let possible = override?.pointsPossible ?? item.pointsPossible
        guard let score else { return "\u{2014}" }
        return "\(formatPoints(score)) / \(formatPoints(possible))"
    }

    /// Matches the dashboard's "nothing to submit" caveat register, same as
    /// `GradeExplanationView`'s category badges.
    private func itemBadge(_ text: String) -> some View {
        Text(text)
            .font(.lhfSans(9, weight: .semibold))
            .foregroundStyle(Color.v2CourseCode)
    }

    // MARK: - Syllabus

    @ViewBuilder
    private var syllabusSection: some View {
        ReportSection(title: "Syllabus") {
            if let attached = store.syllabus(courseID: courseID) {
                attachedSyllabusBody(attached)
            } else if let suggestion = store.suggestedScheme(courseID: courseID) {
                suggestedSchemeBody(suggestion.scheme)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("canvas knows what\u{2019}s graded, not what it\u{2019}s worth. add your syllabus and this report can use the real weights, cutoffs and assignment counts.")
                        .font(.lhfSans(12))
                        .foregroundStyle(Color.v2DateText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("add your syllabus") { showSyllabusSetup = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }

    /// A course with no syllabus of its own yet, but whose weights another
    /// student's device already read off theirs and the backend pooled
    /// server-side (`GradeWatcherStore.suggestedScheme`). Shown instead of
    /// the plain "add your syllabus" prompt, never instead of an actually
    /// attached one — `syllabusSection` above only reaches this branch when
    /// `store.syllabus(courseID:)` is nil. Honesty rule: this never applies
    /// itself; "use these weights" is the only path to
    /// `applySuggestedScheme`, exactly like the parsed-syllabus review
    /// screen's own "use these weights" button.
    @ViewBuilder
    private func suggestedSchemeBody(_ scheme: SyllabusGradingScheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("suggested from the syllabus, as read by locust\u{2019}s server.")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2DateText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(scheme.normalizedCategories) { category in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(category.name)
                                .font(.lhfSans(12, weight: .medium))
                            Spacer()
                            Text(formatPercent(category.weightPercent))
                                .font(.lhfSans(12))
                                .foregroundStyle(Color.v2DateText)
                        }
                        if category.dropLowest > 0 || category.expectedItemCount != nil {
                            Text(suggestedExtras(for: category))
                                .font(.lhfSans(10))
                                .foregroundStyle(Color.v2SpinePurple)
                        }
                    }
                }
            }

            HStack(spacing: 16) {
                Button("use these weights") {
                    store.applySuggestedScheme(courseID: courseID)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("review the syllabus instead") { showSyllabusSetup = true }
                    .font(.lhfSans(12))
            }
        }
    }

    /// "12 expected" / "drops lowest 2" / both, joined — same shape as
    /// `SyllabusSetupView.extras(for:)`, kept as a separate copy rather than
    /// shared because that one is `private` to its own file and this row is
    /// cosmetic enough not to be worth a shared helper over.
    private func suggestedExtras(for category: SyllabusCategory) -> String {
        var parts: [String] = []
        if category.dropLowest > 0 {
            parts.append("drops \(category.dropLowest) lowest")
        }
        if let count = category.expectedItemCount {
            parts.append("\(count) expected")
        }
        return parts.joined(separator: " \u{00b7} ")
    }

    @ViewBuilder
    private func attachedSyllabusBody(_ attached: AttachedSyllabus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(attached.documentName ?? attached.source.label)
                    .font(.lhfSans(12, weight: .medium))
                    .foregroundStyle(Color.v2Ink)
                    .lineLimit(1)
                Spacer()
                Button("review") { showSyllabusSetup = true }
                    .font(.lhfSans(12))
            }

            if let match = store.syllabusMatch(courseID: courseID) {
                if match.isCompleteCoverage {
                    Label("weights from your syllabus are being used.", systemImage: "checkmark.circle.fill")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2SpineGreen)
                } else {
                    let applied = match.matches.filter(\.isApplied).count
                    Label("\(applied) of \(match.matches.count) categories matched. finish matching to use your syllabus\u{2019}s weights.",
                          systemImage: "exclamationmark.circle")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2DueAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if attached.scheme.mentionsCurve {
                Text("your syllabus mentions a curve or instructor discretion, so cutoffs and projections may not hold exactly.")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Caveats

    @ViewBuilder
    private func caveats(_ breakdown: GradeBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.differsFromCanvas(courseID: courseID, currentPercent: breakdown.currentPercent),
               let canvasScore = store.canvasComputedScore(courseID: courseID) {
                Text("canvas computes \(formatPercent(canvasScore)) for this class. the difference usually means a late policy or a rule we can\u{2019}t see.")
                    .font(.lhfSans(10.5))
                    .foregroundStyle(Color.v2RingSub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("last refreshed \(relativeTimeString(store.lastRefreshed)).")
                .font(.lhfSans(10.5))
                .foregroundStyle(Color.v2RingSub)
        }
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

// MARK: - Small shared pieces

/// A titled block on the report. Consistent card treatment so the report reads
/// as a sequence of answers rather than one long wall.
struct ReportSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.lhfSans(9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.v2CourseCode)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.v2Card)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: Color.v2CardShadow.opacity(0.06), radius: 2, y: 1)
    }
}

/// One of the three floor/pace/ceiling numbers.
struct LandingTile: View {
    let label: String
    let value: String
    let caption: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.lhfSans(9.5, weight: .medium))
                .foregroundStyle(Color.v2CourseCode)
                .lineLimit(1)
            Text(value)
                .font(.lhfSerif(20))
                .foregroundStyle(color)
            Text(caption)
                .font(.lhfSans(9))
                .foregroundStyle(Color.v2RingSub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value), \(caption)")
    }
}
