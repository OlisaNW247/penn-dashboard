import SwiftUI
import LowHangingFruitKit

/// "The road": the degree screen's one scrolling story. A headline (when the
/// plan would finish), one bar per degree at Penn's own percent, and a vertical
/// road of semesters from the first one behind the student to the finish.
///
/// Every state is a shape and a word, never a colour alone: done is a filled
/// teal tick, now a filled marigold dot, registered a half-filled one, planned
/// a dashed cobalt ring, an empty term a plain ring, the finish a flag on ink,
/// and the advisor's questions a grape "?". All the arithmetic is the Kit's
/// (`DegreeRoad`, `AppState.degreeRoad`); this file only draws it, and every
/// gesture has a tap path (a semester opens a sheet with menus, nothing needs
/// a drag).
///
/// Penn's own percent is shown unchanged. Anything the app estimates carries
/// "≈" (the lines come from `DegreeProgressMath.ringLines` and
/// `withPlanText`), nothing planned is called met, and there is no combined
/// percent across two degrees.
///
/// The sheets this opens belong to the host (`DegreeProgressView`), which is
/// handed closures: a sheet cannot present over another presenter's sheet.
struct DegreeRoadView: View {
    @EnvironmentObject var state: AppState

    /// Opens the plan-with-ai chat ("why").
    let openChat: () -> Void
    let openSemester: (String) -> Void
    let openAdd: (String) -> Void
    /// Opens the advisor questions sheet.
    let openAdvisor: () -> Void

    @State private var hideWhatIf = false
    @State private var doneExpanded = false

    private var descriptions: [String: String] { state.degreeDescriptions }
    private var running: Bool { state.degreePlannerIsRunning }

    var body: some View {
        let road = state.degreeRoad
        return VStack(alignment: .leading, spacing: 22) {
            headline(road)
            whatIfBanner
            bars
            roadList(road)
        }
    }

    // MARK: Headline

