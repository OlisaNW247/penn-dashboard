import SwiftUI
import PennDashboardKit

// MARK: – Tab

enum DashTab: String, CaseIterable, CustomStringConvertible {
    case active    = "Active"
    case completed = "Completed"
    case other     = "Other"

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

    @State private var selectedTab: DashTab = .active
    @State private var dueDateOverrides: [String: Date] = [:]
    @State private var editingAssignment: Assignment?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    tabBar
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    if selectedTab == .active {
                        activeSections
                    } else if selectedTab == .completed {
                        completedSection
                    } else {
                        otherSection
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

    // MARK: Tab bar

    private var tabBar: some View {
        SegmentedToggleView(
            options: DashTab.allCases,
            selection: $selectedTab,
            counts: [
                .active:    state.assignments.count,
                .completed: state.completedAssignments.count,
                .other:     state.otherItems.count,
            ]
        )
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Completed section

    private var completedSection: some View {
        Group {
            if state.completedAssignments.isEmpty {
                emptyState(title: "Nothing completed yet", message: "Tap the circle on an assignment to mark it done.")
            } else {
                VStack(spacing: 10) {
                    ForEach(state.completedAssignments) { assignment in
                        AssignmentCardView(
                            assignment: assignment,
                            isCompleted: true,
                            dueDateOverride: dueDateOverrides[assignment.id],
                            onToggleCompleted: {
                                state.markActive(assignment)
                                selectedTab = .active
                            },
                            onEditDue: {
                                editingAssignment = assignment
                            }
                        )
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: Other section

    private var otherSection: some View {
        Group {
            if state.otherItems.isEmpty {
                emptyState(title: "No other items", message: "Canvas events and non-assignment items appear here.")
            } else {
                VStack(spacing: 10) {
                    ForEach(state.otherItems) { assignment in
                        AssignmentCardView(
                            assignment: assignment,
                            isCompleted: state.isCompleted(assignment),
                            dueDateOverride: dueDateOverrides[assignment.id],
                            onToggleCompleted: {
                                if state.isCompleted(assignment) {
                                    state.markActive(assignment)
                                } else {
                                    state.markCompleted(assignment)
                                }
                            },
                            onEditDue: {
                                editingAssignment = assignment
                            }
                        )
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: Empty state

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
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
