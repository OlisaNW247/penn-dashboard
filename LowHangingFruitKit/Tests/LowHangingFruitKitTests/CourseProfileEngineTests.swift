import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Course profile engine")
struct CourseProfileEngineTests {
    // Synthetic fixtures only — no real Canvas ids, course names, or tokens.

    private func item(
        course: String,
        kind: Assignment.Kind,
        dueAt: Date?,
        id: String = UUID().uuidString
    ) -> Assignment {
        Assignment(
            source: .canvas,
            sourceID: id,
            kind: kind,
            course: course,
            title: "Item \(id)",
            dueAt: dueAt,
            url: nil
        )
    }

    private func date(_ dayOffset: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(dayOffset) * 86_400)
    }

    @Test("a course with at least one assignment or quiz is normal")
    func mixedCourseIsNormal() throws {
        let items = [
            item(course: "CIS 2400", kind: .assignment, dueAt: date(1)),
            item(course: "CIS 2400", kind: .event, dueAt: date(2)),
        ]
        let enrolled = [CanvasCourseDiscoveryParser.Course(id: "111", name: "CIS 2400 Operating Systems")]

        let reports = CourseProfileEngine.reports(feedItems: items, enrolledCourses: enrolled, probes: [:])

        let report = try #require(reports.first { $0.courseKey == "CIS 2400" })
        #expect(report.profile == .normal)
        #expect(report.fingerprint == "normal")
        #expect(report.canvasCourseID == "111")
    }

    @Test("an events-only course is readingsOnCalendar with the right count and latest date")
    func eventsOnlyIsReadingsOnCalendar() throws {
        let items = [
            item(course: "LGST 9999", kind: .event, dueAt: date(1)),
            item(course: "LGST 9999", kind: .event, dueAt: date(5)),
            item(course: "LGST 9999", kind: .event, dueAt: date(3)),
        ]

        let reports = CourseProfileEngine.reports(feedItems: items, enrolledCourses: [], probes: [:])

        let report = try #require(reports.first { $0.courseKey == "LGST 9999" })
        #expect(report.profile == .readingsOnCalendar(eventCount: 3, latestDate: date(5)))
    }

    @Test("an enrolled course absent from the feed is silent when a probe exists")
    func enrolledAbsentFromFeedWithProbeIsSilent() throws {
        let enrolled = [CanvasCourseDiscoveryParser.Course(id: "222", name: "PSYC 2999 Synthetic Seminar")]
        let probes = ["222": CourseProbeResult(submittableAssignmentCount: 0, moduleReadingCount: 8)]

        let reports = CourseProfileEngine.reports(feedItems: [], enrolledCourses: enrolled, probes: probes)

        let report = try #require(reports.first { $0.courseKey == "PSYC 2999" })
        #expect(report.profile == .silent(moduleReadingCount: 8))
        #expect(report.canvasCourseID == "222")
    }

    @Test("an enrolled course absent from the feed with no probe is unknownSilent")
    func enrolledAbsentFromFeedWithoutProbeIsUnknownSilent() throws {
        let enrolled = [CanvasCourseDiscoveryParser.Course(id: "333", name: "PSYC 3999 Synthetic Lab")]

        let reports = CourseProfileEngine.reports(feedItems: [], enrolledCourses: enrolled, probes: [:])

        let report = try #require(reports.first { $0.courseKey == "PSYC 3999" })
        #expect(report.profile == .unknownSilent)
        #expect(report.fingerprint == "unknownSilent")
    }

    @Test("(unknown course) items are ignored entirely")
    func unknownCourseIsIgnored() {
        let items = [item(course: "(unknown course)", kind: .event, dueAt: date(1))]

        let reports = CourseProfileEngine.reports(feedItems: items, enrolledCourses: [], probes: [:])

        #expect(reports.isEmpty)
        #expect(!reports.contains { $0.courseKey == "(unknown course)" })
    }

    @Test("fingerprint is stable under a small count wobble within the same bucket")
    func fingerprintStableWithinBucket() throws {
        // 11 and 13 both floor-bucket to 10, so a professor adding one
        // reading (or a recount landing a couple off) shouldn't re-trigger
        // an ask the user already answered.
        func readingsFingerprint(count: Int) throws -> String {
            let items = (0..<count).map { i in
                item(course: "LGST 9999", kind: .event, dueAt: date(i), id: "e\(i)")
            }
            let reports = CourseProfileEngine.reports(feedItems: items, enrolledCourses: [], probes: [:])
            return try #require(reports.first { $0.courseKey == "LGST 9999" }).fingerprint
        }

        #expect(try readingsFingerprint(count: 11) == readingsFingerprint(count: 13))
        // A jump into the next bucket (15) is allowed to differ.
        #expect(try readingsFingerprint(count: 11) != readingsFingerprint(count: 15))
    }
}
