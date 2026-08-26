import SwiftUI
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Account, appearance, reminder defaults, tasks, storage and troubleshooting.
///
/// **The class list is no longer here.** It moved to the Profile tab in v4 —
/// see `ProfileClassesSection`, which is that code, moved rather than rewritten.
/// The split is "a preference vs. a thing you own": appearance and reminder
/// lead times are preferences; which classes you're taking is not, and it was
/// odd that turning off a course lived next to the light/dark picker.
/// What stays here is the *global* reminder configuration that per-course
/// settings in Profile will inherit from and override.
///
/// In v4 this is the root of the **Settings tab**, which is where its
/// `NavigationStack` comes from (the dashboard's stack supplies one). It still
/// owns **no** stack of its own — nesting one would strand `Grade Watcher`'s
/// link below it, exactly as it would have when this was a push. It is still
/// reachable as a push too, via `ContentView.DashRoute.settings`, which the
/// screenshot seam drives.
struct SettingsPage: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var scheduler: NotificationScheduler
    @Environment(\.dismiss) private var dismiss
    @State private var showRecurring = false
    /// Which service the "are you sure" confirmation is up for, if any.
    /// Disconnecting throws away a login the user can only get back by passing
    /// SSO again, so it asks first.
    @State private var disconnecting: DisconnectTarget?
    /// "Paste your Canvas calendar link" fallback, also reachable from
    /// onboarding (docs/CANVAS_LOGIN_HARDENING.md item 3b).

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
            // Header deliberately isn't "Profile" any more: that word now names
            // a tab, and a Settings section wearing the same label would read
            // as a shortcut to it. The field itself hasn't moved — a name is a
            // preference, and Profile is about classes.
            Section("your name") {
                TextField("your name", text: Binding(
                    get: { state.userName },
                    set: { state.updateName($0) }
                ))
            }

            // One row per source, connect or disconnect on the right. The
            // paste-a-calendar-link fallback moved out of here: it belongs on
            // the path where a login is actually failing (onboarding), not in
            // a list of accounts, where it read as a third thing to connect.
            Section {
                if state.isPreviewMode {
                    // In the demo every connect action runs `restartOnboarding()`,
                    // which drops preview mode and throws whoever tapped it at the
                    // Penn SSO wall with no way back. One clearly labelled exit
                    // instead, so leaving the demo is always deliberate.
                    Button {
                        dismiss()
                        state.restartOnboarding()
                    } label: {
                        Text("exit preview")
                    }
                } else {
                    accountRow(label: "canvas",
                               connected: state.isCanvasConnected,
                               working: state.isLoading || state.isCanvasDiscoveryLoading,
                               disconnect: .canvas)
                    accountRow(label: "gradescope",
                               connected: state.isGradescopeConnected,
                               working: state.isGradescopeLoading,
                               disconnect: .gradescope)
                }
            } header: {
                Text("accounts")
            } footer: {
                Text("everything stays on your phone.")
            }

            Section("appearance") {
                Picker("appearance", selection: Binding(
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

            if FeatureFlags.gradeWatcher {
                Section("grades") {
                    NavigationLink {
                        GradeWatcherView(store: state.gradeWatcher)
                    } label: {
                        Label("grade watcher", systemImage: "chart.bar.fill")
                    }
                }
            }

            Section("tasks") {
                Button {
                    showRecurring = true
                } label: {
                    Label("add recurring task", systemImage: "calendar.badge.plus")
                }
            }

            remindersSection

            storageSection

            if let notice = state.syncNotice ?? state.error {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.lhfSans(12))
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("settings")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .sheet(isPresented: $showRecurring) {
            RecurringTaskSheet().environmentObject(state)
        }
        .alert(item: $disconnecting) { target in
            Alert(
                title: Text("disconnect \(target.label)?"),
                message: Text(target.message),
                primaryButton: .destructive(Text("disconnect")) {
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
            Section("storage") {
                LabeledContent("saved", value: "\(stats.total)")
                LabeledContent("canvas / gradescope", value: "\(stats.canvas) / \(stats.gradescope)")
                LabeledContent("finished", value: "\(stats.finished)")
                if stats.withScores > 0 {
                    LabeledContent("with a score", value: "\(stats.withScores)")
                }
                if stats.goneFromFeed > 0 {
                    LabeledContent("kept after leaving canvas", value: "\(stats.goneFromFeed)")
                }
                if let earliest = stats.earliestFirstSeen {
                    LabeledContent("tracking since", value: earliest.formatted(date: .abbreviated, time: .omitted))
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
                        : "not saving. assignments will be lost when the app quits.",
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

    // MARK: Reminders

    /// The **global** reminder configuration: whether due-date reminders run at
    /// all, which lead times they use, and the daily digest. v4's Profile tab
    /// adds a per-class layer that inherits from exactly these values and
    /// overrides them class by class, which is why they stay in Settings rather
    /// than following the class list over to Profile — this is the default a
    /// student sets once, not the per-course tuning they revisit.
    @ViewBuilder
    private var remindersSection: some View {
        Section("reminders") {
            Toggle("due-date reminders", isOn: Binding(
                get: { scheduler.isEnabled },
                set: { newValue in Task { await scheduler.setEnabled(newValue) } }
            ))

            if scheduler.isEnabled {
                if scheduler.authStatus == .denied {
                    Label("notifications are off in system settings.", systemImage: "bell.slash")
                        .font(.lhfSans(12))
                        .foregroundStyle(.secondary)
                    Button("open settings") { openSystemNotificationSettings() }
                } else {
                    ForEach(NotificationScheduler.LeadOffset.allCases) { offset in
                        Toggle(offset.label, isOn: Binding(
                            get: { scheduler.leadOffsets.contains(offset) },
                            set: { scheduler.setOffset(offset, on: $0) }
                        ))
                    }

                    Toggle("daily \u{201C}what\u{2019}s due\u{201D} digest", isOn: Binding(
                        get: { scheduler.digestEnabled },
                        set: { scheduler.setDigestEnabled($0) }
                    ))
                    if scheduler.digestEnabled {
                        DatePicker("digest time", selection: digestTimeBinding,
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

    /// One source, with its action on the right. Connected state is carried by
    /// the action word itself rather than a separate "Connected" label: the row
    /// only ever offers the one move that applies, so a second status string
    /// was saying the same thing twice.
    private func accountRow(label: String,
                            connected: Bool,
                            working: Bool,
                            disconnect target: DisconnectTarget) -> some View {
        HStack(spacing: 8) {
            if working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: connected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(connected ? Color.v2SpineGreen : .secondary)
            }
            Text(label)
            Spacer()
            if connected {
                Button("disconnect", role: .destructive) { disconnecting = target }
                    .buttonStyle(.borderless)
            } else {
                Button("connect") {
                    dismiss()
                    state.restartOnboarding()
                }
                .buttonStyle(.borderless)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
