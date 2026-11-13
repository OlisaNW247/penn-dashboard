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
/// "fits" lines and the badge beside a planned course are read against what the
/// student is looking at. They come from `DegreeContribution.planned`, the model
/// behind the ring's planned arc, so a line and the arc cannot disagree. The add sheet is
/// presented from here for the same reason: it has to work wherever the table
/// sits.
///
/// Dragging carries the planned course's normalised code as a plain string. A
/// drop on a future column's card moves the course to the end of that
/// semester; a drop on a planned row puts it before that row. Past and
/// current columns accept nothing and their chips are not draggable. The
/// rules, including every refusal, are `DegreePlanMath.moving`; the view only
/// reports whether the plan changed.
///
/// Two layouts of the same cards. `.strip` is the sideways scroll above, with a
/// "full view" button that opens `DegreeSemesterPage`; `.page` lays every
/// semester out in rows so the whole degree is on one screen. The page is
/// built from plain rows of equal-width cells and `ViewThatFits`, trying the
/// fewest columns first (widest cells) and moving to more columns until the
/// height fits, then scrolling vertically as a last resort. A `LazyVGrid` is
/// the tempting choice and the wrong one: it does not report an honest size to
/// `ViewThatFits`, so nothing would ever be measured. Shrinking the type until
/// everything fits is the other tempting fix and would make course codes
/// unreadable, so the cell width has a floor
/// (`DegreeTimeline.minimumPageCellWidth`) and scrolling is the answer below it.
/// Both layouts share `columnView`, `plannedRow` and `drop`, so drag, remove and
/// add behave the same in each.
struct DegreeSemesterTable: View {
    enum Layout { case strip, page }

    @EnvironmentObject var state: AppState

    let audits: [DegreeLabeledAudit]
    let layout: Layout

    init(audits: [DegreeLabeledAudit], layout: Layout = .strip) {
        self.audits = audits
        self.layout = layout
    }

    /// One audit, or none: the single-degree screen's form.
    init(audit: DegreeAudit?, layout: Layout = .strip) {
        var wrapped: [DegreeLabeledAudit] = []
        if let audit {
            wrapped.append(DegreeLabeledAudit(degreeID: "current", label: "", audit: audit))
        }
        self.init(audits: wrapped, layout: layout)
    }

    /// The audit `DegreeTimeline.columns` looks courses up in. The timeline
    /// only reads courses for credits and titles, and a dual-degree student's
    /// courses are spread over two audits, so with several the first audit is
    /// copied with every audit's courses merged into it.
    private var lookupAudit: DegreeAudit? {
        guard let first = audits.first?.audit else { return nil }
        if audits.count == 1 { return first }
        return DegreeAudit(
            goals: first.goals, isWhatIf: first.isWhatIf, percentComplete: first.percentComplete,
            degreeLabel: first.degreeLabel, catalogYearLabel: first.catalogYearLabel,
            blocks: first.blocks, courses: DegreeOverall.mergedCourses(audits),
            fetchedAt: first.fetchedAt)
    }

    /// The muted line under a planned course for one requirement it counts
    /// toward (a requirement that still has room, per the contribution model).
    nonisolated static func fitLine(_ fit: DegreePlanFit) -> String {
        let requirement = fit.requirement.lowercased()
        if fit.degreeLabel.isEmpty { return "fits · \(requirement)" }
        return "fits · \(fit.degreeLabel) · \(requirement)"
    }

    @State private var sheetTarget: PlanSheetTarget?
    @State private var targetedTerm: String?
    @State private var showPage = false

    private var isPage: Bool { layout == .page }

    private static let columnWidth: CGFloat = 168

    private var plan: DegreePlan { state.degreePlan }

    var body: some View {
        let columns = DegreeTimeline.columns(
            history: state.degree.history, plan: plan, audit: lookupAudit, now: Date())
        let coverage = DegreeContribution.planned(plan: plan, audits: audits)
        return Group {
            if isPage {
                pageTable(columns, coverage: coverage)
            } else {
                stripWithButton(columns, coverage: coverage)
            }
        }
            .sheet(item: $sheetTarget) { target in
                DegreePlanAddSheet(termCode: target.termCode, audits: audits)
                    .environmentObject(state)
            }
    }

