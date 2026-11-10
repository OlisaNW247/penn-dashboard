import Foundation

/// The app's first write to Canvas (docs/AGENT_CONNECTION_PLAN_V11_2026-11-07.md,
/// Phase 4): a submission the student reviewed and confirmed, sent with their
/// own saved session (cookies plus `X-CSRF-Token`, the header Canvas's own UI
/// sends). Promoted from `CanvasSubmitSpike`, whose request shape is reused;
/// **never run against real Canvas** as of 2026-11-10 (Known gaps).
///
/// What it does, in order, and why each step is where it is:
///
/// 1. **Preflight GET** of the assignment with `include[]=submission`. It is
///    harmless, so everything that can refuse is decided here, before any
///    POST: the assignment takes this kind of submission (`submission_types`),
///    it is not locked, the student may submit (`can_submit` when Canvas sends
///    it), a file's extension is allowed. It also returns the current
///    attempt, which the verify step compares against, and usually a fresh
///    `_csrf_token` in `Set-Cookie`.
/// 2. **`beforeFirstPost`**, the caller's attempt record. If it throws,
///    nothing is posted. This is the one place the order matters more than
///    anything else in the file; `CanvasSubmissionClientTests` pins it.
/// 3. For a file, **Canvas's upload**: POST `.../submissions/self/files` for an
///    upload slot, then a multipart POST of the bytes to the slot's
///    `upload_url` (another origin as a rule: no cookie, no CSRF header is
///    ever sent there), then, when Canvas answers with a location instead of
///    the file, one GET to confirm. No submission exists yet at any point
///    here, so every failure in this step is definite.
/// 4. **The submission POST**, exactly once. **No automatic retry, ever**,
///    not even the spike's retry after a 422: a 422 can be a stale CSRF token
///    or a real validation error, and only one of those is safe to repeat.
/// 5. **Verify GET** of `.../submissions/self`: `submitted_at` is set and the
///    attempt moved past the preflight's. A failed or disagreeing verify does
///    not undo a 2xx with a submission id (Canvas said it made it); it only
///    reports `verified: false`, which the sheet words as "check canvas".
///
/// Outcomes are three-valued on purpose. `failed` means Canvas definitely
/// made nothing (it refused, or the request never left the phone);
/// `indeterminate` means a POST went out and the answer is unknown (a
/// timeout, a dropped connection, a 5xx). The caller must treat
/// indeterminate as "maybe submitted": keep the attempt, say "check canvas",
/// and never try again on its own.
///
/// Logging: none. No function here formats a cookie, a token, a body or a
/// URL query into a string; error classes are fixed short words.
public struct CanvasSubmissionClient: Sendable {
    public enum Payload: Equatable, Sendable {
        case text(String)
        case url(URL)
        case file(name: String, mimeType: String, data: Data)

        /// The Canvas `submission_type` this needs.
        public var submissionType: String {
            switch self {
            case .text: return "online_text_entry"
            case .url: return "online_url"
            case .file: return "online_upload"
            }
        }
    }

    /// Refused before any POST: no attempt is recorded, the draft stays open.
    public enum Refusal: String, Equatable, Sendable {
        case missingIDs = "missing_ids"
        case unsupportedType = "unsupported_type"
        case locked
        case sessionDead = "session"
        case noCSRF = "no_csrf"
        case offline
        case preflightFailed = "preflight"
        case attemptNotRecorded = "attempt_not_recorded"
    }

    public enum Outcome: Equatable, Sendable {
        case submitted(submissionID: String, attempt: Int?, verified: Bool)
        case failed(errorClass: String)
        case refused(Refusal)
        case indeterminate
    }

    private let session: URLSession
    private let baseURL: URL
    private let cookies: [HTTPCookie]

    public init(session: URLSession, baseURL: URL, cookies: [HTTPCookie]) {
        self.session = session
        self.baseURL = baseURL
        self.cookies = cookies
    }

    // MARK: The run

