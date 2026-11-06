import Foundation
import LowHangingFruitKit

// MARK: – Facts from the server, applied to the dashboard
//
// The server reads pooled course posts and serves back *facts* ("the quiz is
// cancelled", "the deadline moved to Nov 8", "a new task"). `AppliedFactStore`
// holds them and `FactApplication` decides what each may change. This file is
// the only place those decisions touch the app's state, and it is bound by
// "nothing the student did is ever lost" (CLAUDE.md, "The ledger is the
// point"):
//
//  - a fact never completes or deletes anything. A cancel HIDES the card from
//    todo and tags it (`FactItemDisplay.cancelled`); it stays in all, and the
//    ledger row and its completion are untouched.
//  - a reschedule is substituted into the dashboard pool's copy of the row
//    (`applyingFactReschedules`), never written onto the ledger row, for the
//    reason `applyingStructuredDueOverride` gives: the feed rewrites `dueAt` on
//    every sync. The student's own edit wins twice over: the engine stands a
//    fact down when an edit exists, and `effectiveDueDate` reads the edit first.
//  - a new task is the one thing written to the ledger: a `.canvasAnnouncement`
//    row with a `fact-` sourceID, through the same `upsert` the announcement
//    watcher uses, and only when the row is absent or changed. A rejected or
//    withdrawn fact's row is HIDDEN here (`factHiddenRowIDs`), never deleted.
//  - `undo` is `FactOverride.rejected` on the fact: it stays on the fact, so a
//    newer fact does not resurrect it.
//
// The whole path is behind `FeatureFlags.appliedFacts` and nothing in it can
// fail a sync.

// MARK: Display types

/// What one dashboard row shows because of facts. Pure data, so the card needs
/// no reference to `AppState`.
struct FactItemDisplay: Equatable {
    /// One line of the instructor's own words behind an effect.
    struct Detail: Equatable, Identifiable {
        let factID: String
        /// `cancelled`, `moved` or `changed`.
        let word: String
        /// The quote, collapsed to one line and truncated.
        let text: String
        /// The post it came from, when known.
        let postURL: URL?
        var id: String { factID }
    }

    var cancelled = false
    var moved = false
    /// The date Canvas still says, for the struck-through line. Nil when the
    /// source's own date is not known.
    var movedFrom: Date?
    /// The date a reschedule moved the row to: what the card shows, and what
    /// the tree's work list reads (`applyingTreeOverrides`), so both take the
    /// engine's verdict from this one stored result.
    var movedTo: Date?
    var changed = false
    var details: [Detail] = []
    /// Every fact applied to this row; what `undo` rejects.
    var factIDs: [String] = []

    /// The caveat words, in the order they read best.
    var caveatWords: [String] {
        var words: [String] = []
        if cancelled { words.append("cancelled") }
        if moved { words.append("moved") }
        if changed { words.append("changed") }
        return words
    }
}

/// One applied (or undone) fact, as the megaphone lists it.
struct FactChangeRow: Identifiable, Equatable {
    /// The fact id.
    let id: String
    /// One word: `cancelled`, `moved`, `changed`, `new`, or `undone`.
    let word: String
    let postedAt: Date?
    let url: URL?
}

/// The facts that changed one item, for the megaphone's first group.
struct FactChangeGroup: Identifiable, Equatable {
    /// The item's `Assignment.id` (or, for an undone fact, the fact id).
    let id: String
    let courseCode: String
    let title: String
    var rows: [FactChangeRow]
    /// An undone fact: listed as a plain, dimmed row.
    var isUndone = false

    var url: URL? { rows.compactMap(\.url).first }
    var postedAt: Date? { rows.compactMap(\.postedAt).max() }

    /// The fact ids the row's `undo` takes back, in row order. Empty for an
    /// undone group and for any row already marked `undone`: those are a
    /// record of what the student rejected, not a change still standing, so
    /// offering `undo` on them would reject a fact twice for no effect.
    var undoableFactIDs: [String] {
        guard !isUndone else { return [] }
        return rows.filter { $0.word != "undone" }.map(\.id)
    }
}

