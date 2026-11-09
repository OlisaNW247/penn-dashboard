import SwiftUI
import LowHangingFruitKit

/// The stepped picker behind "switch or add…" and, in `.currentGoals` mode,
/// behind "pick your degree" (the one time Degree Works does not say which
/// degree the student is in). Program, degree, major, then concentration and
/// minor, which can be skipped; every list comes from Degree Works' own goals
/// endpoint through `state.loadDegreeCatalog`, re-asked after each pick because
/// the later lists narrow to what the earlier choices allow.
///
/// Nothing is stored here but `@State`: the draft lives until "run".
struct DegreeWhatIfSheet: View {
    enum Mode {
        case whatIf
        case currentGoals

        var title: String { self == .whatIf ? "what if" : "your degree" }
    }

    let mode: Mode

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .program
    @State private var draft = DegreeGoals()
    @State private var catalog: DegreeGoalCatalog?
    @State private var search = ""
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var reloadToken = 0

    init(mode: Mode) {
        self.mode = mode
    }

    private enum Step: Int, CaseIterable {
        case program, degree, major, concentration, minor, run

        var label: String {
            switch self {
            case .program: return "program"
            case .degree: return "degree"
            case .major: return "major"
            case .concentration: return "concentration"
            case .minor: return "minor"
            case .run: return "run"
            }
        }

        var isOptional: Bool { self == .concentration || self == .minor }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                topBar
                dots
                Text(step.label)
                    .font(.lhfSerif(28))
                    .foregroundStyle(Color.smoothInk)
                if step == .run {
                    runStep
                } else {
                    searchField
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
        .task(id: reloadToken) { await reload() }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            if step != .program {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.smoothInk)
                        .frame(width: 32, height: 32)
                        .background(Color.smoothSurface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("back")
            }
            Text(mode.title)
                .font(.lhfMono(11, weight: .semibold))
                .foregroundStyle(Color.smoothGrapeInk)
            Spacer()
        }
    }

    /// Five dots, one per choice; the run step lights all of them.
    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { index in
                Circle()
                    .fill(index <= step.rawValue ? Color.smoothTeal : Color.smoothRule)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }

    private var searchField: some View {
        TextField("search", text: $search)
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

    // MARK: List

    private var choices: [GoalChoice] {
        let source = catalog ?? .empty
        let all: [GoalChoice]
        switch step {
        case .program: all = source.programs
        case .degree: all = source.degrees
        case .major: all = source.majors
        case .concentration: all = source.concentrations
        case .minor: all = source.minors
        case .run: all = []
        }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.description.lowercased().contains(needle) || $0.key.lowercased().contains(needle) }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if step.isOptional {
                    Button(action: skip) {
                        Text("skip")
                            .font(.lhfSans(15, weight: .semibold))
                            .foregroundStyle(Color.smoothTealInk)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color.smoothRule)
                }
                if isLoading && catalog == nil {
                    HStack { ProgressView() }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if loadFailed && catalog == nil {
                    Button { reloadToken += 1 } label: {
                        Text("couldn't load the list · retry")
                            .font(.lhfSans(14))
                            .foregroundStyle(Color.smoothMuted)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(choices) { choice in
                        Button { pick(choice) } label: {
                            HStack(spacing: 8) {
                                Text(choice.description.lowercased())
                                    .font(.lhfSans(15))
                                    .foregroundStyle(Color.smoothInk)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Text(choice.key)
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

    // MARK: Run

    private var headline: String {
        let descriptions = DegreeProgressMath.descriptions(catalog ?? state.degree.catalog)
        switch mode {
        case .whatIf:
            return DegreeWhatIf.headline(current: state.degree.current?.goals, target: draft, descriptions: descriptions)
        case .currentGoals:
            return draft.title(descriptions: descriptions)
        }
    }

    private var runStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(headline)
                .font(.lhfSans(17, weight: .semibold))
                .foregroundStyle(Color.smoothInk)
            Button(action: run) {
                Text("run")
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 11)
                    .background(Color.smoothTeal, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Actions

    private func pick(_ choice: GoalChoice) {
        switch step {
        case .program: draft.program = choice.key
        case .degree: draft.degree = choice.key
        case .major: draft.majors = [choice.key]
        case .concentration: draft.concentrations = [choice.key]
        case .minor: draft.minors = [choice.key]
        case .run: return
        }
        advance()
    }

    private func skip() {
        switch step {
        case .concentration: draft.concentrations = []
        case .minor: draft.minors = []
        default: return
        }
        advance()
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        search = ""
        step = next
        // The later lists narrow to the earlier choices, so ask again.
        if next != .run { reloadToken += 1 }
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        // Going back forgets this step's choice and every later one.
        if previous.rawValue <= Step.program.rawValue { draft.program = nil }
        if previous.rawValue <= Step.degree.rawValue { draft.degree = nil }
        if previous.rawValue <= Step.major.rawValue { draft.majors = [] }
        if previous.rawValue <= Step.concentration.rawValue { draft.concentrations = [] }
        if previous.rawValue <= Step.minor.rawValue { draft.minors = [] }
        search = ""
        step = previous
        reloadToken += 1
    }

    private func run() {
        let goals = draft
        let chosen = mode
        Task {
            switch chosen {
            case .whatIf: await state.runWhatIf(goals)
            case .currentGoals: await state.pickCurrentGoals(goals)
            }
        }
        dismiss()
    }

    private func reload() async {
        isLoading = true
        loadFailed = false
        let result = await state.loadDegreeCatalog(selected: draft)
        if let result {
            catalog = result
        } else {
            loadFailed = true
        }
        isLoading = false
    }
}
