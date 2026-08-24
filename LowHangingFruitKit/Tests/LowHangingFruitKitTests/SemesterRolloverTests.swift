import Testing
import Foundation
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Semester rollover: detecting a term boundary, archiving the old term without
/// losing it, and adding a class the feed hasn't caught up with yet.
///
/// The bug being fixed is a real one, reported from a real phone in the first
/// week of a real semester: *"I am seeing notifications for last sem and I need
/// it to eventually redo it for my new classes, also only one class will show
/// up."* Both halves trace to the same root — the app derived "my classes" and
/// "my work" from whatever the Canvas feed currently held, with no lower bound
/// on age and no way to declare a class before the feed did.
///
/// The scenarios below are therefore written against a **populated ledger
/// spanning two terms**, replayed across simulated launches, in the shape
/// `AssignmentLedgerScenarioTests` established. Testing the archive flag against
/// a store with three rows in it would prove almost nothing; the interesting
/// failures are the ones that need a February sync and an August sync to show
/// up at all.
@MainActor
@Suite("Semester rollover")
struct SemesterRolloverTests {

    // MARK: Term arithmetic

    @Test("A term code round-trips through parse and back")
    func termCodeRoundTrips() {
        for term in [Term(year: 2026, season: .spring),
                     Term(year: 2026, season: .summer),
                     Term(year: 2026, season: .fall)] {
            #expect(Term(code: term.code) == term)
        }
        #expect(Term(year: 2026, season: .spring).code == "202610")
        #expect(Term(year: 2026, season: .fall).code == "202630")
    }

    @Test("A term renders as something a student would say out loud")
    func termDisplayName() {
        #expect(Term(year: 2026, season: .spring).displayName == "Spring 2026")
        #expect(Term(year: 2026, season: .fall).displayName == "Fall 2026")
    }

    // MARK: Detection — the pure rule

    @Test("No offer when everything the ledger holds is current-term work")
    func noOfferWithinOneTerm() {
        let now = Date()
        let current = Term(date: now)
        let items = (1...5).map {
            SemesterRollover.Item(id: "canvas:\($0)", course: "CIS 1200",
                                  term: current, isArchived: false)
        }
        #expect(SemesterRollover.detect(items, now: now) == nil)
    }

    @Test("An empty ledger offers nothing")
    func noOfferWhenEmpty() {
        #expect(SemesterRollover.detect([], now: Date()) == nil)
    }

    @Test("A past term is offered, with a concrete count and its classes")
    func offersPastTermWithCount() throws {
        let now = Date()
        let prior = priorTerm(to: Term(date: now))
        let items = [
            SemesterRollover.Item(id: "canvas:1", course: "CIS 1200", term: prior, isArchived: false),
            SemesterRollover.Item(id: "canvas:2", course: "CIS 1200", term: prior, isArchived: false),
            SemesterRollover.Item(id: "canvas:3", course: "MATH 1400", term: prior, isArchived: false),
            SemesterRollover.Item(id: "canvas:4", course: "PHYS 0150",
                                  term: Term(date: now), isArchived: false),
        ]

        let offer = try #require(SemesterRollover.detect(items, now: now))
        #expect(offer.totalItemCount == 3)
        #expect(offer.candidates.count == 1)
        #expect(offer.candidates.first?.courseKeys == ["CIS 1200", "MATH 1400"])
        // The count is what makes the card an informed choice rather than a
        // shrug, so the summary string is asserted verbatim.
        #expect(offer.summary == "3 items from \(prior.displayName)")
    }

    @Test("Work already archived is not offered a second time")
    func archivedWorkIsNotReoffered() {
        let now = Date()
        let prior = priorTerm(to: Term(date: now))
        let items = [
            SemesterRollover.Item(id: "canvas:1", course: "CIS 1200", term: prior, isArchived: true),
            SemesterRollover.Item(id: "canvas:2", course: "CIS 1200", term: prior, isArchived: true),
        ]
        // Every past-term item is settled, so there is no question left to ask.
        // Without this the card would reappear on the next launch offering to
        // archive what the student had already archived.
        #expect(SemesterRollover.detect(items, now: now) == nil)
    }

