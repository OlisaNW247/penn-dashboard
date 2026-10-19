import Foundation
import Testing
@testable import LowHangingFruitKit

/// `EdDocumentHeader` reads back the header line `EdDocumentBuilder` writes.
/// Every test that depends on the format builds its text with the real
/// builder (and the real `EdThreadFilter` for the reason), never a string
/// typed here, so a change to either side fails in this file first rather
/// than quietly turning every Ed post into one with no reason.
@Suite("Ed document header")
struct EdDocumentHeaderTests {
    private static let paragraph = "<document version=\"2.0\"><paragraph>Bring ID.</paragraph></document>"

    /// The three threads the filter keeps, with the reason it gives each.
    private static func keptThread(_ reason: String, document: String? = paragraph, category: String? = "Homework", subcategory: String? = "Hw 3", createdAt: Date = Date(timeIntervalSince1970: 0)) -> (EdThread, EdThreadDecision) {
        let thread: EdThread
        let role: String?
        switch reason {
        case "announcement":
            thread = EdThread(id: 1, userID: 7, type: "announcement", title: "A", document: document, category: category, subcategory: subcategory, createdAt: createdAt)
            role = nil
        case "pinned":
            thread = EdThread(id: 2, userID: 7, type: "post", title: "P", document: document, category: category, subcategory: subcategory, isPinned: true, createdAt: createdAt)
            role = nil
        default:
            thread = EdThread(id: 3, userID: 7, type: "post", title: "S", document: document, category: category, subcategory: subcategory, createdAt: createdAt)
            role = "ta"
        }
        return (thread, EdThreadFilter.decide(thread, authorRole: role))
    }

    @Test("round-trips real builder output for every reason the filter keeps")
    func roundTripsEveryReason() {
        for reason in ["announcement", "pinned", "staff post"] {
            let (thread, decision) = Self.keptThread(reason)
            #expect(decision.keep && decision.reason == reason)
            let text = EdDocumentBuilder.text(for: thread, decision: decision)
            let header = EdDocumentHeader.parse(text)
            #expect(header.reason == reason)
            #expect(header.category == "Homework / Hw 3")
            #expect(header.body == "Bring ID.")
            #expect(!header.body.contains("[ed ·"))
        }
    }

    @Test("only an announcement or a pinned post is announcement-or-pinned; a staff post is not")
    func announcementOrPinnedFlags() {
        func parsed(_ reason: String) -> EdDocumentHeader {
            let (thread, decision) = Self.keptThread(reason)
            return EdDocumentHeader.parse(EdDocumentBuilder.text(for: thread, decision: decision))
        }
        #expect(parsed("announcement").isAnnouncementOrPinned)
        #expect(parsed("announcement").isAnnouncement)
        #expect(parsed("pinned").isAnnouncementOrPinned)
        #expect(parsed("pinned").isPinned)
        #expect(!parsed("staff post").isAnnouncementOrPinned)
        #expect(!EdDocumentHeader.parse("no header here").isAnnouncementOrPinned)
    }

    @Test("a header with no category has none; a thread with no body is just its header")
    func missingCategoryAndBody() {
        let (withBody, decision) = Self.keptThread("announcement", category: nil, subcategory: nil)
        let hi = EdDocumentHeader.parse(EdDocumentBuilder.text(for: withBody, decision: decision))
        #expect(hi.reason == "announcement")
        #expect(hi.category == nil)
        #expect(hi.body == "Bring ID.")

        let (empty, emptyDecision) = Self.keptThread("pinned", document: nil, category: "General", subcategory: nil)
        let text = EdDocumentBuilder.text(for: empty, decision: emptyDecision)
        #expect(text == "[ed · pinned] General")
        let headerOnly = EdDocumentHeader.parse(text)
        #expect(headerOnly.reason == "pinned")
        #expect(headerOnly.category == "General")
        #expect(headerOnly.body == "")
    }

    @Test("a multi-line body comes back exactly as the builder wrote it")
    func multiLineBody() {
        let document = "<document version=\"2.0\"><heading level=\"1\">Plan</heading><paragraph>First.</paragraph><paragraph>Second: Due Friday.</paragraph></document>"
        let (thread, decision) = Self.keptThread("announcement", document: document)
        let text = EdDocumentBuilder.text(for: thread, decision: decision)
        let header = EdDocumentHeader.parse(text)
        let firstNewline = text.firstIndex(of: "\n")!
        #expect(header.body == String(text[text.index(after: firstNewline)...]))
        #expect(header.body.contains("First."))
        #expect(header.body.contains("Second: Due Friday."))
    }

