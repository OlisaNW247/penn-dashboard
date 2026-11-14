import Foundation

// Degree progress, v12. "What if I did a math minor?" typed as plain words.
//
// The what-if tab used to offer one searchable list of Penn's 1,049 public
// programs. A student does not think in catalogue rows: they think "a
// finance concentration", "a math minor", "switch to econ", "cs". This file
// turns the catalogue into entries that carry a human KIND (concentration,
// major, minor, other), turns what was typed into a query (kind word, change
// word, content words), and ranks the entries against it. It is pure: no
// clock, no network, no state, so every rule here is a table in a test.
//
// The code's shape decides only what is SHOWN and under which word. What is
// sent to Penn always comes from the chosen row's own info through
// `PathWhatIf.plans`, never from the code's shape: "FNCS-BS" is listed under
// "concentrations" for a Wharton student because that is the word the student
// uses, yet the change that runs is the page's own rule for that row. The
// tempting wrong fix is to build the change from the kind (a "minor" row sends
// "add minor", a "concentration" row sends "add concentration"). Penn's data
// calls a Wharton concentration a major, and a catalogue code is a naming
// convention, not a contract, so the kind would then drive an audit it was
// only ever meant to describe.
//
// Ranking is deliberately small and explicit (exact word, prefix, one typo, a
// substring, an initialism such as "cs", a short alias table) instead of a
// fuzzy score nobody can read. A tie is broken by fixed rules down to the
// lowercased code, so the same query always gives the same list. The search
// runs on every keystroke over about a thousand rows, which is why an entry's
// words are prepared once per call and not once per token.

public enum DegreeProgramKind: String, Sendable, CaseIterable, Hashable {
    case concentration, major, minor, other

    /// The word above a group of rows.
    public var heading: String {
        switch self {
        case .concentration: return "concentrations"
        case .major: return "majors"
        case .minor: return "minors"
        case .other: return "other programs"
        }
    }

    /// The singular word, for a tag or a sentence.
    public var tag: String {
        switch self {
        case .concentration: return "concentration"
        case .major: return "major"
        case .minor: return "minor"
        case .other: return "program"
        }
    }

    fileprivate var rank: Int {
        switch self {
        case .concentration: return 0
        case .major: return 1
        case .minor: return 2
        case .other: return 3
        }
    }
}

public enum DegreeSearchChange: String, Sendable, Hashable { case add, switchTo }

public struct DegreeProgramEntry: Sendable, Hashable, Identifiable {
    public let listing: PathProgramListing
    public let kind: DegreeProgramKind
    /// Lowercase short name, never empty.
    public let name: String
    /// Lowercased second code part ("bs", "bse", "minor"); "" when the code has one part.
    public let degreeCode: String
    /// Id of the student's degree this row is an option within; nil otherwise.
    public let degreeID: String?
    /// That degree's label as passed in; "" when `degreeID` is nil.
    public let degreeLabel: String
    /// That degree's college name, lowercased; "" when unknown or `degreeID` is nil.
    public let collegeName: String
    /// True when one tap can run it (the row's "new program" change within that degree).
    public let isSibling: Bool
    public var id: String { listing.code }

    public init(
        listing: PathProgramListing,
        kind: DegreeProgramKind,
        name: String,
        degreeCode: String,
        degreeID: String?,
        degreeLabel: String,
        collegeName: String,
        isSibling: Bool
    ) {
        self.listing = listing
        self.kind = kind
        self.name = name
        self.degreeCode = degreeCode
        self.degreeID = degreeID
        self.degreeLabel = degreeLabel
        self.collegeName = collegeName
        self.isSibling = isSibling
    }
}

public struct DegreeSearchQuery: Sendable, Equatable {
    /// Tokens joined by one space.
    public let text: String
    public let tokens: [String]
    public let kind: DegreeProgramKind?
    public let change: DegreeSearchChange?
    public var isEmpty: Bool { tokens.isEmpty }

    public init(tokens: [String], kind: DegreeProgramKind?, change: DegreeSearchChange?) {
        self.tokens = tokens
        self.text = tokens.joined(separator: " ")
        self.kind = kind
        self.change = change
    }
}

public struct DegreeSearchSection: Sendable, Equatable, Identifiable {
    public let kind: DegreeProgramKind
    public let entries: [DegreeProgramEntry]
    public var id: String { kind.rawValue }

