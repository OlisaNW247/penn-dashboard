import Foundation

/// The ledger rows a class's syllabus produces: one per exam it names next to
/// a date. Pure; `AppState.syncSyllabusExams` is the only caller and the
/// thing that writes them.
///
/// **Which text.** The course material already on the phone
/// (`CourseKnowledgeBase.documents`): the syllabus, the course home page, and
/// the course's pages, in that order of trust. The home page and the pages are
/// read because a great many courses put the schedule there and keep the
/// syllabus file to policies, and the extractor is strict enough to be asked
/// of any text: it needs an exam noun and a date in the same clause, and it
/// refuses the false friends ("Midterm Review", "Final Project", "Practice
/// Exam 2"). Assignment descriptions, announcements, modules and Ed posts are
/// not read here: announcements and Ed already have their own extractors, and
/// an assignment description is about one assignment.
///
/// **One row per exam, not per mention.** The same exam is usually named more
/// than once (the overview, the weekly schedule, the home page). The row's id
/// is built from the course and the exam's identity (`ExamIdentity.sourceKey`),
/// so the mentions collapse to one, and the first one found wins: syllabus
/// before home page before pages, then in document order. When two documents
/// disagree about a date, the more trusted document is right and the other is
/// not asked. A syllabus that names one exam on two different days (a typo, or
/// "Dec 15 ... Dec 16 for conflicts" if the extractor mispaired it) therefore
/// gets one card, not two cards for one exam.
///
/// **The row.** `.canvasAnnouncement` with a `syllabus-` id
/// (`AnnouncementRecord.syllabusFindSourceID`), kind `.event` because a sitting
/// is something to show up for and not something to hand in. That is what
/// keeps it out of the loud 10-minute alert, which is for unsubmitted work.
/// An exam with no time of day is stored at the end of its day
/// (`AllDayDueMoment`), as every all-day entry in the app is.
public enum SyllabusExamRows {

    /// The kinds of course material read, most trusted first.
    static let kindOrder: [CourseDocument.Kind] = [.syllabus, .home, .page]

    public static func assignments(
        from documents: [CourseDocument],
        courseCodesByID: [String: String],
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> [Assignment] {
        let readable = documents
            .compactMap { document -> (rank: Int, document: CourseDocument)? in
                guard let rank = kindOrder.firstIndex(of: document.kind),
                      courseCodesByID[document.courseID] != nil,
                      !document.text.isEmpty
                else { return nil }
                return (rank, document)
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.document.id < rhs.document.id
            }

        var seen = Set<String>()
        var rows: [Assignment] = []
        for (_, document) in readable {
            guard let courseCode = courseCodesByID[document.courseID] else { continue }
            let candidates = SyllabusExamExtractor.extract(
                text: document.text, referenceDate: referenceDate, calendar: calendar
            )
            for candidate in candidates {
                let identity = ExamIdentity(
                    course: ExamDetection.normalizedCourse(courseCode),
                    kind: candidate.kind,
                    ordinal: candidate.ordinal,
                    modifiers: candidate.modifiers
                )
                let sourceID = AnnouncementRecord.syllabusFindSourceID(
                    courseID: document.courseID, examKey: identity.sourceKey
                )
                guard seen.insert(sourceID).inserted else { continue }
                rows.append(Assignment(
                    source: .canvasAnnouncement,
                    sourceID: sourceID,
                    kind: .event,
                    course: courseCode,
                    title: title(for: candidate),
                    dueAt: candidate.hasTime
                        ? candidate.date
                        : AllDayDueMoment.endOfDay(candidate.date, calendar: calendar),
                    url: document.url,
                    term: nil,
                    submitted: false
                ))
            }
        }
        return rows
    }

    /// What the card says. The extractor's name is the phrase that names the
    /// exam ("Midterm 1"); a makeup, retake or alternate sitting says so in
    /// the words around it, and a card that read "Midterm 1" for the makeup
    /// would look like a duplicate of the real one. The prefix is also what
    /// lets `ExamDetection.examIdentity(title:course:)` read the same identity
    /// back out of the row's title, which is how the dashboard's duplicate
    /// check sees it.
    static func title(for candidate: ExamCandidate) -> String {
        let prefix = modifierOrder
            .filter { candidate.modifiers.contains($0) }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return (prefix + [candidate.name]).joined(separator: " ")
    }

    private static let modifierOrder = ["makeup", "retake", "alternate"]
}