/// A fact the engine would not apply on its own, for the "needs a look" group.
struct FactReviewRow: Identifiable, Equatable {
    let id: String
    let courseCode: String
    let quote: String
    let url: URL?
    let postedAt: Date?
}

/// The result of one evaluation that the dashboard pool needs.
struct FactPass {
    /// Ledger id to the date a reschedule moved it to.
    var reschedules: [String: Date] = [:]
    /// New-task rows were written to the ledger, so the caller must re-read
    /// the announcement rows and rebuild once more.
    var wroteRows = false
}

extension AppState {
    enum FactKey {
        /// `UserDefaults.lhf`, per the preferences rule.
        static let cursor = "factsCursorV1"
        /// The Canvas course ids `factsCursorV1` was earned for. The server
        /// filters facts by the courses in the request, so a cursor is only
        /// meaningful for the courses that were asked about when it advanced.
        static let cursorCourses = "factsCursorCoursesV1"
    }

    /// Ledger `sourceID` prefix of a task a fact created
    /// (`FactApplication.taskSourceID`).
    nonisolated static let factRowPrefix = "fact-"

    nonisolated static func isFactRow(_ item: Assignment) -> Bool {
        item.source == .canvasAnnouncement && item.sourceID.hasPrefix(factRowPrefix)
    }

    // MARK: Words and text

    /// The class label a fact row shows: the student's rename, else the code,
    /// else "Misc" (as `AnnouncementRecord.displayCourse` does).
    nonisolated static func factCourseLabel(_ code: String, overrides: [String: String]) -> String {
        if let custom = overrides[code]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Misc" : trimmed
    }

    nonisolated static let factQuoteLimit = 120

    /// A quote as one line: whitespace collapsed, cut at `limit` characters.
    nonisolated static func oneLineQuote(_ text: String, limit: Int = factQuoteLimit) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// Only an https URL with a host is offered as a link.
    nonisolated static func safeFactURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    // MARK: Sync

    /// The manifest request, carrying the facts cursor. `factsSince` is the
    /// last cursor the server gave, or absent (everything) when there is none.
    /// A store that is only in memory never trusts a persisted cursor: after a
    /// relaunch it holds nothing, and skipping ahead would lose those facts.
    func makeSyncManifestRequest(courses: [CourseSummary], documents: [CourseDocument]) -> SyncManifestRequest {
        SyncManifestRequest(
            courses: courses.map { CourseSummaryWire(summary: $0) },
            documents: documents.map(DocumentStub.init(document:)),
            factsSince: factsSinceForRequest(courseIDs: Set(courses.map(\.courseID)))
        )
    }

    /// `courseIDs`, when given, are the courses this request asks about. The
    /// server only serves facts for those, and the cursor is one number for
    /// all of them, so a class added mid-term (its facts have seqs below the
    /// cursor, earned while the class was not being asked about) would never
    /// receive them. When the request names a course the cursor was not
    /// earned for, `0` goes out for this call: facts are idempotent by id, so
    /// re-reading the others is safe, and `receiveManifestFacts` then records
    /// the new set with the returned cursor. No cursor yet, or no recorded set
    /// (a phone from before this was recorded), reads the same way once.
    /// The wrong fix is a per-course cursor, which needs the protocol to
    /// carry one.
    func factsSinceForRequest(courseIDs: Set<String>? = nil) -> Int? {
        guard FeatureFlags.appliedFacts, let store = appliedFactStore, let defaults = factsDefaults else { return nil }
        guard let cursor = defaults.object(forKey: FactKey.cursor) as? Int, cursor > 0 else { return nil }
        if !store.isPersistent && !SharedDefaults.isTestRunner { return nil }
        if let courseIDs, !courseIDs.isEmpty {
            let earned = Set(defaults.stringArray(forKey: FactKey.cursorCourses) ?? [])
            if !courseIDs.isSubset(of: earned) { return 0 }
        }
        return cursor
    }

