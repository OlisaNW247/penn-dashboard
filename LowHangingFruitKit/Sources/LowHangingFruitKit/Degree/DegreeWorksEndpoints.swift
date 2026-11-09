import Foundation

// Degree progress, v12 (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md).
// EVERY constant here is unverified against Penn's live system: they come
// from Penn Labs' open-source client and a Degree Works CLI, not from a
// capture. They live in this one file so a capture session changes constants,
// not code.

public enum DegreeWorksEndpoints {
    public static let host = "degreeworks-prod-j.isc-seo.upenn.edu"
    public static let port = 9904
    public static var baseURL: URL {
        URL(string: "https://\(host):\(port)") ?? URL(fileURLWithPath: "/")
    }
    /// First guess at the SSO entry: the dashboard root should bounce to Penn
    /// WebLogin and return with the two token cookies set.
    public static let dashboardPath = "/worksheets/"
    public static let pathAtPennFallbackEntry = URL(string: "https://path.at.upenn.edu/")!
    public static let auditPath = "/api/audit"
    public static let goalsPath = "/api/goals"
    /// Best guess; the reader of its answer is lenient.
    public static let studentPath = "/api/students/myself"
    public static let auditAccept = "application/vnd.net.hedtech.degreeworks.dashboard.audit.v1+json"
    public static let authCookieName = "X-AUTH-TOKEN"
    public static let refreshCookieName = "REFRESH_TOKEN"
    /// The footer's "official audit" link.
    public static let officialAuditURL = URL(string: "https://path.at.upenn.edu/")!
}
