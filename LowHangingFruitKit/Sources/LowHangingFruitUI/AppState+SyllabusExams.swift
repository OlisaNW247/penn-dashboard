import Combine
import Foundation
import LowHangingFruitKit

// MARK: – Exams named in a class's syllabus
//
// "If you ever have a midterm, the class finds it from the syllabus or from an
// announcement. Either way, if a midterm is found, don't duplicate it. It
// becomes a new assignment on the page" (owner, 2026-10-18).
//
// The announcement half has been there since the Announcement Watcher: an
// exam announced in prose is a task like any other, and the card draws it as
// an exam. This is the syllabus half. The course material is already on the
// phone (`courseKnowledge`, synced for ask), and a syllabus that says
// "Midterm 1: Thursday, October 23" has said everything an announcement would,
// weeks earlier. `SyllabusExamRows` reads it and this file files what it finds
// and keeps it current.
//
//  - **Rows.** `.canvasAnnouncement` with a `syllabus-` id, kind `.event`; see
//    `AnnouncementRecord.syllabusFindSourceID` for why that and not a new
//    source or a new column, and `SyllabusExamRows` for what each row holds.
//    The id is the exam's identity, so reading the same syllabus twice writes
//    the same rows (not duplicates), a moved date updates the row it moves
//    (the completion, a due-date edit and the ledger row all stay with the
//    exam), and an older build that reads the store sees an announcement task.
//  - **Nothing is read twice, and nothing is rewritten for nothing.** The pass
//    has no ratchet of "documents already read", unlike the announcement
//    passes: those protect an extractor that costs money, and this one is a
//    pure function of the text, so a ratchet would only add a way to be wrong
//    (a document edited after it was read). What it does instead is compare
//    each row with the ledger and write only the ones that differ, so a pass
//    that finds nothing new makes no write and no rebuild.
//  - **Which classes.** Every Canvas site the app can name a class for
//    (`canvasCourseIDs()`), hidden or not: the dashboard decides what is
//    shown (`isCourseSelected`), so a class turned back on has its exams
//    straight away instead of at the next sync. A site the map does not know
//    is skipped, which is also what keeps a disconnected install quiet:
//    disconnecting empties the map and purges these rows, while the documents
//    can outlive it in the course-material cache.
//  - **Deleting is not detected, on purpose.** A syllabus that stops naming an
//    exam leaves its row. A document missing from `courseKnowledge` is weak
//    evidence (a failed sync drops the courses it had not reached), and acting
//    on it would hide a real exam; a syllabus that merely *rewrites* the line
//    updates the row through its stable id, which is the case that happens.
//    The wrong fix is to flag every row the current text does not produce
//    gone: it would remove an exam from the dashboard whenever a page failed
//    to load.
//  - **Off the main actor, and checked again on the way back.** Reading a
//    term's worth of course pages is milliseconds each and adds up; the
//    extraction runs on a background task over a copy of the documents (value
//    types) and only the ledger write is on the main actor. The classes are
//    looked up a second time when it returns, so a Canvas disconnect that
//    happened during the read writes nothing.

extension AppState {

    /// Reads the course material once and files the exams it names. Never
    /// throws; a pass with nothing to do returns quietly.
    ///
    /// Called by `scheduleSyllabusExamPass()` when the course knowledge
    /// changes, and directly by tests.
    func syncSyllabusExams(now: Date = Date(), calendar: Calendar = .current) async {
        guard !isUsingFixtureData, let store = assignmentStore else { return }

        let documents = courseKnowledge.documents
        let codesByID = canvasCourseIDs()
        guard !documents.isEmpty, !codesByID.isEmpty else { return }

        let computed = await Task.detached(priority: .utility) {
            SyllabusExamRows.assignments(
                from: documents, courseCodesByID: codesByID, referenceDate: now, calendar: calendar
            )
        }.value
        syllabusExamComputedHookForTesting?()
        // The await was a hop to another thread, and Canvas can be disconnected
        // meanwhile (which empties the class map and purges these rows). Look
        // the classes up again and keep only the exams of a class that is still
        // known; writing the rest would put a disconnected account's exams back
        // in the ledger just after the purge that removed them.
        guard !isUsingFixtureData else { return }
        let stillKnown = Set(canvasCourseIDs().values)
        let rows = computed.filter { stillKnown.contains($0.course) }
        guard !rows.isEmpty else { return }

        // Only the rows that are new or changed. `store.assignments(source:)`
        // is the active rows, which is all a comparison needs: a row it does
        // not list (aged out) is simply written again. Compared on the fields
        // this pass writes and no others: a stored row also carries a
        // Gradescope pairing (`linkedID`) that the dashboard's own merge may
        // have recorded, `upsert` leaves it alone, and comparing whole values
        // would call every paired exam "changed" on every pass.
        let existing = Dictionary(
            store.assignments(source: .canvasAnnouncement).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let changed = rows.filter { row in
            guard let stored = existing[row.id] else { return true }
            return stored.kind != row.kind || stored.course != row.course || stored.title != row.title
                || stored.dueAt != row.dueAt || stored.url != row.url
        }
        guard !changed.isEmpty else { return }

        store.upsert(changed, now: now)
        applyAnnouncementLedgerChange()
    }

    // MARK: Triggering

    /// Subscribes, once, to `courseKnowledge`, so a syllabus is read as soon as
    /// a sync lands without a call being added to the sync (which this change
    /// leaves alone). The same pattern, and the same reason for the deferred
    /// task, as `observeKnowledgeForEdTasks`: `@Published` fires before the
    /// value changes, so the handler schedules a pass that runs afterwards
    /// instead of reading the value itself.
    func observeKnowledgeForSyllabusExams() {
        guard syllabusExamKnowledgeSubscription == nil else { return }
        syllabusExamKnowledgeSubscription = $courseKnowledge
            .dropFirst()
            .sink { [weak self] _ in
                // `courseKnowledge` is only ever set on the main actor.
                MainActor.assumeIsolated {
                    self?.scheduleSyllabusExamPass()
                }
            }
    }

    /// Runs the pass on the main actor, one at a time. A change that arrives
    /// while a pass is running (the manifest's downloads and then the Ed merge
    /// are two assignments) sets a flag and the run goes round again when it
    /// finishes, so the last knowledge is always the one read.
    func scheduleSyllabusExamPass() {
        if syllabusExamPassTask != nil {
            syllabusExamPassNeedsRerun = true
            return
        }
        syllabusExamPassTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.syllabusExamPassNeedsRerun = false
                await self.syncSyllabusExams()
            } while self.syllabusExamPassNeedsRerun
            self.syllabusExamPassTask = nil
        }
    }
}
