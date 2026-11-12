import Foundation

// Degree progress, v12. "What if I picked a different concentration?"
//
// A student in a degree whose program is listed beside many siblings (an
// undeclared Wharton BS student choosing among Finance, Accounting, Marketing,
// and so on) wants to flip between the siblings and see how each audit looks.
// Penn's catalogue codes every program as `MAJR-DEGC` or `MAJR-DEGC-CONC`
// ("FNCS-BS" is "Finance BS", "CSCI-BSE-NCON" is "Computer Science BSE (No
// Concentration)"), so the rows that belong to the student's own degree can be
// chosen from the code alone.
//
// Wharton's undergraduate "concentrations" are majors in Penn's data: the
// `...-BS` rows. They have no concentration code, so there is no "add
// concentration" change for them. "What if my concentration were Finance" is
// the page's `new-program` change for the catalogue entry "FNCS-BS", which is
// exactly the `.newProgram` plan `PathWhatIf.plans` already produces.
//
// The wrong fixes, both tempting. Treating a Wharton concentration as the
// page's `add-conc` change: that rule needs a `conc_code`, which these rows do
// not carry, so it would never fire. And fetching `programs-v2-info` for all
// 1,049 catalogue rows to learn each one's degree: 50 to 80 kB each, a
// thousand hidden calls for what the code already says. The code structure is
// only used here to choose which rows to SHOW. What is sent to Penn always
// comes from the chosen row's own info, run through the page's rule
// (`plan(for:current:)`), never from the code's shape.

public enum DegreeOptions {
    /// The catalogue rows of the student's own degree, the ones worth
    /// comparing.
    ///
    /// A row qualifies when its code has two or three dash-separated parts and
    /// the second is the degree code. A three-part row ending in `NCON` is the
    /// same program as its two-part row when both are listed, so it is dropped
    /// then. The student's own program (its first part is one of the degree's
    /// majors, with no third part or `NCON`) is dropped, since there is nothing
    /// to compare it with. Sorted by short title, then code, ignoring case.
    public static func listings(for degree: StudentDegree, in programs: [PathProgramListing]) -> [PathProgramListing] {
        let degreeCode = degree.degree.trimmingCharacters(in: .whitespaces).uppercased()
        guard !degreeCode.isEmpty else { return [] }
        let ownMajors = Set(degree.majors.map { $0.uppercased() })

        var twoPartCodes = Set<String>()
        for program in programs {
            let parts = program.code.uppercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2 { twoPartCodes.insert(parts.joined(separator: "-")) }
        }

        var kept: [PathProgramListing] = []
        for program in programs {
            let parts = program.code.uppercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 || parts.count == 3 else { continue }
            guard parts[1] == degreeCode else { continue }
            let plain = parts.count == 2 || parts[2] == "NCON"
            // The student's own program, under either of its spellings. A row
            // with a real third part (their major with a concentration) stays:
            // that is a different program to compare with.
            if plain, ownMajors.contains(parts[0]) { continue }
            if parts.count == 3, parts[2] == "NCON", twoPartCodes.contains(parts[0] + "-" + parts[1]) { continue }
            kept.append(program)
        }

        return kept.sorted { left, right in
            let a = shortTitle(left)
            let b = shortTitle(right)
            if a != b { return a < b }
            return left.code.lowercased() < right.code.lowercased()
        }
    }

    /// The chip text for a listing, lowercase: the title with the degree code
    /// and a trailing "(no concentration)" taken off.
    ///
    /// "Finance BS" is "finance"; "Computer Science BSE (No Concentration)" is
    /// "computer science"; "Wharton MBA MBA (AI for Business)" is "wharton mba
    /// (ai for business)" (only the last standalone degree word before the
    /// parenthesis or the end goes). Never empty: falls back to the code.
    public static func shortTitle(_ listing: PathProgramListing) -> String {
        let parts = listing.code.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let token = parts.count >= 2 ? parts[1].lowercased() : ""
        var text = listing.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let noConc = " (no concentration)"
        if text.hasSuffix(noConc) {
            text = String(text.dropLast(noConc.count)).trimmingCharacters(in: .whitespaces)
        }

        if !token.isEmpty {
            var head = text
            var tail = ""
            if let paren = text.range(of: " (") {
                head = String(text[..<paren.lowerBound])
                tail = String(text[paren.lowerBound...])
            }
            head = head.trimmingCharacters(in: .whitespaces)
            if head.hasSuffix(" " + token) {
                head = String(head.dropLast(token.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            text = head + tail
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? listing.code.lowercased() : text
    }

    /// The word above the row of options.
    ///
    /// Hard-coded for one college on purpose: Wharton calls its undergraduate
    /// majors concentrations, Penn's data calls them majors, and the screen
    /// should use the word the student uses. It is copy, not logic, and
    /// nothing else reads it.
    public static func heading(college: String?) -> String {
        let code = (college ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        return code == "WU" ? "concentrations" : "majors"
    }

    /// The change that makes the listing the student's program, by the page's
    /// own rule; nil when that rule gives none (no level on the entry).
    public static func plan(for info: PathProgramInfo, current: [StudentDegree]) -> PathWhatIfPlan? {
        PathWhatIf.plans(for: info, current: current).first { $0.change == .newProgram }
    }

    /// The key under which `DegreeSnapshot.optionScores` keeps one option's
    /// result for one of the student's degrees.
    public static func scoreKey(degreeID: String, programCode: String) -> String {
        degreeID + "|" + programCode
    }
}