    public init(kind: DegreeProgramKind, entries: [DegreeProgramEntry]) {
        self.kind = kind
        self.entries = entries
    }
}

public enum DegreeProgramSearch {

    // MARK: Entries

    /// Classifies every catalogue row against the student's degrees.
    ///
    /// `labels` is parallel to `degrees` ("" when shorter); `colleges` maps a
    /// college code ("WU") to its name ("Wharton"). Rules, first match wins:
    /// a minor; a concentration of the student's own major; a sibling of one of
    /// their degrees (`DegreeOptions.listings`); another undergraduate major;
    /// anything else.
    public static func entries(
        programs: [PathProgramListing],
        degrees: [StudentDegree],
        labels: [String],
        colleges: [String: String]
    ) -> [DegreeProgramEntry] {
        // Each degree's sibling codes, once, not per row.
        var siblingCodes: [Set<String>] = []
        for degree in degrees {
            siblingCodes.append(Set(DegreeOptions.listings(for: degree, in: programs).map { $0.code }))
        }
        var ownDegreeCodes = Set<String>()
        for degree in degrees {
            let code = degree.degree.trimmingCharacters(in: .whitespaces).uppercased()
            if !code.isEmpty { ownDegreeCodes.insert(code) }
        }

        func label(_ index: Int) -> String { index < labels.count ? labels[index] : "" }
        func college(_ index: Int) -> String {
            (colleges[degrees[index].college] ?? "").lowercased()
        }

        var out: [DegreeProgramEntry] = []
        out.reserveCapacity(programs.count)

        for listing in programs {
            let parts = listing.code.uppercased()
                .split(separator: "-", omittingEmptySubsequences: false)
                .map { String($0) }
            let degreeCode = parts.count >= 2 ? parts[1].lowercased() : ""
            let shortName = DegreeOptions.shortTitle(listing)

            // 1. A minor, by code or by the title's last word.
            let lastCodePart = parts.last ?? ""
            let lastTitleWord = listing.title.lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .last.map { String($0) } ?? ""
            if (parts.count >= 2 && (lastCodePart == "MINOR" || lastCodePart == "MIN")) || lastTitleWord == "minor" {
                var name = shortName
                if name.hasSuffix(" minor") { name = String(name.dropLast(" minor".count)) }
                name = name.trimmingCharacters(in: .whitespaces)
                if name.isEmpty { name = listing.code.lowercased() }
                out.append(DegreeProgramEntry(
                    listing: listing, kind: .minor, name: name, degreeCode: degreeCode,
                    degreeID: nil, degreeLabel: "", collegeName: "", isSibling: false))
                continue
            }

            // 2. A concentration of the student's own major that they do not hold yet.
            if parts.count == 3, parts[2] != "NCON" {
                var found: Int? = nil
                for (index, degree) in degrees.enumerated() {
                    guard degree.degree.uppercased() == parts[1] else { continue }
                    guard degree.majors.contains(where: { $0.uppercased() == parts[0] }) else { continue }
                    guard !degree.concentrations.contains(where: { $0.uppercased() == parts[2] }) else { continue }
                    found = index
                    break
                }
                if let index = found {
                    out.append(DegreeProgramEntry(
                        listing: listing, kind: .concentration, name: shortName, degreeCode: degreeCode,
                        degreeID: degrees[index].id, degreeLabel: label(index), collegeName: college(index),
                        isSibling: false))
                    continue
                }
            }

            // 3. A sibling of one of the student's degrees.
            var siblingIndex: Int? = nil
            for index in 0..<siblingCodes.count where siblingCodes[index].contains(listing.code) {
                siblingIndex = index
                break
            }
            if let index = siblingIndex {
                let kind: DegreeProgramKind =
                    DegreeOptions.heading(college: degrees[index].college) == "concentrations" ? .concentration : .major
                out.append(DegreeProgramEntry(
                    listing: listing, kind: kind, name: shortName, degreeCode: degreeCode,
                    degreeID: degrees[index].id, degreeLabel: label(index), collegeName: college(index),
                    isSibling: true))
                continue
            }

            // 4. Another undergraduate major.
            if parts.count == 2 || parts.count == 3 {
                let second = parts[1]
                if ownDegreeCodes.contains(second) || (second.hasPrefix("B") && second.count <= 4) {
                    out.append(DegreeProgramEntry(
                        listing: listing, kind: .major, name: shortName, degreeCode: degreeCode,
                        degreeID: nil, degreeLabel: "", collegeName: "", isSibling: false))
                    continue
                }
            }

            // 5. Everything else.
            out.append(DegreeProgramEntry(
                listing: listing, kind: .other, name: shortName, degreeCode: degreeCode,
                degreeID: nil, degreeLabel: "", collegeName: "", isSibling: false))
        }

        return out.sorted { ordered($0, $1) }
    }

