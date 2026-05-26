import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        #if os(iOS)
        DashboardView().environmentObject(state)
        #else
        MacOSShell().environmentObject(state)
        #endif
    }
}

// MARK: – macOS shell (setup strip + DashboardView)

#if os(macOS)
private struct MacOSShell: View {
    @EnvironmentObject var state: AppState
    @State private var draftCanvasICSURL = ""
    @State private var isShowingGradescopeLogin = false
    @State private var isShowingRecurringTaskSheet = false
    @State private var isShowingCanvasScanSheet = false

    var body: some View {
        VStack(spacing: 0) {
            setupStrip
            Divider()
            if let notice = state.syncNotice { noticeBar(notice) }
            if !state.canvasRequirementSuggestions.isEmpty { suggestionBar }
            DashboardView().environmentObject(state)
        }
        .onAppear { draftCanvasICSURL = state.canvasICSURL }
        .sheet(isPresented: $isShowingGradescopeLogin) {
            GradescopeLoginSheet().environmentObject(state)
        }
        .sheet(isPresented: $isShowingRecurringTaskSheet) {
            RecurringTaskSheet().environmentObject(state)
        }
        .sheet(isPresented: $isShowingCanvasScanSheet) {
            CanvasRequirementScanSheet().environmentObject(state)
        }
    }

    private var setupStrip: some View {
        VStack(spacing: 6) {
            if state.canvasICSURL.isEmpty {
                HStack(spacing: 8) {
                    TextField(
                        "Canvas Calendar Feed URL (https://canvas.upenn.edu/feeds/calendars/user_….ics)",
                        text: $draftCanvasICSURL
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveCanvasFeedURL() }

                    Button { saveCanvasFeedURL() } label: {
                        Label("Connect Canvas", systemImage: "calendar.badge.checkmark")
                    }
                    .disabled(draftCanvasICSURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack(spacing: 10) {
                statusDot("Canvas Feed",  connected: !state.canvasICSURL.isEmpty,       working: state.isLoading)
                statusDot("Gradescope",   connected: state.isGradescopeConnected,       working: state.isGradescopeLoading)
                statusDot("Canvas Scan",  connected: state.isCanvasDiscoveryConnected,  working: state.isCanvasDiscoveryLoading)
                Spacer()
                if !state.isGradescopeConnected {
                    Button { isShowingGradescopeLogin = true } label: {
                        Label("Connect Gradescope", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                if !state.isCanvasDiscoveryConnected {
                    Button { isShowingCanvasScanSheet = true } label: {
                        Label("Canvas Scan", systemImage: "text.magnifyingglass")
                    }
                }
                Button { isShowingRecurringTaskSheet = true } label: {
                    Label("Recurring", systemImage: "calendar.badge.plus")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statusDot(_ label: String, connected: Bool, working: Bool) -> some View {
        HStack(spacing: 5) {
            if working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: connected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(connected ? .green : .secondary)
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func saveCanvasFeedURL() {
        state.updateCanvasICSURL(draftCanvasICSURL)
        draftCanvasICSURL = state.canvasICSURL
        Task { await state.sync() }
    }

    private func noticeBar(_ notice: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
        }
    }

    @ViewBuilder
    private var suggestionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.canvasRequirementSuggestions) { suggestion in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(suggestion.title) · \(suggestion.course)")
                            .font(.subheadline.weight(.medium))
                        Text("\(suggestion.source.rawValue): \(suggestion.evidence)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Ignore") { state.dismissCanvasSuggestion(suggestion) }
                    Button("Add")    { state.addCanvasSuggestion(suggestion) }
                }
            }
        }
        .padding(12)
        Divider()
    }
}
#endif
