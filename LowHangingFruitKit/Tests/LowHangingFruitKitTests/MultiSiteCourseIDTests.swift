import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Coverage for `AppState.courseIDsByID`, the pure merge behind
/// `canvasCourseIDs()` that fixed a real device's silent Grade Watcher gap: a
/// student enrolled in two Canvas *sites* — a lecture site and a `-402`
/// section site — that both parse to the same course code `"PHYS 0151"`
/// (`CourseCode.parse` deliberately drops the section number). Course
/// identity in this app is keyed by that code, and the persisted Canvas
/// course-id cache (`CoursePreferences.canvasCourseIDsByCode`) is
/// `[code: id]` — one id per code — so every path that filled or read it
/// collapsed the two sites into one, and the submission living in the
/// second site's numeric course id was never fetched. `courseIDsByID`
/// widens only the in-memory *read* the fetch consumes (`[id: code]`,
/// several ids per code allowed) without touching the persisted cache's
/// shape, which other features (readings import, course intel) still
/// legitimately want as one primary id per code. No `AppState` instance,
/// no `UserDefaults` — this is a free function over plain values.
@MainActor
@Suite("Multi-site course id merge (courseIDsByID)")
struct MultiSiteCourseIDTests {
    /// The device case: two enrolled Canvas course sites both keyed to
    /// `"PHYS 0151"`, with only one of the two ids ever having reached the
    /// persisted cache. Both ids must come back mapped to the shared code —
    /// this is exactly what lets `selectedCanvasCourseIDs()` fetch grades
    /// from both sites once the code is selected.
    @Test("two enrolled sites sharing one course code both resolve to that code")
    func twoEnrolledSitesShareOneCode() {
        let result = AppState.courseIDsByID(
            cache: ["PHYS 0151": "1946718"],
            feedCourseIDs: [],
            enrolled: [
                (id: "1946718", key: "PHYS 0151"),
                (id: "1950000", key: "PHYS 0151"),
            ]
        )
        #expect(result["1946718"] == "PHYS 0151")
        #expect(result["1950000"] == "PHYS 0151")
        #expect(result.count == 2)
    }

    @Test("feed items with two different ids for one code both survive")
    func feedItemsWithTwoIDsForOneCodeBothSurvive() {
        let result = AppState.courseIDsByID(
            cache: [:],
            feedCourseIDs: [
                (course: "ACCT 1010", id: "111"),
                (course: "ACCT 1010", id: "222"),
            ],
            enrolled: []
        )
        #expect(result["111"] == "ACCT 1010")
        #expect(result["222"] == "ACCT 1010")
        #expect(result.count == 2)
    }

    @Test("an enrolled entry whose code matches nothing known is not present")
    func enrolledEntryWithUnknownCodeIsExcluded() {
        let result = AppState.courseIDsByID(
            cache: ["ACCT 1010": "111"],
            feedCourseIDs: [],
            enrolled: [(id: "999", key: "CIS 1200")]
        )
        #expect(result["999"] == nil)
        #expect(result.count == 1)
    }

    @Test("an enrolled entry keyed by a raw unknownCourse descriptor is not present")
    func enrolledEntryKeyedByRawDescriptorIsExcluded() {
        let result = AppState.courseIDsByID(
            cache: [:],
            feedCourseIDs: [],
            enrolled: [(id: "999", key: AppState.unknownCourse)]
        )
        #expect(result.isEmpty)
    }

    @Test("a feed pair tagged unknownCourse is not present")
    func feedPairTaggedUnknownCourseIsExcluded() {
        let result = AppState.courseIDsByID(
            cache: [:],
            feedCourseIDs: [(course: AppState.unknownCourse, id: "999")],
            enrolled: []
        )
        #expect(result.isEmpty)
    }

    @Test("the same id under two codes: the cache's code wins")
    func sameIDUnderTwoCodesCacheWins() {
        let result = AppState.courseIDsByID(
            cache: ["ACCT 1010": "111"],
            feedCourseIDs: [(course: "ACCT 1011", id: "111")],
            enrolled: [(id: "111", key: "ACCT 1012")]
        )
        #expect(result["111"] == "ACCT 1010")
        #expect(result.count == 1)
    }

    @Test("empty inputs produce an empty result")
    func emptyInputsProduceEmptyResult() {
        let result = AppState.courseIDsByID(cache: [:], feedCourseIDs: [], enrolled: [])
        #expect(result.isEmpty)
    }

    @Test("existing single-site behaviour is preserved: cache alone inverts cleanly")
    func existingSingleSiteBehaviorPreserved() {
        let result = AppState.courseIDsByID(
            cache: ["ACCT 1010": "1946774"],
            feedCourseIDs: [],
            enrolled: []
        )
        #expect(result == ["1946774": "ACCT 1010"])
    }
}
