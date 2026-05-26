import Foundation
import PennDashboardKit

#if DEBUG
enum SampleData {
    static var assignments: [Assignment] {
        let now = Date()
        func d(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }
        return [
            // Past due — Ruby Red
            Assignment(source: .canvas,     sourceID: "sample-1",  kind: .assignment,
                       course: "MATH 1410", title: "Problem Set 3: Integration",
                       dueAt: d(-72), url: nil),
            Assignment(source: .canvas,     sourceID: "sample-2",  kind: .assignment,
                       course: "ECON 1",    title: "Reading Response: Supply & Demand",
                       dueAt: d(-24), url: nil),
            // Urgent — Amber Earth (<24 h)
            Assignment(source: .canvas,     sourceID: "sample-3",  kind: .assignment,
                       course: "CIS 1210",  title: "PSet 5: Graph Algorithms",
                       dueAt: d(5), url: nil),
            Assignment(source: .gradescope, sourceID: "sample-4",  kind: .assignment,
                       course: "MEAM 1010", title: "Lab Report 4",
                       dueAt: d(18), url: nil),
            // Upcoming — Cornflower Ocean (2–3 days)
            Assignment(source: .canvas,     sourceID: "sample-5",  kind: .assignment,
                       course: "FNAR 3230", title: "Sketchbook Review",
                       dueAt: d(48), url: nil),
            Assignment(source: .canvas,     sourceID: "sample-6",  kind: .assignment,
                       course: "MGMT 1010", title: "Case Analysis: Netflix Strategy",
                       dueAt: d(60), url: nil),
            Assignment(source: .canvas,     sourceID: "sample-7",  kind: .assignment,
                       course: "CIS 1210",  title: "PSet 6: Dynamic Programming",
                       dueAt: d(72), url: nil),
            // Future — Seagrass (4+ days)
            Assignment(source: .canvas,     sourceID: "sample-8",  kind: .assignment,
                       course: "ECON 1",    title: "Midterm Review Sheet",
                       dueAt: d(120), url: nil),
            Assignment(source: .canvas,     sourceID: "sample-9",  kind: .assignment,
                       course: "MEAM 1010", title: "Design Report: Truss Bridge",
                       dueAt: d(168), url: nil),
            Assignment(source: .gradescope, sourceID: "sample-10", kind: .assignment,
                       course: "FNAR 3230", title: "Final Portfolio Draft",
                       dueAt: d(240), url: nil),
            Assignment(source: .canvas,     sourceID: "sample-11", kind: .assignment,
                       course: "MGMT 1010", title: "Group Presentation Slides",
                       dueAt: d(336), url: nil),
        ]
    }
}
#endif
