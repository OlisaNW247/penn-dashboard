import Foundation
import Testing
@testable import LowHangingFruitKit

/// Fixture-based decoding tests for `CanvasModulesClient` — no network calls.
/// Every test drives `CanvasModulesClient.moduleItems(fromPages:)`, the pure
/// (network-free) seam the client's networked `fetchModuleItems` also calls,
/// with realistic Canvas Modules-API JSON (see docs/READINGS_COURSES_PLAN.md).
@Suite("Canvas modules client")
struct CanvasModulesClientTests {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func iso(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
    }

    // MARK: - Basic shape: two modules, several items

    @Test("Two modules with items decode with correct id, title, type")
    func decodesModulesWithItems() {
        let json = """
        [
          {
            "id": 1,
            "name": "Week 1",
            "items": [
              {"id": 111, "title": "Reading: Chapter 1", "type": "Page"},
              {"id": 112, "title": "Problem Set 1", "type": "Assignment"}
            ]
          },
          {
            "id": 2,
            "name": "Week 2",
            "items": [
              {"id": 9001, "title": "Reading: Chapter 2", "type": "Page"}
            ]
          }
        ]
        """
        let items = CanvasModulesClient.moduleItems(fromPages: [data(json)])
        #expect(items.count == 3)
        #expect(items[0].id == "111")
        #expect(items[0].title == "Reading: Chapter 1")
        #expect(items[0].typeRaw == "Page")
        #expect(items[1].id == "112")
        #expect(items[1].typeRaw == "Assignment")
        #expect(items[2].id == "9001")
        #expect(items[2].title == "Reading: Chapter 2")
    }

    // MARK: - Due dates

    @Test("content_details.due_at parses without fractional seconds")
    func parsesDueAtPlain() {
        let json = """
        [
          {
            "id": 1,
            "items": [
              {"id": 111, "title": "Reading: Chapter 1", "type": "Assignment",
               "content_details": {"due_at": "2026-09-05T03:59:59Z"}}
            ]
          }
        ]
        """
        let items = CanvasModulesClient.moduleItems(fromPages: [data(json)])
        #expect(items.count == 1)
        #expect(items[0].dueAt == iso("2026-09-05T03:59:59Z"))
    }

    @Test("content_details.due_at parses with fractional seconds")
    func parsesDueAtFractional() {
        let json = """
        [
          {
            "id": 1,
            "items": [
              {"id": 111, "title": "Reading: Chapter 1", "type": "Assignment",
               "content_details": {"due_at": "2026-09-05T03:59:59.123Z"}}
            ]
          }
        ]
        """
        let items = CanvasModulesClient.moduleItems(fromPages: [data(json)])
        #expect(items.count == 1)
        // The parsed Date carries the .123s fraction, so exact == against a
        // whole-second expectation fails by 123ms while both PRINT the same
        // second (that exact trap shipped in this test's first version).
        // The property under test is "a fractional timestamp parses at all",
        // so assert same-second, not bit-equality.
        let parsed = items[0].dueAt
        #expect(parsed != nil)
        if let parsed {
            #expect(abs(parsed.timeIntervalSince(iso("2026-09-05T03:59:59Z"))) < 0.5)
        }
    }

    @Test("Missing content_details yields nil dueAt")
    func missingContentDetailsYieldsNilDueAt() {
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
        #expect(items[0].dueAt == nil)
    }

    // MARK: - SubHeader skipped

    @Test("SubHeader items are skipped")
    func skipsSubHeaders() {
        let json = """
        [
          {
            "id": 1,
            "items": [
              {"id": 100, "title": "Week 1 Readings", "type": "SubHeader"},
              {"id": 111, "title": "Reading: Chapter 1", "type": "Page"}
            ]
          }
        ]
        """
        let items = CanvasModulesClient.moduleItems(fromPages: [data(json)])
        #expect(items.count == 1)
        #expect(items[0].id == "111")
    }

    // MARK: - Module with no items contributes nothing

    @Test("A module without an items array contributes nothing")
    func moduleWithoutItemsContributesNothing() {
        let json = """
        [
          {"id": 1, "name": "Week 1"},
          {"id": 2, "items": [{"id": 111, "title": "Reading: Chapter 1", "type": "Page"}]}
        ]
        """
        let items = CanvasModulesClient.moduleItems(fromPages: [data(json)])
        #expect(items.count == 1)
        #expect(items[0].id == "111")
    }

    // MARK: - XSSI prefix

    @Test("XSSI-prefixed page data decodes after stripXSSIPrefix")
    func decodesXSSIPrefixedPage() {
        let json = """
        while(1);[
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
        #expect(items[0].id == "111")
    }

    // MARK: - Garbage page

    @Test("A garbage page decodes to no items, not a throw")
    func garbagePageDecodesToEmpty() {
        let items = CanvasModulesClient.moduleItems(fromPages: [data("not json at all")])
        #expect(items.isEmpty)
    }

    @Test("A garbage page doesn't stop other pages from decoding")
    func garbagePageDoesNotBlockOtherPages() {
        let goodJSON = """
        [
          {"id": 1, "items": [{"id": 111, "title": "Reading: Chapter 1", "type": "Page"}]}
        ]
        """
        let items = CanvasModulesClient.moduleItems(fromPages: [data("garbage"), data(goodJSON)])
        #expect(items.count == 1)
        #expect(items[0].id == "111")
    }

    // MARK: - Assignment.id round-trip through Source(rawValue:)

    @Test(".canvasModules source round-trips through Source(rawValue:) and Assignment.id")
    func canvasModulesSourceRoundTrips() {
        let assignment = Assignment(
            source: .canvasModules,
            sourceID: "9001",
            kind: .assignment,
            course: "CIS 1200",
            title: "Reading: Chapter 2",
            dueAt: nil,
            url: nil
        )
        #expect(assignment.id == "canvasModules:9001")
        let decomposed = StoredAssignment.decompose(id: assignment.id)
        #expect(decomposed?.source == .canvasModules)
        #expect(decomposed?.sourceID == "9001")
    }
}
