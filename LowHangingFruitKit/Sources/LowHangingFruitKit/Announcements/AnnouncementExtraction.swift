import Foundation

/// One Canvas announcement, normalized to the plain-text shape both
/// extraction backends need. `Canvas/` is responsible for turning whatever
/// Canvas's announcements API returns into this — HTML stripping, course-code
/// resolution and everything else specific to *fetching* an announcement
/// happens upstream of this type, deliberately, so the extraction layer (this
/// file and its two implementations) never has to know Canvas exists at all
/// and can be exercised with hand-written fixtures.
public struct AnnouncementSourceText: Sendable, Equatable {
    /// The Canvas announcement's own id, kept as a string (not `Int`) for the
    /// same reason `Assignment.sourceID` is a string: Canvas ids are large
    /// enough to be a JSON-number-precision trap, and nothing here does
    /// arithmetic on them — they're only ever compared and stored.
    public let announcementID: String
    /// Clean display course code, e.g. "ACCT 1010" — the same `CourseCode`
    /// key `Assignment.course` uses, so an extracted assignment can be
    /// attached to the right course without a second lookup.
    public let courseCode: String
    public let title: String
    /// Plain text. HTML stripping is the fetch layer's job, not this one's —
    /// an extractor that had to also be an HTML parser would be harder to
    /// unit test and harder to reason about when it inevitably gets an
    /// extraction wrong.
    public let body: String
    /// When Canvas says the announcement was posted. Optional because not
    /// every path that can produce an `AnnouncementSourceText` (tests,
    /// hand-entered fixtures) necessarily has it, and the Claude backend only
    /// uses it as context, not as a hard requirement.
    public let postedAt: Date?

    public init(
        announcementID: String,
        courseCode: String,
        title: String,
        body: String,
        postedAt: Date?
    ) {
        self.announcementID = announcementID
        self.courseCode = courseCode
        self.title = title
        self.body = body
        self.postedAt = postedAt
    }
}

/// What kind of obligation an extracted item describes. This distinction is
/// the fix for the bug where "the slides discussed today have been posted"
/// — an announcement about something the *professor* did, with no verb
/// aimed at the student and nothing to hand in — got filed as an assignment
/// due 11:59 PM and then shown overdue. Not every actionable sentence in an
/// announcement describes a deliverable: "bring a calculator to Tuesday's
/// exam" and "read chapter 3 before class" are real, useful things to
/// surface, but there is nothing to *submit*, so nothing should ever be able
/// to mark them overdue the way a missed problem set is overdue.
public enum ExtractedTaskKind: String, Sendable, Codable, Hashable {
    /// Something handed in — a problem set, a form, a quiz. Behaves like
    /// ordinary homework: it has a due time (defaulting to end of day when
    /// the announcement gives a date but no clock time), and can be overdue.
    case submission
    /// Something to read, watch, review, bring, or otherwise prepare, with
    /// nothing to submit. The app files these as events visible up to their
    /// time and never overdue — there is no "turned it in late" state for
    /// "I didn't bring a calculator."
    case preparation
}

/// One shared vocabulary for deciding whether announcement language belongs
/// on the owed-work dashboard or in the quieter announcement-finds inbox.
/// Extractors and persisted-row placement both call this type so a backend
/// guess cannot permanently disagree with the on-device heuristic.
public enum AnnouncementTaskClassifier {
    /// `midterm`, `mid term`, and `mid-term` are the same noun in professor
    /// prose. Keeping that tolerance inside the shared classifier prevents
    /// one spelling from reaching the dashboard while another becomes a find.
    private static let assessmentNoun = #"(?:quiz(?:zes)?|tests?|assessments?|exams?|mid[\s-]*terms?|prelims?|finals?)"#
    private static let assessmentOrAssignmentNoun = #"(?:"# + assessmentNoun + #"|survey|poll|form|assignment|problem\s+set|pset|homework|hw|lab\s+report|essay|paper|project)"#

    private static let informationalPatterns = [
        #"\b(slides|notes|recording|lecture video|handout|solutions|grades|scores|feedback)\b.{0,40}?\b(posted|uploaded|available|up|out|released|online)\b"#,
        #"\broom change\b"#,
        #"\blocation change\b"#,
        #"\boffice hours\b.{0,20}?\b(moved|changed|cancel\w*)\b"#,
        #"\bclass\b.{0,10}?\bcancel\w*\b"#,
        #"\bno class\b"#,
        #"\breminder:\s*(no|there is no)\b"#,
    ]

    public static func isInformational(_ text: String) -> Bool {
        informationalPatterns.contains { matches($0, in: text) }
    }

