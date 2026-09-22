import Foundation

/// One row of Canvas's `/courses/:id/tabs` response — the course navigation
/// menu (Home, Modules, Grades, and every LTI tool an instructor has placed
/// in the left rail). Nothing else in this codebase reads this endpoint:
/// `CourseKnowledgeCollector` finds external links by scanning module items
/// (`ExternalUrl`), which only ever sees a tool if an instructor also linked
/// it from inside a module — a tool that lives *only* in course navigation
/// (added once, from the course's own Navigation settings, and never touched
/// again) is invisible to that scan. `/tabs` is the one endpoint that lists
/// every navigation entry regardless of whether anything in a module points
/// at it, which is what makes it the right (and only) way to find something
/// like an "Ed Discussion" nav item.
///
/// Explicit `CodingKeys` rather than relying on decoder key conversion:
/// `CourseContentAPI.decoder()` (`CanvasCourseContentClient.swift`) sets no
/// `keyDecodingStrategy`, so every other wire shape in this API spells out
/// its own snake_case keys, and this type matches that convention rather
/// than silently depending on a decoder option nothing else here uses.
public struct CanvasCourseTab: Codable, Sendable, Hashable {
    /// Canvas's tab id. For an LTI tool this is
    /// `"context_external_tool_<id>"`; for a built-in tab it's a short fixed
    /// word (`"assignments"`, `"grades"`, …). Never assumed to be numeric.
    public let id: String
    public let label: String
    /// `"external"` for an LTI tool, `"internal"` for a built-in Canvas tab,
    /// absent on some Canvas versions — treated as an optional hint, not a
    /// filter key.
    public let type: String?
    /// The page Canvas itself would send a browser to for this tab —
    /// present for external tools, absent for some built-ins.
    public let htmlURL: String?
    /// A small subset of tabs (mainly external tools) also carry a plain
    /// `url`, distinct from `htmlURL`; kept alongside it since either can be
    /// the one that actually contains "edstem" for a given course's setup.
    public let url: String?
    public let hidden: Bool?
    /// `"public"`, `"members"`, `"admins"`, … — whether a tab is visible to
    /// students at all. Not filtered on here; a hidden tab is still evidence
    /// worth reporting to the probe, since "the tool exists but is hidden
    /// from students" is itself a finding.
    public let visibility: String?

    enum CodingKeys: String, CodingKey {
        case id, label, type, url, hidden, visibility
        case htmlURL = "html_url"
    }

    public init(
        id: String,
        label: String,
        type: String? = nil,
        htmlURL: String? = nil,
        url: String? = nil,
        hidden: Bool? = nil,
        visibility: String? = nil
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.htmlURL = htmlURL
        self.url = url
        self.hidden = hidden
        self.visibility = visibility
    }
}
