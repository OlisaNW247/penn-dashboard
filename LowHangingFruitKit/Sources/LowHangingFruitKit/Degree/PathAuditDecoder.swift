import Foundation

// Degree progress, v12. The response shape read here was observed on
// 2026-11-10 (key names and types only); see docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md.

/// Reads the degree-audit JSON that Penn's Path@Penn site returns into
/// `DegreeAudit`.
///
/// The privacy rule is structural, as it was for the Degree Works decoder this replaced:
/// `blockhtml` and `legendHtml` (Penn's rendered HTML, which is where a letter
/// grade or a GPA could sit), `actionsMap`, `decisions`, `explanations` (the
/// translator's debug trail), `_originalText` and `auditRef` are never looked
/// at. `docs/PRIVACY.md` ("Degree progress") promises that no grade, GPA,
/// name or email is decoded, and `DegreeAudit` has no field to hold them. The
/// wrong fix would be to decode the HTML and strip the grades afterwards,
/// which leaves a window in which they exist in memory and a path by which a
/// later edit could persist them.
///
/// Every field of every node may be absent or JSON null, so each read is
/// lenient and none can trap: a hostile "1e300" never reaches `Int(_:)`.
public enum PathAuditDecoder {
    public enum Failure: Error, Equatable { case notJSON, noBlocks }

    /// Penn's code for "no concentration"; never surfaced as a concentration.
    public static let noConcentrationCode = "NCON"

    public static func decode(_ data: Data, fallbackGoals: DegreeGoals?, isWhatIf: Bool, now: Date) throws -> DegreeAudit {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { throw Failure.notJSON }
        guard let blockObjects = root["blocks"] as? [Any], !blockObjects.isEmpty else { throw Failure.noBlocks }

        var usedIDs = Set<String>()
        var blocks: [AuditBlock] = []
        for (index, raw) in blockObjects.enumerated() {
            guard let dict = raw as? [String: Any] else { continue }
            blocks.append(parseBlock(dict, index: index, usedIDs: &usedIDs))
        }
        guard !blocks.isEmpty else { throw Failure.noBlocks }

        let info = root["degreeInfo"] as? [String: Any]
        let goals: DegreeGoals
        if let info {
            // Spelled out rather than a `flatMap` with a ternary: the closure's
            // `nil : [$0]` leaves the element type to inference, which is the
            // kind of line that fails only on the compiler nobody here has.
            var concentrations: [String] = []
            if let conc = text(info["conc"]), conc.uppercased() != noConcentrationCode {
                concentrations = [conc]
            }
            goals = DegreeGoals(
                school: text(info["level"]),
                college: text(info["college"]),
                program: text(info["program"]),
                degree: text(info["degree"]),
                majors: text(info["major"]).map { [$0] } ?? [],
                concentrations: concentrations,
                minors: text(info["minor"]).map { [$0] } ?? [],
                catalogYear: text(info["term"])
            )
        } else {
            goals = fallbackGoals ?? DegreeGoals()
        }

        // One entry per code. A copy that is finished beats one still in
        // progress, because the same course can sit in two blocks.
        var byCode: [String: AuditCourse] = [:]
        func collect(_ rules: [AuditRule]) {
            for rule in rules {
                for course in rule.applied {
                    if let existing = byCode[course.code] {
                        if existing.isInProgress && !course.isInProgress { byCode[course.code] = course }
                    } else {
                        byCode[course.code] = course
                    }
                }
                collect(rule.children)
            }
        }
        for block in blocks { collect(block.rules) }
        let courses = byCode.values.sorted { $0.code < $1.code }

        let degreeBlock = blocks.first { $0.type == "DEGREE" }
        return DegreeAudit(
            goals: goals,
            isWhatIf: isWhatIf,
            percentComplete: degreeBlock?.percentComplete,
            degreeLabel: degreeBlock.flatMap { $0.title.isEmpty ? nil : $0.title },
            catalogYearLabel: info.flatMap { text($0["term"]) },
            blocks: blocks,
            courses: courses,
            fetchedAt: now
        )
    }

