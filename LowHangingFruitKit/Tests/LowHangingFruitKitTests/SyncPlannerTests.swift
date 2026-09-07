import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Sync planner")
struct SyncPlannerTests {
    private func course(_ id: String, code: String? = nil) -> CourseSummary {
        CourseSummary(courseID: id, code: code ?? "CIS \(id)", name: "CIS \(id)", url: nil)
    }

    private func doc(courseID: String, kind: CourseDocument.Kind = .page, sourceID: String, text: String, fetchedAt: Date = Date(timeIntervalSince1970: 1_000)) -> CourseDocument {
        CourseDocument(courseID: courseID, course: "CIS \(courseID)", kind: kind, sourceID: sourceID, title: "Doc \(sourceID)", url: nil, text: text, fetchedAt: fetchedAt)
    }

    // MARK: - plan

    @Test("plan splits fresh courses from ones needing a fetch, preserving order")
    func planSplitsFreshFromFetch() {
        let courses = [course("3"), course("1"), course("2")]
        let manifest = SyncManifestResponse(coursesFresh: ["1"])
        let plan = SyncPlanner.plan(courses: courses, manifest: manifest)
        #expect(plan.coursesToFetch.map(\.courseID) == ["3", "2"])
        #expect(plan.coursesFresh == ["1"])
    }

    @Test("plan with no fresh courses fetches everything in the original order")
    func planFetchesAllWhenNothingFresh() {
        let courses = [course("2"), course("1")]
        let plan = SyncPlanner.plan(courses: courses, manifest: SyncManifestResponse())
        #expect(plan.coursesToFetch.map(\.courseID) == ["2", "1"])
        #expect(plan.coursesFresh.isEmpty)
    }

    // MARK: - applyDownloads

    @Test("applyDownloads adds new documents to an empty knowledge base")
    func applyDownloadsAddsNewDocuments() {
        var knowledge = CourseKnowledgeBase.empty
        let downloaded = CourseDocumentWire(document: doc(courseID: "1", sourceID: "a", text: "hello"))
        SyncPlanner.applyDownloads([downloaded], to: &knowledge, courses: [course("1")], now: Date(timeIntervalSince1970: 5_000))
        #expect(knowledge.documents.count == 1)
        #expect(knowledge.documents.first?.id == "page:1:a")
        #expect(knowledge.lastSyncedAt == Date(timeIntervalSince1970: 5_000))
    }

