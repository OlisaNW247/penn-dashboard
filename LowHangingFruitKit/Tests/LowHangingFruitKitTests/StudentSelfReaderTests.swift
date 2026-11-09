import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Student self reader")
struct StudentSelfReaderTests {
    private func goals(_ text: String) -> DegreeGoals? {
        StudentSelfReader.goals(from: Data(text.utf8))
    }

    @Test("finds goal words wherever they are nested, case-insensitively")
    func nested() throws {
        let found = try #require(goals(#"""
        {"student":{"id":"S1","academic":{"School":"UG","degree":"BSE","program":{"code":"EU_BSE","description":"x"},
          "college":"EU","catalogYear":2025,"majors":[{"code":"CIS"},"MATH"],"minor":"ECON","concentrations":["AI"]}}}
        """#))
        #expect(found.school == "UG")
        #expect(found.degree == "BSE")
        #expect(found.program == "EU_BSE")
        #expect(found.college == "EU")
        #expect(found.catalogYear == "2025")
        #expect(found.majors.sorted() == ["CIS", "MATH"])
        #expect(found.minors == ["ECON"])
        #expect(found.concentrations == ["AI"])
    }

    @Test("recognises goals-shaped arrays")
    func goalsShaped() throws {
        let found = try #require(goals(#"""
        {"goals":[
          {"ruleGoalCode":"SCHOOL","name":"school","selectedChoices":[{"key":"UG"}]},
          {"name":"degree","selectedChoices":[{"key":"BA"}]},
          {"ruleGoalCode":"MAJOR","selectedChoices":[{"key":"ECON"},{"key":"CIS"}]},
          {"ruleGoalCode":"MINOR","selectedChoices":[]}
        ]}
        """#))
        #expect(found.school == "UG")
        #expect(found.degree == "BA")
        #expect(found.majors == ["ECON", "CIS"])
        #expect(found.minors.isEmpty)
    }

    @Test("never reads name, email or GPA, and skips their subtrees")
    func privacy() {
        let found = goals(#"""
        {"name":{"school":"LEAK1"},"email":"leak2@example.invalid","studentName":{"degree":"LEAK3"},
         "studentEmail":"leak4@example.invalid","gpa":{"program":"LEAK5"},"school":"UG"}
        """#)
        #expect(found?.school == "UG")
        #expect(found?.degree == nil)
        #expect(found?.program == nil)
        let text = "\(String(describing: found))"
        #expect(!text.contains("LEAK") && !text.contains("leak"))
    }

    @Test("nil when no school, degree or program is found")
    func nothing() {
        #expect(goals(#"{"majors":["CIS"],"catalogYear":"2025"}"#) == nil)
        #expect(goals(#"{"name":"Fake","email":"x"}"#) == nil)
        #expect(goals("not json") == nil)
        #expect(goals("[]") == nil)
    }
}
