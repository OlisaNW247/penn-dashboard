import Foundation

extension CourseDocumentBuilder {
    /// A PDF text shorter than this is a scan (or a cover sheet): nothing to read.
    public static let fileMinimumTextLength = 50
    /// UTF-16 code units, and the pages read. These two caps MUST stay equal to
    /// the Chrome extension's (`FILE_TEXT_MAX_CHARS` in
    /// `chrome-extension/src/core/canvasDocuments.js`, and its PDF page limit):
    /// the content hash covers the text, so a different cap makes one shared
    /// file ping-pong between the two collectors, each re-uploading over the
    /// other. (The server's own limit is 200,000, far above this.)
    public static let fileTextCap = 60_000
    public static let filePDFMaxPages = 60

    /// The `file` document for one Canvas PDF, shaped field for field like the
    /// Chrome extension's (`fileDocument` in `canvasDocuments.js`: kind
    /// `file`, `sourceID` the file id, `title` the display name, `url`
    /// `https://<host>/courses/<course>/files/<id>`) so the two collectors
    /// address one server row. `nil` for a PDF with no readable text.
    public static func file(
        metadata: CanvasFileMetadata,
        fileID: String,
        pdf: Data,
        course: CourseSummary,
        baseURL: URL,
        now: Date = Date()
    ) -> CourseDocument? {
        guard let extracted = SyllabusTextExtractor.text(fromPDF: pdf, maxPages: filePDFMaxPages) else { return nil }
        var text = extracted
        if text.utf16.count > fileTextCap {
            // Like the extension's `.slice`, without leaving half a surrogate pair.
            var units = Array(text.utf16.prefix(fileTextCap))
            if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
            text = String(decoding: units, as: UTF16.self)
        }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= fileMinimumTextLength,
              let host = baseURL.host else { return nil }
        return CourseDocument(
            courseID: course.courseID,
            course: course.code,
            kind: .file,
            sourceID: fileID,
            title: metadata.displayName,
            url: URL(string: "https://\(host)/courses/\(course.courseID)/files/\(fileID)"),
            text: text,
            updatedAt: metadata.updatedAt,
            fetchedAt: now
        )
    }
}

/// Runs one attachment pass's network and PDF work. Nothing here touches app
/// state: the caller merges, saves and uploads what comes back.
public enum AssignmentAttachmentRunner {
    public struct Outcome: Sendable {
        public struct Record: Sendable, Equatable {
            public let id: String
            public let kind: AssignmentAttachmentAttempt.Kind
        }
        public var documents: [CourseDocument] = []
        /// Every id this run asked Canvas about (a dead-session id is not), with
        /// how it ended.
        public var attempted: [Record] = []
        public var planned = 0
        public var fetched = 0
        public var skipped = 0
        public var firstFailure: String?

        public init() {}

        public var attemptedIDs: [String] { attempted.map(\.id) }

        /// Counts and words only: never a title or URL.
        public var summary: String {
            var s = "planned \(planned) · fetched \(fetched) · pooled \(documents.count) · skipped \(skipped)"
            if let firstFailure { s += " · first failure \(firstFailure)" }
            return s
        }
    }

    /// Runs the plan inside a task group raced against the budget, so a
    /// trickling download is cancelled at the deadline instead of outliving it.
    /// Whatever finished before the cancel is returned.
    public static func run(
        plan: [AssignmentAttachmentFetch],
        client: CanvasFilesClient,
        courses: [CourseSummary],
        baseURL: URL,
        now: Date = Date(),
        budget: TimeInterval = 60
    ) async -> Outcome {
        await withTaskGroup(of: Outcome?.self) { group in
            group.addTask { await loop(plan: plan, client: client, courses: courses, baseURL: baseURL, now: now) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(budget, 0) * 1_000_000_000))
                return nil
            }
            var result = Outcome()
            result.planned = plan.count
            for await finished in group {
                if let finished { result = finished }
                group.cancelAll()
            }
            return result
        }
    }

    private static func loop(
        plan: [AssignmentAttachmentFetch],
        client: CanvasFilesClient,
        courses: [CourseSummary],
        baseURL: URL,
        now: Date
    ) async -> Outcome {
        var outcome = Outcome()
        outcome.planned = plan.count
        // Canvas answers 401 for "not allowed" (a course hiding its Files) as
        // well as "signed out". The first 401 asks /users/self once: alive
        // means that file is skipped and the run goes on; otherwise it stops.
        var sessionKnownAlive = false
        for item in plan {
            if Task.isCancelled { break }
            guard let course = courses.first(where: { $0.courseID == item.courseID }) else {
                outcome.skipped += 1
                continue
            }
            do {
                switch try await client.pdf(fileID: item.fileID) {
                case let .pdf(meta, data):
                    outcome.fetched += 1
                    if let doc = CourseDocumentBuilder.file(metadata: meta, fileID: item.fileID, pdf: data,
                                                            course: course, baseURL: baseURL, now: now) {
                        outcome.documents.append(doc)
                        outcome.attempted.append(.init(id: item.fileID, kind: .pooled))
                    } else {
                        // A scan or a short PDF: no text will appear tomorrow.
                        outcome.skipped += 1
                        outcome.attempted.append(.init(id: item.fileID, kind: .noText))
                    }
                case let .skipped(reason):
                    outcome.skipped += 1
                    outcome.attempted.append(.init(id: item.fileID, kind: reason == .unavailable ? .failed : .noText))
                }
            } catch CanvasFilesClient.Error.sessionExpired {
                if !sessionKnownAlive { sessionKnownAlive = await client.sessionIsAlive() }
                if Task.isCancelled { break }
                if sessionKnownAlive {
                    outcome.attempted.append(.init(id: item.fileID, kind: .failed))
                    outcome.skipped += 1
                    continue
                }
                outcome.firstFailure = outcome.firstFailure ?? "sessionExpired"
                break
            } catch {
                // A cancel at the deadline is not a failure of this file.
                if Task.isCancelled { break }
                outcome.attempted.append(.init(id: item.fileID, kind: .failed))
                outcome.firstFailure = outcome.firstFailure ?? kind(of: error)
            }
        }
        return outcome
    }

    static func kind(of error: Swift.Error) -> String {
        if let e = error as? CanvasFilesClient.Error {
            switch e {
            case .sessionExpired: return "sessionExpired"
            case let .http(status): return "http \(status)"
            case .notHTTP: return "notHTTP"
            case .invalidJSON: return "invalidJSON"
            case .tooLarge: return "tooLarge"
            }
        }
        return (error is URLError) ? "network" : "other"
    }
}
