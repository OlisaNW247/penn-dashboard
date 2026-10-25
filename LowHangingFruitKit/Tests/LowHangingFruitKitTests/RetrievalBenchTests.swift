import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// A measuring bench, not a test: it turns a real `course-knowledge.json`
/// copied off a phone into the exact excerpt blocks `ask` would send for a
/// list of questions, so retrieval can be judged on the student's own
/// materials instead of fixtures (`docs/TREE_IMPROVEMENT_PLAN.md`, section 10).
///
/// It does nothing, and prints nothing, unless `LHF_BENCH_KNOWLEDGE` names a
/// readable file, so the normal suite is unaffected and no student data is
/// ever needed in the repo. The file lives outside the checkout and must stay
/// there: it holds the student's course text.
///
///     LHF_BENCH_KNOWLEDGE=~/lhf-bench/course-knowledge.json \
///       swift test --no-parallel --filter RetrievalBenchTests
///
/// Optional: `LHF_BENCH_QUESTIONS` (a text file, one question per line, `#`
/// comments, a line starting with `>` is a follow-up to the line before it)
/// and `LHF_BENCH_ASKED_AT` (ISO 8601; otherwise the file's newest document
/// date, so the recency rule gives the same answer on every run).
///
/// The excerpt block comes from `BackendAssistantResponder.excerptBlock`, the
/// function the phone runs, called with a context built the way
/// `AssistantConversation.send` builds the retrieval inputs: the stored
/// knowledge base, `askedAt`, and the previous questions of the chain. The
/// matcher is given the knowledge base's own `courses`, as the phone does.
/// Nothing is asserted: the bench measures and the reader judges.
@Suite("Retrieval bench (needs LHF_BENCH_KNOWLEDGE)", .serialized)
struct RetrievalBenchTests {
    static let builtInQuestions = """
    when is the ACCT 1010 midterm?
    where is the CIS 2620 midterm?
    what's the late policy in CIS 4500?
    what's the late policy for LGST 1010?
    how much is the final worth in PHYS 0151?
    how is my grade broken down in CIS 2400?
    what did my professor say this week in CIS 2400?
    any announcements in LGST 1010 lately?
    what do I need for lab this week in PHYS 0151?
    when are office hours for ACCT 1010?
    who is the TA for CIS 3990?
    what's due tomorrow?
    what's due this week in CIS 4500?
    is lecture cancelled tomorrow in ACCT 1010?
    where does CIS 2400 lecture meet?
    what's the textbook for PHYS 0151?
    can I get an extension on HW 3 in CIS 4500?
    how do regrades work in CIS 2400?
    what's on the CIS 2620 midterm?
    explain the pumping lemma from lecture in CIS 2620
    did I submit HW 4 for CIS 4500?
    what's the attendance policy in PHYS 0151?
    when is the CIS 3990 project due?
    are ACCT 1010 lectures recorded?
    what's the schedule for week 8 in CIS 4500?
    what are the lab report requirements in PHYS 0151?
    when's the exam in my cis class?
    > what about next week?
    how many points is the ACCT 1010 project worth?
    is there a curve in CIS 2620?
    """

    /// One question line: its text and whether it follows the line before.
    struct BenchQuestion: Equatable {
        let text: String
        let followsPrevious: Bool
    }

    static func parseQuestions(_ raw: String) -> [BenchQuestion] {
        raw.split(whereSeparator: \.isNewline).compactMap { line -> BenchQuestion? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
            if trimmed.hasPrefix(">") {
                let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : BenchQuestion(text: text, followsPrevious: true)
            }
            return BenchQuestion(text: trimmed, followsPrevious: false)
        }
    }

