import Foundation
import LowHangingFruitKit

/// A repeating, non-assignment obligation: the weekly reading, the Sunday
/// check-in, the discussion post that is due every Thursday whether or not
/// anyone posts it to Canvas as an assignment.
///
/// A task is a *rule*; the things a student actually sees on the dashboard are
/// the `Assignment` occurrences `upcomingAssignments` generates from it, one per
/// week inside the horizon. That distinction is why this file also owns the
/// vocabulary for *recognising* an occurrence again later — see
/// `occurrenceSourceID(taskID:due:)` and `isOccurrence(_:)`.
struct RecurringTask: Codable, Hashable, Identifiable {
    enum Origin: String, Codable, Hashable {
        case manual
        case canvasSyllabus
        case canvasAnnouncement
    }

    var id: UUID
    var title: String
    var course: String
    var weekday: Int
    var hour: Int
    var minute: Int
    var startDate: Date
    var endDate: Date?
    var origin: Origin
    var evidence: String?

    init(
        id: UUID = UUID(),
        title: String,
        course: String,
        weekday: Int,
        hour: Int,
        minute: Int,
        startDate: Date,
        endDate: Date?,
        origin: Origin,
        evidence: String? = nil
    ) {
        self.id = id
        self.title = title
        self.course = course
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
        self.startDate = startDate
        self.endDate = endDate
        self.origin = origin
        self.evidence = evidence
    }

    /// A task saved with no course, adopted by the one known class whose
    /// code appears in its title ("Cis 3990 recurring lab" → `CIS 3990`).
    ///
    /// The add sheet's course field was optional free text, so a student
    /// who named the class in the title and skipped the field got a task
    /// that belonged to no class: it never showed under that class and the
    /// class filter could not find it (found on a real phone, 2026-09-24).
    /// The sheets now pick from the class list, but tasks already saved
    /// that way are repaired here rather than by rewriting stored data —
    /// applied on every rebuild, so it also follows a class the student
    /// adds later. Matching ignores case and spacing ("cis3990", "CIS 3990")
    /// and gives up when the title names two classes, since a guess there
    /// could file the work under the wrong one.
    func adoptingCourse(from knownCourses: [String]) -> RecurringTask {
        guard course.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }
        let squash: (String) -> String = { $0.uppercased().filter { !$0.isWhitespace && $0 != "-" } }
        let haystack = squash(title)
        let matches = knownCourses.filter { code in
            let needle = squash(code)
            return !needle.isEmpty && haystack.contains(needle)
        }
        guard matches.count == 1 else { return self }
        var adopted = self
        adopted.course = matches[0]
        return adopted
    }

    /// Reads the persisted task list, losing only the task that is wrong.
    ///
    /// These are the student's own rules, typed in by hand, so a read that
    /// loses all of them over one bad element is the worse failure. A plain
    /// `decode([RecurringTask].self)` threw for the whole list on one task
    /// with an `origin` a newer build wrote or a weekday stored as a string;
    /// `AppState` fell back to `[]` and the next `persistRecurringTasks`
    /// wrote that empty list over every task. Now the readable ones survive
    /// and `droppedCount` says how many did not. A blob that is not a list at
    /// all reads as empty with nothing counted.
    static func decodeAll(_ data: Data?) -> (tasks: [RecurringTask], droppedCount: Int) {
        guard let data,
              let decoded = try? JSONDecoder().decode(LossyArray<RecurringTask>.self, from: data)
        else { return ([], 0) }
        return (decoded.elements, decoded.droppedCount)
    }

    /// - Parameter calendar: injectable so a test can put the phone in any
    ///   time zone or calendar system; callers pass nothing. Whatever it is,
    ///   the weekly walk below runs in the Gregorian calendar in its zone
    ///   (`Calendar.gregorian(matching:)`), so a phone set to a Buddhist or
    ///   Japanese calendar generates the same occurrences as any other.
    func upcomingAssignments(
        from now: Date = Date(),
        weeksAhead: Int = 10,
        calendar: Calendar = .current
    ) -> [Assignment] {
        let calendar = Calendar.gregorian(matching: calendar)
        let horizon = calendar.date(byAdding: .day, value: weeksAhead * 7, to: now) ?? now
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        components.weekday = weekday
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard var due = calendar.date(from: components) else { return [] }
        if due < calendar.startOfDay(for: startDate) {
            due = nextDueDate(onOrAfter: startDate, calendar: calendar) ?? due
        }
        if due < now {
            due = calendar.date(byAdding: .day, value: 7, to: due) ?? due
        }

        var assignments: [Assignment] = []
        while due <= horizon {
            if let endDate, due > endDate { break }
            assignments.append(Assignment(
                source: source,
                sourceID: "\(id.uuidString)-\(Self.occurrenceStamp(due: due, in: calendar))",
                kind: .assignment,
                course: course,
                title: title,
                dueAt: due,
                url: nil,
                submitted: false
            ))
            due = calendar.date(byAdding: .day, value: 7, to: due) ?? horizon.addingTimeInterval(1)
        }
        return assignments
    }

    private var source: Assignment.Source {
        switch origin {
        case .manual:             return .manual
        case .canvasSyllabus:     return .canvasSuggestion
        case .canvasAnnouncement: return .canvasSuggestion
        }
    }

    private func nextDueDate(onOrAfter date: Date, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }
}

