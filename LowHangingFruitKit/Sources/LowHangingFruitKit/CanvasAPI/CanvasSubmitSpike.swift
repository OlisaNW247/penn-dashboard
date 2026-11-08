import Foundation

/// Phase 0 diagnostic for docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md §8
/// items 1-2: does a Canvas submission POST work from URLSession with the
/// student's saved session cookies plus an `X-CSRF-Token` header? Reading
/// canvas-lms source says yes (§4), but nobody has seen it on a real phone,
/// and whether `_csrf_token` even survives in the saved jar is unverified.
///
/// This is a spike, never a product feature: it is reachable only from the
/// DEBUG launch argument `-LHFSubmitSpike`. The production path is
/// `CanvasSubmissionClient` (Phase 4, not yet written); nothing here should
/// grow into it.
///
/// The enum is pure so every request shape and failure class is testable
/// without a network. Secrets are kept out of the output by construction:
/// no function here formats a cookie value or token into a string, and the
/// runner logs only booleans, statuses, counts and URL paths.
public enum CanvasSubmitSpike {
    public enum Outcome: Equatable, Sendable {
        case created(attempt: Int?, workflowState: String?, submittedAt: String?)
        case csrfOrValidation(message: String)
        case sessionDead
        case refused(status: Int, message: String)
        case other(status: Int)
    }

    static let csrfCookieName = "_csrf_token"

    // MARK: CSRF

    /// The header value Canvas's own UI sends: the `_csrf_token` cookie,
    /// percent-decoded and otherwise untouched.
    public static func csrfToken(fromCookies cookies: [HTTPCookie]) -> String? {
        guard let cookie = cookies.first(where: { $0.name == csrfCookieName }) else { return nil }
        return decoded(cookie.value)
    }

    /// Cookie handling is off on these requests, so the GET's `Set-Cookie`
    /// lines have to be read by hand. Each line is parsed on its own so a
    /// comma inside an `Expires` date cannot split one cookie into two.
    public static func csrfToken(fromSetCookieHeaders headers: [String]) -> String? {
        let url = URL(string: "https://canvas.invalid/")!
        for line in headers {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": line], for: url)
            if let token = csrfToken(fromCookies: cookies) { return token }
        }
        return nil
    }

    private static func decoded(_ raw: String) -> String? {
        let value = raw.removingPercentEncoding ?? raw
        return value.isEmpty ? nil : value
    }

    // MARK: URLs