    /// The fixed tie-break: kind, siblings first, name, lowercased code.
    private static func ordered(_ a: DegreeProgramEntry, _ b: DegreeProgramEntry) -> Bool {
        if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
        if a.isSibling != b.isSibling { return a.isSibling }
        if a.name != b.name { return a.name < b.name }
        return a.listing.code.lowercased() < b.listing.code.lowercased()
    }

    // MARK: Parsing

    private static let concentrationWords: Set<String> = [
        "concentration", "concentrations", "conc", "concentrate", "concentrating",
    ]
    private static let majorWords: Set<String> = ["major", "majors", "majoring", "majored"]
    private static let minorWords: Set<String> = ["minor", "minors", "minoring", "minored"]

    private static let fillerWords: Set<String> = [
        "what", "if", "i", "to", "in", "a", "an", "the", "my", "me", "as", "did", "do", "was", "were",
        "would", "want", "wanted", "like", "with", "into", "for", "of", "and", "or", "about", "something",
        "anything", "maybe", "could", "should", "can", "how", "is", "it", "that", "this", "on", "at", "im",
        "be", "go", "going", "study", "studying", "declare", "declaring", "try", "trying",
    ]

    private static let addWords: Set<String> = [
        "add", "adding", "added", "plus", "also", "too", "double", "second", "another", "pick", "picking",
        "take", "taking",
    ]
    private static let switchWords: Set<String> = [
        "switch", "switching", "switched", "change", "changing", "changed", "transfer", "transferring",
        "instead", "drop", "dropping", "replace", "replacing", "move", "moving", "swap", "swapping",
        "leave", "leaving",
    ]

    private static func changeFor(_ word: String) -> DegreeSearchChange? {
        if addWords.contains(word) { return .add }
        if switchWords.contains(word) { return .switchTo }
        return nil
    }

    /// Plain words to a query.
    ///
    /// Kind and filler words are removed wherever they stand. Change words are
    /// recognised only at the start and the end: in the middle they are
    /// content, because a program title may contain "change" ("social change
    /// studies"). The accepted cost is that "climate change" loses its last
    /// word, which the typed-then-searched flow tolerates.
    public static func parse(_ raw: String) -> DegreeSearchQuery {
        // Apostrophes go before the split: "i'm" must become the filler "im",
        // not "i" and a stray "m" that no program matches.
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        let words = folded
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map { String($0) }

        var kind: DegreeProgramKind? = nil
        var rest: [String] = []
        for word in words {
            if concentrationWords.contains(word) {
                if kind == nil { kind = .concentration }
            } else if majorWords.contains(word) {
                if kind == nil { kind = .major }
            } else if minorWords.contains(word) {
                if kind == nil { kind = .minor }
            } else if fillerWords.contains(word) {
                continue
            } else {
                rest.append(word)
            }
        }

        var change: DegreeSearchChange? = nil
        while let first = rest.first, let found = changeFor(first) {
            if change == nil { change = found }
            rest.removeFirst()
        }
        while let last = rest.last, let found = changeFor(last) {
            if change == nil { change = found }
            rest.removeLast()
        }

        return DegreeSearchQuery(tokens: rest, kind: kind, change: change)
    }

    // MARK: Aliases

    private static let phraseAliases: [String: [String]] = [
        "comp sci": ["computer", "science"],
        "poli sci": ["political", "science"],
        "cog sci": ["cognitive", "science"],
        "data sci": ["data", "science"],
        "mech e": ["mechanical", "engineering"],
        "chem e": ["chemical", "engineering"],
    ]

