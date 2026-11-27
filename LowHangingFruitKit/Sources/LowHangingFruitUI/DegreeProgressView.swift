import SwiftUI
import LowHangingFruitKit

/// The arithmetic behind the screen, kept out of the views so a test (and the
/// Profile row, which wants the same "31 of 40 cu") can ask it without
/// building any SwiftUI. Every number here is a reading of Degree Works'
/// own audit; nothing is computed that the audit did not already say, which is
/// why none of it ever produces a word like a verdict.
enum DegreeProgressMath {
    struct Ring: Equatable {
        var fraction: Double
        var extraFraction: Double
        var centre: String
        var caption: String
    }

    /// Every rule at every depth, `.info` left out (a note is not a
    /// requirement and must not count toward "n of N").
    static func countable(_ rules: [AuditRule]) -> [AuditRule] {
        var out: [AuditRule] = []
        for rule in rules {
            if rule.status != .info { out.append(rule) }
            out.append(contentsOf: countable(rule.children))
        }
        return out
    }

    /// "31", "31.5": whole credits print without a decimal.
    static func credits(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    /// "+3%" for what a course adds to the estimate; nil under half a point, because "+0%" reads as a verdict.
    static func gainBadge(_ points: Double) -> String? {
        guard points >= 0.5 else { return nil }
        return "+\(Int(min(points, 100).rounded()))%"
    }

    static func degreeBlock(of audit: DegreeAudit) -> AuditBlock? {
        audit.blocks.first { $0.type.uppercased() == "DEGREE" }
    }

    /// "NN%" from Penn's own percent, rounded and clamped.
    static func percentText(_ percent: Double) -> String {
        "\(Int(min(max(percent, 0), 100).rounded()))%"
    }

    /// "31 of 40 cu" when Penn's own sentence in the DEGREE block says it,
    /// else "NN%" from the audit's percent, else nil.
    static func creditLine(for audit: DegreeAudit) -> String? {
        if let totals = PathAuditDecoder.creditTotals(in: audit) {
            return "\(credits(totals.have)) of \(credits(totals.need)) cu"
        }
        if let percent = audit.percentComplete { return percentText(percent) }
        return nil
    }

    static func ring(for audit: DegreeAudit) -> Ring {
        let counts = audit.ruleCounts
        let total = counts.met + counts.inProgress + counts.open
        let denominator = Double(max(total, 1))
        let fallbackFraction = Double(counts.met) / denominator
        let fraction: Double
        let extra: Double
        if let percent = audit.percentComplete {
            fraction = min(max(percent / 100, 0), 1)
            extra = 0
        } else {
            fraction = fallbackFraction
            extra = Double(counts.inProgress) / denominator
        }
        if let totals = PathAuditDecoder.creditTotals(in: audit) {
            return Ring(fraction: fraction, extraFraction: extra,
                        centre: credits(totals.have), caption: "of \(credits(totals.need)) cu")
        }
        if let percent = audit.percentComplete {
            return Ring(fraction: fraction, extraFraction: extra, centre: percentText(percent), caption: "")
        }
        return Ring(fraction: fraction, extraFraction: extra,
                    centre: "\(counts.met)", caption: "of \(total) met")
    }

    /// A block Penn left empty: no rules, no percent, and a synthetic or
    /// not-applicable type ("Elective Coursework", "Exceptions Applied").
    static func isShown(_ block: AuditBlock) -> Bool {
        guard block.rules.isEmpty else { return true }
        let type = block.type.uppercased()
        guard type == "CL_SYNTHETIC_BLOCK" || type == "N/A" else { return true }
        return (block.percentComplete ?? 0) > 0
    }

    /// An `.info` rule with nothing under it is a sentence, drawn as a quiet note.
    static func isQuietNote(_ rule: AuditRule) -> Bool {
        rule.status == .info && rule.children.isEmpty && rule.applied.isEmpty && rule.advice.isEmpty
    }

    /// A block's loose courses: the synthetic "courses" rule has no label row.
    static func isLooseCourses(_ rule: AuditRule) -> Bool {
        rule.ruleType == "courses" && rule.label.lowercased() == "courses"
    }

    /// The right-hand count of a block row.
    static func blockCount(_ block: AuditBlock) -> String {
        let withCredits = block.rules.filter { ($0.needCredits ?? 0) > 0 }
        if !withCredits.isEmpty {
            let need = withCredits.reduce(0) { $0 + ($1.needCredits ?? 0) }
            let applied = withCredits.reduce(0) { $0 + ($1.appliedCredits ?? 0) }
            return "\(credits(applied)) of \(credits(need)) cu"
        }
        let rules = countable(block.rules)
        if rules.isEmpty, let percent = block.percentComplete { return percentText(percent) }
        let met = rules.filter { $0.status == .met }.count
        return "\(met) of \(rules.count)"
    }

    /// A block's count with the courses the plan lays against it. The plan
    /// never touches the "n of N" itself, which is Penn's reading.
    static func blockCount(_ block: AuditBlock, planned courses: Int) -> String {
        let base = blockCount(block)
        return courses > 0 ? "\(base) · \(courses) planned" : base
    }

    /// A rule's right-hand count: Penn's "n of N" only when the audit said how
    /// many courses the rule needs, then the planned courses beside it.
    static func ruleCountText(_ rule: AuditRule, planned: Int) -> String? {
        var base: String?
        if let need = rule.needCourses, need > 0 {
            base = "\(rule.appliedCount ?? rule.applied.count) of \(need)"
        }
        guard planned > 0 else { return base }
        if let base { return "\(base) · \(planned) planned" }
        return "\(planned) planned"
    }

    /// The projected percent under the ring. It is this app's estimate, not
    /// Penn's, which is why it carries "≈" and its own colour and never
    /// replaces the number in the middle of the ring.
    static func withPlanText(base: Double, gain: Double) -> String? {
        guard gain >= 0.005 else { return nil }
        return "≈ \(percentText(min(1, base + gain) * 100)) with plan"
    }

    /// The line or lines under the ring when the planner sent target data:
    /// "≈ 74% by spring 2028", then "≈ 83% if approved" only when the best
    /// case is meaningfully higher. Without a usable target term the first
    /// line reads "≈ 74% with plan". Empty when there is nothing to say.
    static func ringLines(base: Double, cases: DegreeRingCases, targetTerm: String?) -> [String] {
        guard cases.granted >= 0.005 || cases.showsBest else { return [] }
        var lines: [String] = []
        let granted = percentText(min(1, base + cases.granted) * 100)
        if let targetTerm, !targetTerm.isEmpty {
            lines.append("≈ \(granted) by \(DegreePlanMath.termLabel(targetTerm))")
        } else {
            lines.append("≈ \(granted) with plan")
        }
        if cases.showsBest {
            lines.append("≈ \(percentText(min(1, base + cases.best) * 100)) if approved")
        }
        return lines
    }

    /// Met and in-progress shares of a block's bar.
    static func blockShares(_ block: AuditBlock) -> (met: Double, inProgress: Double) {
        let rules = countable(block.rules)
        guard !rules.isEmpty else { return (0, 0) }
        let total = Double(rules.count)
        return (Double(rules.filter { $0.status == .met }.count) / total,
                Double(rules.filter { $0.status == .inProgress }.count) / total)
    }

    /// Degree block last, the others in the audit's own order.
    static func orderedBlocks(_ blocks: [AuditBlock]) -> [AuditBlock] {
        blocks.filter { $0.type.uppercased() != "DEGREE" } + blocks.filter { $0.type.uppercased() == "DEGREE" }
    }

    static func blockTitle(_ block: AuditBlock) -> String {
        block.type.uppercased() == "DEGREE" ? "everything else" : block.title.lowercased()
    }

    /// The right side of the Profile row: the same text the ring carries,
    /// "31 of 40 cu" or "NN%", else met rules.
    static func profileSummary(_ audit: DegreeAudit) -> String {
        if let line = creditLine(for: audit) { return line }
        let ring = ring(for: audit)
        return "\(ring.centre) \(ring.caption)"
    }
}

/// What one degree's bar and ring draw: Penn's own reading, and the layer the
/// plan adds on top. With the planner's target data it is the granted case
/// solid and, when meaningfully higher, the best case faded behind it, each
/// with its own line; otherwise the single "with plan" figure. The text counts
/// in-progress rules as done; the arc does not. Shared by the road's bars and
/// the requirements page, so a bar and its ring can never disagree.
struct DegreeDrawn {
    var ring: DegreeProgressMath.Ring
    var base: Double
    var projection: DegreeProjection
    var planned: Double
    var bestExtra: Double
    var lines: [String]
}

extension AppState {
    func degreeDrawn(degreeID: String, audit: DegreeAudit) -> DegreeDrawn {
        let ring = DegreeProgressMath.ring(for: audit)
        // Read from the body so a course added in the table redraws the bar.
        let projection = degreeProjection(degreeID: degreeID, audit: audit)
        let base = ring.fraction + (audit.isWhatIf ? ring.extraFraction : 0)
        if let cases = degreeRingCases(degreeID: degreeID, audit: audit, base: base) {
            let lines = DegreeProgressMath.ringLines(
                base: base, cases: cases, targetTerm: degreePlan.summary?.targetTerm)
            return DegreeDrawn(ring: ring, base: base, projection: projection, planned: cases.granted,
                               bestExtra: cases.showsBest ? max(0, cases.best - cases.granted) : 0,
                               lines: lines)
        }
        let line = DegreeProgressMath.withPlanText(base: base, gain: projection.withPlanGain(base: base))
        return DegreeDrawn(ring: ring, base: base, projection: projection,
                           planned: projection.ringGain(base: base), bestExtra: 0,
                           lines: line.map { [$0] } ?? [])
    }
}

/// A sheet the road opens: a semester's courses, or the add sheet for one.
enum DegreeRoadSheetTarget: Identifiable, Equatable {
    case semester(String)
    case add(String)