    @Test("text without a header is returned whole, with no reason")
    func noHeaderIsReturnedWhole() {
        for text in [
            "Grading\nProblem sets 50%.",
            "",
            "[ed · unclosed header\nbody",
            "[ed · ]\nbody",
            "  [ed · pinned] indented, so not the builder's line",
            "Posted: Mon, Sep 7 at 9:00 AM\nRecitation moved.",
        ] {
            let header = EdDocumentHeader.parse(text)
            #expect(header.reason == nil)
            #expect(header.category == nil)
            #expect(header.body == text)
        }
    }

    @Test("the header is only the first line: a later line that looks like one is body")
    func laterHeaderLikeLineIsBody() {
        let text = "Plain first line\n[ed · pinned] not a header"
        let header = EdDocumentHeader.parse(text)
        #expect(header.reason == nil)
        #expect(header.body == text)
    }

    // MARK: - The posting date

    /// The given UTC time, built from components so no formatter's locale is
    /// involved in the expectation.
    private static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Noon US Eastern on the given day: what the parser must return. October
    /// is EDT, so this is 16:00 UTC.
    private static func easternNoon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test("the builder writes the creation day as a posted token, and the parser reads it back as noon Eastern of that day")
    func postedTokenRoundTrips() {
        for reason in ["announcement", "pinned", "staff post"] {
            let (thread, decision) = Self.keptThread(reason, createdAt: Self.utc(2026, 10, 12, 15, 30))
            let text = EdDocumentBuilder.text(for: thread, decision: decision)
            #expect(text == "[ed · \(reason)] Homework / Hw 3 · posted 2026-10-12\nBring ID.")
            let header = EdDocumentHeader.parse(text)
            #expect(header.reason == reason)
            #expect(header.category == "Homework / Hw 3")
            #expect(header.postedAt == Self.easternNoon(2026, 10, 12))
            #expect(header.body == "Bring ID.")
        }
    }

    @Test("a thread with no category still carries the token, and the category stays nil")
    func postedTokenWithoutCategory() {
        let (thread, decision) = Self.keptThread("announcement", category: nil, subcategory: nil, createdAt: Self.utc(2026, 10, 12, 9))
        let text = EdDocumentBuilder.text(for: thread, decision: decision)
        #expect(text == "[ed · announcement] · posted 2026-10-12\nBring ID.")
        let header = EdDocumentHeader.parse(text)
        #expect(header.reason == "announcement")
        #expect(header.category == nil)
        #expect(header.postedAt == Self.easternNoon(2026, 10, 12))
        #expect(header.body == "Bring ID.")

        let (bare, bareDecision) = Self.keptThread("pinned", document: nil, category: nil, subcategory: nil, createdAt: Self.utc(2026, 10, 12, 12))
        #expect(EdDocumentBuilder.text(for: bare, decision: bareDecision) == "[ed · pinned] · posted 2026-10-12")
    }

    @Test("the day is the Eastern day, whatever the device zone: 01:30 UTC on the 13th is the 12th, 03:30 UTC on the 12th is the 11th (both EDT)")
    func postedDayIsEastern() {
        // A Monday 9:30 PM EDT post is Tuesday in UTC; it must read Monday.
        #expect(EdDocumentHeader.postedDayString(Self.utc(2026, 10, 13, 1, 30)) == "2026-10-12")
        #expect(EdDocumentHeader.postedDayString(Self.utc(2026, 10, 12, 3, 30)) == "2026-10-11")
        // 03:59 UTC is 11:59 PM EDT the day before; 04:00 UTC is midnight EDT.
        #expect(EdDocumentHeader.postedDayString(Self.utc(2026, 10, 13, 3, 59)) == "2026-10-12")
        #expect(EdDocumentHeader.postedDayString(Self.utc(2026, 10, 13, 4, 0)) == "2026-10-13")
        // Winter is EST (UTC-5): 04:30 UTC on Jan 6 is still the 5th.
        #expect(EdDocumentHeader.postedDayString(Self.utc(2026, 1, 6, 4, 30)) == "2026-01-05")
        #expect(EdDocumentHeader.postedDayString(Self.utc(2026, 1, 5, 12)) == "2026-01-05")
    }

    @Test("the epoch default of a hand-built thread gets no token rather than a post from 1970")
    func epochCreatedAtOmitsToken() {
        let (thread, decision) = Self.keptThread("pinned")
        let text = EdDocumentBuilder.text(for: thread, decision: decision)
        #expect(text == "[ed · pinned] Homework / Hw 3\nBring ID.")
        #expect(EdDocumentHeader.parse(text).postedAt == nil)
    }

    @Test("a header written before the token existed parses exactly as before, with no postedAt")
    func oldHeaderHasNoPostedAt() {
        let header = EdDocumentHeader.parse("[ed · pinned] Homework / Hw 3\nBring ID.")
        #expect(header == EdDocumentHeader(reason: "pinned", category: "Homework / Hw 3", body: "Bring ID."))
        #expect(header.postedAt == nil)
        #expect(EdDocumentHeader.parse("[ed · announcement]").postedAt == nil)
        #expect(EdDocumentHeader.parse("no header · posted 2026-10-12").postedAt == nil)
    }