    private static let wordAliases: [String: [String]] = [
        "cs": ["computer", "science"],
        "compsci": ["computer", "science"],
        "cis": ["computer", "science"],
        "stats": ["statistics"],
        "maths": ["mathematics"],
        "ml": ["machine", "learning"],
        "polisci": ["political", "science"],
        "cogsci": ["cognitive", "science"],
        "ee": ["electrical", "engineering"],
        "meche": ["mechanical", "engineering"],
        "mgmt": ["management"],
        "fnce": ["finance"],
        "mktg": ["marketing"],
        "acct": ["accounting"],
        "oidd": ["operations"],
        "ops": ["operations"],
        "lgst": ["legal", "studies"],
        "bepp": ["business", "economics"],
        "hcmg": ["health", "care"],
        "biz": ["business"],
        "enviro": ["environmental"],
        "ir": ["international", "relations"],
        "comm": ["communication"],
        "comms": ["communication"],
        "nets": ["networked", "social", "systems"],
        "ds": ["data", "science"],
    ]

    private static func aliased(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            if index + 1 < tokens.count, let phrase = phraseAliases[tokens[index] + " " + tokens[index + 1]] {
                out.append(contentsOf: phrase)
                index += 2
            } else if let single = wordAliases[tokens[index]] {
                out.append(contentsOf: single)
                index += 1
            } else {
                out.append(tokens[index])
                index += 1
            }
        }
        return out
    }

    // MARK: Ranking

    private static let stopWords: Set<String> = ["and", "of", "in", "for", "the", "with", "no"]

    private struct Prepared {
        let entry: DegreeProgramEntry
        let words: [String]
        let initials: String
        let codeHead: String
    }

    private struct Score {
        let cost: Int
        let unmatched: Int
    }

    private static func words(of name: String) -> [String] {
        name.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map { String($0).lowercased() }
            .filter { !stopWords.contains($0) }
    }

    private static func prepare(_ entry: DegreeProgramEntry) -> Prepared {
        let entryWords = words(of: entry.name)
        let initials = String(entryWords.compactMap { $0.first })
        let head = entry.listing.code
            .split(separator: "-", omittingEmptySubsequences: false)
            .first.map { String($0).lowercased() } ?? ""
        return Prepared(entry: entry, words: entryWords, initials: initials, codeHead: head)
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a)
        let y = Array(b)
        if abs(x.count - y.count) > 2 { return 99 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let substitution = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + substitution)
            }
            let swapped = previous
            previous = current
            current = swapped
        }
        return previous[y.count]
    }

    /// Cost of one token against one entry word; nil when it does not match.
    private static func wordCost(_ token: String, _ word: String) -> Int? {
        if token == word { return 0 }
        var best = Int.max
        if token.count >= 2, word.hasPrefix(token) { best = 1 }
        if token.count >= 5 {
            var distance = editDistance(token, word)
            if word.count > token.count {
                distance = min(distance, editDistance(token, String(word.prefix(token.count))))
            }
            if distance == 1 {
                best = min(best, 4)
            } else if distance == 2, token.count >= 9 {
                best = min(best, 5)
            }
        }
        if token.count >= 4, word.contains(token) { best = min(best, 6) }
        return best == Int.max ? nil : best
    }

    /// Cost of one token against a whole entry, and which words it touched.
    private static func tokenCost(_ token: String, _ prepared: Prepared, matched: inout Set<Int>) -> Int? {
        var best = Int.max
        if token.count >= 3, token == prepared.codeHead { best = 0 }
        for (index, word) in prepared.words.enumerated() {
            if let cost = wordCost(token, word) {
                matched.insert(index)
                if cost < best { best = cost }
            }
        }
        return best == Int.max ? nil : best
    }

    /// Every token must match; the cost is the sum.
    private static func score(_ tokens: [String], _ prepared: Prepared) -> Score? {
        var total = 0
        var matched = Set<Int>()
        for token in tokens {
            guard let cost = tokenCost(token, prepared, matched: &matched) else { return nil }
            total += cost
        }
        return Score(cost: total, unmatched: max(0, prepared.words.count - matched.count))
    }

    private static func better(_ a: Score?, _ b: Score?) -> Score? {
        guard let a = a else { return b }
        guard let b = b else { return a }
        if a.cost != b.cost { return a.cost < b.cost ? a : b }
        return a.unmatched <= b.unmatched ? a : b
    }

    private static func pool(_ entries: [DegreeProgramEntry], scope: DegreeProgramKind?, query: DegreeSearchQuery) -> [DegreeProgramEntry] {
        guard let effective = scope ?? query.kind else { return entries }
        return entries.filter { $0.kind == effective }
    }

    /// Entries that match every token, best first. With no tokens, the
    /// scope-filtered entries in the order given.
    public static func search(
        _ query: DegreeSearchQuery,
        in entries: [DegreeProgramEntry],
        scope: DegreeProgramKind?
    ) -> [DegreeProgramEntry] {
        let candidates = pool(entries, scope: scope, query: query)
        if query.tokens.isEmpty { return candidates }

        let tokens = query.tokens
        let alternate = aliased(tokens)
        let useAlternate = alternate != tokens
        let initialismToken: String? =
            (tokens.count == 1 && (2...5).contains(tokens[0].count)) ? tokens[0] : nil

        var scored: [(entry: DegreeProgramEntry, score: Score)] = []
        for entry in candidates {
            let prepared = prepare(entry)
            var best = score(tokens, prepared)
            if useAlternate { best = better(best, score(alternate, prepared)) }
            if let token = initialismToken, !prepared.initials.isEmpty, token == prepared.initials {
                best = better(best, Score(cost: 1, unmatched: 0))
            }
            if let found = best { scored.append((entry: entry, score: found)) }
        }

        scored.sort { left, right in
            if left.score.cost != right.score.cost { return left.score.cost < right.score.cost }
            if left.score.unmatched != right.score.unmatched { return left.score.unmatched < right.score.unmatched }
            return ordered(left.entry, right.entry)
        }
        return scored.map { $0.entry }
    }

    /// Groups by kind, keeping the given order inside each; empty kinds omitted.
    public static func sections(_ entries: [DegreeProgramEntry]) -> [DegreeSearchSection] {
        var out: [DegreeSearchSection] = []
        for kind in DegreeProgramKind.allCases {
            let rows = entries.filter { $0.kind == kind }
            if !rows.isEmpty { out.append(DegreeSearchSection(kind: kind, entries: rows)) }
        }
        return out
    }

    /// Catalogue rows for each of `terms` in turn (the subject names the
    /// on-device model suggested), skipping what is excluded or already taken.
    public static func related(
        terms: [String],
        in entries: [DegreeProgramEntry],
        scope: DegreeProgramKind?,
        excluding: Set<String>,
        limit: Int
    ) -> [DegreeProgramEntry] {
        guard limit > 0 else { return [] }
        var taken = Set<String>()
        var out: [DegreeProgramEntry] = []
        for term in terms {
            let query = parse(term)
            // A term that is only kind or filler words would match everything.
            if query.isEmpty { continue }
            for entry in search(query, in: entries, scope: scope) {
                if excluding.contains(entry.id) || taken.contains(entry.id) { continue }
                taken.insert(entry.id)
                out.append(entry)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// The looser net for a search that found little: entries matching at
    /// least one token of three or more characters, those matching more tokens
    /// first.
    public static func loose(
        _ query: DegreeSearchQuery,
        in entries: [DegreeProgramEntry],
        scope: DegreeProgramKind?,
        excluding: Set<String>,
        limit: Int
    ) -> [DegreeProgramEntry] {
        guard limit > 0 else { return [] }
        let tokens = query.tokens.filter { $0.count >= 3 }
        if tokens.isEmpty { return [] }

        var scored: [(entry: DegreeProgramEntry, count: Int, cost: Int)] = []
        for entry in pool(entries, scope: scope, query: query) where !excluding.contains(entry.id) {
            let prepared = prepare(entry)
            var count = 0
            var cost = 0
            for token in tokens {
                var ignored = Set<Int>()
                if let found = tokenCost(token, prepared, matched: &ignored) {
                    count += 1
                    cost += found
                }
            }
            if count > 0 { scored.append((entry: entry, count: count, cost: cost)) }
        }

        scored.sort { left, right in
            if left.count != right.count { return left.count > right.count }
            if left.cost != right.cost { return left.cost < right.cost }
            return ordered(left.entry, right.entry)
        }
        return Array(scored.prefix(limit).map { $0.entry })
    }

    // MARK: Intent

    private static func candidateChanges(_ query: DegreeSearchQuery) -> [PathWhatIfChange] {
        switch (query.kind, query.change) {
        case (.some(.minor), _):
            return [.addMinor]
        case (.some(.concentration), .some(.switchTo)):
            return [.newProgram, .addConcentration]
        case (.some(.concentration), _):
            return [.addConcentration, .newProgram]
        case (.some(.major), .some(.add)):
            return [.addMajor]
        case (.some(.major), .some(.switchTo)):
            return [.newProgram]
        case (.some(.major), nil):
            return []
        case (nil, .some(.add)):
            return [.addConcentration, .addMinor, .addMajor]
        case (nil, .some(.switchTo)):
            return [.newProgram]
        default:
            return []
        }
    }

    /// The plan a typed intent points at, or nil.
    public static func preferredPlan(_ plans: [PathWhatIfPlan], for query: DegreeSearchQuery) -> PathWhatIfPlan? {
        for change in candidateChanges(query) {
            if let plan = plans.first(where: { $0.change == change }) { return plan }
        }
        return nil
    }

    /// The small lowercase line under a row saying what it is.
    public static func actionLine(for entry: DegreeProgramEntry) -> String {
        func join(_ head: String, _ tail: String) -> String { tail.isEmpty ? head : head + " · " + tail }
        switch entry.kind {
        case .concentration:
            if entry.isSibling {
                return join("concentration", entry.collegeName.isEmpty ? entry.degreeCode : entry.collegeName)
            }
            return join("concentration", entry.degreeLabel)
        case .major:
            if entry.isSibling {
                return entry.degreeLabel.isEmpty ? "major" : "major · instead of " + entry.degreeLabel
            }
            return join("major", entry.degreeCode)
        case .minor:
            return "minor"
        case .other:
            return join("program", entry.degreeCode)
        }
    }
}

// On a phone with Apple's on-device model, a search that finds almost nothing
// asks it for subject names, and THOSE are run through
// `DegreeProgramSearch.related`, so nothing the model says reaches the screen
// unless Penn's catalogue has a row for it. The wrong fix is showing the
// model's words as results: a small model will happily name a major Penn does
// not offer, and the student would then be shown a program that cannot be
// audited. The model is a spelling-and-synonym helper for the search, never a
// source of programs.
public enum DegreeSearchAssist {
    public static let instructions: String =
        "You help a university student search a catalogue of academic programs. Given what the student typed, reply with up to six subject names a university would use for majors, minors or concentrations that fit. Prefer names from OPTIONS when they fit. Reply with the names only, separated by commas. No sentences."

    public static func shouldAsk(_ query: DegreeSearchQuery, resultCount: Int) -> Bool {
        !query.isEmpty && query.text.count >= 4 && resultCount < 3
    }

    public static func prompt(request: String, optionNames: [String]) -> String {
        let names = optionNames.prefix(40).map { String($0.prefix(40)) }
        let options = names.isEmpty ? "none" : names.joined(separator: ", ")
        let flat = request
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "OPTIONS: " + options + "\nSTUDENT TYPED: " + String(flat.prefix(160))
    }

    public static func terms(fromReply reply: String) -> [String] {
        // "\r\n" is one Character in Swift, so it is listed beside its halves.
        let separators: Set<Character> = [",", ";", "\n", "\r", "\r\n"]
        let quoteSet = CharacterSet(charactersIn: "\"“”'‘’.").union(.whitespacesAndNewlines)
        var out: [String] = []
        var seen = Set<String>()
        for piece in reply.split(whereSeparator: { separators.contains($0) }) {
            var text = String(piece).trimmingCharacters(in: .whitespacesAndNewlines)
            text = String(text.drop(while: { "-•*–—· \t".contains($0) }))
            // "1." or "2)" numbering.
            let digits = text.prefix(while: { $0.isNumber })
            if !digits.isEmpty {
                let after = text.dropFirst(digits.count)
                if let mark = after.first, mark == "." || mark == ")" {
                    text = String(after.dropFirst())
                }
            }
            text = text.trimmingCharacters(in: quoteSet).lowercased()
            if text.isEmpty || text.count > 40 { continue }
            if text.split(whereSeparator: { $0.isWhitespace }).count > 5 { continue }
            if seen.insert(text).inserted {
                out.append(text)
                if out.count == 6 { break }
            }
        }
        return out
    }
}
