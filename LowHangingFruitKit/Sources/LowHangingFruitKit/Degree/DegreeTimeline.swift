import Foundation

// The semester table that the three degree tabs share: every semester side by
// side, the ones behind the student, the one they are in, and the ones the
// plan sketches. It is pure. The clock is a parameter, nothing is read from
// Penn, and nothing here says a course counts toward anything: the audit is
// only used to look up a title and credits for a code the history names.

/// One course the history puts in a semester.
public struct TimelineCourse: Sendable, Hashable, Identifiable {
    public let code: String
    public let title: String?
    public let credits: Double?
    public var id: String { code }

    public init(code: String, title: String?, credits: Double?) {
        self.code = code
        self.title = title
        self.credits = credits
    }
}

public struct TimelineColumn: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case past, current, future }

    public let termCode: String
    public let kind: Kind
    /// From the history: taken (past), being taken (current) or registered
    /// (future).
    public let taken: [TimelineCourse]
    /// The student's own sketch; future columns only.
    public let planned: [PlannedCourse]
    public var id: String { termCode }

    public init(termCode: String, kind: Kind, taken: [TimelineCourse], planned: [PlannedCourse]) {
        self.termCode = termCode
        self.kind = kind
        self.taken = taken
        self.planned = planned
    }
}

public enum DegreeTimeline {
    /// Every semester that the history or the plan names, ascending by code.
    ///
    /// A history term with no courses is dropped unless the plan also has it,
    /// and so is a history key that is not a term code. A planned course that
    /// is also in the same column's history shows once, as taken: the student
    /// planned it and then registered. Past and current columns never carry
    /// planned courses, even when a stale plan term sits there, because the
    /// table's drag and drop only moves work between semesters still ahead.
    public static func columns(
        history: [String: [String]], plan: DegreePlan, audit: DegreeAudit?,
        now: Date, calendar: Calendar = .current
    ) -> [TimelineColumn] {
        let currentTerm = Term(date: now, calendar: calendar)

        var auditByCode: [String: AuditCourse] = [:]
        if let audit {
            for course in audit.courses {
                let key = DegreePlanMath.normalizedCode(course.code)
                if auditByCode[key] == nil { auditByCode[key] = course }
            }
        }

        // Keys in sorted order so two keys that parse to one term merge the
        // same way every time.
        var historyCodes: [String: [String]] = [:]
        for key in history.keys.sorted() {
            guard let term = Term(code: key) else { continue }
            var list = historyCodes[term.code] ?? []
            for raw in history[key] ?? [] {
                let code = DegreePlanMath.normalizedCode(raw)
                if !code.isEmpty, !list.contains(code) { list.append(code) }
            }
            historyCodes[term.code] = list
        }

        var plannedByTerm: [String: [PlannedCourse]] = [:]
        for term in plan.terms { plannedByTerm[term.termCode] = term.courses }

        var termCodes = Set<String>()
        for (code, list) in historyCodes where !list.isEmpty { termCodes.insert(code) }
        for code in plannedByTerm.keys { termCodes.insert(code) }

        var out: [TimelineColumn] = []
        for termCode in termCodes.sorted() {
            let kind: TimelineColumn.Kind
            if let term = Term(code: termCode) {
                if term < currentTerm {
                    kind = .past
                } else if term == currentTerm {
                    kind = .current
                } else {
                    kind = .future
                }
            } else {
                kind = .future
            }
            var taken: [TimelineCourse] = []
            for code in historyCodes[termCode] ?? [] {
                let match = auditByCode[code]
                let title: String? = match.map { $0.title }
                taken.append(TimelineCourse(code: code, title: title, credits: match?.credits))
            }
            var planned: [PlannedCourse] = []
            if kind == .future {
                let held = Set(taken.map { $0.code })
                for course in plannedByTerm[termCode] ?? [] {
                    if !held.contains(DegreePlanMath.normalizedCode(course.code)) { planned.append(course) }
                }
            }
            out.append(TimelineColumn(termCode: termCode, kind: kind, taken: taken, planned: planned))
        }
        return out
    }

    /// Credits of one column: what was taken (a course the audit does not
    /// list counts nothing) plus what is planned.
    public static func credits(_ column: TimelineColumn) -> Double {
        let held = column.taken.reduce(0.0) { $0 + ($1.credits ?? 0) }
        let sketched = column.planned.reduce(0.0) { $0 + $1.credits }
        return held + sketched
    }

    /// The narrowest a page-layout cell may be: a course chip plus its remove
    /// button.
    public static let minimumPageCellWidth: Double = 112

    /// Column counts the full-page table tries, fewest first, so the cells are
    /// as wide as they can be while everything still fits without scrolling.
    /// From 2 up to what the width holds at the minimum cell width, never more
    /// than 6, and never wider than the number of cells; always at least one
    /// count (2, or 1 when there is one cell or none).
    public static func pageColumnCounts(width: Double, cells: Int) -> [Int] {
        let cap = max(cells, 1)
        let fit = min(6, max(2, Int(max(width, 0) / minimumPageCellWidth)))
        var out: [Int] = []
        for count in 2...max(fit, 2) {
            let capped = min(count, cap)
            if !out.contains(capped) { out.append(capped) }
        }
        return out
    }

    /// Items cut into rows of `perRow`, in order; the last row may be short.
    /// A `perRow` under 1 is treated as 1.
    public static func rows<T>(_ items: [T], perRow: Int) -> [[T]] {
        let size = max(perRow, 1)
        var out: [[T]] = []
        var index = 0
        while index < items.count {
            let end = min(index + size, items.count)
            out.append(Array(items[index..<end]))
            index = end
        }
        return out
    }

    /// The column the table opens on: the current semester, else the first
    /// one ahead, else nothing.
    public static func leadingColumnID(_ columns: [TimelineColumn]) -> String? {
        if let current = columns.first(where: { $0.kind == .current }) { return current.id }
        return columns.first(where: { $0.kind == .future })?.id
    }
}