    var id: String {
        switch self {
        case .semester(let code): return "semester:" + code
        case .add(let code): return "add:" + code
        }
    }
}

/// The pushed degree page: one screen, "the road" (`DegreeRoadView`).
///
/// Reads only `state.degree`, `state.degreeStatus` and the plan; the one thing
/// it asks of the world is `refreshDegreeAudit`. Copy is the status words from
/// `DegreeStatus.line` and a handful of fixed lowercase labels, never a
/// sentence, and never a verdict: the page reports what Degree Works says
/// and links the official audit for anything that matters. This view owns every
/// sheet the road opens, because a sheet cannot present over another
/// presenter's sheet.
struct DegreeProgressView: View {
    @EnvironmentObject var state: AppState

    @State private var showWhatIf = false
    @State private var showAdvisor = false
    @State private var showAdvisorQuestions = false
    @State private var roadSheet: DegreeRoadSheetTarget?

    private var descriptions: [String: String] { state.degreeDescriptions }

    private var hasAudit: Bool { state.degree.current != nil || !state.degreeAudits.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if hasAudit {
                        DegreeRoadView(
                            openChat: { showAdvisor = true },
                            openSemester: { roadSheet = .semester($0) },
                            openAdd: { roadSheet = .add($0) },
                            openAdvisor: { showAdvisorQuestions = true })
                    } else {
                        emptyProgress
                    }
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .refreshable { await state.refreshDegreeAudit(force: true, userInitiated: true) }
            .overlay(alignment: .bottomTrailing) {
                if state.degreeAdvisorAvailable {
                    Button { showAdvisor = true } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.smoothInk)
                            .frame(width: 52, height: 52)
                            .background(Color.smoothGrape, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(20)
                    .accessibilityLabel("plan with ai")
                }
            }
        }
        .background(Color.smoothPaper.ignoresSafeArea())
        .navigationTitle("")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .onAppear {
            state.loadDegreePlanIfNeeded()
            Task { await state.refreshDegreeAudit(force: false) }
        }
        .task { await state.ensureAllDegreeAudits() }
        .onChange(of: state.degreeAdvisorPendingPrompt) { _, prompt in
            // "update plan" in the advisor sheet, opened from a table: the chat
            // takes the prompt when it appears. The short wait lets any cover
            // that was going away finish closing, because a sheet cannot open
            // while one is.
            guard prompt != nil, !showAdvisor else { return }
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if state.degreeAdvisorPendingPrompt != nil { showAdvisor = true }
            }
        }
        .sheet(isPresented: $showWhatIf) {
            DegreeWhatIfSheet()
                .environmentObject(state)
        }
        .sheet(isPresented: $showAdvisor) {
            DegreeAdvisorView(messages: $state.degreeAdvisorMessages, audits: advisorAudits())
                .environmentObject(state)
        }
        .sheet(isPresented: $showAdvisorQuestions, onDismiss: {
            // The sheet re-runs the planner itself when an answer changed.
            state.degreeAdvisorQuestionsClosed()
        }) {
            DegreeAdvisorQuestionsSheet(onUpdate: {
                state.runDegreePlanner(question: DegreeAdvisorQuestionsSheet.updatePrompt)
            })
            .environmentObject(state)
        }
        .sheet(item: $roadSheet) { target in
            switch target {
            case .semester(let code):
                DegreeSemesterSheet(termCode: code)
                    .environmentObject(state)
            case .add(let code):
                DegreePlanAddSheet(termCode: code, audits: state.degreeAudits)
                    .environmentObject(state)
            }
        }
        // The sign-in page, unless a sheet is up: the what-if sheet and the
        // chat present it themselves, since a sheet cannot present over a sheet.
        .pathSignInSheet(enabled: !showWhatIf && !showAdvisor && !showAdvisorQuestions && roadSheet == nil)
    }

    // MARK: Header and status

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("degree")
                    .font(.lhfSerif(32))
                    .foregroundStyle(Color.smoothInk)
                    .accessibilityAddTraits(.isHeader)
                statusLine
            }
            Spacer(minLength: 0)
            Menu {
                Button("try another major") { showWhatIf = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("more")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var statusRetries: Bool {
        switch state.degreeStatus {
        case .failed, .needsPathSignIn: return true
        default: return false
        }
    }

    /// Tappable only where a tap has an answer: a failure retries;
    /// "sign in to canvas" is just the words.
    @ViewBuilder
    private var statusLine: some View {
        if let text = state.degreeStatus.line(now: Date()) {
            let label = Text(text)
                .font(.lhfSans(13))
                .foregroundStyle(Color.smoothMuted)
            if statusRetries {
                Button { Task { await state.refreshDegreeAudit(force: true, userInitiated: true) } } label: { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private var canRead: Bool {
        switch state.degreeStatus {
        case .idle, .failed, .needsPathSignIn: return true
        default: return false
        }
    }

    private var emptyProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            if canRead {
                Button { Task { await state.refreshDegreeAudit(force: true, userInitiated: true) } } label: {
                    Text("read path@penn")
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

    /// The audits the chat reasons about: the declared ones, not the drawn
    /// ones. The chat reads its own what-ifs from its `activeAudits`, and a
    /// stand-in drawn for the plan must not be handed to it as if the student
    /// had declared it.
    private func advisorAudits() -> [DegreeLabeledAudit] {
        return state.degreeOwnAudits
    }

    private var footer: some View {
        Link("path@penn's reading · official audit ↗", destination: PathPage.officialAuditURL)
            .font(.lhfSans(13))
            .foregroundStyle(Color.smoothTealInk)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }
}

/// One degree's requirement cards, pushed from its bar on the road: the ring
/// exactly as the old overall rings drew it (Penn's number in the middle, the
/// planned arc, the faded best case, the lines under it), the key, and the
/// audit's blocks. Nothing here is computed that the audit did not say.
struct DegreeRequirementsPage: View {
    @EnvironmentObject var state: AppState

    let entry: DegreeLabeledAudit
    @State private var expanded: Set<String> = []

    var body: some View {
        let audit = entry.audit
        let figures = state.degreeDrawn(degreeID: entry.degreeID, audit: audit)
        let ring = figures.ring
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.label)
                    .font(.lhfSerif(28))
                    .foregroundStyle(Color.smoothInk)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 6) {
                    DegreeRingView(fraction: ring.fraction, centre: ring.centre, caption: ring.caption,
                                   extraFraction: audit.isWhatIf ? ring.extraFraction : 0,
                                   plannedFraction: figures.planned,
                                   plannedLine: figures.lines.joined(separator: ", "),
                                   bestExtraFraction: figures.bestExtra)
                    ForEach(figures.lines, id: \.self) { line in
                        Text(line)
                            .font(.lhfMono(10, weight: .semibold))
                            .foregroundStyle(Color.smoothCobaltInk)
                    }
                }
                .frame(maxWidth: .infinity)
                DegreeLegend(showsPlanned: !figures.projection.isEmpty, showsApproved: figures.bestExtra > 0)
                blockRows(audit, projection: figures.projection)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Color.smoothPaper.ignoresSafeArea())
        .navigationTitle("")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private func blockRows(_ audit: DegreeAudit, projection: DegreeProjection) -> some View {
        let blocks = DegreeProgressMath.orderedBlocks(audit.blocks).filter(DegreeProgressMath.isShown)
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(blocks) { block in
                DegreeBlockRow(block: block, isExpanded: expanded.contains(block.id), toggle: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if expanded.contains(block.id) { expanded.remove(block.id) } else { expanded.insert(block.id) }
                    }
                }, projection: projection)
            }
        }
    }
}


/// The key to the bars: teal is done, marigold is being taken now, the track
/// is what is left. Added 2026-11-10, when the owner looked at the first real
/// audit on his phone and asked what orange against green meant. Three words,
/// because the bars carry no other explanation and a colour alone is not one.
struct DegreeLegend: View {
    var showsPlanned: Bool = false
    /// Only while some ring on screen draws a best case.
    var showsApproved: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            entry(Color.smoothTeal, "done")
            entry(Color.smoothMarigold, "in progress")
            if showsPlanned {
                entry(Color.smoothCobalt, "planned")
            }
            if showsApproved {
                entry(Color.smoothCobalt.opacity(0.35), "if approved")
            }
            entry(Color.smoothRule, "left")
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func entry(_ colour: Color, _ word: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(word)
                .font(.lhfSans(12))
                .foregroundStyle(Color.smoothMuted)
        }
    }
}

// MARK: - Ring

/// A 96pt ring: a teal arc over the track, the number in the middle and a mono
/// caption. The optional grape arc continues from where the teal one ends,
/// which is how a what-if shows work still in progress.
struct DegreeRingView: View {
    let fraction: Double
    let centre: String
    let caption: String
    var extraFraction: Double = 0
    var diameter: CGFloat = 96
    /// The projected arc the plan adds, in cobalt after the done and extra
    /// arcs. `plannedLine` is drawn by the callers under the ring and is kept
    /// here only for the accessibility label.
    var plannedFraction: Double = 0
    var plannedLine: String? = nil
    /// The extra arc the best case would add beyond the planned arc, drawn in
    /// the same cobalt at reduced opacity: possible, not yet.
    var bestExtraFraction: Double = 0

    private var main: CGFloat { CGFloat(min(max(fraction, 0), 1)) }
    private var extra: CGFloat { CGFloat(min(max(extraFraction, 0), max(0, 1 - Double(main)))) }
    private var planned: CGFloat {
        CGFloat(min(max(plannedFraction, 0), max(0, 1 - Double(main) - Double(extra))))
    }
    private var bestExtra: CGFloat {
        CGFloat(min(max(bestExtraFraction, 0), max(0, 1 - Double(main) - Double(extra) - Double(planned))))
    }

    private var ringLabel: String {
        let base = caption.isEmpty ? centre : "\(centre) \(caption)"
        if let plannedLine, !plannedLine.isEmpty { return "\(base), \(plannedLine)" }
        return base
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.v2RingTrack, lineWidth: 9)
            if bestExtra > 0 {
                Circle()
                    .trim(from: main + extra + planned, to: main + extra + planned + bestExtra)
                    .stroke(Color.smoothCobalt.opacity(0.35), style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            if planned > 0 {
                Circle()
                    .trim(from: main + extra, to: main + extra + planned)
                    .stroke(Color.smoothCobalt, style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            if extra > 0 {
                Circle()
                    .trim(from: main, to: main + extra)
                    .stroke(Color.smoothGrape, style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            Circle()
                .trim(from: 0, to: main)
                .stroke(Color.smoothTeal, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(centre)
                    .font(.lhfSerif(22))
                    .foregroundStyle(Color.smoothInk)
                    .monospacedDigit()
                Text(caption)
                    .font(.lhfMono(10))
                    .foregroundStyle(Color.smoothMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 10)
        }
        .frame(width: diameter, height: diameter)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: fraction)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: plannedFraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ringLabel)
    }
}

// MARK: - Block

struct DegreeBlockRow: View {
    let block: AuditBlock
    let isExpanded: Bool
    let toggle: () -> Void
    var projection: DegreeProjection = .empty

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { summary }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(block.rules) { rule in
                        DegreeRuleRow(rule: rule, depth: 0, blockID: block.id, projection: projection)
                    }
                }
                .padding(.top, 14)
                .transition(.opacity)
            }
        }
        .padding(16)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.smoothRule, lineWidth: 1) }
    }

    private var summary: some View {
        let planned = projection.block(block)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(DegreeProgressMath.blockTitle(block))
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text(DegreeProgressMath.blockCount(block, planned: planned.courses))
                    .font(.lhfMono(12))
                    .foregroundStyle(Color.smoothMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.smoothMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            DegreeBar(shares: DegreeProgressMath.blockShares(block), planned: planned.share)
        }
        .contentShape(Rectangle())
    }
}

