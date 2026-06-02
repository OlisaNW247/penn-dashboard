import SwiftUI
import LowHangingFruitKit

/// Houses everything that used to clutter the main screen: connection status,
/// reconnect, recurring-task entry, and Canvas requirement suggestions. The
/// main dashboard stays just header + ring + toggle + list.
struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showRecurring = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Accounts") {
                    statusRow(label: "Canvas",
                              connected: state.isCanvasConnected,
                              working: state.isLoading || state.isCanvasDiscoveryLoading)
                    statusRow(label: "Gradescope",
                              connected: state.isGradescopeConnected,
                              working: state.isGradescopeLoading)

                    if !state.isCanvasConnected || !state.isGradescopeConnected {
                        Button {
                            dismiss()
                            state.restartOnboarding()
                        } label: {
                            Label("Connect accounts", systemImage: "link")
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
        }
        .frame(minWidth: 360, minHeight: 420)
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
