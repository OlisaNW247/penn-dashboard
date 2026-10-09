import Foundation
import LowHangingFruitKit

/// Runs one Ed Discussion sync (`docs/ED_DISCUSSION.md`): find which Canvas
/// courses have an "Ed Discussion" nav tool, get an Ed session out of the
/// Canvas login (`EdSessionLauncher`), match Ed's enrolled courses to the
/// student's Canvas courses, read each matched course's threads, and merge
/// the kept ones into the knowledge base as `.ed` documents.
///
/// **Never throws.** Every step is guarded so one failure becomes a note in
/// the `Report` and the rest of the sync still runs where it can. The
/// caller (`AppState.refreshCourseKnowledge`) treats Ed as an enrichment on
/// top of the Canvas sync: an Ed failure must never cost the student the
/// Canvas materials, and a Canvas-only student must never see it fail.
///
/// **Privacy.** Notes carry course codes, counts and error descriptions
/// only; never a cookie value, a URL query string or a thread body. Nothing
/// here is logged beyond the notes the caller already shows in the sync
/// trace.
@MainActor
final class EdDiscussionCoordinator {
    struct Report: Sendable {
        /// Canvas codes whose Ed threads were read this run, with the Ed
        /// course each was matched to.
        var matched: [(code: String, edCourseID: Int)] = []
        /// Ed documents that are new or changed since the knowledge base
        /// handed in (an unchanged thread is not counted).
        var documentsAdded = 0
        var notes: [String] = []
        var statusLine: String
    }

    /// `[canvasCourseID: launchURL]`; a course with no Ed tab has no entry.
    nonisolated static let launchURLKey = "edLaunchURLByCanvasCourseV1"
    /// `[canvasCourseID: Date]` of the last successful tab check, kept
    /// separately so "checked, no Ed" is remembered as well as "has Ed".
    nonisolated static let tabCheckedAtKey = "edTabCheckedAtByCanvasCourseV1"
    /// Set when this coordinator removes a stored Ed session that Ed
    /// rejected, so the next sync's launch is forced past the launcher's
    /// 30-minute throttle. Cleared by a successful `user()`, or by a launch
    /// that fails (then the throttle is exactly what should apply).
    nonisolated static let sessionDroppedKey = "edSessionDroppedV1"
    /// A course's tabs change rarely (an instructor adds the Ed tool once),
    /// so one `/tabs` request per course per week is plenty.
    nonisolated private static let tabRecheckInterval: TimeInterval = 7 * 24 * 60 * 60

    private let launcher: EdSessionLauncher

    init(launcher: EdSessionLauncher = EdSessionLauncher()) {
        self.launcher = launcher
    }

    /// Runs one sync and applies the restore/drop rule below to `knowledge`.
    ///
    /// - Parameter priorEdDocuments: the `.ed` documents the knowledge base
    ///   held before this Canvas sync ran. `CourseKnowledgeCollector` drops
    ///   the `.ed` documents of every course it re-fetches (it has no idea
    ///   Ed exists), so by the time `knowledge` arrives here they may be
    ///   gone; this is where they come back or are deliberately left gone.
    ///
    /// **The restore/drop rule.** What happens to a course's *previous* Ed
    /// documents depends on what this run learned about that course:
    /// - **Read successfully:** replaced by the fresh set
    ///   (`mergeEdDocuments`); a thread deleted on Ed's side disappears.
    /// - **Authoritatively gone, so dropped:** a course that did not match
    ///   an Ed course after a *successful* `user()` and match (it dropped
    ///   its Ed tab, or Ed no longer lists it), and every course when no
    ///   course has an Ed tab and every tab check succeeded. Ed's side says
    ///   there is nothing there, so keeping the old threads would leave
    ///   stale answers in ask forever.
    /// - **Not read, so restored:** a matched course whose Ed read failed or
    ///   was skipped (launch failed, throttled, 401, a fetch error, the run
    ///   stopped by a mid-run 401), and every course when the run never got
    ///   as far as a match. An unknown is not an absence: a bad network day
    ///   must never erase material that was fine yesterday.
    func sync(
        courses: [CourseSummary],
        canvasCookies: [HTTPCookie],
        canvasBase: URL,
        knowledge: inout CourseKnowledgeBase,
        priorEdDocuments: [CourseDocument] = [],
        now: Date = Date()
    ) async -> Report {
        let result = await perform(
            courses: courses,
            canvasCookies: canvasCookies,
            canvasBase: canvasBase,
            knowledge: &knowledge,
            now: now
        )
        Self.droppingEdDocuments(from: &knowledge, courseIDs: result.drop)
        Self.restoringEdDocuments(priorEdDocuments, into: &knowledge, courseIDs: result.restore)
        return result.report
    }

