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
                }

                Section("Tasks") {
                    Button {
                        showRecurring = true
                    } label: {
                        Label("Add recurring task", systemImage: "calendar.badge.plus")
                    }
                }

                remindersSection

                if !state.canvasRequirementSuggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(state.canvasRequirementSuggestions) { suggestion in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(suggestion.title) · \(suggestion.course)")
                                    .font(.lhfSans(13, weight: .medium))
                                Text("\(suggestion.source.rawValue): \(suggestion.evidence)")
                                    .font(.lhfSans(11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                HStack {
                                    Button("Add") { state.addCanvasSuggestion(suggestion) }
                                    Button("Ignore", role: .destructive) {
                                        state.dismissCanvasSuggestion(suggestion)
                                    }
                                }
                                .font(.lhfSans(12, weight: .medium))
                                .padding(.top, 2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                #if DEBUG
                Section("Debug") {
                    Button("Load sample data") { state.loadSampleData() }
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
        .frame(minWidth: 360, minHeight: 420)
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
