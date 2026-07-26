import SwiftUI
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Houses everything that used to clutter the main screen: connection status,
/// reconnect, class editing, recurring-task entry, and reminder preferences.
///
/// Pushed onto the dashboard's `NavigationStack` (from the header's Settings
/// button) rather than presented as a sheet, so it's a full screen with a back
/// button. It therefore owns **no** `NavigationStack` of its own — nesting one
/// would break the push and strand `Grade Watcher`'s own link below it.
struct SettingsPage: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var scheduler: NotificationScheduler
    @Environment(\.dismiss) private var dismiss
    @State private var showRecurring = false
    /// Non-nil while the rename prompt is up; holds the course *code* being
    /// renamed (never the display name, which is what's being edited).
    @State private var renamingCourse: String?
    @State private var renameDraft = ""
    /// Which service the "are you sure" confirmation is up for, if any.
    /// Disconnecting throws away a login the user can only get back by passing
    /// SSO again, so it asks first.
    @State private var disconnecting: DisconnectTarget?

    enum DisconnectTarget: String, Identifiable {
        case canvas, gradescope
        var id: String { rawValue }
        var label: String { self == .canvas ? "Canvas" : "Gradescope" }
        var message: String {
            switch self {
            case .canvas:
                return "Removes your saved Canvas login and calendar feed from this device, along with your synced assignments and grades. Your own tasks, completions and reminders stay. You'll need to sign in to Canvas again to reconnect."
            case .gradescope:
                return "Removes your saved Gradescope login from this device, along with anything synced from it. Canvas stays connected."
            }
        }
    }

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Your name", text: Binding(
                    get: { state.userName },
                    set: { state.updateName($0) }
                ))
            }

            Section {
                statusRow(label: "Canvas",
                          connected: state.isCanvasConnected,
                          working: state.isLoading || state.isCanvasDiscoveryLoading)

                if state.isCanvasConnected {
                    Button(role: .destructive) {
                        disconnecting = .canvas
                    } label: {
                        Label("Disconnect Canvas", systemImage: "link.badge.plus")
                    }
                } else {
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

                if state.isGradescopeConnected {
                    Button(role: .destructive) {
                        disconnecting = .gradescope
                    } label: {
                        Label("Disconnect Gradescope", systemImage: "link.badge.plus")
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Disconnecting erases that service\u{2019}s saved login from this device. LHF has no account and no server \u{2014} everything it knows lives on your phone.")
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

            if FeatureFlags.gradeWatcher {
                Section("Grades") {
                    NavigationLink {
                        GradeWatcherView(store: state.gradeWatcher)
                    } label: {
                        Label("Grade Watcher", systemImage: "chart.bar.fill")
                    }
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
        .sheet(isPresented: $showRecurring) {
            RecurringTaskSheet().environmentObject(state)
        }
        .alert("Rename class", isPresented: Binding(
            get: { renamingCourse != nil },
            set: { if !$0 { renamingCourse = nil } }
        )) {
            TextField("Class name", text: $renameDraft)
            Button("Save") {
                if let course = renamingCourse {
                    state.renameCourse(course, to: renameDraft)
                }
                renamingCourse = nil
            }
            Button("Cancel", role: .cancel) { renamingCourse = nil }
        } message: {
            Text("Shown in place of \(renamingCourse ?? "the class code"). Leave it empty to go back to the original.")
        }
        .alert(item: $disconnecting) { target in
            Alert(
                title: Text("Disconnect \(target.label)?"),
                message: Text(target.message),
                primaryButton: .destructive(Text("Disconnect")) {
                    switch target {
                    case .canvas:     state.disconnectCanvas()
                    case .gradescope: state.disconnectGradescope()
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .task { await scheduler.refreshAuthStatus() }
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
                    classRow(course)
                }

                if !deletedCourses.isEmpty {
                    deletedClassesRow(deletedCourses)
                }
            } header: {
                Text("Classes")
            } footer: {
                Text("Turn a class off to hide its assignments and its reminders. Swipe to rename or delete \u{2014} renaming only changes the label, so grades and reminders keep working.")
            }
        }
    }

    /// One class: the on/off toggle, plus rename and delete. The row shows the
    /// user's own name when they've set one, but every action still keys on
    /// `course` (the code Canvas gave us) so a rename can't detach the class
    /// from its assignments or its grades.
    private func classRow(_ course: String) -> some View {
        Toggle(state.courseDisplayName(course), isOn: Binding(
            get: { state.isCourseSelected(course) },
            set: { state.setCourse(course, selected: $0) }
        ))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                state.deleteCourse(course)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                beginRename(course)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Color.v2DateText)
        }
        .contextMenu {
            Button {
                beginRename(course)
            } label: {
                Label("Rename class", systemImage: "pencil")
            }
            if state.hasCustomName(course) {
                Button {
                    state.renameCourse(course, to: "")
                } label: {
                    Label("Reset to \(course)", systemImage: "arrow.uturn.backward")
                }
            }
            Button(role: .destructive) {
                state.deleteCourse(course)
            } label: {
                Label("Delete class", systemImage: "trash")
            }
        }
    }

    private func beginRename(_ course: String) {
        renameDraft = state.courseDisplayName(course)
        renamingCourse = course
    }

    private func deletedClassesRow(_ deletedCourses: [String]) -> some View {
        DisclosureGroup {
            ForEach(deletedCourses, id: \.self) { course in
                HStack {
                    Text(state.courseDisplayName(course))
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
