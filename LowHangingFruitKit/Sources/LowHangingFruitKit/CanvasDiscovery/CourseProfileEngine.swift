import Foundation

/// What an authenticated per-course probe found (syllabus / assignment-group
/// JSON for submittability, and the Modules page for readings). Both fields
/// are independently optional: a probe can succeed at fetching the course
/// but fail to determine one or the other, and the engine needs to tell
/// "probed, found nothing" apart from "never probed" (see `unknownSilent`).
public struct CourseProbeResult: Sendable, Hashable {
    /// Count of assignment-group entries whose `submission_types` isn't
    /// `none`/`on_paper` — i.e. work Canvas expects an actual submission
    /// for. Not currently used to reclassify a course (silence is decided by
    /// feed presence alone, see `CourseProfileEngine.reports`); carried here
    /// so a future probe-driven refinement doesn't need a new fetch.
    public let submittableAssignmentCount: Int?
    /// Count of items found on the course's Modules page.
    public let moduleReadingCount: Int?

    public init(submittableAssignmentCount: Int?, moduleReadingCount: Int?) {
        self.submittableAssignmentCount = submittableAssignmentCount
        self.moduleReadingCount = moduleReadingCount
    }
}

/// The shape a course's Canvas presence takes, as seen by LHF. Drives both
/// whether a nudge is worth showing and what it says (docs/READINGS_COURSES_PLAN.md).
public enum CourseProfile: Sendable, Hashable {
    /// Feed already carries submittable work for this course. No nudge.
    case normal
    /// Feed has dated calendar items (typically `.event`s — readings,
    /// exam dates) but nothing submittable. `eventCount`/`latestDate`
    /// describe those items so the nudge copy can be concrete.
    case readingsOnCalendar(eventCount: Int, latestDate: Date?)
    /// Enrolled (per the authenticated course list) but zero feed items.
    /// `moduleReadingCount` is folded in from a probe when one exists for
    /// this course; nil means the probe ran but didn't find/determine a
    /// count, not that no probe ran (that's `unknownSilent`).
    case silent(moduleReadingCount: Int?)
    /// Silent, and no probe data at all — no live Canvas session to look
    /// closer with. Nudge copy for this case has to be honest that LHF
    /// can't yet say what's in the course.
    case unknownSilent
}

/// A single course's computed profile, ready for the decision/nudge layer
/// (Phase 2) to consult.
public struct CourseProfileReport: Sendable, Hashable {
    /// Course CODE (e.g. "CIS 2400") when one could be derived, either from
    /// the feed item's already-clean `course` field or by parsing the
    /// enrolled course's display name via `CourseCode.parse`. Falls back to
    /// the raw enrolled display name when no code could be recognized, so
    /// two different unparsed courses don't collide on the same key.
    public let courseKey: String
    /// The numeric Canvas course id, when this report is grounded in (or
    /// could be matched to) an entry from the enrolled-course list.
    public let canvasCourseID: String?
    public let displayName: String
    public let profile: CourseProfile
    /// A string stable across runs while the profile's CLASS and rough
    /// shape hold, so the decision layer can tell "nothing changed" apart
    /// from "this course's shape changed enough to re-ask" (see
    /// `CourseProfileEngine.fingerprint`).
    public let fingerprint: String

    public init(
        courseKey: String,
        canvasCourseID: String?,
        displayName: String,
        profile: CourseProfile,
        fingerprint: String
    ) {
        self.courseKey = courseKey
        self.canvasCourseID = canvasCourseID
        self.displayName = displayName
        self.profile = profile
        self.fingerprint = fingerprint
    }
}

