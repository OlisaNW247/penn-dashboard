import SwiftUI
import LowHangingFruitKit

/// The two halves of the degree screen. `Identifiable` and `CaseIterable` are
/// what `SmoothSegmentPicker` asks of its option type.
enum DegreeTab: String, CaseIterable, Identifiable {
    case progress
    case whatIf

    var id: String { rawValue }
    var label: String { self == .progress ? "progress" : "what if" }
}

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

/// The pushed degree page.
///
/// Reads only `state.degree` and `state.degreeStatus`; the one thing it asks
/// of the world is `refreshDegreeAudit`. Copy is the status words from
/// `DegreeStatus.line` and a handful of fixed lowercase labels, never a
/// sentence, and never a verdict: the page reports what Degree Works says
/// and links the official audit for anything that matters.
struct DegreeProgressView: View {
    @EnvironmentObject var state: AppState

    @State private var tab: DegreeTab = .progress
    @State private var expanded: Set<String> = []
    @State private var selectedWhatIf = 0
    @State private var showSheet = false

    private var descriptions: [String: String] { state.degreeDescriptions }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            SmoothSegmentPicker(selection: $tab) { $0.label }
                .padding(.horizontal, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .progress: progressTab
                    case .whatIf: whatIfTab
                    }
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .refreshable { await state.refreshDegreeAudit(force: true) }
        }
        .background(Color.smoothPaper.ignoresSafeArea())
        .navigationTitle("")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .onAppear { Task { await state.refreshDegreeAudit(force: false) } }
        .onChange(of: state.degree.whatIfs.first?.goals) { _, _ in selectedWhatIf = 0 }
        .sheet(isPresented: $showSheet) {
            DegreeWhatIfSheet()
                .environmentObject(state)
        }
    }

    // MARK: Header and status

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("degree")
                .font(.lhfSerif(32))
                .foregroundStyle(Color.smoothInk)
                .accessibilityAddTraits(.isHeader)
            statusLine
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var statusRetries: Bool {
        if case .failed = state.degreeStatus { return true }
        return false
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
                Button { Task { await state.refreshDegreeAudit(force: true) } } label: { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    // MARK: Progress

    @ViewBuilder
    private var progressTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            degreeChips
            if let audit = state.degree.current {
                auditBody(audit, tag: nil, headline: programTitle(audit), summary: nil, prefix: "c:")
            } else {
                emptyProgress
            }
        }
    }

    /// One chip per degree of a student who has more than one; hidden for one.
    @ViewBuilder
    private var degreeChips: some View {
        let degrees = state.degree.degrees
        if degrees.count > 1 {
            let selectedID = state.degree.selectedDegreeID ?? degrees.first?.id
            let labels = DegreeGoals.chipTitles(for: degrees.map(\.goals), descriptions: descriptions)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(degrees.enumerated()), id: \.element.id) { index, degree in
                        let isSelected = degree.id == selectedID
                        let title = degree.goals.title(descriptions: descriptions)
                        Button { Task { await state.selectDegree(degree.id) } } label: {
                            Text(index < labels.count ? labels[index] : title)
                                .font(.lhfSans(13, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? Color.smoothTealInk : Color.smoothMuted)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(isSelected ? Color.smoothTeal.opacity(0.22) : Color.clear, in: Capsule())
                                .overlay { Capsule().stroke(Color.smoothRule, lineWidth: isSelected ? 0 : 1) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(title)
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
    }

    private var canRead: Bool {
        switch state.degreeStatus {
        case .idle, .failed: return true
        default: return false
        }
    }

    private var emptyProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            if canRead {
                Button { Task { await state.refreshDegreeAudit(force: true) } } label: {
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

    private func programTitle(_ audit: DegreeAudit) -> String {
        var title = audit.goals.title(descriptions: descriptions)
        if let label = audit.degreeLabel, !label.isEmpty, descriptions.isEmpty { title = label.lowercased() }
        // No catalog term here. It was appended as "· catalog 202430" until
        // Olisa saw it on his phone (2026-11-10) and called it tacky: a
        // six-digit registrar code beside the ring tells a student nothing.
        return title
    }

    // MARK: What if

    @ViewBuilder
    private var whatIfTab: some View {
        let list = state.degree.whatIfs
        if list.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                switchButton
            }
            .padding(.top, 8)
        } else {
            let index = min(selectedWhatIf, list.count - 1)
            let target = list[index]
            VStack(alignment: .leading, spacing: 16) {
                whatIfChips(list, selected: index)
                let headline = DegreeWhatIf.headline(current: state.degree.current?.goals,
                                                     target: target.goals, descriptions: descriptions)
                let summary = DegreeWhatIf.summarize(current: state.degree.current, target: target)
                auditBody(target, tag: "what if", headline: headline,
                          summary: summaryLine(summary), prefix: "w:")
            }
        }
    }

    private var switchButton: some View {
        Button { showSheet = true } label: {
            Text("switch or add…")
                .font(.lhfSans(14, weight: .semibold))
                .foregroundStyle(Color.smoothGrapeInk)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color.smoothGrape.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func whatIfChips(_ list: [DegreeAudit], selected: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(list.enumerated()), id: \.offset) { index, audit in
                    let headline = DegreeWhatIf.headline(current: state.degree.current?.goals,
                                                         target: audit.goals, descriptions: descriptions)
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selectedWhatIf = index } } label: {
                        Text(headline)
                            .font(.lhfSans(13, weight: index == selected ? .semibold : .medium))
                            .foregroundStyle(index == selected ? Color.smoothGrapeInk : Color.smoothMuted)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(index == selected ? Color.smoothGrape.opacity(0.18) : Color.clear, in: Capsule())
                            .overlay { Capsule().stroke(Color.smoothRule, lineWidth: index == selected ? 0 : 1) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(headline)
                    .accessibilityAddTraits(index == selected ? [.isButton, .isSelected] : .isButton)
                }
                switchButton
            }
        }
    }

    private func summaryLine(_ s: DegreeWhatIfSummary) -> String {
        "\(s.met) met · \(s.inProgress) in progress · \(s.open) open · \(s.alreadyCounting.count) of your courses count"
    }

    // MARK: Shared audit body

    private func auditBody(_ audit: DegreeAudit, tag: String?, headline: String,
                           summary: String?, prefix: String) -> some View {
        let ring = DegreeProgressMath.ring(for: audit)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 6) {
                    DegreeRingView(fraction: ring.fraction, centre: ring.centre, caption: ring.caption,
                                   extraFraction: tag == nil ? 0 : ring.extraFraction)
                    if let tag {
                        Text(tag)
                            .font(.lhfMono(10, weight: .semibold))
                            .foregroundStyle(Color.smoothGrapeInk)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.smoothGrape.opacity(0.2), in: Capsule())
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline)
                        .font(.lhfSans(17, weight: .semibold))
                        .foregroundStyle(Color.smoothInk)
                        .fixedSize(horizontal: false, vertical: true)
                    if let summary {
                        Text(summary)
                            .font(.lhfSans(13))
                            .foregroundStyle(Color.smoothMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            DegreeLegend()
            ForEach(DegreeProgressMath.orderedBlocks(audit.blocks).filter(DegreeProgressMath.isShown)) { block in
                DegreeBlockRow(block: block, isExpanded: expanded.contains(prefix + block.id)) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        let key = prefix + block.id
                        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        Link("path@penn's reading · official audit ↗", destination: PathPage.officialAuditURL)
            .font(.lhfSans(13))
            .foregroundStyle(Color.smoothTealInk)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }
}

/// The key to the bars: teal is done, marigold is being taken now, the track
/// is what is left. Added 2026-11-10, when the owner looked at the first real
/// audit on his phone and asked what orange against green meant. Three words,
/// because the bars carry no other explanation and a colour alone is not one.
struct DegreeLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            entry(Color.smoothTeal, "done")
            entry(Color.smoothMarigold, "in progress")
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

    private var main: CGFloat { CGFloat(min(max(fraction, 0), 1)) }
    private var extra: CGFloat { CGFloat(min(max(extraFraction, 0), max(0, 1 - Double(main)))) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.v2RingTrack, lineWidth: 9)
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
        .frame(width: 96, height: 96)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.isEmpty ? centre : "\(centre) \(caption)")
    }
}

// MARK: - Block

struct DegreeBlockRow: View {
    let block: AuditBlock
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { summary }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(block.rules) { rule in
                        DegreeRuleRow(rule: rule, depth: 0)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(DegreeProgressMath.blockTitle(block))
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text(DegreeProgressMath.blockCount(block))
                    .font(.lhfMono(12))
                    .foregroundStyle(Color.smoothMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.smoothMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            DegreeBar(shares: DegreeProgressMath.blockShares(block))
        }
        .contentShape(Rectangle())
    }
}

/// Three segments on a rule-grey track: met in teal, in progress in marigold.
struct DegreeBar: View {
    let shares: (met: Double, inProgress: Double)

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.smoothRule)
                Capsule().fill(Color.smoothMarigold)
                    .frame(width: width * CGFloat(min(1, shares.met + shares.inProgress)))
                Capsule().fill(Color.smoothTeal)
                    .frame(width: width * CGFloat(min(1, shares.met)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Rule

struct DegreeRuleRow: View {
    let rule: AuditRule
    let depth: Int

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

    /// "n of N" only when the audit said how many courses the rule needs.
    private var countText: String? {
        guard let need = rule.needCourses, need > 0 else { return nil }
        return "\(rule.appliedCount ?? rule.applied.count) of \(need)"
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
                                .foregroundStyle(Color.smoothMuted)
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
                    DegreeRuleRow(rule: child, depth: depth + 1)
                }
            }
            .padding(.leading, depth == 0 ? 0 : 12)
        }
    }

    @ViewBuilder
    private var chips: some View {
        if rule.status == .open || rule.status == .info {
            // Courses already counted toward an open rule come first, then
            // the suggestions as ghosts; showing only the advice hid progress.
            if !rule.applied.isEmpty || !rule.advice.isEmpty {
                DegreeFlowLayout(spacing: 6) {
                    ForEach(rule.applied) { course in
                        DegreeCourseChip(course: course)
                    }
                    ForEach(rule.advice.prefix(6)) { course in
                        DegreeGhostChip(code: course.code)
                    }
                }
            }
        } else if !rule.applied.isEmpty {
            DegreeFlowLayout(spacing: 6) {
                ForEach(rule.applied) { course in
                    DegreeCourseChip(course: course)
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
