import Foundation

/// Reads back the one-line header `EdDocumentBuilder.text(for:decision:)`
/// writes at the top of an Ed document: `[ed · pinned] Homework / Hw 3`, then
/// the body on the following lines.
///
/// **Why this exists.** The builder writes the header so a model reading an
/// excerpt knows where it came from, and so the category words reach the
/// keyword index. Everything that *shows* an Ed document to a student, or
/// decides what it is, then needs the other half of that bargain: which
/// reason the header carries (an announcement and a pinned post are
/// something a student asks "latest announcements" about; a plain staff post
/// is not), and the body without the bracketed bookkeeping, which reads as
/// noise in a sentence. This type is that reader. It parses nothing the
/// builder does not write and fetches nothing, so it cannot change what is
/// kept or stored.
///
/// **The two halves must not drift.** The format lives in the builder; the
/// reader repeats the one literal it needs (`[ed · `). The wrong fix for a
/// future change of the header is to edit only one side: every Ed document
/// already on a student's phone, and in the pooled copy, keeps the old
/// header until it is re-synced, and a reader that quietly stopped matching
/// would make every Ed post look like it has no reason, with nothing failing.
/// `EdDocumentHeaderTests` round-trips real builder output for each reason
/// the filter can produce, so a change to either side fails there first.
///
/// Text with no header (an older document, or a body that is not from the
/// builder at all) is not an error: `reason` is `nil` and `body` is the text
/// whole.
public struct EdDocumentHeader: Sendable, Equatable {
    /// The filter's reason for keeping the thread: "announcement", "pinned"
    /// or "staff post". `nil` when the text carries no header.
    public let reason: String?
    /// The category words after the bracket (`Homework / Hw 3`), or `nil`.
    public let category: String?
    /// Everything after the header line, exactly as the builder wrote it. The
    /// whole text when there is no header.
    public let body: String

    public init(reason: String?, category: String?, body: String) {
        self.reason = reason
        self.category = category
        self.body = body
    }

    /// What opens every builder header; the reason follows it, closed by `]`.
    private static let opening = "[ed · "
    private static let closing: Character = "]"

    /// A staff announcement: the thread's type is "announcement".
    public var isAnnouncement: Bool { reason == "announcement" }

    /// A pinned thread (only course staff can pin).
    public var isPinned: Bool { reason == "pinned" }

    /// The two reasons worth listing under "latest announcements". A plain
    /// "staff post" is deliberately not one: it is a staff-authored
    /// non-question that the filter keeps as course material, not something
    /// the staff addressed to the class as news.
    public var isAnnouncementOrPinned: Bool { isAnnouncement || isPinned }

    public static func parse(_ text: String) -> EdDocumentHeader {
        let lineEnd = text.firstIndex(of: "\n") ?? text.endIndex
        let firstLine = text[..<lineEnd]
        guard let opened = firstLine.range(of: opening, options: .anchored),
              let closed = firstLine[opened.upperBound...].firstIndex(of: closing)
        else {
            return EdDocumentHeader(reason: nil, category: nil, body: text)
        }
        let reason = firstLine[opened.upperBound..<closed].trimmingCharacters(in: .whitespaces)
        guard !reason.isEmpty else {
            return EdDocumentHeader(reason: nil, category: nil, body: text)
        }
        let category = firstLine[firstLine.index(after: closed)...].trimmingCharacters(in: .whitespaces)
        let body = lineEnd == text.endIndex ? "" : String(text[text.index(after: lineEnd)...])
        return EdDocumentHeader(reason: reason, category: category.isEmpty ? nil : category, body: body)
    }

    /// True when `text`, once its header is set aside, holds nothing a reader
    /// could use: no body at all, or only the `[image]` placeholders
    /// `EdDocumentText` writes where Ed had a picture. Such a post matches a
    /// search on its title and category words alone and then gives the model
    /// (or the student) nothing to read, so `ask` leaves it out of the
    /// excerpts it picks. The test is "no letter or digit left once the
    /// placeholders are removed", so the bullet or quote marker the converter
    /// puts before an image (`- [image]`, `> [image]`) does not count as text.
    public static func carriesNoText(_ text: String) -> Bool {
        let remaining = parse(text).body.replacingOccurrences(of: "[image]", with: "")
        return !remaining.contains { $0.isLetter || $0.isNumber }
    }
}

/// What the on-device answerer and the `ask` excerpt picker need to know about
/// a search hit that came from an Ed Discussion post. Both read the passage
/// through `EdDocumentHeader`, so the two stay in step with the builder.
extension SearchHit {
    /// An Ed passage with nothing to read once the header is set aside: no
    /// body at all, or only `[image]` placeholders (`EdDocumentHeader
    /// .carriesNoText`). Always `false` for any other kind of document.
    public var isTextlessEdPost: Bool {
        document.kind == .ed && EdDocumentHeader.carriesNoText(passage.text)
    }

    /// This hit with an Ed passage's header line removed, for showing to a
    /// student or handing to a model as grounding. The first passage of an Ed
    /// document opens with `[ed · pinned] Homework / Hw 3`; later passages
    /// and every other kind of document have no such line and come back
    /// unchanged. Identity (`passage.id`, the document, the score and the
    /// component) is kept, so nothing that keys on the hit notices.
    public var withoutEdHeader: SearchHit {
        guard document.kind == .ed else { return self }
        let body = EdDocumentHeader.parse(passage.text).body
        guard body != passage.text else { return self }
        return SearchHit(
            passage: Passage(documentID: passage.documentID, ordinal: passage.ordinal, text: body),
            document: document, score: score, component: component
        )
    }
}