    /// Forgets the launcher's 30-minute throttle (a Canvas disconnect starts
    /// a new account's history).
    func resetThrottle() {
        launcher.resetThrottle()
    }

    private struct SyncResult {
        var report: Report
        /// Course ids whose prior `.ed` documents are removed.
        var drop: Set<String>
        /// Course ids whose prior `.ed` documents come back if absent.
        var restore: Set<String>
    }

    private func perform(
        courses: [CourseSummary],
        canvasCookies: [HTTPCookie],
        canvasBase: URL,
        knowledge: inout CourseKnowledgeBase,
        now: Date
    ) async -> SyncResult {
        var report = Report(statusLine: "")
        let allIDs = Set(courses.map(\.courseID))
        /// Anything that stops the run before a match is an unknown, not an
        /// absence: restore everything.
        func unknown(_ report: Report) -> SyncResult {
            SyncResult(report: report, drop: [], restore: allIDs)
        }

        // 1. Find Ed tabs.
        let launchURLs = await findLaunchURLs(
            courses: courses,
            canvasCookies: canvasCookies,
            canvasBase: canvasBase,
            now: now,
            notes: &report.notes
        )
        guard let firstLaunchURL = courses.compactMap({ launchURLs[$0.courseID] }).first else {
            if report.notes.isEmpty {
                report.statusLine = "no classes use ed discussion"
                return SyncResult(report: report, drop: allIDs, restore: [])
            }
            report.statusLine = "ed discussion: \(report.notes[0])"
            return unknown(report)
        }

        // 2. Ed session. A stored session is reused until Ed says 401; only
        // an empty store pays for a launch. `force` is true only when the
        // store is empty because this coordinator removed a dead session
        // (`edSessionDroppedV1`): the 30-minute launch throttle is there to
        // stop a broken launch repeating, and must not also delay the one
        // launch that replaces a session Ed just ended. The stored session
        // is token-first (`EdSessionTokenStore`, Ed's localStorage
        // `authToken`), with the Ed cookies as the fallback.
        var edAuth = Self.authentication(token: EdSessionTokenStore.load(), cookies: SessionCookieStore.load(service: .ed))
        var sessionIsFromStore = edAuth != nil
        if edAuth == nil {
            let force = UserDefaults.lhf.bool(forKey: Self.sessionDroppedKey)
            guard let launched = await launchAndStore(url: firstLaunchURL, force: force, notes: &report.notes) else {
                // A forced launch has now run (or failed); the flag's job is
                // done either way, and the throttle governs what follows.
                UserDefaults.lhf.removeObject(forKey: Self.sessionDroppedKey)
                report.statusLine = "couldn't sign in to ed discussion"
                return unknown(report)
            }
            edAuth = launched
        }
        // Both branches above leave a session or return.
        guard var auth = edAuth else { return unknown(report) }

        // 3. Who am I. A 401 on a STORED session means it died: drop it,
        // launch once more past the throttle, and retry once. A 401 on
        // cookies launched seconds ago earns nothing: a second 40 s hidden
        // launch back to back would not change Ed's answer.
        let userResponse: EdUserResponse
        do {
            userResponse = try await EdClient(auth: auth).user()
        } catch EdClient.Error.sessionExpired {
            Self.dropStoredSession()
            guard sessionIsFromStore else {
                UserDefaults.lhf.removeObject(forKey: Self.sessionDroppedKey)
                report.notes.append("ed rejected a fresh launch session")
                report.statusLine = "couldn't sign in to ed discussion"
                return unknown(report)
            }
            guard let relaunched = await launchAndStore(url: firstLaunchURL, force: true, notes: &report.notes) else {
                UserDefaults.lhf.removeObject(forKey: Self.sessionDroppedKey)
                report.statusLine = "couldn't sign in to ed discussion"
                return unknown(report)
            }
            auth = relaunched
            sessionIsFromStore = false
            do {
                userResponse = try await EdClient(auth: auth).user()
            } catch {
                Self.dropStoredSession()
                UserDefaults.lhf.removeObject(forKey: Self.sessionDroppedKey)
                report.notes.append("ed rejected the new session: \(Self.describe(error))")
                report.statusLine = "couldn't sign in to ed discussion"
                return unknown(report)
            }
        } catch {
            report.notes.append("couldn't read ed account: \(Self.describe(error))")
            report.statusLine = "ed discussion: \(report.notes[0])"
            return unknown(report)
        }
        // The session works, so any "dropped" marker is spent.
        UserDefaults.lhf.removeObject(forKey: Self.sessionDroppedKey)

        // 4. Match. Canvas sites that share a code (PHYS 0151's lecture and
        // lab) collapse to one reference, because the matcher keys on code.
        var seenCodes = Set<String>()
        var refs: [CanvasCourseRef] = []
        for course in courses where seenCodes.insert(course.code).inserted {
            // The term comes from the Canvas descriptor ("… 202630 …"), the
            // same parse the rest of the app uses; a course whose name
            // carries none matches on code alone.
            refs.append(CanvasCourseRef(code: course.code, term: CourseCode.parse(course.name).term))
        }
        let matches = EdCourseMatcher.match(
            edCourses: userResponse.courses.map(\.course),
            canvasCourses: refs,
            edLinks: [:]
        )

        // 5 and 6. Fetch, convert, merge.
        let client = EdClient(auth: auth)
        var matchedTargetIDs = Set<String>()
        var readIDs = Set<String>()
        var signedOutMidRun = false
        for match in matches.sorted(by: { $0.canvasCourseCode < $1.canvasCourseCode }) {
            let sameCode = courses.filter { $0.code == match.canvasCourseCode }
            // One Canvas site gets the documents, never several: the same
            // Ed thread pooled under two Canvas course ids would be stored
            // twice server-side. Prefer a site that actually has the Ed tab
            // (a lab site without one should not collect the lecture's Q&A),
            // else the first.
            guard let target = sameCode.first(where: { launchURLs[$0.courseID] != nil }) ?? sameCode.first else {
                continue
            }
            matchedTargetIDs.insert(target.courseID)
            if sameCode.count > 1 {
                report.notes.append("\(match.canvasCourseCode): \(sameCode.count) canvas sites share this code; ed documents filed under the first")
            }
            let response: EdThreadsResponse
            do {
                response = try await client.threads(courseID: match.edCourseID)
            } catch EdClient.Error.sessionExpired {
                // Ed ended the session mid-run. Dropping it means the next
                // sync relaunches; retrying here would only repeat the 401.
                // The marker (set only for a session that came from the
                // store, never one launched this run) lets that next launch
                // bypass the throttle.
                Self.dropStoredSession()
                if sessionIsFromStore {
                    UserDefaults.lhf.set(true, forKey: Self.sessionDroppedKey)
                }
                report.notes.append("ed ended the session while reading \(match.canvasCourseCode)")
                signedOutMidRun = true
                break
            } catch {
                report.notes.append("couldn't read ed threads for \(match.canvasCourseCode): \(Self.describe(error))")
                continue
            }
            let documents = EdIngestion.documents(course: target, edCourseID: match.edCourseID, response: response, now: now)
            report.documentsAdded += Self.mergeEdDocuments(documents, into: &knowledge, course: target, now: now)
            report.matched.append((code: match.canvasCourseCode, edCourseID: match.edCourseID))
            readIDs.insert(target.courseID)
        }

        if matches.isEmpty {
            report.notes.append("no ed course matched your canvas classes")
        }

        // 7. Status.
        if signedOutMidRun {
            report.statusLine = "ed discussion signed out; reconnecting on the next sync"
        } else if report.matched.isEmpty {
            report.statusLine = "ed discussion: \(report.notes.first ?? "nothing to read")"
        } else {
            report.statusLine = "connected: " + report.matched.map { $0.code }.sorted().joined(separator: ", ")
        }
        // Matched-but-unread keeps its old documents; unmatched is gone.
        return SyncResult(
            report: report,
            drop: allIDs.subtracting(matchedTargetIDs),
            restore: matchedTargetIDs.subtracting(readIDs)
        )
    }

