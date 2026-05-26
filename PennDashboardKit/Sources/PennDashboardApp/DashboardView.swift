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
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 20)

                SegmentedToggleView(
                    options: DashTab.allCases,
                    selection: $selectedTab,
                    counts: [
                        .active:    activeItems.count,
                        .completed: completedItems.count,
                        .other:     state.otherItems.count,
                    ]
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

                tabContent
            }
            .padding(.bottom, 40)
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
        .sheet(isPresented: $showSettings) {
            SettingsSheet().environmentObject(state)
        }
    }

    // MARK: – Data (with DEBUG sample fallback)

    private var isUsingDebugSampleData: Bool {
        #if DEBUG
        return state.canvasItems.isEmpty
            && state.gradescopeAssignments.isEmpty
            && state.recurringTasks.isEmpty
        #else
        return false
        #endif
    }

    private var activeItems: [Assignment] {
        if isUsingDebugSampleData {
            #if DEBUG
            return SampleData.assignments.filter { !state.isCompleted($0) }
            #endif
        }
        return state.assignments
    }

    private var completedItems: [Assignment] {
        if isUsingDebugSampleData {
            #if DEBUG
            return SampleData.assignments.filter { state.isCompleted($0) }
            #endif
        }
        return state.completedAssignments
    }

    // MARK: – Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LHF")
                        .font(.instrumentSerif(34))
                        .foregroundStyle(Color.lhfGraphite)
                    Text("Low Hanging Fruit")
                        .font(.geist(12))
                        .foregroundStyle(Color.lhfGraphite.opacity(0.55))
                }
                Spacer()
                gearButton
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(todayFormatted)
                    .font(.instrumentSerif(28))
                    .foregroundStyle(Color.lhfGraphite)
                Text(weekCountLabel)
                    .font(.geist(13))
                    .foregroundStyle(Color.lhfGraphite.opacity(0.55))
            }
        }
    }

    @ViewBuilder
    private var gearButton: some View {
        #if os(iOS)
        Button { showSettings = true } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.lhfGraphite.opacity(0.55))
        }
        .buttonStyle(.plain)
        #endif
    }

    private var todayFormatted: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }

    private var weekCountLabel: String {
        let now = Date()
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        let count = activeItems.filter { a in
            guard let due = a.dueAt else { return false }
            return due > now && due <= weekEnd
        }.count
        return "\(count) assignment\(count == 1 ? "" : "s") this week"
    }

    // MARK: – Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .active:
            let sections = buildSections(from: activeItems, now: Date())
            if sections.isEmpty {
                emptyState
            } else {
                ForEach(sections) { section in
                    sectionBlock(section)
                }
            }

        case .completed:
            if completedItems.isEmpty {
                emptyState
            } else {
                VStack(spacing: 12) {
                    ForEach(completedItems) { assignment in
                        AssignmentCardView(
                            assignment: assignment,
                            isCompleted: true,
                            dueDateOverride: dueDateOverrides[assignment.id],
                            onToggleCompleted: {
                                state.markActive(assignment)
                                selectedTab = .active
                            },
                            onEditDue: { editingAssignment = assignment }
                        )
                        .padding(.horizontal, 20)
                    }
                }
            }

        case .other:
            if state.otherItems.isEmpty {
                emptyState
            } else {
                VStack(spacing: 12) {
                    ForEach(state.otherItems) { assignment in
                        AssignmentCardView(
                            assignment: assignment,
                            isCompleted: state.isCompleted(assignment),
                            dueDateOverride: dueDateOverrides[assignment.id],
                            onToggleCompleted: {
                                if state.isCompleted(assignment) { state.markActive(assignment) }
                                else { state.markCompleted(assignment) }
                            },
                            onEditDue: { editingAssignment = assignment }
                        )
                        .padding(.horizontal, 20)
                    }
                }
            }
        }
    }

    private func sectionBlock(_ section: DashSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.label)
                .font(.geist(11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.lhfGraphite.opacity(0.4))
                .padding(.horizontal, 20)

            VStack(spacing: 12) {
                ForEach(section.items) { assignment in
                    AssignmentCardView(
                        assignment: assignment,
                        isCompleted: false,
                        dueDateOverride: dueDateOverrides[assignment.id],
                        onToggleCompleted: { state.markCompleted(assignment) },
                        onEditDue: { editingAssignment = assignment }
                    )
                    .padding(.horizontal, 20)
                }
            }
        }
        .padding(.bottom, 24)
    }

    private var emptyState: some View {
        Text("all done.")
            .font(.instrumentSerif(28))
            .foregroundStyle(Color.lhfGraphite.opacity(0.35))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 80)
    }

    // MARK: – Section builder

    private func buildSections(from items: [Assignment], now: Date) -> [DashSection] {
        let cal = Calendar.current
        let todayStart    = cal.startOfDay(for: now)
        let tomorrowStart = cal.date(byAdding: .day, value: 1, to: todayStart)!
        let dayAfter      = cal.date(byAdding: .day, value: 2, to: todayStart)!
        let weekEnd       = cal.date(byAdding: .day, value: 7, to: todayStart)!

        var past:     [Assignment] = []
        var today:    [Assignment] = []
        var tomorrow: [Assignment] = []
        var thisWeek: [Assignment] = []
        var later:    [Assignment] = []

        for item in items {
            let due = dueDateOverrides[item.id] ?? item.dueAt
            guard let due else { later.append(item); continue }
            if due < now              { past.append(item) }
            else if due < tomorrowStart { today.append(item) }
            else if due < dayAfter     { tomorrow.append(item) }
            else if due < weekEnd      { thisWeek.append(item) }
            else                       { later.append(item) }
        }

        var sections: [DashSection] = []
        if !past.isEmpty     { sections.append(.init(id: "past",     label: "PAST DUE",  items: past)) }
        if !today.isEmpty    { sections.append(.init(id: "today",    label: "TODAY",     items: today)) }
        if !tomorrow.isEmpty { sections.append(.init(id: "tomorrow", label: "TOMORROW",  items: tomorrow)) }
        if !thisWeek.isEmpty { sections.append(.init(id: "week",     label: "THIS WEEK", items: thisWeek)) }
        if !later.isEmpty    { sections.append(.init(id: "later",    label: "LATER",     items: later)) }
        return sections
    }
}
