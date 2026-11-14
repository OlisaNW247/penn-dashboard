import SwiftUI
import LowHangingFruitKit

/// A typed, sectioned search over Penn's own program catalogue. Concentrations,
/// majors and minors are headed apart, and each row says in one line what
/// choosing it does ("concentration · wharton", "major · instead of computer
/// science"). A row that is one of the student's own degree's siblings runs at
/// once; any other row opens, right under itself, the changes Path@Penn's page
/// would allow for it.
///
/// The search runs on the phone, over the catalogue the snapshot already
/// holds, and nothing typed here leaves it. When a query finds little, the
/// on-device language model (where the device has one) is asked only for
/// subject names, and those names are then looked up in Penn's catalogue: the
/// model never supplies a row, so nothing it says is shown unless Penn lists
/// it. Without the model the same slot is filled by a looser text match.
///
/// Results are never computed in `body`. They live in `@State`, recomputed by
/// one `.task(id:)` keyed on the inputs; SwiftUI cancels the previous task
/// when the key changes, which is both the debounce and the cancellation of a
/// model call whose question has already moved on.
struct DegreeWhatIfSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// What the results depend on; a change cancels and restarts the task.
    private struct SearchKey: Hashable {
        let text: String
        let scope: DegreeProgramKind?
        let touched: Bool
        let count: Int
    }

    @State private var entries: [DegreeProgramEntry] = []
    @State private var results: [DegreeSearchSection] = []
    @State private var related: [DegreeProgramEntry] = []
    @State private var relatedFromModel = false
    @State private var isAssisting = false

    @State private var search = ""
    @State private var scope: DegreeProgramKind?
    @State private var scopeTouched = false
    @State private var isLoadingList = false
    @FocusState private var searchFocused: Bool

    @State private var selected: DegreeProgramEntry?
    @State private var plans: [PathWhatIfPlan] = []
    @State private var isLoadingPlans = false
    @State private var runningID: String?
    @State private var runFailed = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("what if")
                    .font(.lhfSerif(28))
                    .foregroundStyle(Color.smoothInk)
                    .accessibilityAddTraits(.isHeader)
                if entries.isEmpty {
                    emptyList
                } else {
                    searchField
                    if runFailed, let text = state.degreeStatus.line(now: Date()) {
                        Text(text)
                            .font(.lhfSans(12))
                            .foregroundStyle(Color.smoothMuted)
                    }
                    scopeChips
                    list
                }
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
        .task {
            await loadList()
            searchFocused = true
        }
        .task(id: SearchKey(text: search, scope: scope, touched: scopeTouched, count: entries.count)) {
            await recompute()
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Color.smoothMuted)
            TextField("search concentrations, majors, minors", text: $search)
                .font(.lhfSans(14))
                .textFieldStyle(.plain)
                .focused($searchFocused)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif
            if !search.isEmpty {
                Button {
                    search = ""
                    scope = nil
                    scopeTouched = false
                    runFailed = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.smoothMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.smoothSurface.opacity(0.58), in: Capsule())
        .overlay { Capsule().stroke(Color.smoothRule.opacity(0.72), lineWidth: 1.25) }
        .onChange(of: search) { _, _ in runFailed = false }
    }

    /// The scope the results use: the student's own chip once touched, else
    /// whatever the words typed name ("math minor" lights the minors chip).
    private var effectiveScope: DegreeProgramKind? {
        scopeTouched ? scope : DegreeProgramSearch.parse(search).kind
    }

    private var scopeChips: some View {
        let present = Set(entries.map(\.kind))
        let kinds: [DegreeProgramKind] = [.concentration, .major, .minor].filter { present.contains($0) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                scopeChip("all", isOn: effectiveScope == nil) {
                    scope = nil
                    scopeTouched = true
                }
                ForEach(kinds, id: \.self) { kind in
                    scopeChip(kind.heading, isOn: effectiveScope == kind) {
                        scope = kind
                        scopeTouched = true
                    }
                }
            }
        }
    }

    private func scopeChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.lhfSans(13, weight: isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? Color.smoothGrapeInk : Color.smoothMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isOn ? Color.smoothGrape.opacity(0.18) : Color.clear, in: Capsule())
                .overlay { Capsule().stroke(Color.smoothRule, lineWidth: isOn ? 0 : 1) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(results) { section in
                    Text(section.kind.heading)
                        .font(.lhfSans(13, weight: .semibold))
                        .foregroundStyle(Color.smoothMuted)
                        .padding(.top, 14)
                        .padding(.bottom, 2)
                    ForEach(section.entries) { entry in
                        row(entry)
                    }
                }
                if isAssisting || !related.isEmpty {
                    HStack(spacing: 6) {
                        Text("related")
                            .font(.lhfSans(13, weight: .semibold))
                            .foregroundStyle(Color.smoothMuted)
                        if relatedFromModel {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.smoothMuted)
                        }
                        if isAssisting {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 2)
                    ForEach(related) { entry in
                        row(entry)
                    }
                }
                if results.isEmpty, related.isEmpty, !isAssisting,
                   !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("no match")
                        .font(.lhfSans(13))
                        .foregroundStyle(Color.smoothMuted)
                        .padding(.top, 14)
                }
            }
        }
    }

    private func dotColor(_ kind: DegreeProgramKind) -> Color {
        switch kind {
        case .concentration: return Color.smoothGrape
        case .major: return Color.smoothCobalt
        case .minor: return Color.smoothTeal
        case .other: return Color.smoothRule
        }
    }

    private func row(_ entry: DegreeProgramEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { Task { await tap(entry) } } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .font(.lhfSans(15, weight: selected?.id == entry.id ? .semibold : .regular))
                            .foregroundStyle(Color.smoothInk)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(dotColor(entry.kind))
                                .frame(width: 6, height: 6)
                            Text(DegreeProgramSearch.actionLine(for: entry))
                                .font(.lhfSans(12))
                                .foregroundStyle(Color.smoothMuted)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing(entry)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(runningID != nil)
            if selected?.id == entry.id, !entry.isSibling {
                plansView(entry)
                    .padding(.bottom, 12)
            }
            Divider().overlay(Color.smoothRule.opacity(0.6))
        }
    }

    @ViewBuilder
    private func trailing(_ entry: DegreeProgramEntry) -> some View {
        if runningID == entry.id {
            ProgressView().controlSize(.mini)
        } else if let percent = scoreText(entry) {
            Text(percent)
                .font(.lhfMono(11))
                .foregroundStyle(Color.smoothGrapeInk)
        } else {
            Text(entry.listing.code)
                .font(.lhfMono(11))
                .foregroundStyle(Color.smoothMuted)
        }
    }

    private func scoreText(_ entry: DegreeProgramEntry) -> String? {
        guard entry.isSibling, let degreeID = entry.degreeID,
              let score = state.degree.optionScores[
                DegreeOptions.scoreKey(degreeID: degreeID, programCode: entry.listing.code)]
        else { return nil }
        return "\(Int((score.fraction * 100).rounded()))%"
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

    /// The changes for the chosen row, shown under it. The one the typed words
    /// point at ("add minor" after typing "minor") is first and filled.
    private func plansView(_ entry: DegreeProgramEntry) -> some View {
        let query = DegreeProgramSearch.parse(search)
        let preferred = DegreeProgramSearch.preferredPlan(plans, for: query)
        let ordered: [PathWhatIfPlan] = {
            guard let preferred else { return plans }
            return [preferred] + plans.filter { $0.id != preferred.id }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            if isLoadingPlans {
                ProgressView()
            } else if plans.isEmpty {
                Text("path@penn has no what-if for this one")
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.smoothMuted)
            } else {
                ForEach(ordered) { plan in
                    let isPreferred = preferred?.id == plan.id
                    Button { run(plan, entry: entry) } label: {
                        Text(label(for: plan, entry: entry))
                            .font(.lhfSans(14, weight: .semibold))
                            .foregroundStyle(isPreferred ? Color.smoothInk : Color.smoothGrapeInk)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(isPreferred ? Color.smoothGrape : Color.smoothGrape.opacity(0.18),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(runningID != nil)
                }
            }
        }
    }

    /// "switch to computer engineering bse" for a new program; "add minor" and
    /// the other additions say what they add and nothing more.
    private func label(for plan: PathWhatIfPlan, entry: DegreeProgramEntry) -> String {
        switch plan.change {
        case .newProgram:
            return "switch to \(entry.name)"
        case .addMajor, .addMinor, .addConcentration:
            return plan.change.label
        }
    }

    // MARK: Actions

    private func loadList() async {
        isLoadingList = true
        let programs = await state.loadDegreePrograms()
        entries = state.degreeProgramEntries(programs)
        isLoadingList = false
    }

    /// Recomputes everything the list shows from the inputs. Runs inside
    /// `.task(id:)`, so a newer keystroke cancels this one at its next
    /// suspension point.
    private func recompute() async {
        let typed = DegreeProgramSearch.parse(search)
        let effective = scopeTouched ? scope : typed.kind
        // The Kit reads a nil scope as "use the kind the words named". Once
        // the student has tapped a chip, the chip is the answer, "all"
        // included, so the kind is taken off the query and only the chip
        // decides; otherwise "all" would light up over a list still filtered
        // to minors.
        let query = scopeTouched
            ? DegreeSearchQuery(tokens: typed.tokens, kind: nil, change: typed.change)
            : typed
        let direct = DegreeProgramSearch.search(query, in: entries, scope: effective)
        results = DegreeProgramSearch.sections(direct)
        related = []
        relatedFromModel = false
        isAssisting = false
        guard DegreeSearchAssist.shouldAsk(query, resultCount: direct.count) else { return }
        let shown = Set(direct.map(\.id))
        try? await Task.sleep(nanoseconds: 500_000_000)
        if Task.isCancelled { return }
        if OnDeviceLanguageModel.isAvailable {
            isAssisting = true
            let names = entries.filter { $0.kind == .concentration }.map(\.name)
            let reply = await OnDeviceLanguageModel.reply(
                instructions: DegreeSearchAssist.instructions,
                prompt: DegreeSearchAssist.prompt(request: search, optionNames: names))
            if Task.isCancelled { return }
            isAssisting = false
            let terms = reply.map(DegreeSearchAssist.terms(fromReply:)) ?? []
            let found = DegreeProgramSearch.related(
                terms: terms, in: entries, scope: effective, excluding: shown, limit: 8)
            if !found.isEmpty {
                related = found
                relatedFromModel = true
                return
            }
        }
        related = DegreeProgramSearch.loose(query, in: entries, scope: effective, excluding: shown, limit: 8)
    }

    private func tap(_ entry: DegreeProgramEntry) async {
        guard runningID == nil else { return }
        runFailed = false
        if entry.isSibling {
            runningID = entry.id
            let ok = await state.runDegreeEntry(entry)
            runningID = nil
            if ok { dismiss() } else { runFailed = true }
            return
        }
        selected = entry
        plans = []
        isLoadingPlans = true
        let result = await state.degreeWhatIfPlans(for: entry.listing.code)
        // A later tap may have replaced this one while the plans loaded.
        guard selected?.id == entry.id else { return }
        plans = result
        isLoadingPlans = false
    }

    private func run(_ plan: PathWhatIfPlan, entry: DegreeProgramEntry) {
        guard runningID == nil else { return }
        runningID = entry.id
        Task {
            if let id = entry.degreeID, id != state.selectedStudentDegree?.id {
                await state.selectDegree(id)
            }
            await state.runWhatIf(plan)
            runningID = nil
            dismiss()
        }
    }
}
