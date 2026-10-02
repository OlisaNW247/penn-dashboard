import Foundation

/// A Canvas course as the matcher sees it: the display code the whole app
/// keys on (`CourseCode.parse(...).code`, "CIS 2400") and, when known, its
/// term.
///
/// The term is the Kit's existing `Term` (`YYYYTT`, spring/summer/fall),
/// not a string, so a Canvas course's term arrives already parsed by
/// `CourseCode` and is compared by value. The cost: a school whose terms
/// are not those three seasons (a winter term, quarters) has `nil` here and
/// matches on code alone, which is the cautious behaviour anyway.
public struct CanvasCourseRef: Sendable, Hashable {
    public let code: String
    public let term: Term?

    public init(code: String, term: Term?) {
        self.code = code
        self.term = term
    }

    /// Convenience for a term written as a student would ("Fall 2026") or as
    /// Canvas's `YYYYTT` code ("202630"). Unparseable text is `nil`.
    public init(code: String, termText: String?) {
        self.code = code
        self.term = termText.flatMap(EdCourseMatcher.term(fromText:))
    }
}

public struct EdCourseMatch: Sendable, Equatable {
    public enum Confidence: Sendable, Equatable {
        /// The Ed course id was found in a link on that Canvas course's own
        /// pages: the instructor said so.
        case link
        /// Same normalized code and the same term.
        case codeAndTerm
        /// Same normalized code, and no term on one side to check.
        case codeOnly
    }

    public let edCourseID: Int
    public let canvasCourseCode: String
    public let confidence: Confidence

    public init(edCourseID: Int, canvasCourseCode: String, confidence: Confidence) {
        self.edCourseID = edCourseID
        self.canvasCourseCode = canvasCourseCode
        self.confidence = confidence
    }
}

/// Decides which of the student's Ed courses belongs to which of their
/// Canvas courses.
///
/// **Why a wrong match is worse than no match.** What gets ingested for a
/// matched pair is pooled under the Canvas course, shared with every
/// classmate. Pairing an Ed course with the wrong Canvas course (last year's
/// offering of the same code, a lab site) publishes the wrong class's
/// announcements into this class's answers. So every rule below errs toward
/// returning fewer matches, and an ambiguous case returns none.
///
/// Evidence, strongest first:
/// 1. **A link** (`edLinks`, a Canvas code to an Ed course id already found
///    in that course's Canvas pages). The instructor wrote it. It must still
///    name a course the student is enrolled in on Ed (`edCourses`), since
///    nothing else is readable.
/// 2. **Code and term.** The normalized codes are equal and both sides have a
///    term and the terms are equal.
/// 3. **Code only.** The codes are equal and one side has no term. Two sides
///    that both have a term and *disagree* are not a match at all: that is a
///    previous (or future) offering, the exact case this must not ingest.
///
/// Further rules:
/// - If two Ed courses share a code and only one matches the term, only that
///   one is returned.
/// - If a Canvas course has several code-only candidates and none confirmed
///   by term, it matches none: there is no basis to choose.
/// - An Ed course is matched to at most one Canvas code, at its highest
///   confidence.
/// - A Canvas code settled by a link takes no heuristic matches.
public enum EdCourseMatcher {
    public static func match(
        edCourses: [EdCourse],
        canvasCourses: [CanvasCourseRef],
        edLinks: [String: Int]
    ) -> [EdCourseMatch] {
        var results: [EdCourseMatch] = []
        var claimedEd = Set<Int>()
        var claimedCanvasCodes = Set<String>()
        let edByID = Dictionary(edCourses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // 1. Links, in code order so a double claim resolves the same way
        // every run.
        for (canvasCode, edID) in edLinks.sorted(by: { $0.key < $1.key }) {
            guard edByID[edID] != nil, !claimedEd.contains(edID) else { continue }
            claimedEd.insert(edID)
            claimedCanvasCodes.insert(canvasCode)
            results.append(EdCourseMatch(edCourseID: edID, canvasCourseCode: canvasCode, confidence: .link))
        }

        // 2 and 3. Heuristics. Candidates per Canvas code string, each Ed
        // course at its best confidence against any ref carrying that code.
        var refsByCode: [String: [CanvasCourseRef]] = [:]
        for ref in canvasCourses where !claimedCanvasCodes.contains(ref.code) {
            refsByCode[ref.code, default: []].append(ref)
        }

        struct Candidate {
            let edID: Int
            let canvasCode: String
            let confidence: EdCourseMatch.Confidence
        }
        var candidates: [Candidate] = []

        for canvasCode in refsByCode.keys.sorted() {
            let refs = refsByCode[canvasCode] ?? []
            let canvasKey = normalizedCode(canvasCode)
            var forThisCode: [Candidate] = []
            for ed in edCourses.sorted(by: { $0.id < $1.id }) where !claimedEd.contains(ed.id) {
                guard normalizedCode(ed.code) == canvasKey else { continue }
                let edTerm = term(of: ed)
                var best: EdCourseMatch.Confidence?
                for ref in refs {
                    let confidence: EdCourseMatch.Confidence
                    if let edTerm, let refTerm = ref.term {
                        guard edTerm == refTerm else { continue }
                        confidence = .codeAndTerm
                    } else {
                        confidence = .codeOnly
                    }
                    if best == nil || confidence == .codeAndTerm { best = confidence }
                }
                if let best {
                    forThisCode.append(Candidate(edID: ed.id, canvasCode: canvasCode, confidence: best))
                }
            }
            if forThisCode.contains(where: { $0.confidence == .codeAndTerm }) {
                forThisCode.removeAll { $0.confidence != .codeAndTerm }
            } else if forThisCode.count > 1 {
                forThisCode.removeAll()
            }
            candidates.append(contentsOf: forThisCode)
        }

        // Highest confidence first, then a stable order, so an Ed course
        // wanted by two Canvas codes goes to the better claim.
        candidates.sort { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence == .codeAndTerm }
            if lhs.edID != rhs.edID { return lhs.edID < rhs.edID }
            return lhs.canvasCode < rhs.canvasCode
        }
        for candidate in candidates where !claimedEd.contains(candidate.edID) {
            claimedEd.insert(candidate.edID)
            results.append(EdCourseMatch(
                edCourseID: candidate.edID,
                canvasCourseCode: candidate.canvasCode,
                confidence: candidate.confidence
            ))
        }

        return results.sorted { $0.edCourseID < $1.edCourseID }
    }

