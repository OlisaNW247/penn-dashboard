import Foundation

/// One Canvas announcement as the megaphone sheet's "all announcements" list
/// remembers it: enough to show a row (class, date, title, a two-line
/// preview) and to open the original in Canvas, and nothing more.
///
/// **What is deliberately not here.** No author name, and no full body. The
/// sheet never needed either, and a field that is never stored cannot leak
/// from a backup, a crash report or a future "export". The snippet is the
/// first few hundred characters of the plain text, which is already what the
/// student's own Canvas shows in its list.
///
/// **Why this exists at all.** The megaphone used to list only the *tasks*
/// the announcement extractor managed to pull out of a post ("finds"). The
/// extractor is strict, finds expire, and only 14 days were ever fetched, so
/// the sheet was almost always empty and the button hid itself: students
/// reasonably read that as "announcements aren't there". This is the plain
/// list underneath.
public struct AnnouncementRecord: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// The Canvas announcement id (a decimal string). Unique per Canvas
    /// install, and the install is wiped on disconnect, so no school prefix.
    public let id: String
    public let courseID: String
    /// The course code the rest of the app keys on (`"PHYS 151"`): the same
    /// string `Assignment.course` carries, so hiding or deleting a class
    /// hides its announcements by exactly the rule the finds use.
    public let courseCode: String
    public let title: String
    /// Canvas's `posted_at`. Nil for an announcement Canvas sent undated;
    /// such a record is aged and sorted by `recordedAt` instead, so it can
    /// neither live forever nor outrank everything.
    public let postedAt: Date?
    /// Canvas's `html_url` for the post. Kept as received; the view decides
    /// whether it is safe to offer (`safeWebURL`).
    public let url: URL?
    /// Plain-text preview, at most `snippetLimit` characters.
    public let snippet: String
    /// When this device first logged the record. Only ever the age basis for
    /// an undated announcement (`sortDate`).
    public let recordedAt: Date
    /// True for an Ed "staff post": a staff-authored non-question that the Ed
    /// filter keeps as course material (`EdDocumentHeader.isStaffPost`), as
    /// opposed to an announcement or a pinned thread. Such a row is a
    /// *candidate* for the megaphone sheet and no more: it is listed only when
    /// the post's relevance judgment says it still matters (`AppState
    /// .announcementRecordsForSheet`), never by the 7-day window and never as
    /// its class's latest post, because most staff posts are answers and
    /// course notes and a sheet that listed them all would be the Ed board.
    /// Always false for a Canvas announcement and for an announcement or
    /// pinned Ed row.
    ///
    /// Defaulted, and absent from the stored form when false, so a log written
    /// before this field existed decodes unchanged (as `false`) and a Canvas
    /// record encodes byte for byte as it always did.
    public let isStaffPost: Bool

    public init(
        id: String,
        courseID: String,
        courseCode: String,
        title: String,
        postedAt: Date?,
        url: URL?,
        snippet: String,
        recordedAt: Date,
        isStaffPost: Bool = false
    ) {
        self.id = id
        self.courseID = courseID
        self.courseCode = courseCode
        self.title = title
        self.postedAt = postedAt
        self.url = url
        self.snippet = snippet
        self.recordedAt = recordedAt
        self.isStaffPost = isStaffPost
    }

    private enum CodingKeys: String, CodingKey {
        case id, courseID, courseCode, title, postedAt, url, snippet, recordedAt, isStaffPost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        courseID = try container.decode(String.self, forKey: .courseID)
        courseCode = try container.decode(String.self, forKey: .courseCode)
        title = try container.decode(String.self, forKey: .title)
        postedAt = try container.decodeIfPresent(Date.self, forKey: .postedAt)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        snippet = try container.decode(String.self, forKey: .snippet)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        isStaffPost = try container.decodeIfPresent(Bool.self, forKey: .isStaffPost) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(courseID, forKey: .courseID)
        try container.encode(courseCode, forKey: .courseCode)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(postedAt, forKey: .postedAt)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(snippet, forKey: .snippet)
        try container.encode(recordedAt, forKey: .recordedAt)
        if isStaffPost { try container.encode(true, forKey: .isStaffPost) }
    }

    /// Builds the record for a fetched announcement. `message` on a
    /// `CanvasAnnouncement` has already been flattened to text by
    /// `CanvasAnnouncementsClient`, and running `HTMLText` over text is a
    /// no-op for ordinary prose, so this accepts either.
    public init(announcement: CanvasAnnouncement, courseCode: String, recordedAt: Date) {
        self.init(
            id: announcement.id,
            courseID: announcement.courseID,
            courseCode: courseCode,
            title: announcement.title.trimmingCharacters(in: .whitespacesAndNewlines),
            postedAt: announcement.postedAt,
            url: announcement.url,
            snippet: Self.snippet(fromHTML: announcement.message),
            recordedAt: recordedAt
        )
    }

    // MARK: Snippet

    public static let snippetLimit = 280

    /// The preview text for `html`: tags (including whole `<style>` and
    /// `<script>` blocks) and entities removed by `HTMLText`, every run of
    /// whitespace, newlines included, collapsed to one space, then cut to at
    /// most `limit` characters at a word boundary.
    ///
    /// No ellipsis is appended. The sheet clamps the preview to two lines, so
    /// the stored text is never shown whole, and a trailing "…" would make
    /// "at most 280 characters" a lie about the stored value.
    ///
    /// A single unbroken run longer than the limit (a pasted URL) has no
    /// boundary to cut at, so it is cut hard rather than dropped: an empty
    /// preview would read as "nothing here".
    public static func snippet(fromHTML html: String, limit: Int = snippetLimit) -> String {
        // `HTMLText.plainText` removes `<style>`, `<script>` and comment
        // blocks with patterns whose `.` does not cross a newline, so a
        // multi-line block (what Word and Google Docs paste into a Canvas
        // post) survives it as visible CSS. `HTMLText` also feeds the
        // knowledge sync, so it is not changed here; the blocks are removed
        // first, with dot-matches-newline, and `HTMLText` does the rest.
        let withoutBlocks = html.replacingOccurrences(
            of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>|<!--.*?-->"#,
            with: " ",
            options: .regularExpression
        )
        return collapsedAndCut(HTMLText.plainText(from: withoutBlocks), limit: limit)
    }

    /// The preview for text that is already plain (an Ed post's body, which
    /// `EdDocumentText` converted from Ed's XML): whitespace collapsed and cut
    /// like `snippet(fromHTML:)`, but with no HTML pass. A plain-text body
    /// can legitimately contain `<` and `>` ("x < y and z > w"), and running
    /// `HTMLText` over it would delete everything between them as a tag. The
    /// `[image]` placeholders `EdDocumentText` writes where Ed had a picture
    /// are dropped: in a one-line preview they are noise, not content.
    public static func snippet(fromPlainText text: String, limit: Int = snippetLimit) -> String {
        collapsedAndCut(text.replacingOccurrences(of: "[image]", with: " "), limit: limit)
    }

    private static func collapsedAndCut(_ text: String, limit: Int) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > limit, limit > 0 else { return collapsed }

        let cutIndex = collapsed.index(collapsed.startIndex, offsetBy: limit)
        // The limit landing exactly on a space means the prefix is already
        // whole words.
        if collapsed[cutIndex].isWhitespace {
            return String(collapsed[..<cutIndex])
        }
        let head = collapsed[..<cutIndex]
        if let lastSpace = head.lastIndex(where: { $0.isWhitespace }) {
            return String(head[..<lastSpace])
        }
        return String(head)
    }

    // MARK: Ed Discussion rows

    /// What every Ed row's id starts with: the document id's own kind prefix
    /// (`ed:{canvasCourse}:{thread}`). Canvas announcement ids are decimal
    /// digits, so the two id spaces cannot meet.
    public static let edIDPrefix = "ed:"

    /// True for a row that came from an Ed Discussion document rather than a
    /// Canvas announcement. Derived from the id, which the one constructor
    /// (`edRecord`) builds from the document's, so it cannot disagree with it.
    public var isEd: Bool { id.hasPrefix(Self.edIDPrefix) }

    /// The "all announcements" row for an Ed document, or nil when the
    /// document is not one a student should see listed:
    ///
    /// - it must be an Ed document whose header reason is an announcement, a
    ///   pinned post, or a "staff post". A staff post is course material the
    ///   filter keeps, not news, so its row is marked (`isStaffPost`) and is
    ///   only ever listed when its relevance judgment says it still matters
    ///   (a TA's "No recitation today + HW 5" is such a post, and never
    ///   reached the sheet while only announcements and pins were rows);
    /// - it must carry text, not only `[image]` placeholders
    ///   (`EdDocumentHeader.carriesNoText`);
    /// - it must be dated, and within the log's 60 days. The date is the day
    ///   the thread was posted, from the header's `· posted` token
    ///   (`EdDocumentHeader.postedAt`), else the document's `updatedAt`. That
    ///   is the thread's last-activity date, which Ed moves on every edit,
    ///   reply and pin, so on its own it listed a Monday post as Saturday's;
    ///   it is only the fallback for a document synced before the token
    ///   existed. A row with no date has no place in a newest-first window.
    ///   The 60 days are measured on this same date, as `pruned` measures
    ///   them (`sortDate`), so an old thread bumped today does not appear
    ///   here only to be dropped one step later.
    ///
    /// Pure: reads the document and nothing else, never fetches, and never
    /// changes what Ed keeps. The snippet is the body after the bracketed
    /// header line, so `[ed · pinned] Homework / Hw 3` never shows.
    public static func edRecord(from document: CourseDocument, now: Date) -> AnnouncementRecord? {
        guard document.kind == .ed else { return nil }
        let header = EdDocumentHeader.parse(document.text)
        guard let posted = header.postedAt ?? document.updatedAt,
              posted >= now.addingTimeInterval(-AnnouncementLogStore.retention)
        else { return nil }
        guard header.isAnnouncementOrPinned || header.isStaffPost,
              !EdDocumentHeader.carriesNoText(document.text)
        else { return nil }
        return AnnouncementRecord(
            id: document.id,
            courseID: document.courseID,
            courseCode: document.course,
            title: document.title.trimmingCharacters(in: .whitespacesAndNewlines),
            postedAt: posted,
            url: document.url,
            snippet: snippet(fromPlainText: header.body),
            recordedAt: document.fetchedAt,
            isStaffPost: header.isStaffPost
        )
    }

    /// Every candidate Ed row among `documents`, newest first. A document id
    /// seen twice yields one row.
    ///
    /// The announcement and pinned rows keep the same 60-day, 300-row bounds
    /// as the log (`AnnouncementLogStore.pruned`), and the staff-post rows are
    /// bounded the same way **on their own**. Pruned together, a board with
    /// hundreds of staff posts would push the 300-row cut past the older
    /// announcements, and the sheet would lose a class's latest announcement
    /// to the very posts it lists only when they matter. The wrong version is
    /// one `pruned` call over both.
    public static func edRecords(from documents: [CourseDocument], now: Date) -> [AnnouncementRecord] {
        var seen = Set<String>()
        let rows = documents.compactMap { document -> AnnouncementRecord? in
            guard let row = edRecord(from: document, now: now), seen.insert(row.id).inserted else {
                return nil
            }
            return row
        }
        let news = AnnouncementLogStore.pruned(rows.filter { !$0.isStaffPost }, now: now)
        let staff = AnnouncementLogStore.pruned(rows.filter(\.isStaffPost), now: now)
        return (news + staff).sorted(by: AnnouncementRecord.isNewer(_:than:))
    }

    // MARK: Ordering and age

    /// The moment this record is aged and sorted by: when it was posted, or,
    /// for an undated one, when this device first saw it.
    public var sortDate: Date { postedAt ?? recordedAt }

    /// Newest first, with the id (numerically) as a stable tiebreak so two
    /// posts in the same second never swap places between launches.
    public static func isNewer(_ a: AnnouncementRecord, than b: AnnouncementRecord) -> Bool {
        if a.sortDate != b.sortDate { return a.sortDate > b.sortDate }
        return a.id.compare(b.id, options: .numeric) == .orderedDescending
    }

    // MARK: Link

    /// The URL, only when it is safe to hand to the system: `https` with a
    /// host. The same rule `Assignment.sourceLinks` applies to the finds'
    /// announcement links (`SourceLink.swift`), restated here because that
    /// check is private to its file. Anything else (`http`, `javascript:`,
    /// `file:`, relative) is dropped, so the row is simply not a link.
    public var safeWebURL: URL? {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    // MARK: Date label

    /// The short posted date for a row: "today", "yesterday", else "oct 3".
    /// Nil when the announcement came without a date, so the row shows none
    /// rather than a made-up one. Pure: `now`, `calendar` and `locale` are
    /// arguments so a test can pin all three.
    public func postedLabel(
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        guard let postedAt else { return nil }
        if calendar.isDate(postedAt, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(postedAt, inSameDayAs: yesterday) {
            return "yesterday"
        }
        return PostedDateFormatters.string(from: postedAt, calendar: calendar, locale: locale).lowercased()
    }

    // MARK: Join with the extractor's finds

    /// The ledger `sourceID` of the `index`th task the extractor found in an
    /// announcement. The one place this format is written: `AppState
    /// .announcementAssignments` builds finds through it, and
    /// `announcementID(fromFindSourceID:)` reads it back, so the sheet's
    /// "task found" tag cannot drift from what the ledger holds.
    public static func findSourceID(announcementID: String, index: Int) -> String {
        "announcement-\(announcementID)-\(index)"
    }

    /// Inverse of `findSourceID`: the announcement a find came from, or nil
    /// for a `sourceID` of any other shape. Canvas ids are digits, so the
    /// last hyphen always separates the id from the numeric index.
    public static func announcementID(fromFindSourceID sourceID: String) -> String? {
        let prefix = "announcement-"
        guard sourceID.hasPrefix(prefix) else { return nil }
        let rest = sourceID.dropFirst(prefix.count)
        guard let hyphen = rest.lastIndex(of: "-") else { return nil }
        let id = rest[..<hyphen]
        let index = rest[rest.index(after: hyphen)...]
        guard !id.isEmpty, !index.isEmpty, index.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return String(id)
    }

    // MARK: Ed finds
    //
    // A task found in an Ed post is a `.canvasAnnouncement` ledger row whose
    // `sourceID` starts with `ed-` instead of `announcement-` (see
    // `AnnouncementOrigin`, which reads the origin back from this prefix).
    // There is deliberately no new `Assignment.Source` and no new stored
    // column: `sourceRaw` is a free string and `Assignment.Source(rawValue:)
    // ?? .canvas` is what a build that does not know a value falls back to, so
    // a new raw value would show a newer build's Ed rows to an older one as
    // Canvas calendar items (wrong source, and an id that no longer matches the
    // row's stored id, so ticking one off would never stick). A new column
    // would be a SwiftData schema change, and an older build opening a store
    // from a newer schema falls back to an empty in-memory ledger. A prefix on
    // the id changes neither: an older build reads these as announcement rows,
    // which is exactly what they are.

    /// What every Ed find's `sourceID` starts with. Canvas finds start with
    /// `announcement-`, so the two cannot meet.
    public static let edFindSourcePrefix = "ed-"

    /// The ledger `sourceID` of the `index`th task found in an Ed thread:
    /// `ed-{canvasCourseID}-{threadID}-{index}`. The one place the format is
    /// written; `edDocumentID(fromFindSourceID:)` reads it back.
    public static func edFindSourceID(courseID: String, threadID: String, index: Int) -> String {
        "\(edFindSourcePrefix)\(courseID)-\(threadID)-\(index)"
    }

    /// Inverse of `edFindSourceID`: the id of the Ed document the find came
    /// from (`ed:{courseID}:{threadID}`, the same string the sheet's Ed rows
    /// use as their `id`), or nil for a `sourceID` of any other shape. Thread
    /// ids and indexes are digits, so the last two hyphens separate the
    /// three parts.
    public static func edDocumentID(fromFindSourceID sourceID: String) -> String? {
        guard sourceID.hasPrefix(edFindSourcePrefix) else { return nil }
        let rest = sourceID.dropFirst(edFindSourcePrefix.count)
        guard let indexHyphen = rest.lastIndex(of: "-") else { return nil }
        let index = rest[rest.index(after: indexHyphen)...]
        let head = rest[..<indexHyphen]
        guard let threadHyphen = head.lastIndex(of: "-") else { return nil }
        let thread = head[head.index(after: threadHyphen)...]
        let course = head[..<threadHyphen]
        guard !course.isEmpty,
              !thread.isEmpty, thread.allSatisfy({ $0.isASCII && $0.isNumber }),
              !index.isEmpty, index.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return "\(edIDPrefix)\(course):\(thread)"
    }

    /// The id the sheet's "all announcements" list files the source post
    /// under, from a find's `sourceID`: the Canvas announcement id, or the Ed
    /// document id. Nil for a `sourceID` of any other shape. This is the join
    /// behind the small "task found" tag on a row.
    public static func recordID(fromFindSourceID sourceID: String) -> String? {
        announcementID(fromFindSourceID: sourceID) ?? edDocumentID(fromFindSourceID: sourceID)
    }

    // MARK: Syllabus exams
    //
    // An exam read out of a course's syllabus (`SyllabusExamRows`) is filed the
    // way an Ed find is: a `.canvasAnnouncement` row whose `sourceID` starts
    // with `syllabus-`. Same reasoning as for `ed-` above, and it is worth
    // repeating because the temptation is stronger here, where the row is not
    // an announcement at all: a `Source.syllabus` case would read back as
    // `.canvas` on a build that does not know it (wrong source, and an id that
    // no longer matches the stored one, so a tick would not stick), and a new
    // column is a schema change an older build answers with an empty ledger.
    // The prefix costs neither, and everything the announcement rows already
    // have (going off the dashboard once past, the duplicate check, the completion carry, the
    // purge on disconnect) applies to these without a second copy.
    //
    // The prefix also keeps these rows out of `announcementID(fromFindSourceID:)`
    // (which wants `announcement-`), so `reconcileAnnouncementPresence` can
    // never judge one "deleted" because no Canvas post carries its id.

    /// What every syllabus exam's `sourceID` starts with. Canvas finds start
    /// with `announcement-` and Ed finds with `ed-`, so none of the three
    /// can meet.
    public static let syllabusFindSourcePrefix = "syllabus-"

    /// The ledger `sourceID` of one exam in one Canvas site's course material:
    /// `syllabus-{canvasCourseID}-{examKey}`, where `examKey` is
    /// `ExamIdentity.sourceKey` ("midterm-1", "final", "midterm-1-makeup").
    ///
    /// It is built from the exam's identity and **not** from its date or its
    /// wording, so the same exam keeps one id when the instructor moves it or
    /// rewrites the line: a completion, a due-date edit and the ledger row
    /// all follow the exam instead of orphaning at every correction. The
    /// Canvas course id (not the course code) is the scope because it is what
    /// the document carries, and because a code can come back in a later term
    /// where a site id cannot.
    public static func syllabusFindSourceID(courseID: String, examKey: String) -> String {
        "\(syllabusFindSourcePrefix)\(courseID)-\(examKey)"
    }
}

/// Where a task found in an announcement came from. Not stored: derived from
/// the row's `sourceID` (`AnnouncementRecord.edFindSourceID` vs `findSourceID`
/// vs `syllabusFindSourceID`), so it cannot disagree with it and costs the
/// ledger nothing.
public enum AnnouncementOrigin: String, Sendable, Equatable {
    case canvas
    case ed
    /// Not an announcement: an exam the syllabus names next to a date.
    case syllabus
}

extension Assignment {
    /// The origin of an announcement-derived row, nil for every other source.
    /// A `.canvasAnnouncement` row with neither the Ed nor the syllabus prefix
    /// is Canvas: that is every row written before Ed existed, whatever shape
    /// its `sourceID` has.
    public var announcementOrigin: AnnouncementOrigin? {
        guard source == .canvasAnnouncement else { return nil }
        if sourceID.hasPrefix(AnnouncementRecord.edFindSourcePrefix) { return .ed }
        if sourceID.hasPrefix(AnnouncementRecord.syllabusFindSourcePrefix) { return .syllabus }
        return .canvas
    }
}

/// On-device persistence for `AnnouncementRecord`s: one JSON file beside
/// `course-knowledge.json` in the app's own Application Support directory.
///
/// Like `CourseKnowledgeStore`, this is none of the three storage tiers
/// `CLAUDE.md` names. It is not the ledger (nothing here is the student's own
/// record: every byte can be re-fetched from Canvas, and a lost file costs
/// one sync), not a preference, and not a credential. It is a cache of
/// re-fetchable text, so a plain file the app can throw away and rebuild is
/// the right weight, and it is app-private rather than in the App Group
/// because the widget has no use for it.
///
/// Canvas-derived, so disconnecting Canvas clears it (`AppState
/// .disconnectCanvas`), and it never leaves the phone: nothing reads it to
/// build a request.
public struct AnnouncementLogStore: Sendable {
    /// How long a record is kept, measured on `AnnouncementRecord.sortDate`.
    /// Also the window `syncAnnouncements` asks Canvas for.
    public static let retentionDays = 60
    /// Hard cap, newest first. Sixty days of announcements across a full
    /// course load is far below this; it only bounds a pathological feed.
    public static let maxRecords = 300

    public static var retention: TimeInterval { TimeInterval(retentionDays) * 24 * 60 * 60 }

    public let fileURL: URL

    /// The app's store, in the same directory as `CourseKnowledgeStore`'s
    /// file (Application Support/LowHangingFruit/).
    public static func `default`() -> AnnouncementLogStore {
        AnnouncementLogStore(
            directory: CourseKnowledgeStore.default().fileURL.deletingLastPathComponent()
        )
    }

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("announcement-log.json")
    }

    /// The saved records (pruned as of `now`), or nil when there is no usable
    /// file: never written, or unreadable. The distinction is the point:
    /// nil means "this install has not filled the log yet", which is what
    /// lets the first fill count as already seen. A damaged file reads as
    /// nil too, so it re-seeds quietly instead of flooding the badge.
    public func loadIfPresent(now: Date = Date()) -> [AnnouncementRecord]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let file = try? decoder.decode(LogFile.self, from: data) else { return nil }
        return Self.pruned(file.records, now: now)
    }

    /// `loadIfPresent`, with "nothing usable" as an empty list.
    public func load(now: Date = Date()) -> [AnnouncementRecord] {
        loadIfPresent(now: now) ?? []
    }

    /// Writes `records` after pruning them (older than `retentionDays` goes,
    /// then the newest `maxRecords` stay), atomically, and returns what was
    /// written. An empty list is still written: the file's existence is what
    /// records "the log has been filled once".
    @discardableResult
    public func save(_ records: [AnnouncementRecord], now: Date = Date()) throws -> [AnnouncementRecord] {
        let kept = Self.pruned(records, now: now)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(LogFile(version: 1, records: kept))
        try data.write(to: fileURL, options: .atomic)
        return kept
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Pure rules

    /// Drops records older than `retentionDays` as of `now`, orders newest
    /// first, and keeps at most `maxRecords`.
    public static func pruned(_ records: [AnnouncementRecord], now: Date) -> [AnnouncementRecord] {
        let cutoff = now.addingTimeInterval(-retention)
        let fresh = records
            .filter { $0.sortDate >= cutoff }
            .sorted(by: AnnouncementRecord.isNewer(_:than:))
        return Array(fresh.prefix(maxRecords))
    }

    /// `incoming` laid over `existing`, one record per id. A re-fetched
    /// announcement replaces the stored copy (a professor edits a post), but
    /// keeps the original `recordedAt`, so an undated record's age does not
    /// restart on every sync. Records Canvas did not return this time stay:
    /// the fetch is a window, not a census, and a missing row is not proof of
    /// deletion.
    public static func merged(
        existing: [AnnouncementRecord],
        incoming: [AnnouncementRecord],
        now: Date
    ) -> [AnnouncementRecord] {
        var byID: [String: AnnouncementRecord] = [:]
        for record in existing { byID[record.id] = record }
        for record in incoming {
            let firstSeen = byID[record.id]?.recordedAt ?? record.recordedAt
            byID[record.id] = AnnouncementRecord(
                id: record.id,
                courseID: record.courseID,
                courseCode: record.courseCode,
                title: record.title,
                postedAt: record.postedAt,
                url: record.url,
                snippet: record.snippet,
                recordedAt: firstSeen
            )
        }
        return pruned(Array(byID.values), now: now)
    }

    /// The on-disk shape. A version field so a future change can tell an old
    /// file from a new one; an unreadable file is treated as absent.
    private struct LogFile: Codable {
        var version: Int
        var records: [AnnouncementRecord]
    }
}

