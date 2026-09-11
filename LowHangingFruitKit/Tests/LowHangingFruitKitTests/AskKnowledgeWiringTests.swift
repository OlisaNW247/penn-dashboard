import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// How the knowledge engine plugs into Marco's `ask`: the no-backend
/// responder streams a grounded answer with citations, and the backend
/// responder sends retrieved passages as a separate request field, after the
/// cache breakpoint, without disturbing the cached document.
@Suite("Ask knowledge wiring")
struct AskKnowledgeWiringTests {
    private static var context: AssistantContext {
        AssistantContext(
            courseCodes: AssistantFixture.courses.map(\.code),
            contextDocument: "doc",
            askedAt: AssistantFixture.now,
            knowledge: AssistantFixture.knowledge,
            work: AssistantFixture.items,
            userName: "Olisa"
        )
    }

    private static func collect(_ stream: AsyncStream<AssistantChunk>) async -> (text: String, citations: [AssistantCitation]) {
        var text = ""
        var citations: [AssistantCitation] = []
        for await chunk in stream {
            switch chunk {
            case let .text(piece): text += piece
            case let .citations(list): citations = list
            }
        }
        return (text, citations)
    }

    @Test("on-device responder streams an exact answer with no network")
    func onDeviceExact() async {
        let responder = OnDeviceAssistantResponder(wordDelay: 0)
        let result = await Self.collect(responder.reply(to: "What's due this week?", context: Self.context))
        #expect(result.text.hasPrefix("4 things due in the next 7 days:"))
        #expect(result.text.contains("PSet 3: caches"))
    }

    @Test("on-device responder cites the syllabus it quoted")
    func onDeviceCitations() async {
        let responder = OnDeviceAssistantResponder(wordDelay: 0)
        let result = await Self.collect(responder.reply(to: "What's the late policy in CIS 2400?", context: Self.context))
        #expect(result.text.contains("three late days"))
        #expect(result.citations.first?.course == "CIS 2400")
        #expect(result.citations.first?.source == "syllabus")
        #expect(result.citations.first?.detail == "CIS 2400 syllabus")
    }

    @Test("backend request carries retrieved excerpts as a field separate from the cached document")
    func backendExcerpts() {
        let request = BackendAssistantResponder.makeRequest(question: "What's the late policy in CIS 2400?", context: Self.context)
        #expect(request.contextDocument == "doc")   // untouched cache prefix
        #expect(request.askedAt == AssistantFixture.now)
        #expect(request.excerpts.contains("three late days"))
        #expect(!request.excerpts.contains("ECON 1 syllabus"))   // course filter applied
    }

    @Test("excerpts field is empty when nothing is synced")
    func backendNoExcerpts() {
        let context = AssistantContext(courseCodes: ["PHYS 0151"], contextDocument: "doc", askedAt: AssistantFixture.now)
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "attendance policy", context: context)
        #expect(excerpts.isEmpty)
    }

    @Test("question and excerpts travel as separate request fields; the server joins them")
    func questionAndExcerptsAreSeparateFields() {
        let request = BackendAssistantResponder.makeRequest(question: "What's the late policy in CIS 2400?", context: Self.context)
        #expect(request.question == "What's the late policy in CIS 2400?")
        #expect(!request.question.contains("RETRIEVED EXCERPTS"))
        #expect(!request.excerpts.contains("QUESTION:"))
    }

    @Test("sample knowledge answers the flagship policy question in preview mode")
    func sampleKnowledge() {
        let knowledge = SampleData.knowledge()
        let items = SampleData.items().map { WorkItem(assignment: $0.assignment, isCompleted: $0.isCompleted, dueOverride: $0.dueOverride) }
        let context = AskKnowledgeContext(items: items, knowledge: knowledge)
        let answer = ClassQuestionAnswerer(context: context).answer("what's my cis attendance policy?")
        #expect(answer.text.contains("two absences are free"))
        #expect(answer.sources.first?.title == "CIS 1210 syllabus")
    }
}

