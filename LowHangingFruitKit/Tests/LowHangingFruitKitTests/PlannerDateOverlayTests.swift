import Foundation
import Testing
@testable import LowHangingFruitKit

/// Fixture-based decoding + overlay tests for the Canvas Planner API date
/// source (see `CanvasModulesClient.fetchPlannerDates`,
/// `CanvasModulesClient.overlayDates`). No network calls — everything here
/// drives the pure, network-free seams the same way `CanvasModulesClientTests`
/// exercises `moduleItems(fromPages:)` (see docs/READINGS_COURSES_PLAN.md).
@Suite("Planner date overlay")
struct PlannerDateOverlayTests {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func iso(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
    }

    // MARK: - plannerDatedItems(fromPages:courseID:)

    @Test("Planner items decode plannable_type, plannable.id, and plannable_date")
    func decodesPlannerItems() {
        let json = """
        [
          {
            "course_id": 1234,
            "plannable_type": "wiki_page",
            "plannable_date": "2026-09-10T15:00:00Z",
            "plannable": {"id": 5555}
          }
        ]
        """
        let items = CanvasModulesClient.plannerDatedItems(fromPages: [data(json)], courseID: "1234")
        #expect(items.count == 1)
        #expect(items[0].plannableType == "wiki_page")
        #expect(items[0].plannableID == "5555")
        #expect(items[0].plannedAt == iso("2026-09-10T15:00:00Z"))
    }

    @Test("Entries for a different course_id are filtered out")
    func filtersByCourseID() {
        let json = """
        [
          {"course_id": 1234, "plannable_type": "wiki_page", "plannable_date": "2026-09-10T15:00:00Z", "plannable": {"id": 5555}},
          {"course_id": 9999, "plannable_type": "wiki_page", "plannable_date": "2026-09-11T15:00:00Z", "plannable": {"id": 6666}}
        ]
        """
        let items = CanvasModulesClient.plannerDatedItems(fromPages: [data(json)], courseID: "1234")
        #expect(items.count == 1)
        #expect(items[0].plannableID == "5555")
    }

    @Test("A course-less entry (e.g. planner_note) is skipped")
    func skipsCourseLessEntries() {
        let json = """
        [
          {"plannable_type": "planner_note", "plannable_date": "2026-09-10T15:00:00Z", "plannable": {"id": 1}}
        ]
        """
        let items = CanvasModulesClient.plannerDatedItems(fromPages: [data(json)], courseID: "1234")
        #expect(items.isEmpty)
    }

    @Test("An entry with no plannable_date is skipped")
    func skipsUnparsedDates() {
        let json = """
        [
          {"course_id": 1234, "plannable_type": "wiki_page", "plannable": {"id": 5555}}
        ]
        """
        let items = CanvasModulesClient.plannerDatedItems(fromPages: [data(json)], courseID: "1234")
        #expect(items.isEmpty)
    }

    @Test("An entry missing plannable.id is skipped")
    func skipsMissingPlannableID() {
        let json = """
        [
          {"course_id": 1234, "plannable_type": "wiki_page", "plannable_date": "2026-09-10T15:00:00Z"}
        ]
        """
        let items = CanvasModulesClient.plannerDatedItems(fromPages: [data(json)], courseID: "1234")
        #expect(items.isEmpty)
    }

    @Test("A garbage page decodes to no items, not a throw")
    func garbagePageDecodesToEmpty() {
        let items = CanvasModulesClient.plannerDatedItems(fromPages: [data("not json at all")], courseID: "1234")
        #expect(items.isEmpty)
    }

    @Test("XSSI-prefixed planner page decodes after stripXSSIPrefix")
    func decodesXSSIPrefixedPage() {
        let json = """
        while(1);[
          {"course_id": 1234, "plannable_type": "assignment", "plannable_date": "2026-09-10T15:00:00Z", "plannable": {"id": 42}}
        ]
        """
        let items = CanvasModulesClient.plannerDatedItems(fromPages: [data(json)], courseID: "1234")
        #expect(items.count == 1)
        #expect(items[0].plannableType == "assignment")
        #expect(items[0].plannableID == "42")
    }

    // MARK: - ModuleItem decoder captures content_id and module name

