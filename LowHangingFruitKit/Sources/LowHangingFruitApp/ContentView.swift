import SwiftUI
import LowHangingFruitKit

/// Redesigned root screen: header (wordmark + date + weekly ring), a three-way
/// segmented toggle, and a timeline/done list. All data is read through
/// `DashboardViewModel`, which layers on top of the untouched `AppState`.
struct ContentView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm: DashboardViewModel

    @State private var filter: DashFilter = .thisWeek
    @State private var editing: DashItem?
    @State private var showSettings = false

    init(previewVM: DashboardViewModel? = nil) {
        _vm = StateObject(wrappedValue: previewVM ?? DashboardViewModel())
    }

    var body: some View {
        let progress = vm.weeklyProgress()

        VStack(spacing: 0) {
            header(progress: progress)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            SegmentedToggle(selection: $filter)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)

            ScrollView {
                listContent
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 40)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.items)
            }
        }
        .background(Color.v2Bg.ignoresSafeArea())
        .onAppear { vm.bind(to: state) }
        .sheet(item: $editing) { item in
            EditDueSheet(
                assignment: item.assignment,
                overrideDate: Binding(
                    get: { vm.items.first(where: { $0.id == item.id })?.dueOverride },
                    set: { vm.setDue(item, to: $0) }
                )
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet().environmentObject(state)
        }
    }

    // MARK: Header

    private func header(progress: (done: Int, total: Int)) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LHF")
                    .font(.lhfSerif(27))
                    .foregroundStyle(Color.v2Ink)

                HStack(spacing: 8) {
                    Text(Self.dateText(Date()))
                        .font(.lhfSerif(15))
                        .foregroundStyle(Color.v2DateText)

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.v2DateText.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Settings & accounts")
                }
            }

            Spacer()

            ProgressRingView(done: progress.done, total: progress.total)
        }
    }

    // MARK: List

    @ViewBuilder
    private var listContent: some View {
        switch filter {
        case .thisWeek: timeline(sections: vm.thisWeekSections())
        case .all:      timeline(sections: vm.allSections())
        case .done:
            DoneView(
                sections: vm.doneSections(),
                weeklyDone: vm.weeklyProgress().done,
                onUncomplete: { item in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        vm.uncomplete(item)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func timeline(sections: [DashSection]) -> some View {
        if sections.isEmpty {
            allDoneState
        } else {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(sections) { section in
                    TimelineSectionView(
                        section: section,
                        onComplete: { item in
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                vm.complete(item)
                            }
                        },
                        onEdit: { item in editing = item }
                    )
                }
            }
        }
    }

    private var allDoneState: some View {
        Text("all done.")
            .font(.lhfSerif(28))
            .foregroundStyle(Color.v2DateText.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.top, 120)
    }

    // MARK: Date

    private static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"   // "Tuesday, May 26"
        return f.string(from: date)
    }
}

#if DEBUG
#Preview {
    let vm = DashboardViewModel()
    vm.loadSampleData()
    return ContentView(previewVM: vm)
        .environmentObject(AppState())
        .frame(width: 430, height: 880)
}
#endif
