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
/// `NavigationStack` comes from (`MainTabView` supplies one per tab). It still
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
    @State private var showPasteFeedLink = false
    @State private var didCopyDiagnostics = false

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
            Section("Your name") {
                TextField("Your name", text: Binding(
                    get: { state.userName },
                    set: { state.updateName($0) }
                ))
            }

            Section {
                statusRow(label: "Canvas",
                          connected: state.isCanvasConnected,
                          working: state.isLoading || state.isCanvasDiscoveryLoading)

                if state.isPreviewMode {
                    // In the demo every "Connect…" row runs `restartOnboarding()`,
                    // which silently drops preview mode and throws whoever tapped
                    // it at the Penn SSO wall — with no way back, since the
                    // preview door is gated behind `hasSeenIntro`. That is a trap
                    // for a reviewer and merely baffling for a student who tapped
                    // Preview out of curiosity. One clearly-labelled exit instead,
                    // so leaving the demo is always a deliberate act.
                    Button {
                        dismiss()
                        state.restartOnboarding()
                    } label: {
                        Label("Exit preview and connect my Canvas", systemImage: "arrow.right.circle")
                    }
                } else {
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

                    // The escape hatch for a login that won't complete: paste
                    // the calendar feed URL straight out of Canvas. Stays
                    // inside the non-preview branch — a preview session has no
                    // real feed to point at, and offering one there would put
                    // the reviewer back at the wall the branch above exists to
                    // keep them away from.
                    Button {
                        showPasteFeedLink = true
                    } label: {
                        Label("Paste calendar link instead", systemImage: "link.badge.plus")
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

    // MARK: Reminders

    /// The **global** reminder configuration: whether due-date reminders run at
    /// all, which lead times they use, and the daily digest. v4's Profile tab
    /// adds a per-class layer that inherits from exactly these values and
    /// overrides them class by class, which is why they stay in Settings rather
    /// than following the class list over to Profile — this is the default a
    /// student sets once, not the per-course tuning they revisit.
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
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("Copies device/app info and a redacted login redirect log \u{2014} no passwords, cookies, or links. Paste it when asking for help with a stuck Canvas login.")
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
