import Foundation

// Degree progress, v12 (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md).
// The key names read here are from Penn Labs' client and a Degree Works CLI
// and are UNVERIFIED against Penn's live audit JSON.

/// Reads Degree Works' dashboard audit JSON into `DegreeAudit`.
///
/// The privacy rule is structural: `auditHeader.studentName`, `studentEmail`
/// and `degreeworksGpa`, and every `letterGrade`, are simply never looked at,
/// and `DegreeAudit` has no field to hold them. The wrong fix would be to
/// decode them and blank them later, which leaves a window in which they
/// exist in memory and a path by which a later edit could persist them.
///
/// Numbers arrive as JSON numbers or numeric strings ("100"); both are read.
public enum DegreeWorksAuditDecoder {
    public enum Failure: Error, Equatable { case notJSON, noBlocks }

    public static func decode(_ data: Data, goals: DegreeGoals, isWhatIf: Bool, now: Date) throws -> DegreeAudit {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { throw Failure.notJSON }
        guard let blockObjects = root["blockArray"] as? [Any] else { throw Failure.noBlocks }

        let blocks: [AuditBlock] = blockObjects.compactMap { ($0 as? [String: Any]).map(parseBlock) }

        let header = root["auditHeader"] as? [String: Any]
        let degreeData = ((root["degreeInformation"] as? [String: Any])?["degreeDataArray"] as? [Any])?.first as? [String: Any]

        var seen = Set<String>()
        var courses: [AuditCourse] = []
        let done = ((root["classInformation"] as? [String: Any])?["classArray"] as? [Any]) ?? []
        let active = ((root["inProgress"] as? [String: Any])?["classArray"] as? [Any]) ?? []
        func collect(_ rows: [Any], forceInProgress: Bool) {
            for raw in rows {
                guard let dict = raw as? [String: Any],
                      let course = parseCourse(dict, forceInProgress: forceInProgress) else { continue }
                if seen.insert(course.id).inserted { courses.append(course) }
            }
        }
        collect(done, forceInProgress: false)
        collect(active, forceInProgress: true)
        courses.sort(by: courseOrder)

        return DegreeAudit(
            goals: goals,
            isWhatIf: isWhatIf,
            percentComplete: number(header?["percentComplete"]),
            degreeLabel: text(degreeData?["degreeLiteral"]),
            catalogYearLabel: text(degreeData?["catalogYearLit"]),
            blocks: blocks,
            courses: courses,
            fetchedAt: now
        )
    }

