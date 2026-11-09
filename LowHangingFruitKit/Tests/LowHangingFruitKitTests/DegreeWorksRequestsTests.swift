import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree Works request builders")
struct DegreeWorksRequestsTests {
    private func body(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    @Test("currentAudit: exact URL, query order, Accept header, no Cookie")
    func currentAudit() {
        let request = DegreeWorksRequests.currentAudit(studentID: "S1", school: "UG", degree: "BSE")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString ==
            "https://degreeworks-prod-j.isc-seo.upenn.edu:9904/api/audit?studentId=S1&school=UG&degree=BSE&is-process-new=false&audit-type=AA&auditId=&include-inprogress=true&include-preregistered=true&aid-term=")
        #expect(request.value(forHTTPHeaderField: "Accept") == DegreeWorksEndpoints.auditAccept)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test("whatIfAudit: Penn Labs' body, byte for byte")
    func whatIfBody() {
        let goals = DegreeGoals(
            school: "UG", college: "EU", program: "EU_BSE", degree: "BSE",
            majors: ["CIS"], concentrations: ["AI"], minors: ["MATH"], catalogYear: "2025")
        let request = DegreeWorksRequests.whatIfAudit(studentID: "S1", goals: goals, keepCurriculum: false)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://degreeworks-prod-j.isc-seo.upenn.edu:9904/api/audit")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(body(request) ==
            #"{"catalogYear":"2025","classes":[],"degree":"BSE","goals":[{"code":"COLLEGE","value":"EU"},{"code":"CONC","value":"AI"},{"code":"MAJOR","value":"CIS"},{"code":"MINOR","value":"MATH"},{"code":"PROGRAM","value":"EU_BSE"}],"isIncludeInprogress":true,"isIncludePreregistered":true,"isKeepCurriculum":false,"school":"UG","studentId":"S1"}"#)
    }

    @Test("whatIfAudit: one goal per major and minor, empties omitted, school defaults to UG")
    func whatIfShapes() {
        let goals = DegreeGoals(majors: ["CIS", "MATH"], minors: ["ECON", "PHYS"])
        let request = DegreeWorksRequests.whatIfAudit(studentID: "S2", goals: goals, keepCurriculum: true)
        #expect(body(request) ==
            #"{"classes":[],"goals":[{"code":"MAJOR","value":"CIS"},{"code":"MAJOR","value":"MATH"},{"code":"MINOR","value":"ECON"},{"code":"MINOR","value":"PHYS"}],"isIncludeInprogress":true,"isIncludePreregistered":true,"isKeepCurriculum":true,"school":"UG","studentId":"S2"}"#)
        let again = DegreeWorksRequests.whatIfAudit(studentID: "S2", goals: goals, keepCurriculum: true)
        #expect(request.httpBody == again.httpBody)
        let empty = DegreeWorksRequests.whatIfAudit(studentID: "S3", goals: DegreeGoals(), keepCurriculum: true)
        #expect(body(empty).contains(#""goals":[]"#))
    }

    @Test("goalsPayload: two collections in order, sorted keys, selections filled, byte-stable")
    func goalsPayload() throws {
        let selected = DegreeGoals(school: "UG", college: "EU", program: "EU_BSE", degree: "BSE", majors: ["CIS"], minors: [], catalogYear: "2025")
        let data = DegreeWorksRequests.goalsPayload(selected: selected)
        #expect(data == DegreeWorksRequests.goalsPayload(selected: selected))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix(#"[{"description":"Program","goals":["#))
        #expect(text.contains(#""id":"programCollection""#))
        #expect(text.contains(#""id":"curriculumCollection""#))
        let programAt = try #require(text.range(of: "programCollection"))
        let curriculumAt = try #require(text.range(of: "curriculumCollection"))
        #expect(programAt.lowerBound < curriculumAt.lowerBound)

        let collections = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(collections.count == 2)
        let first = try #require(collections[0]["goals"] as? [[String: Any]])
        #expect(first.compactMap { $0["name"] as? String } == ["catalogYear", "program", "school", "college", "degree"])
        #expect(first.compactMap { $0["entityName"] as? String } == ["catalogYears", "programs", "schools", "colleges", "degrees"])
        #expect(first.compactMap { $0["ruleGoalCode"] as? String } == ["CATALOGYEAR", "PROGRAM", "SCHOOL", "COLLEGE", "DEGREE"])
        #expect(first.compactMap { $0["isDriver"] as? Bool } == [false, true, false, false, false])
        #expect(first.compactMap { $0["isMultiple"] as? Bool } == [false, false, false, false, false])
        let programKeys = (first[1]["selectedChoices"] as? [[String: Any]])?.compactMap { $0["key"] as? String }
        #expect(programKeys == ["EU_BSE"])
        let second = try #require(collections[1]["goals"] as? [[String: Any]])
        #expect(second.compactMap { $0["name"] as? String } == ["major", "concentration", "minor"])
        #expect(second.compactMap { $0["ruleGoalCode"] as? String } == ["MAJOR", "CONC", "MINOR"])
        #expect(second.compactMap { $0["entityName"] as? String } == ["majors", "concentrations", "minors"])
        #expect(second.compactMap { $0["isMultiple"] as? Bool } == [true, true, true])
        #expect((second[0]["selectedChoices"] as? [Any])?.count == 1)
        #expect((second[2]["selectedChoices"] as? [Any])?.isEmpty == true)
        #expect(first[0]["isVisible"] as? Bool == true)
        #expect(first[0]["isStatic"] as? Bool == false)
    }

    @Test("goalsCatalog and studentSelf requests")
    func others() {
        let catalog = DegreeWorksRequests.goalsCatalog(selected: DegreeGoals())
        #expect(catalog.httpMethod == "POST")
        #expect(catalog.url?.path == "/api/goals")
        #expect(catalog.httpBody == DegreeWorksRequests.goalsPayload(selected: DegreeGoals()))
        #expect(catalog.value(forHTTPHeaderField: "Cookie") == nil)
        let me = DegreeWorksRequests.studentSelf()
        #expect(me.httpMethod == "GET")
        #expect(me.url?.path == "/api/students/myself")
        #expect(me.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("endpoint constants")
    func endpoints() {
        #expect(DegreeWorksEndpoints.baseURL.absoluteString == "https://degreeworks-prod-j.isc-seo.upenn.edu:9904")
        #expect(DegreeWorksEndpoints.dashboardPath == "/worksheets/")
    }
}
