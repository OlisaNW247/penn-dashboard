import Foundation

/// A tappable pointer from a dashboard item back to the page it came from
/// ("open in canvas", "open in gradescope").
///
/// **Derived at display time, never stored.** The ledger already keeps each
/// item's `url` (`StoredAssignment.urlString`), and the only thing wrong with
/// that URL is that it is not always the page a student wants: Canvas's ICS
/// feed points an assignment at a *calendar* view
/// (`/calendar?include_contexts=course_<cid>&month=…&year=…#assignment_<aid>`),
/// which opens the month grid rather than the assignment. Rewriting what is
/// stored to fix that would be a data change to a tier that "never loses
/// anything" (CLAUDE.md → Architecture), and the stored shape is what
/// `Assignment.canvasAssignmentID` and the grade-watcher joins read, so
/// `Assignment.sourceLinks` computes the better link on the way out and leaves
/// the stored value alone.
public struct SourceLink: Equatable, Sendable, Identifiable {
    public let url: URL
    /// Lowercase words, in the app's voice ("open in canvas").
    public let label: String

    /// A card never shows the same URL twice, so the URL is identity enough.
    public var id: String { url.absoluteString }

    public init(url: URL, label: String) {
        self.url = url
        self.label = label
    }

    public static let canvasLabel = "open in canvas"
    public static let gradescopeLabel = "open in gradescope"
}

/// Reads the numeric Canvas course id out of a Canvas URL. Lives in the Kit so
/// `AppState.courseID(from:)` (Grade Watcher's course resolution) and
/// `Assignment.sourceLinks` cannot drift apart on what counts as a course id.
public enum CanvasCourseURL {
    /// Pulls a Canvas course id out of an ICS item's URL. Canvas emits two
    /// shapes: a direct `/courses/<id>/assignments/<id>` link, and — for items
    /// surfaced through the calendar rather than the course — a
    /// `/calendar?include_contexts=course_<id>` link. Only the first was handled
    /// before, so a feed of the second kind resolved no courses at all and Grade
    /// Watcher reported that nothing was selected.
    public static func courseID(from url: URL) -> String? {
        let parts = url.pathComponents
        if let index = parts.firstIndex(of: "courses"),
           parts.indices.contains(parts.index(after: index)) {
            let candidate = parts[parts.index(after: index)]
            if !candidate.isEmpty, candidate.allSatisfy(\.isNumber) { return candidate }
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let contexts = components.queryItems?
                .first(where: { $0.name == "include_contexts" })?.value
        else { return nil }

        for context in contexts.split(separator: ",") where context.hasPrefix("course_") {
            let id = context.dropFirst("course_".count)
            if !id.isEmpty, id.allSatisfy(\.isNumber) { return String(id) }
        }
        return nil
    }
}

extension Assignment {
    /// Zero, one or two links back to the page(s) this item came from, in the
    /// order the card shows them: Canvas first, then Gradescope for an item the
    /// deduplicator merged from both.
    ///
    /// Every URL returned is `https` with a host. The stored URL comes out of a
    /// feed and a SwiftData row, and a `Link` will hand whatever it is given to
    /// the system, so anything else (an `http` URL, a `javascript:` or `file:`
    /// scheme, a relative URL) is dropped rather than offered.
    ///
    /// Sources with nothing to point at — `.manual` (including recurring tasks)
    /// and `.canvasSuggestion`, which carry `url: nil` — return no links, and so
    /// does any item whose stored URL fails the check above. Nothing here
    /// guesses a URL for them: a link to the wrong page is worse than no link.
    public var sourceLinks: [SourceLink] {
        switch source {
        case .canvas, .canvasModules:
            var links: [SourceLink] = []
            if let canvas = canvasSourceURL {
                links.append(SourceLink(url: canvas, label: SourceLink.canvasLabel))
            }
            // The deduplicator keeps only the Canvas URL on a merged pair and
            // records the Gradescope twin in `linkedID`; this is the only place
            // that twin's page is still reachable from.
            if let gradescope = linkedGradescopeURL {
                links.append(SourceLink(url: gradescope, label: SourceLink.gradescopeLabel))
            }
            return links

        case .gradescope:
            guard let gradescope = gradescopeSourceURL else { return [] }
            return [SourceLink(url: gradescope, label: SourceLink.gradescopeLabel)]

        case .canvasAnnouncement:
            // The stored URL is the announcement's own Canvas `html_url`; there
            // is nothing better to derive.
            guard let url, Self.isSafeWebURL(url) else { return [] }
            return [SourceLink(url: url, label: SourceLink.canvasLabel)]

        case .manual, .canvasSuggestion:
            return []
        }
    }

    // MARK: - Canvas

