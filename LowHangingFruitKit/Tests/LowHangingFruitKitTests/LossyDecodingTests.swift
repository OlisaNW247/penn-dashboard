import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// B8 of `docs/HARDENING_PLAN_2026-10-25.md`: one bad element must not cost
/// a whole store. Every test here has one malformed element among good ones,
/// and fails against the all-or-nothing decode it replaced (each of those
/// returned `[]`, `.empty` or `[:]` and the next save wrote that over the
/// store).
@Suite("Lossy decoding: one bad element does not cost the store")
struct LossyDecodingTests {

    // MARK: The helper itself

    private struct Probe: Decodable, Equatable {
        let id: Int
        let name: String
    }

    @Test("LossyArray keeps the readable elements and counts the rest")
    func lossyArrayKeepsGoodElements() throws {
        let json = #"[{"id":1,"name":"a"},{"id":"two","name":"b"},{"id":3,"name":"c"},42,null,{"id":6,"name":"f"}]"#
        let decoded = try JSONDecoder().decode(LossyArray<Probe>.self, from: Data(json.utf8))
        #expect(decoded.elements == [Probe(id: 1, name: "a"), Probe(id: 3, name: "c"), Probe(id: 6, name: "f")])
        #expect(decoded.droppedCount == 3)
        // The plain decode this replaces loses everything.
        #expect((try? JSONDecoder().decode([Probe].self, from: Data(json.utf8))) == nil)
    }