    /// Key names only, for the DEBUG shape log. Never a value.
    public static func keyShape(of data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return [] }
        func line(_ path: String, _ dict: [String: Any]?) -> String? {
            guard let dict else { return nil }
            return "\(path): " + dict.keys.sorted().joined(separator: ", ")
        }
        let firstBlock = (root["blockArray"] as? [Any])?.first as? [String: Any]
        let firstRule = (firstBlock?["ruleArray"] as? [Any])?.first as? [String: Any]
        let firstClass = ((root["classInformation"] as? [String: Any])?["classArray"] as? [Any])?.first as? [String: Any]
        return [
            line("audit", root),
            line("block", firstBlock),
            line("rule", firstRule),
            line("class", firstClass),
        ].compactMap { $0 }
    }

    /// Complete, Incomplete, Noncourse and Blocktype rules are notes, not
    /// requirements, so they are `.info` and never counted. `Block` points at
    /// another block and uses the percent rule like a course would.
    public static func status(
        percentComplete: Double?, inProgressIncomplete: String?, ruleType: String, appliedInProgress: Bool
    ) -> RuleStatus {
        let informational = ["complete", "incomplete", "noncourse", "blocktype"]
        if informational.contains(ruleType.lowercased()) { return .info }
        if let percentComplete, percentComplete >= 100 { return .met }
        if inProgressIncomplete == "Yes" || appliedInProgress { return .inProgress }
        return .open
    }

    // MARK: Parsing

    private static func parseBlock(_ dict: [String: Any]) -> AuditBlock {
        let type = text(dict["requirementType"]) ?? ""
        let value = text(dict["requirementValue"]) ?? ""
        let id = text(dict["requirementId"]) ?? "\(type):\(value)"
        let rules = ((dict["ruleArray"] as? [Any]) ?? []).enumerated().compactMap { index, raw in
            (raw as? [String: Any]).map { parseRule($0, id: "\(id).\(index)") }
        }
        return AuditBlock(
            id: id, type: type, value: value, title: text(dict["title"]) ?? "",
            percentComplete: number(dict["percentComplete"]), rules: rules)
    }

    private static func parseRule(_ dict: [String: Any], id: String) -> AuditRule {
        let ruleType = text(dict["ruleType"]) ?? ""
        let percent = number(dict["percentComplete"])
        let requirement = dict["requirement"] as? [String: Any]
        let appliedRaw = (dict["classesAppliedToRule"] as? [String: Any])?["classArray"] as? [Any] ?? []
        let applied = appliedRaw.compactMap { ($0 as? [String: Any]).flatMap { parseCourse($0, forceInProgress: false) } }
        let children = ((dict["ruleArray"] as? [Any]) ?? []).enumerated().compactMap { index, raw in
            (raw as? [String: Any]).map { parseRule($0, id: "\(id).\(index)") }
        }
        let adviceRaw = (dict["advice"] as? [String: Any])?["courseArray"] as? [Any] ?? []
        let advice: [AdviceCourse] = adviceRaw.compactMap { raw in
            guard let item = raw as? [String: Any], let code = courseCode(item) else { return nil }
            return AdviceCourse(code: code, title: text(item["title"]), credits: number(item["credits"]))
        }
        var adviceText: String?
        if let list = (dict["proxyAdvice"] as? [String: Any])?["textList"] as? [Any] {
            let joined = list.compactMap { text($0) }.joined(separator: " ")
            adviceText = joined.isEmpty ? nil : joined
        }
        // A group is in progress when anything under it is, even though the
        // courses are applied to its children and not to the group itself.
        let inProgressBelow = applied.contains { $0.isInProgress } || children.contains { $0.status == .inProgress }
        return AuditRule(
            id: id,
            label: text(dict["label"]) ?? "",
            ruleType: ruleType,
            percentComplete: percent,
            status: status(
                percentComplete: percent, inProgressIncomplete: text(dict["inProgressIncomplete"]),
                ruleType: ruleType, appliedInProgress: inProgressBelow),
            needCourses: wholeNumber(requirement?["classesBegin"]),
            needCredits: number(requirement?["creditsBegin"]),
            appliedCount: wholeNumber(dict["classesApplied"]),
            appliedCredits: number(dict["creditsApplied"]),
            applied: applied,
            advice: advice,
            adviceText: adviceText,
            children: children
        )
    }

    private static func parseCourse(_ dict: [String: Any], forceInProgress: Bool) -> AuditCourse? {
        guard let code = courseCode(dict) else { return nil }
        let flag = (text(dict["inProgress"]) ?? "").uppercased()
        let transfer = (text(dict["transfer"]) ?? "").uppercased()
        return AuditCourse(
            code: code,
            title: text(dict["courseTitle"]) ?? text(dict["title"]) ?? "",
            credits: number(dict["credits"]),
            termCode: text(dict["term"]),
            isInProgress: forceInProgress || flag == "Y" || flag == "YES" || flag == "TRUE",
            isTransfer: transfer == "T"
        )
    }

    /// "CIS 1200": discipline, a space, number; whitespace trimmed and runs of
    /// it collapsed, because Degree Works pads fields.
    private static func courseCode(_ dict: [String: Any]) -> String? {
        let raw = "\(text(dict["discipline"]) ?? "") \(text(dict["number"]) ?? "")"
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func courseOrder(_ a: AuditCourse, _ b: AuditCourse) -> Bool {
        switch (a.termCode, b.termCode) {
        case let (x?, y?): return x != y ? x < y : a.code < b.code
        case (nil, nil): return a.code < b.code
        case (_?, nil): return true
        case (nil, _?): return false
        }
    }

    // MARK: Lenient scalars

    private static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        }
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number.doubleValue : nil }
        return nil
    }

    /// A count, or nil: a hostile "1e300" must not reach `Int(_:)`, which traps.
    private static func wholeNumber(_ value: Any?) -> Int? {
        guard let double = number(value), abs(double) < 1_000_000 else { return nil }
        return Int(double)
    }

    private static func text(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
