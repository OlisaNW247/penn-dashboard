import SwiftUI
import LowHangingFruitKit

/// The degree screen's "plan" tab: one column per semester, side by side, that
/// the student fills with a sample course load. It is their sketch and nothing
/// else. The audit only contributes two things, laid beside the table and never
/// merged into it: the courses Penn already shows as registered for a term (fixed
/// chips), and a muted "fits" line under a planned course that Penn lists among
/// the options of a requirement it still has open. The screen never says a
/// requirement is satisfied by a plan, and never orders or suggests a course:
/// whether a course counts is Penn's decision when it is taken.
///
/// Reads `state.degreePlan` and `state.degree.current`; edits go through
/// `AppState+Degree.swift`, which saves them on the phone and nowhere else.
struct DegreePlanView: View {
    @EnvironmentObject var state: AppState

    @State private var sheetTarget: PlanSheetTarget?

    private static let columnWidth: CGFloat = 168

    private var audit: DegreeAudit? { state.degree.current }
    private var plan: DegreePlan { state.degreePlan }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            table
        }
        .sheet(item: $sheetTarget) { target in
            DegreePlanAddSheet(termCode: target.termCode)
                .environmentObject(state)
        }
    }

    // MARK: Summary

    private var summaryText: String? {
        let total = DegreePlanMath.totalPlannedCredits(plan)
        guard total > 0 else { return nil }
        var text = "\(DegreeProgressMath.credits(total)) cu planned"
        let counts = DegreePlanMath.coveredCount(plan: plan, audit: audit)
        if counts.open > 0 {
            text += " · \(counts.covered) of \(counts.open) open requirements have a planned course"
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

    // MARK: Table

    private var table: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(plan.terms) { term in
                    column(term)
                }
                addTermButton
            }
        }
    }

    private func column(_ term: PlannedTerm) -> some View {
        let coverage = DegreePlanMath.coverage(plan: plan, audit: audit)
        return VStack(alignment: .leading, spacing: 10) {
            header(term)
            ForEach(DegreePlanMath.registered(in: term.termCode, audit: audit)) { course in
                registeredRow(course)
            }
            ForEach(term.courses) { course in
                plannedRow(course, termCode: term.termCode,
                           fit: coverage[DegreePlanMath.normalizedCode(course.code)])
            }
            addCourseButton(term)
        }
        .padding(12)
        .frame(width: Self.columnWidth, alignment: .topLeading)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.smoothRule, lineWidth: 1) }
    }

    private func header(_ term: PlannedTerm) -> some View {
        let isLast = term.id == plan.terms.last?.id
        let canRemove = isLast && term.courses.isEmpty && plan.terms.count > 1
        let credits = DegreePlanMath.termCredits(term, audit: audit)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(DegreePlanMath.termLabel(term.termCode))
                    .font(.lhfSans(14, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if canRemove {
                    Button { state.removeLastPlanTermIfEmpty() } label: {
                        Text("remove")
                            .font(.lhfSans(11))
                            .foregroundStyle(Color.smoothMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("\(DegreeProgressMath.credits(credits)) cu")
                .font(.lhfMono(12))
                .foregroundStyle(Color.smoothMuted)
        }
    }

    // MARK: Rows

    private func chip(code: String, label: String) -> some View {
        Text(code)
            .font(.lhfMono(11))
            .foregroundStyle(courseAccentInk(for: code))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(courseAccent(for: code).opacity(0.28), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }

    private func creditsWord(_ value: Double) -> String {
        "\(DegreeProgressMath.credits(value)) credits"
    }

    private func registeredRow(_ course: AuditCourse) -> some View {
        HStack(spacing: 6) {
            chip(code: course.code,
                 label: "\(course.code), \(creditsWord(course.credits ?? 0)), registered")
            Text("· registered")
                .font(.lhfSans(10))
                .foregroundStyle(Color.smoothMuted)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
    }

    private func plannedRow(_ course: PlannedCourse, termCode: String, fit: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                chip(code: course.code, label: "\(course.code), \(creditsWord(course.credits))")
                Spacer(minLength: 0)
                Button { state.removePlannedCourse(code: course.code, from: termCode) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.smoothMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("remove \(course.code)")
            }
            if let fit {
                Text("fits · \(fit.lowercased())")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.smoothMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addCourseButton(_ term: PlannedTerm) -> some View {
        Button { sheetTarget = PlanSheetTarget(termCode: term.termCode) } label: {
            Text("+ course")
                .font(.lhfSans(13, weight: .semibold))
                .foregroundStyle(Color.smoothTealInk)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addTermButton: some View {
        Button { state.addPlanTerm() } label: {
            Text("+ semester")
                .font(.lhfSans(13, weight: .semibold))
                .foregroundStyle(Color.smoothInk)
                .frame(width: 96, height: 56)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.smoothRule, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(plan.terms.count >= DegreePlanMath.maxTerms)
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

    @State private var typed = ""
    @State private var credits = 1.0

    private var audit: DegreeAudit? { state.degree.current }
    private var plan: DegreePlan { state.degreePlan }

    private var trimmed: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var termIsFull: Bool {
        guard let term = plan.terms.first(where: { $0.termCode == termCode }) else { return true }
        return term.courses.count >= DegreePlanMath.maxCoursesPerTerm
    }

    private var canAdd: Bool {
        !trimmed.isEmpty && !termIsFull && !DegreePlanMath.isPlanned(trimmed, in: plan)
    }

    private var requirements: [DegreePlanMath.OpenRequirement] {
        DegreePlanMath.addable(DegreePlanMath.openRequirements(in: audit), plan: plan, audit: audit)
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
        let list = requirements
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("still open on your audit")
                    .font(.lhfSans(13, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(list) { requirement in
                            section(requirement)
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
