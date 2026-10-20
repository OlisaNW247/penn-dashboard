import Foundation
import Testing
@testable import LowHangingFruitKit

/// `ExamDetection`: which titles are exams, and which exam a title names.
///
/// The false-friend list matters as much as the positives. The exam card is
/// the loudest card on the dashboard, so every title below that names an exam
/// without being one is a card that would have shouted for nothing.
@Suite("Exam detection")
struct ExamDetectionTests {

    @Test("titles that are exams", arguments: [
        "Midterm",
        "Midterm 1",
        "MIDTERM #1",
        "midterm exam",
        "Midterm Exam 2",
        "Mid-term 1",
        "Mid term",
        "Midterm Exam II",
        "Exam",
        "Exam 3",
        "Exam II",
        "Exam #2",
        "Exam No. 2",
        "EXAM 1",
        "Final",
        "Finals",
        "Final Exam",
        "Final Examination",
        "final exam (cumulative)",
        "CIS 1200 Final Exam",
        "Prelim",
        "Prelim 2",
        "Test",
        "Test 1",
        "Chapter 3 Test",
        "Unit 2 Test",
        "Take-home exam",
        "Makeup Midterm 1",
        "Midterm 1 (Section 002) [PHYS 151]",
        "MT2",
        "MT-1",
        "First Midterm",
        "2nd Exam",
        "Exam 1: Chapters 1-4",
        "Midterm \u{2013} Thursday",
    ])
    func positives(title: String) {
        #expect(ExamDetection.isExam(title: title), "\(title) should be an exam")
    }

    @Test("quizzes, practice, review and results are not exams", arguments: [
        "Quiz 3",
        "Quiz on midterm material",
        "Practice Exam",
        "Practice Exam 2",
        "Practice Midterm",
        "Mock Final",
        "Sample Final Exam",
        "Midterm Review Session",
        "Review for Midterm 1",
        "Exam 1 Review",
        "Final Exam Study Guide",
        "Exam Prep",
        "Midterm Solutions",
        "Exam 2 solutions posted",
        "Exam 1 Grades",
        "Midterm scores",
        "Final grades",
        "Midterm Regrade Request",
        "Midterm cheat sheet",
        "Old exams",
        "Past Exams",
        "Midterm Feedback Survey",
        "Exam corrections",
    ])
    func practiceAndAftermath(title: String) {
        #expect(!ExamDetection.isExam(title: title), "\(title) should not be an exam")
    }

    @Test("final project, paper and presentation are not exams", arguments: [
        "Final Project",
        "Final project proposal",
        "Final Paper",
        "Final Presentation",
        "Final Report",
        "Final Draft",
        "Final Reflection",
        "Final Submission",
        "Final thoughts",
        "Midterm Project",
        "Midterm Paper",
    ])
    func finalWorkIsNotAnExam(title: String) {
        #expect(!ExamDetection.isExam(title: title), "\(title) should not be an exam")
    }

    @Test("whole words only: contest, testing, latest, examine, preliminary", arguments: [
        "Contest",
        "Programming Contest 2",
        "Testing",
        "Testing and Debugging",
        "Latest news",
        "Examine the data",
        "Examples",
        "Preliminary proposal",
        "Finally done",
        "Finalize your team",
        "Attestation",
        "Protest reading",
    ])
    func wholeWordsOnly(title: String) {
        #expect(!ExamDetection.isExam(title: title), "\(title) should not be an exam")
    }

    @Test("the programming and statistics senses of test are not exams", arguments: [
        "Test cases",
        "Write test cases",
        "Test suite",
        "Unit tests",
        "Unit test for Stack",
        "Hidden test results",
        "Integration tests",
        "t-test lab",
        "Hypothesis test",
        "Chi-square test",
        "Test your knowledge",
        "Test-driven development",
        "Test data",
    ])
    func testWordSenses(title: String) {
        #expect(!ExamDetection.isExam(title: title), "\(title) should not be an exam")
    }

    @Test("a calendar row that says there are no exams is not an exam", arguments: [
        "Yom Kippur (no exams/assignments)",
        "No exams today",
        "Post-exam survey",
        "Pre-exam check-in",
        "Finals Week",
        "Midterm week",
        "Exam schedule",
        "Exam Policy",
        "Midterm topics",
    ])
    func informationRows(title: String) {
        #expect(!ExamDetection.isExam(title: title), "\(title) should not be an exam")
    }

    @Test("non-exam, non-title text")
    func ordinaryTitles() {
        #expect(!ExamDetection.isExam(title: ""))
        #expect(!ExamDetection.isExam(title: "   "))
        #expect(!ExamDetection.isExam(title: "Homework 3"))
        #expect(!ExamDetection.isExam(title: "Lab 4 report"))
        #expect(!ExamDetection.isExam(title: "Reading: Chapter 5"))
    }

    @Test("an explicit override beats the title in both directions")
    func override() {
        #expect(ExamDetection.isExam(title: "Homework 3", override: true))
        #expect(!ExamDetection.isExam(title: "Midterm 1", override: false))
        #expect(ExamDetection.isExam(title: "Midterm 1", override: nil))
        #expect(!ExamDetection.isExam(title: "Homework 3", override: nil))
    }

