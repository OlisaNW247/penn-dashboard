import Foundation

/// The four things an ambassador does, as the page lists them (2026-11-21,
/// Marco: the page had grown into a wall of sections; it is now four tasks,
/// each opening into its own view where it is done and ticked).
public enum AmbassadorTask: String, CaseIterable, Identifiable, Codable, Sendable {
    case anonChats
    case groupChats
    case posters
    case feedback

    public enum Period: Sendable { case day, week }

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .anonChats: return "anonymous chats"
        case .groupChats: return "group chats"
        case .posters: return "posters"
        case .feedback: return "feedback"
        }
    }

    public var symbol: String {
        switch self {
        case .anonChats: return "bubble.left.and.bubble.right"
        case .groupChats: return "person.3"
        case .posters: return "photo.on.rectangle.angled"
        case .feedback: return "envelope"
        }
    }

    /// How long a tick lasts: the anonymous post is a daily thing, the other
    /// three are weekly.
    public var period: Period {
        switch self {
        case .anonChats: return .day
        case .groupChats, .posters, .feedback: return .week
        }
    }
}

/// Which task was last done on which of the server's day indexes. Pure: the
/// caller supplies today's index (the server's, so the phone's midnight and
/// the server's agree, as `postedToday` does).
public struct AmbassadorTaskLog: Codable, Equatable, Sendable {
    public var doneDayIndex: [String: Int]
    /// Every day an anonymous post was logged, so the week's dots and the
    /// weekly minimum can be read back (the single `doneDayIndex` entry only
    /// remembers the last one). Never sent anywhere.
    public var anonDays: Set<Int>

    public init(doneDayIndex: [String: Int] = [:], anonDays: Set<Int> = []) {
        self.doneDayIndex = doneDayIndex
        self.anonDays = anonDays
    }

    private enum CodingKeys: String, CodingKey { case doneDayIndex, anonDays }

    /// A log saved before `anonDays` existed has no such key: it decodes with
    /// an empty set instead of failing, which would reset every tick.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        doneDayIndex = try c.decodeIfPresent([String: Int].self, forKey: .doneDayIndex) ?? [:]
        anonDays = (try? c.decodeIfPresent(Set<Int>.self, forKey: .anonDays)) ?? []
    }

    /// A day task is done on the day it was ticked; a week task for the seven
    /// days from it (the day itself and six more). A future index never
    /// counts, so a wrong clock cannot leave a task ticked for good.
    public func isDone(_ task: AmbassadorTask, todayIndex: Int) -> Bool {
        guard let index = doneDayIndex[task.rawValue] else { return false }
        switch task.period {
        case .day: return index == todayIndex
        case .week: return index <= todayIndex && todayIndex - index < 7
        }
    }

    public mutating func markDone(_ task: AmbassadorTask, todayIndex: Int) {
        doneDayIndex[task.rawValue] = todayIndex
        if task == .anonChats { anonDays.insert(todayIndex) }
    }

    /// Posts logged on today and the six days before it. A future index never
    /// counts, like `isDone`.
    public func anonPostsInLastWeek(todayIndex: Int) -> Int {
        anonDays.filter { $0 <= todayIndex && todayIndex - $0 < 7 }.count
    }

    /// The weekly floor is one post; the goal is one a day.
    public func anonWeeklyMinimumMet(todayIndex: Int) -> Bool {
        anonPostsInLastWeek(todayIndex: todayIndex) >= 1
    }

    /// Seven flags for the week's dots, oldest first, today last.
    public func anonPostedDays(todayIndex: Int) -> [Bool] {
        (0..<7).map { anonDays.contains(todayIndex - 6 + $0) }
    }
}