    /// Stores what a manifest (or a test) delivered, advances the cursor only
    /// if the save landed, and returns how many facts were new. Never throws.
    @discardableResult
    func ingestFacts(_ wires: [CourseFactWire], cursor: Int?, now: Date = Date()) -> Int {
        ingestFactsReporting(wires, cursor: cursor, now: now).added
    }

    /// `ingestFacts`, also saying whether every delivered fact is held and
    /// nothing failed, which is the condition for trusting that the cursor now
    /// covers the courses the request named.
    func ingestFactsReporting(_ wires: [CourseFactWire], cursor: Int?, now: Date = Date()) -> (added: Int, complete: Bool) {
        guard FeatureFlags.appliedFacts, let store = appliedFactStore else { return (0, false) }
        let failedSavesBefore = store.failedSaveCount
        let failedReadsBefore = store.failedReadCount
        let added = store.upsert(facts: wires, now: now)
        if added > 0 { appliedFactsCache = nil }
        // The cursor moves only past rows that are on disk. `upsert` stores
        // nothing and returns 0 when its read fails (counted in
        // `failedReadCount`), and a failed save is counted in
        // `failedSaveCount`; advancing on either would skip those facts for
        // good. The presence check is the belt to those braces.
        let mayAdvance = Self.mayAdvanceFactsCursor(
            savesFailed: store.failedSaveCount - failedSavesBefore,
            readsFailed: store.failedReadCount - failedReadsBefore,
            wires: wires,
            stored: Set(store.all().map(\.id))
        )
        if mayAdvance, let defaults = factsDefaults {
            // Never backwards, never past 2^53: a nil cursor contributes nothing,
            // and a value outside the range the server can send is ignored.
            let valid = (cursor ?? 0) <= CourseFactWire.maxSeq ? (cursor ?? 0) : 0
            let observed = max(valid, wires.map(\.seq).filter { $0 <= CourseFactWire.maxSeq }.max() ?? 0)
            let current = defaults.object(forKey: FactKey.cursor) as? Int ?? 0
            if observed > current, observed <= CourseFactWire.maxSeq { defaults.set(observed, forKey: FactKey.cursor) }
        }
        return (added, mayAdvance)
    }

    /// Pure half of the cursor rule: no failed read or save during the upsert,
    /// and every delivered fact is now held.
    nonisolated static func mayAdvanceFactsCursor(
        savesFailed: Int, readsFailed: Int, wires: [CourseFactWire], stored: Set<String>
    ) -> Bool {
        guard savesFailed == 0, readsFailed == 0 else { return false }
        return wires.allSatisfy { stored.contains(AppliedFact.factID(documentID: $0.documentID, seq: $0.seq)) }
    }

