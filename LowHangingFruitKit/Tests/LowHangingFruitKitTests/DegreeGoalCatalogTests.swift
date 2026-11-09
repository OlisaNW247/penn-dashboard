import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree goal catalog")
struct DegreeGoalCatalogTests {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    @Test("goals are found by name, not by position; unknown goals are ignored")
    func byName() throws {
        let data = json(#"""
        [
          {"id":"programCollection","goals":[
            {"name":"program","choices":[{"key":"EU_BSE","description":"Engineering BSE"}]},
            {"name":"catalogYear","choices":[{"key":"2025","description":"2025-2026"}]},
            {"name":"mystery","choices":[{"key":"Z"}]}
          ]},
          {"id":"curriculumCollection","goals":[
            {"name":"minor","choices":[{"key":"MATH","description":"Mathematics"}]},
            {"name":"major","choices":[{"key":"CIS","description":"Computer Science"}]},
            {"name":"concentration","choices":[]}
          ]}
        ]
        """#)
        let catalog = try DegreeGoalCatalog.decode(data)
        #expect(catalog.programs == [GoalChoice(key: "EU_BSE", description: "Engineering BSE")])
        #expect(catalog.catalogYears.map(\.key) == ["2025"])
        #expect(catalog.minors.map(\.key) == ["MATH"])
        #expect(catalog.majors.map(\.key) == ["CIS"])
        #expect(catalog.concentrations.isEmpty)
        #expect(catalog.schools.isEmpty)
    }

    @Test("ruleGoalCode is accepted, and position is the last resort")
    func codeAndPosition() throws {
        let data = json(#"""
        [
          {"goals":[
            {"choices":[{"key":"2025"}]},
            {"choices":[{"key":"EU_BSE"}]},
            {"ruleGoalCode":"SCHOOL","choices":[{"key":"UG","description":"Undergraduate"}]},
            {"ruleGoalCode":"COLLEGE","choices":[{"key":"EU"}]},
            {"choices":[{"key":"BSE","description":"Bachelor of Science in Engineering"}]}
          ]},
          {"goals":[{"ruleGoalCode":"CONC","choices":[{"key":"AI","description":"Artificial Intelligence"}]}]}
        ]
        """#)
        let catalog = try DegreeGoalCatalog.decode(data)
        #expect(catalog.catalogYears.map(\.key) == ["2025"])
        #expect(catalog.programs.map(\.key) == ["EU_BSE"])
        #expect(catalog.schools.map(\.key) == ["UG"])
        #expect(catalog.colleges.map(\.key) == ["EU"])
        #expect(catalog.degrees.map(\.key) == ["BSE"])
        #expect(catalog.concentrations.map(\.key) == ["AI"])
    }

    @Test("choices are lenient: key required, description defaults to the key, numeric keys read")
    func lenientChoices() throws {
        let data = json(#"[{"goals":[{"name":"major","choices":[{"key":"CIS"},{"description":"no key"},{"key":2025},"junk",{"key":""}]}]}]"#)
        let catalog = try DegreeGoalCatalog.decode(data)
        #expect(catalog.majors == [GoalChoice(key: "CIS", description: "CIS"), GoalChoice(key: "2025", description: "2025")])
    }

    @Test("description(forKey:) searches every list; not JSON throws")
    func lookup() throws {
        let catalog = DegreeGoalCatalog(majors: [GoalChoice(key: "CIS", description: "Computer Science")], minors: [GoalChoice(key: "MATH", description: "Mathematics")])
        #expect(catalog.description(forKey: "MATH") == "Mathematics")
        #expect(catalog.description(forKey: "CIS") == "Computer Science")
        #expect(catalog.description(forKey: "NOPE") == nil)
        #expect(throws: DegreeGoalCatalog.Failure.notJSON) { try DegreeGoalCatalog.decode(Data("nope".utf8)) }
        #expect(DegreeGoalCatalog.empty.majors.isEmpty)
    }

    @Test("a catalog round-trips through Codable")
    func codable() throws {
        let catalog = DegreeGoalCatalog(programs: [GoalChoice(key: "P", description: "p")])
        let back = try JSONDecoder().decode(DegreeGoalCatalog.self, from: JSONEncoder().encode(catalog))
        #expect(back == catalog)
    }
}