/// Segments on a rule-grey track: met in teal, in progress in marigold, and
/// the planned share in cobalt after them.
struct DegreeBar: View {
    let shares: (met: Double, inProgress: Double)
    var planned: Double = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.smoothRule)
                if planned > 0 {
                    Capsule().fill(Color.smoothCobalt)
                        .frame(width: width * CGFloat(min(1, shares.met + shares.inProgress + planned)))
                }
                Capsule().fill(Color.smoothMarigold)
                    .frame(width: width * CGFloat(min(1, shares.met + shares.inProgress)))
                Capsule().fill(Color.smoothTeal)
                    .frame(width: width * CGFloat(min(1, shares.met)))
            }
        }
        .frame(height: 6)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: planned)
        .accessibilityHidden(true)
    }
}

// MARK: - Rule

struct DegreeRuleRow: View {
    let rule: AuditRule
    let depth: Int
    var blockID: String = ""
    var projection: DegreeProjection = .empty

    private var statusWord: String {
        switch rule.status {
        case .met: return "met"
        case .inProgress: return "in progress"
        case .open, .info: return "open"
        }
    }

    private var statusColor: Color {
        switch rule.status {
        case .met: return .smoothTealInk
        case .inProgress: return .smoothMarigoldInk
        case .open, .info: return .smoothMuted
        }
    }

