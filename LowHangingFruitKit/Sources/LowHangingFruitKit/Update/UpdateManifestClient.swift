import Foundation

/// Fetches the hosted update manifest and decodes it into an `UpdatePolicy`.
/// Modeled directly on `CanvasICSClient`: a thin `Sendable` wrapper around a
/// `URLSession`, with the parsing step exposed as a pure static function so
/// tests never need the network.
public struct UpdateManifestClient: Sendable {
    public enum Error: Swift.Error, Sendable {
        case http(status: Int)
        case notHTTP
    }

    private let manifestURL: URL
    private let session: URLSession

    public init(manifestURL: URL, session: URLSession = .shared) {
        self.manifestURL = manifestURL
        self.session = session
    }

    public func fetchPolicy() async throws -> UpdatePolicy {
        // `.reloadRevalidatingCacheData` rather than the default protocol
        // cache policy: a stale cached copy of this specific file is worse
        // than no copy at all, because the whole point of fetching it is to
        // learn about a state change (a new minimum version) that a stale
        // cache would hide by definition. This runs on the launch path, so
        // the 10s timeout matters too — the app must not hang waiting on a
        // version check before it can show anything, cached or not.
        let request = URLRequest(
            url: manifestURL,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: 10
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode)
        }
        return try Self.policy(from: data)
    }

    /// Exposed as a pure function so tests don't need the network.
    public static func policy(from data: Data) throws -> UpdatePolicy {
        try JSONDecoder().decode(UpdatePolicy.self, from: data)
    }
}
