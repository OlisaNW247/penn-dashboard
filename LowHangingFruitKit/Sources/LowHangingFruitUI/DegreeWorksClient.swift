import Foundation
import LowHangingFruitKit

/// Reads the student's degree audit from Penn's Degree Works with the tokens
/// `DegreeWorksSessionReader` obtained. The request shapes live in the Kit
/// (`DegreeWorksRequests`, pure, testable); this adds what only the UI layer
/// owns: the session cookies, the headers Degree Works wants (Penn Labs sent
/// `Host` and `Origin`; the dashboard itself sends `X-Requested-With`), the
/// network call, and the three-step strategy for finding out WHICH audit to
/// ask for.
///
/// **Why a strategy.** Which degree a student is in is not known to the phone.
/// The endpoint that says (`/api/students/myself`) is a best guess
/// (`DegreeWorksEndpoints.studentPath`), so it is tried and read leniently:
/// (1) if it yields a school and a degree, GET that audit; (2) otherwise POST
/// a what-if with `isKeepCurriculum: true` and no goals, which asks Degree
/// Works to audit the student as they are; (3) if that is refused as a bad
/// request, throw `.needsGoals` so the screen asks the student to pick their
/// degree once. The wrong fix is guessing a degree for the student: an audit
/// of the wrong degree looks entirely plausible.
///
/// **Privacy.** Nothing here logs a token, a cookie, a query string, a
/// student id or a body. `log` receives words and the request path only, and
/// `shape` receives JSON key names only. Both callbacks are the caller's.
///
/// **Unverified.** Every endpoint and status code below was read from Penn
/// Labs' open source and a third-party CLI, not observed against Penn's live
/// system (2026-11-09); constants live in `DegreeWorksEndpoints`.
struct DegreeWorksClient: Sendable {
    enum Failure: Error, Equatable {
        /// 401 or 403: the tokens are no longer accepted. The caller drops
        /// them and reads the session once more.
        case tokensRejected
        /// Degree Works would not audit "the student as they are": the
        /// student has to say which degree.
        case needsGoals
        case http(Int)
        case transport
        case decode
    }

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let fetch: Fetch
    private let log: @Sendable (String) -> Void

    init(
        fetch: @escaping Fetch = { request in try await URLSession.shared.data(for: request) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.fetch = fetch
        self.log = log
    }

    // MARK: Strategy

    /// The current audit, by the strategy above.
    func fetchCurrentAudit(
        tokens: DegreeWorksTokens,
        now: Date,
        shape: @Sendable ([String]) -> Void = { _ in }
    ) async throws -> DegreeAudit {
        guard let studentID = tokens.studentID, !studentID.isEmpty else {
            // A token with no readable subject cannot be a session Degree
            // Works issued; treat it as rejected so the reader runs again.
            throw Failure.tokensRejected
        }

        // Step 1: ask who the student is. Any non-auth failure here only
        // means the guessed endpoint is wrong, so it falls through to step 2.
        if let goals = try await studentGoals(tokens: tokens),
           let school = goals.school, let degree = goals.degree {
            let request = DegreeWorksRequests.currentAudit(studentID: studentID, school: school, degree: degree)
            let (data, status) = try await send(request, tokens: tokens)
            if (200..<300).contains(status) {
                return try decode(data, goals: goals, isWhatIf: false, now: now, shape: shape)
            }
            if status == 401 || status == 403 { throw Failure.tokensRejected }
            log("audit: GET step failed \(status); trying the keep-curriculum audit")
        }

        // Step 2: audit the student as they are, no goals.
        let request = DegreeWorksRequests.whatIfAudit(studentID: studentID, goals: DegreeGoals(), keepCurriculum: true)
        let (data, status) = try await send(request, tokens: tokens)
        if (200..<300).contains(status) {
            return try decode(data, goals: DegreeGoals(), isWhatIf: false, now: now, shape: shape)
        }
        if status == 401 || status == 403 { throw Failure.tokensRejected }
        // Step 3: Degree Works wants to be told the degree.
        if status == 400 || status == 404 || status == 422 { throw Failure.needsGoals }
        throw Failure.http(status)
    }

    /// An audit for `goals`: a what-if, or (with `keepCurriculum`) the
    /// student's own curriculum with the student's picked goals.
    func fetchAudit(
        tokens: DegreeWorksTokens,
        goals: DegreeGoals,
        keepCurriculum: Bool,
        isWhatIf: Bool,
        now: Date,
        shape: @Sendable ([String]) -> Void = { _ in }
    ) async throws -> DegreeAudit {
        guard let studentID = tokens.studentID, !studentID.isEmpty else { throw Failure.tokensRejected }
        let request = DegreeWorksRequests.whatIfAudit(studentID: studentID, goals: goals, keepCurriculum: keepCurriculum)
        let (data, status) = try await send(request, tokens: tokens)
        if status == 401 || status == 403 { throw Failure.tokensRejected }
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        return try decode(data, goals: goals, isWhatIf: isWhatIf, now: now, shape: shape)
    }

    /// The choices for the what-if picker, narrowed by what is `selected`.
    func fetchCatalog(tokens: DegreeWorksTokens, selected: DegreeGoals) async throws -> DegreeGoalCatalog {
        let (data, status) = try await send(DegreeWorksRequests.goalsCatalog(selected: selected), tokens: tokens)
        if status == 401 || status == 403 { throw Failure.tokensRejected }
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        do {
            return try DegreeGoalCatalog.decode(data)
        } catch {
            throw Failure.decode
        }
    }

    // MARK: Plumbing

    private func studentGoals(tokens: DegreeWorksTokens) async throws -> DegreeGoals? {
        let (data, status) = try await send(DegreeWorksRequests.studentSelf(), tokens: tokens)
        if status == 401 || status == 403 { throw Failure.tokensRejected }
        guard (200..<300).contains(status) else { return nil }
        return StudentSelfReader.goals(from: data)
    }

    private func decode(
        _ data: Data,
        goals: DegreeGoals,
        isWhatIf: Bool,
        now: Date,
        shape: @Sendable ([String]) -> Void
    ) throws -> DegreeAudit {
        do {
            let audit = try DegreeWorksAuditDecoder.decode(data, goals: goals, isWhatIf: isWhatIf, now: now)
            shape(DegreeWorksAuditDecoder.keyShape(of: data))
            return audit
        } catch {
            // Key names only, even for a body that did not decode, so the
            // capture session can see what Penn actually sent.
            shape(DegreeWorksAuditDecoder.keyShape(of: data))
            throw Failure.decode
        }
    }

    /// Adds the session and the headers, sends, and returns the status.
    /// Throws `.transport` for anything that is not an HTTP answer.
    private func send(_ original: URLRequest, tokens: DegreeWorksTokens) async throws -> (Data, Int) {
        var request = original
        request.setValue(tokens.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(DegreeWorksEndpoints.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("\(DegreeWorksEndpoints.host):\(DegreeWorksEndpoints.port)", forHTTPHeaderField: "Host")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        let path = request.url?.path ?? "(no path)"
        do {
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse else { throw Failure.transport }
            log("\(request.httpMethod ?? "GET") \(path) -> \(http.statusCode)")
            return (data, http.statusCode)
        } catch let failure as Failure {
            throw failure
        } catch {
            log("\(request.httpMethod ?? "GET") \(path) -> transport error")
            throw Failure.transport
        }
    }
}