    // MARK: - Identity

    private func identity(_ title: String, course: String = "PHYS 151") -> ExamIdentity? {
        ExamDetection.examIdentity(title: title, course: course)
    }

    @Test("every spelling of Midterm 1 agrees")
    func midtermOneAgrees() throws {
        let spellings = [
            "Midterm 1", "MIDTERM #1", "Midterm Exam 1", "midterm exam #1", "Mid-term 1",
            "Mid term 1", "Midterm 01", "Midterm I", "MIDTERM EXAM I", "1st Midterm",
            "First Midterm", "MT1", "MT-1", "Midterm No. 1", "Midterm 1 (Oct 23)",
            "Midterm 1: Chapters 1-4", "Midterm 1 (Section 002) [PHYS 151]",
        ]
        let expected = try #require(identity("Midterm 1"))
        for spelling in spellings {
            #expect(identity(spelling) == expected, "\(spelling) should be Midterm 1")
        }
        #expect(expected.kind == .midterm)
        #expect(expected.ordinal == 1)
    }

    @Test("different numbers, kinds and sittings do not agree")
    func distinctExams() {
        #expect(identity("Midterm 1") != identity("Midterm 2"))
        #expect(identity("Midterm 1") != identity("Exam 1"))
        #expect(identity("Midterm 1") != identity("Final Exam"))
        #expect(identity("Midterm 1") != identity("Makeup Midterm 1"))
        #expect(identity("Midterm 1") != identity("Midterm 1 Retake"))
        // The honest limit: unnumbered and numbered are not equated on the
        // title alone (see ExamIdentity's comment).
        #expect(identity("Midterm") != identity("Midterm 1"))
    }

    @Test("final exam spellings agree, and unnumbered exams have no ordinal")
    func finalAgrees() throws {
        let expected = try #require(identity("Final Exam"))
        #expect(expected.kind == .final)
        #expect(expected.ordinal == nil)
        for spelling in ["Final", "FINAL EXAM", "Final Examination", "final exam (cumulative)", "CIS 1200 Final Exam"] {
            #expect(identity(spelling) == expected, "\(spelling) should be the final exam")
        }
        #expect(identity("Midterm") == identity("Mid-term Exam"))
    }

    @Test("the course is part of the identity and is normalised")
    func courseNormalisation() {
        #expect(identity("Midterm 1", course: "PHYS 151") != identity("Midterm 1", course: "CIS 1200"))
        #expect(identity("Midterm 1", course: "PHYS 151") == identity("Midterm 1", course: "phys 0151"))
        #expect(identity("Midterm 1", course: "PHYS 151") == identity("Midterm 1", course: "PHYS-151"))
        // A zero inside the number is not a leading zero.
        #expect(identity("Midterm 1", course: "CIS 1200") != identity("Midterm 1", course: "CIS 12"))
    }

    @Test("a title that is not an exam has no identity")
    func noIdentity() {
        #expect(identity("Quiz 3") == nil)
        #expect(identity("Final Project") == nil)
        #expect(identity("Homework 3") == nil)
    }

    /// The ordinal of an exam title, failing if the title is not an exam at
    /// all (so "no ordinal" cannot be satisfied by "no identity").
    private func ordinal(of title: String, sourceLocation: SourceLocation = #_sourceLocation) -> Int?? {
        guard let found = identity(title) else {
            Issue.record("\(title) should be an exam", sourceLocation: sourceLocation)
            return nil
        }
        return .some(found.ordinal)
    }

    @Test("a date, weight, time or quantity after the exam word is not its number")
    func numbersThatAreNotOrdinals() {
        #expect(ordinal(of: "Midterm 10/23") == .some(nil))
        #expect(ordinal(of: "Midterm 25%") == .some(nil))
        #expect(ordinal(of: "Final Exam 9:00 am") == .some(nil))
        #expect(ordinal(of: "Final Exam 9 am") == .some(nil))
        #expect(ordinal(of: "Midterm 3 hours") == .some(nil))
        #expect(ordinal(of: "Final Exam 2026") == .some(nil))
        #expect(ordinal(of: "Midterm 2: 10/23") == .some(2))
    }

    @Test("a lone I or V is a numeral only in capitals")
    func romanNumerals() {
        #expect(ordinal(of: "Exam I") == .some(1))
        #expect(ordinal(of: "Exam V") == .some(5))
        #expect(ordinal(of: "exam i") == .some(nil))
        #expect(ordinal(of: "exam ii") == .some(2))
        #expect(ordinal(of: "Exam IV") == .some(4))
    }

    @Test("midterm spellings agree with the announcement classifier")
    func sharedVocabulary() {
        // `AnnouncementTaskClassifier` treats midterm, mid term and mid-term as
        // one noun; the exam rule must not disagree about that.
        for spelling in ["midterm", "mid term", "mid-term"] {
            #expect(AnnouncementTaskClassifier.taskKind(in: "\(spelling) 1") == .submission)
            #expect(ExamDetection.isExam(title: "\(spelling) 1"))
        }
    }
}
