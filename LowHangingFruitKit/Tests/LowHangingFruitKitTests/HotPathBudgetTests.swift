import Foundation
import Testing
@testable import LowHangingFruitKit

/// D2 of `docs/HARDENING_PLAN_2026-10-25.md`: the per-item predicates the
/// dashboard rebuild runs for every item the student has ever had.
///
/// Two kinds of test. The **budget** tests run the real work at the size of a
/// heavy account and fail only if something quadratic, or a regex compiled
/// per call, creeps back; the budgets are generous (several times what a
/// slow CI machine needs) because a flaky timing test teaches people to
/// ignore it. The **equivalence** tests pin that the cache answers exactly
/// what the uncached call did.
@Suite("Per-item predicates stay cheap")
struct HotPathBudgetTests {

    // MARK: Fixture

    private static let courses = ["CIS 1200", "CIS 2400", "MATH 1410", "PHYS 0151", "ECON 0100", "WRIT 0020"]
    private static let stems = [
        "Homework", "Problem Set", "Lab", "Project", "Quiz", "Midterm Exam", "Final Exam",
        "Reading Response", "Attendance", "Participation", "Worksheet", "Essay",
    ]

    /// `count` distinct titles. Distinct on purpose: a title seen twice is a
    /// cache hit, and the budget has to hold for the first pass over a new
    /// account.
    private static func titles(_ count: Int, tag: String) -> [String] {
        (0..<count).map { "\(stems[$0 % stems.count]) \($0 / stems.count + 1) \(tag)" }
    }

    private static func elapsed(_ work: () -> Void) -> TimeInterval {
        let start = Date()
        work()
        return Date().timeIntervalSince(start)
    }

    // MARK: Budgets

    @Test("pairing 500 Canvas rows with 500 Gradescope rows finishes inside the budget")
    func pairingBudget() {
        let tag = UUID().uuidString
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var canvas: [Assignment] = []
        var gradescope: [Assignment] = []
        for (index, title) in Self.titles(500, tag: tag).enumerated() {
            let course = Self.courses[index % 3]   // three classes: ~170 a side each, so the same-course pairs are many
            let due = base.addingTimeInterval(Double(index) * 3_600)
            canvas.append(Assignment(source: .canvas, sourceID: "c\(index)", kind: .assignment,
                                     course: course, title: title, dueAt: due, url: nil))
            gradescope.append(Assignment(source: .gradescope, sourceID: "g\(index)", kind: .assignment,
                                         course: course, title: title.uppercased(), dueAt: due, url: nil))
        }
        var pairs: [AssignmentDeduplicator.Match] = []
        let seconds = Self.elapsed {
            pairs = AssignmentDeduplicator.matchPairs(canvasItems: canvas, gradescopeItems: gradescope)
            _ = AssignmentDeduplicator.merge(canvasItems: canvas, gradescopeItems: gradescope, pairs: pairs)
        }
        #expect(pairs.count > 400, "the fixture must actually pair, got \(pairs.count)")
        #expect(seconds < 2.0, "pairing 500 + 500 took \(seconds)s; titles are being normalised per pair again")
    }

    @Test("classifying 500 items, forty rebuilds running, finishes inside the budget")
    func classificationBudget() {
        let items = Self.titles(500, tag: UUID().uuidString)
        var hits = 0
        let seconds = Self.elapsed {
            for _ in 0..<40 {
                for (index, title) in items.enumerated() {
                    let course = Self.courses[index % Self.courses.count]
                    if WorkItem.looksLikeAssessment(title: title, kind: .assignment) { hits += 1 }
                    if GradeItemClassifier.isAttendanceCategoryName(title) { hits += 1 }
                    if AnnouncementClassReminder.isAttendanceInstruction(title) { hits += 1 }
                    if NonClassCanvasSite.matches(course) { hits += 1 }
                    hits += TitleNormalizer.tokens(title).count
                    hits += CourseMatcher.normalize(course).count
                    hits += AssignmentDeduplicator.normalize(title).count
                }
            }
        }
        #expect(hits > 0)
        #expect(seconds < 2.0, "20,000 item passes took \(seconds)s; a pattern is being compiled per call again")
    }

    // MARK: The caches answer what the uncached call did

