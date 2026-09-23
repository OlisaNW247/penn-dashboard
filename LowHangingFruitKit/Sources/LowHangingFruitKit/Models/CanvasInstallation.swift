import Foundation

/// One institution-specific Canvas installation. Canvas is the product, but
/// every school supplies its own origin and authentication route. Keeping the
/// two URLs separate covers gateways such as Cornell's: login starts on one
/// host and finishes on the host that serves the Canvas API.
public struct CanvasInstallation: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let baseURL: URL
    public let loginURL: URL
    public let isVerified: Bool

    public init(id: String, name: String, baseURL: URL, loginURL: URL? = nil, isVerified: Bool) {
        self.id = id
        self.name = name
        self.baseURL = Self.originURL(from: baseURL) ?? baseURL
        self.loginURL = loginURL ?? baseURL
        self.isVerified = isVerified
    }

    public var host: String { baseURL.host?.lowercased() ?? "" }

    /// WebKit website-data records are grouped by registrable domain rather
    /// than full host. These broad-but-installation-specific fragments cover
    /// the Canvas origin and the common Instructure/Duo hops without baking
    /// Penn's identity provider into every login.
    public var websiteDataDomainHints: [String] {
        var hints = [Self.registrableDomainHint(for: host), "instructure", "duosecurity"]
        if let loginHost = loginURL.host?.lowercased() {
            hints.append(Self.registrableDomainHint(for: loginHost))
        }
        return Array(Set(hints.filter { !$0.isEmpty })).sorted()
    }

    /// Creates an unverified installation from a student-entered address.
    /// Only a normal public HTTPS hostname is accepted; authentication later
    /// proves whether it is actually Canvas.
    public static func custom(address: String) -> CanvasInstallation? {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://" + value }
        guard let entered = URL(string: value),
              entered.scheme?.lowercased() == "https",
              let host = entered.host?.lowercased(),
              !host.isEmpty,
              host.contains("."),
              host != "localhost",
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              !Self.looksLikeIPAddress(host),
              let origin = originURL(from: entered)
        else { return nil }
        return CanvasInstallation(
            id: "custom:\(host)",
            name: host,
            baseURL: origin,
            loginURL: origin,
            isVerified: false
        )
    }

    public static let penn = CanvasInstallation(
        id: "upenn",
        name: "University of Pennsylvania",
        baseURL: URL(string: "https://canvas.upenn.edu")!,
        isVerified: true
    )

    public static let verifiedSchools: [CanvasInstallation] = [
        .penn,
        CanvasInstallation(id: "brown", name: "Brown University", baseURL: URL(string: "https://canvas.brown.edu")!, isVerified: true),
        CanvasInstallation(id: "columbia", name: "Columbia University", baseURL: URL(string: "https://courseworks.columbia.edu")!, isVerified: true),
        CanvasInstallation(id: "cornell", name: "Cornell University", baseURL: URL(string: "https://canvas.cornell.edu")!, loginURL: URL(string: "https://login.canvas.cornell.edu")!, isVerified: true),
        CanvasInstallation(id: "dartmouth", name: "Dartmouth College", baseURL: URL(string: "https://canvas.dartmouth.edu")!, isVerified: true),
        CanvasInstallation(id: "harvard", name: "Harvard University", baseURL: URL(string: "https://canvas.harvard.edu")!, isVerified: true),
        CanvasInstallation(id: "princeton", name: "Princeton University", baseURL: URL(string: "https://canvas.princeton.edu")!, isVerified: true),
        CanvasInstallation(id: "yale", name: "Yale University", baseURL: URL(string: "https://canvas.yale.edu")!, isVerified: true),
    ].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    private static func originURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil
        else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func registrableDomainHint(for host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }

    private static func looksLikeIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}