/// Pure, deterministic, no networking: turns already-fetched data (feed
/// items, the enrolled-course list, and any probe results the caller
/// managed to collect) into one profile per course. Everything it needs is
/// a parameter, so it's exercised entirely with synthetic fixtures — no
/// live Canvas session required to test it (docs/READINGS_COURSES_PLAN.md
/// Phase 1.4).
public enum CourseProfileEngine {
    /// - Parameters:
    ///   - feedItems: Every parsed calendar item across all courses.
    ///     Items whose `course` is `"(unknown course)"` (see `CourseCode
    ///     .parse`) are ignored entirely — there's no key to report them
    ///     under, and a nudge with no course name to show would be useless.
    ///   - enrolledCourses: The authenticated course list
    ///     (`CanvasDiscoveryClient.discoverEnrolledCourses()`), which is
    ///     what makes SILENT detectable at all — a course with zero feed
    ///     items is otherwise invisible to LHF.
    ///   - probes: Per-course probe results, keyed by the same numeric id
    ///     `enrolledCourses` uses. Absence of a key (rather than a probe
    ///     with `nil` fields) is what distinguishes `silent` from
    ///     `unknownSilent` — an unprobed course, e.g. because the session
    ///     had expired, mustn't be reported as "probed, found nothing."
    public static func reports(
        feedItems: [Assignment],
        enrolledCourses: [CanvasCourseDiscoveryParser.Course],
        probes: [String: CourseProbeResult]
    ) -> [CourseProfileReport] {
        var feedGroups: [String: [Assignment]] = [:]
        for item in feedItems where item.course != "(unknown course)" {
            feedGroups[item.course, default: []].append(item)
        }

        // Enrolled courses keyed the same way feed items already are, so a
        // course that shows up in both places collapses to one report
        // instead of a duplicate "normal" + "silent" pair. Later entries win
        // on a key collision (e.g. cross-listed sections) — rare, and not a
        // case this engine needs to disambiguate further.
        var enrolledByKey: [String: CanvasCourseDiscoveryParser.Course] = [:]
        for course in enrolledCourses {
            enrolledByKey[courseKey(for: course)] = course
        }

        var reports: [CourseProfileReport] = []

        for (key, items) in feedGroups {
            let matchedCourse = enrolledByKey[key]
            let profile = feedProfile(for: items)
            reports.append(CourseProfileReport(
                courseKey: key,
                canvasCourseID: matchedCourse?.id,
                displayName: matchedCourse?.name ?? key,
                profile: profile,
                fingerprint: fingerprint(for: profile)
            ))
        }

        for (key, course) in enrolledByKey where feedGroups[key] == nil {
            let probe = probes[course.id]
            let profile: CourseProfile = probe != nil
                ? .silent(moduleReadingCount: probe?.moduleReadingCount)
                : .unknownSilent
            reports.append(CourseProfileReport(
                courseKey: key,
                canvasCourseID: course.id,
                displayName: course.name,
                profile: profile,
                fingerprint: fingerprint(for: profile)
            ))
        }

        return reports.sorted { $0.courseKey.localizedCaseInsensitiveCompare($1.courseKey) == .orderedAscending }
    }

    /// A course with ≥1 submittable feed item (`.assignment`/`.quiz`) is
    /// NORMAL regardless of anything else in the feed. Otherwise, any dated
    /// items at all (typically `.event`, but a discussion- or other-only
    /// feed shape falls in here too — there's no submittable work, which is
    /// the property that matters) make it READINGS_ON_CALENDAR, counted and
    /// dated by the `.event` items specifically per the plan's "N dated
    /// readings through DATE" copy, falling back to all items present if
    /// there happen to be no `.event`s among them.
    private static func feedProfile(for items: [Assignment]) -> CourseProfile {
        let hasSubmittable = items.contains { $0.kind == .assignment || $0.kind == .quiz }
        guard !hasSubmittable else { return .normal }

        let events = items.filter { $0.kind == .event }
        let countedItems = events.isEmpty ? items : events
        let latestDate = countedItems.compactMap(\.dueAt).max()
        return .readingsOnCalendar(eventCount: countedItems.count, latestDate: latestDate)
    }

    private static func courseKey(for course: CanvasCourseDiscoveryParser.Course) -> String {
        let parsedCode = CourseCode.parse(course.name).code
        return parsedCode == "(unknown course)" ? course.name : parsedCode
    }

    /// Buckets a count down to the nearest multiple of 5 (11-14 all bucket
    /// to 10, 15-19 to 15, …) so a professor posting one extra reading, or a
    /// module page miscounting by a couple, doesn't flip the fingerprint and
    /// re-trigger an ask the user already answered. Only the profile's CLASS
    /// and rough shape need to be stable — exact counts still come from live
    /// data at ask time, not from the fingerprint.
    private static func bucket(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (count / 5) * 5
    }

    private static func fingerprint(for profile: CourseProfile) -> String {
        switch profile {
        case .normal:
            return "normal"
        case let .readingsOnCalendar(eventCount, _):
            return "readings:\(bucket(eventCount))"
        case let .silent(moduleReadingCount):
            guard let moduleReadingCount else { return "silent:none" }
            return "silent:\(bucket(moduleReadingCount))"
        case .unknownSilent:
            return "unknownSilent"
        }
    }
}
