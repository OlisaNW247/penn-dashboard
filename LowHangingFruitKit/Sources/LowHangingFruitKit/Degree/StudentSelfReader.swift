import Foundation

// Degree progress, v12 (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md).
// The shape of Degree Works' student endpoint is UNVERIFIED, so this reads
// wherever the goal words appear instead of at a fixed path.

/// Best-effort read of the student endpoint for the goals the audit needs.
///
/// It never reads a name, email or GPA: any subtree under a key with one of
/// those names is skipped, and no scalar outside the goal words is returned.
/// The endpoint's answer is personal; this takes only program codes from it.
public enum StudentSelfReader {
    private static let skippedKeys: Set<String> = ["name", "email", "studentname", "studentemail", "gpa", "degreeworksgpa"]
    private static let maxDepth = 24

    private struct Found {
        var school: String?
        var college: String?
        var program: String?
        var degree: String?
        var catalogYear: String?
        var majors: [String] = []
        var concentrations: [String] = []
        var minors: [String] = []
    }

    public static func goals(from data: Data) -> DegreeGoals? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var found = Found()
        walk(object, depth: 0, into: &found)
        guard found.school != nil || found.degree != nil || found.program != nil else { return nil }
        return DegreeGoals(
            school: found.school, college: found.college, program: found.program, degree: found.degree,
            majors: found.majors, concentrations: found.concentrations, minors: found.minors,
            catalogYear: found.catalogYear)
    }

    private static func walk(_ node: Any, depth: Int, into found: inout Found) {
        guard depth < maxDepth else { return }
        if let array = node as? [Any] {
            for element in array {
                if let goal = element as? [String: Any], isGoalShaped(goal) {
                    absorbGoal(goal, into: &found)
                } else {
                    walk(element, depth: depth + 1, into: &found)
                }
            }
            return
        }
        guard let dict = node as? [String: Any] else { return }
        for (key, value) in dict {
            let lower = key.lowercased()
            if skippedKeys.contains(lower) { continue }
            switch lower {
            case "school": set(&found.school, scalar(value))
            case "college": set(&found.college, scalar(value))
            case "program": set(&found.program, scalar(value))
            case "degree": set(&found.degree, scalar(value))
            case "catalogyear": set(&found.catalogYear, scalar(value, allowNumber: true))
            case "major", "majors": append(&found.majors, values(value))
            case "concentration", "concentrations": append(&found.concentrations, values(value))
            case "minor", "minors": append(&found.minors, values(value))
            default: walk(value, depth: depth + 1, into: &found)
            }
        }
    }

    /// `{ruleGoalCode or name, selectedChoices}`: the /api/goals goal shape.
    private static func isGoalShaped(_ dict: [String: Any]) -> Bool {
        dict["selectedChoices"] is [Any] && (dict["ruleGoalCode"] is String || dict["name"] is String)
    }

    /// The goal's `name` here is the goal's name ("college"), not the
    /// student's; only the selected keys are read.
    private static func absorbGoal(_ goal: [String: Any], into found: inout Found) {
        let selected = values(goal["selectedChoices"])
        let name = (goal["name"] as? String)?.lowercased() ?? ""
        let code = (goal["ruleGoalCode"] as? String)?.uppercased() ?? ""
        switch (code, name) {
        case ("SCHOOL", _), (_, "school"): set(&found.school, selected.first)
        case ("COLLEGE", _), (_, "college"): set(&found.college, selected.first)
        case ("PROGRAM", _), (_, "program"): set(&found.program, selected.first)
        case ("DEGREE", _), (_, "degree"): set(&found.degree, selected.first)
        case ("CATALOGYEAR", _), (_, "catalogyear"): set(&found.catalogYear, selected.first)
        case ("MAJOR", _), (_, "major"): append(&found.majors, selected)
        case ("CONC", _), (_, "concentration"): append(&found.concentrations, selected)
        case ("MINOR", _), (_, "minor"): append(&found.minors, selected)
        default: break
        }
    }

    private static func set(_ slot: inout String?, _ value: String?) {
        if slot == nil, let value, !value.isEmpty { slot = value }
    }

    private static func append(_ list: inout [String], _ more: [String]) {
        for value in more where !value.isEmpty && !list.contains(value) { list.append(value) }
    }

    /// A string, or a `{code|key|value}` object holding one.
    private static func scalar(_ value: Any, allowNumber: Bool = false) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if allowNumber, let number = value as? NSNumber { return number.stringValue }
        if let dict = value as? [String: Any] {
            for key in ["code", "key", "value"] {
                if let string = dict[key] as? String, !string.isEmpty { return string }
            }
        }
        return nil
    }

    private static func values(_ value: Any?) -> [String] {
        guard let value else { return [] }
        if let array = value as? [Any] { return array.compactMap { scalar($0) } }
        if let single = scalar(value) { return [single] }
        return []
    }
}
