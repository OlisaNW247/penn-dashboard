import SwiftUI
import Combine
import LowHangingFruitKit

// MARK: – DashItem
//
// A presentation wrapper around `Assignment`. It adds purely-UI state the
// model doesn't carry — a local due-date override and a completion timestamp
// (completion time isn't stored by AppState, so it's only known for items
// completed during this session or supplied by DEBUG sample data).

struct DashItem: Identifiable, Equatable {
    let assignment: Assignment
    var dueOverride: Date?
    var isCompleted: Bool
    var completedAt: Date?

    var id: String { assignment.id }
    var due: Date? { dueOverride ?? assignment.dueAt }

    func state(now: Date = Date()) -> DueState { DueState(due: due, now: now) }
}

// MARK: – Toggle tabs

enum DashFilter: String, CaseIterable, Identifiable {
    case thisWeek = "This week"
    case all      = "All"
    case done     = "Done"
    var id: String { rawValue }
}

// MARK: – Section model

struct DashSection: Identifiable {
    let id: String
    let label: String
    let labelColor: Color
    var items: [DashItem]
    /// Optional per-item trailing day label (used by the Done view: "Mon").
    var dayLabel: ((DashItem) -> String?)? = nil
}

// MARK: – DashboardViewModel
//
// Single source of truth for the redesigned UI. Seeded from AppState's
// published, already-grouped arrays (or from SampleData in DEBUG when there's
// no real data yet). It NEVER reaches into the scrapers/sync and only writes
// back to AppState through its existing public API (markCompleted/markActive).

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var items: [DashItem] = []

    private weak var appState: AppState?
    private(set) var usingSampleData = false
    private var cancellable: AnyCancellable?

    /// Wire up to the environment AppState once and load. Re-pulls whenever
    /// AppState republishes (e.g. a sync lands), preserving session-local
    /// completion/override edits where ids still match.
    func bind(to state: AppState) {
        guard appState == nil else { return }
        appState = state
        // A preview may have pre-seeded sample data; don't clobber it with the
        // (empty) real store.
        if usingSampleData { return }
        reload()
        cancellable = state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.reloadFromRealDataIfNeeded() }
    }

    private func reloadFromRealDataIfNeeded() {
        guard !usingSampleData else { return }
        reload(preservingEdits: true)
    }

    /// Populate from bundled fixtures. Used by SwiftUI previews and by the in-app
    /// Preview mode (reviewer demo). Real usage reads scraped data via `reload()`.
    func loadSampleData() {
        usingSampleData = true
        items = SampleData.items()
    }

    func reload(preservingEdits: Bool = false) {
        guard let state = appState else { return }

        usingSampleData = false
        let priorByID = preservingEdits
            ? Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            : [:]

        var built: [DashItem] = []

        // Active pool: everything AppState surfaces as incomplete.
        let active = state.assignments + state.laterAssignments + state.assessments
        for a in active {
            let prior = priorByID[a.assignmentID]
            built.append(DashItem(assignment: a,
                                  dueOverride: prior?.dueOverride,
                                  isCompleted: false,
                                  completedAt: nil))
        }

        // Completed pool: reconstruct from every source feed, since the grouped
        // arrays exclude completed items. Completion time comes from AppState's
        // persisted map (so completed work survives relaunch); a prior session
        // timestamp is the fallback for the current run.
        let pool = state.canvasItems + state.gradescopeItems + state.manualAssignments.map { $0.asAssignment() }
        var seen = Set(active.map { $0.id })
        // Respect the class picker here too, so a hidden course's completed work
        // doesn't linger on the Done tab after the user turned the course off.
        for a in pool where state.isCompleted(a) && !seen.contains(a.id) && state.isCourseSelected(a.course) {
            seen.insert(a.id)
            built.append(DashItem(assignment: a,
                                  dueOverride: priorByID[a.id]?.dueOverride,
                                  isCompleted: true,
                                  completedAt: state.completedAt(a) ?? priorByID[a.id]?.completedAt))
        }

        items = built
    }

    // MARK: Mutations

    func complete(_ item: DashItem) {
        guard let i = index(of: item) else { return }
        items[i].isCompleted = true
        items[i].completedAt = Date()
        if !usingSampleData { appState?.markCompleted(item.assignment) }
    }

    func uncomplete(_ item: DashItem) {
        guard let i = index(of: item) else { return }
        items[i].isCompleted = false
        items[i].completedAt = nil
        if !usingSampleData { appState?.markActive(item.assignment) }
    }

    func setDue(_ item: DashItem, to date: Date?) {
        guard let i = index(of: item) else { return }
        items[i].dueOverride = date
    }

    private func index(of item: DashItem) -> Int? {
        items.firstIndex { $0.id == item.id }
    }

    // MARK: Derived — active sections

    private var activeItems: [DashItem] { items.filter { !$0.isCompleted } }

    /// "This week" = overdue (pinned on top) + everything due in the next 7 days.
    /// Nothing beyond a week out appears here.
    func thisWeekSections(now: Date = Date()) -> [DashSection] {
        timelineSections(now: now, includeOverdue: true, includeLater: false)
    }

    /// "All" = strictly future work through the end of the current term (the pool
    /// is already term-capped). Overdue items live only on the This-week tab.
    func allSections(now: Date = Date()) -> [DashSection] {
        timelineSections(now: now, includeOverdue: false, includeLater: true)
    }

    private func timelineSections(now: Date, includeOverdue: Bool, includeLater: Bool) -> [DashSection] {
        var overdue: [DashItem] = []
        var today: [DashItem] = []
        var rest: [DashItem] = []
        var later: [DashItem] = []

        // Section thresholds are independent of the per-card color tiers:
        // overdue / today (<24h) / rest of week (1–7d) / later (8d+).
        for item in activeItems {
            guard let due = item.due else {
                if includeLater { later.append(item) }   // undated → "later" only
                continue
            }
            let s = due.timeIntervalSince(now)
            if s < 0 {
                overdue.append(item)
            } else if s < 86_400 {
                today.append(item)
            } else if s <= 86_400 * 7 {
                rest.append(item)
            } else {
                later.append(item)
            }
        }

        // Overdue: most-overdue first. Everything else: soonest first.
        let byDueAscending: (DashItem, DashItem) -> Bool = { a, b in
            (a.due ?? .distantFuture) < (b.due ?? .distantFuture)
        }
        overdue.sort(by: byDueAscending)
        today.sort(by: byDueAscending)
        rest.sort(by: byDueAscending)
        later.sort(by: byDueAscending)

        var sections: [DashSection] = []
        if includeOverdue && !overdue.isEmpty {
            sections.append(.init(id: "overdue", label: "OVERDUE",
                                  labelColor: .v2SpineRed, items: overdue))
        }
        if !today.isEmpty {
            sections.append(.init(id: "today", label: "TODAY",
                                  labelColor: .v2SectionMuted, items: today))
        }
        if !rest.isEmpty {
            sections.append(.init(id: "rest", label: includeLater ? "THIS WEEK" : "REST OF WEEK",
                                  labelColor: .v2SectionMuted, items: rest))
        }
        if includeLater && !later.isEmpty {
            sections.append(.init(id: "later", label: "LATER",
                                  labelColor: .v2SectionMuted, items: later))
        }
        return sections
    }

    // MARK: Derived — done sections

    /// Done tab: everything finished this week up top, then (on scroll) everything
    /// finished earlier this semester. Placement uses the persisted completion
    /// time, falling back to the due date for items completed before timestamps
    /// were tracked — so completed work is never dropped.
    func doneSections(now: Date = Date()) -> [DashSection] {
        let completed = items.filter { $0.isCompleted }
        let cal = Calendar.current
        let semesterStart = Term(date: now).startDate()

        func placed(_ item: DashItem) -> Date? { item.completedAt ?? item.due }
        let newestFirst: (DashItem, DashItem) -> Bool = {
            (placed($0) ?? .distantPast) > (placed($1) ?? .distantPast)
        }

        let thisWeek = completed
            .filter { placed($0).map { isSameWeek($0, now, cal) } ?? false }
            .sorted(by: newestFirst)

        let thisWeekIDs = Set(thisWeek.map(\.id))
        let semester = completed
            .filter { !thisWeekIDs.contains($0.id) }
            // Keep the current term (plus any item whose date we can't place, so
            // it still shows) and drop older leftovers.
            .filter { item in placed(item).map { $0 >= semesterStart } ?? true }
            .sorted(by: newestFirst)

        // Weekday for this week ("Mon"); month/day for older items ("Apr 3").
        let weekdayLabel: (DashItem) -> String? = { item in
            placed(item).map { Self.string($0, "EEE") }
        }
        let dateLabel: (DashItem) -> String? = { item in
            placed(item).map { Self.string($0, "MMM d") }
        }

        var sections: [DashSection] = []
        if !thisWeek.isEmpty {
            sections.append(.init(id: "doneWeek", label: "THIS WEEK",
                                  labelColor: .v2SectionMuted, items: thisWeek,
                                  dayLabel: weekdayLabel))
        }
        if !semester.isEmpty {
            sections.append(.init(id: "doneSemester", label: "EARLIER THIS SEMESTER",
                                  labelColor: .v2SectionMuted, items: semester,
                                  dayLabel: dateLabel))
        }
        return sections
    }

    private static func string(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.dateFormat = format
        return f.string(from: date)
    }

    // MARK: Derived — weekly progress ring

    /// (completed this week, total this week). Overdue items are excluded from
    /// "this week" — the ring reflects the planned weekly load, not arrears.
    func weeklyProgress(now: Date = Date()) -> (done: Int, total: Int) {
        let cal = Calendar.current
        let weekEnd = now.addingTimeInterval(7 * 86_400)

        // Only items with a real completion timestamp in this week count. (Don't
        // fall back to `now`: source-`submitted` items — e.g. Gradescope — carry
        // no timestamp and would otherwise inflate the ring to the whole term's
        // submitted work, every week.)
        let doneThisWeek = items.filter {
            guard $0.isCompleted, let completedAt = $0.completedAt else { return false }
            return isSameWeek(completedAt, now, cal)
        }.count

        let dueThisWeek = items.filter {
            guard !$0.isCompleted, let d = $0.due else { return false }
            return d >= now && d <= weekEnd
        }.count

        return (doneThisWeek, doneThisWeek + dueThisWeek)
    }

    // MARK: Date helpers

    private func isSameWeek(_ a: Date, _ b: Date, _ cal: Calendar) -> Bool {
        cal.isDate(a, equalTo: b, toGranularity: .weekOfYear)
    }
}

private extension Assignment {
    var assignmentID: String { id }
}
