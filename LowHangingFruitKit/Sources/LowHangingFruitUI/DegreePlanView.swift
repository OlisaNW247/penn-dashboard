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

/// The add sheet: type any course code, or tap one of the options Penn's own
/// audit lists for a requirement it still has open. The list is Penn's, in
/// Penn's order; the only thing removed from it is what the plan or the audit
/// already holds. Nothing here ranks, filters or recommends.
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

    private struct OptionGroup: Identifiable {
        let id: String
        let label: String
        let requirements: [DegreePlanMath.OpenRequirement]
    }

    /// One group per audit with something addable; empty groups are skipped.
    private var groups: [OptionGroup] {
        var out: [OptionGroup] = []
        for group in DegreeOverall.openGroups(audits) {
            let audit = audits.first { $0.degreeID == group.degreeID }?.audit
            let addable = DegreePlanMath.addable(group.requirements, plan: plan, audit: audit,
                                                 history: state.degree.history)
            if !addable.isEmpty {
                out.append(OptionGroup(id: group.degreeID, label: group.label, requirements: addable))
            }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(DegreePlanMath.termLabel(termCode))
                    .font(.lhfSerif(28))
                    .foregroundStyle(Color.smoothInk)
                    .accessibilityAddTraits(.isHeader)
                entryRow
                options
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

    @ViewBuilder
    private var options: some View {
        let list = groups
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("still open on your audit")
                    .font(.lhfSans(13, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(list) { group in
                            if list.count > 1 {
                                Text(group.label)
                                    .font(.lhfSans(12, weight: .semibold))
                                    .foregroundStyle(Color.smoothMuted)
                            }
                            ForEach(group.requirements) { requirement in
                                section(requirement)
                            }
                        }
                    }
                }
            }
        }
    }

    private func section(_ requirement: DegreePlanMath.OpenRequirement) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(requirement.label.lowercased())
                .font(.lhfMono(11))
                .foregroundStyle(Color.smoothMuted)
                .padding(.bottom, 4)
            ForEach(Array(requirement.options.enumerated()), id: \.offset) { _, option in
                optionRow(option)
                Divider().overlay(Color.smoothRule.opacity(0.6))
            }
        }
    }

    private func optionRow(_ option: AdviceCourse) -> some View {
        Button { choose(option) } label: {
            HStack(spacing: 8) {
                Text(option.code)
                    .font(.lhfMono(12))
                    .foregroundStyle(Color.smoothInk)
                if let title = option.title, !title.isEmpty {
                    Text(title.lowercased())
                        .font(.lhfSans(14))
                        .foregroundStyle(Color.smoothMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let value = option.credits {
                    Text("\(DegreeProgressMath.credits(value)) cu")
                        .font(.lhfMono(11))
                        .foregroundStyle(Color.smoothMuted)
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
