import Foundation

/// The invite sheet's school search: the schools the ambassador site already
/// has first, then the app's own catalog of Canvas schools (so a new school
/// arrives with its Canvas host and no app update). The catalog's own
/// relevance rule does the ranking; nothing here scores anything.
public enum AmbassadorSchoolSearch {
    public struct Match: Equatable, Sendable {
        public var name: String
        public var shortName: String
        /// The site's id when the school already exists there.
        public var existingID: String?
        /// The school's Canvas host, for a catalog entry.
        public var host: String?

        public init(name: String, shortName: String, existingID: String? = nil, host: String? = nil) {
            self.name = name
            self.shortName = shortName
            self.existingID = existingID
            self.host = host
        }
    }

    public static func matches(query: String, existing: [AmbassadorPlan.Invite.School],
                               limit: Int = 6) -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, limit > 0 else { return [] }
        var result: [Match] = []
        var listed = Set<String>()
        for school in existing where school.name.range(of: trimmed, options: .caseInsensitive) != nil {
            result.append(Match(name: school.name, shortName: school.name, existingID: school.id, host: nil))
            listed.insert(CanvasSchoolCatalog.normalized(school.name))
        }
        let ranked = CanvasSchoolCatalog.entries.compactMap { entry -> (CanvasSchoolCatalog.Entry, Int)? in
            guard let score = CanvasSchoolCatalog.relevance(entry, query: trimmed) else { return nil }
            return (entry, score)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.installation.name.localizedStandardCompare(rhs.0.installation.name) == .orderedAscending
        }
        for (entry, _) in ranked {
            let name = entry.installation.name
            let key = CanvasSchoolCatalog.normalized(name)
            if listed.contains(key) { continue }
            listed.insert(key)
            let short: String
            if let first = entry.aliases.first, first.count <= 24, !first.isEmpty {
                short = first
            } else {
                short = name
            }
            result.append(Match(name: name, shortName: short, existingID: nil, host: entry.installation.host))
        }
        return Array(result.prefix(limit))
    }
}