    public func submit(
        courseID: String,
        assignmentID: String,
        payload: Payload,
        beforeFirstPost: () throws -> Void
    ) async -> Outcome {
        guard Self.isCanvasID(courseID), Self.isCanvasID(assignmentID) else { return .refused(.missingIDs) }

        // 1. Preflight.
        let preflightURL = CanvasSubmitSpike.preflightURL(baseURL: baseURL, courseID: courseID, assignmentID: assignmentID)
        let pre: Reply
        do {
            pre = try await send(Self.getRequest(url: preflightURL, cookies: cookies))
        } catch {
            return .refused(Self.isNeverSent(error) ? .offline : .preflightFailed)
        }
        if Self.isSessionDead(pre) { return .refused(.sessionDead) }
        guard (200..<300).contains(pre.status) else { return .refused(.preflightFailed) }
        let assignment = Self.json(pre.data) ?? [:]
        let types = (assignment["submission_types"] as? [String]) ?? []
        guard Self.accepts(types: types, payload: payload,
                           allowedExtensions: assignment["allowed_extensions"] as? [String]) else {
            return .refused(.unsupportedType)
        }
        if assignment["locked_for_user"] as? Bool == true { return .refused(.locked) }
        if assignment["can_submit"] as? Bool == false { return .refused(.locked) }
        let priorAttempt = (assignment["submission"] as? [String: Any]).flatMap { Self.int($0["attempt"]) }

        guard let token = pre.setCookieToken ?? CanvasSubmitSpike.csrfToken(fromCookies: cookies) else {
            return .refused(.noCSRF)
        }

        // 2. The attempt record, before anything is posted.
        do { try beforeFirstPost() } catch { return .refused(.attemptNotRecorded) }

        // 3. The file, if any.
        var fileID: String?
        if case let .file(name, mimeType, data) = payload {
            switch await upload(courseID: courseID, assignmentID: assignmentID, name: name,
                                mimeType: mimeType, data: data, token: token) {
            case .success(let id): fileID = id
            case .failure(let failure): return .failed(errorClass: failure.rawValue)
            }
        }

        // 4. The submission, once.
        let submissionsURL = CanvasSubmitSpike.submissionsURL(baseURL: baseURL, courseID: courseID, assignmentID: assignmentID)
        let request = Self.submissionRequest(url: submissionsURL, payload: payload, fileID: fileID,
                                             csrfToken: token, cookies: cookies, origin: baseURL)
        let posted: Reply
        do {
            posted = try await send(request)
        } catch {
            return Self.isNeverSent(error) ? .failed(errorClass: "offline") : .indeterminate
        }
        if Self.isSessionDead(posted) { return .failed(errorClass: "session") }
        switch posted.status {
        case 200..<300:
            break
        case 400, 403, 404, 409, 422:
            return .failed(errorClass: "rejected_\(posted.status)")
        default:
            // 5xx and anything unexpected: Canvas may have made it.
            return .indeterminate
        }
        let created = Self.json(posted.data) ?? [:]
        guard let submissionID = Self.idString(created["id"]) else { return .indeterminate }
        let attempt = Self.int(created["attempt"])

        // 5. Verify.
        let verifyURL = CanvasSubmitSpike.verifyURL(baseURL: baseURL, courseID: courseID, assignmentID: assignmentID)
        let verified: Bool
        if let reply = try? await send(Self.getRequest(url: verifyURL, cookies: cookies)),
           (200..<300).contains(reply.status), !Self.isSessionDead(reply) {
            verified = Self.verifyAgrees(Self.json(reply.data) ?? [:], postedAttempt: attempt, priorAttempt: priorAttempt)
        } else {
            verified = false
        }
        return .submitted(submissionID: submissionID, attempt: attempt, verified: verified)
    }

    // MARK: Upload

    enum UploadFailure: String, Error {
        case start = "upload_start"
        case transfer = "upload"
        case confirm = "upload_confirm"
        case session
    }

