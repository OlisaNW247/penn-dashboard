import SwiftUI
import PennDashboardKit

struct ContentView: View {
    private enum DashboardTab: String, CaseIterable, Identifiable {
        case assignments = "Assignments"
        case completed = "Completed"
        case other = "Other"

        var id: Self { self }
    }

    @EnvironmentObject var state: AppState
    @State private var draftCanvasICSURL = ""
    @State private var selectedTab: DashboardTab = .assignments
    @State private var isShowingGradescopeLogin = false
    @State private var isShowingRecurringTaskSheet = false
    @State private var isShowingCanvasScanSheet = false

    var body: some View {
        VStack(spacing: 0) {
            setupBar
            Divider()
            content
            if state.lastSync != nil || state.lastGradescopeSync != nil {
                Divider()
                statusBar
            }
        }
        .onAppear {
            draftCanvasICSURL = state.canvasICSURL
        }
        .sheet(isPresented: $isShowingGradescopeLogin) {
            GradescopeLoginSheet()
                .environmentObject(state)
        }
        .sheet(isPresented: $isShowingRecurringTaskSheet) {
            RecurringTaskSheet()
                .environmentObject(state)
        }
        .sheet(isPresented: $isShowingCanvasScanSheet) {
            CanvasRequirementScanSheet()
                .environmentObject(state)
        }
    }

    private var visibleItems: [Assignment] {
        switch selectedTab {
        case .assignments:
            return state.assignments
        case .completed:
            return state.completedAssignments
        case .other:
            return state.otherItems
        }
    }

