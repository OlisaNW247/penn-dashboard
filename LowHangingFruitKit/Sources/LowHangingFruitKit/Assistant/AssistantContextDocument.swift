import Foundation

/// Builds the single text document handed to Claude as a cacheable system
/// prompt for the in-app class assistant ("ask").
///
/// ## Why this has to be byte-stable
///
/// Anthropic's prompt caching keys on an exact byte prefix: the first call
/// that sends a given system prompt pays full price and the API caches it;
/// every later call that sends the *identical* prefix reuses that cache and
/// is billed — and behaves, latency-wise — as if that prefix were nearly
/// free. The moment a single byte of this document differs between two
/// calls, the cache misses and the student pays in full, in tokens and in
/// wall-clock time, to re-process the whole class context just to ask one
/// more question. So the property this file exists to guarantee is not
/// "produces a readable document" — any string does that — it's "produces
/// the *same* string for the *same* facts, forever, regardless of when or
/// on what device it runs." Everything below is in service of that one
/// property.
///
/// The tempting wrong fix, the day someone asks "what's due soon", is to
/// stamp today's date at the top so the model "knows what day it is" —
/// something like `# Today is 2026-09-02`. Do not do that here. That line
/// changes every single day, which invalidates the cache once every 24
/// hours for every student, which throws away most of the point of caching
/// a document that is otherwise stable for weeks at a stretch. The current
/// date is cheap, per-question context; it belongs in the user-turn message
/// the caller sends alongside this cached system prompt, not baked into the
/// cached prefix. The same reasoning rules out any relative framing at all
/// — "due tomorrow", "3 days overdue", "posted last week" are all functions
/// of *when the question is asked*, not facts about the student's classes,
/// and belong at question time, computed by the caller from the absolute
/// dates this document does contain.
///
/// Concretely, this file:
/// - never touches the wall clock or a random source — no `Date()`,
///   `Date.now`, `UUID()`, and no relative-time strings;
/// - sorts every collection through an explicit, total comparator before
///   rendering, so two calls carrying the same facts in a different array
///   order (a fetch returning items in a new sequence, a `Set` walked in a
///   different hash order, a shuffled fixture in a test) still produce
///   identical bytes — nothing here trusts incoming order;
/// - renders every date through a formatter pinned to UTC and
///   `Locale(identifier: "en_US_POSIX")`, so the device's ambient timezone
///   and region — which differ per student and can change on the very same
///   device between two calls — can never leak a byte into the output.
public enum AssistantContextDocument {

    // MARK: - Input facts

    /// One course's identity and grading structure, as known on-device.
    ///
    /// Deliberately thin. `gradeCategories` is *only* the grading-weight
    /// table `SyllabusParser` manages to extract from a syllabus — never the
    /// syllabus's prose. Widening what this struct carries is a product
    /// decision (see the header this type feeds into,
    /// `AssistantContextDocument.build(...)`, for why that boundary is
    /// stated explicitly to the model rather than left implicit).
    public struct CourseFacts: Sendable, Equatable {
        /// The `CourseCode` key (see `CourseCode.parse`) — the same string
        /// `Assignment.course`, `CoursePreferences` and reminders all key
        /// on. This is the identifier the model should use to tie a `WORK`
        /// or `ANNOUNCEMENTS` line back to this course; `displayName` never
        /// is, because renaming a course is deliberately cosmetic-only in
        /// this app (see CLAUDE.md, "Course identity").
        public let code: String
        /// The student's own rename of the course, if they set one. Purely
        /// cosmetic — shown so the assistant can use the name the student
        /// actually recognizes, never as a substitute identifier for `code`.
        public let displayName: String?
        public let gradeCategories: [GradeCategoryFacts]

        public init(code: String, displayName: String?, gradeCategories: [GradeCategoryFacts]) {
            self.code = code
            self.displayName = displayName
            self.gradeCategories = gradeCategories
        }
    }

