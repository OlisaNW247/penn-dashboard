import Foundation
import LowHangingFruitKit
import Security

/// Persists the login cookies captured from the in-app WebView so the session
/// survives app launches. `WKWebsiteDataStore` drops *session* cookies (no
/// expiry) when the app quits — which is exactly what Gradescope and Penn SSO
/// use — so without this the user is silently logged out on every relaunch.
///
/// Stored in the **Keychain** (not UserDefaults): these are live authentication
/// tokens, so they must be encrypted at rest and kept out of unencrypted device
/// backups. We only need name/value/domain/path to replay the session via
/// `HTTPCookie.requestHeaderFields(with:)`, so that's all we store.
///
/// **Keyed by service, not by domain substring** (docs/CANVAS_LOGIN_HARDENING.md
/// item 2e). Canvas and Gradescope both flow through Penn SSO, so both can
/// leave cookies on `upenn.edu`/`pennkey.upenn.edu` — a domain-substring
/// purge like the old `remove(domainContains: "upenn")` would delete
/// Gradescope's PennKey session while "only" disconnecting Canvas, and vice
/// versa. Each service now gets its own Keychain item, so a Canvas
/// disconnect/purge can only ever touch cookies captured from the Canvas
/// login pane, regardless of which domain they happen to live on.
enum SessionCookieStore {
    enum Service: String, CaseIterable {
        case canvas
        case gradescope
        /// Ed Discussion's session (`us.edstem.org`), captured by
        /// `EdSessionLauncher` from the hidden LTI launch on the Canvas
        /// WebView. Same Keychain home as the others: device-bound
        /// (`AfterFirstUnlockThisDeviceOnly`), never synced, deleted with a
        /// Canvas disconnect (`AppState.disconnectCanvas`) because it exists
        /// only as a child of the Canvas login. Its own item, so removing it
        /// (a 401 from Ed) can never touch a Canvas or Gradescope session.
        ///
        /// **It does not carry the 24-hour no-expiry rule** (see
        /// `maxAge(for:)`): that rule is the *trigger* for Canvas's silent
        /// renewal, which is a thing the app can do. Nothing here can renew
        /// an Ed session except relaunching through Canvas, and Ed's own 401
        /// is the authoritative signal for that, so an Ed cookie is trusted
        /// until Ed says otherwise.
        case ed
    }

    private static func service(for s: Service) -> String {
        "com.lhf.lowhangingfruit.session.\(s.rawValue)"
    }
    private static let account = "sessionCookies"

    /// Merge the given cookies into `service`'s persisted set (replacing any
    /// with the same name+domain+path).
    ///
    /// A read-modify-write, and the read decides whether the write happens.
    /// When the Keychain will not answer (`unavailable`: a device locked
    /// before first unlock, a refused access list) nothing is written:
    /// treating that as "nothing saved yet" would replace the whole stored
    /// set, session cookie included, with just the cookies in hand. The fresh
    /// cookies are lost for this call, which costs one more renewal; the saved
    /// set is not.
    static func save(_ cookies: [HTTPCookie], service: Service) {
        guard !cookies.isEmpty else { return }
        guard let stored = storedSet(afterSaving: cookies, into: readDicts(service: service)) else { return }
        write(stored, service: service)
    }

    /// Pure half of `save`: the set to persist after adding `cookies` to what
    /// the read found, or `nil` when the read was `unavailable` and nothing
    /// may be written. `notFound` starts from an empty set.
    static func storedSet(
        afterSaving cookies: [HTTPCookie],
        into read: KeychainRead<[[String: String]]>
    ) -> [[String: String]]? {
        var stored: [[String: String]]
        switch read {
        case let .found(dicts): stored = dicts
        case .notFound: stored = []
        case .unavailable: return nil
        }
        for cookie in cookies {
            let d = dict(from: cookie)
            stored.removeAll { $0["name"] == d["name"] && $0["domain"] == d["domain"] && $0["path"] == d["path"] }
            stored.append(d)
        }
        return stored
    }