    private var setupBar: some View {
        VStack(spacing: 8) {
            if state.canvasICSURL.isEmpty {
                HStack(spacing: 8) {
                    TextField("Canvas Calendar Feed URL (https://canvas.upenn.edu/feeds/calendars/user_….ics)",
                              text: $draftCanvasICSURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveCanvasFeedURL() }

                    Button {
                        saveCanvasFeedURL()
                    } label: {
                        Label("Connect Canvas", systemImage: "calendar.badge.checkmark")
                    }
                    .disabled(draftCanvasICSURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack(spacing: 10) {
                connectionStatus(label: "Canvas Feed", isConnected: !state.canvasICSURL.isEmpty, isWorking: state.isLoading)
                connectionStatus(label: "Gradescope", isConnected: state.isGradescopeConnected, isWorking: state.isGradescopeLoading)
                connectionStatus(label: "Canvas Scan", isConnected: state.isCanvasDiscoveryConnected, isWorking: state.isCanvasDiscoveryLoading)

                Spacer()

                if !state.isGradescopeConnected {
                    Button {
                        isShowingGradescopeLogin = true
                    } label: {
                        Label("Connect Gradescope", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }

                if !state.isCanvasDiscoveryConnected {
                    Button {
                        isShowingCanvasScanSheet = true
                    } label: {
                        Label("Connect Canvas Scan", systemImage: "text.magnifyingglass")
                    }
                }

                Button {
                    isShowingRecurringTaskSheet = true
                } label: {
                    Label("Recurring", systemImage: "calendar.badge.plus")
                }
            }
        }
        .padding(12)
    }

    private func saveCanvasFeedURL() {
        state.updateCanvasICSURL(draftCanvasICSURL)
        draftCanvasICSURL = state.canvasICSURL
        Task { await state.sync() }
    }

    private func connectionStatus(label: String, isConnected: Bool, isWorking: Bool) -> some View {
        HStack(spacing: 5) {
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: isConnected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isConnected ? .green : .secondary)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = state.error {
            VStack(spacing: 0) {
                inlineErrorBar(error)
                tabBar
                Divider()
                noticeBar
                suggestionBar
                tabContent
            }
        } else {
            VStack(spacing: 0) {
                tabBar
                Divider()
                noticeBar
                suggestionBar
                tabContent
            }
        }
    }

    private func inlineErrorBar(_ error: String) -> some View {
        HStack {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var noticeBar: some View {
        if let notice = state.syncNotice {
            HStack {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
        }
    }

    @ViewBuilder
    private var suggestionBar: some View {
        if !state.canvasRequirementSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.canvasRequirementSuggestions) { suggestion in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(suggestion.title) · \(suggestion.course)")
                                .font(.subheadline.weight(.medium))
                            Text("\(suggestion.source.rawValue): \(suggestion.evidence)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Ignore") {
                            state.dismissCanvasSuggestion(suggestion)
                        }
                        Button("Add") {
                            state.addCanvasSuggestion(suggestion)
                        }
                    }
                }
            }
            .padding(12)
            Divider()
        }
    }

    private var tabBar: some View {
        Picker("Dashboard", selection: $selectedTab) {
            ForEach(DashboardTab.allCases) { tab in
                Text("\(tab.rawValue) (\(count(for: tab)))").tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var tabContent: some View {
        if visibleItems.isEmpty && !state.isLoading {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "tray")
            } description: {
                Text(emptyMessage)
            }
        } else {
            List {
                Section(selectedTab.rawValue) {
                    ForEach(visibleItems) { assignment in
                        AssignmentRow(
                            assignment: assignment,
                            isCompleted: selectedTab == .completed,
                            onToggleCompleted: {
                                toggleCompletion(for: assignment)
                            }
                        )
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var emptyTitle: String {
        switch selectedTab {
        case .assignments:
            return "No assignments yet"
        case .completed:
            return "No completed assignments"
        case .other:
            return "No other Canvas items"
        }
    }

    private var emptyMessage: String {
        if state.canvasICSURL.isEmpty {
            return "Connect Canvas Feed or Gradescope above."
        }
        if state.canvasItems.isEmpty && state.gradescopeAssignments.isEmpty {
            return "No dashboard items were found."
        }

        switch selectedTab {
        case .assignments:
            return "No Canvas or Gradescope assignments were found."
        case .completed:
            return "Click the checkmark on an assignment to move it here."
        case .other:
            return "Canvas and Gradescope returned only assignment items."
        }
    }

    private var statusBar: some View {
        HStack {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func count(for tab: DashboardTab) -> Int {
        switch tab {
        case .assignments:
            return state.assignments.count
        case .completed:
            return state.completedAssignments.count
        case .other:
            return state.otherItems.count
        }
    }

    private var statusText: String {
        var parts: [String] = []
        if let last = state.lastSync {
            parts.append("Canvas \(last.formatted(date: .omitted, time: .shortened))")
        }
        if let last = state.lastGradescopeSync {
            parts.append("Gradescope \(last.formatted(date: .omitted, time: .shortened))")
        }
        parts.append("\(state.assignments.count) assignments")
        parts.append("\(state.completedAssignments.count) completed")
        parts.append("\(state.recurringTasks.count) recurring")
        parts.append("\(state.gradescopeAssignments.count) Gradescope")
        parts.append("\(state.otherItems.count) other")
        return parts.joined(separator: " · ")
    }

    private func toggleCompletion(for assignment: Assignment) {
        if state.isCompleted(assignment) {
            state.markActive(assignment)
            selectedTab = .assignments
        } else {
            state.markCompleted(assignment)
            selectedTab = .completed
        }
    }
}

private struct AssignmentRow: View {
    let assignment: Assignment
    let isCompleted: Bool
    let onToggleCompleted: () -> Void

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { timeline in
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(assignment.title).font(.headline)
                    HStack(spacing: 6) {
                        Text(assignment.course)
                        Text(sourceLabel)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(sourceColor.opacity(0.14), in: Capsule())
                            .foregroundStyle(sourceColor)
                        if !assignment.isAssignment {
                            Text(kindLabel)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(kindColor.opacity(0.14), in: Capsule())
                                .foregroundStyle(kindColor)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(dueText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(urgencyColor(at: timeline.date))
                        .lineLimit(1)
                    Text(relativeDueText(at: timeline.date))
                        .font(.caption)
                        .foregroundStyle(urgencyColor(at: timeline.date))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Button {
                            onToggleCompleted()
                        } label: {
                            Label(completionButtonTitle, systemImage: completionButtonIcon)
                                .labelStyle(.iconOnly)
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(completionButtonColor)
                        .help(completionButtonTitle)

                        if let url = assignment.url {
                            Link(destination: url) {
                                Label("Open", systemImage: "arrow.up.right.square")
                                    .labelStyle(.iconOnly)
                                    .font(.body)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var dueText: String {
        guard let due = assignment.dueAt else { return "No due date or time" }
        return "Due \(due.formatted(date: .abbreviated, time: .shortened))"
    }

    private func urgencyColor(at now: Date) -> Color {
        guard let due = assignment.dueAt else { return .secondary }
        let interval = due.timeIntervalSince(now)
        if interval < 0          { return .red }
        if interval < 86_400     { return .orange }
        if interval < 86_400 * 3 { return .yellow }
        return .primary
    }

    private func relativeDueText(at now: Date) -> String {
        guard let due = assignment.dueAt else { return "Countdown unavailable" }

        let interval = due.timeIntervalSince(now)
        if abs(interval) < 60 {
            return interval >= 0 ? "Due now" : "Just overdue"
        }

        let duration = compactDuration(abs(interval))
        return interval >= 0 ? "Due in \(duration)" : "Overdue by \(duration)"
    }

    private func compactDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = max(1, Int(interval / 60))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    private var kindLabel: String {
        switch assignment.kind {
        case .assignment: return "Assignment"
        case .quiz:       return "Quiz"
        case .discussion: return "Discussion"
        case .event:      return "Event"
        case .other:      return "Other"
        }
    }

    private var kindColor: Color {
        switch assignment.kind {
        case .assignment: return .primary
        case .quiz:       return .purple
        case .discussion: return .blue
        case .event:      return .green
        case .other:      return .secondary
        }
    }

    private var sourceLabel: String {
        switch assignment.source {
        case .canvas:     return "Canvas"
        case .gradescope: return "Gradescope"
        case .ed:         return "Ed"
        case .manual:     return "Manual"
        case .canvasSuggestion: return "Canvas Found"
        }
    }

    private var sourceColor: Color {
        switch assignment.source {
        case .canvas:     return .red
        case .gradescope: return .indigo
        case .ed:         return .teal
        case .manual:     return .brown
        case .canvasSuggestion: return .orange
        }
    }

    private var completionButtonTitle: String {
        isCompleted ? "Move back to assignments" : "Mark completed"
    }

    private var completionButtonIcon: String {
        isCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle"
    }

    private var completionButtonColor: Color {
        isCompleted ? .secondary : .green
    }
}
