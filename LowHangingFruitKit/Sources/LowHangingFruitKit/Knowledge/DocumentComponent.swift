import Foundation

/// A Canvas course site can bundle more than one component under one code —
/// PHYS 0151 is a 1.0 CU lecture plus a 0.5 CU pass/fail lab, with a lab
/// syllabus and a lecture syllabus both synced as separate `CourseDocument`s.
/// Retrieval used to be blind to this: a question about "the class" could
/// retrieve the lab syllabus purely because it scored higher on keyword
/// overlap, and the model would answer about the lab. `DocumentComponent`
/// gives `CourseSearch` something to key a preference on, and gives the
/// rendered excerpts a label so the model (and, transitively, the student)
/// can see which component a passage came from even when it isn't the one
/// preferred.
///
/// Classification is a cheap, deterministic heuristic over title and the
/// first slice of body text — not a model call, not per-passage — because a
/// wrong guess here should be rare and cheap to make, not something a
/// student notices as latency. It is deliberately conservative: the bias
/// throughout is toward `.general` (visible everywhere, boosted nowhere)
/// rather than a confident wrong guess of `.lab`, since mislabeling a
/// lecture document as `.lab` would recreate exactly the bug this type
/// exists to fix.
public enum DocumentComponent: String, Sendable, Hashable, CaseIterable {
    case lecture
    case lab
    case recitation
    case general

    /// Short human-readable tag, e.g. for `"[lab] "` prefixes. `.general`
    /// renders as the empty string — most documents belong to no particular
    /// component and shouldn't be labelled as if they did.
    public var label: String {
        switch self {
        case .lecture: return "lecture"
        case .lab: return "lab"
        case .recitation: return "recitation"
        case .general: return ""
        }
    }

    /// Recitation words are unambiguous enough (no course calls its lecture
    /// "recitation") that they're checked before lab/lecture in `classify`,
    /// and never in tension with the "never lab" bias.
    // Every comparison below runs against `TextTokenizer.tokens`, which
    // stems: "recitation" comes out as "recitate", "class" as "clas",
    // "exams" as "exam". A word list written in plain English would then
    // silently never match those forms — the first version of this file did
    // exactly that and would have classified every recitation page as
    // `.general` and every "how is the class graded" question as having no
    // component. So the lists are stemmed once here, with the same function,
    // and stay in lockstep with whatever the stemmer does next.
    private static func stemmed(_ words: [String]) -> Set<String> {
        Set(words.map(TextTokenizer.stem))
    }

    private static let recitationWords = stemmed(["recitation", "recitations", "rec", "discussion"])
    private static let labWords = stemmed(["lab", "labs", "laboratory", "laboratories"])
    private static let lectureTitleWords = stemmed(["lecture", "lectures", "syllabus"])
    private static let lectureHeadWords = stemmed(["lecture", "lectures", "exam", "exams", "midterm", "midterms", "problem", "homework", "homeworks"])
    private static let classWords = stemmed(["lecture", "lectures", "class", "classes"])
    private static let recitationQuestionWords = stemmed(["recitation", "recitations", "rec"])
    /// Narrower than `lectureTitleWords` on purpose: that set includes
    /// "syllabus", which is a fine signal in a *document title* ("PHYS 0151
    /// Syllabus" is almost certainly the lecture's) but not in a *course
    /// site's own name*, where "syllabus" never appears and would just be
    /// dead weight.
    private static let siteNameLectureWords = stemmed(["lecture", "lectures"])
    private static let headTextLength = 400

