import Foundation

// Degree progress, v12 (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md).
// The paths, query keys and body shapes are unverified against Penn's live
// Degree Works (Penn Labs' client and a CLI are the sources). Pure builders:
// the UI client adds the Cookie and Origin headers; no Cookie header is ever
// set in the Kit.

public enum DegreeWorksRequests {
    private static let timeout: TimeInterval = 30

    private static func url(path: String, query: [URLQueryItem]? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = DegreeWorksEndpoints.host
        components.port = DegreeWorksEndpoints.port
        components.path = path
        components.queryItems = query
        return components.url ?? DegreeWorksEndpoints.baseURL
    }

    /// GET the dashboard's own audit. The query keys and their order are the
    /// dashboard's; empty values are sent empty, as it does.
    public static func currentAudit(studentID: String, school: String, degree: String) -> URLRequest {
        let query = [
            URLQueryItem(name: "studentId", value: studentID),
            URLQueryItem(name: "school", value: school),
            URLQueryItem(name: "degree", value: degree),
            URLQueryItem(name: "is-process-new", value: "false"),
            URLQueryItem(name: "audit-type", value: "AA"),
            URLQueryItem(name: "auditId", value: ""),
            URLQueryItem(name: "include-inprogress", value: "true"),
            URLQueryItem(name: "include-preregistered", value: "true"),
            URLQueryItem(name: "aid-term", value: ""),
        ]
        var request = URLRequest(url: url(path: DegreeWorksEndpoints.auditPath, query: query), timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(DegreeWorksEndpoints.auditAccept, forHTTPHeaderField: "Accept")
        return request
    }

    /// POST a what-if audit, Penn Labs' body. Keys are sorted and the goals
    /// array has a fixed order (COLLEGE, CONC, MAJOR, MINOR, PROGRAM), so the
    /// same inputs are the same bytes (a test pins it).
    public static func whatIfAudit(studentID: String, goals: DegreeGoals, keepCurriculum: Bool) -> URLRequest {
        var entries: [[String: Any]] = []
        func add(_ code: String, _ values: [String]) {
            for value in values where !value.isEmpty { entries.append(["code": code, "value": value]) }
        }
        add("COLLEGE", [goals.college ?? ""])
        add("CONC", goals.concentrations)
        add("MAJOR", goals.majors)
        add("MINOR", goals.minors)
        add("PROGRAM", [goals.program ?? ""])

        var body: [String: Any] = [
            "studentId": studentID,
            "isIncludeInprogress": true,
            "isIncludePreregistered": true,
            "isKeepCurriculum": keepCurriculum,
            "school": (goals.school?.isEmpty == false) ? (goals.school ?? "UG") : "UG",
            "goals": entries,
            "classes": [Any](),
        ]
        if let degree = goals.degree, !degree.isEmpty { body["degree"] = degree }
        if let year = goals.catalogYear, !year.isEmpty { body["catalogYear"] = year }

        var request = URLRequest(url: url(path: DegreeWorksEndpoints.auditPath), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = sortedJSON(body)
        return request
    }

    public static func goalsCatalog(selected: DegreeGoals) -> URLRequest {
        var request = URLRequest(url: url(path: DegreeWorksEndpoints.goalsPath), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = goalsPayload(selected: selected)
        return request
    }

    public static func studentSelf() -> URLRequest {
        var request = URLRequest(url: url(path: DegreeWorksEndpoints.studentPath), timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The two-collection skeleton `/api/goals` takes, with `selectedChoices`
    /// filled from what the student has picked so far; re-posting narrows the
    /// later choices. Sorted keys, byte-stable. The `selectedChoices` element
    /// shape (`{"key": …}`) is a guess from the response's `choices` shape.
    public static func goalsPayload(selected: DegreeGoals) -> Data {
        func goal(
            _ name: String, _ description: String, _ entity: String, _ code: String,
            driver: Bool = false, multiple: Bool = false, required: Bool, values: [String]
        ) -> [String: Any] {
            let chosen: [[String: Any]] = values.filter { !$0.isEmpty }.map { ["key": $0] }
            return [
                "name": name,
                "description": description,
                "entityName": entity,
                "isDisabled": false,
                "isDriver": driver,
                "isError": false,
                "isMultiple": multiple,
                "isRequired": required,
                "isStatic": false,
                "isVisible": true,
                "isNoValidOptionsWarning": false,
                "source": "",
                "errorMessage": "",
                "choices": [Any](),
                "selectedChoices": chosen,
                "ruleGoalCode": code,
                "links": [Any](),
            ]
        }
        let program: [String: Any] = [
            "id": "programCollection",
            "description": "Program",
            "isExpandable": false,
            "goals": [
                goal("catalogYear", "Catalog Year", "catalogYears", "CATALOGYEAR", required: true, values: [selected.catalogYear ?? ""]),
                goal("program", "Program", "programs", "PROGRAM", driver: true, required: true, values: [selected.program ?? ""]),
                goal("school", "School", "schools", "SCHOOL", required: true, values: [selected.school ?? ""]),
                goal("college", "College", "colleges", "COLLEGE", required: true, values: [selected.college ?? ""]),
                goal("degree", "Degree", "degrees", "DEGREE", required: true, values: [selected.degree ?? ""]),
            ],
        ]
        let curriculum: [String: Any] = [
            "id": "curriculumCollection",
            "description": "Curriculum",
            "isExpandable": false,
            "goals": [
                goal("major", "Major", "majors", "MAJOR", multiple: true, required: true, values: selected.majors),
                goal("concentration", "Concentration", "concentrations", "CONC", multiple: true, required: false, values: selected.concentrations),
                goal("minor", "Minor", "minors", "MINOR", multiple: true, required: false, values: selected.minors),
            ],
        ]
        return sortedJSON([program, curriculum])
    }

    private static func sortedJSON(_ object: Any) -> Data {
        let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return data ?? Data("{}".utf8)
    }
}