    /// The best Canvas page for a `.canvas` / `.canvasModules` row.
    ///
    /// 1. A URL that already names a Canvas object
    ///    (`/courses/<cid>/assignments|quizzes|discussion_topics/<id>`) is used
    ///    unchanged. A quiz or discussion is never rewritten to `/assignments/`:
    ///    those live in their own id spaces, so the same number there names a
    ///    different object (the mis-join `AppState.moduleReadingAssignment`
    ///    already guards against).
    /// 2. A calendar-shaped URL whose fragment is `#assignment_<aid>` and whose
    ///    query names a course becomes `/courses/<cid>/assignments/<aid>` on the
    ///    *stored URL's own host*, so a non-Penn school's link stays on its own
    ///    Canvas.
    /// 3. Anything else falls back to the stored URL itself.
    ///
    /// The assignment id in (2) is read from the URL's fragment only, **not**
    /// from `canvasAssignmentID`, even though that property is the join key
    /// everywhere else. It falls back to the ICS UID, and the pattern it uses
    /// there (`assignment-(\d+)`, unanchored) also matches inside
    /// `event-sub_assignment-<n>`, a sub-assignment / checkpoint id from a
    /// different id space. For an equality join that residue is harmless;
    /// building a URL from it would send the student to the wrong assignment.
    /// For the same reason an `event-assignment-override-<n>` UID is never
    /// consulted: `<n>` is a section-override id (CLAUDE.md → Canvas
    /// assignment id trap), and the fragment is the only honest carrier of
    /// the real id. When the fragment is missing or not a plain
    /// `#assignment_<aid>` (a `#sub_assignment_<n>` or `#quiz_<n>`), case (3)
    /// applies.
    private var canvasSourceURL: URL? {
        guard let url, Self.isSafeWebURL(url) else { return nil }

        if Self.namesCanvasObject(url) { return url }

        if let assignmentID = Self.fragmentAssignmentID(of: url),
           let courseID = CanvasCourseURL.courseID(from: url),
           Self.isASCIIDigits(courseID) {
            var components = URLComponents()
            components.scheme = "https"
            components.host = url.host
            components.port = url.port
            components.path = "/courses/\(courseID)/assignments/\(assignmentID)"
            if let built = components.url, Self.isSafeWebURL(built) { return built }
        }

        return url
    }

    /// True for `/courses/<cid>/(assignments|quizzes|discussion_topics)/<id>`
    /// (with anything after it), judged on the path alone.
    private static func namesCanvasObject(_ url: URL) -> Bool {
        let parts = url.pathComponents
        guard parts.count >= 5,
              parts[0] == "/",
              parts[1] == "courses",
              isASCIIDigits(parts[2]),
              ["assignments", "quizzes", "discussion_topics"].contains(parts[3]),
              isASCIIDigits(parts[4])
        else { return false }
        return true
    }

    /// The `<aid>` of a `#assignment_<aid>` fragment, and only that shape:
    /// `#sub_assignment_<n>` and `#quiz_<n>` do not start with `assignment_`.
    private static func fragmentAssignmentID(of url: URL) -> String? {
        guard let fragment = url.fragment, fragment.hasPrefix("assignment_") else { return nil }
        let id = String(fragment.dropFirst("assignment_".count))
        return isASCIIDigits(id) ? id : nil
    }

    // MARK: - Gradescope

    private static let gradescopeOrigin = "https://www.gradescope.com"

    /// A `.gradescope` row's stored URL, or — only when none was stored — the
    /// assignment page rebuilt from its `sourceID`
    /// (`course-<cid>-assignment-<aid>`, written by `GradescopeClient`). A
    /// stored URL that fails the https check is dropped, not replaced.
    private var gradescopeSourceURL: URL? {
        if let url { return Self.isSafeWebURL(url) ? url : nil }
        return Self.gradescopeAssignmentURL(fromIdentity: sourceID)
    }

    /// The Gradescope twin of a deduplicated Canvas item, from the
    /// `gradescope:course-<cid>-assignment-<aid>` identity in `linkedID`.
    private var linkedGradescopeURL: URL? {
        guard let linkedID, linkedID.hasPrefix("gradescope:") else { return nil }
        return Self.gradescopeAssignmentURL(fromIdentity: String(linkedID.dropFirst("gradescope:".count)))
    }

    /// Parses exactly `course-<cid>-assignment-<aid>`. `GradescopeClient` writes
    /// `course-0-…` when it could not read the course id off the page, and `0`
    /// names no real course, so that placeholder builds nothing.
    private static func gradescopeAssignmentURL(fromIdentity identity: String) -> URL? {
        let parts = identity.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4,
              parts[0] == "course", parts[2] == "assignment",
              isASCIIDigits(parts[1]), parts[1] != "0",
              isASCIIDigits(parts[3])
        else { return nil }
        guard let url = URL(string: "\(gradescopeOrigin)/courses/\(parts[1])/assignments/\(parts[3])"),
              isSafeWebURL(url)
        else { return nil }
        return url
    }

    // MARK: - Shared checks

    private static func isSafeWebURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return false }
        return true
    }

    private static func isASCIIDigits(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