    private func upload(courseID: String, assignmentID: String, name: String, mimeType: String,
                        data: Data, token: String) async -> Result<String, UploadFailure> {
        let startURL = CanvasSubmitSpike.verifyURL(baseURL: baseURL, courseID: courseID, assignmentID: assignmentID)
            .appendingPathComponent("files")
        let start = Self.uploadStartRequest(url: startURL, name: name, size: data.count, mimeType: mimeType,
                                            csrfToken: token, cookies: cookies, origin: baseURL)
        guard let slotReply = try? await send(start) else { return .failure(.start) }
        if Self.isSessionDead(slotReply) { return .failure(.session) }
        guard (200..<300).contains(slotReply.status),
              let slot = Self.json(slotReply.data),
              let uploadString = slot["upload_url"] as? String,
              let uploadURL = URL(string: uploadString), uploadURL.scheme == "https"
        else { return .failure(.start) }
        let params = (slot["upload_params"] as? [String: Any] ?? [:]).compactMapValues { value -> String? in
            if let s = value as? String { return s }
            if let n = value as? NSNumber { return n.stringValue }
            return nil
        }
        let fileParam = (slot["file_param"] as? String) ?? "file"

        let boundary = "smooth-\(UUID().uuidString)"
        var transfer = URLRequest(url: uploadURL)
        transfer.httpMethod = "POST"
        transfer.httpShouldHandleCookies = false
        transfer.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        transfer.setValue("application/json", forHTTPHeaderField: "Accept")
        transfer.httpBody = Self.multipartBody(params: params, fileParam: fileParam, fileName: name,
                                               mimeType: mimeType, data: data, boundary: boundary)
        // No cookies and no CSRF header: the slot's URL is the file store's,
        // usually another origin, and its params carry their own signature.
        guard let uploaded = try? await sendWithoutRedirects(transfer) else { return .failure(.transfer) }

        if (200..<300).contains(uploaded.status), let object = Self.json(uploaded.data) {
            if let id = Self.idString(object["id"]) { return .success(id) }
            if let location = (object["location"] as? String).flatMap(URL.init(string:)) {
                return await confirm(location)
            }
            return .failure(.transfer)
        }
        if (300..<400).contains(uploaded.status), let location = uploaded.location {
            return await confirm(location)
        }
        return .failure(.transfer)
    }

    /// The legacy S3 flow and some inst-fs answers hand back a Canvas URL to
    /// GET. Cookies go only to Canvas's own origin.
    private func confirm(_ location: URL) async -> Result<String, UploadFailure> {
        var request = URLRequest(url: location)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if CredentialOrigin.isSameOrigin(location, as: baseURL) {
            CanvasAuth.apply(to: &request, cookies: cookies, accessToken: nil)
        }
        guard let reply = try? await send(request), (200..<300).contains(reply.status),
              let id = Self.json(reply.data).flatMap({ Self.idString($0["id"]) })
        else { return .failure(.confirm) }
        return .success(id)
    }

    // MARK: Requests (pure)

    static func getRequest(url: URL, cookies: [HTTPCookie]) -> URLRequest {
        CanvasSubmitSpike.getRequest(url: url, cookies: cookies)
    }

    static func jsonPost(url: URL, payload: [String: Any], csrfToken: String,
                         cookies: [HTTPCookie], origin: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-Token")
        let originString = Self.originString(origin)
        request.setValue(originString, forHTTPHeaderField: "Origin")
        request.setValue(originString + "/", forHTTPHeaderField: "Referer")
        CanvasAuth.apply(to: &request, cookies: cookies, accessToken: nil)
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }

    public static func submissionRequest(url: URL, payload: Payload, fileID: String?, csrfToken: String,
                                         cookies: [HTTPCookie], origin: URL) -> URLRequest {
        var submission: [String: Any] = ["submission_type": payload.submissionType]
        switch payload {
        case .text(let body): submission["body"] = htmlBody(body)
        case .url(let link): submission["url"] = link.absoluteString
        case .file:
            // Canvas's ids are integers; a string id is sent as Canvas gave it.
            if let fileID, let number = Int(fileID) {
                submission["file_ids"] = [number]
            } else {
                submission["file_ids"] = [fileID ?? ""]
            }
        }
        return jsonPost(url: url, payload: ["submission": submission], csrfToken: csrfToken,
                        cookies: cookies, origin: origin)
    }

    static func uploadStartRequest(url: URL, name: String, size: Int, mimeType: String,
                                   csrfToken: String, cookies: [HTTPCookie], origin: URL) -> URLRequest {
        jsonPost(url: url, payload: ["name": name, "size": size, "content_type": mimeType],
                 csrfToken: csrfToken, cookies: cookies, origin: origin)
    }

