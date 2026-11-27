import Foundation
import Testing
import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The degree screens' copy rules (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md):
/// lowercase, no verdict words, the official audit always named, and every
/// status sentence read from `DegreeStatus.line` rather than written here.
@Suite("Degree copy")
struct DegreeCopyTests {
    private static let files = ["DegreeProgressView.swift", "DegreeWhatIfSheet.swift", "DegreePlanView.swift", "DegreeSemesterTable.swift", "DegreeAdvisorView.swift", "DegreeRoadView.swift", "DegreeSemesterSheet.swift"]

    private func uiSource(_ filename: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI")
        return try String(contentsOf: sources.appendingPathComponent(filename), encoding: .utf8)
    }

    @Test("no verdict words anywhere in the degree views")
    func noVerdictWords() throws {
        for file in Self.files {
            let source = try uiSource(file).lowercased()
            for word in ["graduate", "on track", "eligible"] {
                #expect(!source.contains(word), "\(file) contains \(word)")
            }
        }
    }

    @Test("the title beside the ring never carries the catalog term")
    func noCatalogTerm() throws {
        let source = try uiSource("DegreeProgressView.swift")
        #expect(!source.contains("catalogYearLabel"))
    }

    @Test("the bars have a three-word key: done, in progress, left")
    func legend() throws {
        let source = try uiSource("DegreeProgressView.swift")
        #expect(source.contains("DegreeLegend("))
        for word in ["\"done\"", "\"in progress\"", "\"left\""] {
            #expect(source.contains(word), "legend is missing \(word)")
        }
    }

    @Test("the footer names the official audit")
    func footer() throws {
        let source = try uiSource("DegreeProgressView.swift")
        #expect(source.contains("path@penn's reading · official audit ↗"))
        #expect(source.contains("PathPage.officialAuditURL"))
    }

