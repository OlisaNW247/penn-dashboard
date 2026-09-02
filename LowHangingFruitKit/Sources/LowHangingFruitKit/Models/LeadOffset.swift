import Foundation

/// How far before a due date a reminder fires.
///
/// **Why this lives in the Kit rather than on `NotificationScheduler`.** It
/// began as a nested enum on the scheduler, which was right for as long as the
/// only thing in the app with an opinion about lead times was the single global
/// Settings control that the scheduler itself owns. That stopped being true
/// when `CoursePreferences` grew a per-course `leadOffsets`: that type lives in
/// `LowHangingFruitKit`, the scheduler lives in `LowHangingFruitUI`, and the
/// Kit cannot import the UI module. Moving the enum *down* is the only
/// direction that resolves the dependency — the alternative, duplicating the
/// five cases in the Kit, would put two definitions of the same five integers
/// in the codebase and guarantee they eventually disagree.
///
/// `NotificationScheduler` keeps a nested `typealias LeadOffset` pointing here,
/// so `NotificationScheduler.LeadOffset` — the spelling Settings and every
/// other existing call site uses — still resolves to exactly this type.
///
/// **The raw values are seconds, and they are frozen.** They are persisted in
/// two places: the global `notif.leadOffsets` array, and the optional
/// per-course set inside the `coursePreferences` blob. Renumbering a case would
/// silently reinterpret every reminder a student has already configured — `.h1`
/// becoming three hours, say — with no error anywhere. A new lead time is a new
/// case with a new number, never a change to an existing one.
public enum LeadOffset: Int, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case h1 = 3600
    case h3 = 10800
    case h24 = 86_400
    case d2 = 172_800
    case d7 = 604_800

    public var id: Int { rawValue }

    /// Settings-row label.
    public var label: String {
        switch self {
        case .h1:  return "1 hour before"
        case .h3:  return "3 hours before"
        case .h24: return "1 day before"
        case .d2:  return "2 days before"
        case .d7:  return "1 week before"
        }
    }

    /// The reminder notification's entire body text (see
    /// `NotificationScheduler.plannedRequests` — the owner's notification
    /// redesign made the lead phrase the whole message). "Due in 24 hours",
    /// not "Due tomorrow": a 24h-before reminder for something due at 6 AM
    /// fires at 6 AM today, where "tomorrow" reads wrong.
    public var headline: String {
        switch self {
        case .h1:  return "Due in 1 hour"
        case .h3:  return "Due in 3 hours"
        case .h24: return "Due in 24 hours"
        case .d2:  return "Due in 2 days"
        case .d7:  return "Due in a week"
        }
    }

    /// What a student gets when they have never touched the reminder settings.
    ///
    /// Held here rather than inline in `NotificationScheduler.init` because
    /// per-course preferences need to be able to say "inherit the default" in
    /// contexts where no scheduler has been constructed — a Profile screen
    /// rendering a course row before reminders have ever been enabled, for one.
    public static let defaults: Set<LeadOffset> = [.h24, .h1]
}
