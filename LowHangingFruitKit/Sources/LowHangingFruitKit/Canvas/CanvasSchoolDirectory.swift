import Foundation

/// The same public directory used by Instructure's Canvas login finder.
/// Directory membership identifies a login route, not a tested integration.
public enum CanvasSchoolDirectory {
    public static let bundledSchools: [CanvasInstallation] = CanvasSchoolCatalog.entries
        .map(\.installation)
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    public static func bundledMatches(for query: String) -> [CanvasInstallation] {
        let matches = CanvasSchoolCatalog.entries.compactMap { entry -> (CanvasInstallation, Int)? in
            guard let score = CanvasSchoolCatalog.relevance(entry, query: query) else { return nil }
            return (entry.installation, score)
        }
        // Typo matches are a fallback. A precise acronym such as UPenn
        // must not gain unrelated schools merely one edit away from Penn.
        let hasDirectMatch = matches.contains { $0.1 < 100 }
        return matches.filter { !hasDirectMatch || $0.1 < 100 }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
        }.map { $0.0 }
    }

    private static let knownByHost: [String: CanvasInstallation] = {
        var result: [String: CanvasInstallation] = [:]
        for entry in CanvasSchoolCatalog.entries {
            for host in entry.hostAliases { result[host] = entry.installation }
        }
        return result
    }()

    public static func request(for query: String) -> URLRequest {
        var components = URLComponents(string: "https://sso.canvaslms.com/api/v1/accounts/search")!
        components.queryItems = [
            URLQueryItem(name: "search_term", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "per_page", value: "100")
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        return request
    }

    public static func search(_ query: String, session: URLSession) async throws -> [CanvasInstallation] {
        let (data, response) = try await session.data(for: request(for: query))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> [CanvasInstallation] {
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        let candidates: [CanvasInstallation] = entries.compactMap { entry in
            guard let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let domain = entry.domain,
                  let origin = CanvasInstallation.custom(address: domain),
                  // The directory contract is a hostname, never a URL/path.
                  domain.lowercased() == origin.host else { return nil }
            let provider = entry.authentication_provider ?? ""
            guard provider.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) else { return nil }
            if let known = knownByHost[origin.host] {
                return known
            }
            let id = "directory:\(origin.host)"
            let loginURL = provider.isEmpty ? origin.baseURL : origin.baseURL.appendingPathComponent("login").appendingPathComponent(provider)
            return CanvasInstallation(id: id, name: name, baseURL: origin.baseURL,
                                      loginURL: loginURL, isVerified: false)
        }
        // Directory aliases and student/guest authentication routes do not
        // represent separate Canvas sites. If a site has multiple routes,
        // enter at its root so Canvas can present its own login choices.
        var sites: [String: CanvasInstallation] = [:]
        for candidate in candidates {
            guard let existing = sites[candidate.host] else {
                sites[candidate.host] = candidate
                continue
            }
            if bundledSchools.contains(where: { $0.id == existing.id }) { continue }
            let labels: [String] = [existing.name, candidate.name]
            let cleaned: [String] = labels.map { (label: String) -> String in
                label.replacingOccurrences(of: #"(?i)\s*[-–]\s*(students?|guests?|parents?|staff|faculty)$"#,
                                           with: "", options: .regularExpression)
            }
            let names = cleaned.sorted { (lhs: String, rhs: String) -> Bool in
                if lhs.count == rhs.count { return lhs < rhs }
                return lhs.count < rhs.count
            }
            let name = names[0]
            sites[candidate.host] = CanvasInstallation(
                id: existing.id, name: name, baseURL: existing.baseURL,
                loginURL: existing.loginURL == candidate.loginURL ? existing.loginURL : existing.baseURL,
                isVerified: false
            )
        }
        return sites.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func merging(_ remote: [CanvasInstallation], query: String) -> [CanvasInstallation] {
        // Only curated university sites belong in onboarding. The public
        // directory also returns training, extension and online-program sites.
        // Never relabel those different hosts as a school's primary Canvas.
        bundledMatches(for: query)
    }

    private struct Entry: Decodable {
        let name: String?
        let domain: String?
        let authentication_provider: String?
    }
}
