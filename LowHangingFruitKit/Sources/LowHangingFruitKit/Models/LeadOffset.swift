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
/// cases in the Kit, would put two definitions of the same integers in the
/// codebase and guarantee they eventually disagree.
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
    case m10 = 600
    case h1 = 3600
    case h3 = 10800
    case h24 = 86_400
    case d2 = 172_800
    case d7 = 604_800

    public var id: Int { rawValue }

    /// Settings-row label.
    public var label: String {
        switch self {
        case .m10: return "10 minutes before"
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
        case .m10: return "Due in 10 minutes"
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
    ///
    /// **`.m10` is deliberately not in here.** "10 minutes before" is opt-in: a
    /// reminder that close to the deadline is one a student asks for, not one
    /// to hand every install on the day the case ships. A saved selection is
    /// read back as-is, so an existing install's reminders stay exactly what
    /// they were; the new case can only appear in a set if the student
    /// switches it on.
    public static let defaults: Set<LeadOffset> = [.h24, .h1]

    /// The lead times a student can choose, and the only ones that fire, in the
    /// order Settings and the per-class override list them (shortest first).
    /// `.d7` ("1 week before") was taken out of Settings on 2026-09-24 as
    /// clutter — a week out is the dashboard's job, not a notification's.
    /// The case itself stays (raw values are frozen, see above, and saved
    /// sets may still hold it), but the scheduler skips it, since a
    /// student who had it on could no longer see the switch to turn it off.
    /// `.m10` was added on 2026-10-09 as an opt-in (see `defaults`).
    public static let offered: [LeadOffset] = [.m10, .h1, .h3, .h24, .d2]

    /// The lead times the first-run walk shows, which is `offered` minus
    /// `.m10`, on purpose and by name rather than by a filter.
    ///
    /// Onboarding lays these out as pills in a two-column grid
    /// (`OnboardingView.leadTimeSection`). Four options fill it as two even
    /// rows; a fifth would strand one pill alone in a half-empty third row, and
    /// that layout was not checked on a device for this change, so it is not
    /// something to alter as a side effect of adding a reminder. And a
    /// first-run student is choosing how early to be warned about their
    /// classes, not tuning a last-minute nudge; "10 minutes before" is one
    /// switch away in Profile → reminders, and in each class's own override,
    /// once they want it.
    ///
    /// Every entry here must also be in `offered`, or the first-run screen
    /// would show a pill for a lead time the scheduler skips (a test pins
    /// that).
    public static let onboardingOffered: [LeadOffset] = [.h1, .h3, .h24, .d2]
}