    /// The draft's plain text as Canvas's rich-text body: paragraphs on blank
    /// lines, `<br>` on single line breaks, everything escaped. The agent's
    /// text is never sent as raw HTML, so it cannot smuggle markup (an image
    /// that phones home, a hidden paragraph) into the student's submission.
    public static func htmlBody(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return paragraphs.map { paragraph in
            "<p>" + paragraph.components(separatedBy: "\n").map(escapeHTML).joined(separator: "<br>") + "</p>"
        }.joined()
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func multipartBody(params: [String: String], fileParam: String, fileName: String,
                              mimeType: String, data: Data, boundary: String) -> Data {
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        // Canvas documents the params in the order it gave them; keys sorted
        // keeps the body deterministic, and S3 requires only that the file
        // comes last.
        for key in params.keys.sorted() {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(quoted(key))\"")
            line("")
            line(params[key] ?? "")
        }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"\(quoted(fileParam))\"; filename=\"\(quoted(fileName))\"")
        line("Content-Type: \(mimeType)")
        line("")
        body.append(data)
        line("")
        line("--\(boundary)--")
        return body
    }

    private static func quoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    private static func originString(_ origin: URL) -> String {
        var text = "\(origin.scheme ?? "https")://\(origin.host ?? "")"
        if let port = origin.port { text += ":\(port)" }
        return text
    }

    // MARK: Rules (pure)

    /// Text, a link or a file, and only when Canvas lists that type. Quizzes,
    /// external tools, media recordings, annotation, "on paper" and "none" all
    /// answer false, so they are refused before anything is posted.
    public static func accepts(types: [String], payload: Payload, allowedExtensions: [String]?) -> Bool {
        guard types.contains(payload.submissionType) else { return false }
        if case let .file(name, _, _) = payload, let allowed = allowedExtensions, !allowed.isEmpty {
            let ext = (name as NSString).pathExtension.lowercased()
            return allowed.map { $0.lowercased() }.contains(ext)
        }
        return true
    }

    /// `submitted_at` is set, and the attempt is the one the POST returned, or
    /// past the one the preflight saw.
    static func verifyAgrees(_ object: [String: Any], postedAttempt: Int?, priorAttempt: Int?) -> Bool {
        guard let submittedAt = object["submitted_at"] as? String, !submittedAt.isEmpty else { return false }
        let attempt = int(object["attempt"])
        if let postedAttempt, let attempt { return attempt >= postedAttempt }
        if let priorAttempt, let attempt { return attempt > priorAttempt }
        // Nothing to compare: Canvas's own submitted_at is the evidence.
        return true
    }

    static func isCanvasID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 20 && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The request never reached a server: safe to call a definite failure.
    /// Every other transport error after a POST (a timeout, a dropped
    /// connection) is indeterminate.
    static func isNeverSent(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .appTransportSecurityRequiresSecureConnection:
            return true
        default:
            return false
        }
    }

    private static func isSessionDead(_ reply: Reply) -> Bool {
        if reply.status == 401 || (300..<400).contains(reply.status) { return true }
        if let type = reply.contentType, type.localizedCaseInsensitiveContains("text/html") { return true }
        return false
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: CourseContentAPI.stripAntiHijackPrefix(data))) as? [String: Any]
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func idString(_ value: Any?) -> String? {
        if let n = value as? NSNumber { return n.stringValue }
        if let s = value as? String, !s.isEmpty, s.count <= 64 { return s }
        return nil
    }

    // MARK: Transport

    struct Reply {
        let status: Int
        let contentType: String?
        let data: Data
        let setCookieToken: String?
        let location: URL?
    }

    private func send(_ request: URLRequest) async throws -> Reply {
        let (data, response) = try await session.credentialSafeData(for: request)
        return try Self.reply(data, response)
    }

    private func sendWithoutRedirects(_ request: URLRequest) async throws -> Reply {
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        return try Self.reply(data, response)
    }

    private static func reply(_ data: Data, _ response: URLResponse) throws -> Reply {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let setCookie = (http.allHeaderFields.first { ($0.key as? String)?.lowercased() == "set-cookie" }?.value as? String)
            .map { [$0] } ?? []
        return Reply(
            status: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            data: data,
            setCookieToken: CanvasSubmitSpike.csrfToken(fromSetCookieHeaders: setCookie),
            location: http.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: http.url)?.absoluteURL }
        )
    }
}

/// The upload's answer is read as it comes: a redirect is Canvas telling us
/// where to confirm, and following it automatically would turn a POST into a
/// GET on a URL we have not checked.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
