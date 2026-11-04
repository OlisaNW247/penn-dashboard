import Foundation
import Testing
@testable import LowHangingFruitKit

@MainActor
@Suite("Applied fact store")
struct AppliedFactStoreTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func wire(
        _ seq: Int,
        course: String = "1234",
        doc: String = "announcement:1234:55",
        hash: String = "h1",
        type: CourseFactWire.FactType = .cancel
    ) -> CourseFactWire {
        CourseFactWire(seq: seq, courseID: course, documentID: doc, contentHash: hash, type: type,
                       target: "555", title: "PSet 3", quote: "q", confidence: .high,
                       postedAt: Self.now)
    }

    @Test("upsert is idempotent by fact and never overwrites the student's verdict")
    func idempotentUpsert() throws {
        let store = try AppliedFactStore(inMemory: true)
        #expect(store.upsert(facts: [wire(1), wire(2)], now: Self.now) == 2)
        #expect(store.setOverride(factID: "announcement:1234:55#1", to: .confirmed, now: Self.now))
        #expect(store.upsert(facts: [wire(1), wire(2), wire(3)], now: Self.now.addingTimeInterval(500)) == 1)
        let all = store.all()
        #expect(all.map(\.seq) == [1, 2, 3])
        #expect(all[0].studentOverride == .confirmed)
        #expect(all[0].receivedAt == Self.now)
    }

    @Test("cursor is the highest stored seq, 0 when empty")
    func cursor() throws {
        let store = try AppliedFactStore(inMemory: true)
        #expect(store.cursor() == 0)
        store.upsert(facts: [wire(4), wire(9), wire(6)], now: Self.now)
        #expect(store.cursor() == 9)
    }

    @Test("setOverride records and clears a verdict; an unknown fact reports false")
    func override() throws {
        let store = try AppliedFactStore(inMemory: true)
        store.upsert(facts: [wire(1)], now: Self.now)
        let id = "announcement:1234:55#1"
        #expect(store.setOverride(factID: id, to: .rejected, now: Self.now))
        #expect(store.all()[0].studentOverride == .rejected)
        #expect(store.all()[0].overrideAt == Self.now)
        #expect(store.setOverride(factID: id, to: .none, now: Self.now))
        #expect(store.all()[0].studentOverride == .none)
        #expect(store.all()[0].overrideAt == nil)
        #expect(!store.setOverride(factID: "nope#1", to: .confirmed, now: Self.now))
    }

    @Test("purge removes only the named courses")
    func purge() throws {
        let store = try AppliedFactStore(inMemory: true)
        store.upsert(facts: [wire(1), wire(2, course: "99", doc: "page:99:1")], now: Self.now)
        #expect(store.purge(courseIDs: []) == 0)
        #expect(store.purge(courseIDs: ["1234"]) == 1)
        #expect(store.all().map(\.courseID) == ["99"])
    }

    @Test("removeFacts drops one stale revision and leaves the new one")
    func staleHashRemoval() throws {
        let store = try AppliedFactStore(inMemory: true)
        store.upsert(facts: [wire(1, hash: "old"), wire(2, hash: "new"), wire(3, doc: "page:1234:7", hash: "old")], now: Self.now)
        #expect(store.removeFacts(documentID: "announcement:1234:55", contentHash: "old") == 1)
        #expect(store.all().map(\.seq) == [2, 3])
    }

    @Test("record writes bookkeeping only: applied item, supersession, never content or override")
    func recordBookkeeping() throws {
        let store = try AppliedFactStore(inMemory: true)
        store.upsert(facts: [wire(1), wire(2)], now: Self.now)
        store.setOverride(factID: "announcement:1234:55#1", to: .confirmed, now: Self.now)
        var effects = FactEffects(evaluatedAt: Self.now)
        effects.applied = ["announcement:1234:55#2"]
        effects.resolvedItems = ["announcement:1234:55#2": "canvas:555"]
        effects.redundant = [.init(factID: "announcement:1234:55#1", reason: .supersededBySeq(2))]
        #expect(store.record(effects, now: Self.now.addingTimeInterval(5)))
        let all = store.all()
        #expect(all[0].supersededBySeq == 2)
        #expect(all[0].studentOverride == .confirmed)
        #expect(all[0].appliedAt == nil)
        #expect(all[1].resolvedItemID == "canvas:555")
        #expect(all[1].appliedAt == Self.now.addingTimeInterval(5))
        #expect(store.facts(forItem: "canvas:555").map(\.seq) == [2])
        #expect(all[1].title == "PSet 3")
    }

    @Test("an in-memory store is not persistent and a file store survives reopening")
    func persistence() throws {
        #expect(try AppliedFactStore(inMemory: true).isPersistent == false)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lhf-facts-\(UUID().uuidString).store")
        defer { for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        do {
            let store = try AppliedFactStore(url: url)
            store.upsert(facts: [wire(1)], now: Self.now)
            store.setOverride(factID: "announcement:1234:55#1", to: .rejected, now: Self.now)
        }
        let reopened = try AppliedFactStore(url: url)
        #expect(reopened.isPersistent)
        #expect(reopened.all().first?.studentOverride == .rejected)
    }

    @Test("a missing App Group falls back to memory and says why")
    func fallback() throws {
        let store = try #require(AppliedFactStore.openOrFallBack(at: nil))
        #expect(!store.isPersistent)
        #expect(store.storageFailureReason != nil)
    }
}
