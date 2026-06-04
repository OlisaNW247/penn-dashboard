import Foundation
import LowHangingFruitKit

#if DEBUG
/// Hardcoded fixtures for SwiftUI previews and offline UI work — no scrapers,
/// no login, no network. Populates every section richly (2 overdue, 2 due
/// today, 4 rest-of-week, 4 completed) so the full design is visible on first
/// launch. Completion timestamps are synthesized here because the model
/// doesn't store them. Compiles out of release builds.
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
        let earlierA = max(weekStart, cal.date(byAdding: .day, value: -1, to: startToday)!)
            .addingTimeInterval(14 * 3600)                                     // earlier this week
        let earlierB = max(weekStart, cal.date(byAdding: .day, value: -2, to: startToday)!)
            .addingTimeInterval(11 * 3600)                                     // earlier this week

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
            active(.gradescope, "s-5", "MEAM 1010", "Lab report 4",             due: days(2)),
            active(.canvas,     "s-6", "CIS 1210",  "PSet 6: hashing",          due: days(3)),
            active(.canvas,     "s-7", "ECON 1",    "Midterm study guide",      due: days(4)),
            active(.canvas,     "s-8", "MGMT 1010", "Group case writeup",       due: days(5)),
            // DONE — completed today
            done(.canvas,       "s-9",  "PSYC 1",    "Weekly quiz 8",           at: doneA),
            done(.canvas,       "s-10", "CIS 1210",  "Recitation worksheet",    at: doneB),
            // DONE — earlier this week
            done(.canvas,       "s-11", "ECON 1",    "Problem set 2",           at: earlierB),
            done(.gradescope,   "s-12", "MEAM 1010", "Lab report 3",            at: earlierA),
        ]
    }
}
#endif