    @Test("a malformed or impossible date is nil and leaves the category and body alone")
    func malformedPostedToken() {
        for bad in ["2026-13-45", "2026-02-31", "yesterday", "2026-10-1", "20261012", "2026-10-12T09:00", "", "0000-00-00"] {
            let text = "[ed · pinned] Homework · posted \(bad)\nBring ID."
            let header = EdDocumentHeader.parse(text)
            #expect(header.postedAt == nil, "\(bad)")
            #expect(header.reason == "pinned")
            #expect(header.category?.hasPrefix("Homework") == true)
            #expect(header.body == "Bring ID.")
        }
        // A category that merely contains the separator is not a token.
        let dotted = EdDocumentHeader.parse("[ed · pinned] Labs · Week 3\nBring ID.")
        #expect(dotted.category == "Labs · Week 3")
        #expect(dotted.postedAt == nil)
    }

    // MARK: - carriesNoText

    @Test("a post that is only a picture carries no text; the placeholder comes from the real converter")
    func imageOnlyPostCarriesNoText() {
        let document = "<document version=\"2.0\"><image src=\"https://static.edusercontent.com/files/x\" width=\"100\" height=\"100\"/></document>"
        let (thread, decision) = Self.keptThread("announcement", document: document)
        let text = EdDocumentBuilder.text(for: thread, decision: decision)
        #expect(text.contains("[image]"))
        #expect(EdDocumentHeader.carriesNoText(text))
    }

    @Test("a header alone, several placeholders, and a bulleted placeholder all carry no text")
    func emptyShapes() {
        #expect(EdDocumentHeader.carriesNoText("[ed · announcement]"))
        #expect(EdDocumentHeader.carriesNoText("[ed · announcement] General"))
        #expect(EdDocumentHeader.carriesNoText("[ed · pinned] General / FAQ\n[image]\n[image]"))
        #expect(EdDocumentHeader.carriesNoText("[ed · pinned]\n- [image]\n> [image]"))
        // A later chunk of a long document has no header at all.
        #expect(EdDocumentHeader.carriesNoText("[image]"))
        #expect(EdDocumentHeader.carriesNoText("   \n"))
    }

    @Test("any real word or number in the body means the post carries text")
    func realTextCarriesText() {
        #expect(!EdDocumentHeader.carriesNoText("[ed · announcement] General\nMidterm moved to Friday."))
        #expect(!EdDocumentHeader.carriesNoText("[ed · pinned]\n[image]\nSee the diagram above."))
        #expect(!EdDocumentHeader.carriesNoText("[ed · pinned]\n[image]\nRoom 100"))
        #expect(!EdDocumentHeader.carriesNoText("Plain text with no header"))
    }

    // MARK: - SearchHit helpers

    private static func hit(_ text: String, kind: CourseDocument.Kind = .ed, ordinal: Int = 0) -> SearchHit {
        let document = CourseDocument(courseID: "1", course: "CIS 2400", kind: kind, sourceID: "9", title: "T", url: nil, text: text)
        return SearchHit(passage: Passage(documentID: document.id, ordinal: ordinal, text: text), document: document, score: 2.5)
    }

    @Test("an Ed hit whose passage is empty or only placeholders is textless; anything else is not")
    func textlessEdHit() {
        #expect(Self.hit("[ed · announcement] General\n[image]").isTextlessEdPost)
        #expect(Self.hit("[ed · pinned]").isTextlessEdPost)
        #expect(!Self.hit("[ed · announcement] General\nMidterm moved.").isTextlessEdPost)
        // Only Ed documents are ever judged: a page that is just "[image]" is left to the ranking.
        #expect(!Self.hit("[image]", kind: .page).isTextlessEdPost)
    }

    @Test("withoutEdHeader drops the header from the first passage and keeps the hit's identity")
    func hitWithoutHeader() {
        let hit = Self.hit("[ed · pinned] Homework / Hw 3\nBring ID.")
        let clean = hit.withoutEdHeader
        #expect(clean.passage.text == "Bring ID.")
        #expect(clean.passage.id == hit.passage.id)
        #expect(clean.document == hit.document)
        #expect(clean.score == hit.score)
        #expect(clean.component == hit.component)
    }

    @Test("withoutEdHeader leaves a later passage and every other kind of document unchanged")
    func hitWithoutHeaderLeavesOthersAlone() {
        let later = Self.hit("The second chunk of a long post.", ordinal: 1)
        #expect(later.withoutEdHeader == later)
        let page = Self.hit("[ed · pinned] looks like a header but this is a page", kind: .page)
        #expect(page.withoutEdHeader == page)
    }
}