    @Test("no capitalised literal in a visible string")
    func lowercaseLiterals() throws {
        let pattern = try NSRegularExpression(pattern: #"(Text|Button|Link|TextField|Label)\("[A-Z]"#)
        for file in Self.files {
            let source = try uiSource(file)
            let range = NSRange(source.startIndex..., in: source)
            #expect(pattern.firstMatch(in: source, range: range) == nil, "\(file) has a capitalised string")
        }
    }

    @Test("the status sentence comes from DegreeStatus.line, not the view")
    func statusFromLine() throws {
        let source = try uiSource("DegreeProgressView.swift")
        #expect(source.contains("degreeStatus.line(now:"))
        for phrase in ["reading path@penn…", "approve the duo push", "couldn't read path@penn"] {
            #expect(!source.contains(phrase), "\(phrase) belongs to DegreeStatus")
        }
    }

    @Test("the what-if sheet is a searchable list wired to the three data calls")
    func sheetIsASearchableList() throws {
        let source = try uiSource("DegreeWhatIfSheet.swift")
        #expect(source.contains("search concentrations, majors, minors"))
        for piece in ["DegreeProgramSearch.sections(", "DegreeProgramSearch.actionLine(", "runDegreeEntry(",
                      "DegreeSearchAssist.shouldAsk(", "OnDeviceLanguageModel.reply(", ".task(id:",
                      "Text(\"related\")"] {
            #expect(source.contains(piece), "the sheet is missing \(piece)")
        }
        #expect(source.contains("loadDegreePrograms"))
        #expect(source.contains("degreeWhatIfPlans"))
        #expect(source.contains("runWhatIf("))
        #expect(source.contains("degreeStatus.line(now:"))
    }

    @Test("the plan view carries its four fixed phrases")
    func planPhrases() throws {
        // The table's phrases moved with it to DegreeSemesterTable.swift; the
        // add sheet stayed in DegreePlanView.swift.
        let source = try uiSource("DegreePlanView.swift") + uiSource("DegreeSemesterTable.swift")
        for phrase in ["+ course", "+ semester", "fits · ", "counts toward your degree"] {
            #expect(source.contains(phrase), "the plan views are missing \(phrase)")
        }
    }

    @Test("the strip has a full view button and the page hosts the table in page layout")
    func fullView() throws {
        let source = try uiSource("DegreeSemesterTable.swift")
        #expect(source.contains("struct DegreeSemesterPage"))
        #expect(source.contains("Text(\"full view\")"))
        #expect(source.contains(".accessibilityLabel(\"full view\")"))
        #expect(source.contains("DegreeSemesterTable(audits: audits, layout: .page)"))
        #expect(source.contains("Text(\"semesters\")"))
    }

    @Test("the road: one bar per degree at Penn's own percent, no combined percent, no shared-course row")
    func combinedView() throws {
        let progress = try uiSource("DegreeProgressView.swift")
        let road = try uiSource("DegreeRoadView.swift")
        #expect(road.contains("state.degreeAudits"))
        #expect(road.contains("DegreeBar("))
        #expect(road.contains("ring.centre"))
        #expect(!(progress + road).contains("counts in both"))
        #expect(progress.contains("ensureAllDegreeAudits()"))
        #expect(!(progress + road).lowercased().contains("average"))
        #expect(try uiSource("DegreeSemesterTable.swift").contains("DegreeContribution.planned("))
        #expect(try uiSource("DegreePlanView.swift").contains("DegreeContribution.suggestions("))
    }

    @Test("the road screen reads the road, drops the tabs and offers the menu path for every edit")
    func roadScreen() throws {
        let progress = try uiSource("DegreeProgressView.swift")
        let road = try uiSource("DegreeRoadView.swift")
        let sheet = try uiSource("DegreeSemesterSheet.swift")
        #expect(road.contains("state.degreeRoad"))
        #expect(road.contains("state.degreePlannerRun"))
        #expect(road.contains("AppState.degreePlanTheRestPrompt"))
        #expect(road.contains("DegreeRoad.soonerText("))
        #expect(road.contains("state.addPlanTerm()"))
        #expect(!progress.contains("SmoothSegmentPicker"))
        #expect(!progress.contains("DegreeTab"))
        #expect(!progress.contains("advisorMessages"))
        #expect(progress.contains("$state.degreeAdvisorMessages"))
        #expect(progress.contains("try another major"))
        #expect(progress.contains("DegreeWhatIfSheet()"))
        #expect(sheet.contains("Menu(\"move to\")"))
        #expect(sheet.contains("Button(\"remove\""))
        #expect(sheet.contains("DegreePlanAddSheet("))
    }

    @Test("the advisor questions sheet tells the planner when it goes away")
    func advisorSheetClosed() throws {
        let progress = try uiSource("DegreeProgressView.swift")
        let start = try #require(progress.range(of: "isPresented: $showAdvisorQuestions"))
        let window = String(progress[start.lowerBound...].prefix(500))
        #expect(window.contains("onDismiss"))
        #expect(window.contains("degreeAdvisorQuestionsClosed()"))
        #expect(window.contains("runDegreePlanner(question: DegreeAdvisorQuestionsSheet.updatePrompt)"))
    }

    @Test("every road state is a shape and a word")
    func roadStatesAreShapes() throws {
        let road = try uiSource("DegreeRoadView.swift")
        for piece in ["\"checkmark\"", "\"flag.fill\"", "dash: [3, 2]", "trim(from: 0, to: 0.5)", "Text(\"?\")",
                      "DegreeRoad.stateWord(", "\"finish\""] {
            #expect(road.contains(piece), "the road is missing \(piece)")
        }
    }

    @Test("the chat and a background planner run never overlap")
    func advisorWaitsForPlanner() throws {
        let advisor = try uiSource("DegreeAdvisorView.swift")
        #expect(advisor.contains("!state.degreePlannerIsRunning"))
        #expect(advisor.contains("plannerStage"))
    }

    @Test("a fits line names the degree only when there is one to name")
    func fitLine() {
        let single = DegreePlanFit(degreeLabel: "", requirement: "Free Electives")
        #expect(DegreeSemesterTable.fitLine(single) == "fits · free electives")
        let dual = DegreePlanFit(degreeLabel: "finance", requirement: "Core Math")
        #expect(DegreeSemesterTable.fitLine(dual) == "fits · finance · core math")
    }

    // MARK: Planned layer

    private func planRule(needCourses: Int?, applied: Int?) -> AuditRule {
        AuditRule(id: "r", label: "rule", ruleType: "Subset", percentComplete: nil, status: .open,
                  needCourses: needCourses, needCredits: nil, appliedCount: applied, appliedCredits: nil,
                  applied: [], advice: [], adviceText: nil, children: [])
    }

    @Test("the with-plan line appears only for a real gain and clamps at 100%")
    func withPlanText() {
        #expect(DegreeProgressMath.withPlanText(base: 0.5, gain: 0) == nil)
        #expect(DegreeProgressMath.withPlanText(base: 0.5, gain: 0.004) == nil)
        #expect(DegreeProgressMath.withPlanText(base: 0.67, gain: 0.09) == "≈ 76% with plan")
        #expect(DegreeProgressMath.withPlanText(base: 0.95, gain: 0.3) == "≈ 100% with plan")
    }

    @Test("a block count adds planned courses and is unchanged without any")
    func blockCountPlanned() {
        let block = AuditBlock(id: "B", type: "MAJOR", value: "B", title: "Major", percentComplete: nil,
                               rules: [planRule(needCourses: 2, applied: 1)])
        #expect(DegreeProgressMath.blockCount(block, planned: 0) == DegreeProgressMath.blockCount(block))
        #expect(DegreeProgressMath.blockCount(block, planned: 3).hasSuffix(" · 3 planned"))
    }

    @Test("a rule count: Penn's n of N, the planned count, both, or nothing")
    func ruleCountPlanned() {
        let counted = planRule(needCourses: 3, applied: 1)
        let uncounted = planRule(needCourses: nil, applied: nil)
        #expect(DegreeProgressMath.ruleCountText(counted, planned: 0) == "1 of 3")
        #expect(DegreeProgressMath.ruleCountText(counted, planned: 2) == "1 of 3 · 2 planned")
        #expect(DegreeProgressMath.ruleCountText(uncounted, planned: 2) == "2 planned")
        #expect(DegreeProgressMath.ruleCountText(uncounted, planned: 0) == nil)
    }

    @Test("the progress view draws the planned layer from the plan")
    func plannedLayerSource() throws {
        let source = try uiSource("DegreeProgressView.swift")
        #expect(source.contains("\"planned\""))
        #expect(source.contains("with plan"))
        // Both projections go through the one helper that also applies the
        // planner's coverage (`AppState.degreeProjection`).
        #expect(source.contains("degreeProjection(degreeID:"))
        #expect(!source.contains("DegreeProjection.make(plan:"))
        #expect(!source.lowercased().contains("recommend"))
    }

    // MARK: Contribution

    @Test("the gain badge hides under half a point and caps at 100")
    func gainBadge() {
        #expect(DegreeProgressMath.gainBadge(0) == nil)
        #expect(DegreeProgressMath.gainBadge(0.4) == nil)
        #expect(DegreeProgressMath.gainBadge(0.5) == "+1%")
        #expect(DegreeProgressMath.gainBadge(1.4) == "+1%")
        #expect(DegreeProgressMath.gainBadge(33.3) == "+33%")
        #expect(DegreeProgressMath.gainBadge(250) == "+100%")
    }

    @Test("a suggestion's line names the degree only when there is one to name")
    func gainLine() {
        let single = DegreeGain(degreeID: "a", degreeLabel: "", requirement: "Calc III", points: 3)
        #expect(DegreePlanAddSheet.gainLine(single) == "calc iii")
        let dual = DegreeGain(degreeID: "a", degreeLabel: "computer science", requirement: "Calc III", points: 3)
        #expect(DegreePlanAddSheet.gainLine(dual) == "computer science · calc iii")
    }

    @Test("the add sheet's search ignores case and spaces, in codes and titles")
    func suggestionMatching() {
        let gain = DegreeGain(degreeID: "a", degreeLabel: "", requirement: "Core", points: 2)
        let course = AdviceCourse(code: "CIS 1200", title: "Big Data Analytics", credits: 1)
        let suggestion = DegreeSuggestion(course: course, gains: [gain])
        #expect(DegreePlanAddSheet.matches(suggestion, query: "cis12"))
        #expect(DegreePlanAddSheet.matches(suggestion, query: "data"))
        #expect(!DegreePlanAddSheet.matches(suggestion, query: "zzz"))
    }

    @Test("the add sheet suggests from the contribution model and the table says what does not count")
    func contributionSource() throws {
        let table = try uiSource("DegreeSemesterTable.swift")
        let sheet = try uiSource("DegreePlanView.swift")
        #expect(table.contains("\"not on an open requirement\""))
        #expect(sheet.contains(".task {"))
        #expect(sheet.contains("DegreeContribution.suggestions("))
        for source in [table, sheet] {
            #expect(!source.contains("\"recommended"))
        }
    }

    @Test("the advisor sheet says what it sends and can undo")
    func advisorSheet() throws {
        let source = try uiSource("DegreeAdvisorView.swift")
        #expect(source.contains("Text(\"plan with ai\")"))
        #expect(source.contains("sends your audit and plan to smooth's server to answer. nothing is stored."))
        #expect(source.contains("askDegreeAdvisor("))
        #expect(source.contains("undoDegreeAdvisor("))
        #expect(source.contains("activeAudits"))
        #expect(source.contains("onStage:"))
        #expect(source.contains("DegreeAdvisor.summary("))
        #expect(!source.lowercased().contains("recommend"))
        #expect(try uiSource("DegreePlanView.swift").contains("DegreeContribution.grouped("))
    }

    @Test("the advisor's starter chips name the next term, or fall back")
    func advisorStarters() {
        let both = DegreeAdvisorView.starters(hasSeveralDegrees: true, nextTermLabel: "spring 2027")
        #expect(both == ["what should i take in spring 2027 for both degrees?",
                         "fill spring 2027 with classes that count",
                         "what's left in each degree?"])
        let one = DegreeAdvisorView.starters(hasSeveralDegrees: false, nextTermLabel: "spring 2027")
        #expect(one == ["what should i take in spring 2027?",
                        "fill spring 2027 with classes that count",
                        "what's left to finish?"])
        let none = DegreeAdvisorView.starters(hasSeveralDegrees: false, nextTermLabel: nil)
        #expect(none.first == "what should i take in next semester?")
    }
}
