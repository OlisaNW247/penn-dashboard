import Foundation
import Testing
@testable import LowHangingFruitKit

/// D8 of `docs/HARDENING_PLAN_2026-10-25.md`: bound text work. The ask
/// question is cut before it is classified, because `classify`'s regular
/// expressions backtrack (two `.*` in one pattern) and a pasted syllabus
/// would otherwise freeze the main actor.
@Suite("Ask question length bound")
struct QuestionLengthBoundTests {

    private static let courses = [
        CourseSummary(courseID: "1", code: "CIS 2400", name: "CIS 2400 Machine Architecture", url: nil),
    ]

    private static func elapsed(_ work: () -> Void) -> TimeInterval {
        let start = Date()
        work()
        return Date().timeIntervalSince(start)
    }

    @Test("a pasted 30,000-character question is parsed inside the budget and carried at the cap")
    func hugeQuestionIsBounded() {
        // Every "what" is a place the submission pattern starts from and has
        // to backtrack to the end of the text from: quadratic without a cap.
        let pasted = String(repeating: "what is due ", count: 2_500)
        #expect(pasted.count >= 30_000)
        var parsed: ParsedQuestion?
        let seconds = Self.elapsed { parsed = QuestionParser.parse(pasted, courses: Self.courses) }
        #expect(seconds < 2.0, "parsing took \(seconds)s; the question is not being bounded")
        #expect((parsed?.original.count ?? .max) <= QuestionParser.maxQuestionLength)
    }

    @Test("an adversarial question at the cap stays cheap")
    func adversarialQuestionAtTheCapIsCheap() {
        let hostile = "what " + String(repeating: "not ", count: 600)   // ~2,400 characters, no "submit" to end the match
        let seconds = Self.elapsed { _ = QuestionParser.parse(hostile, courses: Self.courses) }
        #expect(seconds < 2.0, "took \(seconds)s")
    }

    @Test("the cut is at the cap, on a character boundary, and short questions are untouched")
    func theCutIsExact() {
        let exact = String(repeating: "a", count: QuestionParser.maxQuestionLength)
        #expect(QuestionParser.bounded(exact) == exact)
        #expect(QuestionParser.bounded(exact + "b").count == QuestionParser.maxQuestionLength)
        #expect(QuestionParser.bounded("") == "")
        #expect(QuestionParser.bounded("When is my next exam?") == "When is my next exam?")

        // A grapheme cluster (family emoji, 7 scalars) is one character and
        // is not cut in half, and an accent stays with its letter.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let emoji = String(repeating: family, count: QuestionParser.maxQuestionLength + 5)
        let cut = QuestionParser.bounded(emoji)
        #expect(cut.count == QuestionParser.maxQuestionLength)
        #expect(cut == String(repeating: family, count: QuestionParser.maxQuestionLength))
        let accents = String(repeating: "e\u{0301}", count: QuestionParser.maxQuestionLength + 3)
        #expect(QuestionParser.bounded(accents).count == QuestionParser.maxQuestionLength)
        #expect(QuestionParser.bounded(accents).unicodeScalars.count == 2 * QuestionParser.maxQuestionLength)
    }

    @Test("an ordinary question parses exactly as before, and a keyword inside the cap is still found")
    func ordinaryQuestionsAreUnchanged() {
        #expect(QuestionParser.parse("when is my next exam?", courses: Self.courses).intent
            == .nextItem(kind: .exam))
        #expect(QuestionParser.parse("  what classes am I taking  ", courses: Self.courses).intent == .courseList)
        #expect(QuestionParser.parse("what classes am I taking", courses: Self.courses).original
            == "what classes am I taking")

        // A long preamble well inside the cap, then the question.
        let preamble = String(repeating: "Here is some context from my syllabus. ", count: 20)   // ~780 characters
        let parsed = QuestionParser.parse(preamble + "Anything overdue?", courses: Self.courses)
        #expect(parsed.intent == .overdue)
    }
}
