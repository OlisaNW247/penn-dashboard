import SwiftUI
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Houses everything that used to clutter the main screen: connection status,
/// reconnect, recurring-task entry, and Canvas requirement suggestions. The
/// main dashboard stays just header + ring + toggle + list.
struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var scheduler: NotificationScheduler
    @Environment(\.dismiss) private var dismiss
    @State private var showRecurring = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Your name", text: Binding(
                        get: { state.userName },
                        set: { state.updateName($0) }
                    ))
                }

                Section("Account") {
                    statusRow(label: "Canvas",
                              connected: state.isCanvasConnected,
                              working: state.isLoading || state.isCanvasDiscoveryLoading)

                    if !state.isCanvasConnected {
                        Button {
                            dismiss()
                            state.restartOnboarding()
                        } label: {
                            Label("Connect Canvas", systemImage: "link")
                        }
                    }

                    statusRow(label: "Gradescope",
                              connected: state.isGradescopeConnected,
                              working: state.isGradescopeLoading)

                    Button {
                        dismiss()
                        state.restartOnboarding()
                    } label: {
                        Label(state.isGradescopeConnected ? "Reconnect Gradescope" : "Connect Gradescope",
                              systemImage: "link")
                    }
                }

                Section("Appearance") {
                    Picker("Appearance", selection: Binding(
                        get: { state.appearanceMode },
                        set: { state.setAppearanceMode($0) }
                    )) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                classesSection

                Section("Grades") {
                    NavigationLink {
                        GradeWatcherView(store: state.gradeWatcher)
                    } label: {
                        Label("Grade Watcher", systemImage: "chart.bar.fill")
                    }
                }

                Section("Tasks") {
                    Button {
                        showRecurring = true
                    } label: {
                        Label("Add recurring task", systemImage: "calendar.badge.plus")
                    }
                }

                remindersSection

                #if DEBUG
                // Hidden in demo/screenshot mode so store assets stay clean.
                if !ProcessInfo.processInfo.arguments.contains("-LHFDemoData") {
                    Section("Debug") {
                        Button("Load sample data") { state.loadSampleData() }
                    }
                }
                #endif

                if let notice = state.syncNotice ?? state.error {
                    Section {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .font(.lhfSans(12))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Settings")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showRecurring) {
                RecurringTaskSheet().environmentObject(state)
            }
            .task { await scheduler.refreshAuthStatus() }
        }
        .lhfSheetTheme()
        .frame(minWidth: 360, minHeight: 420)
    }

    // MARK: Classes

    /// Same class picker as onboarding, so a course can be turned off any time.
    /// Off = hidden from the dashboard and from reminders. Swipe to delete a
    /// class entirely (it drops out of this list, not just off); "Deleted
    /// classes" below lists anything deleted so it can be brought back.
    @ViewBuilder
    private var classesSection: some View {
        let courses = state.visibleCourseCodes()
        let deletedCourses = state.deletedCourseCodes()
        if !courses.isEmpty || !deletedCourses.isEmpty {
            Section {
                ForEach(courses, id: \.self) { course in
                    Toggle(course, isOn: Binding(
                        get: { state.isCourseSelected(course) },
                        set: { state.setCourse(course, selected: $0) }
                    ))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            state.deleteCourse(course)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            state.deleteCourse(course)
                        } label: {
                            Label("Delete class", systemImage: "trash")
                        }
                    }
                }

                if !deletedCourses.isEmpty {
                    deletedClassesRow(deletedCourses)
                }
            } header: {
                Text("Classes")
            } footer: {
                Text("Turn a class off to hide its assignments and its reminders. Swipe to delete a class you don\u{2019}t want to see at all.")
            }
        }
    }

    private func deletedClassesRow(_ deletedCourses: [String]) -> some View {
        DisclosureGroup {
            ForEach(deletedCourses, id: \.self) { course in
                HStack {
                    Text(course)
                        .font(.lhfSans(14))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore") {
                        state.restoreCourse(course)
                    }
                    .font(.lhfSans(13))
                }
            }
        } label: {
            Label("Deleted classes (\(deletedCourses.count))", systemImage: "trash")
                .font(.lhfSans(13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Reminders

    @ViewBuilder
    private var remindersSection: some View {
        Section("Reminders") {
            Toggle("Due-date reminders", isOn: Binding(
                get: { scheduler.isEnabled },
                set: { newValue in Task { await scheduler.setEnabled(newValue) } }
            ))

            if scheduler.isEnabled {
                if scheduler.authStatus == .denied {
                    Label("Notifications are off in System Settings.", systemImage: "bell.slash")
                        .font(.lhfSans(12))
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { openSystemNotificationSettings() }
                } else {
                    ForEach(NotificationScheduler.LeadOffset.allCases) { offset in
                        Toggle(offset.label, isOn: Binding(
                            get: { scheduler.leadOffsets.contains(offset) },
                            set: { scheduler.setOffset(offset, on: $0) }
                        ))
                    }

                    Toggle("Daily \u{201C}what\u{2019}s due\u{201D} digest", isOn: Binding(
                        get: { scheduler.digestEnabled },
                        set: { scheduler.setDigestEnabled($0) }
                    ))
                    if scheduler.digestEnabled {
                        DatePicker("Digest time", selection: digestTimeBinding,
                                   displayedComponents: .hourAndMinute)
                    }
                }
            }
        }
    }

    private var digestTimeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: scheduler.digestTime) ?? Date() },
            set: { scheduler.setDigestTime(Calendar.current.dateComponents([.hour, .minute], from: $0)) }
        )
    }

    private func openSystemNotificationSettings() {
#if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
#elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
#endif
    }

    private func statusRow(label: String, connected: Bool, working: Bool) -> some View {
        HStack(spacing: 8) {
            if working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: connected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(connected ? Color.v2SpineGreen : .secondary)
            }
            Text(label)
            Spacer()
            Text(connected ? "Connected" : "Not connected")
                .font(.lhfSans(12))
                .foregroundStyle(.secondary)
        }
    }
}
