import Foundation

// Degree progress, v12 (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md).
// The /api/goals response shape is from Penn Labs' client and is UNVERIFIED
// against Penn's live system, which is why this decode is lenient.

public struct GoalChoice: Codable, Sendable, Hashable, Identifiable {
    public let key: String
    public let description: String
    public var id: String { key }

    public init(key: String, description: String) {
        self.key = key
        self.description = description
    }
}

/// What a student may pick, per goal, as `/api/goals` last answered.
public struct DegreeGoalCatalog: Codable, Sendable, Equatable {
    public var catalogYears: [GoalChoice]
    public var programs: [GoalChoice]
    public var schools: [GoalChoice]
    public var colleges: [GoalChoice]
    public var degrees: [GoalChoice]
    public var majors: [GoalChoice]
    public var concentrations: [GoalChoice]
    public var minors: [GoalChoice]

    public init(
        catalogYears: [GoalChoice] = [], programs: [GoalChoice] = [], schools: [GoalChoice] = [],
        colleges: [GoalChoice] = [], degrees: [GoalChoice] = [], majors: [GoalChoice] = [],
        concentrations: [GoalChoice] = [], minors: [GoalChoice] = []
    ) {
        self.catalogYears = catalogYears
        self.programs = programs
        self.schools = schools
        self.colleges = colleges
        self.degrees = degrees
        self.majors = majors
        self.concentrations = concentrations
        self.minors = minors
    }

    public static let empty = DegreeGoalCatalog()

    public enum Failure: Error, Equatable { case notJSON }

    private enum Slot { case catalogYear, program, school, college, degree, major, concentration, minor }

    /// A goal is found by its `name` (or `ruleGoalCode`) and only by position
    /// when it carries neither: the server may reorder or add goals, and an
    /// index-only reading would then fill the wrong list. Unknown goals are
    /// ignored.
    public static func decode(_ data: Data) throws -> DegreeGoalCatalog {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw Failure.notJSON }
        var collections: [[String: Any]] = []
        if let array = object as? [Any] {
            collections = array.compactMap { $0 as? [String: Any] }
        } else if let dict = object as? [String: Any] {
            if dict["goals"] is [Any] {
                collections = [dict]
            } else if let inner = dict["collections"] as? [Any] {
                collections = inner.compactMap { $0 as? [String: Any] }
            } else {
                throw Failure.notJSON
            }
        } else {
            throw Failure.notJSON
        }

        let positional: [[Slot]] = [
            [.catalogYear, .program, .school, .college, .degree],
            [.major, .concentration, .minor],
        ]
        var catalog = DegreeGoalCatalog()
        for (collectionIndex, collection) in collections.enumerated() {
            let goals = (collection["goals"] as? [Any]) ?? []
            for (goalIndex, raw) in goals.enumerated() {
                guard let goal = raw as? [String: Any] else { continue }
                var slot = slotFor(name: goal["name"] as? String) ?? slotFor(code: goal["ruleGoalCode"] as? String)
                let named = (goal["name"] as? String)?.isEmpty == false || (goal["ruleGoalCode"] as? String)?.isEmpty == false
                if slot == nil, !named, collectionIndex < positional.count, goalIndex < positional[collectionIndex].count {
                    slot = positional[collectionIndex][goalIndex]
                }
                guard let slot else { continue }
                let choices = parseChoices(goal["choices"])
                switch slot {
                case .catalogYear: catalog.catalogYears = choices
                case .program: catalog.programs = choices
                case .school: catalog.schools = choices
                case .college: catalog.colleges = choices
                case .degree: catalog.degrees = choices
                case .major: catalog.majors = choices
                case .concentration: catalog.concentrations = choices
                case .minor: catalog.minors = choices
                }
            }
        }
        return catalog
    }

    /// The description for a code in any list; the first list that has it wins.
    public func description(forKey key: String) -> String? {
        let lists = [programs, degrees, majors, concentrations, minors, colleges, schools, catalogYears]
        for list in lists {
            if let hit = list.first(where: { $0.key == key }) { return hit.description }
        }
        return nil
    }

    private static func slotFor(name: String?) -> Slot? {
        switch name?.lowercased() {
        case "catalogyear": return .catalogYear
        case "program": return .program
        case "school": return .school
        case "college": return .college
        case "degree": return .degree
        case "major": return .major
        case "concentration": return .concentration
        case "minor": return .minor
        default: return nil
        }
    }

    private static func slotFor(code: String?) -> Slot? {
        switch code?.uppercased() {
        case "CATALOGYEAR": return .catalogYear
        case "PROGRAM": return .program
        case "SCHOOL": return .school
        case "COLLEGE": return .college
        case "DEGREE": return .degree
        case "MAJOR": return .major
        case "CONC": return .concentration
        case "MINOR": return .minor
        default: return nil
        }
    }

    /// `key` is required (a string or a number); `description` is optional
    /// and defaults to the key.
    private static func parseChoices(_ raw: Any?) -> [GoalChoice] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { element in
            guard let dict = element as? [String: Any] else { return nil }
            var key: String?
            if let string = dict["key"] as? String { key = string }
            else if let number = dict["key"] as? NSNumber { key = number.stringValue }
            guard let key, !key.isEmpty else { return nil }
            let description = (dict["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            return GoalChoice(key: key, description: description)
        }
    }
}