    /// One grading-weight line item extracted from a syllabus (e.g. "Problem
    /// sets, 20% of the final grade, lowest score dropped"). `weightPercent`
    /// is `nil`, not `0`, when the syllabus states a category exists but
    /// never gives it a number — `0` would be a false claim about the
    /// student's grade, not an admission of missing data.
    public struct GradeCategoryFacts: Sendable, Equatable {
        public let name: String
        public let weightPercent: Double?
        public let dropsLowest: Bool

        public init(name: String, weightPercent: Double?, dropsLowest: Bool) {
            self.name = name
            self.weightPercent = weightPercent
            self.dropsLowest = dropsLowest
        }
    }

    /// One dashboard item — an assignment, quiz, reading, lecture, or
    /// manually-added task — regardless of which of the app's sources it
    /// came from. Mirrors the shape of `Assignment` closely on purpose, but
    /// stays its own type rather than reusing `Assignment` directly: this
    /// struct is the seam between "everything the ledger knows" and "the
    /// small, stable slice that is safe and useful to hand an LLM", and
    /// letting `Assignment` grow a field should never silently change what
    /// this document contains.
    public struct WorkFacts: Sendable, Equatable {
        /// Course code, or `""` when the item couldn't be tied to a course
        /// (rendered as an explicit placeholder — see `build(...)` — rather
        /// than left blank, so a delimited line never has an ambiguous
        /// empty field).
        public let course: String
        public let title: String
        public let due: Date?
        public let isCompleted: Bool
        /// True for calendar entries that are informational rather than
        /// something to hand in — a lecture, an office hour, an exam date
        /// with no separate submission. Kept distinct from `isCompleted` so
        /// the document can say "nothing to submit" instead of the
        /// misleading "done", which would imply the student did something.
        public let nothingToSubmit: Bool
        /// "canvas" | "gradescope" | "reading" | "manual" — free-form on
        /// purpose, matching `Assignment.Source`'s raw values loosely rather
        /// than importing that enum, so this file has no dependency on
        /// `Assignment`'s shape.
        public let source: String

        public init(
            course: String,
            title: String,
            due: Date?,
            isCompleted: Bool,
            nothingToSubmit: Bool,
            source: String
        ) {
            self.course = course
            self.title = title
            self.due = due
            self.isCompleted = isCompleted
            self.nothingToSubmit = nothingToSubmit
            self.source = source
        }
    }

    /// One course announcement, trimmed to what's safe to hand an LLM
    /// wholesale. See `announcementBodyLimit`.
    public struct AnnouncementFacts: Sendable, Equatable {
        public let course: String
        public let title: String
        public let body: String
        public let postedAt: Date?

        public init(course: String, title: String, body: String, postedAt: Date?) {
            self.course = course
            self.title = title
            self.body = body
            self.postedAt = postedAt
        }
    }

    // MARK: - Limits

    /// Ceiling on how much of a single announcement body reaches the model,
    /// in `Character`s (grapheme clusters), not bytes or UTF-16 units — see
    /// `truncatedBody(_:)`. A professor's announcement can be a one-line
    /// room change or, just as easily, a forwarded email with a syllabus
    /// pasted into it; without a cap, one oversized announcement could
    /// dominate the context budget and, worse, dominate the *cached*
    /// prefix, since every future question pays to re-read it. 2000
    /// characters is generous for the case this feature actually targets —
    /// "the exam moved rooms" — while keeping a pathological paste bounded.
    public static let announcementBodyLimit = 2000

    // MARK: - Build