    /// Merges freshly re-issued cookies into the persisted set for `service`:
    /// an incoming cookie replaces any stored cookie with the same
    /// (name, domain, path); everything else is kept. Cookies whose
    /// expiresDate is already past are dropped rather than stored — a
    /// Set-Cookie with a past expiry is the server deleting that cookie.
    /// Saving also refreshes the store's own staleness clock (see
    /// `sessionCookieMaxAge`), which is the point: a session that keeps
    /// getting used keeps reading as fresh. Canvas's sliding sessions
    /// re-mint the session cookie on every authenticated response
    /// (`CanvasGradesClient.refreshedCookieHandler`), so a caller that wires
    /// that handler up to this merge is what turns "ages out from login"
    /// into "stays alive as long as the app is actually used."
    static func merge(_ fresh: [HTTPCookie], service: Service) {
        guard !fresh.isEmpty else { return }
        // Never touch the developer's real Keychain item under `swift
        // test` — the same trap `SharedDefaults.isTestRunner` guards
        // everywhere else in this codebase (CLAUDE.md: an unsandboxed
        // macOS test run resolves real on-device state without the
        // entitlement that would otherwise gate it).
        guard !SharedDefaults.isTestRunner else { return }
        let existing = load(service: service)
        let combined = merged(existing: existing, fresh: fresh)
        guard !combined.isEmpty else { return }
        save(combined, service: service)
    }

    /// Pure merge logic behind `merge(_:service:)`: an incoming cookie
    /// replaces any existing cookie with the same (name, domain, path);
    /// everything else in `existing` is kept as-is. An incoming cookie whose
    /// `expiresDate` is already past is dropped rather than carried forward
    /// — a `Set-Cookie` with a past expiry is the server's own way of
    /// deleting that cookie, so re-adding it would resurrect something the
    /// server just killed. No Keychain I/O, so this is the seam the test
    /// suite exercises directly instead of going through the real Keychain.
    static func merged(existing: [HTTPCookie], fresh: [HTTPCookie]) -> [HTTPCookie] {
        guard !fresh.isEmpty else { return existing }
        let now = Date()
        var result = existing
        for cookie in fresh {
            result.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if let expires = cookie.expiresDate, expires <= now { continue }
            result.append(cookie)
        }
        return result
    }

    /// Loads `service`'s persisted cookies, dropping any that are stale: a
    /// cookie carrying a real, past `expiresDate` (from `Set-Cookie: ...;
    /// Expires=` or `Max-Age=`), or one with no expiry at all (a true session
    /// cookie — Penn SSO's and Canvas's are both this kind) that's older than
    /// `sessionCookieMaxAge` since it was captured. Without this, a
    /// session-only cookie captured at connect time would be replayed as a
    /// live session forever, regardless of whether the server-side session
    /// died hours or weeks ago — exactly the mechanism behind
    /// docs/CANVAS_LOGIN_DIAGNOSIS.md's H1/H2.
    ///
    /// For Canvas, what survives that per-cookie check is then gated on the
    /// session cookie itself (`gatedOnLiveSession`): a set that once held
    /// `canvas_session` reads as empty the moment `canvas_session` is gone,
    /// even if analytics cookies saved beside it are still inside their own
    /// far-future `expiresDate`. Without the gate those cookies keep this
    /// method from ever returning empty, so `isExpired` never goes true and
    /// the renew-on-open trigger never fires (found on a real phone,
    /// 2026-10-08). The decision is made here, at read time, on purpose:
    /// sets already saved on students' phones are polluted, and filtering
    /// the two cookie harvests alone would leave every one of them broken.
    static func load(service: Service) -> [HTTPCookie] {
        let now = Date()
        let entries = loadDicts(service: service)
        let fresh = entries.compactMap { entry -> HTTPCookie? in
            guard let cookie = cookie(from: entry) else { return nil }
            if let expiresString = entry["expiresDate"], let expires = isoFormatter.date(from: expiresString) {
                return expires > now ? cookie : nil
            }
            if let capturedString = entry["capturedAt"], let captured = isoFormatter.date(from: capturedString) {
                return isStale(capturedAt: captured, now: now, service: service) ? nil : cookie
            }
            // No expiry and no capture timestamp recorded (data written before
            // this staleness tracking existed) — treat as expired rather than
            // eternal, forcing a fresh login instead of silently replaying an
            // untraceable cookie of unknown age.
            return nil
        }
        return gatedOnLiveSession(fresh: fresh, persistedNames: entries.compactMap { $0["name"] }, service: service)
    }

