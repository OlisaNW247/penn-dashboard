import SwiftUI
import LowHangingFruitKit

/// One semester of the road, opened by a tap on its row: the courses Penn
/// holds for it (fixed rows), then the student's own planned ones, each with a
/// menu to move it to another future semester or remove it. A menu rather than
/// a drag, so every edit has a tap path. "+ course" opens the add sheet from
/// here, because a sheet cannot present over another presenter's sheet.
///
/// The "fits" lines come from `DegreeContribution.planned`, the model behind
/// the road's planned layer, so a line here and a bar there cannot disagree;
/// the engine's own lines and the approval tag are the table's
/// (`DegreeSemesterTable.engineLines` and `.approvalTag`).
struct DegreeSemesterSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let termCode: String

    @State private var addTarget: PlanSheetTarget?

    /// The audit `DegreeTimeline.columns` looks courses up in. A dual-degree
    /// student's courses are spread over two audits, so with several the first
    /// is copied with every audit's courses merged into it.
    private var lookupAudit: DegreeAudit? {
        let audits = state.degreeAudits
        guard let first = audits.first?.audit else { return state.degree.current }
        if audits.count == 1 { return first }
        return DegreeAudit(
            goals: first.goals, isWhatIf: first.isWhatIf, percentComplete: first.percentComplete,
            degreeLabel: first.degreeLabel, catalogYearLabel: first.catalogYearLabel,
            blocks: first.blocks, courses: DegreeOverall.mergedCourses(audits),
            fetchedAt: first.fetchedAt)
    }

    private var columns: [TimelineColumn] {
        DegreeTimeline.columns(
            history: state.degree.history, plan: state.degreePlan, audit: lookupAudit, now: Date())
    }

    var body: some View {
        let all = columns
        let column = all.first { $0.termCode == termCode }
            ?? TimelineColumn(termCode: termCode, kind: .future, taken: [], planned: [])
        let others = all.filter { $0.kind == .future && $0.termCode != termCode }.map(\.termCode)
        let coverage = DegreeContribution.planned(plan: state.degreePlan, audits: state.degreeAudits)
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(DegreePlanMath.termLabel(termCode)) · \(stateWord(column))")
                        .font(.lhfSerif(28))
                        .foregroundStyle(Color.smoothInk)
                        .accessibilityAddTraits(.isHeader)
                    creditsLine(column)
                    if column.taken.isEmpty && column.planned.isEmpty {
                        Text(column.kind == .future ? "nothing planned yet" : "no classes")
                            .font(.lhfSans(14))
                            .foregroundStyle(Color.smoothMuted)
                    }
                    ForEach(column.taken) { course in
                        takenRow(course)
                    }
                    ForEach(column.planned) { course in
                        plannedRow(course, others: others,
                                   gains: coverage[DegreePlanMath.normalizedCode(course.code)] ?? [])
                    }
                    if column.kind == .future {
                        Button { addTarget = PlanSheetTarget(termCode: termCode) } label: {
                            Text("+ course")
                                .font(.lhfSans(14, weight: .semibold))
                                .foregroundStyle(Color.smoothTealInk)
                                .frame(minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
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
        .sheet(item: $addTarget) { target in
            DegreePlanAddSheet(termCode: target.termCode, audits: state.degreeAudits)
                .environmentObject(state)
        }
        .environmentObject(state)
        .lhfSheetTheme()
    }

    // MARK: Pieces

    /// The same words the road uses for a term's state.
    private func stateWord(_ column: TimelineColumn) -> String {
        switch column.kind {
        case .past: return "done"
        case .current: return DegreeRoad.stateWord(.now)
        case .future:
            if !column.taken.isEmpty { return DegreeRoad.stateWord(.registered) }
            return column.planned.isEmpty ? DegreeRoad.stateWord(.empty) : DegreeRoad.stateWord(.planned)
        }
    }

    @ViewBuilder
    private func creditsLine(_ column: TimelineColumn) -> some View {
        let credits = DegreeTimeline.credits(column)
        if credits > 0 {
            let over = DegreeSemesterTable.loadIsOver(column)
            Text("\(DegreeProgressMath.credits(credits)) cu")
                .font(.lhfMono(13))
                .foregroundStyle(over ? Color.smoothTomatoInk : Color.smoothMuted)
                .accessibilityValue(over ? "over the limit" : "")
        }
    }

    private func codeText(_ code: String) -> some View {
        Text(code)
            .font(.lhfMono(13))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(courseAccentInk(for: code))
    }

    private func takenRow(_ course: TimelineCourse) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            codeText(course.code)
            if let title = course.title, !title.isEmpty {
                Text(title.lowercased())
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.smoothMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func plannedRow(_ course: PlannedCourse, others: [String], gains: [DegreeGain]) -> some View {
        let engineLines = DegreeSemesterTable.engineLines(course)
        let lines = engineLines.isEmpty ? DegreeSemesterTable.fitLines(gains) : engineLines
        let tag = DegreeSemesterTable.approvalTag(course.approval)
        let pickLabel = course.pickLabel.flatMap { $0.isEmpty ? nil : $0 }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                codeText(course.code)
                if let title = course.title, !title.isEmpty {
                    Text(title.lowercased())
                        .font(.lhfSans(13))
                        .foregroundStyle(Color.smoothMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Menu {
                    if !others.isEmpty {
                        Menu("move to") {
                            ForEach(others, id: \.self) { target in
                                Button(DegreePlanMath.termLabel(target)) {
                                    state.movePlannedCourse(code: course.code, to: target, before: nil)
                                }
                            }
                        }
                    }
                    Button("remove", role: .destructive) {
                        state.removePlannedCourse(code: course.code, from: termCode)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.smoothMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("options for \(course.code)")
            }
            if let tag {
                Text(tag)
                    .font(.lhfSans(10, weight: .semibold))
                    .foregroundStyle(Color.smoothGrapeInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.smoothGrape.opacity(0.22), in: Capsule())
            }
            if !lines.isEmpty {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.lhfSans(12))
                        .foregroundStyle(Color.smoothMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let pickLabel {
                Text("your pick · \(pickLabel)")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.smoothInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.smoothRule.opacity(0.72), lineWidth: 1)
        }
    }
}