    /// Deterministic, word-boundary classification of one document. Reuses
    /// `TextTokenizer.tokens` (rather than a regex) both for consistency
    /// with the rest of the retrieval stack and because a raw-string regex
    /// with real Unicode escapes is a known trap in this codebase — this
    /// avoids the class of bug entirely by not writing a regex at all.
    public static func classify(title: String, text: String) -> DocumentComponent {
        let titleTokens = Set(TextTokenizer.tokens(title, minLength: 1))
        let headTokens = TextTokenizer.tokens(String(text.prefix(headTextLength)), minLength: 1)
        let headTokenSet = Set(headTokens)

        if !titleTokens.isDisjoint(with: recitationWords) || !headTokenSet.isDisjoint(with: recitationWords) {
            return .recitation
        }

        if !titleTokens.isDisjoint(with: labWords) {
            return .lab
        }

        let headLabCount = headTokens.filter { labWords.contains($0) }.count
        let headLectureCount = headTokens.filter { lectureHeadWords.contains($0) }.count
        if headLabCount >= 2 && headLectureCount == 0 {
            return .lab
        }

        let titleHasLecture = !titleTokens.isDisjoint(with: lectureTitleWords)
        if titleHasLecture && headLectureCount > headLabCount {
            return .lecture
        }

        return .general
    }

    /// Which component (if any) a free-text question is asking about. `nil`
    /// means the question doesn't name a component, so retrieval shouldn't
    /// prefer one. Checked in priority order lab, recitation, lecture: a
    /// question naming more than one ("class lab report") means the student
    /// typed "class" generically but "lab" specifically, so lab wins.
    public static func mentioned(in question: String) -> DocumentComponent? {
        let tokens = Set(TextTokenizer.tokens(question, minLength: 1))
        if !tokens.isDisjoint(with: labWords) {
            return .lab
        }
        if !tokens.isDisjoint(with: recitationQuestionWords) {
            return .recitation
        }
        if !tokens.isDisjoint(with: classWords) {
            return .lecture
        }
        return nil
    }

    /// Whether labelling a hit from this course as `[lecture]` or `[lab]`
    /// tells the reader anything. It does only when the course is actually
    /// split: at least one of its documents classifies as a lab or a
    /// recitation. A plain lecture course with a syllabus that happens to
    /// mention exams would otherwise sprout a "[lecture]" tag on every
    /// answer, which reads as noise to the student and as a hint of a lab
    /// that doesn't exist to the model.
    ///
    /// Only structural documents count — a syllabus, a page, a module, the
    /// course home. An announcement saying "recitation moved this week" or
    /// an assignment called "Lab 3" mentions a component without proving
    /// the course is graded in two parts; the first version of this check
    /// counted them and labelled every CIS 2400 answer "[lecture]" on the
    /// strength of one rescheduled recitation.
    public static func courseIsSplit(_ documents: [CourseDocument]) -> Bool {
        documents.contains { document in
            switch document.kind {
            case .announcement, .assignment: return false
            case .syllabus, .home, .page, .module, .website: break
            }
            switch classify(title: document.title, text: document.text) {
            case .lab, .recitation: return true
            case .lecture, .general: return false
            }
        }
    }

    /// The component a document belongs to, now that one course `code` can
    /// span several Canvas *sites* (PHYS 0151's lecture and lab are two
    /// sites sharing one code — see `CourseCode.Parsed.section` and
    /// `CourseKnowledgeBase.courseIDs(forCode:)`). Prefers identity signals
    /// specific to the *site* a document came from over guessing from the
    /// document's own title/text, because a plainly-titled "Syllabus" on
    /// the lab site should still classify as `.lab` even though nothing in
    /// its title or body says so — `classify(title:text:)` alone would call
    /// that `.general` and the labelling this type exists for would go
    /// missing for exactly the documents that need it most.
    ///
    /// Falls back to `classify(title:text:)` — unchanged from before this
    /// method existed — whenever the site itself gives no identity signal:
    /// a course that was never split, a document whose `courseID` isn't in
    /// `knowledge` yet, or a site whose registrar section and name are both
    /// uninformative.
    public static func component(of document: CourseDocument, in knowledge: CourseKnowledgeBase) -> DocumentComponent {
        if let summary = knowledge.summary(forCourseID: document.courseID),
           let identity = siteIdentityComponent(for: summary, in: knowledge) {
            return identity
        }
        return classify(title: document.title, text: document.text)
    }