    static func parseISO8601(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private static func environmentPath(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return (value as NSString).expandingTildeInPath
    }

    @Test("prints the excerpt block the phone would send for each question")
    func bench() throws {
        guard let knowledgePath = Self.environmentPath("LHF_BENCH_KNOWLEDGE"),
              let data = FileManager.default.contents(atPath: knowledgePath)
        else { return }

        // Decoded exactly as `CourseKnowledgeStore.load()` does (same type,
        // same date strategy), except that a failure is reported here and
        // not turned into an empty base.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let knowledge: CourseKnowledgeBase
        do {
            knowledge = try decoder.decode(CourseKnowledgeBase.self, from: data)
        } catch {
            print("RETRIEVAL BENCH: could not decode \(knowledgePath): \(error)")
            return
        }

        // askedAt: pinned so the recency rule is reproducible.
        let askedAt: Date
        let askedAtSource: String
        if let text = ProcessInfo.processInfo.environment["LHF_BENCH_ASKED_AT"], let date = Self.parseISO8601(text) {
            askedAt = date
            askedAtSource = "LHF_BENCH_ASKED_AT"
        } else if let newest = knowledge.documents.map({ $0.shownPostedAt ?? $0.updatedAt ?? $0.fetchedAt }).max() {
            askedAt = newest
            askedAtSource = "newest document date in the file"
        } else {
            askedAt = Date(timeIntervalSince1970: 0)
            askedAtSource = "epoch (the file holds no documents)"
        }

        var questionSource = "built-in list"
        var questions = Self.parseQuestions(Self.builtInQuestions)
        if let path = Self.environmentPath("LHF_BENCH_QUESTIONS") {
            if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
                questions = Self.parseQuestions(raw)
                questionSource = path
            } else {
                print("RETRIEVAL BENCH: could not read LHF_BENCH_QUESTIONS (\(path)); using the built-in list")
            }
        }

        var byKind: [String: Int] = [:]
        for document in knowledge.documents { byKind[document.kind.rawValue, default: 0] += 1 }
        let kindSummary = byKind.keys.sorted().map { "\($0) \(byKind[$0] ?? 0)" }.joined(separator: ", ")
        let iso = ISO8601DateFormatter()
        print("RETRIEVAL BENCH")
        print("file: \(knowledgePath)")
        print("documents: \(knowledge.documents.count) (\(kindSummary))")
        print("courses: \(knowledge.courses.count) sites, \(Set(knowledge.courses.map(\.code)).count) codes")
        print("askedAt: \(iso.string(from: askedAt)) (\(askedAtSource))")
        print("questions: \(questions.count) from \(questionSource)")

        var zeroHits = 0
        var hitsButNoScope = 0
        // Questions of the current chain, newest first. A line that is not a
        // follow-up starts a fresh chain, like opening a new conversation.
        var earlier: [String] = []
        for (index, item) in questions.enumerated() {
            if !item.followsPrevious || index == 0 { earlier = [] }
            let previous = earlier.first
            let older = Array(earlier.dropFirst())
            let context = AssistantContext(
                courseCodes: Array(Set(knowledge.courses.map(\.code))).sorted(),
                contextDocument: "",
                askedAt: askedAt,
                knowledge: knowledge,
                previousQuestion: previous,
                olderQuestions: older
            )
            let block = BackendAssistantResponder.excerptBlock(question: item.text, context: context)
            let followUp = FollowUpRetrieval.resolve(
                question: item.text, previousQuestion: previous, olderQuestions: older, courses: knowledge.courses
            )
            let recency = RecencyIntent.detect(in: followUp.query)
            let scope = followUp.course.map { "\($0.code) (\(knowledge.courseIDs(forCode: $0.code).count) site(s))" } ?? "unscoped"

            print("")
            print("Q\(index + 1)\(item.followsPrevious && index > 0 ? " (follow-up)" : ""): \(item.text)")
            if followUp.query != item.text { print("  searched as: \(followUp.query)") }
            print("  scope: \(scope)")
            if let recency {
                print("  recency rule: fired (window \(recency.windowDays.map { "\($0) days" } ?? "none")), newest posts first")
            } else {
                print("  recency rule: not fired")
            }

            // The block does not carry scores, so the same search the block
            // ran is repeated for them. With the recency rule fired the
            // leading lines are picks (score 0), not BM25 hits.
            let search = CourseSearch(knowledge: knowledge)
            let scored = search.search(
                followUp.query,
                courseIDs: followUp.course.map { knowledge.courseIDs(forCode: $0.code) },
                preferredComponent: DocumentComponent.mentioned(in: item.text),
                limit: BackendAssistantResponder.excerptLimit,
                perDocument: BackendAssistantResponder.excerptsPerDocument
            )
            let scores = scored.map { String(format: "%.2f", $0.score) }.joined(separator: " ")
            print("  bm25 scores of the search: \(scores.isEmpty ? "none" : scores)")

            let lines = block.text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[") }
            if lines.isEmpty {
                print("  excerpts: none")
                zeroHits += 1
            } else {
                for line in lines { print("  \(line.prefix(160))") }
                if followUp.course == nil { hitsButNoScope += 1 }
            }
            earlier.insert(item.text, at: 0)
        }
        print("")
        print("SUMMARY: \(questions.count) questions, \(zeroHits) with 0 hits, \(hitsButNoScope) with hits but no scope")
        #expect(true)
    }
}
