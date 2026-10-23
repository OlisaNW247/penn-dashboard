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
        /// What the line below says in numbers (2026-10-23), so a test or a
        /// caller need not parse it. Classes here are Canvas courses:
        /// `matched` found an Ed course, `read` were read this run,
        /// `restored` kept their stored Ed documents because they were not
        /// read, `dropped` had their stored Ed documents removed because Ed
        /// authoritatively has nothing for them.
        var matchedClasses = 0
        var readClasses = 0
        var restoredClasses = 0
        var droppedClasses = 0
        /// The first failure's kind, a fixed word and never a message:
        /// `noTab`, `tabCheck`, `launch`, `noMatch`, `sessionExpired`,
        /// `http(code)`, `notHTTP`, `invalidJSON` or `other`.
        var firstFailure: String?
        /// "matched 3 · read 1 · restored 2 · dropped 0 · first failure
        /// sessionExpired · <detail>". The counts lead so that
        /// `AppState.scrubbedForSummary`'s 120-character cap cuts the detail
        /// and never the numbers.
        var statusLine: String
    }

    /// One Canvas class to read from Ed: the Ed course it matched, and the
    /// single Canvas site the documents are filed under.
    struct ReadTarget: Sendable, Equatable {
        let edCourseID: Int
        let code: String
        let course: CourseSummary
    }

    /// What `readTargets` did. Notes are code-and-count sentences only.
    struct ReadTally: Sendable {
        var readIDs = Set<String>()
        var read: [(code: String, edCourseID: Int)] = []
        var documentsAdded = 0
        var notes: [String] = []
        var firstFailure: String?
        /// The class whose read Ed answered with a 401; the run stopped there.
        var signedOutCode: String?
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
    ///   held before this Canvas sync ran. `CourseKnowledgeCollector` keeps
    ///   the `.ed` documents of every course it re-fetches (since 2026-10-23;
    ///   before that it dropped them, having no idea Ed exists, and saved the
    ///   result), so `knowledge` normally arrives here still holding them.
    ///   This is the belt to that brace: a document absent from `knowledge`
    ///   (a store written by an older build, a pooled download applied since)
    ///   comes back if its class is restored, and a class is dropped only on
    ///   the evidence below.
    ///
    /// **The restore/drop rule.** What happens to a course's *previous* Ed
    /// documents depends on what this run learned about that course:
    /// - **Read successfully:** replaced by the fresh set
    ///   (`mergeEdDocuments`); a thread deleted on Ed's side disappears.
    /// - **Authoritatively gone, so dropped:** a course that did not match
    ///   an Ed course after a *successful* `user()` and match (it dropped
    ///   its Ed tab, or Ed no longer lists it) **and nothing about that
    ///   course failed this run**, and every course when no course has an Ed
    ///   tab and every tab check succeeded. Ed's side says there is nothing
    ///   there, so keeping the old threads would leave stale answers in ask
    ///   forever.
    /// - **Not read, so restored:** a matched course whose Ed read failed or
    ///   was skipped (launch failed, throttled, 401, a fetch error, the run
    ///   stopped by a mid-run 401, which also covers every matched course the
    ///   run had not reached yet), a course whose own Canvas `/tabs` lookup
    ///   failed this run (whatever the match said: the one request that
    ///   would have told us whether the class has Ed went unanswered), and
    ///   every course when the run never got as far as a match. An unknown
    ///   is not an absence: a bad network day must never erase material
    ///   that was fine yesterday.
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
        func unknown(_ report: Report, failure: String) -> SyncResult {
            Self.finished(report, drop: [], restore: allIDs, matched: 0, read: 0, failure: failure)
        }

        // 1. Find Ed tabs.
        let tabs = await findLaunchURLs(
            courses: courses,
            canvasCookies: canvasCookies,
            canvasBase: canvasBase,
            now: now,
            notes: &report.notes
        )
        let launchURLs = tabs.urls
        guard let firstLaunchURL = courses.compactMap({ launchURLs[$0.courseID] }).first else {
            if tabs.failedCourseIDs.isEmpty {
                report.statusLine = "no classes use ed discussion"
                return Self.finished(report, drop: allIDs, restore: [], matched: 0, read: 0, failure: "noTab")
            }
            // Tab checks failed (Canvas unreachable, say): nobody knows
            // whether a class has Ed, so nothing is dropped.
            report.statusLine = report.notes[0]
            return unknown(report, failure: "tabCheck")
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
                return unknown(report, failure: "launch")
            }
            edAuth = launched
        }
        // Both branches above leave a session or return.
        guard var auth = edAuth else { return unknown(report, failure: "launch") }

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
                return unknown(report, failure: "sessionExpired")
            }
            guard let relaunched = await launchAndStore(url: firstLaunchURL, force: true, notes: &report.notes) else {
                UserDefaults.lhf.removeObject(forKey: Self.sessionDroppedKey)
                report.statusLine = "couldn't sign in to ed discussion"
                return unknown(report, failure: "launch")
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
                return unknown(report, failure: Self.failureKind(error))
            }
        } catch {
            report.notes.append("couldn't read ed account: \(Self.describe(error))")
            report.statusLine = report.notes[0]
            return unknown(report, failure: Self.failureKind(error))
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

        // 5. Resolve every match to its Canvas site BEFORE reading any. This
        // is what makes a mid-run sign-out safe: the matched set is the
        // whole list, not "the classes the loop reached", so a class the
        // run never got to is "matched, not read" and is restored below.
        // (Until 2026-10-23 the set was filled as the loop went, a 401 broke
        // out of it, and every class after the break fell into `drop`, which
        // deletes its stored Ed documents: a sign-out on the second of six
        // classes erased the other four classes' posts.)
        var targets: [ReadTarget] = []
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
            if sameCode.count > 1 {
                report.notes.append("\(match.canvasCourseCode): \(sameCode.count) canvas sites share this code; ed documents filed under the first")
            }
            targets.append(ReadTarget(edCourseID: match.edCourseID, code: match.canvasCourseCode, course: target))
        }
        let matchedTargetIDs = Set(targets.map { $0.course.courseID })

        // 6. Fetch, convert, merge.
        let client = EdClient(auth: auth)
        let tally = await Self.readTargets(targets, knowledge: &knowledge, now: now) { edCourseID in
            try await client.threadsWithinWindow(courseID: edCourseID, now: now)
        }
        report.notes.append(contentsOf: tally.notes)
        report.documentsAdded += tally.documentsAdded
        report.matched = tally.read
        var firstFailure = tally.firstFailure
        if tally.signedOutCode != nil {
            // Ed ended the session mid-run. Dropping it means the next
            // sync relaunches; retrying here would only repeat the 401.
            // The marker (set only for a session that came from the
            // store, never one launched this run) lets that next launch
            // bypass the throttle.
            Self.dropStoredSession()
            if sessionIsFromStore {
                UserDefaults.lhf.set(true, forKey: Self.sessionDroppedKey)
            }
        }

        if matches.isEmpty {
            report.notes.append("no ed course matched your canvas classes")
            if firstFailure == nil { firstFailure = "noMatch" }
        }

        // 7. Status.
        if tally.signedOutCode != nil {
            report.statusLine = "signed out; reconnecting next sync"
        } else if report.matched.isEmpty {
            report.statusLine = report.notes.first ?? "nothing to read"
        } else {
            report.statusLine = "connected: " + report.matched.map { $0.code }.sorted().joined(separator: ", ")
        }
        // A class whose `/tabs` request failed is unknown, matched or not:
        // see `restoreDropPlan`. It reaches this point only because another
        // class's cached launch URL let the run go on.
        let plan = Self.restoreDropPlan(
            allIDs: allIDs,
            matched: matchedTargetIDs,
            read: tally.readIDs,
            unknown: tabs.failedCourseIDs
        )
        return Self.finished(
            report,
            drop: plan.drop,
            restore: plan.restore,
            matched: matchedTargetIDs.count,
            read: tally.readIDs.count,
            failure: firstFailure
        )
    }

    /// Reads each target in order, merging what it reads into `knowledge`.
    /// The seam the sign-out tests drive: `read` stands for the network.
    ///
    /// - A class whose read throws `EdClient.Error.sessionExpired` ends the
    ///   run: it and every class after it stay unread (the caller restores
    ///   their stored documents), the classes before it keep what they
    ///   replaced, and `signedOutCode` names the class. The caller does the
    ///   session clean-up; this function touches no store or defaults.
    /// - Any other error is a note and the run goes on to the next class.
    nonisolated static func readTargets(
        _ targets: [ReadTarget],
        knowledge: inout CourseKnowledgeBase,
        now: Date,
        read: @Sendable (Int) async throws -> EdThreadsResponse
    ) async -> ReadTally {
        var tally = ReadTally()
        for target in targets {
            let response: EdThreadsResponse
            do {
                response = try await read(target.edCourseID)
            } catch EdClient.Error.sessionExpired {
                tally.notes.append("ed ended the session while reading \(target.code)")
                if tally.firstFailure == nil { tally.firstFailure = "sessionExpired" }
                tally.signedOutCode = target.code
                break
            } catch {
                tally.notes.append("couldn't read ed threads for \(target.code): \(describe(error))")
                if tally.firstFailure == nil { tally.firstFailure = failureKind(error) }
                continue
            }
            let documents = EdIngestion.documents(course: target.course, edCourseID: target.edCourseID, response: response, now: now)
            tally.documentsAdded += mergeEdDocuments(documents, into: &knowledge, course: target.course, now: now)
            tally.read.append((code: target.code, edCourseID: target.edCourseID))
            tally.readIDs.insert(target.course.courseID)
        }
        return tally
    }

    /// The restore/drop rule on `sync`, as sets. Matched-but-unread keeps its
    /// old documents (`restore`, which is every matched class the run did not
    /// read: a failed read, and every class a mid-run 401 stopped before);
    /// a class with no Ed match is authoritatively gone (`drop`), unless
    /// something about that class failed this run. The two never overlap, and
    /// neither holds a class that was read.
    ///
    /// - Parameter unknown: classes whose own state could not be established
    ///   this run, today those whose Canvas `/tabs` lookup failed. They are
    ///   restored unless read, and never dropped, even with no Ed match:
    ///   "no match" is only evidence of absence when nothing about the class
    ///   went wrong, and a flaky request on one class (while another class's
    ///   cached launch URL let the run go on) said nothing about whether it
    ///   has Ed. Before 2026-10-23 this input did not exist, so such a class
    ///   fell into `allIDs - matched` like a class Ed had really dropped and
    ///   its stored posts were deleted for the run. The wrong fix is to treat
    ///   every unmatched class as unknown, which would keep a class's posts
    ///   forever after it drops Ed; the rule is that a drop needs a clean
    ///   run for that class. Defaults to empty so the pure rule can still be
    ///   asked "what if nothing failed".
    nonisolated static func restoreDropPlan(
        allIDs: Set<String>,
        matched: Set<String>,
        read: Set<String>,
        unknown: Set<String> = []
    ) -> (drop: Set<String>, restore: Set<String>) {
        (
            drop: allIDs.subtracting(matched).subtracting(unknown),
            restore: matched.union(unknown.intersection(allIDs)).subtracting(read)
        )
    }

    /// Stamps the counts onto the report's status line and packages the
    /// restore/drop decision.
    private static func finished(
        _ report: Report,
        drop: Set<String>,
        restore: Set<String>,
        matched: Int,
        read: Int,
        failure: String?
    ) -> SyncResult {
        var report = report
        report.matchedClasses = matched
        report.readClasses = read
        report.restoredClasses = restore.count
        report.droppedClasses = drop.count
        report.firstFailure = failure
        report.statusLine = statusLine(
            matched: matched, read: read, restored: restore.count, dropped: drop.count,
            firstFailure: failure, detail: report.statusLine
        )
        return SyncResult(report: report, drop: drop, restore: restore)
    }

    /// "matched 3 · read 1 · restored 2 · dropped 0 · first failure
    /// sessionExpired · <detail>". Counts and fixed words only; the detail is
    /// the coordinator's own short phrase or a list of class codes.
    nonisolated static func statusLine(
        matched: Int,
        read: Int,
        restored: Int,
        dropped: Int,
        firstFailure: String?,
        detail: String
    ) -> String {
        var parts = ["matched \(matched)", "read \(read)", "restored \(restored)", "dropped \(dropped)"]
        if let firstFailure { parts.append("first failure \(firstFailure)") }
        if !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// An error as one fixed word, for the status line. Never a message: an
    /// `invalidJSON` payload could hold a thread body.
    nonisolated static func failureKind(_ error: Error) -> String {
        guard let edError = error as? EdClient.Error else { return "other" }
        switch edError {
        case .sessionExpired: return "sessionExpired"
        case let .http(status): return "http(\(status))"
        case .notHTTP: return "notHTTP"
        case .invalidJSON: return "invalidJSON"
        }
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

    /// Puts back `.ed` documents that are absent from `knowledge`.
    ///
    /// `CourseKnowledgeCollector.run` used to merge each re-fetched course
    /// with itself as the complete set, and it knows nothing of Ed, so every
    /// course it re-fetched lost its Ed documents; this was the only thing
    /// that brought them back, and only in memory. The collector now keeps
    /// them (`preservingKinds: [.ed]`), so this is normally a no-op. It stays
    /// as the guard for a document that is missing anyway, so that a run in
    /// which Ed is unreachable (session expired, throttled launch, Ed down)
    /// cannot erase Ed material that was fine a minute ago and then tell the
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

    /// What step 1 learned: the launch URLs, and which courses it could not
    /// check at all.
    private struct TabLookup {
        var urls: [String: URL]
        /// Courses whose `/tabs` request failed this run (and whose cached
        /// answer, if any, was too old to trust). Whether they have Ed is
        /// unknown, so the restore/drop rule never drops them
        /// (`restoreDropPlan`).
        var failedCourseIDs: Set<String>
    }

    /// Step 1. Cached launch URLs for fresh courses; a `/tabs` request for
    /// the rest. A failed request leaves its course unchecked so the next
    /// run retries, is reported once as a count, not once per course, and is
    /// returned by id so the run can treat that class as unknown rather than
    /// as one with no Ed.
    private func findLaunchURLs(
        courses: [CourseSummary],
        canvasCookies: [HTTPCookie],
        canvasBase: URL,
        now: Date,
        notes: inout [String]
    ) async -> TabLookup {
        var urlStrings = UserDefaults.lhf.dictionary(forKey: Self.launchURLKey) as? [String: String] ?? [:]
        var checkedAt = UserDefaults.lhf.dictionary(forKey: Self.tabCheckedAtKey) as? [String: Date] ?? [:]
        let client = CanvasCourseContentClient(baseURL: canvasBase, cookies: canvasCookies)

        var failedCourseIDs = Set<String>()
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
                failedCourseIDs.insert(course.courseID)
                if firstFailure == nil { firstFailure = Self.describe(error) }
            }
        }
        UserDefaults.lhf.set(urlStrings, forKey: Self.launchURLKey)
        UserDefaults.lhf.set(checkedAt, forKey: Self.tabCheckedAtKey)
        if !failedCourseIDs.isEmpty, let firstFailure {
            notes.append("couldn't read the tabs of \(failedCourseIDs.count) canvas course(s): \(firstFailure)")
        }
        return TabLookup(urls: urlStrings.compactMapValues { URL(string: $0) }, failedCourseIDs: failedCourseIDs)
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