    @Test("applyDownloads keeps an existing document's fetchedAt when the hash is unchanged")
    func applyDownloadsKeepsFetchedAtForUnchangedDocument() {
        let original = doc(courseID: "1", sourceID: "a", text: "same text", fetchedAt: Date(timeIntervalSince1970: 1_000))
        var knowledge = CourseKnowledgeBase(courses: [course("1")], documents: [original])
        let downloaded = CourseDocumentWire(document: doc(courseID: "1", sourceID: "a", text: "same text", fetchedAt: Date(timeIntervalSince1970: 9_000)))
        SyncPlanner.applyDownloads([downloaded], to: &knowledge, courses: [course("1")], now: Date(timeIntervalSince1970: 5_000))
        #expect(knowledge.documents.first?.fetchedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test("applyDownloads never removes a local document not mentioned in the batch")
    func applyDownloadsNeverRemovesLocalDocuments() {
        let untouched = doc(courseID: "1", sourceID: "syllabus", text: "syllabus text")
        var knowledge = CourseKnowledgeBase(courses: [course("1")], documents: [untouched])
        // Only an announcement is downloaded this run; the syllabus doc
        // above must survive even though it's absent from `downloads`.
        let downloaded = CourseDocumentWire(document: doc(courseID: "1", kind: .announcement, sourceID: "new", text: "new post"))
        SyncPlanner.applyDownloads([downloaded], to: &knowledge, courses: [course("1")], now: Date())
        #expect(knowledge.documents.contains { $0.id == untouched.id })
        #expect(knowledge.documents.count == 2)
    }

    @Test("applyDownloads skips a wire document that fails to convert")
    func applyDownloadsSkipsUnconvertibleDocuments() {
        var knowledge = CourseKnowledgeBase.empty
        let bad = CourseDocumentWire(id: "bad", courseID: "1", course: "CIS 1", kind: "not-a-kind", sourceID: "x", title: "t", text: "b", fetchedAt: Date(), contentHash: "h")
        SyncPlanner.applyDownloads([bad], to: &knowledge, courses: [course("1")], now: Date())
        #expect(knowledge.documents.isEmpty)
    }

    // MARK: - uploads

    @Test("uploads excludes documents the server already has with a matching hash")
    func uploadsExcludesMatchingDocuments() {
        let known = doc(courseID: "1", sourceID: "a", text: "unchanged")
        let changed = doc(courseID: "1", sourceID: "b", text: "new text")
        let knowledge = CourseKnowledgeBase(courses: [course("1")], documents: [known, changed])
        // The server's manifest lists "b" with a stale hash (the local copy
        // changed since the server last saw it) and doesn't mention "a" at
        // all except with its current hash.
        let serverManifest = [
            DocumentStub(document: known),
            DocumentStub(id: changed.id, contentHash: "stale-hash"),
        ]
        let request = SyncPlanner.uploads(local: knowledge, serverManifest: serverManifest, fullyFetched: [])
        #expect(request.documents.map(\.id) == [changed.id])
    }

    @Test("uploads includes every local document when the server manifest is empty")
    func uploadsIncludesEverythingWhenServerManifestEmpty() {
        let a = doc(courseID: "1", sourceID: "a", text: "a")
        let b = doc(courseID: "1", sourceID: "b", text: "b")
        let knowledge = CourseKnowledgeBase(courses: [course("1")], documents: [a, b])
        let request = SyncPlanner.uploads(local: knowledge, serverManifest: [], fullyFetched: [])
        #expect(Set(request.documents.map(\.id)) == Set([a.id, b.id]))
    }

    @Test("uploads lists fullySyncedCourses only for fully fetched courses, with sorted document ids")
    func uploadsFullySyncedCoursesSorted() throws {
        let doc1 = doc(courseID: "1", sourceID: "z", text: "z")
        let doc2 = doc(courseID: "1", sourceID: "a", text: "a")
        let doc3 = doc(courseID: "2", sourceID: "x", text: "x")
        let knowledge = CourseKnowledgeBase(courses: [course("1"), course("2")], documents: [doc1, doc2, doc3])
        let request = SyncPlanner.uploads(local: knowledge, serverManifest: [], fullyFetched: ["1"])
        #expect(request.fullySyncedCourses.count == 1)
        let entry = try #require(request.fullySyncedCourses.first)
        #expect(entry.courseID == "1")
        #expect(entry.documentIDs == entry.documentIDs.sorted())
        #expect(Set(entry.documentIDs) == Set([doc1.id, doc2.id]))
    }

    @Test("uploads sorts fullySyncedCourses entries by course id")
    func uploadsSortsFullySyncedCourseOrder() {
        let knowledge = CourseKnowledgeBase(courses: [course("2"), course("1")], documents: [doc(courseID: "1", sourceID: "a", text: "a"), doc(courseID: "2", sourceID: "b", text: "b")])
        let request = SyncPlanner.uploads(local: knowledge, serverManifest: [], fullyFetched: ["2", "1"])
        #expect(request.fullySyncedCourses.map(\.courseID) == ["1", "2"])
    }

    // MARK: - uploadBatches

    @Test("uploadBatches puts fullySyncedCourses only on the last batch")
    func uploadBatchesPutsFullySyncedCoursesOnLastBatchOnly() {
        let docs = (0..<5).map { CourseDocumentWire(document: doc(courseID: "1", sourceID: "\($0)", text: "t\($0)")) }
        let request = SyncUploadRequest(documents: docs, fullySyncedCourses: [FullySyncedCourse(courseID: "1", documentIDs: docs.map(\.id))])
        let batches = SyncPlanner.uploadBatches(request, maxDocuments: 2)
        #expect(batches.count == 3)
        #expect(batches.dropLast().allSatisfy { $0.fullySyncedCourses.isEmpty })
        #expect(batches.last?.fullySyncedCourses.count == 1)
        // Every document appears exactly once, across the batches.
        let allIDs = batches.flatMap { $0.documents.map(\.id) }
        #expect(Set(allIDs) == Set(docs.map(\.id)))
        #expect(allIDs.count == docs.count)
    }

    @Test("uploadBatches with no documents and fullySyncedCourses yields exactly one batch")
    func uploadBatchesEmptyDocumentsYieldsOneBatch() {
        let request = SyncUploadRequest(documents: [], fullySyncedCourses: [FullySyncedCourse(courseID: "1", documentIDs: [])])
        let batches = SyncPlanner.uploadBatches(request)
        #expect(batches.count == 1)
        #expect(batches[0].documents.isEmpty)
        #expect(batches[0].fullySyncedCourses.count == 1)
    }

    @Test("uploadBatches with documents fitting in one batch under maxDocuments")
    func uploadBatchesSingleBatchWhenUnderLimit() {
        let docs = (0..<3).map { CourseDocumentWire(document: doc(courseID: "1", sourceID: "\($0)", text: "t\($0)")) }
        let request = SyncUploadRequest(documents: docs, fullySyncedCourses: [FullySyncedCourse(courseID: "1", documentIDs: docs.map(\.id))])
        let batches = SyncPlanner.uploadBatches(request, maxDocuments: 200)
        #expect(batches.count == 1)
        #expect(batches[0].fullySyncedCourses.count == 1)
    }
}