    /// Steps 1 and 2 of `component(of:in:)`'s lookup, factored out so
    /// `courseIsSplit(code:in:)` can ask "do this code's sites disagree on
    /// identity?" without also pulling in step 3's per-document text guess
    /// — a course whose two sites both fall through to `classify` on their
    /// syllabi isn't "split by identity," it's "split (or not) by the
    /// existing per-document heuristic," which `courseIsSplit(code:in:)`
    /// checks separately.
    ///
    /// **Step 1 — the registrar catalog.** `summary.section` is this site's
    /// own section token ("151", "401"); Penn Labs meeting ids are shaped
    /// like `PHYS-0151-151`, i.e. the catalog code plus a dash plus that
    /// same section token, so a meeting whose `sectionID` ends with
    /// `-<section>` is this site's own meeting, and its registrar
    /// `activity` ("LEC"/"LAB"/"REC") is about as authoritative a signal as
    /// exists. An activity code the client doesn't recognize (or a section
    /// with no matching meeting) falls through to step 2 rather than
    /// stopping here — a future registrar code shouldn't regress a split
    /// course to unlabelled.
    ///
    /// **Step 2 — the site's own name.** Canvas course names routinely say
    /// the quiet part out loud ("PHYS 0151-401 Lab", "PHYS 0151-151
    /// Recitation"), so before giving up and guessing from one document's
    /// text, check the one piece of text that describes the whole site.
    public static func siteIdentityComponent(for summary: CourseSummary, in knowledge: CourseKnowledgeBase) -> DocumentComponent? {
        if let section = summary.section, let catalogEntry = knowledge.catalogEntry(forCourseCode: summary.code) {
            for meeting in catalogEntry.meetings where meeting.sectionID.hasSuffix("-\(section)") {
                switch meeting.activity {
                case "LEC": return .lecture
                case "LAB": return .lab
                case "REC": return .recitation
                default: continue
                }
            }
        }

        let nameTokens = Set(TextTokenizer.tokens(summary.name, minLength: 1))
        if !nameTokens.isDisjoint(with: labWords) { return .lab }
        if !nameTokens.isDisjoint(with: recitationWords) { return .recitation }
        if !nameTokens.isDisjoint(with: siteNameLectureWords) { return .lecture }
        return nil
    }

    /// Whether a course `code` is actually split into more than one
    /// component, now that a code can span several Canvas sites. True in
    /// either of two independent ways:
    ///
    /// - The sites sharing `code` resolve to more than one distinct,
    ///   non-`.general` component by *identity* (`siteIdentityComponent`,
    ///   steps 1/2 of `component(of:in:)`) — this is the PHYS 0151 case,
    ///   where the lecture and lab are two whole Canvas sites and neither
    ///   one's documents need to mention "lab" anywhere for the split to
    ///   be real.
    /// - OR any single one of those sites is split the old way — one site
    ///   whose own structural documents disagree (`courseIsSplit(_:)`,
    ///   unchanged) — which is the pre-existing "one site, two syllabi"
    ///   case this type was originally built for and must keep detecting.
    public static func courseIsSplit(code: String, in knowledge: CourseKnowledgeBase) -> Bool {
        let courseIDs = knowledge.courseIDs(forCode: code)
        guard !courseIDs.isEmpty else { return false }

        var siteComponents: Set<DocumentComponent> = []
        for courseID in courseIDs {
            guard let summary = knowledge.summary(forCourseID: courseID),
                  let identity = siteIdentityComponent(for: summary, in: knowledge)
            else { continue }
            siteComponents.insert(identity)
        }
        if siteComponents.count > 1 { return true }

        return courseIDs.contains { courseIsSplit(knowledge.documents(for: $0)) }
    }
}