    /// Renders the full context document from on-device facts.
    ///
    public static func build(
        courses: [CourseFacts],
        work: [WorkFacts],
        announcements: [AnnouncementFacts]
    ) -> String {
        var lines = header

        let sortedCourses = courses.sorted(by: courseIsOrderedBefore)
        if !sortedCourses.isEmpty {
            lines.append("")
            lines.append("# CLASSES")
            for course in sortedCourses {
                lines.append(contentsOf: render(course))
            }
        }

        let sortedWork = work.sorted(by: workIsOrderedBefore)
        if !sortedWork.isEmpty {
            lines.append("")
            lines.append("# WORK")
            for item in sortedWork {
                lines.append(render(item))
            }
        }

        let sortedAnnouncements = announcements.sorted(by: announcementIsOrderedBefore)
        if !sortedAnnouncements.isEmpty {
            lines.append("")
            lines.append("# ANNOUNCEMENTS")
            for item in sortedAnnouncements {
                lines.append(contentsOf: render(item))
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Header

    /// States, in the document itself, what it does and does not contain.
    ///
    /// The "does not contain" half is the load-bearing part. The app's
    /// syllabus pipeline (`Syllabus/SyllabusParser.swift`) extracts grading
    /// weights and cutoff tables and discards the rest — it does not keep
    /// attendance policy, late-work policy, or office-hours text. A
    /// document that lists grading percentages and due dates *looks*
    /// comprehensive; a model handed it and asked "how many absences am I
    /// allowed" has every incentive to construct a plausible-sounding
    /// policy rather than say the app never captured one. Stating the gap
    /// explicitly, in the cached document the model always sees, is cheaper
    /// and more reliable than hoping a per-question prompt remembers to.
    private static var header: [String] {
        [
            "# ASSISTANT CONTEXT",
            "Generated on-device from the student's own Canvas and Gradescope data.",
            "Contains: the student's current classes, any grading weights the app",
            "extracted from a syllabus, work items with due dates and completion",
            "status, and recent course announcements (bodies truncated at",
            "\(announcementBodyLimit) characters).",
            "",
            "Does NOT contain syllabus prose: attendance policy, late-work policy,",
            "office hours, or any text beyond the grading weights listed under",
            "\"grading:\" below. If asked about a policy not stated in this document,",
            "say it isn't in the app's records rather than inferring one.",
        ]
    }

    // MARK: - Rendering

    private static func render(_ course: CourseFacts) -> [String] {
        var lines: [String] = []
        if let displayName = course.displayName, !displayName.isEmpty {
            lines.append("## \(course.code) (shown as: \(displayName))")
        } else {
            lines.append("## \(course.code)")
        }

        // Sorted independently of the parent array so a caller shuffling
        // `gradeCategories` (or a source that never guaranteed an order —
        // dictionary-derived syllabus extraction, say) can't change these
        // two lines' bytes either.
        let categories = course.gradeCategories.sorted { $0.name < $1.name }
        if categories.isEmpty {
            // Explicit rather than omitted: silence here would look
            // identical to "this course has no grading breakdown", which
            // isn't what a missing extraction means.
            lines.append("grading: not extracted from a syllabus")
        } else {
            let parts = categories.map { category -> String in
                if let weight = category.weightPercent {
                    return "\(category.name) \(formatPercent(weight))"
                } else {
                    return "\(category.name) (weight not specified)"
                }
            }
            lines.append("grading: \(parts.joined(separator: "; "))")

            let drops = categories.filter(\.dropsLowest).map(\.name)
            if !drops.isEmpty {
                lines.append("drops lowest: \(drops.joined(separator: ", "))")
            }
        }
        return lines
    }

    private static func render(_ item: WorkFacts) -> String {
        let courseLabel = item.course.isEmpty ? "(no course)" : item.course
        let dueLabel = item.due.map { "due \(isoTimestamp($0))" } ?? "no due date"
        let statusLabel: String
        if item.isCompleted {
            statusLabel = "done"
        } else if item.nothingToSubmit {
            statusLabel = "nothing to submit"
        } else {
            statusLabel = "outstanding"
        }
        return "\(courseLabel) | \(item.title) | \(dueLabel) | \(statusLabel) | \(item.source)"
    }

    private static func render(_ item: AnnouncementFacts) -> [String] {
        let courseLabel = item.course.isEmpty ? "(no course)" : item.course
        let dateSuffix = item.postedAt.map { " (\(isoDate($0)))" } ?? ""
        return [
            "## \(courseLabel) — \(item.title)\(dateSuffix)",
            truncatedBody(item.body),
        ]
    }

    /// Caps a body at `announcementBodyLimit` **characters** (grapheme
    /// clusters), never bytes. Cutting on a UTF-8 byte offset can land
    /// inside a multi-byte scalar or split a combined grapheme cluster
    /// (an emoji with a skin-tone modifier, an accented letter written as
    /// two scalars) and produce invalid or corrupted text; `String.prefix`
    /// only ever cuts between whole `Character`s, so this is always safe
    /// regardless of what a professor pasted into an announcement.
    private static func truncatedBody(_ body: String) -> String {
        guard body.count > announcementBodyLimit else { return body }
        return "\(body.prefix(announcementBodyLimit))…[truncated]"
    }

    // MARK: - Ordering

    /// Courses ascending by `code`, the identity key — never by
    /// `displayName`, which is cosmetic and mutable. The `displayName`
    /// tie-break only guards the (caller-bug) case of two facts sharing a
    /// `code`; it does not make `code` collisions a supported input.
    private static func courseIsOrderedBefore(_ a: CourseFacts, _ b: CourseFacts) -> Bool {
        if a.code != b.code { return a.code < b.code }
        return (a.displayName ?? "") < (b.displayName ?? "")
    }

    /// Due date ascending, undated work last, then title/course/source as
    /// tie-breaks so that two facts which are merely due at the same
    /// instant (a common case — a professor sets the same 11:59pm deadline
    /// for several assignments) still land in a fixed, input-order-blind
    /// sequence rather than whatever order they arrived in.
    private static func workIsOrderedBefore(_ a: WorkFacts, _ b: WorkFacts) -> Bool {
        if a.due != b.due {
            switch (a.due, b.due) {
            case let (dueA?, dueB?): return dueA < dueB
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        if a.title != b.title { return a.title < b.title }
        if a.course != b.course { return a.course < b.course }
        return a.source < b.source
    }

    /// Posted-at descending (most recent announcement first — the one most
    /// likely to matter to a "what changed" question), undated last, then
    /// title/course/body as tie-breaks for the same reason as
    /// `workIsOrderedBefore`.
    private static func announcementIsOrderedBefore(_ a: AnnouncementFacts, _ b: AnnouncementFacts) -> Bool {
        if a.postedAt != b.postedAt {
            switch (a.postedAt, b.postedAt) {
            case let (postedA?, postedB?): return postedA > postedB
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        if a.title != b.title { return a.title < b.title }
        if a.course != b.course { return a.course < b.course }
        return a.body < b.body
    }

    // MARK: - Deterministic formatting

    /// Full timestamp, always UTC, always this exact shape:
    /// "2026-09-04T23:59:00Z". Built fresh on every call rather than cached
    /// as a `static let` because `ISO8601DateFormatter` is a mutable
    /// Foundation class that isn't documented `Sendable` — the same reason
    /// `CanvasAnnouncementsClient.parseDate` and
    /// `CanvasGradesClient.parseDate` build theirs locally rather than
    /// reusing a shared instance.
    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Date-only ("2026-08-26"), used where the time of day would just be
    /// noise (the announcement section header). `DateFormatter`, not
    /// `ISO8601DateFormatter`, because the latter has no date-only output
    /// mode; pinned to `Locale(identifier: "en_US_POSIX")` and UTC for the
    /// same reason as `isoTimestamp(_:)` — an unpinned `DateFormatter`
    /// reads the device's ambient locale and timezone, and `en_US_POSIX` is
    /// Apple's own documented escape hatch for "the same digits everywhere,
    /// regardless of the user's region settings."
    private static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Renders a grading weight as "20%" or "17.5%" without ever routing
    /// through `String(format:)` or a locale-sensitive number rendering —
    /// pinned to `en_US_POSIX` for the same reason the date formatters
    /// above are, so a decimal weight never comes out with a comma decimal
    /// separator (as it would under, say, a French region setting) and
    /// silently change the document's bytes on a different device.
    private static func formatPercent(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let rendered = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return "\(rendered)%"
    }
}
