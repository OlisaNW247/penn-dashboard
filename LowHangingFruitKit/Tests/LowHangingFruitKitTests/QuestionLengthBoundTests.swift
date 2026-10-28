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

    @Test("over the cap the head and the tail are kept, at the cap, on character boundaries; anything that fits is untouched")
    func theCutKeepsHeadAndTail() {
        let max = QuestionParser.maxQuestionLength
        let exact = String(repeating: "a", count: max)
        #expect(QuestionParser.bounded(exact) == exact)
        #expect(QuestionParser.bounded("") == "")
        #expect(QuestionParser.bounded("When is my next exam?") == "When is my next exam?")

        // One over: cut, to exactly the cap, head then tail.
        let over = String(repeating: "h", count: QuestionParser.headLength) + String(repeating: "m", count: 700) + String(repeating: "t", count: 499)
        let cut = QuestionParser.bounded(over)
        #expect(cut.count == max)
        #expect(cut.hasPrefix(String(repeating: "h", count: QuestionParser.headLength) + " "))
        #expect(cut.hasSuffix(String(repeating: "t", count: 499)))
        #expect(!cut.contains("m"))
        #expect(QuestionParser.bounded(exact + "b").count == max)
        #expect(QuestionParser.bounded(exact + "b").hasSuffix("ab"))

        // A grapheme cluster (family emoji, 7 scalars) is one character and
        // is not cut in half at either end, and an accent stays with its letter.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let emoji = String(repeating: family, count: max + 5)
        let emojiCut = QuestionParser.bounded(emoji)
        #expect(emojiCut.count == max)
        #expect(emojiCut == String(repeating: family, count: QuestionParser.headLength) + " "
            + String(repeating: family, count: max - QuestionParser.headLength - 1))
        let accents = String(repeating: "e\u{0301}", count: max + 3)
        let accentCut = QuestionParser.bounded(accents)
        #expect(accentCut.count == max)
        #expect(accentCut.unicodeScalars.filter { $0 == "\u{0301}" }.count == max - 1)   // every kept e still has its accent
    }

    @Test("a question typed under a long paste is still the one that is answered")
    func theQuestionAtTheTailSurvives() {
        let paste = String(repeating: "Here is some context from my syllabus about the course. ", count: 600)   // ~36,000 characters
        #expect(paste.count > 30_000)
        let parsed = QuestionParser.parse(paste + "\n\nAnything overdue?", courses: Self.courses)
        #expect(parsed.intent == .overdue)
        #expect(parsed.original.count <= QuestionParser.maxQuestionLength)
        #expect(parsed.original.hasSuffix("Anything overdue?"))
        // And the head is still there for a question typed above the paste.
        let headFirst = QuestionParser.parse("When is my next exam? " + paste, courses: Self.courses)
        #expect(headFirst.intent == .nextItem(kind: .exam))
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
