import SwiftUI
import LowHangingFruitKit

/// The degree screen's "plan" tab: a summary line over the semester table
/// (`DegreeSemesterTable`, which the progress and what-if tabs host too). The
/// plan is the student's sketch and nothing else. The audit contributes only a
/// muted "fits" line under a planned course that Penn lists among the options
/// of a requirement it still has open. The screen never says a requirement is
/// satisfied by a plan, and never orders or suggests a course: whether a course
/// counts is Penn's decision when it is taken.
///
/// Reads `state.degreePlan` and `state.degree.current`; edits go through
/// `AppState+Degree.swift`, which saves them on the phone and nowhere else.
struct DegreePlanView: View {
    @EnvironmentObject var state: AppState

    private var audit: DegreeAudit? { state.degree.current }
    private var plan: DegreePlan { state.degreePlan }

    /// A dual-degree student plans toward both audits: the plan is one set of
    /// semesters.
    private var audits: [DegreeLabeledAudit] {
        if state.degreeHasSeveral { return state.degreeAudits }
        var single: [DegreeLabeledAudit] = []
        if let audit { single.append(DegreeLabeledAudit(degreeID: "current", label: "", audit: audit)) }
        return single
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            DegreeSemesterTable(audits: audits)
        }
    }

    // MARK: Summary

    private var summaryText: String? {
        let total = DegreePlanMath.totalPlannedCredits(plan)
        guard total > 0 else { return nil }
        var text = "\(DegreeProgressMath.credits(total)) cu planned"
        var covered = 0
        var open = 0
        for entry in audits {
            let counts = DegreePlanMath.coveredCount(plan: plan, audit: entry.audit)
            covered += counts.covered
            open += counts.open
        }
        if open > 0 {
            text += " · \(covered) of \(open) open requirements have a planned course"
        }
        return text
    }

    @ViewBuilder
    private var summary: some View {
        if let text = summaryText {
            Text(text)
                .font(.lhfSans(13))
                .foregroundStyle(Color.smoothMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the add sheet is open for: the semester it will add to.
struct PlanSheetTarget: Identifiable {
    let termCode: String
    var id: String { termCode }
}

/// The add sheet: type any course code, or tap a course that counts toward a
/// requirement still open. Until 2026-11-13 this sheet listed Penn's options in
/// Penn's order and nothing in it ranked, filtered or suggested; the owner
/// reversed that ("it should guide you and only recommend courses that
/// contribute to your degree. classes that contribute to a higher percentage
/// of completion to your degrees should be highlighted differently"). So the
/// list is now ordered by how much each course raises the degree estimate, and
/// a course that raises it by more than half a point carries that figure.
///
/// What survives from before: every course offered is still one Penn itself
/// lists as an option of a requirement that still has room, the percent is this
/// app's own estimate (the one the ring labels "with plan", never Penn's), and
/// typing any code still works. A typed course that counts nowhere is added all
/// the same; the line under the field only says what it would do. The list is
/// computed once when the sheet opens, in `.task`, and not in `body`: it runs
/// one projection per candidate and a requirement can list hundreds of courses.
struct DegreePlanAddSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let termCode: String
    /// The audits the table behind the sheet is drawn against, so a what-if's
    /// open requirements are the ones offered while a what-if is showing.
    let audits: [DegreeLabeledAudit]

    @State private var typed = ""
    @State private var credits = 1.0

    private var plan: DegreePlan { state.degreePlan }

    private var trimmed: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var termIsFull: Bool {
        guard let term = plan.terms.first(where: { $0.termCode == termCode }) else { return true }
        return term.courses.count >= DegreePlanMath.maxCoursesPerTerm
    }

    private var canAdd: Bool {
        !trimmed.isEmpty && !termIsFull && !DegreePlanMath.isPlanned(trimmed, in: plan)
    }

    @State private var suggestions: [DegreeSuggestion] = []

    /// Case-insensitive, spaces ignored on both sides, so "cis12" finds "CIS 1200".
    nonisolated static func matches(_ suggestion: DegreeSuggestion, query: String) -> Bool {
        let needle = query.lowercased().replacingOccurrences(of: " ", with: "")
        if needle.isEmpty { return true }
        let code = suggestion.course.code.lowercased().replacingOccurrences(of: " ", with: "")
        if code.contains(needle) { return true }
        let title = (suggestion.course.title ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        return title.contains(needle)
    }

    /// The muted line under a suggestion for one requirement it counts toward.
    nonisolated static func gainLine(_ gain: DegreeGain) -> String {
        let requirement = gain.requirement.lowercased()
        if gain.degreeLabel.isEmpty { return requirement }
        return "\(gain.degreeLabel) · \(requirement)"
    }

    private var filtered: [DegreeSuggestion] {
        if trimmed.isEmpty { return suggestions }
        return suggestions.filter { Self.matches($0, query: trimmed) }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(DegreePlanMath.termLabel(termCode))
                    .font(.lhfSerif(28))
                    .foregroundStyle(Color.smoothInk)
                    .accessibilityAddTraits(.isHeader)
                entryRow
                typedNote
                options
            }
            .task {
                suggestions = DegreeContribution.suggestions(
                    plan: plan, audits: audits, history: state.degree.history)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.smoothPaper.ignoresSafeArea())
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close") { dismiss() }
                }
            }
        }
        .environmentObject(state)
        .lhfSheetTheme()
#if os(iOS)
        .presentationDetents([.medium, .large])
#endif
    }

    // MARK: Typed entry

    private var entryRow: some View {
        HStack(spacing: 10) {
            TextField("course code", text: $typed)
                .font(.lhfSans(14))
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.smoothSurface.opacity(0.58), in: Capsule())
                .overlay { Capsule().stroke(Color.smoothRule.opacity(0.72), lineWidth: 1.25) }
                .onSubmit { addTyped() }
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif
            Text("\(DegreeProgressMath.credits(credits)) cu")
                .font(.lhfMono(12))
                .foregroundStyle(Color.smoothMuted)
                .fixedSize()
            Stepper(value: $credits, in: 0.5...4, step: 0.5) { EmptyView() }
                .labelsHidden()
                .accessibilityLabel("credits")
            Button { addTyped() } label: {
                Text("add")
                    .font(.lhfSans(14, weight: .semibold))
                    .foregroundStyle(canAdd ? Color.smoothInk : Color.smoothMuted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.smoothSurface, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
        }
    }

    private func addTyped() {
        guard canAdd else { return }
        state.addPlannedCourse(code: trimmed, title: nil, credits: credits, to: termCode)
        dismiss()
    }

    // MARK: Penn's open options

    /// What a typed code would do, so the student can still add anything but
    /// knows whether it moves the estimate. Two projections per degree: cheap
    /// enough for `body`.
    @ViewBuilder
    private var typedNote: some View {
        // Only once nothing in the list matches what was typed: a note under a
        // half-typed "cis" would call the prefix itself a course that counts
        // nowhere while the matches sit right below it. And with no audit read
        // there is nothing to judge a code against.
        if !trimmed.isEmpty, canAdd, !audits.isEmpty, filtered.isEmpty {
            let typedGains = DegreeContribution.gains(
                for: trimmed, credits: credits, plan: plan, audits: audits)
            if typedGains.isEmpty {
                Text("not on an open requirement")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.smoothMuted)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(typedGains.prefix(2).enumerated()), id: \.offset) { _, gain in
                        Text(Self.gainLine(gain))
                            .font(.lhfSans(12))
                            .foregroundStyle(Color.smoothCobaltInk)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var options: some View {
        let list = filtered
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("counts toward your degree")
                    .font(.lhfSans(13, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(list) { suggestion in
                            suggestionRow(suggestion)
                            Divider().overlay(Color.smoothRule.opacity(0.6))
                        }
                    }
                }
            }
        }
    }

    private func badge(_ suggestion: DegreeSuggestion, text: String) -> some View {
        let both = suggestion.gains.count >= 2
        return Text(text)
            .font(.lhfMono(11, weight: .semibold))
            .foregroundStyle(both ? Color.smoothInk : Color.smoothCobaltInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(both ? Color.smoothCobalt : Color.smoothCobalt.opacity(0.18), in: Capsule())
    }

    private func suggestionRow(_ suggestion: DegreeSuggestion) -> some View {
        Button { choose(suggestion.course) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(suggestion.course.code)
                        .font(.lhfMono(12))
                        .foregroundStyle(Color.smoothInk)
                    if let title = suggestion.course.title, !title.isEmpty {
                        Text(title.lowercased())
                            .font(.lhfSans(14))
                            .foregroundStyle(Color.smoothMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let value = suggestion.course.credits {
                        Text("\(DegreeProgressMath.credits(value)) cu")
                            .font(.lhfMono(11))
                            .foregroundStyle(Color.smoothMuted)
                    }
                    if let text = DegreeProgressMath.gainBadge(suggestion.points) {
                        badge(suggestion, text: text)
                    }
                }
                ForEach(Array(suggestion.gains.prefix(2).enumerated()), id: \.offset) { _, gain in
                    Text(Self.gainLine(gain))
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.smoothMuted)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(termIsFull)
    }

    private func choose(_ option: AdviceCourse) {
        guard !termIsFull else { return }
        state.addPlannedCourse(code: option.code, title: option.title, credits: option.credits ?? 1, to: termCode)
        dismiss()
    }
}