    @Test("LossyArray on a clean list drops nothing, and on a non-list throws")
    func lossyArrayCleanAndNotAList() throws {
        let clean = try JSONDecoder().decode(LossyArray<Probe>.self, from: Data(#"[{"id":1,"name":"a"}]"#.utf8))
        #expect(clean.elements.count == 1)
        #expect(clean.droppedCount == 0)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LossyArray<Probe>.self, from: Data(#"{"id":1}"#.utf8))
        }
    }

    @Test("LossyDictionary keeps the readable values and counts the rest")
    func lossyDictionaryKeepsGoodValues() throws {
        let json = #"{"a":{"id":1,"name":"a"},"b":{"id":"x"},"c":{"id":3,"name":"c"}}"#
        let decoded = try JSONDecoder().decode(LossyDictionary<Probe>.self, from: Data(json.utf8))
        #expect(Set(decoded.entries.keys) == ["a", "c"])
        #expect(decoded.droppedCount == 1)
    }

    // MARK: Course knowledge file

    private func scratchStore() -> CourseKnowledgeStore {
        CourseKnowledgeStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("lossy-knowledge-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func document(_ id: String, course: String = "1111") -> CourseDocument {
        CourseDocument(
            courseID: course, course: "CIS 1110", kind: .page, sourceID: id,
            title: "Page \(id)", url: nil, text: "Text of page \(id).",
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    /// Saves a base of `ids` and then replaces the document at `badIndex`
    /// with something that cannot decode (a kind no build has heard of).
    private func writeBase(ids: [String], corrupting badIndex: Int, to store: CourseKnowledgeStore) throws -> Data {
        var base = CourseKnowledgeBase.empty
        base.merge(
            courses: [CourseSummary(courseID: "1111", code: "CIS 1110", name: "CIS 1110", url: nil)],
            documents: ids.map { document($0) },
            resyncedCourseIDs: [], syncedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try store.save(base)
        var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        var docs = try #require(root["documents"] as? [[String: Any]])
        docs[badIndex]["kind"] = "from-a-future-build"
        root["documents"] = docs
        let damaged = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try damaged.write(to: store.fileURL)
        return damaged
    }

    @Test("one undecodable document costs that document, not the file, and the original is kept")
    func knowledgeFileKeepsGoodDocuments() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let damaged = try writeBase(ids: ["a", "b", "c"], corrupting: 1, to: store)
        let now = Date(timeIntervalSince1970: 1_800_000_500)

        let report = store.loadReport(now: now)

        #expect(report.droppedCount == 1)
        #expect(report.knowledge.documents.count == 2)
        #expect(report.knowledge.courses.count == 1)
        // The original bytes were set aside before anything was rewritten.
        let aside = try #require(report.quarantinedTo)
        #expect(aside.lastPathComponent == "course-knowledge.json.corrupt-1800000500")
        #expect(try Data(contentsOf: aside) == damaged)
        // The file itself was healed, so the same damage is not reported again.
        let again = store.loadReport(now: now.addingTimeInterval(60))
        #expect(again.droppedCount == 0)
        #expect(again.quarantinedTo == nil)
        #expect(again.knowledge.documents.count == 2)
        #expect(store.load().documents.count == 2)
    }

    @Test("a file that cannot be read as a knowledge base is moved aside, not overwritten")
    func knowledgeFileUnreadableIsMovedAside() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let garbage = Data(#"{"documents": "not a list", "courses": []"#.utf8)   // also truncated
        try garbage.write(to: store.fileURL)

        let report = store.loadReport(now: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(report.knowledge == .empty)
        let aside = try #require(report.quarantinedTo)
        #expect(aside.lastPathComponent == "course-knowledge.json.corrupt-1800000000")
        #expect(try Data(contentsOf: aside) == garbage)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        // A save after that does not touch the quarantined copy.
        try store.save(CourseKnowledgeBase(documents: [document("x")]))
        #expect(try Data(contentsOf: aside) == garbage)
        #expect(store.load().documents.count == 1)
    }

    @Test("a missing file is empty and sets nothing aside")
    func knowledgeFileMissing() {
        let store = scratchStore()
        let report = store.loadReport()
        #expect(report.knowledge == .empty)
        #expect(report.droppedCount == 0)
        #expect(report.quarantinedTo == nil)
    }

    @Test("a clean file loads with nothing dropped")
    func knowledgeFileClean() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(CourseKnowledgeBase(documents: [document("a"), document("b")]))
        let report = store.loadReport()
        #expect(report.droppedCount == 0)
        #expect(report.quarantinedTo == nil)
        #expect(report.knowledge.documents.count == 2)
    }

    // MARK: Modules

    private func page(_ json: String) -> Data { Data(json.utf8) }

    @Test("one bad module item drops that item, not its page")
    func moduleItemDropsOnlyItself() {
        let json = """
        [{"name": "Week 1", "items": [
            {"id": 1, "title": "Syllabus", "type": "Page"},
            {"id": "not-a-number", "title": "Broken", "type": "Page"},
            {"id": 3, "title": null, "type": "Page"},
            {"id": 4, "title": "Reading", "type": "File"}
        ]},
         {"name": "Week 2", "items": [{"id": 5, "title": "Quiz", "type": "Quiz"}]}]
        """
        let result = CanvasModulesClient.decodeModules(fromPages: [page(json)])
        #expect(result.items.map(\.id) == ["1", "4", "5"])
        #expect(result.droppedCount == 2)
        // The old entry point still answers, with the survivors.
        #expect(CanvasModulesClient.moduleItems(fromPages: [page(json)]).map(\.id) == ["1", "4", "5"])
    }

    @Test("one bad module drops that module, and a page that is not modules is counted once")
    func moduleAndPageDrops() {
        let mixed = #"[{"name": "Good", "items": [{"id": 1, "title": "A", "type": "Page"}]}, "oops", {"name": "Odd", "items": "nope"}]"#
        let notModules = #"{"errors": [{"message": "unauthorized"}]}"#
        let result = CanvasModulesClient.decodeModules(fromPages: [page(mixed), page(notModules), page("[]")])
        #expect(result.items.map(\.id) == ["1"])
        // "oops", the module whose items is not a list, and the error page.
        #expect(result.droppedCount == 3)
    }

    @Test("a clean modules response drops nothing")
    func moduleCleanDropsNothing() {
        let json = #"[{"name": "W", "items": [{"id": 1, "title": "A", "type": "SubHeader"}, {"id": 2, "title": "B", "type": "Page"}]}, {"name": "Empty"}]"#
        let result = CanvasModulesClient.decodeModules(fromPages: [page(json)])
        #expect(result.items.map(\.id) == ["2"])
        #expect(result.droppedCount == 0)
    }

    // MARK: CoursePreferences map

    @Test("one unreadable course record resets that course, not every course")
    func coursePreferencesMapKeepsGoodRecords() {
        let json = """
        {"CIS 1110": {"courseKey": "CIS 1110", "displayName": "Programming", "isVisible": false},
         "CIS 2400": {"courseKey": "CIS 2400", "isVisible": "yes please"},
         "PHYS 0151": {"courseKey": "PHYS 0151", "isDeleted": true}}
        """
        let report = CoursePreferencesStore.decodeMapReport(Data(json.utf8))
        #expect(report.droppedCount == 1)
        #expect(Set(report.map.keys) == ["CIS 1110", "PHYS 0151"])
        #expect(report.map["CIS 1110"]?.isVisible == false)
        #expect(report.map["PHYS 0151"]?.isDeleted == true)
        #expect(CoursePreferencesStore.decodeMap(Data(json.utf8)).count == 2)
    }

    @Test("a preference blob that is not a map is empty, and nil is empty")
    func coursePreferencesMapNotAMap() {
        #expect(CoursePreferencesStore.decodeMapReport(Data("[1,2]".utf8)).map.isEmpty)
        #expect(CoursePreferencesStore.decodeMapReport(nil).map.isEmpty)
    }

    // MARK: Recurring tasks

    @Test("one unreadable recurring task costs that task, not the list")
    func recurringTasksKeepGoodTasks() throws {
        let good = RecurringTask(
            title: "Weekly reading", course: "CIS 1110", weekday: 2, hour: 9, minute: 0,
            startDate: Date(timeIntervalSince1970: 1_800_000_000), endDate: nil, origin: .manual
        )
        let encoded = try JSONEncoder().encode([good, good])
        var list = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        list[1]["id"] = UUID().uuidString
        list.insert(["id": UUID().uuidString, "title": "From a future build", "origin": "telepathy"], at: 1)
        let data = try JSONSerialization.data(withJSONObject: list)

        let result = RecurringTask.decodeAll(data)

        #expect(result.tasks.count == 2)
        #expect(result.droppedCount == 1)
        #expect(result.tasks.first?.title == "Weekly reading")
        #expect(RecurringTask.decodeAll(nil).tasks.isEmpty)
    }

    // MARK: Grade overrides

    @Test("one unreadable grade override costs that override, not every correction")
    func gradeOverridesKeepGoodEntries() {
        let json = """
        {"1001": {"hw1": {"score": 9, "isExcluded": false},
                  "hw2": {"score": "ninety", "isExcluded": false},
                  "hw3": {"pointsPossible": 20, "isExcluded": true}},
         "1002": {"quiz1": {"score": 5, "isExcluded": false}},
         "1003": "not a map"}
        """
        let result = GradeItemOverride.decodeMap(Data(json.utf8))
        #expect(result.droppedCount == 2)
        #expect(Set(result.map.keys) == ["1001", "1002"])
        #expect(Set(result.map["1001"]?.keys ?? [:].keys) == ["hw1", "hw3"])
        #expect(result.map["1002"]?["quiz1"]?.score == 5)
        #expect(GradeItemOverride.decodeMap(nil).map.isEmpty)
    }
}

// MARK: - Collector: a dropped module piece makes the course partial

/// Drives `CourseKnowledgeCollector` end to end through a `URLProtocol` with
/// a modules response that has one bad item. The stub's state is process-wide
/// static, so the suite is serialized, as the other collector suites are.
@Suite("Collector counts a dropped module piece as a course error", .serialized)
struct CollectorModuleDropTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let course = CourseSummary(
        courseID: "1111", code: "CIS 1110", name: "CIS 1110 Intro", url: nil
    )

    fileprivate final class ModulesStub: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var modulesBody = "[]"

        static func configure(modulesBody: String) {
            lock.lock(); defer { lock.unlock() }
            self.modulesBody = modulesBody
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            let body: String = {
                Self.lock.lock(); defer { Self.lock.unlock() }
                return path.hasSuffix("/courses/1111/modules") ? Self.modulesBody : "[]"
            }()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func run(modulesBody: String) async throws -> (CourseKnowledgeCollector.Report, CourseKnowledgeStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("collector-module-drop-\(UUID().uuidString)", isDirectory: true)
        let store = CourseKnowledgeStore(directory: directory)
        // A stored module document the run must not retire.
        var base = CourseKnowledgeBase.empty
        base.merge(
            courses: [Self.course],
            documents: [CourseDocument(
                courseID: "1111", course: "CIS 1110", kind: .module, sourceID: "stored-module",
                title: "Stored module", url: nil, text: "Stored module text."
            )],
            resyncedCourseIDs: [], syncedAt: Self.now.addingTimeInterval(-86_400)
        )
        try store.save(base)

        ModulesStub.configure(modulesBody: modulesBody)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModulesStub.self]
        let collector = CourseKnowledgeCollector(
            cookies: [], store: store, session: URLSession(configuration: configuration)
        )
        let report = try await collector.run(courses: [Self.course], now: Self.now)
        return (report, store)
    }

    @Test("a bad module item makes the course partial and keeps its stored module documents")
    func droppedModuleItemMakesCoursePartial() async throws {
        defer { ModulesStub.configure(modulesBody: "[]") }
        let body = #"[{"name": "W1", "items": [{"id": 1, "title": "Good", "type": "Page"}, {"id": "bad", "title": "Bad", "type": "Page"}]}]"#
        let (report, store) = try await run(modulesBody: body)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

        #expect(report.partialCourseIDs == ["1111"])
        #expect(report.fullyFetchedCourseIDs.isEmpty)
        #expect(report.errors.contains { $0.hasPrefix("CIS 1110 modules:") })
        let ids = Set(report.knowledge.documents.map(\.id))
        #expect(ids.contains("module:1111:stored-module"))
    }

    @Test("a clean modules response still lets the course count as fully synced")
    func cleanModulesCourseIsFullySynced() async throws {
        defer { ModulesStub.configure(modulesBody: "[]") }
        let body = #"[{"name": "W1", "items": [{"id": 1, "title": "Good", "type": "Page"}]}]"#
        let (report, store) = try await run(modulesBody: body)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

        #expect(report.fullyFetchedCourseIDs == ["1111"])
        #expect(report.partialCourseIDs.isEmpty)
        // A clean run retires the document Canvas no longer lists.
        #expect(!report.knowledge.documents.contains { $0.id == "module:1111:stored-module" })
    }
}

// MARK: - The raw blob is kept before the next save overwrites it

/// The student-authored blobs (course preferences, recurring tasks, grade
/// overrides) keep what could not be read: the survivors are what the next
/// save writes, so without a copy the unreadable element is gone for good.
@Suite("Unreadable student-authored blobs are kept before they are overwritten")
struct UnreadableBlobTests {

    private func scratchDefaults() -> UserDefaults {
        let name = "unreadable-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let preferences = Data(#"""
        {"CIS 1110": {"courseKey": "CIS 1110", "displayName": "Programming"},
         "CIS 2400": {"courseKey": "CIS 2400", "isVisible": "from a newer build"}}
        """#.utf8)

    @Test("course preferences: the raw blob is kept when a record is unreadable, the survivors load, and the copy is made once")
    @MainActor
    func coursePreferences() {
        let defaults = scratchDefaults()
        defaults.set(preferences, forKey: CoursePreferencesStore.storageKey)

        let store = CoursePreferencesStore(defaults: defaults)
        #expect(Set(store.byCourseKey.keys) == ["CIS 1110"])
        #expect(UnreadableBlob.rawCopy(forKey: CoursePreferencesStore.storageKey, in: defaults) == preferences)

        // The next save overwrites the live blob with the survivors only...
        store.setDisplayName("CIS 1110", to: "Programming II")
        #expect(defaults.data(forKey: CoursePreferencesStore.storageKey) != preferences)
        // ...and the copy is still the original, and is not replaced.
        #expect(UnreadableBlob.rawCopy(forKey: CoursePreferencesStore.storageKey, in: defaults) == preferences)
        defaults.set(Data(#"{"X": {"isVisible": 3}}"#.utf8), forKey: CoursePreferencesStore.storageKey)
        _ = CoursePreferencesStore(defaults: defaults)
        #expect(UnreadableBlob.rawCopy(forKey: CoursePreferencesStore.storageKey, in: defaults) == preferences)
    }

    @Test("course preferences: a blob that is not a map is kept too, and a clean blob leaves no copy")
    @MainActor
    func coursePreferencesWholeBlobAndClean() {
        let garbage = Data("[1, 2, 3".utf8)
        let broken = scratchDefaults()
        broken.set(garbage, forKey: CoursePreferencesStore.storageKey)
        #expect(CoursePreferencesStore(defaults: broken).byCourseKey.isEmpty)
        #expect(UnreadableBlob.rawCopy(forKey: CoursePreferencesStore.storageKey, in: broken) == garbage)

        let clean = scratchDefaults()
        clean.set(Data(#"{"CIS 1110": {"courseKey": "CIS 1110", "displayName": "P"}}"#.utf8), forKey: CoursePreferencesStore.storageKey)
        _ = CoursePreferencesStore(defaults: clean)
        #expect(UnreadableBlob.rawCopy(forKey: CoursePreferencesStore.storageKey, in: clean) == nil)
        _ = CoursePreferencesStore(defaults: scratchDefaults())   // nothing stored at all
    }

    @Test("recurring tasks: the raw list is kept when a task is unreadable")
    func recurringTasks() throws {
        let defaults = scratchDefaults()
        let good = RecurringTask(
            title: "Weekly reading", course: "CIS 1110", weekday: 2, hour: 9, minute: 0,
            startDate: Date(timeIntervalSince1970: 1_800_000_000), endDate: nil, origin: .manual
        )
        var list = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode([good])) as? [[String: Any]])
        list.append(["id": UUID().uuidString, "title": "From a newer build", "origin": "telepathy"])
        let raw = try JSONSerialization.data(withJSONObject: list)
        defaults.set(raw, forKey: "recurringTasks")

        let tasks = RecurringTask.load(from: defaults, key: "recurringTasks")

        #expect(tasks.map(\.title) == ["Weekly reading"])
        #expect(UnreadableBlob.rawCopy(forKey: "recurringTasks", in: defaults) == raw)
        // A clean list leaves nothing behind.
        let clean = scratchDefaults()
        clean.set(try JSONEncoder().encode([good]), forKey: "recurringTasks")
        #expect(RecurringTask.load(from: clean, key: "recurringTasks").count == 1)
        #expect(UnreadableBlob.rawCopy(forKey: "recurringTasks", in: clean) == nil)
    }

    @Test("grade overrides: the raw blob is kept when an override is unreadable")
    func gradeOverrides() {
        let defaults = scratchDefaults()
        let raw = Data(#"{"1001": {"hw1": {"score": 9, "isExcluded": false}, "hw2": {"score": "ninety", "isExcluded": false}}}"#.utf8)
        defaults.set(raw, forKey: "gradeWatcherItemOverrides")

        let map = GradeItemOverride.loadMap(from: defaults, key: "gradeWatcherItemOverrides")

        #expect(map["1001"]?["hw1"]?.score == 9)
        #expect(map["1001"]?["hw2"] == nil)
        #expect(UnreadableBlob.rawCopy(forKey: "gradeWatcherItemOverrides", in: defaults) == raw)
        // Whole blob unreadable counts, too; nothing stored does not.
        let garbage = scratchDefaults()
        garbage.set(Data("not json".utf8), forKey: "k")
        #expect(GradeItemOverride.loadMap(from: garbage, key: "k").isEmpty)
        #expect(UnreadableBlob.rawCopy(forKey: "k", in: garbage) == Data("not json".utf8))
        #expect(GradeItemOverride.loadMap(from: scratchDefaults(), key: "k").isEmpty)
    }
}