    private var entry: DegreeRuleProjection? {
        projection.rule(blockID: blockID, ruleID: rule.id)
    }

    private var plannedCourses: [PlannedCourse] { entry?.planned ?? [] }

    /// "n of N" only when the audit said how many courses the rule needs,
    /// then the planned count.
    private var countText: String? {
        DegreeProgressMath.ruleCountText(rule, planned: plannedCourses.count)
    }

    var body: some View {
        if DegreeProgressMath.isQuietNote(rule) {
            Text(rule.label.lowercased())
                .font(.lhfSans(12))
                .foregroundStyle(Color.smoothMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, depth == 0 ? 0 : 12)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !DegreeProgressMath.isLooseCourses(rule) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(rule.label.lowercased())
                            .font(.lhfSans(14, weight: .medium))
                            .foregroundStyle(Color.smoothInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if let countText {
                            Text(countText)
                                .font(.lhfMono(11))
                                .foregroundStyle(plannedCourses.isEmpty ? Color.smoothMuted : Color.smoothCobaltInk)
                        }
                        if rule.status != .info {
                            Text(statusWord)
                                .font(.lhfMono(11, weight: .semibold))
                                .foregroundStyle(statusColor)
                        }
                    }
                }
                chips
                ForEach(rule.children) { child in
                    DegreeRuleRow(rule: child, depth: depth + 1, blockID: blockID, projection: projection)
                }
            }
            .padding(.leading, depth == 0 ? 0 : 12)
        }
    }

    @ViewBuilder
    private var chips: some View {
        let planned = plannedCourses
        let plannedCodes = Set(planned.map { DegreePlanMath.normalizedCode($0.code) })
        if rule.status == .open || rule.status == .info {
            // Courses already counted toward an open rule come first, then
            // the planned ones in cobalt, then the suggestions as ghosts;
            // showing only the advice hid progress. A suggestion the plan
            // already holds is drawn once, as the planned chip.
            let ghosts = rule.advice.filter { !plannedCodes.contains(DegreePlanMath.normalizedCode($0.code)) }
            if !rule.applied.isEmpty || !planned.isEmpty || !ghosts.isEmpty {
                DegreeFlowLayout(spacing: 6) {
                    ForEach(rule.applied) { course in
                        DegreeCourseChip(course: course)
                    }
                    ForEach(Array(planned.enumerated()), id: \.offset) { _, course in
                        DegreePlannedChip(code: course.code)
                    }
                    ForEach(ghosts.prefix(6)) { course in
                        DegreeGhostChip(code: course.code)
                    }
                }
            }
        } else if !rule.applied.isEmpty || !planned.isEmpty {
            DegreeFlowLayout(spacing: 6) {
                ForEach(rule.applied) { course in
                    DegreeCourseChip(course: course)
                }
                ForEach(Array(planned.enumerated()), id: \.offset) { _, course in
                    DegreePlannedChip(code: course.code)
                }
            }
        }
    }
}