    /// Classification hierarchy is intentional:
    ///
    /// 1. A practice-modified assessment is preparation even when introduced
    ///    by "take" ("take the practice mid term").
    /// 2. Any recognized assessment noun is submission: announcement titles
    ///    are often just "Quiz 2" or "Mid term 1" with no imperative verb.
    /// 3. Explicit transfer verbs (submit/upload/turn in…) are submission and
    ///    outrank generic prep language ("review and submit Problem Set 2").
    /// 4. Preparation/reference verbs remain finds when no assessment is named.
    /// 5. Ambiguous actions (take/complete/sit) require a recognized work noun;
    ///    "take a seat" never qualifies.
    /// 6. A recognized work noun explicitly described as due is submission.
    /// 7. Informational or unknown prose returns nil rather than inventing debt.
    public static func taskKind(in text: String) -> ExtractedTaskKind? {
        let lower = text.lowercased()
        if isInformational(lower) { return nil }

        let practiceAssessment = #"\bpractice\b.{0,40}\b"# + assessmentNoun + #"\b"#
        if matches(practiceAssessment, in: lower) { return .preparation }

        if matches(#"\b"# + assessmentNoun + #"\b"#, in: lower) { return .submission }

        // Deliberately excludes past-tense "submitted"/"uploaded" and the
        // noun "submission": this tier describes an instruction to transfer
        // work, not a status report. The outer extractor separately requires
        // student-directed language; dashboard placement also runs the
        // informational guard above before reaching this rule.
        let explicitTransfer = #"\b(submit|submits|submitting|upload|uploads|uploading)\b|\bturn\s+in\b|\bhand\s+in\b|\bfill\s+out\b"#
        if matches(explicitTransfer, in: lower) { return .submission }

        let preparationCue = #"\b(review|study|bring|read|watch|prepare|print|skim)\w*\b|\blook\s+over\b"#
        if matches(preparationCue, in: lower) { return .preparation }
        if matches(#"\bfinish\w*\b"#, in: lower),
           matches(#"\b(reading|chapter|ch|pages|pp|article|book)\b"#, in: lower) {
            return .preparation
        }

        let ambiguousAction = #"\b(complete\w*|take|sit)\b"#
        if matches(ambiguousAction, in: lower),
           matches(#"\b"# + assessmentOrAssignmentNoun + #"\b"#, in: lower) {
            return .submission
        }

        if matches(#"\bdue\b"#, in: lower),
           matches(#"\b"# + assessmentOrAssignmentNoun + #"\b"#, in: lower) {
            return .submission
        }
        return nil
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// A candidate assignment an extractor believes an announcement describes.
///
/// Deliberately *not* `Assignment` — this is a proposal, not a ledger row.
/// Whatever calls an extractor (not built here; that's the sync-layer's job)
/// decides how a run of `ExtractedAssignment`s becomes `Assignment.Source
/// .canvasSuggestion` rows, whether they need user confirmation, and how they
/// dedupe against assignments the ICS feed or Modules API already produced.
/// Keeping this struct minimal keeps that decision out of the extraction
/// layer, where it doesn't belong.
public struct ExtractedAssignment: Sendable, Equatable {
    public let title: String
    /// Nil when no extractor could pin down a date. Undated items are legal
    /// throughout LHF (see `AssignmentStore.reconcile` in CLAUDE.md) — an
    /// extractor that refused to emit anything without a date would silently
    /// drop real, useful "there's a reading, no clue when it's due" signal.
    public let dueAt: Date?
    /// Defaults to `.submission` — the historical, only-ever behavior before
    /// this distinction existed — so every call site that predates
    /// `ExtractedTaskKind` (the Claude backend's decode seam, in particular)
    /// keeps compiling and keeps its old meaning unchanged.
    public let kind: ExtractedTaskKind

    public init(title: String, dueAt: Date?, kind: ExtractedTaskKind = .submission) {
        self.title = title
        self.dueAt = dueAt
        self.kind = kind
    }
}

/// The contract both extraction backends satisfy: given one announcement and
/// the caller's notion of "now" (never `Date()` read internally — see
/// `HeuristicAnnouncementExtractor`'s doc comment for why that matters for
/// weekday/relative-date math and for tests), produce zero or more candidate
/// assignments.
///
/// `async throws` even though the heuristic backend never actually suspends
/// or throws: the Claude backend does both (network I/O, HTTP/decoding
/// errors), and a caller that wants to swap backends behind a single call
/// site — which is the entire point of this being a protocol — needs one
/// signature that already accounts for the more demanding implementation.
/// `Sendable` because both backends are meant to be constructed once and
/// reused from whatever actor drives the announcement sync.
public protocol AnnouncementAssignmentExtractor: Sendable {
    func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment]
}
