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

    #if DEBUG
    /// Preview-only: populate from bundled fixtures. The running app never calls
    /// this — it always reads real scraped data via `reload()`.
    func loadSampleData() {
        usingSampleData = true
        items = SampleData.items()
    }
    #endif

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

        // Completed pool: reconstruct from the source feeds, since the grouped
        // arrays exclude completed items. Completion time isn't tracked by the
        // model, so reuse a prior session timestamp if we have one.
        let pool = state.canvasItems + state.gradescopeAssignments
        var seen = Set(active.map { $0.id })
        for a in pool where state.isCompleted(a) && !seen.contains(a.id) {
            seen.insert(a.id)
            built.append(DashItem(assignment: a,
                                  dueOverride: priorByID[a.id]?.dueOverride,
                                  isCompleted: true,
                                  completedAt: priorByID[a.id]?.completedAt))
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

    /// "This week" = overdue + due within 7 days, in three sections.
    func thisWeekSections(now: Date = Date()) -> [DashSection] {
        timelineSections(now: now, includeLater: false)
    }

    /// "All" = the same three sections plus a LATER bucket (8+ days out).
    func allSections(now: Date = Date()) -> [DashSection] {
        timelineSections(now: now, includeLater: true)
    }

    private func timelineSections(now: Date, includeLater: Bool) -> [DashSection] {
        var overdue: [DashItem] = []
        var today: [DashItem] = []
        var rest: [DashItem] = []
        var later: [DashItem] = []

        // Section thresholds are independent of the per-card color tiers:
        // overdue / today (<24h) / rest of week (1–7d) / later (8d+).
        for item in activeItems {
            guard let due = item.due else { later.append(item); continue }
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
        if !overdue.isEmpty {
            sections.append(.init(id: "overdue", label: "OVERDUE",
                                  labelColor: .v2SpineRed, items: overdue))
        }
        if !today.isEmpty {
            sections.append(.init(id: "today", label: "TODAY",
                                  labelColor: .v2SectionMuted, items: today))
        }
        if !rest.isEmpty {
            sections.append(.init(id: "rest", label: "REST OF WEEK",
                                  labelColor: .v2SectionMuted, items: rest))
        }
        if includeLater && !later.isEmpty {
            sections.append(.init(id: "later", label: "LATER",
                                  labelColor: .v2SectionMuted, items: later))
        }
        return sections
    }

    // MARK: Derived — done sections

    func doneSections(now: Date = Date()) -> [DashSection] {
        let completed = items.filter { $0.isCompleted }
        let cal = Calendar.current

        let todayItems = completed
            .filter { isSameDay($0.completedAt, now, cal) }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }

        let earlierItems = completed
            .filter { item in
                guard let c = item.completedAt else { return false }
                return !isSameDay(c, now, cal) && isSameWeek(c, now, cal)
            }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }

        let dayLabel: (DashItem) -> String? = { item in
            guard let c = item.completedAt else { return nil }
            let f = DateFormatter()
            f.dateFormat = "EEE"          // "Mon", "Sun"
            return f.string(from: c)
        }

        var sections: [DashSection] = []
        if !todayItems.isEmpty {
            sections.append(.init(id: "doneToday", label: "COMPLETED TODAY",
                                  labelColor: .v2SectionMuted, items: todayItems))
        }
        if !earlierItems.isEmpty {
            sections.append(.init(id: "doneEarlier", label: "EARLIER THIS WEEK",
                                  labelColor: .v2SectionMuted, items: earlierItems,
                                  dayLabel: dayLabel))
        }
        return sections
    }

    // MARK: Derived — weekly progress ring

    /// (completed this week, total this week). Overdue items are excluded from
    /// "this week" — the ring reflects the planned weekly load, not arrears.
    func weeklyProgress(now: Date = Date()) -> (done: Int, total: Int) {
        let cal = Calendar.current
        let weekEnd = now.addingTimeInterval(7 * 86_400)

        let doneThisWeek = items.filter {
            $0.isCompleted && isSameWeek($0.completedAt ?? now, now, cal)
        }.count

        let dueThisWeek = items.filter {
            guard !$0.isCompleted, let d = $0.due else { return false }
            return d >= now && d <= weekEnd
        }.count

        return (doneThisWeek, doneThisWeek + dueThisWeek)
    }

    // MARK: Date helpers

    private func isSameDay(_ a: Date?, _ b: Date, _ cal: Calendar) -> Bool {
        guard let a else { return false }
        return cal.isDate(a, inSameDayAs: b)
    }

    private func isSameWeek(_ a: Date, _ b: Date, _ cal: Calendar) -> Bool {
        cal.isDate(a, equalTo: b, toGranularity: .weekOfYear)
    }
}

private extension Assignment {
    var assignmentID: String { id }
}
