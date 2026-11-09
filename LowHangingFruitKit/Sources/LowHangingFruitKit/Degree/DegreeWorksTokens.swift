import Foundation

// Degree progress, v12 (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md).
// Cookie names and the JWT claim layout are unverified against Penn's live
// Degree Works; they come from Penn Labs' client.

/// The two cookies Degree Works hands back after the SAML hop. They are
/// bearer credentials, so `description` is redacted and nothing in the Kit
/// ever prints or logs a token. Persistence is the UI layer's Keychain job.
public struct DegreeWorksTokens: Sendable, Equatable, CustomStringConvertible {
    public let authToken: String
    public let refreshToken: String?

    public init(authToken: String, refreshToken: String?) {
        self.authToken = authToken
        self.refreshToken = refreshToken
    }

    /// The student id Degree Works keys every call on: the JWT's `sub`.
    public var studentID: String? { JWTClaims.subject(authToken) }

    public var authExpiresAt: Date? { JWTClaims.expiry(authToken) }

    /// Usable when it has at least a minute left, or carries no `exp` at all
    /// (then the server is the judge, and a 401 sends us back to sign in).
    public func isUsable(now: Date) -> Bool {
        guard let expiry = authExpiresAt else { return true }
        return expiry > now.addingTimeInterval(60)
    }

    /// Picks the first cookie with each exact name, on any domain. Another
    /// school's tokens carried a "Bearer+" prefix inside the cookie value;
    /// it is stripped so the JWT decodes and the header is the bare token.
    public static func from(cookies: [HTTPCookie]) -> DegreeWorksTokens? {
        guard let auth = cookies.first(where: { $0.name == DegreeWorksEndpoints.authCookieName }) else { return nil }
        let authValue = stripBearer(auth.value)
        guard !authValue.isEmpty else { return nil }
        let refresh = cookies.first(where: { $0.name == DegreeWorksEndpoints.refreshCookieName })
            .map { stripBearer($0.value) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return DegreeWorksTokens(authToken: authValue, refreshToken: refresh)
    }

    static func stripBearer(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Bearer+", "Bearer ", "Bearer%20", "Bearer%2B"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        return value
    }

    /// "X-AUTH-TOKEN=…; REFRESH_TOKEN=…". The UI client attaches it; the
    /// request builders in this Kit never set a Cookie header.
    public var cookieHeader: String {
        var parts = ["\(DegreeWorksEndpoints.authCookieName)=\(authToken)"]
        if let refreshToken { parts.append("\(DegreeWorksEndpoints.refreshCookieName)=\(refreshToken)") }
        return parts.joined(separator: "; ")
    }

    public var description: String {
        "DegreeWorksTokens(auth: present, refresh: \(refreshToken == nil ? "absent" : "present"))"
    }
}

/// Reads a JWT's claims without verifying it. We are not the audience; we
/// only need `sub` and `exp`, and the server verifies the signature.
public enum JWTClaims {
    public static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }

    public static func subject(_ token: String) -> String? {
        guard let value = payload(token)?["sub"] else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// `exp` as a number or a numeric string, seconds since 1970.
    public static func expiry(_ token: String) -> Date? {
        guard let value = payload(token)?["exp"] else { return nil }
        if let text = value as? String, let seconds = Double(text.trimmingCharacters(in: .whitespaces)) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        return nil
    }
}
