import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Submission reads")
struct SubmissionReadTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Only a submitted verdict cancels")
    func cancels() {
        for (verdict, expected) in [(SubmissionRead.Verdict.submitted, true), (.unsubmitted, false), (.unknown, false)] {
            let r = SubmissionRead(assignmentID: "1", readAt: at, source: .grades, verdict: verdict)
            #expect(r.cancels == expected)
        }
    }

    @Test("Planner items map to verdicts")
    func plannerMapping() {
        let items = [
            CanvasPlannerItem(plannableType: "assignment", plannableID: "1", submitted: true, assignmentID: "1"),
            CanvasPlannerItem(plannableType: "assignment", plannableID: "2", markedComplete: true, assignmentID: "2"),
            CanvasPlannerItem(plannableType: "assignment", plannableID: "3", submitted: false, assignmentID: "3"),
            CanvasPlannerItem(plannableType: "assignment", plannableID: "4", assignmentID: "4"),
            CanvasPlannerItem(plannableType: "planner_note", plannableID: "5", submitted: true),
        ]
        let reads = SubmissionRead.verdicts(fromPlanner: items, readAt: at)
        #expect(reads.map(\.assignmentID) == ["1", "2", "3", "4"])
        #expect(reads.map(\.verdict) == [.submitted, .submitted, .unsubmitted, .unknown])
        #expect(reads.allSatisfy { $0.source == .planner && $0.readAt == at })
        #expect(reads.map(\.cancels) == [true, true, false, false])
    }

    @Test("A tick wins over an explicit unsubmitted flag, and no id means no read")
    func tickAndNoID() {
        let both = CanvasPlannerItem(plannableType: "assignment", plannableID: "1", markedComplete: true,
                                     submitted: false, assignmentID: "1")
        #expect(SubmissionRead.verdicts(fromPlanner: [both], readAt: at).first?.verdict == .submitted)
        let none = CanvasPlannerItem(plannableType: "wiki_page", plannableID: "9", submitted: true)
        #expect(SubmissionRead.verdicts(fromPlanner: [none], readAt: at).isEmpty)
        #expect(SubmissionRead.verdicts(fromPlanner: [], readAt: at).isEmpty)
    }

    @Test("Excused work reads as submitted; not excused and not submitted stays unsubmitted")
    func excused() {
        let json = """
        [{"plannable_type":"assignment","plannable_id":1,"plannable":{"title":"A","assignment_id":1},
          "submissions":{"submitted":false,"excused":true}},
         {"plannable_type":"assignment","plannable_id":2,"plannable":{"title":"B","assignment_id":2},
          "submissions":{"submitted":false,"excused":false}},
         {"plannable_type":"assignment","plannable_id":3,"plannable":{"title":"C","assignment_id":3},
          "submissions":{"submitted":false,"graded":true}}]
        """
        let r = CanvasStructuredDecoding.decode(CanvasPlannerItem.self, fromPages: [Data(json.utf8)])
        #expect(r.elements.map(\.excused) == [true, false, nil])
        let reads = SubmissionRead.verdicts(fromPlanner: r.elements, readAt: at)
        #expect(reads.map(\.verdict) == [.submitted, .unsubmitted, .unsubmitted])
    }
}