struct DegreeCourseChip: View {
    let course: AuditCourse

    var body: some View {
        Text(course.isInProgress ? "\(course.code) · now" : course.code)
            .font(.lhfMono(11))
            .foregroundStyle(courseAccentInk(for: course.code))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(courseAccent(for: course.code).opacity(0.28), in: Capsule())
            .accessibilityLabel(course.isInProgress ? "\(course.code), in progress" : course.code)
    }
}

/// A course Degree Works suggested for an open rule: a dashed outline and
/// muted type, so it never reads as something the student has.
struct DegreeGhostChip: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.lhfMono(11))
            .foregroundStyle(Color.smoothMuted)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .overlay {
                Capsule().strokeBorder(Color.smoothRule, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .accessibilityLabel("\(code), could count")
    }
}

/// A course the student has planned against a rule: the ghost chip's metrics
/// in cobalt, so it reads as a sketch and never as something Penn counted.
struct DegreePlannedChip: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.lhfMono(11))
            .foregroundStyle(Color.smoothCobaltInk)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.smoothCobalt.opacity(0.18), in: Capsule())
            .accessibilityLabel("\(code), planned")
    }
}

/// A left-to-right wrapping row; chips are short and numerous, and a
/// horizontal scroller would hide most of them.
struct DegreeFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