    /// "40 CU are required. You currently have 31. ..." becomes
    /// (have: 31, need: 40), searched in the DEGREE block's rules, recursively.
    /// nil when no label matches.
    public static func creditTotals(in audit: DegreeAudit) -> (have: Double, need: Double)? {
        guard let block = audit.blocks.first(where: { $0.type == "DEGREE" }),
              let regex = try? NSRegularExpression(
                pattern: "([0-9]+(?:\\.[0-9]+)?) CU are required\\. You currently have ([0-9]+(?:\\.[0-9]+)?)",
                options: [.caseInsensitive])
        else { return nil }

        func match(_ label: String) -> (have: Double, need: Double)? {
            let whole = NSRange(label.startIndex..., in: label)
            guard let found = regex.firstMatch(in: label, options: [], range: whole),
                  let needRange = Range(found.range(at: 1), in: label),
                  let haveRange = Range(found.range(at: 2), in: label),
                  let need = Double(label[needRange]),
                  let have = Double(label[haveRange])
            else { return nil }
            return (have: have, need: need)
        }
        func search(_ rules: [AuditRule]) -> (have: Double, need: Double)? {
            for rule in rules {
                if let found = match(rule.label) { return found }
                if let found = search(rule.children) { return found }
            }
            return nil
        }
        return search(block.rules)
    }

    // MARK: Parsing

    private static func parseBlock(_ dict: [String: Any], index: Int, usedIDs: inout Set<String>) -> AuditBlock {
        let id = text(dict["id"]) ?? "block-\(index)"
        let percent = number(dict["completionPercent"])
        let request = dict["courseReqCopy"] as? [String: Any]

        // The block's real content usually sits under one `term` wrapper.
        // Unwrap the top level once and never again: a nested `term` is a
        // real group (it can carry its own icon and percent).
        var top: [[String: Any]] = []
        for member in nodes(request?["members"]) {
            if text(member["type"]) == "term" {
                top.append(contentsOf: nodes(member["members"]))
            } else {
                top.append(member)
            }
        }

        var courseNodes: [[String: Any]] = []
        var rules: [AuditRule] = []
        for (i, node) in top.enumerated() {
            if text(node["type"]) == "course" {
                courseNodes.append(node)
            } else {
                rules.append(parseRule(node, path: "\(id).\(i)", usedIDs: &usedIDs))
            }
        }

        // Bare courses at block level are one synthetic rule, placed first.
        let split = splitCourses(courseNodes)
        if !split.applied.isEmpty || !split.advice.isEmpty {
            let syntheticPath = "\(id).courses"
            let ruleID = uniqueID(syntheticPath, path: syntheticPath, usedIDs: &usedIDs)
            let status: RuleStatus
            if let percent, percent >= 100 {
                status = .met
            } else if split.applied.contains(where: { $0.isInProgress }) {
                status = .inProgress
            } else {
                status = .open
            }
            rules.insert(
                AuditRule(
                    id: ruleID, label: "courses", ruleType: "courses", percentComplete: nil, status: status,
                    needCourses: nil, needCredits: nil,
                    appliedCount: split.applied.isEmpty ? nil : split.applied.count,
                    appliedCredits: creditSum(split.applied),
                    applied: split.applied, advice: split.advice, adviceText: nil, children: []),
                at: 0)
        }

        return AuditBlock(
            id: id, type: text(dict["type"]) ?? "OTHER", value: "",
            title: text(dict["title"]) ?? "", percentComplete: percent, rules: rules)
    }