    // MARK: - Pure helpers (tested)

    /// Replaces `course`'s `.ed` documents with `edDocuments` and returns how
    /// many are new or changed.
    ///
    /// **Why the course's own documents are rebuilt instead of merging the
    /// Ed documents alone.** `CourseKnowledgeBase.merge` treats the documents
    /// it is given for each id in `resyncedCourseIDs` as that course's
    /// *complete* set: every stored document of a resynced course that is
    /// not in the new list is dropped (that is how a page deleted from
    /// Canvas disappears). Handing it only the `.ed` documents would delete
    /// the course's syllabus, pages and announcements. So the set passed is
    /// the course's existing non-Ed documents plus the new Ed ones. The
    /// non-Ed ones are unchanged by hash, so `merge` keeps their original
    /// `fetchedAt`; unchanged Ed threads keep theirs too. The wrong
    /// alternative, `resyncedCourseIDs: []`, would never drop an Ed thread
    /// that was deleted or aged past `maxAge`.
    ///
    /// `lastSyncedAt` is put back afterwards: it is the Canvas sync's clock
    /// (`courseKnowledgeIsStale`), and an Ed merge must not make a failed or
    /// partial Canvas sync look fresh.
    nonisolated static func mergeEdDocuments(
        _ edDocuments: [CourseDocument],
        into knowledge: inout CourseKnowledgeBase,
        course: CourseSummary,
        now: Date
    ) -> Int {
        let courseID = course.courseID
        var previousHashes: [String: String] = [:]
        var complete: [CourseDocument] = []
        for document in knowledge.documents where document.courseID == courseID {
            if document.kind == .ed {
                previousHashes[document.id] = document.contentHash
            } else {
                complete.append(document)
            }
        }
        complete.append(contentsOf: edDocuments)

        let lastSyncedAt = knowledge.lastSyncedAt
        knowledge.merge(courses: [], documents: complete, resyncedCourseIDs: [courseID], syncedAt: now)
        knowledge.lastSyncedAt = lastSyncedAt

        return edDocuments.filter { previousHashes[$0.id] != $0.contentHash }.count
    }