    public static func preflightURL(baseURL: URL, courseID: String, assignmentID: String) -> URL {
        var components = URLComponents(url: assignmentBase(baseURL, courseID, assignmentID), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "include[]", value: "submission"),
            URLQueryItem(name: "include[]", value: "can_submit"),
        ]
        return components.url!
    }

    public static func submissionsURL(baseURL: URL, courseID: String, assignmentID: String) -> URL {
        assignmentBase(baseURL, courseID, assignmentID).appendingPathComponent("submissions")
    }

    public static func verifyURL(baseURL: URL, courseID: String, assignmentID: String) -> URL {
        submissionsURL(baseURL: baseURL, courseID: courseID, assignmentID: assignmentID).appendingPathComponent("self")
    }

    private static func assignmentBase(_ baseURL: URL, _ courseID: String, _ assignmentID: String) -> URL {
        baseURL.appendingPathComponent("api/v1/courses/\(courseID)/assignments/\(assignmentID)")
    }

    // MARK: Requests

    public static func textEntryRequest(
        url: URL,
        body: String,
        csrfToken: String,
        cookies: [HTTPCookie],
        origin: URL
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-Token")
        // Canvas does no Origin check of its own; same-origin values are sent
        // anyway so the request looks like the one its UI makes.
        let originString = originString(origin)
        request.setValue(originString, forHTTPHeaderField: "Origin")
        request.setValue(originString + "/", forHTTPHeaderField: "Referer")
        CanvasAuth.apply(to: &request, cookies: cookies, accessToken: nil)
        let payload: [String: Any] = [
            "submission": [
                "submission_type": "online_text_entry",
                "body": "<p>\(escapeHTML(body))</p>",
            ] as [String: Any],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }

    public static func getRequest(url: URL, cookies: [HTTPCookie]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        CanvasAuth.apply(to: &request, cookies: cookies, accessToken: nil)
        return request
    }

    private static func originString(_ origin: URL) -> String {
        var text = "\(origin.scheme ?? "https")://\(origin.host ?? "")"
        if let port = origin.port { text += ":\(port)" }
        return text
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Classification

    public static func classify(status: Int, contentType: String?, body: Data) -> Outcome {
        if status == 401 || (300..<400).contains(status) { return .sessionDead }
        if let contentType, contentType.localizedCaseInsensitiveContains("text/html") { return .sessionDead }
        let stripped = CourseContentAPI.stripAntiHijackPrefix(body)
        switch status {
        case 200..<300:
            let object = (try? JSONSerialization.jsonObject(with: stripped)) as? [String: Any]
            return .created(
                attempt: object?["attempt"] as? Int,
                workflowState: object?["workflow_state"] as? String,
                submittedAt: object?["submitted_at"] as? String
            )
        case 422:
            return .csrfOrValidation(message: snippet(stripped))
        case 400, 403:
            return .refused(status: status, message: snippet(stripped))
        default:
            return .other(status: status)
        }
    }

    static func snippet(_ data: Data) -> String {
        String(String(decoding: data, as: UTF8.self).prefix(300))
    }
}

/// Drives the whole spike against one assignment. Exactly one POST, plus one
/// retry after a 422 with a fresh token; never a third.
public struct CanvasSubmitSpikeRunner {
    private let session: URLSession
    private let baseURL: URL
    private let cookies: [HTTPCookie]

    public init(session: URLSession, baseURL: URL, cookies: [HTTPCookie]) {
        self.session = session
        self.baseURL = baseURL
        self.cookies = cookies
    }

    public func run(courseID: String, assignmentID: String, log: @Sendable (String) -> Void) async {
        func say(_ text: String) { log("LHF-SUBMIT \(text)") }
        do {
            let jarToken = CanvasSubmitSpike.csrfToken(fromCookies: cookies)
            say("jar csrf present: \(jarToken != nil)")

            let preflightURL = CanvasSubmitSpike.preflightURL(baseURL: baseURL, courseID: courseID, assignmentID: assignmentID)
            let pre = try await get(preflightURL)
            let object = (try? JSONSerialization.jsonObject(with: CourseContentAPI.stripAntiHijackPrefix(pre.data))) as? [String: Any]
            let types = (object?["submission_types"] as? [String]) ?? []
            let locked = object?["locked_for_user"] as? Bool
            let canSubmit = object?["can_submit"] as? Bool
            let setCookieToken = pre.setCookieToken
            say("preflight status: \(pre.status) submission_types: \(types.joined(separator: ",")) locked_for_user: \(describe(locked)) can_submit: \(describe(canSubmit)) allowed_attempts: \(describe(object?["allowed_attempts"]))")
            say("setcookie csrf present: \(setCookieToken != nil)")
            guard types.contains("online_text_entry") else { return say("abort: online_text_entry not in submission_types") }
            guard locked == false else { return say("abort: locked_for_user is not false") }
            guard canSubmit != false else { return say("abort: can_submit is false") }

            var token = setCookieToken ?? jarToken
            say("csrf source: \(setCookieToken != nil ? "setcookie" : (jarToken != nil ? "jar" : "none"))")
            guard let first = token else { return say("abort: no csrf token") }

            let submissionsURL = CanvasSubmitSpike.submissionsURL(baseURL: baseURL, courseID: courseID, assignmentID: assignmentID)
            var outcome = try await post(submissionsURL, token: first, say: say)

            if case .csrfOrValidation = outcome {
                let again = try await get(preflightURL)
                token = again.setCookieToken ?? token
                say("retry after 422 with fresh token from setcookie: \(again.setCookieToken != nil)")
                if let retryToken = token {
                    outcome = try await post(submissionsURL, token: retryToken, say: say)
                }
            }

            let verifyURL = CanvasSubmitSpike.verifyURL(baseURL: baseURL, courseID: courseID, assignmentID: assignmentID)
            let verify = try await get(verifyURL)
            let v = (try? JSONSerialization.jsonObject(with: CourseContentAPI.stripAntiHijackPrefix(verify.data))) as? [String: Any]
            say("verify status: \(verify.status) attempt: \(describe(v?["attempt"])) workflow_state: \(describe(v?["workflow_state"])) submitted_at: \(describe(v?["submitted_at"]))")
            say("done")
        } catch {
            say("error: \(type(of: error))")
        }
    }

    // MARK: Steps

    private struct Reply {
        let status: Int
        let contentType: String?
        let data: Data
        let setCookieToken: String?
    }

    private func get(_ url: URL) async throws -> Reply {
        try await send(CanvasSubmitSpike.getRequest(url: url, cookies: cookies))
    }

    private func post(_ url: URL, token: String, say: (String) -> Void) async throws -> CanvasSubmitSpike.Outcome {
        let request = CanvasSubmitSpike.textEntryRequest(url: url, body: "spike", csrfToken: token, cookies: cookies, origin: baseURL)
        let reply = try await send(request)
        let outcome = CanvasSubmitSpike.classify(status: reply.status, contentType: reply.contentType, body: reply.data)
        say("post status: \(reply.status) content-type: \(reply.contentType ?? "none") body length: \(reply.data.count) outcome: \(label(outcome))")
        switch outcome {
        case let .created(attempt, state, submittedAt):
            say("created attempt: \(describe(attempt)) workflow_state: \(describe(state)) submitted_at: \(describe(submittedAt))")
        case let .csrfOrValidation(message), let .refused(_, message):
            say("body: \(message)")
        default:
            break
        }
        return outcome
    }

    private func send(_ request: URLRequest) async throws -> Reply {
        let (data, response) = try await session.credentialSafeData(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // `allHeaderFields` joins repeated Set-Cookie headers with commas;
        // the token parser handles a joined value the same as a single one.
        let setCookie = (http.allHeaderFields.first { ($0.key as? String)?.lowercased() == "set-cookie" }?.value as? String).map { [$0] } ?? []
        return Reply(
            status: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            data: data,
            setCookieToken: CanvasSubmitSpike.csrfToken(fromSetCookieHeaders: setCookie)
        )
    }

    private func label(_ outcome: CanvasSubmitSpike.Outcome) -> String {
        switch outcome {
        case .created: return "created"
        case .csrfOrValidation: return "csrfOrValidation"
        case .sessionDead: return "sessionDead"
        case .refused: return "refused"
        case .other: return "other"
        }
    }

    private func describe(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "nil" }
        return "\(value)"
    }
}
