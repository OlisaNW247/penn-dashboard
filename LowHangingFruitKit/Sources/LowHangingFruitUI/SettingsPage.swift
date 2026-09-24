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
    /// Shown under the accounts rows when the server-side delete that
    /// disconnecting Canvas triggers didn't go through.
    @State private var backendDataDeletionError: String?
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
                return "Removes your Canvas login, saved PennKey password and synced assignments and grades from this device, and deletes your class data from Smooth's server. Your own tasks, completions and reminders stay."
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
                    if let backendDataDeletionError {
                        Label(backendDataDeletionError, systemImage: "exclamationmark.triangle")
                            .font(.lhfSecondary(12))
                            .foregroundStyle(Color.smoothTomatoInk)
                    }
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
                    case .canvas:
                        state.disconnectCanvas()
                        deleteServerData()
                    case .gradescope:
                        state.disconnectGradescope()
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .task { await scheduler.refreshAuthStatus() }
        .lhfSheetTheme()
        .frame(minWidth: 360, minHeight: 420)
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
                    ForEach(NotificationScheduler.LeadOffset.offered) { offset in
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
        } header: {
            SmoothSectionHeader("sync", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothCobalt)
    }

    /// "Delete my class data" used to be its own button (under
    /// troubleshooting, which is gone). It now rides on disconnecting
    /// Canvas: the student who takes their Canvas login off the device is
    /// the student who wants their server rows gone too, and docs/PRIVACY.md
    /// says so. A failure is reported here rather than swallowed, since
    /// the disconnect itself has already happened by then.
    private func deleteServerData() {
        guard BackendServices.client != nil else { return }
        backendDataDeletionError = nil
        Task {
            if !(await state.deleteBackendData()) {
                backendDataDeletionError = "couldn't delete your data from smooth's server. check your connection, then reconnect and disconnect again."
            }
        }
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

    /// "Stay signed in" repair row, inside the "accounts" section. The
    /// password itself is only ever entered in `PennKeyCredentialsSheet`,
    /// offered after an interactive Canvas login; this row appears only when
    /// Penn rejected the stored password and auto-login switched itself off.
    @ViewBuilder
    private var stayLoggedInRows: some View {
        // No on/off toggle any more (owner's call, 2026-09-24): staying
        // signed in is simply how Smooth works once a password has been
        // saved from the sign-in offer. What remains is the repair path —
        // without it a rejected password could never be re-entered.
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
