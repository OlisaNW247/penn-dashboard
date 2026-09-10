import SwiftUI
import LowHangingFruitKit

/// One class's Grade Watcher card: big current-grade number, a "decided vs
/// still open" bar, status chips, and an expandable category breakdown with
/// manual weight editing. Visual idiom matches `AssignmentCardView` /
/// `DoneCardView` (white v2Card surface, 13pt continuous corners, soft
/// shadow) so this reads as native to the rest of the app.
struct GradeCourseCardView: View {
    @ObservedObject var store: GradeWatcherStore
    let courseID: String
    let courseName: String
    /// "lecture" / "lab" / "recitation" when this course code has several
    /// Canvas sites (`AppState.gradeSiteLabel`), else nil. Distinguishes two
    /// cards that would otherwise both just say "PHYS 0151" — the real-phone
    /// report this fixes had a pass/fail lab site reading as if it were the
    /// letter-graded lecture.
    let siteLabel: String?

    @State private var isExpanded = false
    @State private var isUnmatchedExpanded = false
    @State private var isSuggestedExpanded = false

    private let corner: CGFloat = 13

    private var breakdown: GradeBreakdown? {
        store.breakdown(courseID: courseID)
    }

    /// Gradescope scores that named an assignment but never made it into this
    /// course's math (docs/grades.md §4) — no candidate, ambiguous, or a
    /// duplicate of an already-filled item. Never counted; shown so the user
    /// can see what Gradescope has that Grade Watcher didn't apply.
    private var unmatchedScores: [GradescopeOverlay.UnmatchedItem] {
        store.unmatchedGradescopeScores(courseID: courseID)
    }

    /// Lower-confidence fuzzy name matches (docs/grades.md §5 item 4) — never
    /// counted until the user explicitly confirms one via `suggestedMatchRow`.
    private var suggestedMatches: [GradescopeOverlay.SuggestedMatch] {
        store.suggestedGradescopeMatches(courseID: courseID)
    }

    private var hasSnapshot: Bool {
        store.snapshots[courseID] != nil
    }

