import Foundation
import LowHangingFruitKit

// MARK: – Turning a citation into a link

extension AssistantCitation {
    /// `url` only when it is safe to hand to the system: `https` with a host.
    /// The same rule `Assignment.sourceLinks` applies to card links
    /// (`Models/SourceLink.swift`) and `AnnouncementRecord.safeWebURL` restates
    /// for the announcement finds. That check is `private` to its file, so
    /// this mirrors it rather than reaching it; anything else (`http`,
    /// `javascript:`, `file:`, a relative URL) is dropped and the chip stays
    /// plain text.
    ///
    /// One shape more is refused: a Canvas calendar grid
    /// (`/calendar?include_contexts=…#assignment_<id>`). The ICS feed stores
    /// that as a work item's URL, and `SourceLink.swift` documents why it is
    /// not the page a student wants: it opens the month, not the assignment.
    /// On-device answers about what is due cite work items, so without this
    /// the commonest chip would open the wrong page. A wrong link is worse
    /// than none.
    static func linkable(_ url: URL?) -> URL? {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.path != "/calendar"
        else { return nil }
        return url
    }
}

/// One document that rode along in the `excerpts` of a single `ask` turn.
///
/// The phone keeps these for the length of the turn, beside the request and
/// not in it (the wire request is unchanged), so the model's trailing
/// `<sources>COURSE|kind|detail</sources>` can be matched back to the
/// document it was drawn from. The server cannot return URLs; the phone is
/// the only party that knows which documents it just sent.
struct ExcerptSource: Sendable, Equatable {
    let documentID: String
    let course: String
    let kind: CourseDocument.Kind
    let title: String
    let url: URL?

    init(document: CourseDocument) {
        self.documentID = document.id
        self.course = document.course
        self.kind = document.kind
        self.title = document.title
        self.url = document.url
    }
}

enum CitationLinks {
    /// Gives a citation the URL of the one excerpt document it names, and
    /// leaves every other citation exactly as it came.
    ///
    /// **The rule, all of it.** A citation is linked only when exactly one
    /// *document* among the turn's excerpts satisfies all three:
    /// 1. **course**: `CourseMatcher.normalize` of the citation's course
    ///    equals that of the document's course code ("CIS2400", "cis 2400"
    ///    and "CIS 2400-001" are one course; nothing else is);
    /// 2. **kind**: the citation's kind word, case-folded, equals the
    ///    document kind's label ("syllabus", "announcement", "ed discussion")
    ///    or its raw name ("website", "ed"), or is "canvas" and the document is
    ///    a Canvas page, assignment, module or course home (the server prompt's
    ///    own word for them);
    /// 3. **title**: the citation's detail, normalised (case and diacritics
    ///    folded, whitespace collapsed), equals the document's title
    ///    normalised, or contains all of it as whole words. Never a prefix, a
    ///    shared word, or a similarity score.
    ///
    /// Two excerpts that are passages of one document count once. Two
    /// different documents that both match (two announcements called
    /// "Reminder", a lecture and a lab site's syllabus) are ambiguous and
    /// link nothing. A match whose URL is not `https` with a host links
    /// nothing either (`AssistantCitation.linkable`). Order of citations and
    /// every field but `url` are preserved.
    static func resolve(_ citations: [AssistantCitation], against sources: [ExcerptSource]) -> [AssistantCitation] {
        guard !sources.isEmpty else { return citations }
        return citations.map { citation in
            guard citation.url == nil, let detail = citation.detail else { return citation }
            var matched: [String: ExcerptSource] = [:]
            for source in sources
            where sameCourse(citation.course, source.course)
                && kind(citation.source, names: source.kind)
                && title(source.title, matches: detail) {
                matched[source.documentID] = source
            }
            guard matched.count == 1, let only = matched.values.first else { return citation }
            var linked = citation
            linked.url = AssistantCitation.linkable(only.url)
            return linked
        }
    }

    // MARK: Matching (each one tight on purpose)

    static func sameCourse(_ a: String, _ b: String) -> Bool {
        let left = CourseMatcher.normalize(a)
        return !left.isEmpty && left == CourseMatcher.normalize(b)
    }

    /// Whether the model's kind word names this document kind. The prompt
    /// tells the model to write one of syllabus, canvas, website, announcement.
    static func kind(_ word: String, names kind: CourseDocument.Kind) -> Bool {
        let w = fold(word)
        guard !w.isEmpty else { return false }
        if fold(kind.label) == w || kind.rawValue == w { return true }
        return w == "canvas" && [.home, .assignment, .module, .page].contains(kind)
    }

    /// Normalised equality, or `detail` containing the whole `title` as
    /// whole words (so a title "Quiz" is not found inside "Quizzes").
    static func title(_ title: String, matches detail: String) -> Bool {
        let t = fold(title)
        let d = fold(detail)
        guard !t.isEmpty, !d.isEmpty else { return false }
        if t == d { return true }
        var searchFrom = d.startIndex
        while let found = d.range(of: t, range: searchFrom..<d.endIndex) {
            let before = found.lowerBound == d.startIndex ? nil : d[d.index(before: found.lowerBound)]
            let after = found.upperBound == d.endIndex ? nil : d[found.upperBound]
            if !(before.map(isWordCharacter) ?? false), !(after.map(isWordCharacter) ?? false) {
                return true
            }
            searchFrom = found.upperBound
        }
        return false
    }

    /// Case and diacritics folded, runs of whitespace collapsed to one space,
    /// ends trimmed. Punctuation is kept: "PSet 3: caches" and "PSet 3 caches"
    /// are different titles.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
}
