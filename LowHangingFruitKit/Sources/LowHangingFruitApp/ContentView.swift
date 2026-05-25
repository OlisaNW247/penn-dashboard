import SwiftUI
import LowHangingFruitKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var isShowingRecurringTaskSheet = false

    var body: some View {
        VStack(spacing: 0) {
            setupStrip
            if let notice = state.syncNotice { noticeBar(notice) }
            if !state.canvasRequirementSuggestions.isEmpty { suggestionBar }
            DashboardView()
                .environmentObject(state)
        }
        .sheet(isPresented: $isShowingRecurringTaskSheet) {
            RecurringTaskSheet().environmentObject(state)
        }
    }

    // MARK: Setup strip

    @ViewBuilder
    private var setupStrip: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                statusDot(label: "Canvas",     connected: state.isCanvasConnected,     working: state.isLoading || state.isCanvasDiscoveryLoading)
                statusDot(label: "Gradescope", connected: state.isGradescopeConnected, working: state.isGradescopeLoading)

                Spacer()

                if !state.isCanvasConnected || !state.isGradescopeConnected {
                    Button {
                        state.restartOnboarding()
                    } label: {
                        Label("Connect accounts", systemImage: "link")
                    }
                }

                Button {
                    isShowingRecurringTaskSheet = true
                } label: {
                    Label("Recurring", systemImage: "calendar.badge.plus")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.lhfBg)

        Divider()
    }

    private func statusDot(label: String, connected: Bool, working: Bool) -> some View {
        HStack(spacing: 5) {
            if working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: connected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(connected ? .green : .secondary)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Notice / suggestion bars

    private func noticeBar(_ notice: String) -> some View {
        Group {
            HStack {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
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
