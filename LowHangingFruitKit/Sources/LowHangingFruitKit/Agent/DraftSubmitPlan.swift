import Foundation

/// What Canvas says about one assignment's submissions: the four fields the
/// submit preflight reads (`CanvasSubmissionClient`), read once and early so
/// the review sheet can say what Canvas takes before the student decides
/// (2026-11-11, after Marco's phone printed "submit this one in canvas" for a
/// text draft on an upload-only problem set).
public struct CanvasSubmissionRules: Equatable, Sendable {
    public var submissionTypes: [String]
    /// Lowercased, without dots. Empty means Canvas named none: any file.
    public var allowedExtensions: [String]
    public var lockedForUser: Bool
    /// Nil when Canvas did not send it (the assignments list never does).
    public var canSubmit: Bool?

    public init(submissionTypes: [String], allowedExtensions: [String] = [],
                lockedForUser: Bool = false, canSubmit: Bool? = nil) {
        self.submissionTypes = submissionTypes
        self.allowedExtensions = Self.normalised(allowedExtensions)
        self.lockedForUser = lockedForUser
        self.canSubmit = canSubmit
    }

    /// The preflight GET's assignment object, read leniently.
    public init(assignmentJSON object: [String: Any]) {
        self.init(submissionTypes: (object["submission_types"] as? [String]) ?? [],
                  allowedExtensions: (object["allowed_extensions"] as? [String]) ?? [],
                  lockedForUser: object["locked_for_user"] as? Bool == true,
                  canSubmit: object["can_submit"] as? Bool)
    }

    static func normalised(_ extensions: [String]) -> [String] {
        var seen = Set<String>()
        return extensions
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// What Canvas takes online for one assignment, in the five shapes the sheet
/// words: text, a link, a file (with its extensions), nothing online (on
/// paper, none, an external tool, a quiz, a discussion, media), or locked.
/// Text, link and file can come together (`online`).
public enum CanvasAcceptance: Equatable, Sendable {
    case online(text: Bool, url: Bool, file: Bool, extensions: [String])
    case notOnline
    case locked

    /// "Nothing online" wins over "locked": an on-paper assignment that is
    /// also locked is still one the phone can never send.
    public static func derive(_ rules: CanvasSubmissionRules) -> CanvasAcceptance {
        let types = Set(rules.submissionTypes)
        let text = types.contains("online_text_entry")
        let url = types.contains("online_url")
        let file = types.contains("online_upload")
        guard text || url || file else { return .notOnline }
        if rules.lockedForUser || rules.canSubmit == false { return .locked }
        return .online(text: text, url: url, file: file, extensions: file ? rules.allowedExtensions : [])
    }

    /// True when a file of this name would pass Canvas's extension list.
    public func acceptsFile(named name: String) -> Bool {
        guard case let .online(_, _, file, extensions) = self, file else { return false }
        guard !extensions.isEmpty else { return true }
        return extensions.contains((name as NSString).pathExtension.lowercased())
    }
}

/// How the student sends a draft: its text as text, its text rendered to a
/// PDF on the phone, its link, or its file.
public enum DraftSubmitRoute: String, Equatable, Sendable, CaseIterable {
    case text, pdf, url, file
}

/// The review sheet's choice, worked out once from the draft and what Canvas
/// takes: the routes on offer (a picker only when there are two), the one
/// chosen at first, or why nothing can be sent from the phone.
public struct DraftSubmitPlan: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        /// On paper, none, a quiz, an external tool; or an item the phone has
        /// no Canvas ids for, or one that is not a Canvas assignment.
        case notOnline
        case locked
        /// A file whose extension Canvas refuses (for a text draft, the
        /// rendered pdf on an assignment that names other extensions).
        case fileType(ext: String, allowed: [String])
        /// Canvas takes something online, but not this kind of draft (a link
        /// on an upload-only assignment).
        case kind(AgentDraft.Kind)
        /// A kind this build does not know: never sent.
        case unknownKind
    }

    public var routes: [DraftSubmitRoute]
    public var defaultRoute: DraftSubmitRoute?
    public var block: Block?

    public init(routes: [DraftSubmitRoute], defaultRoute: DraftSubmitRoute?, block: Block?) {
        self.routes = routes; self.defaultRoute = defaultRoute; self.block = block
    }

    static func blocked(_ block: Block) -> DraftSubmitPlan {
        DraftSubmitPlan(routes: [], defaultRoute: nil, block: block)
    }

    /// `acceptance` nil means it is not known yet (the early GET failed or is
    /// still out): the draft's own kind is offered, with the pdf beside text,
    /// and the submit's own preflight decides. `canRenderPDF` is
    /// `DraftDocumentRenderer.canRender` (false on macOS).
    public static func make(draft: AgentDraft, acceptance: CanvasAcceptance?, canRenderPDF: Bool) -> DraftSubmitPlan {
        if draft.kind == .unknown { return .blocked(.unknownKind) }
        guard let acceptance else {
            switch draft.kind {
            case .text:
                let routes: [DraftSubmitRoute] = canRenderPDF ? [.text, .pdf] : [.text]
                let preferred: DraftSubmitRoute = AgentDraftSubmitChoice.defaultChoice(for: draft) == .pdf ? .pdf : .text
                return DraftSubmitPlan(routes: routes, defaultRoute: routes.contains(preferred) ? preferred : .text, block: nil)
            case .url: return DraftSubmitPlan(routes: [.url], defaultRoute: .url, block: nil)
            case .file: return DraftSubmitPlan(routes: [.file], defaultRoute: .file, block: nil)
            case .unknown: return .blocked(.unknownKind)
            }
        }
        switch acceptance {
        case .notOnline: return .blocked(.notOnline)
        case .locked: return .blocked(.locked)
        case let .online(text, url, file, extensions):
            switch draft.kind {
            case .text:
                let pdfAllowed = file && (extensions.isEmpty || extensions.contains("pdf"))
                var routes: [DraftSubmitRoute] = []
                if text { routes.append(.text) }
                if pdfAllowed && canRenderPDF { routes.append(.pdf) }
                if routes.isEmpty {
                    if file && !pdfAllowed { return .blocked(.fileType(ext: "pdf", allowed: extensions)) }
                    return .blocked(.kind(.text))
                }
                // Both go: plain text defaults to text, a markdown draft to
                // the pdf (sent as text, its `**` and `#` would arrive raw).
                let markdown = routes.contains(.pdf) && AgentDraftSubmitChoice.defaultChoice(for: draft) == .pdf
                return DraftSubmitPlan(routes: routes, defaultRoute: markdown ? .pdf : routes[0], block: nil)
            case .url:
                return url ? DraftSubmitPlan(routes: [.url], defaultRoute: .url, block: nil) : .blocked(.kind(.url))
            case .file:
                guard file else { return .blocked(.kind(.file)) }
                let name = draft.fileName ?? ""
                if acceptance.acceptsFile(named: name) {
                    return DraftSubmitPlan(routes: [.file], defaultRoute: .file, block: nil)
                }
                return .blocked(.fileType(ext: (name as NSString).pathExtension.lowercased(), allowed: extensions))
            case .unknown:
                return .blocked(.unknownKind)
            }
        }
    }
}
