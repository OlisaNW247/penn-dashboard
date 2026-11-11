import SwiftUI
import LowHangingFruitKit

/// A searchable list of Penn's own program catalogue. Tap a row to see the
/// changes Path@Penn's page would allow for it, tap a change to run it.
///
/// Nothing is stored here but `@State`: the list comes from
/// `state.loadDegreePrograms()`, the plans from `state.degreeWhatIfPlans`, and
/// running one hands the plan back to `state.runWhatIf`. The sheet decides
/// nothing about which changes make sense; that is the page's rule, mirrored in
/// the Kit.
struct DegreeWhatIfSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var programs: [PathProgramListing] = []
    @State private var search = ""
    @State private var isLoadingList = false
    @State private var selected: PathProgramListing?
    @State private var plans: [PathWhatIfPlan] = []
    @State private var isLoadingPlans = false
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("what if")
                    .font(.lhfSerif(28))
                    .foregroundStyle(Color.smoothInk)
                    .accessibilityAddTraits(.isHeader)
                searchField
                if let selected {
                    planCard(selected)
                }
                list
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.smoothPaper.ignoresSafeArea())
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close") { dismiss() }
                }
            }
        }
        .environmentObject(state)
        .lhfSheetTheme()
        .task { await loadList() }
    }

    // MARK: Search

    private var searchField: some View {
        TextField("search programs", text: $search)
            .font(.lhfSans(14))
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.smoothSurface.opacity(0.58), in: Capsule())
            .overlay { Capsule().stroke(Color.smoothRule.opacity(0.72), lineWidth: 1.25) }
#if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#endif
    }

    /// Case- and diacritic-insensitive over the title and the code.
    private var filtered: [PathProgramListing] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return programs }
        return programs.filter { program in
            program.title.localizedStandardContains(needle) || program.code.localizedStandardContains(needle)
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if programs.isEmpty {
            emptyList
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { program in
                        Button { Task { await choose(program) } } label: {
                            HStack(spacing: 8) {
                                Text(program.title.lowercased())
                                    .font(.lhfSans(15, weight: selected?.code == program.code ? .semibold : .regular))
                                    .foregroundStyle(Color.smoothInk)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Text(program.code)
                                    .font(.lhfMono(11))
                                    .foregroundStyle(Color.smoothMuted)
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.smoothRule.opacity(0.6))
                    }
                }
            }
        }
    }

    private var emptyList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let text = state.degreeStatus.line(now: Date()) {
                Text(text)
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.smoothMuted)
            }
            if isLoadingList {
                ProgressView()
            } else {
                Button { Task { await loadList() } } label: {
                    Text("retry")
                        .font(.lhfSans(14, weight: .semibold))
                        .foregroundStyle(Color.smoothInk)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.smoothSurface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Plans

    private func planCard(_ program: PathProgramListing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(program.title.lowercased())
                .font(.lhfSans(15, weight: .semibold))
                .foregroundStyle(Color.smoothInk)
                .fixedSize(horizontal: false, vertical: true)
            if isLoadingPlans {
                ProgressView()
            } else if plans.isEmpty {
                Text("path@penn has no what-if for this one")
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.smoothMuted)
            } else {
                ForEach(plans) { plan in
                    Button { run(plan) } label: {
                        Text(label(for: plan, program: program))
                            .font(.lhfSans(14, weight: .semibold))
                            .foregroundStyle(Color.smoothGrapeInk)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.smoothGrape.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning)
                }
            }
            if isRunning {
                ProgressView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.smoothRule, lineWidth: 1) }
    }

    /// "switch to computer engineering bse" for a new program; "add minor" and
    /// the other additions say what they add and nothing more.
    private func label(for plan: PathWhatIfPlan, program: PathProgramListing) -> String {
        switch plan.change {
        case .newProgram:
            return "\(plan.change.label) \(program.title.lowercased())"
        case .addMajor, .addMinor, .addConcentration:
            return plan.change.label
        }
    }

    // MARK: Actions

    private func loadList() async {
        isLoadingList = true
        let result = await state.loadDegreePrograms()
        programs = result
        isLoadingList = false
    }

    private func choose(_ program: PathProgramListing) async {
        selected = program
        plans = []
        isLoadingPlans = true
        let result = await state.degreeWhatIfPlans(for: program.code)
        // A later tap may have replaced this one while the plans loaded.
        guard selected?.code == program.code else { return }
        plans = result
        isLoadingPlans = false
    }

    private func run(_ plan: PathWhatIfPlan) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            await state.runWhatIf(plan)
            isRunning = false
            dismiss()
        }
    }
}
