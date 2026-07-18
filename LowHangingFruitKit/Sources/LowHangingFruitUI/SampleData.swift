import Foundation
import LowHangingFruitKit

/// Hardcoded fixtures used by (1) SwiftUI previews / offline UI work and (2) the
/// in-app **Preview mode** an App Store reviewer taps on the onboarding screen —
/// no scrapers, no login, no network. Populates every section richly (2 overdue,
/// 2 due today, 4 rest-of-week, 2 later, 4 completed this week, 2 completed
/// earlier this semester) so the full design is visible without a Canvas account.
enum SampleData {
    static func items(now: Date = Date()) -> [DashItem] {
        let cal = Calendar.current
        func hrs(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }
        func days(_ d: Double) -> Date { now.addingTimeInterval(d * 86_400) }

        // Completion timestamps, clamped so they always land in-week / today
        // regardless of the actual weekday the demo is run on.
        let startToday = cal.startOfDay(for: now)
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? startToday
        let doneA = max(startToday, hrs(-2))                                   // today
        let doneB = max(startToday, hrs(-5))                                   // today
        let dayBefore = cal.date(byAdding: .day, value: -1, to: startToday) ?? startToday
        let twoDaysBefore = cal.date(byAdding: .day, value: -2, to: startToday) ?? startToday
        let earlierA = max(weekStart, dayBefore).addingTimeInterval(14 * 3600)  // earlier this week
        let earlierB = max(weekStart, twoDaysBefore).addingTimeInterval(11 * 3600)

        // Earlier this semester — fills the Done tab's scroll-down history.
        // Clamped to sit inside the current term but before this week.
        let semesterStart = Term(date: now).startDate()
        let beforeThisWeek = weekStart.addingTimeInterval(-2 * 86_400)
        func inSemester(daysAgo: Int) -> Date {
            let target = cal.date(byAdding: .day, value: -daysAgo, to: startToday) ?? startToday
            return max(semesterStart, min(target, beforeThisWeek)).addingTimeInterval(13 * 3600)
        }
        let semesterA = inSemester(daysAgo: 18)
        let semesterB = inSemester(daysAgo: 25)

        func active(_ source: Assignment.Source, _ id: String, _ course: String,
                    _ title: String, due: Date) -> DashItem {
            DashItem(assignment: Assignment(source: source, sourceID: id, kind: .assignment,
                                            course: course, title: title, dueAt: due, url: nil),
                     dueOverride: nil, isCompleted: false, completedAt: nil)
        }

        func done(_ source: Assignment.Source, _ id: String, _ course: String,
                  _ title: String, at completed: Date) -> DashItem {
            DashItem(assignment: Assignment(source: source, sourceID: id, kind: .assignment,
                                            course: course, title: title,
                                            dueAt: completed.addingTimeInterval(-3600), url: nil),
                     dueOverride: nil, isCompleted: true, completedAt: completed)
        }

        return [
            // OVERDUE (red)
            active(.canvas,     "s-1", "CIS 1210",  "PSet 5: graph algorithms", due: days(-2)),
            active(.canvas,     "s-2", "FNAR 3230", "Sketchbook review",        due: days(-4)),
            // TODAY (amber)
            active(.canvas,     "s-3", "ECON 1",    "Problem set 3",            due: hrs(5).addingTimeInterval(1800)),
            active(.canvas,     "s-4", "MGMT 1010", "Reading response 7",       due: hrs(9).addingTimeInterval(1800)),
            // REST OF WEEK (green)
            active(.canvas,     "s-5", "MEAM 1010", "Lab report 4",             due: days(2)),
            active(.canvas,     "s-6", "CIS 1210",  "PSet 6: hashing",          due: days(3)),
            active(.canvas,     "s-7", "ECON 1",    "Midterm study guide",      due: days(4)),
            active(.canvas,     "s-8", "MGMT 1010", "Group case writeup",       due: days(5)),
            // LATER (8+ days out — fills the "All" tab's Later section)
            active(.canvas,     "s-13", "CIS 1210", "Final project checkpoint", due: days(9)),
            active(.canvas,     "s-14", "PHYS 0150", "Lab practical prep",       due: days(12)),
            // DONE — completed today
            done(.canvas,       "s-9",  "PSYC 1",    "Weekly quiz 8",           at: doneA),
            done(.canvas,       "s-10", "CIS 1210",  "Recitation worksheet",    at: doneB),
            // DONE — earlier this week
            done(.canvas,       "s-11", "ECON 1",    "Problem set 2",           at: earlierB),
            done(.canvas,       "s-12", "MEAM 1010", "Lab report 3",            at: earlierA),
            // DONE — earlier this semester (Done tab's scroll-down history)
            done(.canvas,       "s-15", "PSYC 1",    "Reading quiz 3",          at: semesterA),
            done(.gradescope,   "s-16", "CIS 1210",  "PSet 1: recursion",       at: semesterB),
        ]
    }
}