    /// A comparison key for a course code: "CIS2400", "cis 2400",
    /// "CIS 2400-001" and "CIS-2400" all become "CIS 2400".
    ///
    /// Not "uppercase and strip punctuation", which would turn the section in
    /// "CIS 2400-001" into digits glued onto the number ("CIS2400001") and
    /// match nothing. Instead: find the first run of letters (a department)
    /// that is followed, across any whitespace or dashes, by digits (the
    /// number), keep one optional letter stuck to the number ("CHEM 1010L"),
    /// and ignore the rest, which is section and title. A cross-listing prefix
    /// ("BAN-PHYS-151") is skipped because its first letters are followed by
    /// more letters, not digits. A string with no such pair falls back to its
    /// letters and digits only, uppercased.
    public static func normalizedCode(_ raw: String) -> String {
        let chars = Array(raw.uppercased())
        let separators: Set<Character> = ["-", "_", "\u{2013}", "\u{2014}", "/", ".", " ", "\t", "\u{00A0}"]
        var i = 0
        while i < chars.count {
            guard chars[i].isLetter else { i += 1; continue }
            let deptStart = i
            while i < chars.count, chars[i].isLetter { i += 1 }
            let dept = String(chars[deptStart..<i])
            var j = i
            while j < chars.count, separators.contains(chars[j]) { j += 1 }
            guard (2...8).contains(dept.count), j < chars.count, chars[j].isNumber else { continue }
            let numberStart = j
            while j < chars.count, chars[j].isNumber { j += 1 }
            var number = String(chars[numberStart..<j])
            if j < chars.count, chars[j].isLetter, j + 1 == chars.count || !chars[j + 1].isLetter {
                number.append(chars[j])
            }
            return dept + " " + number
        }
        return String(chars.filter { $0.isLetter || $0.isNumber })
    }

    /// An Ed course's term from its free-text `year` and `session`. Both are
    /// needed: the year from `year` (or a four-digit run in `session`), the
    /// season from the words in `session`. Anything else, including a winter
    /// session or an academic-year range like "2025-2026" that does not say
    /// which calendar year the spring fell in, is `nil`: unknown, so the
    /// match falls back to code-only rather than guessing a term.
    public static func term(of course: EdCourse) -> Term? {
        guard let session = course.session else { return nil }
        guard let parsedSeason = season(fromText: session) else { return nil }
        if let year = course.year.flatMap(singleYear(in:)) ?? singleYear(in: session) {
            return Term(year: year, season: parsedSeason)
        }
        return nil
    }

    /// "Fall 2026" or "202630" as a `Term`; otherwise `nil`.
    public static func term(fromText text: String) -> Term? {
        if let byCode = Term(code: text) { return byCode }
        guard let parsedSeason = season(fromText: text), let year = singleYear(in: text) else { return nil }
        return Term(year: year, season: parsedSeason)
    }

    private static func season(fromText text: String) -> Term.Season? {
        let lower = text.lowercased()
        if lower.contains("fall") || lower.contains("autumn") { return .fall }
        if lower.contains("spring") { return .spring }
        if lower.contains("summer") { return .summer }
        return nil
    }

    /// The year, only when the text names exactly one distinct four-digit
    /// year; "2025-2026" names two and is rejected.
    private static func singleYear(in text: String) -> Int? {
        var years = Set<Int>()
        var run = ""
        for ch in text + " " {
            if ch.isASCII, ch.isNumber {
                run.append(ch)
            } else {
                if run.count == 4, let year = Int(run) { years.insert(year) }
                run = ""
            }
        }
        return years.count == 1 ? years.first : nil
    }
}
