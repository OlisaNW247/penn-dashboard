import Foundation

/// Pure planning logic for the `sync` function's manifest exchange
/// (`backend/PROTOCOL.md`, "sync — manifest exchange, then upload"). Nothing
/// here touches the network or the Canvas session; a future network-facing
/// coordinator calls these functions around the actual HTTP round trips, so
/// the decisions — what to fetch, what to upload, how to batch it — can be
/// tested against fixtures instead of a live server.
public enum SyncPlanner {
    /// What the client should do after reading a `SyncManifestResponse`:
    /// which courses are fresh enough on the server to skip a Canvas fetch
    /// this run, and which still need one.
    public struct SyncPlan: Equatable, Sendable {
        public let coursesToFetch: [CourseSummary]
        public let coursesFresh: Set<String>

        public init(coursesToFetch: [CourseSummary], coursesFresh: Set<String>) {
            self.coursesToFetch = coursesToFetch
            self.coursesFresh = coursesFresh
        }
    }

    /// Splits the student's enrolled courses into "server already has a full
    /// sync newer than FRESH_WINDOW" (skip the Canvas fetch for these;
    /// announcements are still fetched for every course regardless, per the
    /// protocol) and everything else. Preserves the caller's original
    /// ordering rather than sorting, so a course list built for display
    /// doesn't reshuffle between syncs for no reason visible to the student.
    public static func plan(courses: [CourseSummary], manifest: SyncManifestResponse) -> SyncPlan {
        let fresh = Set(manifest.coursesFresh)
        let toFetch = courses.filter { !fresh.contains($0.courseID) }
        return SyncPlan(coursesToFetch: toFetch, coursesFresh: fresh)
    }

    /// Applies the server's `download` batch to the local knowledge base.
    /// Per protocol this runs *before* any Canvas fetch this cycle: "Client:
    /// applies `download` to local knowledge first."
    ///
    /// `resyncedCourseIDs` is passed as empty on purpose, not as the set of
    /// courses the downloads mention. `CourseKnowledgeBase.merge` only drops
    /// a course's existing documents when that course is listed as
    /// resynced — its contract is "I just re-enumerated every live document
    /// for this course from the source of truth, so anything old not in
    /// this new list is gone." A `download` batch is never that: the
    /// manifest request already told the server every `(id, contentHash)`
    /// the client holds, so `download` is only the *changed* documents, not
    /// a full listing of everything live for the course. Treating it as a
    /// full resync would let a partial `download` silently erase local
    /// documents the server simply had no reason to mention — the same
    /// wholesale-replace failure mode `StoredAssignment`'s `reconcile()` was
    /// written to avoid on the ledger side (see CLAUDE.md, "The ledger is
    /// the point"). With `resyncedCourseIDs` empty, `merge` only ever adds
    /// or updates documents here; a download can never remove one.
    ///
    /// Documents whose `CourseDocumentWire.document()` conversion fails
    /// (an unrecognized `kind` or a tampered `id`) are silently skipped
    /// rather than aborting the whole batch — one bad entry shouldn't cost
    /// the rest of the sync.
    public static func applyDownloads(
        _ downloads: [CourseDocumentWire],
        to knowledge: inout CourseKnowledgeBase,
        courses: [CourseSummary],
        now: Date
    ) {
        let documents = downloads.compactMap { $0.document() }
        knowledge.merge(courses: courses, documents: documents, resyncedCourseIDs: [], syncedAt: now)
    }

    /// Applies `SyncManifestResponse.catalog` to the local knowledge base.
    /// A thin wrapper over `CourseKnowledgeBase.mergeCatalog` rather than
    /// folding the catalog into `applyDownloads`'s signature: the manifest
    /// response carries both `download` and `catalog` at once, but they're
    /// two independent pieces of data with two independent merge rules (one
    /// keyed by document id, one keyed by course id), and giving each its
    /// own small function keeps `applyDownloads`'s existing signature and
    /// every existing call/test of it untouched.
    public static func applyCatalog(_ entries: [CourseCatalogEntry], to knowledge: inout CourseKnowledgeBase) {
        knowledge.mergeCatalog(entries)
    }

    /// Builds the upload half of the manifest exchange: only documents the
    /// server doesn't already have byte-for-byte (matched by id *and*
    /// `contentHash`, so an edited document re-uploads even though its id
    /// is unchanged and a stale server copy is replaced), plus one
    /// `FullySyncedCourse` entry per course the client fetched completely
    /// from Canvas this run, listing every document id it now holds for
    /// that course, so the server can mark vanished documents gone for
    /// exactly those courses and no others.
    /// - Parameter links: this run's `CourseKnowledgeCollector.Report.links`
    ///   (already deduplicated and capped there). Defaulted to `[]` so
    ///   existing call sites keep compiling; forwarded onto the request
    ///   unfiltered — the server, not the client, decides which links are
    ///   worth crawling.
    public static func uploads(
        local: CourseKnowledgeBase,
        serverManifest: [DocumentStub],
        fullyFetched: Set<String>,
        links: [CourseLink] = []
    ) -> SyncUploadRequest {
        let known = Set(serverManifest)
        let documents = local.documents
            .filter { !known.contains(DocumentStub(document: $0)) }
            .sorted { $0.id < $1.id }
            .map { CourseDocumentWire(document: $0) }

        let fullySyncedCourses = fullyFetched.sorted().map { courseID in
            FullySyncedCourse(courseID: courseID, documentIDs: local.documents(for: courseID).map(\.id).sorted())
        }

        return SyncUploadRequest(documents: documents, fullySyncedCourses: fullySyncedCourses, links: links.map(CourseLinkWire.init(link:)))
    }

    /// Splits an upload into batches under the protocol's 6 MB body cap.
    /// `maxDocuments` is a document-count proxy for that cap rather than an
    /// actual byte budget: the server counts bytes, but the client doesn't
    /// have an easy way to know the encoded size of documents it hasn't
    /// serialized yet, and 200 documents of course-material text is a
    /// conservative stand-in for "well under 6 MB" in practice.
    ///
    /// `fullySyncedCourses` and `links` both ride only on the last batch.
    /// The server only marks a fully-synced course's vanished documents
    /// gone once every live document for that course has actually arrived;
    /// attaching `fullySyncedCourses` to an earlier batch would tell the
    /// server that before it was true, and it could mark documents in a
    /// later batch gone before they ever land. `links` has no such ordering
    /// hazard — it exists to piggyback on the same request rather than earn
    /// its own — but there is equally no reason to repeat it on every
    /// batch, so it follows `fullySyncedCourses`'s placement.
    public static func uploadBatches(_ request: SyncUploadRequest, maxDocuments: Int = 200) -> [SyncUploadRequest] {
        guard !request.documents.isEmpty else {
            // No documents to chunk, but there may still be courses to
            // report as fully synced (e.g. a course with zero documents
            // this run) — that's one batch, not zero.
            return [SyncUploadRequest(documents: [], fullySyncedCourses: request.fullySyncedCourses, links: request.links)]
        }

        var batches: [SyncUploadRequest] = []
        var index = 0
        while index < request.documents.count {
            let end = min(index + max(maxDocuments, 1), request.documents.count)
            let chunk = Array(request.documents[index..<end])
            let isLastBatch = end == request.documents.count
            batches.append(SyncUploadRequest(
                documents: chunk,
                fullySyncedCourses: isLastBatch ? request.fullySyncedCourses : [],
                links: isLastBatch ? request.links : []
            ))
            index = end
        }
        return batches
    }
}