    // MARK: Table

    private func stripWithButton(_ columns: [TimelineColumn], coverage: [String: [DegreeGain]]) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button { showPage = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                    Text("full view")
                }
                .font(.lhfSans(12, weight: .semibold))
                .foregroundStyle(Color.smoothMuted)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("full view")
            table(columns, coverage: coverage)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showPage) {
            DegreeSemesterPage(audits: audits)
                .environmentObject(state)
                .lhfSheetTheme()
        }
        #else
        .sheet(isPresented: $showPage) {
            DegreeSemesterPage(audits: audits)
                .environmentObject(state)
                .lhfSheetTheme()
        }
        #endif
    }

    // MARK: Page

    private func pageTable(_ columns: [TimelineColumn], coverage: [String: [DegreeGain]]) -> some View {
        GeometryReader { geo in
            let cells = columns.count + 1
            let counts = DegreeTimeline.pageColumnCounts(width: Double(geo.size.width), cells: cells)
            pageFit(counts[...], widest: counts[0], columns: columns, coverage: coverage)
        }
    }

    /// Each count in turn, fewest columns first; the last resort is the
    /// widest-cell grid inside a vertical scroll. Nested rather than a loop
    /// because `ViewThatFits` takes its candidates as a view builder.
    private func pageFit(
        _ counts: ArraySlice<Int>, widest: Int,
        columns: [TimelineColumn], coverage: [String: [DegreeGain]]
    ) -> AnyView {
        guard let first = counts.first else {
            return AnyView(ScrollView(.vertical, showsIndicators: false) {
                pageGrid(perRow: widest, columns: columns, coverage: coverage)
            })
        }
        return AnyView(ViewThatFits(in: .vertical) {
            pageGrid(perRow: first, columns: columns, coverage: coverage)
            pageFit(counts.dropFirst(), widest: widest, columns: columns, coverage: coverage)
        })
    }

    private func pageGrid(perRow: Int, columns: [TimelineColumn], coverage: [String: [DegreeGain]]) -> some View {
        var cells: [PageCell] = columns.map { PageCell.column($0) }
        cells.append(.addSemester)
        let rows = DegreeTimeline.rows(cells, perRow: perRow)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(row) { cell in
                        pageCell(cell, coverage: coverage)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    // Invisible cells keep a short last row at the same cell
                    // width. Zero height on purpose: an unsized `Color.clear`
                    // expands vertically and would stretch the row.
                    ForEach(0..<max(perRow - row.count, 0), id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func pageCell(_ cell: PageCell, coverage: [String: [DegreeGain]]) -> some View {
        switch cell {
        case .column(let column): columnView(column, coverage: coverage)
        case .addSemester: addTermButton
        }
    }

    private enum PageCell: Identifiable {
        case column(TimelineColumn)
        case addSemester

        var id: String {
            switch self {
            case .column(let column): return column.termCode
            case .addSemester: return "add-semester"
            }
        }
    }

    private func table(_ columns: [TimelineColumn], coverage: [String: [DegreeGain]]) -> some View {
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
    private func columnView(_ column: TimelineColumn, coverage: [String: [DegreeGain]]) -> some View {
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

    private func card(_ column: TimelineColumn, coverage: [String: [DegreeGain]]) -> some View {
        let isTargeted = targetedTerm == column.termCode
        return VStack(alignment: .leading, spacing: isPage ? 6 : 10) {
            header(column)
            ForEach(column.taken) { course in
                takenRow(course, kind: column.kind)
            }
            ForEach(column.planned) { course in
                plannedRow(course, termCode: column.termCode,
                           gains: coverage[DegreePlanMath.normalizedCode(course.code)] ?? [])
            }
            if column.kind == .future {
                addCourseButton(column)
            }
        }
        .padding(isPage ? 10 : 12)
        .modifier(CardWidth(fixed: isPage ? nil : Self.columnWidth))
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
                if isPage, column.kind == .current {
                    Text("now")
                        .font(.lhfSans(10, weight: .semibold))
                        .foregroundStyle(Color.smoothTealInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.smoothTeal.opacity(0.22), in: Capsule())
                }
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

    private func chip(code: String, label: String, muted: Bool = false) -> some View {
        Text(code)
            .font(.lhfMono(11))
            .foregroundStyle(muted ? Color.smoothMuted : courseAccentInk(for: code))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(muted ? Color.smoothRule.opacity(0.5) : courseAccent(for: code).opacity(0.28), in: Capsule())
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
            if !isPage, let word = suffix(for: kind) {
                Text(word)
                    .font(.lhfSans(10))
                    .foregroundStyle(Color.smoothMuted)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
    }

    /// A planned course. When the contribution model lays it against a
    /// requirement that still has room, the chip keeps its class colour, the
    /// estimate it adds is shown beside it and one "fits" line per requirement
    /// sits under it. When it counts nowhere the chip is muted and one line says
    /// so. The lines come from the same model as the ring's planned arc, so the
    /// line and the arc cannot disagree.
    private func plannedRow(_ course: PlannedCourse, termCode: String, gains: [DegreeGain]) -> some View {
        let code = DegreePlanMath.normalizedCode(course.code)
        let counts = !gains.isEmpty
        // With no audit read yet there is nothing to judge a course against, and
        // muting every planned course then would read as "none of this counts".
        let judged = !audits.isEmpty
        let total = gains.reduce(0) { $0 + $1.points }
        let countsWord = counts ? ", counts toward your degree" : (judged ? ", not on an open requirement" : "")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                chip(code: course.code,
                     label: "\(course.code), \(creditsWord(course.credits))\(countsWord)",
                     muted: judged && !counts)
                    .draggable(code)
                if counts, let badge = DegreeProgressMath.gainBadge(total) {
                    Text(badge)
                        .font(.lhfMono(10, weight: .semibold))
                        .foregroundStyle(Color.smoothCobaltInk)
                        .lineLimit(1)
                }
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
            if counts {
                ForEach(Array(gains.prefix(2).enumerated()), id: \.offset) { _, gain in
                    Text(Self.fitLine(DegreePlanFit(degreeLabel: gain.degreeLabel, requirement: gain.requirement)))
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.smoothMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("not on an open requirement")
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
                .frame(width: isPage ? nil : 96, height: 56)
                .frame(maxWidth: isPage ? CGFloat.infinity : nil)
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

/// A fixed width in the strip, the cell's own flexible width in the page. A
/// modifier because `frame(width:)` has no "none" and the two branches would
/// otherwise differ in view type.
private struct CardWidth: ViewModifier {
    let fixed: CGFloat?

    func body(content: Content) -> some View {
        if let fixed {
            content.frame(width: fixed, alignment: .topLeading)
        } else {
            content.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// The full-screen view of the semester table: every semester on one page, in
/// rows. Opened from the strip's "full view" button.
struct DegreeSemesterPage: View {
    @Environment(\.dismiss) private var dismiss

    let audits: [DegreeLabeledAudit]

    init(audits: [DegreeLabeledAudit]) {
        self.audits = audits
    }

    init(audit: DegreeAudit?) {
        var wrapped: [DegreeLabeledAudit] = []
        if let audit {
            wrapped.append(DegreeLabeledAudit(degreeID: "current", label: "", audit: audit))
        }
        self.audits = wrapped
    }

    var body: some View {
        ZStack {
            Color.smoothPaper.ignoresSafeArea()
            VStack(spacing: 8) {
                HStack {
                    Text("semesters")
                        .font(.lhfSerif(28))
                        .foregroundStyle(Color.smoothInk)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.smoothInk)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("close")
                }
                DegreeSemesterTable(audits: audits, layout: .page)
            }
            .padding(.horizontal, 16)
        }
    }
}
