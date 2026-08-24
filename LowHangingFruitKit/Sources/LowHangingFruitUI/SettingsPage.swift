import SwiftUI
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if os(macOS)
import ServiceManagement
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
    /// "Paste your Canvas calendar link" fallback, also reachable from
    /// onboarding (docs/CANVAS_LOGIN_HARDENING.md item 3b).
    @State private var showPasteFeedLink = false
    @State private var didCopyDiagnostics = false
    #if os(macOS)
    /// Bumped after every `SMAppService` register/unregister call so the
    /// toggle below re-reads `.status` — that call doesn't publish anything
    /// itself, and the toggle's `get` has no other reason to be re-evaluated.
    @State private var loginItemRefreshNonce = 0
    #endif

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
                    Button {
                        showPasteFeedLink = true
                    } label: {
                        Label("Paste calendar link instead", systemImage: "link.badge.plus")
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

            courseContentSection

            if FeatureFlags.gradeWatcher {
                Section {
                    if state.canUseGradeWatcher {
                        NavigationLink {
                            GradeWatcherView(store: state.gradeWatcher)
                        } label: {
                            Label("Grade Watcher", systemImage: "chart.bar.fill")
                        }
                    } else {
                        Label("Grade Watcher", systemImage: "chart.bar.fill")
                            .foregroundStyle(Color.secondary)
                    }
                } header: {
                    Text("Grades")
                } footer: {
                    if !state.canUseGradeWatcher {
                        Text("Grade Watcher needs the in-app Canvas login \u{2014} a pasted calendar link carries no account access, so it can never show grades. Use Disconnect Canvas above, then Connect Canvas to log in directly.")
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

            iCloudSyncSection

            #if os(macOS)
            onThisMacSection
            #endif

            storageSection

            diagnosticsSection

            if let notice = state.syncNotice ?? state.error {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.lhfSans(12))
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .sheet(isPresented: $showRecurring) {
            RecurringTaskSheet().environmentObject(state)
        }
        .sheet(isPresented: $showPasteFeedLink) {
            PasteFeedLinkSheet(onSaved: {}).environmentObject(state)
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

    // MARK: Storage

    /// What the durable ledger is actually holding. This exists because the
    /// failure mode it guards against is invisible: if the App Group container
    /// isn't entitled, `AssignmentStore` degrades to an in-memory store and the
    /// app looks completely normal right up until everything is gone after a
    /// relaunch. "Saved on this device" vs "Not saving" is the whole point;
    /// the counts underneath are how you confirm a sync actually landed.
    @ViewBuilder
    private var storageSection: some View {
        if let stats = state.assignmentStore?.stats() {
            Section("Storage") {
                LabeledContent("Saved assignments", value: "\(stats.total)")
                LabeledContent("Canvas / Gradescope", value: "\(stats.canvas) / \(stats.gradescope)")
                LabeledContent("Finished (kept forever)", value: "\(stats.finished)")
                if stats.withScores > 0 {
                    LabeledContent("With a saved score", value: "\(stats.withScores)")
                }
                if stats.goneFromFeed > 0 {
                    LabeledContent("Retained after leaving the feed", value: "\(stats.goneFromFeed)")
                }
                if let earliest = stats.earliestFirstSeen {
                    LabeledContent("Tracking since", value: earliest.formatted(date: .abbreviated, time: .omitted))
                }
                // Always shown, even at 0: this is the number that says the
                // in-code uniqueness invariant is holding now that the
                // database no longer enforces it (`.unique` came off for
                // CloudKit), and a provable zero after a two-device merge is
                // the whole point. An absent row would be indistinguishable
                // from "nobody ever checked".
                LabeledContent("Duplicate entries", value: "\(stats.duplicateIDs)")
                if stats.duplicateIDs > 0 {
                    Text("The ledger is holding more than one copy of the same assignment. It will self-heal on the next sync, but this appearing at all is a bug worth reporting.")
                        .font(.lhfSans(12))
                        .foregroundStyle(Color.orange)
                }
                // Three states, not two. A store can be perfectly on-disk and
                // still be failing every write, and telling that user their
                // work "will be lost when the app quits" is both wrong and
                // unactionable.
                Label(
                    stats.isPersistent
                        ? (stats.failedSaveCount == 0
                            ? "Saved on this device."
                            : "Saved on this device, but recent changes didn't stick.")
                        : "Not saving — assignments will be lost when the app quits.",
                    systemImage: stats.isHealthy ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.lhfSans(12))
                .foregroundStyle(stats.isHealthy ? Color.secondary : Color.orange)

                // The specifics, when there are any. "Not saving" on its own
                // tells the user something is wrong but nothing about what —
                // and these two failures have completely different fixes
                // (reinstall vs. free up space), so naming them is the
                // difference between an actionable warning and a shrug.
                if let reason = stats.storageFailureReason {
                    Text(reason)
                        .font(.lhfSans(12))
                        .foregroundStyle(Color.orange)
                }
                if stats.failedSaveCount > 0 {
                    Text("\(stats.failedSaveCount) change\(stats.failedSaveCount == 1 ? "" : "s") couldn't be written to storage. Check that your device isn't out of space.")
                        .font(.lhfSans(12))
                        .foregroundStyle(Color.orange)
                }
            }
        }
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

    // MARK: Reading & event classes

    /// Management surface for courses whose readings/events the dashboard
    /// isn't showing by default (docs/READINGS_COURSES_PLAN.md Phase 3.8) —
    /// the durable, revisitable counterpart to `CourseNudgeSheet`'s one-time
    /// ask. Only lists courses `AppState` considers manageable; a normal
    /// course with submittable work never appears here.
    @ViewBuilder
    private var courseContentSection: some View {
        let manageable = state.courseContentManageableCourses
        if !manageable.isEmpty {
            Section {
                ForEach(manageable, id: \.courseKey) { report in
                    Toggle(isOn: Binding(
                        get: { state.courseContentIncluded(report.courseKey) },
                        set: { state.setCourseContentIncluded(report.courseKey, $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.courseDisplayName(report.courseKey))
                            Text(courseContentCaption(report))
                                .font(.lhfSans(11))
                                .foregroundStyle(Color.v2DateText)
                        }
                    }
                }
            } header: {
                Text("Reading & event classes")
            } footer: {
                Text("These classes only post readings or events \u{2014} nothing to submit. On means their items show on your list.")
            }
        }
    }

    /// Short summary of what was actually found for `report`, shown under its
    /// toggle. Mirrors the counts `CourseNudgeSheet` explains at ask time.
    private func courseContentCaption(_ report: CourseProfileReport) -> String {
        switch report.profile {
        case let .readingsOnCalendar(eventCount, _):
            return "\(eventCount) calendar reading\(eventCount == 1 ? "" : "s")"
        case let .silent(moduleReadingCount):
            guard let moduleReadingCount, moduleReadingCount > 0 else { return "nothing found yet" }
            return "\(moduleReadingCount) module reading\(moduleReadingCount == 1 ? "" : "s")"
        case .normal, .unknownSilent:
            return "nothing found yet"
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

                    Toggle("\u{201C}Turned in\u{201D} confirmations", isOn: Binding(
                        get: { scheduler.turnedInEnabled },
                        set: { scheduler.setTurnedInEnabled($0) }
                    ))

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

    // MARK: iCloud sync

    /// Settings → "Sync between my devices" (docs/LAPTOP_INTEGRATION_PLAN.md
    /// Tier 2), placed between Reminders and the macOS section so it reads
    /// as one more per-device preference rather than a headline feature —
    /// matching that plan's own caution to ship it "behind a Settings
    /// toggle... default off for one release."
    @ViewBuilder
    private var iCloudSyncSection: some View {
        Section {
            Toggle("Sync between my devices", isOn: Binding(
                get: { state.cloudSyncEnabled },
                set: { state.setCloudSyncEnabled($0) }
            ))

            // Priority order matters here, not just presence: a toggle
            // flipped THIS session hasn't actually reconfigured
            // `assignmentStore` yet (see `AppState.cloudSyncEnabledAtLaunch`),
            // so "takes effect next launch" must win over both other lines —
            // otherwise a student who just turned sync on would see "Sync is
            // on" immediately, which isn't true until they relaunch.
            if state.cloudSyncEnabled != state.cloudSyncEnabledAtLaunch {
                Text("Takes effect after you quit and reopen LHF.")
                    .font(.lhfSans(12))
                    .foregroundStyle(.secondary)
            } else if state.cloudSyncEnabled, let reason = state.assignmentStore?.storageFailureReason {
                Text(reason)
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.orange)
            } else if state.cloudSyncEnabled {
                Text("Sync is on. Changes appear on your other devices within a minute or two.")
                    .font(.lhfSans(12))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("iCloud sync")
        } footer: {
            Text("Syncs your assignments and choices through your own iCloud account \u{2014} nothing is visible to LHF\u{2019}s developer. Takes effect the next time you quit and reopen LHF. Both devices need to be signed into the same iCloud account.")
        }
    }

    // MARK: On this Mac

    #if os(macOS)
    /// Launch-at-login (docs/LAPTOP_INTEGRATION_PLAN.md Tier 1) — what makes
    /// the persistent menu-bar sync loop (`MenuBarLabel` in `LHFScenes.swift`)
    /// actually start without the user remembering to open the app after
    /// every reboot. `SMAppService.mainApp` registers/unregisters *this* app
    /// bundle as a login item directly; no separate helper target needed.
    @ViewBuilder
    private var onThisMacSection: some View {
        Section {
            Toggle("Open at login", isOn: Binding(
                get: {
                    _ = loginItemRefreshNonce // force a re-read after register/unregister
                    return SMAppService.mainApp.status == .enabled
                },
                set: { newValue in
                    if newValue {
                        try? SMAppService.mainApp.register()
                    } else {
                        try? SMAppService.mainApp.unregister()
                    }
                    loginItemRefreshNonce += 1
                }
            ))
        } header: {
            Text("On this Mac")
        } footer: {
            Text("Keeps LHF in your menu bar so assignments stay fresh all day.")
        }
    }
    #endif

    /// Copyable diagnostics report (docs/CANVAS_LOGIN_HARDENING.md item 3e) —
    /// meant to be pasted into a support message when Canvas login is stuck.
    /// Contains no credentials, cookie values, or the ICS feed URL/token —
    /// see `DiagnosticsReport`'s doc comment for exactly what's included.
    private var diagnosticsSection: some View {
        Section {
            Button {
                copyDiagnostics()
            } label: {
                Label(didCopyDiagnostics ? "Copied" : "Copy diagnostics report", systemImage: didCopyDiagnostics ? "checkmark" : "doc.on.doc")
            }
            Button {
                reportProblem()
            } label: {
                Label("Report a problem", systemImage: "envelope")
            }
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("Copies device/app info and a redacted login redirect log \u{2014} no passwords, cookies, or links. \u{201C}Report a problem\u{201D} opens an email with that same redacted report already in it, so you only have to describe what happened.")
        }
    }

    private func copyDiagnostics() {
        let report = DiagnosticsReport.generate(state: state)
        #if canImport(UIKit)
        UIPasteboard.general.string = report
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        #endif
        didCopyDiagnostics = true
    }

    private func reportProblem() {
        let report = DiagnosticsReport.generate(state: state)
        SupportContact.openReportMail(diagnostics: report)
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