    /// Drops facts of a document revision the phone has since replaced: the
    /// local copy has a different hash and was fetched after the fact arrived
    /// (`removeFacts`). Returns how many.
    @discardableResult
    func pruneStaleFacts() -> Int {
        guard FeatureFlags.appliedFacts, let store = appliedFactStore else { return 0 }
        let documentByID = Dictionary(
            courseKnowledge.documents.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen: Set<String> = []
        var removed = 0
        for fact in store.all() {
            // Stale only when the phone's copy is a DIFFERENT revision AND the
            // newer one: fetched after this fact arrived. A fact that arrives
            // for a new revision while the local document is still the old one
            // (a download that failed or was capped) is kept for the next
            // sync, and the cursor has already moved past it, so deleting it
            // would lose it for good.
            guard let local = documentByID[fact.documentID], local.contentHash != fact.contentHash,
                  local.fetchedAt > fact.receivedAt,
                  seen.insert("\(fact.documentID)|\(fact.contentHash)").inserted else { continue }
            removed += store.removeFacts(documentID: fact.documentID, contentHash: fact.contentHash)
        }
        if removed > 0 { appliedFactsCache = nil }
        return removed
    }

    /// Ends the effect of facts whose document the server no longer lists.
    /// `pruneStaleFacts` only notices an EDITED post (the local copy has a
    /// different hash); a deleted or withdrawn post leaves no local copy to
    /// compare, so its cancel stayed on the card forever. The manifest's
    /// `serverManifest` is every live document for the courses asked about,
    /// so a stored fact of one of those courses whose document is absent is
    /// withdrawn. Narrow on purpose:
    ///  - only courses in the request (the list says nothing about others),
    ///  - never on an empty list (a server that returned nothing at all is
    ///    more likely failing than withdrawing every post, and the wrong
    ///    guess would lift every cancel),
    ///  - never for a document kind this phone did not ask the server to list
    ///    (`file` rows are withheld from `serverManifest` by design),
    ///  - the student's rejections are kept (`AppliedFactStore.removeFacts`).
    nonisolated static let withdrawalAgeLimit: TimeInterval = 100 * 86_400

    @discardableResult
    func pruneWithdrawnFacts(serverManifest: [DocumentStub], requestedCourseIDs: Set<String>, now: Date = Date()) -> Int {
        guard FeatureFlags.appliedFacts, let store = appliedFactStore,
              !serverManifest.isEmpty, !requestedCourseIDs.isEmpty else { return 0 }
        let live = Set(serverManifest.map(\.id))
        let localKind = Dictionary(courseKnowledge.documents.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        var removed = 0
        var seen: Set<String> = []
        for fact in store.all() {
            // The server stops serving window-kind documents (announcement,
            // ed) after 120 days, so their absence from `serverManifest` is
            // not a withdrawal once the post is old: a cancel from an August
            // announcement for a late-November date is still valid. 100 days
            // keeps a margin inside the server's 120. Old facts age out by
            // supersession or the student's undo only.
            let age = (fact.postedAt ?? fact.receivedAt)
            guard now.timeIntervalSince(age) < Self.withdrawalAgeLimit else { continue }
            guard requestedCourseIDs.contains(fact.courseID), !live.contains(fact.documentID),
                  localKind[fact.documentID] != .file,
                  seen.insert(fact.documentID).inserted else { continue }
            removed += store.removeFacts(documentID: fact.documentID)
        }
        if removed > 0 { appliedFactsCache = nil }
        return removed
    }

    /// The sync's whole facts step: store, advance, prune, and rebuild if
    /// anything changed. Called with the manifest response, after its
    /// documents are folded into the knowledge base.
    ///
    /// `requestedCourseIDs` is the course set the manifest request carried,
    /// and is nil when the manifest FAILED (the caller then hands in an empty
    /// response): a failed exchange proves nothing, so it neither withdraws
    /// facts nor records which courses the cursor covers.
    func receiveManifestFacts(_ manifest: SyncManifestResponse, now: Date = Date(), requestedCourseIDs: Set<String>? = nil) {
        guard FeatureFlags.appliedFacts, appliedFactStore != nil else { return }
        // Read before the ingest, which advances it.
        let storedCursor = factsDefaults?.object(forKey: FactKey.cursor) as? Int ?? 0
        let ingest = ingestFactsReporting(manifest.facts, cursor: manifest.factsCursor, now: now)
        var removed = pruneStaleFacts()
        if let requested = requestedCourseIDs {
            removed += pruneWithdrawnFacts(serverManifest: manifest.serverManifest, requestedCourseIDs: requested, now: now)
            // The new course set is trusted only when the answer's cursor is at
            // least the one already stored. A degraded facts read (the server
            // swallows a facts error and answers 200 with `factsCursor =
            // factsSince`, which is 0 for a re-read) or a re-read capped at
            // 1000 rows comes back BELOW it; recording the set then would mark
            // the new class covered although its earlier facts never arrived.
            // Left unrecorded, the next request re-reads from 0 again.
            if ingest.complete, let returned = manifest.factsCursor, returned >= storedCursor, let defaults = factsDefaults {
                defaults.set(requested.sorted(), forKey: FactKey.cursorCourses)
            }
        }
        if ingest.added > 0 || removed > 0 { rebuildDashboardItems(now: now) }
    }

    /// Canvas disconnect: facts are derived from course material, so they go
    /// with it, and the cursor with them (a reconnect re-reads from the start).
    func clearAppliedFacts() {
        appliedFactsCache = nil
        factsLastEffects = nil
        factDisplay = [:]
        factHiddenRowIDs = []
        factChangeGroups = []
        factReviewRows = []
        factsDefaults?.removeObject(forKey: FactKey.cursor)
        factsDefaults?.removeObject(forKey: FactKey.cursorCourses)
        guard let store = appliedFactStore else { return }
        store.purge(courseIDs: Set(store.all().map(\.courseID)))
    }

    // MARK: Undo

    /// The student says a fact is wrong. It stays on the fact (not the item),
    /// so a newer fact cannot resurrect it. A cancel comes back to todo; a
    /// new task's row is hidden, not deleted.
    func rejectFact(factID: String, now: Date = Date()) {
        guard let store = appliedFactStore,
              store.setOverride(factID: factID, to: .rejected, now: now) else { return }
        appliedFactsCache = nil
        rebuildDashboardItems(now: now)
    }

    /// Every fact behind a card, rejected together by its one `undo`.
    func rejectFacts(_ factIDs: [String], now: Date = Date()) {
        guard let store = appliedFactStore else { return }
        var any = false
        for id in factIDs where store.setOverride(factID: id, to: .rejected, now: now) { any = true }
        guard any else { return }
        appliedFactsCache = nil
        rebuildDashboardItems(now: now)
    }

    // MARK: Read

    func currentAppliedFacts() -> [AppliedFact] {
        if let cached = appliedFactsCache { return cached }
        let loaded = appliedFactStore?.all() ?? []
        appliedFactsCache = loaded
        return loaded
    }

    /// True while a fact has cancelled the row: off todo, off reminders, off
    /// the widget.
    func isFactCancelled(_ assignment: Assignment) -> Bool {
        factDisplay[assignment.id]?.cancelled == true
    }

    /// The pool's copy of a Canvas row with a reschedule's date. Identity
    /// (`id`) is unchanged.
    nonisolated static func applyingFactReschedule(_ item: Assignment, to due: Date) -> Assignment {
        guard due != item.dueAt else { return item }
        return Assignment(
            source: item.source, sourceID: item.sourceID, kind: item.kind, course: item.course,
            title: item.title, dueAt: due, url: item.url, term: item.term, submitted: item.submitted,
            scoreEarned: item.scoreEarned, scoreMax: item.scoreMax, linkedID: item.linkedID
        )
    }

    /// The Canvas-side dates the dashboard pool shows, for the tree's work
    /// list (the server context document and the on-device answerer): the
    /// section `all_dates` override first, then an applied fact's reschedule,
    /// the order `rebuildDashboardItems` applies them in. It reads the stored
    /// results of that rebuild (`structuredDueOverrides`, `factDisplay`) and
    /// re-derives nothing, so a rejected fact or a hand-edited date (which
    /// stood the engine down) is already absent from `factDisplay`. The
    /// student's own edit is NOT applied here: the server document keeps the
    /// feed date on purpose (docs/PRIVACY.md), and the on-device pool carries
    /// the edit separately as `dueOverride`.
    func applyingTreeOverrides(_ item: Assignment) -> Assignment {
        let sectionDated = applyingStructuredDueOverride(item)
        guard let moved = factDisplay[item.id]?.movedTo else { return sectionDated }
        return Self.applyingFactReschedule(sectionDated, to: moved)
    }

    /// The seen-state keys of the facts the megaphone lists as applied, which
    /// the badge counts while unread.
    var appliedFactKeys: [String] {
        factChangeGroups.filter { !$0.isUndone }.flatMap(\.rows).map { AnnouncementReadState.factKey($0.id) }
    }

    // MARK: Evaluate

    /// Runs the engine over the stored facts and the pool, records the result,
    /// writes new-task rows, and refreshes everything the screens read
    /// (`factDisplay`, `factHiddenRowIDs`, the megaphone's groups). Called by
    /// the rebuild with the Canvas pool as it stands after the structured
    /// overrides; the caller applies `reschedules` to that pool and drops
    /// `factHiddenRowIDs` from the announcement rows.
    func evaluateAppliedFacts(canvasPool: [Assignment], now: Date) -> FactPass {
        var pass = FactPass()
        let factRows = announcementItems.filter(Self.isFactRow)
        let factRowIDs = Set(factRows.map(\.id))

        guard FeatureFlags.appliedFacts, !isUsingFixtureData, appliedFactStore != nil else {
            // Off (or nothing to read them with): rows an earlier run wrote
            // stay in the ledger but off the dashboard.
            setFactState(display: [:], hidden: factRowIDs, groups: [], reviews: [])
            return pass
        }
        let facts = currentAppliedFacts()
        if facts.isEmpty && factRows.isEmpty {
            setFactState(display: [:], hidden: [], groups: [], reviews: [])
            return pass
        }

        let courseCodeByID = canvasCourseIDs()
        var documentURLs: [String: URL] = [:]
        for document in courseKnowledge.documents {
            if let url = document.url { documentURLs[document.id] = url }
        }
        let gone = assignmentStore.map {
            $0.goneFromFeedIDs(source: .canvas).union($0.goneFromFeedIDs(source: .canvasModules))
        } ?? []
        let poolIDs = Set(canvasPool.map(\.id))
        let rows = canvasPool + announcementItems.filter { !poolIDs.contains($0.id) }
        let items = rows.map { row in
            FactItem(
                assignment: row,
                userCompleted: isCompleted(row),
                editedDueDate: editedDueDate(for: row),
                isGoneFromFeed: gone.contains(row.id),
                // Post-override: Canvas's own date for this student.
                canvasDueAt: row.dueAt,
                hasStructuredDueDate: structuredDueOverrides[row.id] != nil
            )
        }
        let effects = FactApplication.evaluate(
            facts: facts, items: items, courseCodeByID: courseCodeByID,
            documentURLs: documentURLs, now: now
        )

        // Write the bookkeeping back only when the verdicts moved: `record`
        // touches every row, and a rebuild runs far more often than facts change.
        var comparable = effects
        comparable.evaluatedAt = .distantPast
        if comparable != factsLastEffects {
            appliedFactStore?.record(effects, now: now)
            factsLastEffects = comparable
        }

        // New tasks: upsert the rows that are absent or changed. The same
        // `upsert` the announcement watcher uses; nothing is reconciled.
        let existing = Dictionary(announcementItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let toWrite = effects.newTasks.map(\.assignment).filter { row in
            guard let have = existing[row.id] else { return true }
            return have.title != row.title || have.dueAt != row.dueAt || have.kind != row.kind
                || have.url != row.url || have.course != row.course
        }
        if !toWrite.isEmpty, let store = assignmentStore, store.upsert(toWrite).saved {
            pass.wroteRows = true
        }

        let factByID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func detail(_ factID: String, _ word: String) -> FactItemDisplay.Detail {
            let fact = factByID[factID]
            let url = fact.flatMap { documentURLs[$0.documentID] }
            return .init(
                factID: factID, word: word,
                text: Self.oneLineQuote(fact?.quote ?? ""),
                postURL: Self.safeFactURL(url)
            )
        }
        func change(_ factID: String, _ word: String) -> FactChangeRow {
            let fact = factByID[factID]
            return .init(
                id: factID, word: word, postedAt: fact?.postedAt,
                url: Self.safeFactURL(fact.flatMap { documentURLs[$0.documentID] })
            )
        }
        let titleByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var display: [String: FactItemDisplay] = [:]
        var groups: [FactChangeGroup] = []
        for (itemID, effect) in effects.items.sorted(by: { $0.key < $1.key }) {
            guard let row = titleByID[itemID], isCourseSelected(row.course) else { continue }
            var shown = FactItemDisplay()
            var changeRows: [FactChangeRow] = []
            func add(_ factID: String, _ word: String) {
                shown.factIDs.append(factID)
                shown.details.append(detail(factID, word))
                changeRows.append(change(factID, word))
            }
            if let cancelled = effect.cancelled {
                shown.cancelled = true
                add(cancelled.by, "cancelled")
            }
            // A reschedule only counts where the pool's copy is replaced; a
            // row outside the Canvas pool would say "moved" and show no new date.
            if let moved = effect.rescheduled, poolIDs.contains(itemID) {
                shown.moved = true
                if let from = moved.from, abs(from.timeIntervalSince(moved.to)) > FactApplication.sameDateTolerance {
                    shown.movedFrom = from
                }
                shown.movedTo = moved.to
                pass.reschedules[itemID] = moved.to
                add(moved.by, "moved")
            }
            if let scope = effect.scopeChanged {
                shown.changed = true
                add(scope.by, "changed")
            }
            for note in effect.notes {
                shown.changed = true
                add(note.by, "changed")
            }
            guard !shown.factIDs.isEmpty else { continue }
            display[itemID] = shown
            groups.append(FactChangeGroup(id: itemID, courseCode: row.course, title: row.title, rows: changeRows))
        }
        for task in effects.newTasks where isCourseSelected(task.assignment.course) {
            let id = task.assignment.id
            display[id] = FactItemDisplay(factIDs: [task.factID])
            groups.append(FactChangeGroup(
                id: id, courseCode: task.assignment.course, title: task.assignment.title,
                rows: [change(task.factID, "new")]
            ))
        }
        groups.sort { ($0.postedAt ?? .distantPast, $0.id) > ($1.postedAt ?? .distantPast, $1.id) }

        // Undone facts: a plain, dimmed row each, so a wrong tap is visible.
        for fact in facts where fact.studentOverride == .rejected {
            guard let code = courseCodeByID[fact.courseID], isCourseSelected(code) else { continue }
            let title = fact.title.flatMap { $0.isEmpty ? nil : $0 } ?? Self.oneLineQuote(fact.quote)
            groups.append(FactChangeGroup(
                id: fact.id, courseCode: code, title: title,
                rows: [change(fact.id, "undone")], isUndone: true
            ))
        }

        var reviews: [FactReviewRow] = []
        for review in effects.needsReview where review.reason != .unknownCourse {
            let fact = review.fact
            guard let code = courseCodeByID[fact.courseID], isCourseSelected(code) else { continue }
            reviews.append(FactReviewRow(
                id: fact.id, courseCode: code, quote: Self.oneLineQuote(fact.quote),
                url: Self.safeFactURL(documentURLs[fact.documentID]), postedAt: fact.postedAt
            ))
        }

        // A fact row the engine did not emit this time (undone, now covered
        // by Canvas, withdrawn) is hidden, unless the student finished it:
        // that is their record, and prev keeps it.
        let live = Set(effects.newTasks.map { $0.assignment.id })
        let hidden = Set(factRows.filter { !live.contains($0.id) && !isCompleted($0) }.map(\.id))
        setFactState(display: display, hidden: hidden, groups: groups, reviews: reviews)
        return pass
    }

    private func setFactState(
        display: [String: FactItemDisplay],
        hidden: Set<String>,
        groups: [FactChangeGroup],
        reviews: [FactReviewRow]
    ) {
        factDisplay = display
        factHiddenRowIDs = hidden
        factChangeGroups = groups
        factReviewRows = reviews
    }
}