    /// Puts back the `.ed` documents a Canvas collector run dropped.
    ///
    /// `CourseKnowledgeCollector.run` merges each re-fetched course with
    /// itself as the complete set, and it knows nothing of Ed, so every
    /// course it re-fetches loses its Ed documents. Without this, a run in
    /// which Ed is unreachable (session expired, throttled launch, Ed down)
    /// would erase Ed material that was fine a minute ago, and then tell the
    /// backend those documents are gone (`fullySyncedCourses` lists the
    /// course's current ids). Only documents of `courseIDs` that are absent
    /// from `knowledge` are restored; a fresh Ed merge then replaces them
    /// for every course it reaches.
    nonisolated static func restoringEdDocuments(
        _ prior: [CourseDocument],
        into knowledge: inout CourseKnowledgeBase,
        courseIDs: Set<String>
    ) {
        let present = Set(knowledge.documents.map(\.id))
        let missing = prior.filter { $0.kind == .ed && courseIDs.contains($0.courseID) && !present.contains($0.id) }
        guard !missing.isEmpty else { return }
        let lastSyncedAt = knowledge.lastSyncedAt
        let everything = knowledge.documents + missing
        knowledge.merge(
            courses: [],
            documents: everything,
            resyncedCourseIDs: [],
            syncedAt: lastSyncedAt ?? Date()
        )
        knowledge.lastSyncedAt = lastSyncedAt
    }

    /// Drops both caches. Called when Canvas is disconnected: they describe
    /// that Canvas account's courses.
    nonisolated static func clearCaches() {
        UserDefaults.lhf.removeObject(forKey: launchURLKey)
        UserDefaults.lhf.removeObject(forKey: tabCheckedAtKey)
        UserDefaults.lhf.removeObject(forKey: sessionDroppedKey)
        // The Ed session token is a child of the Canvas login too. Doing it
        // here is what lets a Canvas disconnect delete it without
        // `AppState.disconnectCanvas` knowing the store exists. (That method
        // removes the Ed cookies itself with `SessionCookieStore.remove`.)
        EdSessionTokenStore.remove()
    }

    /// The `EdAuth` to use for a stored or freshly captured session, or nil
    /// when there is nothing: the token if there is a non-empty one, else the
    /// cookies if any, else nothing. Token-first because that is what Ed's
    /// web client actually uses (2026-10-09 probe); the cookie path stays as
    /// a fallback at no cost.
    nonisolated static func authentication(token: String?, cookies: [HTTPCookie]) -> EdAuth? {
        if let token, !token.isEmpty { return .token(token) }
        if !cookies.isEmpty { return .cookies(cookies) }
        return nil
    }

    /// Forgets the whole stored Ed session, token and cookies together. A
    /// 401 means Ed ended the session, and leaving either half behind would
    /// make the next sync reuse it (token-first, so a surviving token would
    /// shadow the relaunch's new cookies).
    nonisolated private static func dropStoredSession() {
        EdSessionTokenStore.remove()
        SessionCookieStore.remove(service: .ed)
    }

