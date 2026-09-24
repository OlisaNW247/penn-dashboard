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

/// The single Profile destination: identity, classes, notification choices and
/// app preferences. Infrequent preferences collapse into one group so the page
/// stays short during ordinary use.
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
    /// Presents `PennKeyCredentialsSheet` — set true by the "stay signed in"
    /// toggle's own binding when it's flipped ON (the sheet's own save is
    /// what actually calls `AppState.enableStayLoggedIn`; see
    /// `stayLoggedInRows`) and by its "update password" button after a
    /// rejection.
    @State private var showStayLoggedInSheet = false
    @State private var didCopyDiagnostics = false
    @State private var confirmingBackendDataDeletion = false
    #if DEBUG
    /// Drives the "simulate canvas logout" DEBUG row below — `nil` result
    /// with `isRunning == false` is the row's resting state (never shown
    /// yet this launch); `isRunning` shows a spinner in its place; a
    /// non-nil result persists until the next tap, which resets it back to
    /// `nil` before the new attempt starts so a stale result never lingers
    /// alongside the fresh spinner.
    @State private var isSimulatingCanvasLogout = false
    @State private var simulateCanvasLogoutResult: String?
    /// Same resting/running/result shape as the pair above, for the
    /// "probe ed discussion" row (`AppState.probeEdDiscussionForTesting()`).
    @State private var isProbingEdDiscussion = false
    @State private var probeEdDiscussionResult: String?
    @State private var didCopyProbeEdDiscussionResult = false
    #endif
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
            Section {
                SmoothFormHeader(
                    title: "Profile",
                    accent: .smoothTeal,
                    spark: .smoothGrape
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            .listRowSeparator(.hidden)

            Section {
                TextField("your name", text: Binding(
                    get: { state.userName },
                    set: { state.updateName($0) }
                ))
            } header: {
                SmoothSectionHeader("your name", accent: .smoothCobalt)
            }
            .smoothSectionBackground(.smoothLemon)

            Section {
                if state.isPreviewMode {
                    // Every row below calls `restartOnboarding()`, which
                    // silently drops preview mode — the reviewer's only way
                    // to see a populated app without Penn SSO, which they
                    // cannot pass. Left as two ordinary rows, "canvas" would
                    // read "not connected" in preview (there's no real
                    // login), so a reviewer poking at Profile the way
                    // REVIEW_NOTES.md tells them to would tap it expecting
                    // to see connection status and get ejected instead, with
                    // no way back short of reinstalling. One clearly-labelled
                    // exit, so leaving the demo is always deliberate. See
                    // `c999c38` — this collapsed row is that same fix,
                    // restored after a later Settings/Profile merge dropped
                    // it along with the rest of the old two-row layout.
                    Button {
                        dismiss()
                        state.restartOnboarding()
                    } label: {
                        Label("exit preview and connect my Canvas", systemImage: "arrow.right.circle")
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
                    stayLoggedInRows
                }
            } header: {
                SmoothSectionHeader("accounts", accent: .smoothCobalt)
            }
            .smoothSectionBackground(.smoothTeal)

            Section {
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
            } header: {
                SmoothSectionHeader("appearance", accent: .smoothCobalt)
            }
            .smoothSectionBackground(.smoothCobalt)

            remindersSection
            ProfileClassesSection { showRecurring = true }
            ProfileNotificationsSection()
            iCloudSyncSection
        }
        .formStyle(.grouped)
        .font(.lhfSecondary(15))
        .foregroundStyle(Color.smoothInk)
        .smoothFormChrome(accent: .smoothTeal)
        .navigationTitle("")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .sheet(isPresented: $showRecurring) {
            RecurringTaskSheet().environmentObject(state)
        }
        .sheet(isPresented: $showStayLoggedInSheet) {
            PennKeyCredentialsSheet().environmentObject(state)
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
        .confirmationDialog(
            "delete my class data from lhf's server?",
            isPresented: $confirmingBackendDataDeletion,
            titleVisibility: .visible
        ) {
            Button("delete", role: .destructive) {
                Task { _ = await state.deleteBackendData() }
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("This removes your enrollment and shared course-material rows from LHF's server. Your assignments, completions and settings on this device stay.")
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
            Section {
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
                        .font(.lhfSecondary(12))
                        .foregroundStyle(Color.smoothTomatoInk)
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
                .font(.lhfSecondary(12))
                .foregroundStyle(stats.isHealthy ? Color.v2DateText : Color.smoothTomatoInk)

                // The specifics, when there are any. "Not saving" on its own
                // tells the user something is wrong but nothing about what —
                // and these two failures have completely different fixes
                // (reinstall vs. free up space), so naming them is the
                // difference between an actionable warning and a shrug.
                if let reason = stats.storageFailureReason {
                    Text(reason)
                        .font(.lhfSecondary(12))
                        .foregroundStyle(Color.smoothTomatoInk)
                }
                if stats.failedSaveCount > 0 {
                    Text("\(stats.failedSaveCount) change\(stats.failedSaveCount == 1 ? "" : "s") couldn't be written to storage. Check that your device isn't out of space.")
                        .font(.lhfSecondary(12))
                        .foregroundStyle(Color.smoothTomatoInk)
                }
            } header: {
                SmoothSectionHeader("storage", accent: .smoothCobalt)
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
    /// **Why the "ai assist" toggle only shows up with a backend
    /// configured.** There used to be a student-pasted Anthropic key here
    /// (`AnthropicKeyStore`, removed); now the AI path is LHF's own server
    /// (`BackendAnnouncementExtractor`), and with no key for a student to
    /// paste there is nothing this toggle could turn on when
    /// `BackendServices.client` is `nil` — showing it anyway would just be a
    /// switch that silently does nothing.
    @ViewBuilder
    private var announcementWatcherSection: some View {
        Section {
            Toggle("watch announcements", isOn: Binding(
                get: { state.announcementWatcherEnabled },
                set: { state.setAnnouncementWatcherEnabled($0) }
            ))

            if state.announcementWatcherEnabled, BackendServices.client != nil {
                Toggle("ai assist", isOn: Binding(
                    get: { state.announcementAIEnabled },
                    set: { state.setAnnouncementAIEnabled($0) }
                ))
            }
        } header: {
            SmoothSectionHeader("preferences", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothGrape)
    }

    // MARK: Reminders

    /// The **global** reminder configuration: whether due-date reminders run at
    /// all and which lead times they use. v4's Profile tab
    /// adds a per-class layer that inherits from exactly these values and
    /// overrides them class by class, which is why they stay in Settings rather
    /// than following the class list over to Profile — this is the default a
    /// student sets once, not the per-course tuning they revisit.
    @ViewBuilder
    private var remindersSection: some View {
        Section {
            Toggle("due-date reminders", isOn: Binding(
                get: { scheduler.isEnabled },
                set: { newValue in Task { await scheduler.setEnabled(newValue) } }
            ))

            if scheduler.isEnabled {
                if scheduler.authStatus == .denied {
                    Label("notifications are off in system settings.", systemImage: "bell.slash")
                        .font(.lhfSecondary(12))
                        .foregroundStyle(Color.v2DateText)
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

                }
            }
        } header: {
            SmoothSectionHeader("reminders", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothTomato)
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
                Text("restart Smooth to apply")
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.v2DateText)
            } else if state.cloudSyncEnabled, let reason = state.assignmentStore?.storageFailureReason {
                Text(reason)
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.smoothTomatoInk)
            }

            HStack(spacing: 8) {
                if state.isCourseKnowledgeSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state.courseKnowledge.isEmpty ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(state.courseKnowledge.isEmpty ? Color.v2DateText : Color.v2SpineGreen)
                }
                Text("course materials")
                Spacer()
                Text(courseKnowledgeSummary)
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.v2DateText)
            }

            if let notice = state.courseKnowledgeNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.smoothMarigoldInk)
            }

            if BackendServices.client != nil {
                Button("delete my class data from lhf's server", role: .destructive) {
                    confirmingBackendDataDeletion = true
                }
            }

            #if os(macOS)
            Toggle("open at login", isOn: Binding(
                get: {
                    _ = loginItemRefreshNonce
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
            #endif

            if let notice = state.syncNotice ?? state.error {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.smoothMarigoldInk)
            }

            DisclosureGroup("troubleshooting") {
                Button {
                    copyDiagnostics()
                } label: {
                    Label(didCopyDiagnostics ? "copied" : "copy diagnostics", systemImage: didCopyDiagnostics ? "checkmark" : "doc.on.doc")
                }
                Button {
                    reportProblem()
                } label: {
                    Label("report a problem", systemImage: "envelope")
                }

                #if DEBUG
                simulateCanvasLogoutRow
                probeEdDiscussionRow
                #endif
            }
        } header: {
            SmoothSectionHeader("sync", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothCobalt)
    }

    private var courseKnowledgeSummary: String {
        let knowledge = state.courseKnowledge
        guard let synced = knowledge.lastSyncedAt else { return "not synced" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: synced, relativeTo: Date())
        return "\(knowledge.documents.count) items · \(knowledge.courses.count) courses · \(when)"
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
            SmoothSectionHeader("on this mac", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothTeal)
    }
    #endif

    /// Copyable diagnostics report (docs/CANVAS_LOGIN_HARDENING.md item 3e) —
    /// meant to be pasted into a support message when Canvas login is stuck.
    /// Contains no credentials, cookie values, or the ICS feed URL/token —
    /// see `DiagnosticsReport`'s doc comment for exactly what's included.
    ///
    /// No longer also embeds `simulateCanvasLogoutRow` under `#if DEBUG` —
    /// that was a leftover from before the "testing" section above got its
    /// own home in the Form (see that section's own comment); with THIS
    /// section now placed too, keeping both would show the same row twice
    /// on the same page.
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
            SmoothSectionHeader("troubleshooting", accent: .smoothCobalt)
        }
    }

    #if DEBUG
    /// Owner-only "stay signed in" test seam (CLAUDE.md's "stay signed in"
    /// section, and `AppState.simulateCanvasLogoutForTesting()`'s own doc
    /// comment for the mechanism). Testing that feature against a REAL
    /// expiry means waiting roughly a day for Canvas's cookie to age out;
    /// this button kills the session on the spot so the owner can watch the
    /// whole silent-renewal chain — cookie purge, IdP-session purge (Duo's
    /// own cookie deliberately spared), throttle reset, renewal attempt —
    /// run in one tap on a real phone with a real Canvas login. Compiles out
    /// of every Release build; nothing here is reachable by a student.
    @ViewBuilder
    private var simulateCanvasLogoutRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                runSimulateCanvasLogout()
            } label: {
                if isSimulatingCanvasLogout {
                    HStack {
                        ProgressView()
                        Text("simulating canvas logout…")
                    }
                } else {
                    Label("simulate canvas logout", systemImage: "bolt.slash")
                }
            }
            .disabled(isSimulatingCanvasLogout)

            if let simulateCanvasLogoutResult, !isSimulatingCanvasLogout {
                Text(simulateCanvasLogoutResult)
                    .font(.lhfSecondary(12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A second tap while one attempt is still running is blocked by
    /// `.disabled(isSimulatingCanvasLogout)` above, rather than by anything
    /// in `AppState` — there's exactly one owner tapping this button, so a
    /// UI-level guard is enough; `CanvasSessionRenewer`'s own `isInFlight`
    /// guard (untouched by `resetThrottlesForTesting()`) would catch a
    /// genuine race anyway. The stale result is cleared before the new
    /// attempt starts, not after, so the row never shows an old string
    /// under a fresh spinner.
    private func runSimulateCanvasLogout() {
        simulateCanvasLogoutResult = nil
        isSimulatingCanvasLogout = true
        Task {
            let result = await state.simulateCanvasLogoutForTesting()
            simulateCanvasLogoutResult = result
            isSimulatingCanvasLogout = false
        }
    }

    /// Owner-only "probe ed discussion" row (CLAUDE.md's own name for this
    /// diagnostic) — see `AppState.probeEdDiscussionForTesting()`'s doc
    /// comment for what it actually does and the privacy rule it's built
    /// under (names only, never a storage/cookie value). Same
    /// resting/running/result shape as `simulateCanvasLogoutRow` above, plus
    /// a small "copy" button: the full report (per-course tab list, hop
    /// list, storage/cookie key names) is long enough that reading it off a
    /// phone screen is awkward, so `.textSelection(.enabled)` alone isn't
    /// enough to get it somewhere more useful.
    @ViewBuilder
    private var probeEdDiscussionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                runProbeEdDiscussion()
            } label: {
                if isProbingEdDiscussion {
                    HStack {
                        ProgressView()
                        Text("probing ed discussion…")
                    }
                } else {
                    Label("probe ed discussion", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
            .disabled(isProbingEdDiscussion)

            if let probeEdDiscussionResult, !isProbingEdDiscussion {
                Text(probeEdDiscussionResult)
                    .font(.lhfSecondary(12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Button {
                    copyProbeEdDiscussionResult()
                } label: {
                    Label(
                        didCopyProbeEdDiscussionResult ? "copied" : "copy probe result",
                        systemImage: didCopyProbeEdDiscussionResult ? "checkmark" : "doc.on.doc"
                    )
                }
                .font(.lhfSecondary(12))
            }
        }
    }

    /// Same single-flight guard as `runSimulateCanvasLogout` above, and the
    /// same reason for clearing the stale result before the new attempt
    /// starts rather than after.
    private func runProbeEdDiscussion() {
        probeEdDiscussionResult = nil
        didCopyProbeEdDiscussionResult = false
        isProbingEdDiscussion = true
        Task {
            let result = await state.probeEdDiscussionForTesting()
            probeEdDiscussionResult = result
            isProbingEdDiscussion = false
        }
    }

    /// Exactly `copyDiagnostics()`'s cross-platform pasteboard code below,
    /// applied to this row's own result string instead of a full
    /// diagnostics report.
    private func copyProbeEdDiscussionResult() {
        guard let probeEdDiscussionResult else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = probeEdDiscussionResult
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(probeEdDiscussionResult, forType: .string)
        #endif
        didCopyProbeEdDiscussionResult = true
    }
    #endif

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

    /// "Stay signed in" — the owner's decision (CLAUDE.md's "stay signed in"
    /// entry) to optionally store the student's PennKey password and use it
    /// to sign back into Canvas automatically. Off by default; lives inside
    /// the "accounts" section, right below the Canvas/Gradescope rows, since
    /// it's a property of the Canvas login specifically, not a general
    /// preference.
    ///
    /// Turning the toggle ON does NOT itself call
    /// `AppState.enableStayLoggedIn` — it only opens
    /// `PennKeyCredentialsSheet`, whose own "save" button is the one thing
    /// that actually turns the feature on (see that binding's `set` below).
    /// Turning it OFF calls `AppState.disableStayLoggedIn()` immediately,
    /// with no confirmation — unlike disconnecting a whole account, this
    /// only throws away a locally-stored password copy the student can
    /// re-enter in a few seconds, so the same "are you sure" friction that
    /// `disconnecting` guards elsewhere in this file isn't warranted here.
    @ViewBuilder
    private var stayLoggedInRows: some View {
        Toggle("stay signed in", isOn: Binding(
            get: { state.stayLoggedInEnabled },
            set: { newValue in
                if newValue {
                    showStayLoggedInSheet = true
                } else {
                    state.disableStayLoggedIn()
                }
            }
        ))
        .accessibilityHint("stores your PennKey password in this phone's keychain so Smooth can sign back in; it never leaves this phone")
        // Only while the toggle is on — a student who hasn't turned this on
        // has no reason to care how long Duo will keep skipping its own
        // prompt, since nothing here is auto-filling anything for them yet.
        if state.stayLoggedInEnabled, let duoSummary = state.duoRememberSummary {
            Text(duoSummary)
                .font(.lhfSecondary(12))
                .foregroundStyle(Color.v2DateText)
        }
        if let reason = state.autoLoginDisabledReason {
            Text(reason)
                .font(.lhfSecondary(12))
                .foregroundStyle(Color.smoothTomatoInk)
            Button("update password") {
                showStayLoggedInSheet = true
            }
        }
    }

    /// One tappable source row. Its trailing status says what is true; tapping
    /// the row performs the only relevant action: connect or disconnect.
    private func accountRow(label: String,
                            connected: Bool,
                            working: Bool,
                            disconnect target: DisconnectTarget) -> some View {
        Button {
            guard !working else { return }
            if connected {
                disconnecting = target
            } else {
                dismiss()
                state.restartOnboarding(for: target == .canvas ? .canvas : .gradescope)
            }
        } label: {
            HStack(spacing: 10) {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: connected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(connected ? Color.smoothTeal : Color.smoothMuted)
                }
                Text(label)
                    .foregroundStyle(Color.smoothInk)
                Spacer()
                Text(working ? "checking" : (connected ? "connected" : "not connected"))
                    .font(.lhfSecondary(12, weight: .medium))
                    .foregroundStyle(Color.smoothMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.smoothMuted)
            }
        }
        .buttonStyle(.plain)
        .disabled(working)
        .accessibilityElement(children: .combine)
        .accessibilityHint(connected ? "double tap to disconnect" : "double tap to connect")
    }
}
