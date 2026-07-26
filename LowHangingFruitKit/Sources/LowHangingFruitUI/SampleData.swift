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

    // MARK: - Grade Watcher fixtures (preview mode)

    /// Synthetic Canvas course ids for the sample courses, `id -> course code`
    /// (the shape `AppState.canvasCourseIDs()` returns).
    ///
    /// These are deliberately **never persisted** into
    /// `canvasCourseIDsByCode`: a leftover "CIS 1210 → 900001" mapping would
    /// outlive preview mode and send a real Grade Watcher refresh at a course
    /// id that doesn't exist on the user's Canvas. `AppState` substitutes this
    /// map in-memory while `isPreviewMode` is on instead.
    static let previewCourseIDsByID: [String: String] = [
        "900001": "CIS 1210",
        "900002": "ECON 1",
        "900003": "MGMT 1010",
        "900004": "MEAM 1010",
        "900005": "PSYC 1",
    ]

    /// Fully-formed grade snapshots for preview mode — the same type
    /// `CanvasGradesClient.fetchSnapshot` returns, so Grade Watcher, the grade
    /// report, and the projection math all run their real code paths against
    /// them. Covers the interesting shapes on purpose: weighted and points
    /// mode, a drop-lowest category, an ungraded future category, extra
    /// credit, an excused item, and past-due-unscored work.
    static func gradeSnapshots(now: Date = Date()) -> [String: CourseGradeSnapshot] {
        func days(_ d: Double) -> Date { now.addingTimeInterval(d * 86_400) }

        func item(_ id: String, _ name: String, _ possible: Double, _ score: Double?,
                  due: Date? = nil, excused: Bool = false) -> GradeItem {
            GradeItem(id: id, name: name, pointsPossible: possible, score: score,
                      scoreSource: score != nil ? .canvas : nil,
                      isExcused: excused, omitFromFinalGrade: false, dueAt: due)
        }

        // CIS 1210 — weighted, drop-lowest homework, final not yet taken.
        let cis = CourseGradeSnapshot(
            courseID: "900001",
            courseUsesWeights: true,
            categories: [
                GradeCategory(id: "c1-hw", name: "Problem Sets", weight: 40, dropLowest: 1, items: [
                    item("i1", "PSet 1: recursion",       100, 94, due: days(-30)),
                    item("i2", "PSet 2: sorting",         100, 88, due: days(-23)),
                    item("i3", "PSet 3: heaps",           100, 71, due: days(-16)),
                    item("i4", "PSet 4: dynamic programming", 100, 96, due: days(-9)),
                    item("i5", "PSet 5: graph algorithms", 100, nil, due: days(-2)),
                    item("i6", "PSet 6: hashing",         100, nil, due: days(3)),
                ]),
                GradeCategory(id: "c1-mid", name: "Midterm", weight: 25, items: [
                    item("i7", "Midterm exam", 100, 89, due: days(-12)),
                ]),
                GradeCategory(id: "c1-final", name: "Final", weight: 25, items: [
                    item("i8", "Final exam", 100, nil, due: days(28)),
                ]),
                GradeCategory(id: "c1-part", name: "Participation", weight: 10, items: [
                    item("i9", "Recitation worksheet", 10, 10, due: days(-5)),
                    item("i10", "Final project checkpoint", 10, nil, due: days(9)),
                ]),
            ],
            // Matches what the engine computes, so the demo doesn't flag a
            // disagreement on every card. MEAM below keeps a real 1.2-point
            // gap so the "differs from Canvas" treatment is still visible.
            canvasComputedCurrentScore: 92.4,
            submissions: [],
            fetchedAt: now
        )

        // ECON 1 — points mode (no weights at all): the case where manual or
        // syllabus weights are the only way to get a weighted grade.
        let econ = CourseGradeSnapshot(
            courseID: "900002",
            courseUsesWeights: false,
            categories: [
                GradeCategory(id: "c2-all", name: "Assignments", weight: nil, items: [
                    item("i11", "Problem set 1", 50, 46, due: days(-28)),
                    item("i12", "Problem set 2", 50, 43, due: days(-21)),
                    item("i13", "Quiz 1",        25, 22, due: days(-14)),
                    item("i14", "Midterm",      150, 129, due: days(-7)),
                    item("i15", "Problem set 3", 50, nil, due: days(0)),
                    item("i16", "Midterm study guide", 25, nil, due: days(4)),
                    item("i17", "Final",        200, nil, due: days(30)),
                ]),
            ],
            canvasComputedCurrentScore: 87.3,
            submissions: [],
            fetchedAt: now
        )

        // MGMT 1010 — weighted, with an excused item and an extra-credit item.
        let mgmt = CourseGradeSnapshot(
            courseID: "900003",
            courseUsesWeights: true,
            categories: [
                GradeCategory(id: "c3-resp", name: "Reading Responses", weight: 20, items: [
                    item("i18", "Reading response 5", 10, 9, due: days(-14)),
                    item("i19", "Reading response 6", 10, nil, due: days(-7), excused: true),
                    item("i20", "Reading response 7", 10, nil, due: days(0)),
                ]),
                GradeCategory(id: "c3-case", name: "Case Writeups", weight: 50, items: [
                    item("i21", "Case 1", 100, 92, due: days(-20)),
                    item("i22", "Group case writeup", 100, nil, due: days(5)),
                ]),
                GradeCategory(id: "c3-final", name: "Final Paper", weight: 30, items: [
                    item("i23", "Final paper", 100, nil, due: days(26)),
                ]),
                GradeCategory(id: "c3-ec", name: "Extra Credit", weight: 0, items: [
                    item("i24", "Optional seminar writeup", 0, 3, due: days(-3)),
                ]),
            ],
            canvasComputedCurrentScore: nil,   // professor hides totals
            submissions: [],
            fetchedAt: now
        )

        // MEAM 1010 — weighted, with past-due unscored work (pending grading).
        let meam = CourseGradeSnapshot(
            courseID: "900004",
            courseUsesWeights: true,
            categories: [
                GradeCategory(id: "c4-lab", name: "Lab Reports", weight: 60, items: [
                    item("i25", "Lab report 1", 100, 84, due: days(-24)),
                    item("i26", "Lab report 2", 100, 90, due: days(-17)),
                    item("i27", "Lab report 3", 100, nil, due: days(-6)),   // pending
                    item("i28", "Lab report 4", 100, nil, due: days(2)),
                ]),
                GradeCategory(id: "c4-exam", name: "Exams", weight: 40, items: [
                    item("i29", "Exam 1", 100, 78, due: days(-11)),
                    item("i30", "Exam 2", 100, nil, due: days(20)),
                ]),
            ],
            canvasComputedCurrentScore: 84.6,
            submissions: [],
            fetchedAt: now
        )

        // PSYC 1 — weighted, mostly graded, comfortably strong.
        let psyc = CourseGradeSnapshot(
            courseID: "900005",
            courseUsesWeights: true,
            categories: [
                GradeCategory(id: "c5-quiz", name: "Weekly Quizzes", weight: 30, dropLowest: 1, items: [
                    item("i31", "Reading quiz 3", 20, 19, due: days(-25)),
                    item("i32", "Weekly quiz 6",  20, 15, due: days(-18)),
                    item("i33", "Weekly quiz 7",  20, 20, due: days(-11)),
                    item("i34", "Weekly quiz 8",  20, 18, due: days(-4)),
                ]),
                GradeCategory(id: "c5-mid", name: "Midterms", weight: 40, items: [
                    item("i35", "Midterm 1", 100, 95, due: days(-20)),
                    item("i36", "Midterm 2", 100, 91, due: days(-6)),
                ]),
                GradeCategory(id: "c5-final", name: "Final", weight: 30, items: [
                    item("i37", "Final exam", 100, nil, due: days(27)),
                ]),
            ],
            canvasComputedCurrentScore: 93.9,
            submissions: [],
            fetchedAt: now
        )

        return [
            cis.courseID: cis,
            econ.courseID: econ,
            mgmt.courseID: mgmt,
            meam.courseID: meam,
            psyc.courseID: psyc,
        ]
    }
}
