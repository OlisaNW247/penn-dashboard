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
/// **The server's reading comes first.** The backend reads every class's
/// syllabus and pages once, for everyone in the class, and keeps the exams it
/// found (`CourseGradingProfile.examDates`). A dated exam from there wins over
/// the phone's own reading of the same exam, and an exam only the server found
/// becomes a row too. "The same exam" is `ExamIdentity` (kind, number,
/// makeup), which is also what builds the row's id, so the two readings are
/// one row: an exam already filed from the phone's reading is updated where it
/// is and never filed a second time, and the completion, a due-date edit and
/// the ledger row stay with it. The phone's reading is the fallback and still
/// runs for every class: it is what serves an install whose server has
/// nothing for the class (not extracted yet, an older server, offline) and
/// every exam the server did not name. An undated server entry says nothing
/// about when and is ignored, so it never displaces a date the phone found.
/// Two refinements to "the server wins" (`reconciled`): when both agree on the
/// day the phone's time of day is kept, because the server only ever gives a
/// day; and when they disagree on the day but the phone's line named a weekday
/// that fits its date (`ExamCandidate.weekdayConfirmed`), the phone's reading
/// stands, because the server is given no current date and so guesses the year
/// of a date written without one.
/// The same previous-term cut-off as the phone's reading applies
/// (`SyllabusExamExtractor.staleAfterDays`), because the server reads the same
/// recycled site's text.
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
        profiles: [CourseGradingProfile] = [],
        courseCodesByID: [String: String],
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> [Assignment] {
        // Gregorian whatever the phone is set to (`Calendar.gregorian(matching:)`);
        // the extractor and `ExamDate.day(in:)` read years off the page.
        let calendar = Calendar.gregorian(matching: calendar)
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
        // What the phone read for each row, kept so that when the server read
        // the same exam the two can be compared (see `reconciled`).
        var candidatesByID: [String: ExamCandidate] = [:]
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
                candidatesByID[sourceID] = candidate
                rows.append(row(
                    sourceID: sourceID,
                    course: courseCode,
                    title: title(for: candidate),
                    dueAt: candidate.hasTime
                        ? candidate.date
                        : AllDayDueMoment.endOfDay(candidate.date, calendar: calendar),
                    url: document.url
                ))
            }
        }

        let fromServer = serverRows(
            from: profiles, documents: documents, courseCodesByID: courseCodesByID,
            referenceDate: referenceDate, calendar: calendar
        )
        guard !fromServer.isEmpty else { return rows }

        // The server's row takes the place of the phone's row for the same
        // exam (same id, so the same ledger row) unless `reconciled` says the
        // phone's reading stands, and an exam only the server found follows
        // after.
        let serverByID = Dictionary(fromServer.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = rows.map { row -> Assignment in
            guard let server = serverByID[row.sourceID] else { return row }
            guard let candidate = candidatesByID[row.sourceID] else { return server }
            return reconciled(phone: row, candidate: candidate, server: server, calendar: calendar)
        }
        let alreadyThere = Set(rows.map(\.sourceID))
        merged.append(contentsOf: fromServer.filter { !alreadyThere.contains($0.sourceID) })
        return merged
    }

    /// The row for an exam both the phone and the server read.
    ///
    /// - **They agree on the day:** the server's row, with the phone's time of
    ///   day if the phone found one. The server's date is a day and nothing
    ///   more ("2026-10-23" says nothing about 7 pm), so taking its row whole
    ///   would throw away a time the syllabus did state. The title and link
    ///   are the server's, as everywhere else.
    /// - **They disagree and the phone's line named a weekday that fits its
    ///   date:** the phone's row. The server is given no current date, so a
    ///   syllabus date written without a year gets the model's guess of the
    ///   year, and a Thursday that is a Thursday in the phone's year and a
    ///   Friday in the server's is the guess being wrong, not the instructor.
    ///   Two facts in the line fit the phone's date; nothing in the server's
    ///   entry corroborates its own.
    /// - **Otherwise the server's row,** as before. A phone reading with no
    ///   weekday to back it is only the extractor's choice of year.
    ///
    /// The wrong version of the second rule is to trust the phone whenever
    /// the two disagree: the server reads the same text with more context
    /// (the whole syllabus, not one line at a time) and moves with a corrected
    /// syllabus, so it must keep winning every disagreement the phone cannot
    /// back with a weekday.
    private static func reconciled(
        phone: Assignment, candidate: ExamCandidate, server: Assignment, calendar: Calendar
    ) -> Assignment {
        guard let serverDue = server.dueAt else { return server }
        if calendar.isDate(candidate.date, inSameDayAs: serverDue) {
            guard candidate.hasTime else { return server }
            return row(
                sourceID: server.sourceID, course: server.course, title: server.title,
                dueAt: phone.dueAt, url: server.url
            )
        }
        return candidate.weekdayConfirmed ? phone : server
    }

    /// The one shape every syllabus exam row has, whichever reading it came
    /// from: see the type comment.
    private static func row(sourceID: String, course: String, title: String, dueAt: Date?, url: URL?) -> Assignment {
        Assignment(
            source: .canvasAnnouncement,
            sourceID: sourceID,
            kind: .event,
            course: course,
            title: title,
            dueAt: dueAt,
            url: url,
            term: nil,
            submitted: false
        )
    }

    /// One row per dated exam the server named, for the classes the app can
    /// name. In class order, then the server's own order, and the first entry
    /// for an exam wins, so a profile that lists one exam twice gives one row.
    ///
    /// An entry is skipped when it has no usable day, when its day is a
    /// previous term's, or when its name does not say which exam it is: one
    /// exam mention exactly. "Midterm 1 and Midterm 2" has no single date to
    /// give, an unnumbered plural ("Midterms") is a category, and "Quiz 3" or
    /// "Final Project" is not an exam, so there is no identity to file it
    /// under (and a loud exam card for it would be wrong).
    ///
    /// The title is built from the exam mention in the name, as the phone's
    /// reading builds it from the syllabus line, and not taken from the name
    /// whole: "Midterm Exam 1 (chapters 1-5, in class)" is the card "Midterm
    /// Exam 1", and whichever reading wins the card is named the same way. It
    /// is also what keeps the title reading back as the identity the id says
    /// (`ExamDetection.examIdentity(title:course:)`), which is how the
    /// dashboard's duplicate check sees the row.
    static func serverRows(
        from profiles: [CourseGradingProfile],
        documents: [CourseDocument],
        courseCodesByID: [String: String],
        referenceDate: Date,
        calendar: Calendar
    ) -> [Assignment] {
        let calendar = Calendar.gregorian(matching: calendar)
        guard !profiles.isEmpty,
              let cutoff = calendar.date(byAdding: .day, value: -SyllabusExamExtractor.staleAfterDays, to: referenceDate)
        else { return [] }

        var seen = Set<String>()
        var rows: [Assignment] = []
        for profile in profiles.sorted(by: { $0.courseID < $1.courseID }) {
            guard let courseCode = courseCodesByID[profile.courseID] else { continue }
            for exam in profile.examDates {
                guard let day = exam.day(in: calendar), day >= cutoff else { continue }
                let mentions = ExamDetection.mentions(in: exam.name, contextWindow: nil)
                guard mentions.count == 1, let mention = mentions.first,
                      !(mention.isPlural && mention.ordinal == nil),
                      let identity = ExamDetection.examIdentity(title: exam.name, course: courseCode)
                else { continue }
                let sourceID = AnnouncementRecord.syllabusFindSourceID(
                    courseID: profile.courseID, examKey: identity.sourceKey
                )
                guard seen.insert(sourceID).inserted else { continue }
                rows.append(row(
                    sourceID: sourceID,
                    course: courseCode,
                    title: title(name: SyllabusExamExtractor.displayName(mention.phrase), modifiers: mention.modifiers),
                    dueAt: AllDayDueMoment.endOfDay(day, calendar: calendar),
                    url: link(forCourse: profile.courseID, in: documents)
                ))
            }
        }
        return rows
    }

    /// Where a server-read exam points: the course's syllabus, else its home
    /// page, else a course page. The server does not say which document an
    /// exam came from, and a card with a link to the class's own material is
    /// better than one with none.
    private static func link(forCourse courseID: String, in documents: [CourseDocument]) -> URL? {
        for kind in kindOrder {
            let candidates = documents
                .filter { $0.courseID == courseID && $0.kind == kind && $0.url != nil }
                .sorted { $0.id < $1.id }
            if let url = candidates.first?.url { return url }
        }
        return nil
    }

    /// What the card says. The extractor's name is the phrase that names the
    /// exam ("Midterm 1"); a makeup, retake or alternate sitting says so in
    /// the words around it, and a card that read "Midterm 1" for the makeup
    /// would look like a duplicate of the real one. The prefix is also what
    /// lets `ExamDetection.examIdentity(title:course:)` read the same identity
    /// back out of the row's title, which is how the dashboard's duplicate
    /// check sees it.
    static func title(for candidate: ExamCandidate) -> String {
        title(name: candidate.name, modifiers: candidate.modifiers)
    }

    static func title(name: String, modifiers: Set<String>) -> String {
        let prefix = modifierOrder
            .filter { modifiers.contains($0) }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return (prefix + [name]).joined(separator: " ")
    }

    private static let modifierOrder = ["makeup", "retake", "alternate"]
}