    /// Canvas's own session cookie names, matched as a case-insensitive
    /// substring of the cookie's `name`: `canvas_session` is Canvas's own
    /// Rails session cookie, `_normandy_session` is Instructure's shared
    /// Normandy auth service cookie (so `_legacy_normandy_session` counts
    /// too). Either one present on a Canvas cookie means "a real session was
    /// minted." `CanvasSessionRenewer` keeps its own private copy of these
    /// same two markers for its harvest check, left untouched on purpose
    /// (the harvests stay as `39b2fff` ran them); if one list ever changes,
    /// change the other, or the renewer and the read-time gate will disagree
    /// about what a session cookie is.
    private static let canvasSessionCookieNameMarkers = ["canvas_session", "_normandy_session"]

    /// True when `name` is one of Canvas's session cookie names (see
    /// `canvasSessionCookieNameMarkers`), as opposed to a CSRF token, a
    /// Canvas "log_session_id", or an analytics cookie such as `_ga`.
    static func isCanvasSessionCookieName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return canvasSessionCookieNameMarkers.contains { lowered.contains($0) }
    }

    /// The read-time gate behind `load(service:)`: a Canvas set that once
    /// held a session cookie is only as alive as that cookie. `fresh` is what
    /// survived the per-cookie staleness check (`isStale`, or the cookie's own
    /// `expiresDate`); `persistedNames` is every name on record for the
    /// service, stale or not. Pure, so the tests call it without touching
    /// the Keychain.
    ///
    /// Why it exists: the harvests save more than the session.
    /// `CanvasLoginPane.connect()` keeps every cookie on the Canvas host and
    /// `CanvasSessionRenewer` keeps every cookie whose domain contains
    /// "canvas", so `_ga`, `_gid` and `last_known_canvas_host` ride along with
    /// real expiry dates months or a year out. They are never stale, so
    /// `load` never came back empty once `canvas_session` itself had aged
    /// out, and `isExpired` (the renew-on-open trigger) read false forever.
    /// The wrong fix is filtering the harvests alone: the sets already saved
    /// on students' phones stay polluted, and whether a phone is polluted is
    /// a race at each harvest (was the analytics script done when the
    /// cookies were read), so only a decision made at read time reaches all
    /// of them. The harvests are left as they were for the same reason as
    /// above, and this gate does not make them necessary.
    ///
    /// The rules:
    /// - Not Canvas: returned unchanged. Gradescope never had this problem,
    ///   Ed's session is judged by Ed's own 401, and their cookie names are
    ///   not ours to judge. (A `guard`, not an exhaustive `switch`, so `.ed`
    ///   and any service case added later falls through unchanged.)
    /// - No session-named cookie was ever persisted: returned unchanged. A
    ///   Canvas install whose session cookie has a name we do not know (an
    ///   unverified school's) keeps exactly the old rule. The wrong version
    ///   of this gate returns empty here, which reads such an install as
    ///   signed out forever.
    /// - `fresh` still holds a session-named cookie: returned unchanged,
    ///   analytics cookies included. This is not a filter on what gets
    ///   replayed to Canvas.
    /// - Otherwise the session is gone and only bystanders are left: `[]`.
    static func gatedOnLiveSession(fresh: [HTTPCookie], persistedNames: [String], service: Service) -> [HTTPCookie] {
        guard service == .canvas else { return fresh }
        guard persistedNames.contains(where: isCanvasSessionCookieName) else { return fresh }
        guard !fresh.contains(where: { isCanvasSessionCookieName($0.name) }) else { return fresh }
        return []
    }

    /// Every service's persisted cookies, folded together. Only for read
    /// paths that genuinely don't care which service a cookie came from (e.g.
    /// diagnostics); prefer `load(service:)` everywhere a specific service's
    /// session is what's actually needed.
    static func loadAll() -> [HTTPCookie] {
        Service.allCases.flatMap { load(service: $0) }
    }

    /// True when `service` once had a captured login session that's now
    /// entirely expired/stale (every persisted entry was dropped by
    /// `load(service:)`'s staleness check) — as opposed to never having had
    /// one at all. Lets a caller distinguish "reconnect, your session died"
    /// from "you never logged in via this path" (e.g. a feed-only/paste-link
    /// Canvas user, who never captured a cookie session and shouldn't be
    /// nagged to reconnect one). See `AppState.canvasSessionExpired`.
    ///
    /// **Left alone on purpose when the "login is gone" fix was written
    /// (`AppState.canvasLoginIsMissing`).** This answers "there WAS a session
    /// and it aged out", and it can only answer that while something is still
    /// saved: a deleted item reads `false` here, exactly as a calendar-link
    /// install that never had a session does, because the store keeps no
    /// record that a login ever happened. The wrong fix is making this return
    /// `true` for "nothing saved": it would raise the "needs a refresh" banner
    /// on every pasted-link install (and every install before its first
    /// login), none of which has anything to refresh. The missing fact, "this
    /// install did log in once", lives in `AppState` (`canvasLoginEverCaptured`),
    /// which is where the other half of the decision is, and it asks the store
    /// only `hasSavedCookies(service:)` below.
    ///
    /// "Every persisted entry was dropped" is read through the live-session
    /// gate in `load(service:)`, so for Canvas it also holds when the session
    /// cookie is gone and only analytics cookies with far-future expiry dates
    /// remain. That is the case that used to keep this false forever on a
    /// polluted set, which switched off the 24-hour renew-on-open trigger.
    /// No code here had to change; the wrong fix was filtering the harvests
    /// alone, which leaves sets already on students' phones broken.
    ///
    /// **Unavailable is "not expired".** This reads the Keychain twice (the
    /// saved entries, then `load(service:)`), and a read the Keychain refuses
    /// used to come back as `[]` from either. A refusal on the second read
    /// alone looked exactly like "something saved and nothing fresh left", so
    /// it raised the banner and started a renewal over a perfectly good saved
    /// session. A refused read is no evidence that anything aged out: it
    /// answers false, and an empty `load` is only believed after a third read
    /// confirms the set is still there.
    static func isExpired(service: Service) -> Bool {
        isExpired(
            service: service,
            read: { readDicts(service: $0) },
            fresh: { load(service: $0) }
        )
    }

    /// The decision behind `isExpired(service:)`, with both Keychain reads
    /// injected so a test can refuse one.
    static func isExpired(
        service: Service,
        read: (Service) -> KeychainRead<[[String: String]]>,
        fresh: (Service) -> [HTTPCookie]
    ) -> Bool {
        guard case let .found(entries) = read(service), !entries.isEmpty else { return false }
        guard fresh(service).isEmpty else { return false }
        // `fresh` read the Keychain itself. An empty answer from a read that
        // was refused only that second time looks identical to "every cookie
        // aged out", so ask once more before believing it.
        guard case .found = read(service) else { return false }
        return true
    }

    /// True when `service` has ANY persisted cookie entry, live or stale.
    /// Deliberately not `!load(service:).isEmpty`: `load` drops the stale
    /// ones, and the caller (`AppState.canvasLoginIsMissing`) needs to tell
    /// "saved but aged out", which `isExpired` already reports, from "nothing
    /// saved at all", which is the state a rejected Grade Watcher fetch leaves
    /// behind (`GradeWatcherView.performRefresh` removes the item).
    ///
    /// **Unavailable is "saved".** A Keychain that will not answer has not
    /// said the cookies are gone, and "nothing saved" is what raises the
    /// "your login is gone" banner (`AppState.canvasLoginIsMissing`). Failing
    /// toward "saved" costs a banner that appears one launch later if the
    /// cookies really are missing; failing toward "nothing saved" signs a
    /// student out of a session that is sitting in the Keychain.
    static func hasSavedCookies(service: Service) -> Bool {
        hasSavedCookies(from: readDicts(service: service))
    }

    /// The decision behind `hasSavedCookies(service:)`, on an injected read.
    static func hasSavedCookies(from read: KeychainRead<[[String: String]]>) -> Bool {
        switch read {
        case let .found(entries): return !entries.isEmpty
        case .notFound: return false
        case .unavailable: return true
        }
    }

    /// What an empty Gradescope cookie set means for the reconnect verdict
    /// (`GradescopeReauthRule`), given the Keychain's answer about the saved
    /// set. The coordinator asks only after it has found nothing to replay.
    ///
    /// - A saved set that is definitively gone (not found, or entries that are
    ///   all expired by their own server-set dates) is a `loginForm`-grade
    ///   sighting: Gradescope's server cannot recognise a phone that holds no
    ///   session, and with nothing to send, no response will ever say so. Two
    ///   such runs an hour apart raise the line like any other.
    /// - A Keychain that would not answer is `inconclusive`: it says nothing
    ///   about whether the cookies exist.
    ///
    /// `isExpired` is injected and only asked about a non-empty set, because
    /// it reads the Keychain itself and confirms with a second read.
    static func emptySetOutcome(
        read: KeychainRead<[[String: String]]>,
        isExpired: () -> Bool
    ) -> GradescopeReauthRule.Outcome {
        switch read {
        case .unavailable:
            return .inconclusive
        case .notFound:
            return .loginForm
        case let .found(entries):
            if entries.isEmpty { return .loginForm }
            return isExpired() ? .loginForm : .inconclusive
        }
    }

    /// `emptySetOutcome` against the real Keychain, for Gradescope.
    static func emptyGradescopeSetOutcome() -> GradescopeReauthRule.Outcome {
        emptySetOutcome(
            read: readDicts(service: .gradescope),
            isExpired: { isExpired(service: .gradescope) }
        )
    }

    /// How long a true session cookie (no server-supplied expiry) is trusted
    /// after capture before it's treated as dead and dropped rather than
    /// replayed. Penn SSO/Canvas sessions don't survive this long in
    /// practice; this is a safety bound, not an attempt to model their real
    /// server-side timeout.
    private static let sessionCookieMaxAge: TimeInterval = 24 * 60 * 60

    /// The no-expiry trust window for `service`, or `nil` for a service that
    /// has none. Only Canvas keeps the 24 hours (`sessionCookieMaxAge`); Ed
    /// and, since 2026-10-27, Gradescope have no clock at all.
    ///
    /// **Why Canvas keeps it.** The 24-hour rule is Canvas's renewal
    /// *trigger*: it is what flips `canvasSessionExpired` and starts the
    /// silent re-login, which the app can actually perform (the saved PennKey,
    /// Duo's trust cookie).
    ///
    /// **Why Gradescope lost it.** Nothing on the phone can renew a Gradescope
    /// session, so for Gradescope the clock was only ever a way to sign the
    /// student out: a day after the last save `load` read the set as empty and
    /// `AutoSyncCoordinator` took that for "disconnected" (SYN-01, SES-008 in
    /// `docs/HARDENING_PLAN_2026-10-25.md`). Gradescope's server decides when
    /// its session is dead, and the proof is a response that is a login form
    /// (`GradescopeHTMLParser.isLoginPage`, judged by `GradescopeReauthRule`),
    /// not a cookie's age on this phone. The wrong fix is raising 24 hours to
    /// seven days: that is the same clock, later, and it still can only sign a
    /// student out.
    ///
    /// The same shape as Ed's, and for the same reason; the wrong version of
    /// adding `.ed` was letting it inherit the 24 hours by falling through
    /// `load(service:)` unchanged: the session would silently die a day after
    /// every launch, and unlike Canvas nothing renews it on the next open
    /// except a fresh LTI launch the coordinator only makes when the store
    /// comes back empty or Ed answers 401.
    static func maxAge(for service: Service) -> TimeInterval? {
        switch service {
        case .canvas: return sessionCookieMaxAge
        case .gradescope, .ed: return nil
        }
    }

    /// Pure staleness rule behind `load(service:)` for a cookie with no
    /// server-supplied expiry, split out so a test can age a cookie without
    /// touching the Keychain.
    static func isStale(capturedAt: Date, now: Date, service: Service) -> Bool {
        guard let limit = maxAge(for: service) else { return false }
        return now.timeIntervalSince(capturedAt) >= limit
    }

    // `ISO8601DateFormatter` isn't `Sendable`, but every use here is a simple
    // stateless format/parse call (no shared mutable configuration is ever
    // written after init), so a single shared instance is safe in practice.
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    /// Removes every service's persisted cookies.
    static func clear() {
        for s in Service.allCases { KeychainItem.delete(baseQuery(service: s)) }
    }

    /// Removes only `service`'s persisted cookies, leaving every other
    /// service's session untouched — including one that happens to share a
    /// domain (e.g. both flowing through `upenn.edu` Penn SSO).
    static func remove(service: Service) {
        KeychainItem.delete(baseQuery(service: service))
    }

    #if DEBUG
    /// `-LHFAgeCanvasSession` seam: rewrites every persisted Canvas cookie's
    /// `capturedAt` to 25 hours ago, deleting nothing and changing nothing
    /// else. Lets a debug launch exercise the real 24h renewal trigger in
    /// `load(service:)` above on demand, instead of waiting a real day for a
    /// session to age past `sessionCookieMaxAge`. A no-op under `swift test`
    /// for the same reason `merge` is: an unsandboxed macOS test run would
    /// otherwise reach a developer's real Keychain item.
    static func ageCanvasSessionForTesting(by age: TimeInterval = 25 * 60 * 60) {
        guard !SharedDefaults.isTestRunner else { return }
        var dicts = loadDicts(service: .canvas)
        guard !dicts.isEmpty else { return }
        let staleString = isoFormatter.string(from: Date().addingTimeInterval(-age))
        for index in dicts.indices {
            dicts[index]["capturedAt"] = staleString
        }
        write(dicts, service: .canvas)
    }

    /// `-LHFSessionDiagnostics` seam (`DebugSessionDiagnostics`): one line per
    /// persisted cookie for `service`, giving its domain, name, expiry and
    /// capture time, and never its value. It exists because the 24h rule in
    /// `load(service:)` only trips when EVERY persisted cookie is stale, and
    /// a cookie carrying a real, far-future `expiresDate` is never stale, so
    /// the only way to tell why a phone's renew-on-open trigger did or didn't
    /// fire is to see what the set actually holds. A name is cut at its first
    /// `|` for the same reason `AppState.duoCookieDisplayName` cuts Duo's:
    /// what follows can be a per-device identifier.
    static func debugEntrySummaries(service: Service) -> [String] {
        loadDicts(service: service).map { entry in
            let name = (entry["name"] ?? "?").split(separator: "|").first.map(String.init) ?? "?"
            let marker = isCanvasSessionCookieName(name) ? " | session" : ""
            return "\(entry["domain"] ?? "?") | \(name) | expires \(entry["expiresDate"] ?? "none") | captured \(entry["capturedAt"] ?? "none")\(marker)"
        }
    }
    #endif

    // MARK: - Keychain

    private static func baseQuery(service: Service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service(for: service),
            kSecAttrAccount as String: account,
        ]
    }

    /// The persisted entries in three answers (see `KeychainRead`). A blob
    /// that is present but is not the JSON we wrote reads as `notFound`: it is
    /// corrupt, no later read will fix it, and the next `save` replaces it.
    private static func readDicts(service: Service) -> KeychainRead<[[String: String]]> {
        KeychainItem.read(baseQuery(service: service)).decoded {
            try? JSONSerialization.jsonObject(with: $0) as? [[String: String]]
        }
    }

    /// The entries, or `[]` for anything but a successful read. Kept for the
    /// callers that only want the entries (`load(service:)` among them). The
    /// two decisions that must tell "empty" from "refused" (`isExpired`,
    /// `hasSavedCookies`) and the read-modify-write (`save`) use `readDicts`.
    private static func loadDicts(service: Service) -> [[String: String]] {
        readDicts(service: service).value ?? []
    }

    /// Persists `dicts`, replacing the item in place (`KeychainItem.write`:
    /// update first, add only when nothing is there, every status counted).
    /// The old "Keychain has no upsert, so delete then add" left a window with
    /// no session saved at all, and discarded the add's status.
    @discardableResult
    private static func write(_ dicts: [[String: String]], service: Service) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: dicts) else { return false }
        return KeychainItem.write(data, base: baseQuery(service: service)) == errSecSuccess
    }

    // MARK: - Serialization

    /// `HTTPCookiePropertyKey` has no built-in case for `HttpOnly` — Foundation
    /// only exposes it as a read-only computed property (`cookie.isHTTPOnly`)
    /// backed by this undocumented-but-stable raw key, same as WebKit/curl
    /// use on the wire.
    private static let httpOnlyKey = HTTPCookiePropertyKey("HttpOnly")

    private static func dict(from cookie: HTTPCookie) -> [String: String] {
        var d: [String: String] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure ? "1" : "0",
            "httpOnly": cookie.isHTTPOnly ? "1" : "0",
            "capturedAt": isoFormatter.string(from: Date()),
        ]
        if let expires = cookie.expiresDate {
            d["expiresDate"] = isoFormatter.string(from: expires)
        }
        if let sameSite = cookie.sameSitePolicy {
            d["sameSite"] = sameSite.rawValue
        }
        return d
    }

    private static func cookie(from d: [String: String]) -> HTTPCookie? {
        guard let name = d["name"], let value = d["value"], let domain = d["domain"] else { return nil }
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: d["path"] ?? "/",
        ]
        if d["secure"] == "1" { props[.secure] = "TRUE" }
        if d["httpOnly"] == "1" { props[httpOnlyKey] = "TRUE" }
        if let expiresString = d["expiresDate"], let expires = isoFormatter.date(from: expiresString) {
            props[.expires] = expires
        }
        if let sameSite = d["sameSite"] {
            props[.sameSitePolicy] = sameSite
        }
        return HTTPCookie(properties: props)
    }
}