/// Penn runs PHYS 0151 as two Canvas *sites* — a lecture site and a lab site
/// — that both parse to the course code "PHYS 0151" (`CourseCode.parse`
/// deliberately drops the section number). `AppState.canvasCourseSummaries()`
/// exists because `refreshCourseKnowledge` used to build its course list from
/// `canvasCourseIDsByCode`, a `[code: id]` cache that can only remember one
/// id per code, so materials sync only ever pulled one of the two sites.
///
/// `AppState` persists into the process-wide `UserDefaults.lhf`
/// (`enrolledCanvasCoursesV1` and `CoursePreferencesStore.storageKey`), so —
/// exactly like `AnnouncementWatcherWiringTests` — this suite is
/// `.serialized`, `@MainActor` (`AppState` itself is `@MainActor`), and backs
/// up/restores every key it touches.
@MainActor
@Suite("Canvas course summaries span both sites of a split course", .serialized)
struct CanvasCourseSummariesTests {
    private static let enrolledCanvasCoursesKey = "enrolledCanvasCoursesV1"

    /// Snapshots the two process-wide keys this suite writes, runs `body`,
    /// then restores them exactly as found (`nil` meaning "the key was
    /// absent," restored by removing it) — mirrors
    /// `AnnouncementWatcherWiringTests.withRestoredDefaults`.
    private func withRestoredDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.lhf
        let keys = [Self.enrolledCanvasCoursesKey, CoursePreferencesStore.storageKey]
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
        body()
    }

    /// Seeds both storage tiers `canvasCourseSummaries()` reads through
    /// `canvasCourseIDs()`: the enrolled-course cache (both sites, by id) and
    /// `canvasCourseIDsByCode` (one id — the lecture site's, "1" — the same
    /// way onboarding/Grade Watcher would have cached whichever site it saw
    /// first). `canvasCourseIDs()`'s merge rule then recovers the lab site's
    /// id "2" from the enrolled list because its parsed code, "PHYS 0151",
    /// already matches something the cache vouched for — see
    /// `AppState.courseIDsByID`'s doc comment.
    private func seedTwoSitesOneCode() {
        // Start from an empty preferences blob. `setCanvasCourseID` MERGES into
        // whatever is already stored, and other suites leave course→id entries
        // behind under small ids like "1" — on the first Mac run one of those
        // mapped id "1" to a different code, dictionary order put it first in
        // `courseIDsByID`'s cache pass, the PHYS entry was skipped as a
        // duplicate id, and the lab site was then never recognised. The key
        // is restored by `withRestoredDefaults` afterwards.
        UserDefaults.lhf.removeObject(forKey: CoursePreferencesStore.storageKey)
        UserDefaults.lhf.set(
            [
                Self.lectureSiteID: "PHYS 0151-401 202630 Principles II",
                Self.labSiteID: "PHYS 0151-151 202630 Principles II Lab",
            ],
            forKey: Self.enrolledCanvasCoursesKey
        )
        CoursePreferencesStore().setCanvasCourseID("PHYS 0151", Self.lectureSiteID)
    }

    /// Real-looking Canvas ids, chosen so no other suite's fixture can collide
    /// with them in the shared defaults.
    private static let lectureSiteID = "1946718"
    private static let labSiteID = "1946719"

    @Test("two Canvas sites sharing one course code yield two summaries, not one")
    func twoSitesYieldTwoSummaries() {
        withRestoredDefaults {
            seedTwoSitesOneCode()
            let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))

            let summaries = state.canvasCourseSummaries()
            #expect(summaries.count == 2)
            #expect(summaries.allSatisfy { $0.code == "PHYS 0151" })
            #expect(Set(summaries.map(\.courseID)) == [Self.lectureSiteID, Self.labSiteID])
        }
    }

    @Test("each site's section is derived from its own Canvas name, not shared across the split code")
    func sitesHaveDistinctSections() {
        withRestoredDefaults {
            seedTwoSitesOneCode()
            let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))

            let summaries = state.canvasCourseSummaries()
            let lecture = summaries.first { $0.courseID == Self.lectureSiteID }
            let lab = summaries.first { $0.courseID == Self.labSiteID }
            #expect(lecture?.section == "401")
            #expect(lab?.section == "151")
        }
    }

    @Test("the raw Canvas name is carried, not the cosmetic display name, so the lab site keeps its 'Lab' text")
    func rawNamesAreCarried() {
        withRestoredDefaults {
            seedTwoSitesOneCode()
            let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))

            let summaries = state.canvasCourseSummaries()
            let lecture = summaries.first { $0.courseID == Self.lectureSiteID }
            let lab = summaries.first { $0.courseID == Self.labSiteID }
            #expect(lecture?.name == "PHYS 0151-401 202630 Principles II")
            #expect(lab?.name == "PHYS 0151-151 202630 Principles II Lab")
        }
    }
}
