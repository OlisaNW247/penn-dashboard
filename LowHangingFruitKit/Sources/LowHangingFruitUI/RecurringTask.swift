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

    func upcomingAssignments(from now: Date = Date(), weeksAhead: Int = 10) -> [Assignment] {
        let calendar = Calendar.current
        let horizon = calendar.date(byAdding: .day, value: weeksAhead * 7, to: now) ?? now
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        components.weekday = weekday
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard var due = calendar.date(from: components) else { return [] }
        if due < calendar.startOfDay(for: startDate) {
            due = nextDueDate(onOrAfter: startDate) ?? due
        }
        if due < now {
            due = calendar.date(byAdding: .day, value: 7, to: due) ?? due
        }

        var assignments: [Assignment] = []
        while due <= horizon {
            if let endDate, due > endDate { break }
            assignments.append(Assignment(
                source: source,
                sourceID: Self.occurrenceSourceID(taskID: id, due: due),
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

    private func nextDueDate(onOrAfter date: Date) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.current.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
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

    /// The `sourceID` an occurrence due at `due` carries. Frozen — see the note
    /// above on why this string cannot be redesigned.
    static func occurrenceSourceID(taskID: UUID, due: Date) -> String {
        "\(taskID.uuidString)-\(Int(due.timeIntervalSince1970))"
    }

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
    /// Gates the per-course `recurringEnabled` switch. Answering `true` here for
    /// a genuine assignment would let that switch silence real work, so the
    /// `.manual` branch insists on the full structural match rather than
    /// guessing.
    static func isOccurrence(_ assignment: Assignment) -> Bool {
        switch assignment.source {
        case .canvasSuggestion:
            return true
        case .manual:
            return occurrenceTaskID(fromSourceID: assignment.sourceID) != nil
        case .canvas, .gradescope:
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