    @Test("Module item decoder captures content_id and the parent module's name")
    func decodesContentIDAndModuleName() {
        let json = """
        [
          {
            "id": 1,
            "name": "Week 1",
            "items": [
              {"id": 111, "title": "Reading: Chapter 1", "type": "Page", "content_id": 5555}
            ]
          }
        ]
        """
        let items = CanvasModulesClient.moduleItems(fromPages: [data(json)])
        #expect(items.count == 1)
        #expect(items[0].contentID == "5555")
        #expect(items[0].moduleName == "Week 1")
    }

    @Test("Module item decoder yields nil content_id and module name when absent")
    func missingContentIDAndModuleNameYieldNil() {
        let json = """
        [
          {
            "id": 1,
            "items": [
              {"id": 111, "title": "Reading: Chapter 1", "type": "Page"}
            ]
          }
        ]
        """
        let items = CanvasModulesClient.moduleItems(fromPages: [data(json)])
        #expect(items.count == 1)
        #expect(items[0].contentID == nil)
        #expect(items[0].moduleName == nil)
    }

    // MARK: - overlayDates(_:planner:)

    private func moduleItem(
        id: String,
        title: String = "Reading",
        dueAt: Date? = nil,
        typeRaw: String,
        contentID: String?
    ) -> CanvasModulesClient.ModuleItem {
        CanvasModulesClient.ModuleItem(id: id, title: title, dueAt: dueAt, typeRaw: typeRaw, contentID: contentID)
    }

    @Test("An already-dated item keeps its own date, ignoring any planner match")
    func datedItemKeepsItsOwnDate() {
        let originalDate = iso("2026-09-01T00:00:00Z")
        let items = [moduleItem(id: "1", dueAt: originalDate, typeRaw: "Assignment", contentID: "5555")]
        let planner = [PlannerDatedItem(plannableType: "assignment", plannableID: "5555", plannedAt: iso("2026-09-10T00:00:00Z"))]
        let overlaid = CanvasModulesClient.overlayDates(items, planner: planner)
        #expect(overlaid.count == 1)
        #expect(overlaid[0].dueAt == originalDate)
    }

    @Test("An undated Page gains a date from a matching wiki_page planner entry")
    func undatedPageGainsPlannerDate() {
        let plannedDate = iso("2026-09-10T15:00:00Z")
        let items = [moduleItem(id: "1", typeRaw: "Page", contentID: "5555")]
        let planner = [PlannerDatedItem(plannableType: "wiki_page", plannableID: "5555", plannedAt: plannedDate)]
        let overlaid = CanvasModulesClient.overlayDates(items, planner: planner)
        #expect(overlaid.count == 1)
        #expect(overlaid[0].dueAt == plannedDate)
        // Everything else about the item is preserved.
        #expect(overlaid[0].id == "1")
        #expect(overlaid[0].typeRaw == "Page")
        #expect(overlaid[0].contentID == "5555")
    }

    @Test("An undated item with no matching planner entry stays nil")
    func undatedItemWithNoMatchStaysNil() {
        let items = [moduleItem(id: "1", typeRaw: "Page", contentID: "5555")]
        let planner = [PlannerDatedItem(plannableType: "wiki_page", plannableID: "9999", plannedAt: iso("2026-09-10T15:00:00Z"))]
        let overlaid = CanvasModulesClient.overlayDates(items, planner: planner)
        #expect(overlaid.count == 1)
        #expect(overlaid[0].dueAt == nil)
    }

    @Test("An undated item with nil contentID stays nil regardless of planner data")
    func undatedItemWithNilContentIDStaysNil() {
        let items = [moduleItem(id: "1", typeRaw: "Page", contentID: nil)]
        let planner = [PlannerDatedItem(plannableType: "wiki_page", plannableID: "5555", plannedAt: iso("2026-09-10T15:00:00Z"))]
        let overlaid = CanvasModulesClient.overlayDates(items, planner: planner)
        #expect(overlaid.count == 1)
        #expect(overlaid[0].dueAt == nil)
    }

    @Test("A module item type with no planner analogue (File) is left unmatched")
    func unknownTypeIsUnmatched() {
        let items = [moduleItem(id: "1", typeRaw: "File", contentID: "5555")]
        // Deliberately mismatched plannable_type — "File" maps to nothing, so
        // this entry must never be reachable via the overlay's lookup.
        let planner = [PlannerDatedItem(plannableType: "wiki_page", plannableID: "5555", plannedAt: iso("2026-09-10T15:00:00Z"))]
        let overlaid = CanvasModulesClient.overlayDates(items, planner: planner)
        #expect(overlaid.count == 1)
        #expect(overlaid[0].dueAt == nil)
    }