    private func headline(_ road: DegreeRoad) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch road.headline {
            case .noPlan:
                Text("no plan yet")
                    .font(.lhfSerif(40))
                    .foregroundStyle(Color.smoothInk)
                    .accessibilityAddTraits(.isHeader)
                plannerButton("plan the rest ✦", question: AppState.degreePlanTheRestPrompt, filled: true)
            case .finish(let termCode, let semestersToGo, let checked):
                Text((checked ? "would finish · " : "your plan ends · ") + DegreeRoad.semestersText(semestersToGo))
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.smoothMuted)
                Text(DegreePlanMath.termLabel(termCode))
                    .font(.lhfSerif(40))
                    .foregroundStyle(Color.smoothInk)
                    .accessibilityAddTraits(.isHeader)
                if !checked {
                    plannerButton("check with the planner ✦",
                                  question: "check my plan and fill anything missing", filled: false)
                }
            }
            if let sooner = road.sooner {
                soonerButton(sooner)
            }
            runStatus
        }
    }

    private func plannerButton(_ title: String, question: String, filled: Bool) -> some View {
        Button { state.runDegreePlanner(question: question) } label: {
            Text(title)
                .font(.lhfSans(14, weight: .semibold))
                .foregroundStyle(filled ? Color.smoothInk : Color.smoothGrapeInk)
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
                .background(filled ? Color.smoothGrape : Color.smoothGrape.opacity(0.16), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(running)
        .opacity(running ? 0.5 : 1)
        .padding(.top, 4)
    }

    private func soonerButton(_ sooner: DegreeRoadSooner) -> some View {
        Button { openAdvisor() } label: {
            Text(DegreeRoad.soonerText(sooner) + " ›")
                .font(.lhfSans(14, weight: .semibold))
                .foregroundStyle(Color.smoothGrapeInk)
                .frame(minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(DegreeRoad.soonerText(sooner))
    }

    /// What a planner run is doing or did, under the headline.
    @ViewBuilder
    private var runStatus: some View {
        switch state.degreePlannerRun {
        case .idle:
            EmptyView()
        case .running(let stage):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stage.isEmpty ? "planning…" : stage)
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.smoothMuted)
            }
            .padding(.top, 4)
        case .finished(let finishBefore, let finishAfter, let planBefore, _):
            HStack(spacing: 14) {
                Text(finishedLine(before: finishBefore, after: finishAfter, changed: planBefore != nil))
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.smoothMuted)
                if planBefore != nil {
                    textButton("undo") { state.undoDegreePlannerRun() }
                }
                textButton("why") { openChat() }
                Spacer(minLength: 0)
                closeButton
            }
            .padding(.top, 4)
        case .failed(let line, let canRetry, _):
            HStack(spacing: 14) {
                Text(line)
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.smoothMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if canRetry {
                    textButton("try again") { state.retryDegreePlanner() }
                }
                Spacer(minLength: 0)
                closeButton
            }
            .padding(.top, 4)
        }
    }

    /// A run that changed nothing (the planner only answered) says so,
    /// rather than claiming an update; "why" then shows the answer.
    private func finishedLine(before: String?, after: String?, changed: Bool) -> String {
        guard changed else { return "nothing changed" }
        if let before, let after, before != after {
            return "was \(DegreePlanMath.termLabel(before))"
        }
        return "plan updated"
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.lhfSans(12, weight: .semibold))
                .foregroundStyle(Color.smoothGrapeInk)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button { state.dismissDegreePlannerResult() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.smoothMuted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("close")
    }

    // MARK: Bars

    private struct BarEntry: Identifiable {
        let labeled: DegreeLabeledAudit
        let isWhatIf: Bool
        var id: String { (isWhatIf ? "w:" : "d:") + labeled.degreeID }
    }

    private var currentWhatIf: DegreeAudit? { state.degree.whatIfs.first }

    private func barEntries() -> [BarEntry] {
        var out: [BarEntry] = []
        let audits = state.degreeAudits
        if audits.isEmpty, let current = state.degree.current {
            var title = current.goals.title(descriptions: descriptions)
            if let label = current.degreeLabel, !label.isEmpty, descriptions.isEmpty { title = label.lowercased() }
            out.append(BarEntry(labeled: DegreeLabeledAudit(
                degreeID: state.selectedStudentDegree?.id ?? "", label: title, audit: current), isWhatIf: false))
        } else {
            out.append(contentsOf: audits.map { BarEntry(labeled: $0, isWhatIf: false) })
        }
        if !hideWhatIf, let target = currentWhatIf {
            let title = DegreeWhatIf.headline(current: state.degree.current?.goals, target: target.goals,
                                              descriptions: descriptions)
            out.append(BarEntry(labeled: DegreeLabeledAudit(
                degreeID: state.selectedStudentDegree?.id ?? "", label: title, audit: target), isWhatIf: true))
        }
        return out
    }

    /// Above the bars while a what-if is on screen; "hide" only hides it here.
    @ViewBuilder
    private var whatIfBanner: some View {
        if !hideWhatIf, let target = currentWhatIf {
            let title = DegreeWhatIf.headline(current: state.degree.current?.goals, target: target.goals,
                                              descriptions: descriptions)
            HStack(spacing: 10) {
                Text("what if · \(title) · not declared")
                    .font(.lhfSans(12, weight: .semibold))
                    .foregroundStyle(Color.smoothGrapeInk)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button { hideWhatIf = true } label: {
                    Text("hide")
                        .font(.lhfSans(12, weight: .semibold))
                        .foregroundStyle(Color.smoothGrapeInk)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.smoothGrape.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(barEntries()) { entry in
                barRow(entry)
            }
            barKey
        }
    }

    private func barRow(_ entry: BarEntry) -> some View {
        let audit = entry.labeled.audit
        let figures = state.degreeDrawn(degreeID: entry.labeled.degreeID, audit: audit)
        let ring = figures.ring
        let penn = ring.caption.isEmpty ? ring.centre : "\(ring.centre) \(ring.caption)"
        let shares = (met: ring.fraction, inProgress: audit.isWhatIf ? ring.extraFraction : 0.0)
        return NavigationLink {
            DegreeRequirementsPage(entry: entry.labeled)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.labeled.label)
                        .font(.lhfSans(15, weight: .semibold))
                        .foregroundStyle(Color.smoothInk)
                        .lineLimit(1)
                    if entry.isWhatIf {
                        Text("what if")
                            .font(.lhfMono(10, weight: .semibold))
                            .foregroundStyle(Color.smoothGrapeInk)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.smoothGrape.opacity(0.2), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    Text(penn)
                        .font(.lhfMono(13, weight: .semibold))
                        .foregroundStyle(Color.smoothInk)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.smoothMuted)
                }
                DegreeBar(shares: shares, planned: figures.planned)
                if let line = figures.lines.first {
                    Text(line)
                        .font(.lhfMono(10, weight: .semibold))
                        .foregroundStyle(Color.smoothCobaltInk)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(entry.labeled.label), \(penn)" + (figures.lines.first.map { ", \($0)" } ?? ""))
        .accessibilityHint("opens its requirements")
    }

    private var barKey: some View {
        HStack(spacing: 14) {
            keyEntry(Color.smoothTeal, "done")
            keyEntry(Color.smoothMarigold, "in progress")
            keyEntry(Color.smoothCobalt, "planned")
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func keyEntry(_ colour: Color, _ word: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(word)
                .font(.lhfSans(11))
                .foregroundStyle(Color.smoothMuted)
        }
    }

    // MARK: Road

    /// Class counts of the semesters behind the student, for the expanded
    /// "done" stop.
    private func pastCounts() -> [String: Int] {
        let columns = DegreeTimeline.columns(
            history: state.degree.history, plan: state.degreePlan, audit: state.degree.current, now: Date())
        var out: [String: Int] = [:]
        for column in columns { out[column.termCode] = column.taken.count }
        return out
    }

    private func roadList(_ road: DegreeRoad) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(road.stops) { stop in
                stopRow(stop)
                // "ask your advisor" is the advisor row itself, already grape
                // and tappable; a callout under it only repeated the words.
                if road.nextStepStopID == stop.id, let step = road.nextStep, step != .askAdvisor {
                    callout(step)
                }
                if case .term(_, _, _, _, _, let isFinish) = stop.kind, isFinish, let sooner = road.sooner {
                    soonerButton(sooner)
                        .padding(.leading, 40)
                        .padding(.bottom, 4)
                }
            }
            addSemesterRow
        }
        .background(alignment: .topLeading) {
            Rectangle()
                .fill(Color.smoothRule)
                .frame(width: 2)
                .padding(.leading, 13)
                .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func stopRow(_ stop: DegreeRoadStop) -> some View {
        switch stop.kind {
        case .done(let termCodes, let classes):
            VStack(alignment: .leading, spacing: 0) {
                row(dot: .done) {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { doneExpanded.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Text(doneTitle(termCodes.count))
                                .font(.lhfSans(15, weight: .semibold))
                                .foregroundStyle(Color.smoothInk)
                            Spacer(minLength: 8)
                            Text(DegreeRoad.classesText(classes))
                                .font(.lhfMono(12))
                                .foregroundStyle(Color.smoothMuted)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.smoothMuted)
                                .rotationEffect(.degrees(doneExpanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(doneTitle(termCodes.count)), \(DegreeRoad.classesText(classes))")
                    .accessibilityHint(doneExpanded ? "hides them" : "lists them")
                }
                if doneExpanded {
                    let counts = pastCounts()
                    ForEach(termCodes, id: \.self) { code in
                        Button { openSemester(code) } label: {
                            HStack(spacing: 8) {
                                Text("\(DegreePlanMath.termLabel(code)) · done")
                                    .font(.lhfSans(13))
                                    .foregroundStyle(Color.smoothInk)
                                Spacer(minLength: 8)
                                Text(DegreeRoad.classesText(counts[code] ?? 0))
                                    .font(.lhfMono(11))
                                    .foregroundStyle(Color.smoothMuted)
                            }
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 40)
                        .accessibilityLabel(
                            "\(DegreePlanMath.termLabel(code)), done, \(DegreeRoad.classesText(counts[code] ?? 0))")
                    }
                }
            }
        case .term(let termCode, let termState, let classes, let credits, let overLimit, let isFinish):
            row(dot: isFinish ? .finish : look(for: termState)) {
                termContent(termCode: termCode, termState: termState, classes: classes,
                            credits: credits, overLimit: overLimit, isFinish: isFinish)
            }
        case .advisor(let open, _):
            row(dot: .advisor) {
                Button { openAdvisor() } label: {
                    HStack(spacing: 8) {
                        Text(open > 0 ? "ask your advisor · \(open) open" : "advisor · all answered")
                            .font(.lhfSans(15, weight: .semibold))
                            .foregroundStyle(Color.smoothGrapeInk)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.smoothMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open > 0 ? "ask your advisor, \(open) open" : "advisor, all answered")
            }
        }
    }

    private func doneTitle(_ count: Int) -> String {
        count == 1 ? "1 semester done" : "\(count) semesters done"
    }

    private func look(for termState: DegreeRoadTermState) -> DegreeRoadDot.Look {
        switch termState {
        case .now: return .now
        case .registered: return .registered
        case .planned: return .planned
        case .empty: return .empty
        }
    }

    private func termContent(termCode: String, termState: DegreeRoadTermState, classes: Int,
                             credits: Double, overLimit: Bool, isFinish: Bool) -> some View {
        let word = isFinish ? "finish" : DegreeRoad.stateWord(termState)
        let title = "\(DegreePlanMath.termLabel(termCode)) · \(word)"
        let showCredits = termState != .now && credits > 0
        let creditsText = "\(DegreePlanSummary.creditsText(credits)) cu"
        return Button { openSemester(termCode) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(DegreeRoad.classesText(classes))
                        .font(.lhfMono(12))
                        .foregroundStyle(Color.smoothMuted)
                    if showCredits {
                        Text(creditsText)
                            .font(.lhfMono(11, weight: overLimit ? .semibold : .regular))
                            .foregroundStyle(overLimit ? Color.smoothTomatoInk : Color.smoothMuted)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(title), \(DegreeRoad.classesText(classes))" + (showCredits ? ", \(creditsText)" : ""))
        .accessibilityValue(showCredits && overLimit ? "over the limit" : "")
        .accessibilityHint("opens the semester")
    }

    /// One road row: the dot column, then the content.
    private func row<Content: View>(dot: DegreeRoadDot.Look, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            DegreeRoadDot(look: dot)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            content()
                .padding(.vertical, 4)
                .frame(minHeight: 28, alignment: .center)
        }
        .padding(.vertical, 6)
    }

    // MARK: Next step

    @ViewBuilder
    private func callout(_ step: DegreeRoadNextStep) -> some View {
        HStack(spacing: 10) {
            switch step {
            case .planTheRest:
                Text("nothing planned ahead")
                    .font(.lhfSans(14, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                Spacer(minLength: 8)
                calloutButton("plan the rest ✦", tint: Color.smoothGrape) {
                    state.runDegreePlanner(question: AppState.degreePlanTheRestPrompt)
                }
                .disabled(running)
                .opacity(running ? 0.5 : 1)
            case .askAdvisor:
                Text(DegreeRoad.nextStepText(step))
                    .font(.lhfSans(14, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                Spacer(minLength: 8)
                calloutButton("ask your advisor", tint: Color.smoothGrape) { openAdvisor() }
            case .room(let termCode, _):
                Text(DegreeRoad.nextStepText(step))
                    .font(.lhfSans(14, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                Spacer(minLength: 8)
                calloutButton("+ add", tint: Color.smoothCobalt) { openAdd(termCode) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.smoothCobalt.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.leading, 40)
        .padding(.bottom, 6)
    }

    private func calloutButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.lhfSans(13, weight: .semibold))
                .foregroundStyle(Color.smoothInk)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(tint, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var addSemesterRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.smoothMuted)
                .frame(width: 22, height: 22)
                .background(Color.smoothPaper, in: Circle())
                .overlay { Circle().stroke(Color.smoothRule, lineWidth: 1.5) }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Button { state.addPlanTerm() } label: {
                Text("+ semester")
                    .font(.lhfSans(14, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                    .frame(minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.degreePlan.terms.count >= DegreePlanMath.maxTerms)
        }
        .padding(.vertical, 6)
    }
}

/// The dot on the road. Each look is a different shape as well as a different
/// colour, so no state rests on colour alone.
struct DegreeRoadDot: View {
    enum Look { case done, now, registered, planned, empty, finish, advisor }

    let look: Look

    private let size: CGFloat = 22

    var body: some View {
        ZStack {
            switch look {
            case .done:
                Circle().fill(Color.smoothTeal)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.smoothInk)
            case .now:
                Circle().fill(Color.smoothMarigold)
            case .registered:
                Circle().fill(Color.smoothPaper)
                Circle().trim(from: 0, to: 0.5).fill(Color.smoothMarigold)
                Circle().stroke(Color.smoothMarigold, lineWidth: 2)
            case .planned:
                Circle().fill(Color.smoothPaper)
                Circle().strokeBorder(Color.smoothCobalt, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            case .empty:
                Circle().fill(Color.smoothPaper)
                Circle().stroke(Color.smoothRule, lineWidth: 2)
            case .finish:
                Circle().fill(Color.smoothInk)
                Image(systemName: "flag.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.smoothPaper)
            case .advisor:
                Circle().fill(Color.smoothGrape)
                Text("?")
                    .font(.lhfSans(12, weight: .bold))
                    .foregroundStyle(Color.smoothInk)
            }
        }
        .frame(width: size, height: size)
    }
}