/// One `DateFormatter` per (locale, calendar, time zone), made once and
/// reused. The sheet asks for a label per row, and building a `DateFormatter`
/// (and parsing its template) is among the slower things a row can do; with
/// up to a few hundred rows that was a visible cost on opening the sheet. The
/// key names everything the output depends on, so a student who changes time
/// zone or region gets a fresh formatter rather than the old one's answer.
///
/// `DateFormatter` is not `Sendable`, so access is serialized by a lock and
/// the instances never leave this type.
private final class PostedDateFormatters: @unchecked Sendable {
    private static let shared = PostedDateFormatters()
    private let lock = NSLock()
    private var formatters: [String: DateFormatter] = [:]

    static func string(from date: Date, calendar: Calendar, locale: Locale) -> String {
        shared.string(from: date, calendar: calendar, locale: locale)
    }

    /// The cached formatter's identity for this (locale, calendar, time zone),
    /// or nil when none has been built. Lets a test pin reuse (the same
    /// object every call) without counting a process-wide total that other
    /// tests running alongside would disturb.
    static func identity(calendar: Calendar, locale: Locale) -> ObjectIdentifier? {
        shared.identity(forKey: key(calendar: calendar, locale: locale))
    }

    private static func key(calendar: Calendar, locale: Locale) -> String {
        "\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
    }

    private func identity(forKey key: String) -> ObjectIdentifier? {
        lock.lock(); defer { lock.unlock() }
        return formatters[key].map { ObjectIdentifier($0) }
    }

    private func string(from date: Date, calendar: Calendar, locale: Locale) -> String {
        let key = Self.key(calendar: calendar, locale: locale)
        lock.lock(); defer { lock.unlock() }
        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            formatters[key] = formatter
        }
        return formatter.string(from: date)
    }
}

extension AnnouncementRecord {
    /// Test hook: identity of the cached posted-date formatter for this
    /// locale, calendar and time zone, or nil if none has been built yet.
    static func postedFormatterIdentity(calendar: Calendar, locale: Locale) -> ObjectIdentifier? {
        PostedDateFormatters.identity(calendar: calendar, locale: locale)
    }
}