    /// A refresh has been attempted at least once (success or failure) — used
    /// to tell "still loading for the first time" apart from "we tried and
    /// this course's fetch failed."
    private var hasAttemptedRefresh: Bool {
        store.lastRefreshed != nil || store.error != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.isCourseExcluded(courseID: courseID) {
                // A course the student has said doesn't count toward their
                // grade (the lab-site fix) gets a compact card: no percent,
                // no decided bar, no report link -- there is nothing to
                // compute or drill into for a class whose grade isn't being
                // tracked, and showing those affordances anyway would imply
                // otherwise.
                excludedHeader
                    .padding(14)
            } else {
                header
                    .padding(14)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleExpanded() }

                if breakdown != nil {
                    Divider().padding(.horizontal, 14)
                    reportLink
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }

                if isExpanded, let breakdown {
                    Divider().padding(.horizontal, 14)
                    VStack(alignment: .leading, spacing: 12) {
                        if let explanation = store.explanation(courseID: courseID) {
                            GradeExplanationView(explanation: explanation, compact: true)
                        }
                        breakdownList(breakdown)
                    }
                    .padding(14)
                }
            }
        }
        .background(Color.v2Card)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .shadow(color: Color.v2CardShadow.opacity(0.06), radius: 2, y: 1)
    }

    /// Compact card body for a course excluded from the grade math (docs/
    /// grades.md — the pass/fail lab site must not read as the lecture).
    private var excludedHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.headerText(courseName: courseName, siteLabel: siteLabel))
                .font(.lhfSans(9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.v2CourseCode)
            Text("not counted toward your grade")
                .font(.lhfSans(13))
                .foregroundStyle(Color.v2DateText)
            Button {
                store.setCourseExcluded(courseID: courseID, false)
            } label: {
                Text("count it")
                    .font(.lhfSans(11, weight: .semibold))
                    .foregroundStyle(Color.v2SpineBlue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("count \(courseName) toward your grade")
        }
    }

    /// Route into the full report, plus the watch toggle.
    ///
    /// Watching is opt-in per class because attaching a syllabus is per-course
    /// setup work; the report itself is always reachable, since everything in
    /// it except the syllabus parts is computed from data already fetched.
    private var reportLink: some View {
        HStack(spacing: 10) {
            NavigationLink {
                GradeReportView(store: store, courseID: courseID, courseName: courseName, siteLabel: siteLabel)
            } label: {
                HStack(spacing: 4) {
                    Text("full report")
                        .font(.lhfSans(12, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.v2SpineBlue)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                store.setWatching(!store.isWatching(courseID), courseID: courseID)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: store.isWatching(courseID) ? "eye.fill" : "eye")
                        .font(.system(size: 11))
                    Text(store.isWatching(courseID) ? "Watching" : "Watch")
                        .font(.lhfSans(11, weight: .medium))
                }
                .foregroundStyle(store.isWatching(courseID) ? Color.v2SpinePurple : Color.v2CourseCode)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isWatching(courseID)
                                ? "Stop watching \(courseName)"
                                : "Watch \(courseName)")
        }
    }

    // MARK: - Header (collapsed content)

    @ViewBuilder
    private var header: some View {
        if let breakdown {
            loadedHeader(breakdown)
        } else if !hasSnapshot && hasAttemptedRefresh && !store.isRefreshing && !store.isSessionExpired {
            cardErrorState
        } else if store.isSessionExpired && !hasSnapshot {
            cardLoginNeededState
        } else {
            cardLoadingState
        }
    }

    private func loadedHeader(_ breakdown: GradeBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.headerText(courseName: courseName, siteLabel: siteLabel))
                    .font(.lhfSans(9, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Color.v2CourseCode)
                Spacer()
                cardMenu
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.v2CourseCode)
                    .accessibilityHidden(true)
            }

            gradeRow(breakdown)
            decidedBar(breakdown)

            if breakdown.pendingGradingCount > 0 || differsFromCanvas(breakdown) {
                chipsRow(breakdown)
            }
        }
    }

    /// The "…" menu: whether this course counts toward the GPA/term summary
    /// at all, and which grading mode (canvas / weighted / points) the
    /// engine should use for it. Both are per-course overrides the student
    /// controls directly, rather than only being reachable by tapping into
    /// the full report.
    private var cardMenu: some View {
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
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.v2CourseCode)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("grade options for \(courseName)")
        .buttonStyle(.plain)
    }

    /// Big number + "this week" delta chip + trajectory sparkline
    /// (docs/grades.md §11). Chip and sparkline appear only once their data
    /// exists, so a fresh course degrades to just the number.
    private func gradeRow(_ breakdown: GradeBreakdown) -> some View {
        HStack(alignment: .center, spacing: 10) {
            currentGradeLine(breakdown)

            if let delta = displayedWeekDelta {
                Chip(
                    text: String(format: "%@ %.1f this week", delta > 0 ? "\u{25B2}" : "\u{25BC}", abs(delta)),
                    color: delta > 0 ? .v2SpineGreen : .v2SpineRed
                )
                .accessibilityLabel(String(format: "%@ %.1f points since last week", delta > 0 ? "Up" : "Down", abs(delta)))
            }

            Spacer(minLength: 8)

            if trajectory.count >= 2 {
                GradeSparkline(points: trajectory, endpointColor: sparklineEndpointColor)
                    .frame(width: 64, height: 26)
            }
        }
    }

    /// Hidden while |Δ| < 0.1 — rounding noise isn't a trend.
    private var displayedWeekDelta: Double? {
        guard let delta = store.weekDelta(courseID: courseID), abs(delta) >= 0.1 else { return nil }
        return delta
    }

    private var trajectory: [GradeEngine.TrajectoryPoint] {
        store.trajectory(courseID: courseID)
    }

    /// Direction tint: the observed week delta when there is one, otherwise
    /// the trajectory's own overall slope; neutral course-code grey when flat.
    private var sparklineEndpointColor: Color {
        if let delta = displayedWeekDelta {
            return delta > 0 ? .v2SpineGreen : .v2SpineRed
        }
        guard let first = trajectory.first, let last = trajectory.last else { return .v2CourseCode }
        if last.percent - first.percent > 0.05 { return .v2SpineGreen }
        if first.percent - last.percent > 0.05 { return .v2SpineRed }
        return .v2CourseCode
    }

    @ViewBuilder
    private func currentGradeLine(_ breakdown: GradeBreakdown) -> some View {
        if let percent = breakdown.currentPercent {
            Text(formatPercent(percent))
                .font(.lhfSerif(34))
                .foregroundStyle(Color.v2Ink)
                .accessibilityLabel("current grade \(Int(percent.rounded())) percent in \(courseName)")
        } else {
            Text("no scores yet")
                .font(.lhfSerif(22))
                .foregroundStyle(Color.v2DateText)
                .accessibilityLabel("no grades yet in \(courseName)")
        }
    }

    private func decidedBar(_ breakdown: GradeBreakdown) -> some View {
        let fraction = min(max(Self.decidedFraction(for: breakdown), 0), 1)
        // A real-phone report: a pass/fail lab site two weeks into term read
        // "63% of your grade is decided," because that number was only ever
        // measured against what Canvas had posted so far (2 of a semester's
        // 12 labs, both graded). `Self.decidedFraction`/`decidedText` prefer
        // `semesterDecidedFraction` — the syllabus-informed whole-semester
        // share — the moment it's known, and fall back to the old
        // posted-only reading with a caveat when it isn't. The fill is
        // dimmed in the fallback case so the bar itself hints "this isn't
        // the honest number yet" even before the caption is read.
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

            Text(Self.decidedText(for: breakdown))
                .font(.lhfSans(10.5))
                .foregroundStyle(Color.v2RingSub)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.decidedText(for: breakdown))
    }

    private func chipsRow(_ breakdown: GradeBreakdown) -> some View {
        HStack(spacing: 6) {
            if breakdown.pendingGradingCount > 0 {
                Chip(
                    text: "\(breakdown.pendingGradingCount) pending grading",
                    color: .v2SpineAmber
                )
            }
            if differsFromCanvas(breakdown) {
                Text("differs from canvas\(canvasScoreSuffix(breakdown))")
                    .font(.lhfSans(9.5))
                    .foregroundStyle(Color.v2RingSub)
                    .lineLimit(1)
            }
        }
    }

    private func canvasScoreSuffix(_ breakdown: GradeBreakdown) -> String {
        guard let canvasScore = store.canvasComputedScore(courseID: courseID) else { return "" }
        return " (Canvas: \(formatPercent(canvasScore)))"
    }

    private func differsFromCanvas(_ breakdown: GradeBreakdown) -> Bool {
        store.differsFromCanvas(courseID: courseID, currentPercent: breakdown.currentPercent)
    }

    // MARK: - Header (per-card non-happy-path states)

    private var cardLoadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("loading \(courseName)\u{2026}")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2RingSub)
        }
    }

    private var cardErrorState: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(courseName.uppercased())
                    .font(.lhfSans(9, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Color.v2CourseCode)
                Text("couldn\u{2019}t load this class\u{2019}s grades.")
                    .font(.lhfSans(12, weight: .medium))
                    .foregroundStyle(Color.v2DueRed)
            }
            Spacer()
        }
    }

    private var cardLoginNeededState: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(courseName.uppercased())
                    .font(.lhfSans(9, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Color.v2CourseCode)
                Text("log in to canvas to load this class\u{2019}s grades.")
                    .font(.lhfSans(12, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
            }
            Spacer()
        }
    }

    // MARK: - Decided-fraction / header text rules (pure, tested — see
    // GradeDecidedTextTests.swift)

    /// The fraction the decided bar/caption actually reports: the
    /// syllabus-informed whole-semester share when the engine could compute
    /// one, otherwise the old posted-only share. Shared by
    /// `GradeReportView`'s headline so the card and the full report never
    /// say two different "decided" numbers for the same course.
    static func decidedFraction(for breakdown: GradeBreakdown) -> Double {
        breakdown.semesterDecidedFraction ?? breakdown.decidedFraction
    }

    /// "N% of the semester is decided" once `semesterDecidedFraction` is
    /// known; otherwise "N% of what's posted is graded · semester share
    /// unknown," which is the honest fallback when the syllabus hasn't given
    /// every relevant category an expected item count yet.
    static func decidedText(for breakdown: GradeBreakdown) -> String {
        let percent = Int((min(max(decidedFraction(for: breakdown), 0), 1) * 100).rounded())
        if breakdown.semesterDecidedFraction != nil {
            return "\(percent)% of the semester is decided"
        }
        return "\(percent)% of what\u{2019}s posted is graded \u{00b7} semester share unknown"
    }

    /// "COURSE NAME" alone, or "COURSE NAME · LAB" when a course code has
    /// several Canvas sites (`AppState.gradeSiteLabel`) and this card needs
    /// to say which one it is.
    static func headerText(courseName: String, siteLabel: String?) -> String {
        let base = courseName.uppercased()
        guard let siteLabel, !siteLabel.isEmpty else { return base }
        return "\(base) \u{00b7} \(siteLabel.uppercased())"
    }

    private func toggleExpanded() {
        guard breakdown != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
        }
    }

    // MARK: - Expanded breakdown

    private func breakdownList(_ breakdown: GradeBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(breakdown.categories) { category in
                GradeCategoryRow(
                    store: store,
                    courseID: courseID,
                    category: category,
                    hasGradescopeEarlyScore: hasGradescopeEarlyScore(for: category)
                )
            }

            if breakdown.mode == .points {
                Text("this class uses points, not weights. manual weights only apply once every category above has one. a partial set is ignored, so this class stays points-based until then.")
                    .font(.lhfSans(10.5))
                    .foregroundStyle(Color.v2RingSub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !suggestedMatches.isEmpty {
                suggestedMatchesDisclosure
            }

            if !unmatchedScores.isEmpty {
                unmatchedDisclosure
            }
        }
    }

    /// Whether any scored, kept (post-drop) item in this category came from
    /// the Gradescope early overlay (docs/grades.md §6 "Per-number source
    /// badges"). `GradeBreakdown.CategoryResult` only carries aggregates, so
    /// this looks the category back up in the overlay-applied `GradeCategory`
    /// list (which does carry per-item `scoreSource`) via `store.gradeCategories`.
    private func hasGradescopeEarlyScore(for category: GradeBreakdown.CategoryResult) -> Bool {
        guard let liveCategory = store.gradeCategories(courseID: courseID).first(where: { $0.id == category.id }) else {
            return false
        }
        return liveCategory.items.contains { item in
            !item.isExcused && !item.omitFromFinalGrade
                && item.score != nil
                && item.scoreSource == .gradescopeEarly
                && !category.droppedItemIDs.contains(item.id)
        }
    }

    // MARK: - Suggested Gradescope matches (docs/grades.md §5 item 4 — fuzzy tier, user-confirmable)

    private var suggestedMatchesDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSuggestedExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isSuggestedExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                    Text("\(suggestedMatches.count) suggested gradescope \(suggestedMatches.count == 1 ? "match" : "matches")")
                        .font(.lhfSans(10.5, weight: .medium))
                }
                .foregroundStyle(Color.v2SpineAmber)
            }
            .buttonStyle(.plain)

            if isSuggestedExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(suggestedMatches.enumerated()), id: \.offset) { _, match in
                        suggestedMatchRow(match)
                    }
                    Text("not counted yet. confirm a match to apply its score.")
                        .font(.lhfSans(9.5))
                        .foregroundStyle(Color.v2RingSub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
    }

    private func suggestedMatchRow(_ match: GradescopeOverlay.SuggestedMatch) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\u{201c}\(match.gradescopeTitle)\u{201d} \u{2192} \(match.itemName)")
                    .font(.lhfSans(10.5))
                    .foregroundStyle(Color.v2Ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(formatPoints(match.scoreEarned))/\(formatPoints(match.scoreMax))")
                    .font(.lhfSans(9.5))
                    .foregroundStyle(Color.v2RingSub)
            }
            Spacer(minLength: 8)
            Button {
                store.confirmSuggestedMatch(courseID: courseID, match: match)
            } label: {
                Label("confirm", systemImage: "checkmark.circle.fill")
                    .font(.lhfSans(10.5, weight: .medium))
                    .foregroundStyle(Color.v2SpineGreen)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("confirm \(match.gradescopeTitle) matches \(match.itemName)")
        }
    }

    // MARK: - Unmatched Gradescope scores

    private var unmatchedDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isUnmatchedExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isUnmatchedExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                    Text("\(unmatchedScores.count) unmatched gradescope \(unmatchedScores.count == 1 ? "score" : "scores")")
                        .font(.lhfSans(10.5, weight: .medium))
                }
                .foregroundStyle(Color.v2RingSub)
            }
            .buttonStyle(.plain)

            if isUnmatchedExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(unmatchedScores.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top) {
                            Text(item.title)
                                .font(.lhfSans(10.5))
                                .foregroundStyle(Color.v2Ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text("\(formatPoints(item.scoreEarned))/\(formatPoints(item.scoreMax))")
                                .font(.lhfSans(10.5))
                                .foregroundStyle(Color.v2RingSub)
                        }
                    }
                    Text("not counted. no matching canvas assignment.")
                        .font(.lhfSans(9.5))
                        .foregroundStyle(Color.v2RingSub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - Shared small views

/// A pill-shaped status chip. This is the app's first reusable chip/badge
/// component — `AssignmentCardView`/`DoneCardView` inline their labels, but
/// Grade Watcher needs the same look in several places (pending count, source
/// badges), so it's factored out here instead of copy-pasted a third time.
struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.lhfSans(9.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// Per-number provenance badge. `ScoreSource` has all three cases (`canvas` /
/// `gradescopeEarly` / `manual`) from CP2; used both for a category's weight
/// source (`GradeCategoryRow`'s weight column) and, since the CP5 fuzzy-tier
/// fix, for the category's scored-numbers line whenever a Gradescope-early
/// score contributes to it (docs/grades.md §6 "Per-number source badges").
struct GradeSourceBadge: View {
    let source: ScoreSource

    var body: some View {
        Chip(text: label, color: color)
    }

    private var label: String {
        switch source {
        case .canvas: return "Canvas"
        case .gradescopeEarly: return "Gradescope early"
        case .manual: return "Manual"
        case .syllabus: return "Syllabus"
        }
    }

    private var color: Color {
        switch source {
        case .canvas: return .v2SpineBlue
        case .gradescopeEarly: return .v2SpineGreen
        case .manual: return .v2SpineAmber
        case .syllabus: return .v2SpinePurple
        }
    }
}

// MARK: - Formatting helpers

/// "91.4%" — one decimal, trimmed when it's a whole number ("100%" not "100.0%").
func formatPercent(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    if rounded == rounded.rounded() {
        return "\(Int(rounded))%"
    }
    return String(format: "%.1f%%", rounded)
}

/// "34/40 pts" — whole numbers unless the value genuinely has a fraction
/// (extra credit / partial credit can produce non-integers).
func formatPoints(_ value: Double) -> String {
    if value == value.rounded() {
        return "\(Int(value))"
    }
    return String(format: "%.1f", value)
}
