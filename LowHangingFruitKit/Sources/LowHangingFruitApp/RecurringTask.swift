import Foundation
import LowHangingFruitKit

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
                sourceID: "\(id.uuidString)-\(Int(due.timeIntervalSince1970))",
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

extension RecurringTask.Origin {
    init(_ source: CanvasRequirementSuggestion.Source) {
        switch source {
        case .syllabus:     self = .canvasSyllabus
        case .announcement: self = .canvasAnnouncement
        }
    }
}