    /// Removes the `.ed` documents of `courseIDs`, leaving every other kind.
    /// The "authoritatively gone" half of the rule on `sync`.
    nonisolated static func droppingEdDocuments(from knowledge: inout CourseKnowledgeBase, courseIDs: Set<String>) {
        guard knowledge.documents.contains(where: { $0.kind == .ed && courseIDs.contains($0.courseID) }) else { return }
        let lastSyncedAt = knowledge.lastSyncedAt
        let remaining = knowledge.documents.filter { !($0.kind == .ed && courseIDs.contains($0.courseID)) }
        // `merge` only drops documents of `resyncedCourseIDs` that are
        // missing from the list given, and `remaining` holds every other
        // document of those courses, so only the Ed ones go.
        knowledge.merge(
            courses: [],
            documents: remaining,
            resyncedCourseIDs: courseIDs,
            syncedAt: lastSyncedAt ?? Date()
        )
        knowledge.lastSyncedAt = lastSyncedAt
    }

    // MARK: - Steps

    /// Step 1. Cached launch URLs for fresh courses; a `/tabs` request for
    /// the rest. A failed request leaves its course unchecked so the next
    /// run retries, and is reported once as a count, not once per course.
    private func findLaunchURLs(
        courses: [CourseSummary],
        canvasCookies: [HTTPCookie],
        canvasBase: URL,
        now: Date,
        notes: inout [String]
    ) async -> [String: URL] {
        var urlStrings = UserDefaults.lhf.dictionary(forKey: Self.launchURLKey) as? [String: String] ?? [:]
        var checkedAt = UserDefaults.lhf.dictionary(forKey: Self.tabCheckedAtKey) as? [String: Date] ?? [:]
        let client = CanvasCourseContentClient(baseURL: canvasBase, cookies: canvasCookies)

        var failures = 0
        var firstFailure: String?
        for course in courses {
            if let last = checkedAt[course.courseID], now.timeIntervalSince(last) < Self.tabRecheckInterval {
                continue
            }
            do {
                let tabs = try await client.tabs(courseID: course.courseID)
                if let tab = EdTabFinder.edTab(in: tabs),
                   let url = EdTabFinder.launchURL(for: tab, canvasBase: canvasBase) {
                    urlStrings[course.courseID] = url.absoluteString
                } else {
                    urlStrings.removeValue(forKey: course.courseID)
                }
                checkedAt[course.courseID] = now
            } catch {
                failures += 1
                if firstFailure == nil { firstFailure = Self.describe(error) }
            }
        }
        UserDefaults.lhf.set(urlStrings, forKey: Self.launchURLKey)
        UserDefaults.lhf.set(checkedAt, forKey: Self.tabCheckedAtKey)
        if failures > 0, let firstFailure {
            notes.append("couldn't read the tabs of \(failures) canvas course(s): \(firstFailure)")
        }
        return urlStrings.compactMapValues { URL(string: $0) }
    }

    /// Steps 2 and 3's launch: runs the launcher and saves what it captured
    /// (the token to `EdSessionTokenStore`, any Ed cookies to
    /// `SessionCookieStore.Service.ed`). `nil` (with a note) when no usable
    /// session came out. Never puts the token in a note.
    private func launchAndStore(url: URL, force: Bool, notes: inout [String]) async -> EdAuth? {
        switch await launcher.launch(url: url, force: force) {
        case let .landed(session, _):
            guard let auth = Self.authentication(token: session.token, cookies: session.cookies) else {
                notes.append("ed launch returned no session")
                return nil
            }
            if let token = session.token, !token.isEmpty {
                EdSessionTokenStore.save(token)
            }
            SessionCookieStore.save(session.cookies, service: .ed)
            return auth
        case let .noEdSession(finalPage):
            notes.append("ed launch ended without a session at \(finalPage)")
        case let .timedOut(finalPage):
            notes.append("ed launch timed out at \(finalPage)")
        case .throttled:
            notes.append("ed launch skipped (one ran recently)")
        case .noCanvasSession:
            notes.append("no canvas session to launch ed with")
        }
        return nil
    }

    /// An error as a short phrase. `EdClient.Error.invalidJSON` carries a
    /// string of unknown content, so its payload is deliberately not printed
    /// (it must never be the way a thread body reaches a log).
    nonisolated private static func describe(_ error: Error) -> String {
        if let edError = error as? EdClient.Error {
            switch edError {
            case .sessionExpired: return "session expired"
            case let .http(status): return "http \(status)"
            case .notHTTP: return "not an http response"
            case .invalidJSON: return "unreadable response"
            }
        }
        return error.localizedDescription
    }
}
