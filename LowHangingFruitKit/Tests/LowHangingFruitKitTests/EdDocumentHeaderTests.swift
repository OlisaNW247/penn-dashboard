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
    private static func keptThread(_ reason: String, document: String? = paragraph, category: String? = "Homework", subcategory: String? = "Hw 3") -> (EdThread, EdThreadDecision) {
        let thread: EdThread
        let role: String?
        switch reason {
        case "announcement":
            thread = EdThread(id: 1, userID: 7, type: "announcement", title: "A", document: document, category: category, subcategory: subcategory)
            role = nil
        case "pinned":
            thread = EdThread(id: 2, userID: 7, type: "post", title: "P", document: document, category: category, subcategory: subcategory, isPinned: true)
            role = nil
        default:
            thread = EdThread(id: 3, userID: 7, type: "post", title: "S", document: document, category: category, subcategory: subcategory)
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
}