// MARK: - Recognising an occurrence again

/// Minting *and* recognising the `sourceID` of a generated occurrence, in one
/// place.
///
/// **Why this is needed at all.** The per-course notification settings added in
/// v4 include a switch for recurring work specifically — "keep telling me about
/// assignments, stop telling me about the weekly reading". Honouring it means
/// `NotificationScheduler` has to look at a `DashItem` and answer whether it
/// came from a `RecurringTask`. All it has is the `Assignment`, so the answer
/// has to be recoverable from the value alone.
///
/// **Why by pattern-matching rather than by a nice explicit prefix.** A
/// `"recurring:"` prefix would be cleaner to read and is the obvious first
/// instinct. It is also wrong here, because `sourceID` is half of
/// `Assignment.id`, and `Assignment.id` is the key completion is filed under on
/// the SwiftData ledger. Changing the format would orphan every recurring item
/// the student has already ticked off — a reading marked done on Sunday would
/// reappear as owed on Monday, permanently, for the one kind of item that
/// regenerates weekly. This repo's whole persistence thesis is that losing
/// finished work is the failure it cannot have (see the v3 ledger notes), so the
/// stored format stays exactly as it was and recognition works with it.
///
/// The format is unambiguous as it stands, which is what makes that safe:
///
/// - `.canvasSuggestion` is minted **only** by this type — `RecurringTask.source`
///   is the sole place in the codebase that produces it — so that source alone
///   settles it.
/// - `.manual` is shared with `ManualAssignment`, which writes
///   `"manual-<UUID>"`. An occurrence writes `"<UUID>-<epoch>"`. A 36-character
///   UUID followed by `-` and an integer cannot be confused with a string that
///   begins `"manual-"`, nor with a bare UUID (which is exactly 36 characters
///   and so fails the length test).
extension RecurringTask {

    /// The `sourceID` an occurrence due at `due` carries. The *shape* is frozen
    /// — see the note above on why this string cannot be redesigned — and the
    /// number on the end is `occurrenceStamp(due:zone:)`.
    ///
    /// - Parameter zone: the zone `due`'s wall-clock time is read in, which is
    ///   the phone's current zone for a caller that passes nothing.
    static func occurrenceSourceID(taskID: UUID, due: Date, zone: TimeZone = .current) -> String {
        "\(taskID.uuidString)-\(occurrenceStamp(due: due, zone: zone))"
    }