    @Test("A future term is never a rollover candidate")
    func futureTermNotOffered() {
        let now = Date()
        let next = Term(year: Term(date: now).year + 5, season: .fall)
        let items = [SemesterRollover.Item(id: "canvas:1", course: "CIS 1200",
                                           term: next, isArchived: false)]
        // Canvas lists next semester's shell course as active well before it
        // starts. Offering to archive work that hasn't been assigned yet would
        // be nonsense; `withinTermCap` already keeps it off the dashboard.
        #expect(SemesterRollover.detect(items, now: now) == nil)
    }

    @Test("Several past terms are offered newest-first and summarised together")
    func multipleTermsSortedNewestFirst() throws {
        let now = Date()
        let current = Term(date: now)
        let one = priorTerm(to: current)
        let two = priorTerm(to: one)
        let items = [
            SemesterRollover.Item(id: "canvas:1", course: "A 100", term: one, isArchived: false),
            SemesterRollover.Item(id: "canvas:2", course: "B 100", term: two, isArchived: false),
        ]

        let offer = try #require(SemesterRollover.detect(items, now: now))
        #expect(offer.terms == [one, two])
        #expect(offer.summary == "2 items from 2 earlier terms")
    }

    // MARK: effectiveTerm — the precedence that fixes the leak

    @Test("A row's term comes from the course code first, then the due date, then firstSeen")
    func effectiveTermPrecedence() throws {
        let stamped = Term(year: 2026, season: .spring)
        let dueInFall = date(2026, 10, 1)
        let seenInSpring = date(2026, 2, 10)

        // 1. The course-code term wins outright — it is exact, where everything
        //    below it is inference.
        let withTerm = StoredAssignment(
            id: "canvas:1", sourceRaw: "canvas", sourceID: "1", kindRaw: "assignment",
            course: "CIS 1200", title: "HW", dueAt: dueInFall, urlString: nil,
            termYear: stamped.year, termSeasonRaw: stamped.season.rawValue,
            firstSeen: seenInSpring, lastSeenInFeed: seenInSpring)
        #expect(withTerm.effectiveTerm() == stamped)

        // 2. No term: the due date dates it.
        let withDue = StoredAssignment(
            id: "canvas:2", sourceRaw: "canvas", sourceID: "2", kindRaw: "assignment",
            course: "CIS 1200", title: "HW", dueAt: dueInFall, urlString: nil,
            termYear: nil, termSeasonRaw: nil,
            firstSeen: seenInSpring, lastSeenInFeed: seenInSpring)
        #expect(withDue.effectiveTerm() == Term(year: 2026, season: .fall))

        // 3. Neither: `firstSeen`. THIS is the clause that fixes the reported
        //    bug. An undated, termless row is exactly what slips through
        //    `withinTermCap`'s "undated items always pass", it is exempt from
        //    aging (no due date to be overdue against) and from `isTooOld` for
        //    the same reason — so it survives forever and keeps firing
        //    reminders. The ledger cannot say when it was due, but it has always
        //    known when it first turned up.
        let bare = StoredAssignment(
            id: "canvas:3", sourceRaw: "canvas", sourceID: "3", kindRaw: "assignment",
            course: "CIS 1200", title: "Reading", dueAt: nil, urlString: nil,
            termYear: nil, termSeasonRaw: nil,
            firstSeen: seenInSpring, lastSeenInFeed: seenInSpring)
        #expect(bare.effectiveTerm() == Term(year: 2026, season: .spring))
    }

