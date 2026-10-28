import Foundation

/// Curated US universities and university systems, shipped locally. Address
/// provenance and the full readable list live in docs/canvas-directory/.
/// A directory/HTTP check is not an authenticated Smooth integration test.
enum CanvasSchoolCatalog {
    struct Entry: Sendable {
        let installation: CanvasInstallation
        let aliases: [String]
        let hostAliases: [String]

        init(id: String, name: String, host: String, login: String? = nil,
             aliases: String = "", hostAliases: String = "") {
            if let existing = CanvasInstallation.verifiedSchools.first(where: { $0.id == id }) {
                installation = existing
            } else {
                installation = CanvasInstallation(
                    id: id, name: name, baseURL: URL(string: "https://" + host)!,
                    loginURL: login.flatMap(URL.init(string:)), isVerified: false
                )
            }
            self.aliases = aliases.split(separator: ";").map(String.init)
            self.hostAliases = Array(Set(
                hostAliases.split(separator: ";").map(String.init)
                + [host, installation.host, installation.loginURL.host ?? host]
            ))
        }
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Lower scores are stronger matches. Exact names/acronyms win, then
    /// word prefixes, then small spelling mistakes. Hostnames are not search
    /// labels: incidental domain text should not outrank a university name.
    static func relevance(_ entry: Entry, query: String) -> Int? {
        let query = normalized(query)
        guard query.count >= 2 else { return nil }
        let terms = query.split(separator: " ").map(String.init)
        return ([entry.installation.name] + entry.aliases).compactMap { label -> Int? in
            let label = normalized(label)
            if label == query { return 0 }
            let words = label.split(separator: " ").map(String.init)
            var cost = 0
            for term in terms {
                if words.contains(term) { continue }
                if words.contains(where: { $0.hasPrefix(term) }) {
                    cost += 20
                } else if term.count >= 5,
                          let distance = words.map({ editDistance(term, $0) }).min(),
                          distance <= (term.count >= 8 ? 2 : 1) {
                    cost += 100 + distance
                } else {
                    return nil
                }
            }
            return 10 + cost + max(0, words.count - terms.count)
        }.min()
    }

    // Levenshtein distance keeps typo tolerance bounded to long words, so
    // short acronyms such as MIT do not match a collection of unrelated schools.
    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (i, character) in left.enumerated() {
            var current = [i + 1]
            for (j, other) in right.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1,
                                   previous[j] + (character == other ? 0 : 1)))
            }
            previous = current
        }
        return previous[right.count]
    }
}
