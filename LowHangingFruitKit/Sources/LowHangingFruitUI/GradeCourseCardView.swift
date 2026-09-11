import SwiftUI
import LowHangingFruitKit

/// One class's Grade Watcher card, rebuilt minimal (docs/grades.md — Grade
/// Watcher's card and report used to carry full sentences and an expandable
/// category list; the whole card is now a single `NavigationLink` into
/// `GradeReportView` showing only a course code, the current number, a 3pt
/// decided bar and a six-word status line). Every action this card used to
/// offer inline now lives one tap away, in the report:
///
/// - the expand toggle and its `breakdownList` (category rows, manual weight
///   editing, expected-count editing) → the report's categories table, whose
///   rows expand to items and whose items open `GradeItemEditorSheet`; bulk
///   category restructuring moved to the report toolbar's "edit categories"
///   sheet (`GradeCategoryMapEditor`).
/// - the "full report" link and the Watch/Unwatch button → the whole card is
///   now the link, and Watch/Unwatch moved into the report's toolbar menu.
/// - `cardMenu` (counts-toward-grade toggle, grading-mode picker) → the same
///   toggle and picker, now in the report's toolbar menu only.
/// - the pending-grading / "differs from canvas" chips and the week-delta
///   chip + trajectory sparkline → the "differs from canvas" line moved into
///   the report's collapsed "how" section; the pending-grading count and the
///   sparkline are dropped rather than relocated (informational only, not on
///   the kept-capability list this rebuild was scoped against).
/// - the inline "count it" button on an excluded course's card → the
///   counts-toward-grade toggle in the report's toolbar menu (the excluded
///   card still navigates there).
/// - the suggested-Gradescope-match and unmatched-Gradescope-score
///   disclosures → the report's `suggestionsSection` (one use/skip nudge row
///   per fuzzy match, via `store.confirmSuggestedMatch`) and a one-line
///   unmatched count in its `howSection`.
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

    private let corner: CGFloat = 13

    private var breakdown: GradeBreakdown? {
        store.breakdown(courseID: courseID)
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
        NavigationLink {
            GradeReportView(store: store, courseID: courseID, courseName: courseName, siteLabel: siteLabel)
        } label: {
            content
                .padding(14)
        }
        .buttonStyle(.plain)
        .background(Color.v2Card)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .shadow(color: Color.v2CardShadow.opacity(0.06), radius: 2, y: 1)
    }

    @ViewBuilder
    private var content: some View {
        if store.isCourseExcluded(courseID: courseID) {
            // A course the student has said doesn't count toward their grade
            // (the lab-site fix) still opens the report -- "not counted" is a
            // state to review and reverse, not a dead end.
            excludedContent
        } else if let breakdown {
            loadedContent(breakdown)
        } else if !hasSnapshot && hasAttemptedRefresh && !store.isRefreshing && !store.isSessionExpired {
            oneWordState("offline")
        } else if store.isSessionExpired && !hasSnapshot {
            oneWordState("log in")
        } else {
            oneWordState("\u{2026}")
        }
    }

    private var excludedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerLine
            Text("not counted")
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2DateText)
        }
    }

    private func oneWordState(_ word: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            headerLine
            Text(word)
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2DateText)
        }
    }

    private var headerLine: some View {
        Text(Self.headerText(courseName: courseName, siteLabel: siteLabel))
            .font(.lhfSans(9, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(Color.v2CourseCode)
    }

    // MARK: - Loaded content

    private func loadedContent(_ breakdown: GradeBreakdown) -> some View {
        let headline = Self.headlineText(for: breakdown)
        return VStack(alignment: .leading, spacing: 8) {
            headerLine

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(headline.primary)
                    .font(.lhfSerif(34))
                    .foregroundStyle(Color.v2Ink)
                if let secondary = headline.secondary {
                    Text(secondary)
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2DateText)
                }
            }

            decidedBar(breakdown)

            Text(Self.statusText(for: breakdown))
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2DateText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(courseName): \(headline.secondary.map { "\(headline.primary), \($0)" } ?? headline.primary), \(Self.statusText(for: breakdown))")
    }

    /// Unlabeled 3pt fill — same fraction/dimming rule as before
    /// (`Self.decidedFraction`, dimmed while only the posted-only share is
    /// known), just without the caption underneath; the caption is now the
    /// card's one status line (`statusText`), not a second line under the bar.
    private func decidedBar(_ breakdown: GradeBreakdown) -> some View {
        let fraction = min(max(Self.decidedFraction(for: breakdown), 0), 1)
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

    // MARK: - Decided-fraction / header text rules (pure, tested — see
    // GradeDecidedTextTests.swift, GradeMinimalCopyTests.swift)
    //
    // These are `nonisolated` on purpose. A SwiftUI `View`'s members are
    // main-actor isolated, and under Swift 6 that isolation is enforced at
    // run time as well as compile time: a closure formed inside an isolated
    // static (even `{ $0.lowercased() }` inside a `map`) carries the
    // isolation and traps with `dispatch_assert_queue_fail` when it runs
    // off the main actor. `GradeDecidedTextTests` runs its cases on the
    // testing library's own executor, so the first test to reach such a
    // closure killed the whole `swift test` process with SIGTRAP and no
    // "Fatal error" line -- the earlier cases in the same suite passed only
    // because they returned before the closure. The wrong fix is to mark the
    // test suite `@MainActor`: that hides the trap but leaves pure string
    // rules pretending they need the UI thread, and the next caller from a
    // background context (a widget, a notification body) trips it again.
    // These functions read nothing from the view, so they have no business
    // being isolated.

    /// The fraction the decided bar/caption actually reports: the
    /// syllabus-informed whole-semester share when the engine could compute
    /// one, otherwise the old posted-only share. Shared by
    /// `GradeReportView`'s headline so the card and the full report never
    /// say two different "decided" numbers for the same course.
    nonisolated static func decidedFraction(for breakdown: GradeBreakdown) -> Double {
        breakdown.semesterDecidedFraction ?? breakdown.decidedFraction
    }

    /// Kept for compatibility and `GradeDecidedTextTests`, which still call
    /// it directly; the card itself now shows `statusText` instead of this
    /// sentence-length caption.
    nonisolated static func decidedText(for breakdown: GradeBreakdown) -> String {
        let percent = Int((min(max(decidedFraction(for: breakdown), 0), 1) * 100).rounded())
        if breakdown.semesterDecidedFraction != nil {
            return "\(percent)% of the semester is decided"
        }
        let base = "\(percent)% of what\u{2019}s posted is graded \u{00b7} semester share unknown"
        let missing = breakdown.categoriesMissingExpectedCount
        guard !missing.isEmpty else { return base }
        let names = missing.map { $0.lowercased() }.joined(separator: ", ")
        return "\(base) \u{00b7} add expected counts for \(names)"
    }

    /// The card's and report's one status line: "N% decided", with
    /// " · week W of T" appended once the engine knows the term's length
    /// (`GradeBreakdown.term`). W is the elapsed week, rounded up and floored
    /// at 1 -- a course three days into week 1 should read "week 1", not
    /// "week 0". At most six words, no sentence, matching the copy budget
    /// `GradeMinimalCopyTests` enforces.
    nonisolated static func statusText(for breakdown: GradeBreakdown) -> String {
        let percent = Int((min(max(decidedFraction(for: breakdown), 0), 1) * 100).rounded())
        var text = "\(percent)% decided"
        if let term = breakdown.term {
            let elapsed = max(1, Int(term.elapsedWeeks(at: Date()).rounded(.up)))
            let total = Int(term.weeks.rounded())
            text += " \u{00b7} week \(elapsed) of \(total)"
        }
        return text
    }

    /// The card's/report's headline pair: the big number, and -- only in the
    /// attendance-only case -- a second line underneath it. Pulled out as a
    /// pure function (rather than inlined) so the three cases (percent, no
    /// scores at all, attendance-only) are each independently testable
    /// without instantiating SwiftUI (see `GradeDecidedTextTests`).
    nonisolated static func headlineText(for breakdown: GradeBreakdown) -> (primary: String, secondary: String?) {
        if let percent = breakdown.currentPercent {
            return (formatPercent(percent), nil)
        }
        if let attendance = breakdown.attendanceOnlyPercent {
            return ("no graded work yet", "attendance \(formatPercent(attendance))")
        }
        return ("no scores yet", nil)
    }

    /// "COURSE NAME" alone, or "COURSE NAME · LAB" when a course code has
    /// several Canvas sites (`AppState.gradeSiteLabel`) and this card needs
    /// to say which one it is.
    nonisolated static func headerText(courseName: String, siteLabel: String?) -> String {
        let base = courseName.uppercased()
        guard let siteLabel, !siteLabel.isEmpty else { return base }
        return "\(base) \u{00b7} \(siteLabel.uppercased())"
    }
}

// MARK: - Shared small views

/// A pill-shaped status chip. Still used by `GradeCategoryMapEditor` and
/// `GradeExplanationView`'s "needs a home" flag even though the card and
/// report no longer use it directly.
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
/// `gradescopeEarly` / `manual`) from CP2; still used by `GradeCategoryRow`
/// and `GradeCategoryMapEditor`.
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
