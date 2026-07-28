#if os(macOS)
import SwiftUI

/// The Mac dashboard's left rail. The iPhone keeps its stacked header and pill
/// toggle; on a landscape MacBook screen those become this fixed sidebar —
/// wordmark, serif greeting, the weekly ring (which lost its header spot on
/// iPhone), the three views as a vertical nav list with counts, and the
/// Settings/Grades routes pinned at the bottom. Deliberately a hand-built rail
/// rather than `NavigationSplitView`: the system sidebar's material chrome
/// fights the app's paper look, and the v2 tokens already carry light/dark.
///
/// There's no Sync button on purpose — the dashboard auto-refreshes on open,
/// activation and a 5-minute loop (see `ContentView.refresh`), so the rail
/// only *reports* freshness ("Synced 3 minutes ago").
struct MacDashboardSidebar: View {
    let greeting: String
    let dateText: String
    let progress: (done: Int, total: Int)
    let counts: (thisWeek: Int, all: Int, done: Int)
    @Binding var filter: DashFilter
    let showGrades: Bool
    let lastSync: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LHF")
                .font(.lhfSans(11, weight: .semibold))
                .tracking(2)
                .foregroundStyle(Color.v2CourseCode)

            Text(greeting)
                .font(.lhfSerif(28))
                .foregroundStyle(Color.v2Ink)
                .padding(.top, 4)

            Text(dateText)
                .font(.lhfSerif(15))
                .foregroundStyle(Color.v2DateText)
                .padding(.top, 2)

            ringRow
                .padding(.vertical, 22)

            VStack(spacing: 2) {
                navItem(.thisWeek, label: "This week", count: counts.thisWeek)
                navItem(.all, label: "All", count: counts.all)
                navItem(.done, label: "Done", count: counts.done)
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 2) {
                if showGrades {
                    routeRow(.grades, icon: "chart.line.uptrend.xyaxis", title: "Grades")
                }
                routeRow(.settings, icon: "gearshape.fill", title: "Settings")

                Text(syncText)
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
                    .padding(.top, 10)
                    .padding(.leading, 12)
            }
        }
        .padding(20)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.v2DoneCard)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.v2Divider).frame(width: 1)
        }
    }

    private var ringRow: some View {
        HStack(spacing: 12) {
            ProgressRingView(done: progress.done, total: progress.total, diameter: 64)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(progress.done) of \(progress.total) done")
                    .font(.lhfSans(13, weight: .semibold))
                    .foregroundStyle(Color.v2Ink)
                Text("this week")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2RingSub)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(progress.done) of \(progress.total) done this week")
    }

    /// One view-switcher row. Selected state mirrors the pill toggle's look:
    /// ink capsule, paper text.
    private func navItem(_ value: DashFilter, label: String, count: Int) -> some View {
        let selected = filter == value
        return Button { filter = value } label: {
            HStack(spacing: 10) {
                Text(label)
                    .font(.lhfSans(14, weight: selected ? .semibold : .medium))
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.lhfSans(12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.v2ToggleActiveTx.opacity(0.7) : Color.v2SectionCount)
            }
            .foregroundStyle(selected ? Color.v2ToggleActiveTx : Color.v2DateText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.v2Ink : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(count) items")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A pushed destination (Settings / Grades) — same `DashRoute` values the
    /// iPhone header buttons use, so both platforms share one navigation model.
    private func routeRow(_ route: ContentView.DashRoute, icon: String, title: String) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(.lhfSans(13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.v2DateText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var syncText: String {
        guard let lastSync else { return "Not synced yet" }
        return "Synced \(relativeTimeString(lastSync))"
    }
}
#endif