    /// The zone every occurrence id is counted in, wherever the phone is.
    ///
    /// An occurrence is "Tuesday at 9 pm", a local calendar date and a wall
    /// clock time, but the id used to end in the **instant** that lands on in
    /// the phone's zone. Fly home for break and the same Tuesday is a
    /// different instant, so the id changed under it: the ticks the student
    /// had made were filed under ids that no longer existed, the week's
    /// readings came back as owed, and the due-date edits keyed by the old id
    /// were gone too (`DAT-12` in `docs/HARDENING_PLAN_2026-10-25.md`). The
    /// id now ends in the instant that same local date and clock time would
    /// be in this fixed zone, so it is the same string in every zone.
    ///
    /// **Why Eastern, and why not the date as digits.** The obvious fix is to
    /// end the id in `20261027`. It would also orphan every tick and due-date
    /// edit the student has already made, once, on the day this ships, which
    /// is the failure the note above rules out. Counting in
    /// `America/New_York` makes the new id *byte for byte the old id* for a
    /// phone that is, or was when it minted the ids, in Eastern time, which is
    /// where Penn, Brown, Columbia, Cornell, Dartmouth, Harvard, Princeton
    /// and Yale all are. A phone in another zone gets new ids once, and then
    /// keeps them. A different constant would be equally stable and would
    /// orphan everyone; do not change this one, for the same reason the
    /// format is frozen.
    static let occurrenceAnchorZone: TimeZone =
        TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600) ?? .gmt

    /// The number an occurrence's id ends in: the local calendar date and
    /// clock time of `due` in `zone`, re-read in `occurrenceAnchorZone`.
    /// Both reads are Gregorian, so the phone's calendar system cannot change
    /// it either.
    static func occurrenceStamp(due: Date, zone: TimeZone) -> Int {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        return occurrenceStamp(due: due, in: local)
    }

    /// The same, for a caller that already holds the Gregorian calendar of
    /// the zone it is working in, so a pass over a task's ten weeks builds
    /// one calendar and not twenty. `calendar` must be Gregorian
    /// (`upcomingAssignments` has normalised it).
    static func occurrenceStamp(due: Date, in calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: due)
        let instant = occurrenceAnchorCalendar.date(from: parts) ?? due
        return Int(instant.timeIntervalSince1970)
    }

    private static let occurrenceAnchorCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = occurrenceAnchorZone
        return calendar
    }()

    /// The task a `sourceID` was generated by, or `nil` if it wasn't generated
    /// by one.
    ///
    /// Parsed by fixed offset rather than by splitting on `-`, because a UUID
    /// string contains four of them and a pre-1970 epoch would contribute a
    /// fifth; taking the first 36 characters and requiring the rest to be `-`
    /// plus an integer has neither ambiguity.
    static func occurrenceTaskID(fromSourceID sourceID: String) -> UUID? {
        let uuidLength = 36
        guard sourceID.count > uuidLength,
              let taskID = UUID(uuidString: String(sourceID.prefix(uuidLength)))
        else { return nil }
        let rest = sourceID.dropFirst(uuidLength)
        guard rest.first == "-" else { return nil }
        let epoch = rest.dropFirst()
        guard !epoch.isEmpty, Int(epoch) != nil else { return nil }
        return taskID
    }

    /// Whether this assignment is one of a recurring task's occurrences — a
    /// reading or a check-in — rather than real coursework.
    ///
    /// Gates the per-course `nothingToSubmitEnabled` switch's one carve-out
    /// (`NotificationScheduler` silences an occurrence's reminders when the
    /// toggle is off, but — unlike `.event` items and no-submission Canvas
    /// assignments — never hides it from the dashboard; see that field's doc
    /// comment). Answering `true` here for a genuine assignment would let
    /// the switch silence real work, so the `.manual` branch insists on the
    /// full structural match rather than guessing.
    static func isOccurrence(_ assignment: Assignment) -> Bool {
        switch assignment.source {
        case .canvasSuggestion:
            return true
        case .manual:
            return occurrenceTaskID(fromSourceID: assignment.sourceID) != nil
        case .canvas, .gradescope, .canvasModules, .canvasAnnouncement:
            // `.canvasModules` rows are imported module readings — real synced
            // coursework, exactly like the other feed sources, never a
            // generated occurrence. `.canvasAnnouncement` rows are real
            // coursework too, just extracted from an announcement's text
            // instead of a structured feed — an extractor-found "read ch. 4
            // before Friday" is a one-off task tied to that specific
            // announcement, not a rule this file's weekly-occurrence machinery
            // generated, so it's never mistaken for one here.
            return false
        }
    }
}

extension RecurringTask.Origin {
    init(_ source: CanvasRequirementSuggestion.Source) {
        switch source {
        case .syllabus:     self = .canvasSyllabus
        case .announcement: self = .canvasAnnouncement
        }
    }
}