    // MARK: - overlayDates(_:planner:) — title fallback (pass 2)

    @Test("An undated Page with no contentID joins by exact title match")
    func undatedPageWithNoContentIDJoinsByTitle() {
        let plannedDate = iso("2026-09-10T15:00:00Z")
        let items = [moduleItem(id: "1", title: "Reading: Chapter 1", typeRaw: "Page", contentID: nil)]
        let planner = [
            PlannerDatedItem(plannableType: "wiki_page", plannableID: "5555", plannedAt: plannedDate, title: "Reading: Chapter 1"),
        ]
        let overlaid = CanvasModulesClient.overlayDates(items, planner: planner)
        #expect(overlaid.count == 1)
        #expect(overlaid[0].dueAt == plannedDate)
    }

    @Test("A title differing only by case/whitespace still joins")
    func titleFallbackNormalizesCaseAndWhitespace() {
        let plannedDate = iso("2026-09-10T15:00:00Z")
        let items = [moduleItem(id: "1", title: "  Reading: Chapter 1 \n", typeRaw: "Page", contentID: nil)]
        let planner = [
            PlannerDatedItem(plannableType: "wiki_page", plannableID: "5555", plannedAt: plannedDate, title: "reading: chapter 1"),
        ]
        let overlaid = CanvasModulesClient.overlayDates(items, planner: planner)
        #expect(overlaid.count == 1)
        #expect(overlaid[0].dueAt == plannedDate)
    }

    @Test("Two planner entries sharing a normalized title with different dates leave the item undated")
    func titleFallbackAmbiguousDifferentDatesStaysUndated() {
        let items = [moduleItem(id: "1", title: "Reading: Chapter 1", typeRaw: "Page", contentID: nil)]
        let planner = [
            PlannerDatedItem(plannableType: "wiki_page", plannableID: "5555", plannedAt: iso("2026-09-10T15:00:00Z"), title: "Reading: Chapter 1"),
            PlannerDatedItem(plannableType: "assignment", plannableID: "6666", plannedAt: iso("2026-09-11T15:00:00Z"), title: "Reading: Chapter 1"),
        ]
        let overlaid = CanvasModulesClient.overlayDates(items, planner: planner)
        #expect(overlaid.count == 1)
        #expect(overlaid[0].dueAt == nil)
    }

    @Test("Two planner entries sharing a title with the same date still join (one distinct date)")
    func titleFallbackSameDateAcrossEntriesJoins() {
        let plannedDate = iso("2026-09-10T15:00:00Z")
        let items = [moduleItem(id: "1", title: "Reading: Chapter 1", typeRaw: "Page", contentID: nil)]
        let planner = [
            PlannerDatedItem(plannableType: "wiki_page", plannableID: "5555", plannedAt: plannedDate, title: "Reading: Chapter 1"),
            PlannerDatedItem(plannableType: "assignment", plannableID: "6666", plannedAt: plannedDate, title: "Reading: Chapter 1"),
        ]
        let overlaid = CanvasModulesClient.overlayDates(items, planner: planner)
        #expect(overlaid.count == 1)
        #expect(overlaid[0].dueAt == plannedDate)
    }

    @Test("The id join still wins first, even when a same-title entry has a different date")
    func idJoinWinsOverTitleFallback() {
        let idJoinedDate = iso("2026-09-10T15:00:00Z")
        let titleOnlyDate = iso("2026-09-20T15:00:00Z")
        let items = [moduleItem(id: "1", title: "Reading: Chapter 1", typeRaw: "Assignment", contentID: "5555")]
        let planner = [
            PlannerDatedItem(plannableType: "assignment", plannableID: "5555", plannedAt: idJoinedDate, title: "Some Other Title"),
            PlannerDatedItem(plannableType: "wiki_page", plannableID: "9999", plannedAt: titleOnlyDate, title: "Reading: Chapter 1"),
        ]
        let overlaid = CanvasModulesClient.overlayDates(items, planner: planner)
        #expect(overlaid.count == 1)
        #expect(overlaid[0].dueAt == idJoinedDate)
    }
}