    @Test("RegexCache.contains agrees with range(of:options:.regularExpression) on the patterns the app uses")
    func containsMatchesTheUncachedCall() {
        let patterns = [
            #"(?i)\b(midterms?|exams?|quiz|quizzes|prelims?|finals|final exam)\b"#,
            #"(?i)\bquiz(zes)?\b"#,
            #"(?i)\b(attendance|participation)\b"#,
            #"^(?i)TAP\s+(19|20)\d{2}$"#,
            #"\bdue\b"#,
            #"^\s*([a-z]{2,5})\s?-?(\d{3,4}[a-z]?)"#,
        ]
        var rng = SeededGenerator(seed: 7)
        let words = ["Midterm", "exam", "Quiz", "quizzes", "Final Exam", "TAP 2028", "tap  1999", "TAP 20x8",
                     "attendance", "Participation grade", "due", "undue", "cis 2400", "PHYS-0151", "café", "日本語",
                     "", " ", "x", "hw 3", "Homework 3 due friday"]
        var samples: [String] = words
        for _ in 0..<300 {
            let count = Int.random(in: 1...4, using: &rng)
            samples.append((0..<count).map { _ in words.randomElement(using: &rng)! }.joined(separator: " "))
        }
        for pattern in patterns {
            for sample in samples {
                let expected = sample.range(of: pattern, options: .regularExpression) != nil
                #expect(RegexCache.contains(pattern, in: sample) == expected, "\(pattern) on \"\(sample)\"")
            }
        }
        // Case-insensitive, the way the announcement helpers asked for it.
        for sample in samples {
            let pattern = #"\battend\b"#
            let expected = sample.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            #expect(RegexCache.contains(pattern, in: sample, options: [.caseInsensitive]) == expected)
        }
    }

    @Test("RegexCache.replacing agrees with replacingOccurrences, and TitleNormalizer is unchanged by it")
    func replacingMatchesTheUncachedCall() {
        for sample in ["Problem Sets 3", "HW #3: Intro!", "  spaced   out  ", "Café ÉCOLE 2", ""] {
            #expect(
                RegexCache.replacing(#"[^a-z0-9\s]"#, in: sample.lowercased(), with: " ")
                    == sample.lowercased().replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
            )
        }
        #expect(TitleNormalizer.tokens("Problem Set 03") == ["hw", "3"])
        #expect(TitleNormalizer.tokens("HW #3 -- Intro!") == ["hw", "3", "intro"])
    }

    @Test("a pattern that does not compile matches nothing and is not retried")
    func badPatternIsHarmless() {
        #expect(RegexCache.regex("([unclosed") == nil)
        #expect(!RegexCache.contains("([unclosed", in: "anything"))
        #expect(RegexCache.replacing("([unclosed", in: "text", with: "x") == "text")
    }

    @Test("the regex cache is bounded")
    func regexCacheIsBounded() {
        for index in 0..<(RegexCache.capacity * 2) {
            _ = RegexCache.contains("bound-test-\(index)-\(UUID().uuidString)", in: "x")
        }
        #expect(RegexCache.entryCount <= RegexCache.capacity)
    }

    @Test("title tokens are the same cached as computed, and the memos are bounded")
    func titleTokenMemosAreExactAndBounded() {
        let titles = Self.titles(40, tag: "exact") + ["HW3", "PSET 2", "CombinedWorksheets6-7", "  ", ""]
        let first = titles.map(AssignmentDeduplicator.normalize)
        let second = titles.map(AssignmentDeduplicator.normalize)     // served from the memo
        #expect(first == second)
        #expect(AssignmentDeduplicator.normalize("HW3") == ["hw", "3"])
        let normalizerFirst = titles.map(TitleNormalizer.tokens)
        #expect(normalizerFirst == titles.map(TitleNormalizer.tokens))
        #expect(TitleNormalizer.tokens("Problem Set 03") == ["hw", "3"])

        let capacity = AssignmentDeduplicator.tokenMemo.capacity
        for index in 0..<(capacity + 50) {
            _ = AssignmentDeduplicator.normalize("bounded title \(index) \(UUID().uuidString)")
            _ = TitleNormalizer.tokens("bounded title \(index) \(UUID().uuidString)")
        }
        #expect(AssignmentDeduplicator.tokenMemo.count <= capacity)
        #expect(TitleNormalizer.tokenMemo.count <= TitleNormalizer.tokenMemo.capacity)
    }

    @Test("a program-year site is still recognised, cached or not")
    func nonClassSiteVerdictsAreExact() {
        for key in ["TAP 2028", "tap 1999", " TAP 2030 ", "TAP 2028-001 202630 Program", "CIS 1200", "TAP", "TAP 20x8", "ACCT 1010 (Hail) - Fall 2026"] {
            let first = NonClassCanvasSite.matches(key)
            #expect(NonClassCanvasSite.matches(key) == first, "\(key)")
        }
        #expect(NonClassCanvasSite.matches("TAP 2028"))
        #expect(NonClassCanvasSite.matches(" tap 1999 "))
        #expect(!NonClassCanvasSite.matches("CIS 1200"))
        #expect(!NonClassCanvasSite.matches("TAP 20x8"))
    }
}