    @Test("When two rows for one id collapse, live beats archived")
    func absorbPrefersLive() throws {
        let spring = Term(year: 2026, season: .spring)

        let archived = StoredAssignment(
            id: "canvas:dup", sourceRaw: "canvas", sourceID: "dup", kindRaw: "assignment",
            course: "CIS 1200", title: "HW", dueAt: date(2026, 3, 1), urlString: nil,
            termYear: spring.year, termSeasonRaw: spring.season.rawValue,
            firstSeen: date(2026, 2, 1), lastSeenInFeed: date(2026, 2, 1),
            archivedTermYear: spring.year, archivedTermSeasonRaw: spring.season.rawValue)
        archived.absorb(StoredAssignment(
            id: "canvas:dup", sourceRaw: "canvas", sourceID: "dup", kindRaw: "assignment",
            course: "CIS 1200", title: "HW", dueAt: date(2026, 3, 1), urlString: nil,
            termYear: spring.year, termSeasonRaw: spring.season.rawValue,
            firstSeen: date(2026, 2, 1), lastSeenInFeed: date(2026, 2, 1)))

        // The two mistakes are not symmetric. A row wrongly left live is
        // clutter; a row wrongly archived is work that has disappeared. `absorb`
        // resolves toward whatever the student would notice missing.
        #expect(!archived.isArchived)
    }

    // MARK: The store — archive is a stamp, never a delete

    @Test("Archiving stamps only the named terms, and running it twice changes nothing")
    func archiveIsScopedAndIdempotent() throws {
        let store = try AssignmentStore(inMemory: true)
        let spring = Term(year: 2026, season: .spring)
        let fall = Term(year: 2026, season: .fall)

        _ = store.reconcile([
            canvas("s1", course: "ROLL-A 100", term: spring, due: date(2026, 3, 1)),
            canvas("s2", course: "ROLL-A 100", term: spring, due: date(2026, 4, 1)),
            canvas("f1", course: "ROLL-B 100", term: fall, due: date(2026, 10, 1)),
        ], source: .canvas, now: date(2026, 2, 1))

        #expect(store.archive(terms: [spring]) == 2)
        #expect(store.archivedAssignmentIDs() == ["canvas:s1", "canvas:s2"])
        #expect(store.archivedTerms() == [spring])
        // Idempotent: a second pass finds nothing left to stamp, so the returned
        // count is an honest "nothing happened" rather than a repeat of the
        // first number.
        #expect(store.archive(terms: [spring]) == 0)
    }

    @Test("Archived work is still on the ledger, and unarchiving brings it back")
    func archiveIsReversibleAndLossless() throws {
        let store = try AssignmentStore(inMemory: true)
        let spring = Term(year: 2026, season: .spring)
        _ = store.reconcile([
            canvas("s1", course: "ROLL-C 100", term: spring, due: date(2026, 3, 1)),
        ], source: .canvas, now: date(2026, 2, 1))

        store.archive(terms: [spring])
        // Still returned by the read the dashboard and the Done tab are seeded
        // from. Archiving changes what `AppState` *shows*, not what exists.
        #expect(store.currentAssignments().map(\.id) == ["canvas:s1"])
        #expect(store.rowCount() == 1)

        #expect(store.unarchive(terms: [spring]) == 1)
        #expect(store.archivedAssignmentIDs().isEmpty)
        #expect(store.rowCount() == 1)
    }

    @Test("Archived work is exempt from the pruner, so archiving can never delete")
    func archivedRowsSurvivePruning() throws {
        let store = try AssignmentStore(inMemory: true)
        let spring = Term(year: 2026, season: .spring)
        let longAfterSpring = date(2026, 8, 23)

        _ = store.reconcile([
            canvas("s1", course: "ROLL-D 100", term: spring, due: date(2026, 3, 1)),
        ], source: .canvas, now: date(2026, 2, 1))
        // The item leaves the feed, which is what a concluded course does.
        _ = store.reconcile([
            canvas("other", course: "ROLL-D 100", term: spring, due: date(2026, 3, 1)),
        ], source: .canvas, now: date(2026, 3, 2))

        store.archive(terms: [spring])

        // Every clause of `isAgedOut` is now satisfied: unfinished, gone from
        // the feed, and months past due. Without the archived exemption,
        // agreeing to "archive Spring 2026" would hand the student's spring to
        // the pruner a fortnight later and take the Done history with it.
        #expect(store.pruneAgedOut(now: longAfterSpring) == 0)
        #expect(store.archivedAssignmentIDs().contains("canvas:s1"))
    }

