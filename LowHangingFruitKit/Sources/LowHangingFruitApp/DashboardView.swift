import SwiftUI
import LowHangingFruitKit

// MARK: – Tab

private enum DashTab: String, CaseIterable, CustomStringConvertible {
    case dashboard   = "Dashboard"
    case later       = "Later"
    case assessments = "Assessments"

    var description: String { rawValue }
}

// MARK: – Section model

private struct DashSection: Identifiable {
    let id: String
    let label: String
    var items: [Assignment]
}

// MARK: – DashboardView

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    @State private var selectedTab: DashTab = .dashboard
    @State private var dueDateOverrides: [String: Date] = [:]
    @State private var editingAssignment: Assignment?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            tabBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    switch selectedTab {
                    case .dashboard:   dashboardContent
                    case .later:       laterContent
                    case .assessments: assessmentsContent
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .background(Color.lhfBg.ignoresSafeArea())
        .sheet(item: $editingAssignment) { assignment in
            EditDueSheet(
                assignment: assignment,
                overrideDate: Binding(
                    get: { dueDateOverrides[assignment.id] },
                    set: { dueDateOverrides[assignment.id] = $0 }
                )
            )
        }
    }

    private var tabBar: some View {
        SegmentedToggleView(
            options: DashTab.allCases,
            selection: $selectedTab,
            counts: [
                .dashboard:   state.assignments.count,
                .later:       state.laterAssignments.count,
                .assessments: state.assessments.count,
            ]
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Tab content

    @ViewBuilder
    private var dashboardContent: some View {
        if state.assignments.isEmpty {
            emptyState(
                systemImage: "leaf.fill",
                title: "go touch grass",
                message: "Nothing due in the next week."
            )
        } else {
            activeSections
                .padding(.top, 16)
        }
    }

    @ViewBuilder
    private var laterContent: some View {
        if state.laterAssignments.isEmpty {
            emptyState(
                title: "Nothing later",
                message: "Assignments due more than a week out — and ones with no due date — show up here."
            )
        } else {
            datedSections(
                from: state.laterAssignments,
                datedLabel: "UPCOMING",
                undatedLabel: "NO DUE DATE"
            )
            .padding(.top, 16)
        }
    }

    @ViewBuilder
    private var assessmentsContent: some View {
        if state.assessments.isEmpty {
            emptyState(
                systemImage: "graduationcap.fill",
                title: "No assessments",
                message: "Quizzes, midterms, and exams show up here."
            )
        } else {
            datedSections(
                from: state.assessments,
                datedLabel: "SCHEDULED",
                undatedLabel: "NO DUE DATE"
            )
            .padding(.top, 16)
        }
    }

    private func datedSections(from items: [Assignment], datedLabel: String, undatedLabel: String) -> some View {
        let dated = items.filter { $0.dueAt != nil }
        let undated = items.filter { $0.dueAt == nil }
        return VStack(alignment: .leading, spacing: 20) {
            if !dated.isEmpty   { cardSection(label: datedLabel,   items: dated) }
            if !undated.isEmpty { cardSection(label: undatedLabel, items: undated) }
        }
    }

    private func cardSection(label: String, items: [Assignment]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.geist(11, weight: .semibold))
                .foregroundStyle(Color.lhfGraphite.opacity(0.45))
                .padding(.horizontal, 16)

            ForEach(items) { assignment in
                AssignmentCardView(
                    assignment: assignment,
                    isCompleted: false,
                    dueDateOverride: dueDateOverrides[assignment.id],
                    onToggleCompleted: { state.markCompleted(assignment) },
                    onEditDue: { editingAssignment = assignment }
                )
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("LHF")
                    .font(.instrumentSerif(28))
                    .foregroundStyle(Color.lhfGraphite)
                Text("Low Hanging Fruit")
                    .font(.geist(11))
                    .foregroundStyle(Color.lhfGraphite.opacity(0.5))
            }
            Spacer()
            syncIndicators
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var syncIndicators: some View {
        HStack(spacing: 10) {
            if state.isLoading || state.isGradescopeLoading || state.isCanvasDiscoveryLoading {
                ProgressView().controlSize(.small)
            }
            if let err = state.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(err)
            }
        }
    }

    // MARK: Active sections

    private var activeSections: some View {
        let sections = buildSections(from: state.assignments, now: Date())
        return ForEach(sections) { section in
            VStack(alignment: .leading, spacing: 10) {
                Text(section.label)
                    .font(.geist(11, weight: .semibold))
                    .foregroundStyle(Color.lhfGraphite.opacity(0.45))
                    .padding(.horizontal, 16)

                ForEach(section.items) { assignment in
                    AssignmentCardView(
                        assignment: assignment,
                        isCompleted: false,
                        dueDateOverride: dueDateOverrides[assignment.id],
                        onToggleCompleted: {
                            state.markCompleted(assignment)
                        },
                        onEditDue: {
                            editingAssignment = assignment
                        }
                    )
                    .padding(.horizontal, 16)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal:   .opacity.combined(with: .offset(y: -8))
                    ))
                }
            }
            .padding(.bottom, 20)
        }
    }

    // MARK: Empty state

    private func emptyState(systemImage: String = "tray", title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(Color.lhfGraphite.opacity(0.25))
            Text(title)
                .font(.geist(15, weight: .semibold))
                .foregroundStyle(Color.lhfGraphite.opacity(0.5))
            Text(message)
                .font(.geist(13))
                .foregroundStyle(Color.lhfGraphite.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
        .padding(.horizontal, 40)
    }

    // MARK: Section builder

    private func buildSections(from items: [Assignment], now: Date) -> [DashSection] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let tomorrowStart = cal.date(byAdding: .day, value: 1, to: todayStart)!
        let dayAfterTomorrow = cal.date(byAdding: .day, value: 2, to: todayStart)!
        let weekEnd = cal.date(byAdding: .day, value: 7, to: todayStart)!

        var past:     [Assignment] = []
        var today:    [Assignment] = []
        var tomorrow: [Assignment] = []
        var thisWeek: [Assignment] = []
        var later:    [Assignment] = []

        for item in items {
            let due = dueDateOverrides[item.id] ?? item.dueAt
            guard let due else { later.append(item); continue }
            if due < now {
                past.append(item)
            } else if due < tomorrowStart {
                today.append(item)
            } else if due < dayAfterTomorrow {
                tomorrow.append(item)
            } else if due < weekEnd {
                thisWeek.append(item)
            } else {
                later.append(item)
            }
        }

        var sections: [DashSection] = []
        if !past.isEmpty     { sections.append(.init(id: "past",     label: "PAST DUE",   items: past)) }
        if !today.isEmpty    { sections.append(.init(id: "today",    label: "TODAY",      items: today)) }
        if !tomorrow.isEmpty { sections.append(.init(id: "tomorrow", label: "TOMORROW",   items: tomorrow)) }
        if !thisWeek.isEmpty { sections.append(.init(id: "week",     label: "THIS WEEK",  items: thisWeek)) }
        if !later.isEmpty    { sections.append(.init(id: "later",    label: "LATER",      items: later)) }
        return sections
    }
}
