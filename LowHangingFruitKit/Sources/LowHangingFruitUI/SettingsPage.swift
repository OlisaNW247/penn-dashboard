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
    @State private var didCopyDiagnostics = false
    /// What the student is currently typing into the Anthropic API key field.
    /// Deliberately starts empty and is never populated from
    /// `AnthropicKeyStore.load()` — see `announcementWatcherSection`'s doc
    /// comment for why round-tripping a secret from storage back into visible
    /// UI state is worth avoiding even though this key never leaves the
    /// device unencrypted.
    @State private var anthropicAPIKeyField = ""
    /// Whether a key is currently saved in the Keychain, read once when this
    /// section appears (and again right after a save) so the field's helper
    /// text can say "a key is saved" without holding the key itself in view
    /// state.
    @State private var hasSavedAnthropicKey = false
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

                    // The feed-connected-but-no-cookie-session state: the
                    // calendar link keeps the dashboard working while
                    // everything session-powered (Grade Watcher, submission
                    // detection, course probes) is silently unavailable —
                    // and, because the Grades entry and the reconnect banner
                    // are both gated on cookie state, there was previously NO
                    // visible way back short of Disconnect → Connect. That
                    // pair is no longer safe advice: disconnect purges the
                    // ledger's Canvas rows, and with iCloud sync on, those
                    // deletions propagate to the user's other devices. This
                    // button is the non-destructive path — same
                    // restartOnboarding() route as "connect", which touches
                    // no stored data and lands on the connect checklist where
                    // the Canvas login step can be redone.
                    if state.isCanvasConnected && !state.canUseGradeWatcher {
                        Button {
                            dismiss()
                            state.restartOnboarding()
                        } label: {
                            Label("sign in to canvas", systemImage: "link")
                        }
                    }

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

            announcementWatcherSection

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
                Section {
                    if state.canUseGradeWatcher {
                        NavigationLink {
                            GradeWatcherView(store: state.gradeWatcher)
                        } label: {
                            Label("grade watcher", systemImage: "chart.bar.fill")
                        }
                    } else {
                        Label("grade watcher", systemImage: "chart.bar.fill")
                            .foregroundStyle(Color.secondary)
                    }
                } header: {
                    Text("grades")
                } footer: {
                    if !state.canUseGradeWatcher {
                        Text("Grade Watcher needs the in-app Canvas login \u{2014} a pasted calendar link carries no account access, so it can never show grades. Use \u{201C}Sign in to Canvas\u{201D} in the Account section above to log in directly; your calendar feed and synced assignments stay put.")
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

    // The "reading & event classes" section that used to sit here was removed
    // when calendar events became include-by-default (owner's call,
    // 2026-08-26 — see `AppState.includesAsOptedInContent`). A readings-only
    // class now behaves like any other class: it lives in the Profile classes
    // list and the normal per-class toggle is what hides it.

    // MARK: Announcement watcher

    /// Settings → "announcement watcher": turns Canvas course announcements
    /// into dashboard items the same way the ICS feed and Modules readings
    /// already do. Placed right after the accounts section — like Grade
    /// Watcher above, this is session-powered (it reads announcements with
    /// the same Canvas login the accounts section connects), so it reads as
    /// one more thing that login unlocks rather than an unrelated preference.
    ///
    /// **Why the API key field never shows the saved key back.** A `SecureField`
    /// pre-filled from `AnthropicKeyStore.load()` would round-trip a bearer
    /// credential (see that store's own doc comment on what the key can do on
    /// its own) from the Keychain into this view's state on every appearance
    /// of this screen — one more place in memory carrying a secret that has
    /// no reason to still be there once it's saved. The field starts empty
    /// and stays that way; `hasSavedAnthropicKey` is the only thing this view
    /// reads back from the store, and it's a boolean, not the key.
    @ViewBuilder
    private var announcementWatcherSection: some View {
        Section {
            Toggle("watch announcements", isOn: Binding(
                get: { state.announcementWatcherEnabled },
                set: { state.setAnnouncementWatcherEnabled($0) }
            ))

            if state.announcementWatcherEnabled {
                Toggle("ai assist", isOn: Binding(
                    get: { state.announcementAIEnabled },
                    set: { state.setAnnouncementAIEnabled($0) }
                ))

                if state.announcementAIEnabled {
                    // Same inline-Binding shape as "your name" above: the
                    // `set` closure both updates the local field state and
                    // persists on every edit, rather than introducing a
                    // separate explicit "save" gesture this file has no other
                    // example of.
                    SecureField("anthropic api key", text: Binding(
                        get: { anthropicAPIKeyField },
                        set: { newValue in
                            anthropicAPIKeyField = newValue
                            AnthropicKeyStore.save(newValue)
                            hasSavedAnthropicKey = !newValue.isEmpty
                        }
                    ))
                    Text(hasSavedAnthropicKey ? "a key is saved on this device." : "no key saved yet \u{2014} paste one above.")
                        .font(.lhfSans(12))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("announcement watcher")
        } footer: {
            Text("reads your professors' announcements with your canvas login and turns 'read this before class' into items here. with ai assist on, announcement text is sent to anthropic's api using your key; off, everything stays on this phone.")
        }
        .onAppear {
            hasSavedAnthropicKey = !AnthropicKeyStore.load().isEmpty
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

                    Toggle("\u{201C}turned in\u{201D} confirmations", isOn: Binding(
                        get: { scheduler.turnedInEnabled },
                        set: { scheduler.setTurnedInEnabled($0) }
                    ))

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

    // MARK: iCloud sync

    /// Settings → "Sync between my devices" (docs/LAPTOP_INTEGRATION_PLAN.md
    /// Tier 2), placed between Reminders and the macOS section so it reads
    /// as one more per-device preference rather than a headline feature —
    /// matching that plan's own caution to ship it "behind a Settings
    /// toggle... default off for one release."
    @ViewBuilder
    private var iCloudSyncSection: some View {
        Section {
            Toggle("sync between my devices", isOn: Binding(
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
            Text("icloud sync")
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
            Toggle("open at login", isOn: Binding(
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
            Text("on this mac")
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
                Label(didCopyDiagnostics ? "copied" : "copy diagnostics report", systemImage: didCopyDiagnostics ? "checkmark" : "doc.on.doc")
            }
            Button {
                reportProblem()
            } label: {
                Label("report a problem", systemImage: "envelope")
            }
        } header: {
            Text("troubleshooting")
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