    @Test("A re-sync does not un-archive: archival is ledger-owned, not feed-owned")
    func feedCannotUnarchive() throws {
        let store = try AssignmentStore(inMemory: true)
        let spring = Term(year: 2026, season: .spring)
        let item = canvas("s1", course: "ROLL-E 100", term: spring, due: date(2026, 3, 1))

        _ = store.reconcile([item], source: .canvas, now: date(2026, 2, 1))
        store.archive(terms: [spring])

        // Canvas keeps publishing a concluded course's calendar for weeks. If
        // `refresh(from:now:)` touched the archival fields, the very next sync
        // would silently undo a decision the student was asked to make.
        _ = store.reconcile([item], source: .canvas, now: date(2026, 8, 23))
        #expect(store.archivedAssignmentIDs().contains("canvas:s1"))
    }

    @Test("The widget stops advertising archived work")
    func widgetExcludesArchived() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-rollover-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try AssignmentStore(url: url)
        let spring = Term(year: 2026, season: .spring)
        let soon = Date().addingTimeInterval(3 * 86_400)
        _ = store.reconcile([
            canvas("w1", course: "ROLL-F 100", term: spring, due: soon),
        ], source: .canvas, now: Date())

        #expect(LedgerWidgetReader.snapshot(storeURL: url)?.items.count == 1)
        store.archive(terms: [spring])
        // A widget still counting down to last April's problem set is the same
        // bug wearing a home screen.
        #expect(LedgerWidgetReader.snapshot(storeURL: url) == nil)
    }

    // MARK: The term cap

    @Test("An unarchived past term still passes the cap; an archived one does not")
    func termCapBoundsThePastOnlyOnceArchived() {
        let now = date(2026, 8, 23)
        let spring = Term(year: 2026, season: .spring)
        let summer = Term(year: 2026, season: .summer)
        let item = { (term: Term) in
            Assignment(source: .canvas, sourceID: "x", kind: .assignment,
                       course: "CIS 1200", title: "HW", dueAt: nil, url: nil, term: term)
        }

        // The naive repair for this bug — demanding `term == current` — would
        // fail here, and expensively: `Term(date:)` maps August to fall, so a
        // summer course with an August deadline is already a "past" term and a
        // student still finishing it would watch live work vanish.
        #expect(AppState.withinTermCap(item(summer), now: now))
        #expect(AppState.withinTermCap(item(spring), now: now))

        // Once the student has been shown a count and agreed, it goes.
        #expect(!AppState.withinTermCap(item(spring), now: now, archivedTerms: [spring]))
        #expect(AppState.withinTermCap(item(summer), now: now, archivedTerms: [spring]))
    }

    @Test("An overdue item from an archived term stops leaking through the due-date door")
    func termCapCatchesUndatedTermlessLeftovers() {
        let now = date(2026, 8, 23)
        let spring = Term(year: 2026, season: .spring)
        // No term of its own, and overdue — the combination the old cap waved
        // through unconditionally ("undated and overdue items always pass").
        let overdueSpringItem = Assignment(
            source: .canvas, sourceID: "x", kind: .assignment, course: "CIS 1200",
            title: "HW", dueAt: date(2026, 3, 15), url: nil, term: nil)

        #expect(AppState.withinTermCap(overdueSpringItem, now: now))
        #expect(!AppState.withinTermCap(overdueSpringItem, now: now, archivedTerms: [spring]))
    }

    @Test("A future term is still excluded, archived or not")
    func termCapStillBoundsTheFuture() {
        let now = date(2026, 8, 23)
        let future = Assignment(source: .canvas, sourceID: "x", kind: .assignment,
                                course: "CIS 1200", title: "HW", dueAt: nil, url: nil,
                                term: Term(year: 2099, season: .fall))
        #expect(!AppState.withinTermCap(future, now: now))
    }

    // MARK: The populated two-term scenario

    @Test("Two terms, two launches: archiving clears the dashboard and keeps Done")
    func twoTermLedgerArchivesCleanly() throws {
        try withCourseState {
            let store = try AssignmentStore(inMemory: true)
            let now = Date()
            let current = Term(date: now)
            let prior = priorTerm(to: current)
            let priorSync = prior.startDate().addingTimeInterval(20 * 86_400)

            // --- Launch 1, mid-prior-term. A real week's feed: dated work, an
            // undated reading, and something the student finishes.
            _ = store.reconcile([
                canvas("p1", course: "SEM-A 100", term: prior,
                       due: priorSync.addingTimeInterval(5 * 86_400)),
                canvas("p2", course: "SEM-A 100", term: prior, due: nil),
                canvas("p3", course: "SEM-B 100", term: prior,
                       due: priorSync.addingTimeInterval(9 * 86_400)),
            ], source: .canvas, now: priorSync)
            store.setCompleted(ids: ["canvas:p3"], at: priorSync.addingTimeInterval(8 * 86_400))

            // --- Launch 2, this term. Canvas is still publishing the concluded
            // course's calendar, which is why last term's work is still here at
            // all — plus one genuinely new class.
            _ = store.reconcile([
                canvas("p1", course: "SEM-A 100", term: prior,
                       due: priorSync.addingTimeInterval(5 * 86_400)),
                canvas("p2", course: "SEM-A 100", term: prior, due: nil),
                canvas("n1", course: "SEM-C 100", term: current,
                       due: now.addingTimeInterval(4 * 86_400)),
            ], source: .canvas, now: now)

            let state = AppState(assignmentStore: store)
            let onDashboard = { Set((state.assignments + state.laterAssignments).map(\.id)) }

            // Before: last term is still on the dashboard. This is the reported
            // bug, reproduced.
            #expect(onDashboard().contains("canvas:p2"))

            let offer = try #require(store.rolloverOffer(now: now))
            #expect(offer.terms.contains(prior))

            // --- The student taps the card.
            let stamped = state.archiveTerms([prior], now: now)
            #expect(stamped >= 2)

            // After: last term is off the dashboard, this term is untouched.
            #expect(!onDashboard().contains("canvas:p1"))
            #expect(!onDashboard().contains("canvas:p2"))
            #expect(onDashboard().contains("canvas:n1"))

            // And nothing was lost. The finished item is still in the pool the
            // Done tab reads, and the ledger still holds every row. Archiving is
            // not deletion — that is the whole bargain the card offers.
            #expect(state.mergedCoursework.contains { $0.id == "canvas:p3" })
            #expect(state.completedAssignmentIDs.contains("canvas:p3"))
            #expect(store.currentAssignments().contains { $0.id == "canvas:p1" })

            // The archived classes leave the class list but stay *selected*, so
            // Done keeps showing their finished work.
            #expect(!state.visibleCourseCodes().contains("SEM-A 100"))
            #expect(state.isCourseSelected("SEM-A 100"))
            #expect(state.visibleCourseCodes().contains("SEM-C 100"))

            // Restoring puts it all back.
            state.unarchiveTerms([prior], now: now)
            #expect(onDashboard().contains("canvas:p2"))
            #expect(state.visibleCourseCodes().contains("SEM-A 100"))
        }
    }

    @Test("A class taken in both terms stays on the roster when the old term is archived")
    func retakenCourseSurvivesRollover() throws {
        try withCourseState {
            let store = try AssignmentStore(inMemory: true)
            let now = Date()
            let current = Term(date: now)
            let prior = priorTerm(to: current)
            let priorSync = prior.startDate().addingTimeInterval(20 * 86_400)

            // One course key, two terms — a retake, or a year-long sequence.
            _ = store.reconcile([
                canvas("old", course: "SEM-D 100", term: prior,
                       due: priorSync.addingTimeInterval(3 * 86_400)),
            ], source: .canvas, now: priorSync)
            _ = store.reconcile([
                canvas("old", course: "SEM-D 100", term: prior,
                       due: priorSync.addingTimeInterval(3 * 86_400)),
                canvas("new", course: "SEM-D 100", term: current,
                       due: now.addingTimeInterval(4 * 86_400)),
            ], source: .canvas, now: now)

            let state = AppState(assignmentStore: store)
            state.archiveTerms([prior], now: now)

            // The row-level stamp is per-item, so last term's work goes and this
            // term's stays — which a course-level flag alone could not express,
            // because `courseKey` carries no term.
            #expect(!state.assignments.contains { $0.id == "canvas:old" })
            #expect(state.assignments.contains { $0.id == "canvas:new" }
                    || state.laterAssignments.contains { $0.id == "canvas:new" })
            // And the class the student is sitting in this week is still listed.
            #expect(state.visibleCourseCodes().contains("SEM-D 100"))
        }
    }

    // MARK: The reported symptom — reminders for last semester

    @Test("Archiving stops last semester's reminders being scheduled at all")
    func archivedWorkSchedulesNoReminders() throws {
        try withCourseState {
            let store = try AssignmentStore(inMemory: true)
            let now = Date()
            let current = Term(date: now)
            let prior = priorTerm(to: current)

            // Last term's work, still being published by Canvas and still due
            // "soon" as far as any date-based filter is concerned. This is the
            // shape of the item that was firing reminders in August for a
            // course that ended in May.
            _ = store.reconcile([
                canvas("old1", course: "SEM-F 100", term: prior,
                       due: now.addingTimeInterval(2 * 86_400)),
                canvas("new1", course: "SEM-G 100", term: current,
                       due: now.addingTimeInterval(2 * 86_400)),
            ], source: .canvas, now: now)

            let state = AppState(assignmentStore: store)
            let scheduler = NotificationScheduler()

            // `reschedule()` is driven by the dashboard view model, which is
            // built from exactly the arrays `rebuildDashboardItems` fills — so
            // dropping an item from those arrays is what silences it. No hook in
            // `NotificationScheduler` is involved.
            // Explicitly `@MainActor`: a nested function does not inherit the
            // isolation of the closure it sits in, however that closure is
            // annotated.
            @MainActor func plannedIDs() -> Set<String> {
                // A fresh view model each time: `bind(to:)` is one-shot, and the
                // question here is what a *relaunch* would schedule.
                let vm = DashboardViewModel()
                vm.bind(to: state)
                return Set(scheduler.plannedRequests(from: vm.items, now: now)
                    .map(\.identifier))
            }

            let before = plannedIDs()
            #expect(before.contains { $0.contains("old1") })

            state.archiveTerms([prior], now: now)

            let after = plannedIDs()
            #expect(!after.contains { $0.contains("old1") })
            // This term's reminders are untouched — the fix is a scalpel, not a
            // mute button.
            #expect(after.contains { $0.contains("new1") })
        }
    }

    // MARK: Add a class by hand

    @Test("A hand-added class appears in the list and survives a relaunch")
    func addedClassIsFirstClassAndDurable() throws {
        try withCourseState {
            let store = try AssignmentStore(inMemory: true)
            let state = AppState(assignmentStore: store)

            #expect(state.addCourse("ADDX 1200") == "ADDX 1200")
            #expect(state.visibleCourseCodes().contains("ADDX 1200"))
            #expect(state.isCourseSelected("ADDX 1200"))

            // A second `AppState` over the same defaults is a relaunch. The
            // record lives in the App Group suite, so it comes back.
            let relaunched = AppState(assignmentStore: store)
            #expect(relaunched.visibleCourseCodes().contains("ADDX 1200"))

            // Hiding and showing work like any other class.
            relaunched.setCourse("ADDX 1200", selected: false)
            #expect(!relaunched.isCourseSelected("ADDX 1200"))
            #expect(relaunched.visibleCourseCodes().contains("ADDX 1200"))
        }
    }

    @Test("Typed course codes are normalised to the canonical form")
    func addedClassIsNormalised() throws {
        try withCourseState {
            let state = AppState(assignmentStore: try AssignmentStore(inMemory: true))
            // Everything that identifies a class keys on `CourseCode.parse`, so
            // an added class has to arrive through it or it sits beside the
            // feed's copy of the same course forever.
            #expect(state.addCourse("addy1200") == "ADDY 1200")
            #expect(state.addCourse("  addy-1200 ") == "ADDY 1200")
            #expect(state.manuallyAddedCourseCodes().filter { $0 == "ADDY 1200" }.count == 1)
            // Junk is refused rather than filed under a meaningless key.
            #expect(state.addCourse("") == nil)
            #expect(state.addCourse("???") == nil)
            #expect(state.addCourse("   ") == nil)
            // But a class that genuinely has no course code is still a class.
            // `CourseCode.parse` keeps an unrecognised name as typed, which is
            // what a thesis or an off-Canvas reading group needs.
            #expect(state.addCourse("Senior Thesis") == "Senior Thesis")
        }
    }

    @Test("When Canvas catches up, the hand-added class does not become a duplicate")
    func addedClassReconcilesWithTheFeed() throws {
        try withCourseState {
            let store = try AssignmentStore(inMemory: true)
            let state = AppState(assignmentStore: store)
            let now = Date()

            // Week one: the course exists on the student's timetable but has
            // posted nothing, so the feed knows nothing about it.
            state.addCourse("ADDZ 1200")
            #expect(state.visibleCourseCodes().filter { $0 == "ADDZ 1200" }.count == 1)

            // Week two: Canvas finally posts, with the full noisy descriptor the
            // ICS feed actually carries.
            let parsed = CourseCode.parse("ADDZ 1200-401 \(Term(date: now).code) INTRO")
            #expect(parsed.code == "ADDZ 1200")
            _ = store.reconcile([
                canvas("z1", course: parsed.code, term: parsed.term, due: now.addingTimeInterval(86_400)),
            ], source: .canvas, now: now)
            state.canvasItems = store.currentAssignments().filter { $0.source == .canvas }

            // Exactly one class, because the hand-added course and the feed's
            // course are the same canonical key — the union is a `Set`, so there
            // is no reconciliation step to get wrong.
            #expect(state.visibleCourseCodes().filter { $0 == "ADDZ 1200" }.count == 1)
            #expect(state.allCourseCodes().filter { $0 == "ADDZ 1200" }.count == 1)
        }
    }

    @Test("A hand-added class carries manual assignments onto the dashboard")
    func addedClassCarriesManualWork() throws {
        try withCourseState {
            let state = AppState(assignmentStore: try AssignmentStore(inMemory: true))
            state.addCourse("ADDW 1200")
            state.addManualAssignment(ManualAssignment(
                title: "Read chapter 1", course: "ADDW 1200",
                dueAt: Date().addingTimeInterval(2 * 86_400)))

            // The class existing is what lets the work through: the dashboard
            // filter consults `isCourseSelected`, and before this feature a
            // course the feed had never mentioned was not selectable at all.
            #expect(state.assignments.contains { $0.course == "ADDW 1200" })
        }
    }

    @Test("Removing a hand-added class keeps it only if the feed also knows it")
    func removingAddedClassRespectsTheFeed() throws {
        try withCourseState {
            let store = try AssignmentStore(inMemory: true)
            let state = AppState(assignmentStore: store)
            let now = Date()

            state.addCourse("ADDV 1200")
            state.removeAddedCourse("ADDV 1200")
            #expect(!state.visibleCourseCodes().contains("ADDV 1200"))

            // Now the same class, but with the feed publishing for it. Removing
            // the hand-added mark must not remove a real class.
            state.addCourse("ADDU 1200")
            _ = store.reconcile([
                canvas("u1", course: "ADDU 1200", term: Term(date: now),
                       due: now.addingTimeInterval(86_400)),
            ], source: .canvas, now: now)
            state.canvasItems = store.currentAssignments().filter { $0.source == .canvas }
            state.removeAddedCourse("ADDU 1200")
            #expect(state.visibleCourseCodes().contains("ADDU 1200"))
        }
    }

    // MARK: Dismissal

    @Test("Dismissing the offer silences this boundary but not the next one")
    func dismissalIsScopedToTheBoundary() throws {
        try withCourseState {
            let store = try AssignmentStore(inMemory: true)
            let now = Date()
            let prior = priorTerm(to: Term(date: now))
            _ = store.reconcile([
                canvas("d1", course: "SEM-E 100", term: prior,
                       due: prior.startDate().addingTimeInterval(5 * 86_400)),
            ], source: .canvas, now: prior.startDate())

            let state = AppState(assignmentStore: store)
            state.dismissRolloverOffer(now: now)
            #expect(state.rolloverOffer == nil)
            // Nothing was archived — dismissing is "not now", not "yes".
            #expect(state.archivedAssignmentIDs.isEmpty)
            // And the work is still on the dashboard, which is the honest
            // consequence of saying no.
            #expect(store.rolloverOffer(now: now) != nil)
        }
    }

    @Test("A dismissal silences only the boundary it was given for")
    func dismissalScopingRule() {
        let now = Date()
        let current = Term(date: now)
        let offer = SemesterRollover.Offer(
            currentTerm: current,
            candidates: [.init(term: priorTerm(to: current), itemCount: 3,
                               courseKeys: ["CIS 1200"])])

        // Dismissed for this boundary: silent.
        #expect(AppState.visibleRolloverOffer(offer, dismissedTerm: current) == nil)
        // Never dismissed, or dismissed for some *other* boundary: asks again.
        // Waving away "archive Spring 2026" in August must not also wave away
        // "archive Fall 2026" next January.
        #expect(AppState.visibleRolloverOffer(offer, dismissedTerm: nil) != nil)
        #expect(AppState.visibleRolloverOffer(
            offer, dismissedTerm: priorTerm(to: current)) != nil)
        // No offer is no card, dismissed or not.
        #expect(AppState.visibleRolloverOffer(nil, dismissedTerm: nil) == nil)
    }

    // MARK: Fixtures

    private func canvas(_ id: String, course: String, term: Term?, due: Date?) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: course, title: "HW \(id)", dueAt: due,
                   url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"),
                   term: term)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    /// The term immediately before `term`, following Penn's spring → summer →
    /// fall cycle. Local to the tests because production code never needs to
    /// step backwards through terms — it compares them.
    private func priorTerm(to term: Term) -> Term {
        switch term.season {
        case .spring: return Term(year: term.year - 1, season: .fall)
        case .summer: return Term(year: term.year, season: .spring)
        case .fall:   return Term(year: term.year, season: .summer)
        }
    }

    /// A clean slate for every per-course and rollover key, restored afterwards.
    ///
    /// All of them live in the process-wide `UserDefaults.lhf`, which in a test
    /// run with no App Group entitlement *is* `.standard`. Without this, a
    /// failed assertion here would leak an archived course into the developer's
    /// own app and into every later suite in the run — the hazard HANDOFF.md
    /// warns about, and one that fails somewhere other than where it was caused.
    /// Normalised on the way in **and** out.
    /// The closure is `@MainActor` so a nested helper declared inside it still
    /// inherits isolation — a plain `func` inside a nonisolated closure does
    /// not, and everything it would want to touch (`AppState`, the scheduler,
    /// the view model) is main-actor.
    private func withCourseState(_ body: @MainActor () throws -> Void) throws {
        let defaults = UserDefaults.lhf
        let keys = [
            CoursePreferencesStore.storageKey,
            SharedDefaults.hiddenCoursesKey,
            SharedDefaults.deletedCoursesKey,
            SharedDefaults.courseNameOverridesKey,
            "canvasCourseIDsByCode",
            "rolloverDismissedTerm",
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        try body()
    }
}
