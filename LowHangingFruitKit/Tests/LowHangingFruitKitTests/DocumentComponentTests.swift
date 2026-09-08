import Foundation
import Testing
@testable import LowHangingFruitKit

/// PHYS 0151 is one Canvas site holding a 1.0 CU lecture and a 0.5 CU
/// pass/fail lab, each with its own syllabus. `DocumentComponent` is the
/// heuristic that tells them apart so retrieval can prefer the right one.
@Suite("Document component classification")
struct DocumentComponentTests {
    @Test("lab syllabus classified by title")
    func labByTitle() {
        let component = DocumentComponent.classify(
            title: "PHYS 0151 Lab Syllabus",
            text: "Meets weekly. Bring a laptop."
        )
        #expect(component == .lab)
    }

    @Test("lab syllabus classified by head text when the title is generic")
    func labByHeadText() {
        let component = DocumentComponent.classify(
            title: "Syllabus",
            text: "This is the laboratory syllabus for PHYS 0151. Labs meet Tuesdays in the lab room. Bring safety goggles."
        )
        #expect(component == .lab)
    }

    @Test("recitation document classified by title")
    func recitation() {
        let component = DocumentComponent.classify(
            title: "Recitation Overview",
            text: "Recitation sections meet Fridays."
        )
        #expect(component == .recitation)
    }

    @Test("lecture syllabus classified by title and lecture-ish head text")
    func lectureSyllabus() {
        let component = DocumentComponent.classify(
            title: "PHYS 0151 Lecture Syllabus",
            text: "Lecture meets Mondays and Wednesdays. There is a midterm and a final exam. Problem sets are due weekly. Homework is graded."
        )
        #expect(component == .lecture)
    }

    @Test("plain announcement classified as general")
    func announcementIsGeneral() {
        let component = DocumentComponent.classify(
            title: "Welcome to the course",
            text: "Office hours start Monday. Check the calendar for details."
        )
        #expect(component == .general)
    }

    @Test("ambiguous document with no strong signal classified as general")
    func ambiguousIsGeneral() {
        let component = DocumentComponent.classify(
            title: "Syllabus",
            text: "This course covers the fundamentals of the subject. See the calendar for the schedule."
        )
        #expect(component == .general)
    }

    @Test("'Lab 3 due Friday' assignment classified as lab")
    func labAssignment() {
        let component = DocumentComponent.classify(
            title: "Lab 3 due Friday",
            text: "Submit your writeup by 11:59pm."
        )
        #expect(component == .lab)
    }

    @Test("mentioned(in:) finds a lab question")
    func mentionedLab() {
        #expect(DocumentComponent.mentioned(in: "what's the lab late policy") == .lab)
    }

    @Test("mentioned(in:) finds a lecture question via 'class'")
    func mentionedLecture() {
        #expect(DocumentComponent.mentioned(in: "how is the class graded") == .lecture)
    }

    @Test("mentioned(in:) finds a recitation question")
    func mentionedRecitation() {
        #expect(DocumentComponent.mentioned(in: "when is recitation") == .recitation)
    }

    @Test("mentioned(in:) returns nil for a question naming no component")
    func mentionedNone() {
        #expect(DocumentComponent.mentioned(in: "when is the midterm") == nil)
    }

    @Test("mentioned(in:) prefers lab when both lab and class appear")
    func mentionedLabWins() {
        #expect(DocumentComponent.mentioned(in: "class lab report") == .lab)
    }

    @Test("label is empty for general and non-empty for named components")
    func labelText() {
        #expect(DocumentComponent.general.label == "")
        #expect(DocumentComponent.lab.label == "lab")
        #expect(DocumentComponent.recitation.label == "recitation")
        #expect(DocumentComponent.lecture.label == "lecture")
    }
}
