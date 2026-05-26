import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var draftURL = ""
    @State private var isShowingGradescopeLogin = false
    @State private var isShowingCanvasScanSheet = false
    @State private var isShowingRecurringTask = false

    var body: some View {
        NavigationStack {
            Form {
                canvasSection
                gradescopeSection
                canvasScanSection
                recurringSection
                if state.error != nil || state.syncNotice != nil { statusSection }
                if state.lastSync != nil || state.lastGradescopeSync != nil { lastSyncSection }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .onAppear { draftURL = state.canvasICSURL }
        }
        .sheet(isPresented: $isShowingGradescopeLogin) {
            GradescopeLoginSheet().environmentObject(state)
        }
        .sheet(isPresented: $isShowingCanvasScanSheet) {
            CanvasRequirementScanSheet().environmentObject(state)
        }
        .sheet(isPresented: $isShowingRecurringTask) {
            RecurringTaskSheet().environmentObject(state)
        }
    }

    // MARK: – Sections

    private var canvasSection: some View {
        Section("Canvas Feed") {
            if state.canvasICSURL.isEmpty {
                TextField(
                    "https://canvas.upenn.edu/feeds/calendars/user_….ics",
                    text: $draftURL
                )
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif

                Button("Connect") {
                    state.updateCanvasICSURL(draftURL)
                    draftURL = state.canvasICSURL
                    Task { await state.sync() }
                }
                .disabled(draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                HStack {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    if state.isLoading { ProgressView().controlSize(.small) }
                }
                Button("Disconnect", role: .destructive) {
                    state.updateCanvasICSURL("")
                }
            }
        }
    }

    private var gradescopeSection: some View {
        Section("Gradescope") {
            Button {
                isShowingGradescopeLogin = true
            } label: {
                Label(
                    state.isGradescopeConnected ? "Connected — Reconnect" : "Connect Gradescope",
                    systemImage: state.isGradescopeConnected
                        ? "checkmark.circle.fill" : "person.crop.circle.badge.plus"
                )
                .foregroundStyle(state.isGradescopeConnected ? .green : .accentColor)
            }
            if state.isGradescopeLoading {
                HStack { ProgressView(); Text("Syncing…").foregroundStyle(.secondary) }
            }
        }
    }

    private var canvasScanSection: some View {
        Section("Canvas Scan") {
            Button {
                isShowingCanvasScanSheet = true
            } label: {
                Label(
                    state.isCanvasDiscoveryConnected ? "Connected — Rescan" : "Connect Canvas Scan",
                    systemImage: state.isCanvasDiscoveryConnected
                        ? "checkmark.circle.fill" : "text.magnifyingglass"
                )
                .foregroundStyle(state.isCanvasDiscoveryConnected ? .green : .accentColor)
            }
            if state.isCanvasDiscoveryLoading {
                HStack { ProgressView(); Text("Scanning…").foregroundStyle(.secondary) }
            }
        }
    }

    private var recurringSection: some View {
        Section("Recurring Tasks") {
            Button {
                isShowingRecurringTask = true
            } label: {
                Label("Manage Recurring Tasks", systemImage: "calendar.badge.plus")
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let notice = state.syncNotice {
                Label(notice, systemImage: "info.circle").foregroundStyle(.secondary)
            }
        } header: { Text("Status") }
    }

    private var lastSyncSection: some View {
        Section("Last Sync") {
            if let last = state.lastSync {
                LabeledContent("Canvas", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            if let last = state.lastGradescopeSync {
                LabeledContent("Gradescope", value: last.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }
}
