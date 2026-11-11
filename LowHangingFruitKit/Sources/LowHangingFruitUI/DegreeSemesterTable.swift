import SwiftUI
import LowHangingFruitKit

/// Every semester side by side, scrolling sideways, in all three tabs of the
/// degree screen: the ones behind the student (fixed chips), the one they are
/// in ("· now"), and the ones ahead, where Penn's registered courses are fixed
/// and the student's own sketch is removable, draggable and added to.
///
/// One view, hosted by the progress and what-if tabs (under the ring) and by
/// the plan tab, so the table is written once. It is handed the audit its host
/// is drawing: in a what-if that is the what-if program's audit, so the
/// "fits" line is read against what the student is looking at. The add sheet is
/// presented from here for the same reason: it has to work wherever the table
/// sits.
///
/// Dragging carries the planned course's normalised code as a plain string. A
/// drop on a future column's card moves the course to the end of that
/// semester; a drop on a planned row puts it before that row. Past and
/// current columns accept nothing and their chips are not draggable. The
/// rules, including every refusal, are `DegreePlanMath.moving`; the view only
/// reports whether the plan changed.
struct DegreeSemesterTable: View {
    @EnvironmentObject var state: AppState

    let audit: DegreeAudit?

    @State private var sheetTarget: PlanSheetTarget?
    @State private var targetedTerm: String?

    private static let columnWidth: CGFloat = 168

    private var plan: DegreePlan { state.degreePlan }

    var body: some View {
        let columns = DegreeTimeline.columns(
            history: state.degree.history, plan: plan, audit: audit, now: Date())
        let coverage = DegreePlanMath.coverage(plan: plan, audit: audit)
        return table(columns, coverage: coverage)
            .sheet(item: $sheetTarget) { target in
                DegreePlanAddSheet(termCode: target.termCode, audit: audit)
                    .environmentObject(state)
            }
    }

    // MARK: Table

    private func table(_ columns: [TimelineColumn], coverage: [String: String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(columns) { column in
                        columnView(column, coverage: coverage)
                            .id(column.termCode)
                    }
                    addTermButton
                }
            }
            .onAppear {
                // Opens on the current semester (else the first one ahead), so
                // the past does not push the part the student edits off screen.
                if let id = DegreeTimeline.leadingColumnID(columns) {
                    proxy.scrollTo(id, anchor: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func columnView(_ column: TimelineColumn, coverage: [String: String]) -> some View {
        if column.kind == .future {
            card(column, coverage: coverage)
                .dropDestination(for: String.self) { items, _ in
                    drop(items, to: column.termCode, before: nil)
                } isTargeted: { targeted in
                    if targeted {
                        targetedTerm = column.termCode
                    } else if targetedTerm == column.termCode {
                        targetedTerm = nil
                    }
                }
        } else {
            card(column, coverage: coverage)
        }
    }

    private func card(_ column: TimelineColumn, coverage: [String: String]) -> some View {
        let isTargeted = targetedTerm == column.termCode
        return VStack(alignment: .leading, spacing: 10) {
            header(column)
            ForEach(column.taken) { course in
                takenRow(course, kind: column.kind)
            }
            ForEach(column.planned) { course in
                plannedRow(course, termCode: column.termCode,
                           fit: coverage[DegreePlanMath.normalizedCode(course.code)])
            }
            if column.kind == .future {
                addCourseButton(column)
            }
        }
        .padding(12)
        .frame(width: Self.columnWidth, alignment: .topLeading)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isTargeted ? Color.smoothTeal : Color.smoothRule, lineWidth: isTargeted ? 2 : 1)
        }
    }

    private func header(_ column: TimelineColumn) -> some View {
        let planTerm = plan.terms.last
        let canRemove = column.kind == .future
            && planTerm?.termCode == column.termCode
            && (planTerm?.courses.isEmpty ?? false)
            && column.taken.isEmpty
            && plan.terms.count > 1
        let credits = DegreeTimeline.credits(column)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(DegreePlanMath.termLabel(column.termCode))
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

    /// Nothing after a past course; "· now" for the semester in progress (the
    /// mark the progress tab's chips use); "· registered" for one ahead.
    private func suffix(for kind: TimelineColumn.Kind) -> String? {
        switch kind {
        case .past: return nil
        case .current: return "· now"
        case .future: return "· registered"
        }
    }

    private func takenLabel(_ course: TimelineCourse, kind: TimelineColumn.Kind) -> String {
        var parts = [course.code]
        if let credits = course.credits { parts.append(creditsWord(credits)) }
        switch kind {
        case .past: break
        case .current: parts.append("in progress")
        case .future: parts.append("registered")
        }
        return parts.joined(separator: ", ")
    }

    private func takenRow(_ course: TimelineCourse, kind: TimelineColumn.Kind) -> some View {
        HStack(spacing: 6) {
            chip(code: course.code, label: takenLabel(course, kind: kind))
            if let word = suffix(for: kind) {
                Text(word)
                    .font(.lhfSans(10))
                    .foregroundStyle(Color.smoothMuted)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
    }

    private func plannedRow(_ course: PlannedCourse, termCode: String, fit: String?) -> some View {
        let code = DegreePlanMath.normalizedCode(course.code)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                chip(code: course.code, label: "\(course.code), \(creditsWord(course.credits))")
                    .draggable(code)
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
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            drop(items, to: termCode, before: code)
        }
    }

    private func addCourseButton(_ column: TimelineColumn) -> some View {
        Button { sheetTarget = PlanSheetTarget(termCode: column.termCode) } label: {
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

    // MARK: Drop

    /// True only when the plan changed, so SwiftUI shows a refused drop (a full
    /// semester, a course dropped on itself, a string that is not planned) as
    /// one.
    private func drop(_ items: [String], to termCode: String, before anchor: String?) -> Bool {
        guard let code = items.first else { return false }
        let before = state.degreePlan
        state.movePlannedCourse(code: code, to: termCode, before: anchor)
        return state.degreePlan != before
    }
}