    private static func parseRule(_ node: [String: Any], path: String, usedIDs: inout Set<String>) -> AuditRule {
        let id = uniqueID(text(node["id"]) ?? path, path: path, usedIDs: &usedIDs)
        let type = text(node["type"]) ?? ""
        let percent = number(node["completionPercent"])
        let icon = text(node["completionIconName"])
        let members = nodes(node["members"])

        var courseNodes: [[String: Any]] = []
        var children: [AuditRule] = []
        for (j, member) in members.enumerated() {
            if text(member["type"]) == "course" {
                courseNodes.append(member)
            } else {
                children.append(parseRule(member, path: "\(path).\(j)", usedIDs: &usedIDs))
            }
        }
        let split = splitCourses(courseNodes)

        func anyInProgress(_ rules: [AuditRule]) -> Bool {
            rules.contains { $0.status == .inProgress || anyInProgress($0.children) }
        }
        let inProgressBelow = split.applied.contains { $0.isInProgress } || anyInProgress(children)

        let status: RuleStatus
        if icon == "completed" {
            status = .met
        } else if icon == "registered" {
            status = .inProgress
        } else if icon == "partial" {
            status = inProgressBelow ? .inProgress : .open
        } else if let percent, percent >= 100 {
            status = .met
        } else if type == "comment" && members.isEmpty && percent == nil {
            status = .info
        } else {
            status = .open
        }

        return AuditRule(
            id: id,
            label: text(node["label"]) ?? "",
            ruleType: type,
            percentComplete: percent,
            status: status,
            needCourses: wholeNumber(node["coursesNeeded"]) ?? wholeNumber(node["membersNeeded"]),
            needCredits: number(node["hoursNeeded"]),
            appliedCount: split.applied.isEmpty ? nil : split.applied.count,
            appliedCredits: creditSum(split.applied),
            applied: split.applied,
            advice: split.advice,
            adviceText: text(node["infoText"]) ?? text(node["details"]),
            children: children
        )
    }

    /// Course nodes with an icon (or some percent) are courses the student has
    /// taken or is registered for; the rest are options still open. First copy
    /// of a code wins within one rule.
    private static func splitCourses(_ courseNodes: [[String: Any]]) -> (applied: [AuditCourse], advice: [AdviceCourse]) {
        var applied: [AuditCourse] = []
        var advice: [AdviceCourse] = []
        var seen = Set<String>()
        for node in courseNodes {
            guard let rawCode = text(node["courseCode"]) else { continue }
            let code = rawCode.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !code.isEmpty, seen.insert(code).inserted else { continue }
            let icon = text(node["completionIconName"])
            let percent = number(node["completionPercent"]) ?? 0
            if icon != nil || percent > 0 {
                applied.append(AuditCourse(
                    code: code,
                    title: text(node["title"]) ?? text(node["titleLong"]) ?? text(node["titleShort"]) ?? "",
                    credits: leadingNumber(node["hours"]),
                    termCode: nil,
                    isInProgress: icon == "registered",
                    isTransfer: false))
            } else {
                advice.append(AdviceCourse(
                    code: code,
                    title: text(node["titleLong"]) ?? text(node["titleShort"]) ?? text(node["title"]),
                    credits: leadingNumber(node["hoursCalculated"]) ?? leadingNumber(node["hours"])))
            }
        }
        return (applied, advice)
    }

    private static func creditSum(_ courses: [AuditCourse]) -> Double? {
        let values = courses.compactMap { $0.credits }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// A node id, else the path id. A repeated id is suffixed with its path,
    /// so every rule id in one audit is unique.
    private static func uniqueID(_ base: String, path: String, usedIDs: inout Set<String>) -> String {
        var candidate = base
        if usedIDs.contains(candidate) { candidate = "\(base)@\(path)" }
        var attempt = 2
        while !usedIDs.insert(candidate).inserted {
            candidate = "\(base)@\(path)#\(attempt)"
            attempt += 1
        }
        return candidate
    }

    // MARK: Lenient scalars

    private static func nodes(_ value: Any?) -> [[String: Any]] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { $0 as? [String: Any] }
    }

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

    /// "1", "1.5", "1 CU" read as 1, 1.5, 1; a JSON number is read as is.
    private static func leadingNumber(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number.doubleValue : nil }
        guard let string = value as? String else { return nil }
        var digits = ""
        var seenDot = false
        for character in string.trimmingCharacters(in: .whitespacesAndNewlines) {
            if character.isASCII && character.isNumber {
                digits.append(character)
            } else if character == "." && !seenDot {
                seenDot = true
                digits.append(character)
            } else {
                break
            }
        }
        while digits.hasSuffix(".") { digits.removeLast() }
        guard let parsed = Double(digits), parsed.isFinite else { return nil }
        return parsed
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
