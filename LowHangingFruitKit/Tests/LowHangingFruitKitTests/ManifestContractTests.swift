import Foundation
import Testing
@testable import LowHangingFruitKit

/// The cross-language contract: `Fixtures/manifest-with-facts.json` and
/// `Fixtures/document-posted-at.json` are written by the SERVER's own code
/// (`backend/test/fixtures/facts/make-swift-fixture.ts` calls `factsResponse`,
/// `documentRowToWire`, `profileRowToWire`, `diffManifest`, `validateDocument`),
/// so a server-side shape change that the phone cannot read turns this red
/// once the fixture is regenerated. Never edit the JSON by hand.
@MainActor
@Suite("Manifest contract (server JSON to effects)")
struct ManifestContractTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"), "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    private func manifest() throws -> SyncManifestResponse {
        try BackendJSON.decoder().decode(SyncManifestResponse.self, from: fixture("manifest-with-facts"))
    }

    private func date(_ iso: String) throws -> Date { try #require(BackendJSON.parseDate(iso)) }

    @Test("the server's manifest decodes whole: documents, profiles, facts and cursor")
    func decodesWholeManifest() throws {
        let response = try manifest()
        #expect(response.coursesFresh == ["1234"])
        #expect(response.serverManifest.count == 3)
        #expect(response.download.count == 3)
        #expect(response.download.allSatisfy { $0.document() != nil }, "every served document must pass its own id check")
        #expect(response.profiles.contains { $0.courseID == "1234" && $0.weights.count == 2 && $0.examDates.count == 1 })
        #expect(response.facts.count == 4)
        // The withheld stale-revision row (seq 107) still moves the cursor.
        #expect(response.factsCursor == 107)
    }

    @Test("every fact field round-trips from the server's JSON")
    func factFieldsRoundTrip() throws {
        let facts = try manifest().facts
        #expect(facts.map(\.seq) == [101, 102, 103, 104])
        #expect(facts.map(\.type) == [.cancel, .reschedule, .newTask, .needsReview])

        let cancel = facts[0]
        #expect(cancel.courseID == "1234")
        #expect(cancel.documentID == "announcement:1234:55")
        #expect(cancel.contentHash == "hash-55")
        #expect(cancel.target == "555")
        #expect(cancel.title == nil && cancel.dueAt == nil && cancel.kind == nil)
        #expect(cancel.quote == "the quote")
        #expect(cancel.confidence == .high)
        #expect(cancel.postedAt == (try date("2026-11-02T09:00:00.000Z")))

        let reschedule = facts[1]
        #expect(reschedule.dueAt == (try date("2026-11-12T04:59:00.000Z")))
        #expect(reschedule.quote == "now due Thursday")

        let task = facts[2]
        #expect(task.target == nil)
        #expect(task.title == "Read ch. 5")
        #expect(task.kind == .preparation)
        #expect(task.confidence == .medium)
        #expect(task.postedAt == nil)
        #expect(task.dueAt == (try date("2026-11-09T14:00:00.000Z")))

        let review = facts[3]
        #expect(review.type == .needsReview)
        #expect(review.target == "module:abc")
        #expect(review.confidence == .medium)
    }

    @Test("postedAt: the server's normalized upload echo decodes, and download carries none")
    func documentPostedAt() throws {
        let echoed = try BackendJSON.decoder().decode(CourseDocumentWire.self, from: fixture("document-posted-at"))
        // Sent as 04:00 at -05:00; the server normalizes to UTC ISO.
        #expect(echoed.postedAt == (try date("2026-11-02T09:00:00.000Z")))
        #expect(echoed.document()?.postedAt == echoed.postedAt)
        // `documentRowToWire` never serves postedAt back (manifest.ts CourseDocumentWire doc comment).
        #expect(try manifest().download.allSatisfy { $0.postedAt == nil })
    }

    @Test("server JSON to store to engine to effects, once, end to end")
    func wholePipe() throws {
        let response = try manifest()
        let store = try AppliedFactStore(inMemory: true)
        #expect(store.upsert(facts: response.facts, now: Self.now) == 4)
        #expect(store.upsert(facts: response.facts, now: Self.now) == 0, "a re-read adds nothing")
        // The store's own max is the highest SERVED seq; the server's cursor is
        // higher because it also counts the withheld row.
        #expect(store.cursor() == 104)
        #expect(max(store.cursor(), response.factsCursor ?? 0) == 107)

        let due = try date("2026-11-10T04:59:00.000Z")
        let row = Assignment(
            source: .canvas, sourceID: "event-assignment-555", kind: .assignment, course: "CIS 2400",
            title: "PSet 3", dueAt: due,
            url: URL(string: "https://canvas.upenn.edu/calendar?include_contexts=course_1234&month=11&year=2026#assignment_555")
        )
        let effects = FactApplication.evaluate(
            facts: store.all(), items: [FactItem(row)], courseCodeByID: ["1234": "CIS 2400"], now: Self.now
        )

        let item = try #require(effects.items[row.id])
        // Rewritten 2026-11-05: the fixture's cancel (#101) and reschedule (#102)
        // of one target share a post time, and they now share one supersession
        // key, so the later seq wins and the cancel is superseded (it used to
        // apply alongside, leaving a card both hidden and moved).
        #expect(item.cancelled == nil)
        #expect(effects.redundant.contains(.init(factID: "announcement:1234:55#101", reason: .supersededBySeq(102))))
        #expect(item.rescheduled?.to == (try date("2026-11-12T04:59:00.000Z")))
        #expect(item.rescheduled?.from == due)
        #expect(effects.newTasks.count == 1)
        #expect(effects.newTasks.first?.assignment.title == "Read ch. 5")
        #expect(effects.newTasks.first?.assignment.kind == .other)
        #expect(effects.needsReview.map(\.reason) == [.flaggedByExtractor])
        #expect(effects.applied == ["announcement:1234:55#102", "announcement:1234:55#103"])

        // And the write-back leaves the store consistent.
        #expect(store.record(effects, now: Self.now))
        let stored = store.all()
        #expect(stored.filter { $0.appliedAt != nil }.map(\.seq) == [102, 103])
        #expect(stored.first { $0.seq == 102 }?.resolvedItemID == row.id)
    }
}
