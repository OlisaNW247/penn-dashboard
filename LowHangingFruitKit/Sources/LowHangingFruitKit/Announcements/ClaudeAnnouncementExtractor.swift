import Foundation

/// Opt-in backend: calls Anthropic's Messages API directly over
/// `URLSession` (Anthropic ships no official Swift SDK, so raw HTTP against
/// a documented REST endpoint is the sanctioned path — the same stance this
/// package already takes toward Canvas and Gradescope, neither of which has
/// one either).
///
/// This exists for announcements `HeuristicAnnouncementExtractor` can't make
/// sense of — irregular phrasing, deadlines buried in a paragraph instead of
/// stated plainly. It costs money and a network round trip per call, so
/// nothing in this file decides *when* to use it; that policy (probably:
/// only after the free heuristic finds nothing, and only with the user's API
/// key present) belongs to whatever syncs announcements, not to the
/// extractor itself.
public struct ClaudeAnnouncementExtractor: AnnouncementAssignmentExtractor {
    public enum ExtractionError: Error, Sendable, Equatable {
        /// Non-2xx HTTP status from Anthropic (auth failure, rate limit,
        /// server error, etc.) — the raw status is preserved so a caller can
        /// distinguish "bad key" (401) from "try again later" (429/5xx)
        /// without this file having to encode that policy itself.
        case http(Int)
        /// The response body wasn't the JSON shape expected, at either the
        /// outer message level or inside the `tool_use` block's `input`.
        /// Also used for the "response wasn't HTTP at all" case, which in
        /// practice only happens against a broken `URLSession`/mock — there's
        /// no separate case for it because nothing downstream needs to tell
        /// the two apart.
        case decodingFailed(String)
        /// Claude answered but never invoked `record_assignments` — with
        /// `tool_choice` forced to that specific tool this should not happen
        /// in practice, but treating "no tool_use block" as success-with-zero-
        /// results would hide a real API contract change (a model update,
        /// Anthropic altering forced-tool-use behavior) behind a silently
        /// empty extraction instead of a visible error.
        case noToolUse
    }

    /// The cheapest Claude tier, and an explicit constraint from the feature
    /// owner: extraction runs on short, cheap announcement text, not on
    /// anything that needs the strongest model available. Every other
    /// request field lives in `buildRequest(for:now:)`; this is the one
    /// line to change if that constraint ever does.
    private static let model = "claude-haiku-4-5"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let systemPrompt = """
    You extract actionable student tasks from a professor's course announcement. Extract only concrete, dated-or-datable tasks the student must do (readings, submissions, preparation). Do not invent tasks or deadlines; omit anything uncertain. Emit nothing for purely informational announcements.
    """

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(Self.buildRequest(for: announcement, now: now))

        // No retries here, deliberately: every retry against this endpoint is
        // a billed API call, and this file has no visibility into whether a
        // failure is worth paying to retry (a 429 probably is, on backoff; a
        // 401 never is). That policy belongs to whatever layer calls this
        // extractor and can weigh cost against the rest of a sync run, not to
        // the client making one request.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExtractionError.decodingFailed("response was not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ExtractionError.http(http.statusCode)
        }
        return try Self.decodeExtraction(responseBody: data, now: now)
    }

    // MARK: - Request construction

    static func buildRequest(for announcement: AnnouncementSourceText, now: Date) -> MessagesRequest {
        MessagesRequest(
            model: model,
            maxTokens: 1024,
            system: systemPrompt,
            tools: [
                ToolSpec(
                    name: "record_assignments",
                    description: "Record the extracted tasks.",
                    inputSchema: RecordAssignmentsSchema()
                ),
            ],
            toolChoice: ToolChoice(name: "record_assignments"),
            messages: [ChatMessage(role: "user", content: userContent(for: announcement, now: now))]
        )
    }

    /// Course code, announcement title, posted-at, and "Current date" as
    /// plain-text context lines ahead of the body, so the model has the same
    /// grounding `HeuristicAnnouncementExtractor` gets for free from its
    /// `now`/`calendar` parameters — Claude has no other way to know what
    /// "today" or "the course" means for this announcement.
    ///
    /// The body is capped at 4000 characters — token economy. A professor
    /// occasionally pastes an entire syllabus into an "announcement"; the
    /// sentence that actually states the task is almost always in the first
    /// paragraph, so paying to send (and have the model read) thousands of
    /// characters of boilerplate past that point buys nothing. If this cap
    /// ever proves too aggressive, the fix is raising the number here, not
    /// removing the cap.
    static func userContent(for announcement: AnnouncementSourceText, now: Date) -> String {
        // Built locally, not cached as static state — `ISO8601DateFormatter`
        // is not `Sendable`, and this type needs to stay `Sendable` itself;
        // same convention `CanvasGradesClient.parseDate` and
        // `CanvasModulesClient.parseDate` already use.
        let iso = ISO8601DateFormatter()

        var lines: [String] = [
            "Course: \(announcement.courseCode)",
            "Announcement title: \(announcement.title)",
        ]
        if let postedAt = announcement.postedAt {
            lines.append("Posted at: \(iso.string(from: postedAt))")
        }
        lines.append("Current date: \(iso.string(from: now))")
        lines.append("")
        lines.append(String(announcement.body.prefix(4000)))
        return lines.joined(separator: "\n")
    }

    // MARK: - Response decoding (pure — no network, so this is fully unit-testable)

    /// The one seam every test in this file drives. Kept `static` and free of
    /// any instance state (no `apiKey`, no `session`) so a test can hand it a
    /// recorded or hand-written response body without constructing a real
    /// extractor or touching the network at all.
    static func decodeExtraction(responseBody: Data, now: Date) throws -> [ExtractedAssignment] {
        let decoded: MessagesResponse
        do {
            decoded = try JSONDecoder().decode(MessagesResponse.self, from: responseBody)
        } catch {
            throw ExtractionError.decodingFailed(String(describing: error))
        }

        guard let toolUseBlock = decoded.content.first(where: { $0.type == "tool_use" }),
              let input = toolUseBlock.input else {
            throw ExtractionError.noToolUse
        }

        return input.assignments.map { raw in
            ExtractedAssignment(
                title: raw.title,
                dueAt: raw.dueISO8601.flatMap { parseISO8601($0) }
            )
        }
    }

    /// The double-formatter trick used throughout this Kit for Canvas
    /// timestamps: try with fractional seconds first (`ISO8601DateFormatter`
    /// refuses to parse a fractional-seconds string without that option set,
    /// and refuses a non-fractional one *with* it set), fall back to plain.
    /// Local, not a stored static, for the same non-`Sendable` reason as
    /// `userContent(for:now:)`'s formatter above.
    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// MARK: - Request Codable shapes

/// Hand-written to mirror the exact JSON Anthropic's docs specify (see the
/// brief this was built from), rather than built from `[String: Any]`
/// dictionaries — a typo in a dictionary key is a runtime bug discovered
/// against a live API call; a typo in one of these property names is a
/// compile error caught before the code ships.
struct MessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let tools: [ToolSpec]
    let toolChoice: ToolChoice
    let messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case tools
        case toolChoice = "tool_choice"
        case messages
    }
}

struct ToolSpec: Encodable {
    let name: String
    let description: String
    let inputSchema: RecordAssignmentsSchema

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }
}

struct ToolChoice: Encodable {
    let type = "tool"
    let name: String
}

struct ChatMessage: Encodable {
    let role: String
    let content: String
}

/// Mirrors the JSON Schema Anthropic's tool-use API expects for
/// `record_assignments`. Hand-written as nested `Encodable` structs (not a
/// generic JSON-value type) because this shape is small, fixed, and used at
/// exactly one call site — a general-purpose JSON encoder would be more code
/// to introduce and maintain than the schema it would replace.
struct RecordAssignmentsSchema: Encodable {
    let type = "object"
    let properties = Properties()
    let required = ["assignments"]

    struct Properties: Encodable {
        let assignments = AssignmentsArraySchema()
    }
}

struct AssignmentsArraySchema: Encodable {
    let type = "array"
    let items = AssignmentItemSchema()
}

struct AssignmentItemSchema: Encodable {
    let type = "object"
    let properties = ItemProperties()
    let required = ["title", "due_iso8601"]

    struct ItemProperties: Encodable {
        let title = TitleFieldSchema()
        let dueISO8601 = DueFieldSchema()

        enum CodingKeys: String, CodingKey {
            case title
            case dueISO8601 = "due_iso8601"
        }
    }
}

struct TitleFieldSchema: Encodable {
    let type = "string"
    let description = "Short imperative task title, <=80 chars"
}

/// The one field in this schema that isn't a plain scalar type: JSON Schema
/// expresses "string, or null" as `"type": ["string", "null"]` — a JSON
/// array, not a single string — which is why `type` here is `[String]`
/// rather than matching every other schema struct's `String`.
struct DueFieldSchema: Encodable {
    let type = ["string", "null"]
    let description = "Due datetime in ISO8601 with timezone, or null if the announcement gives none"
}

// MARK: - Response Decodable shapes

struct MessagesResponse: Decodable {
    let content: [ContentBlock]
}

/// Anthropic's `content` array mixes block types (`text`, `tool_use`, and
/// others depending on what the model does); `input` is only present on
/// `tool_use` blocks, hence optional here rather than a `type`-keyed set of
/// separate structs — this file only ever needs the one block type.
struct ContentBlock: Decodable {
    let type: String
    let input: ToolUseInput?
}

struct ToolUseInput: Decodable {
    let assignments: [RawExtractedAssignment]
}

struct RawExtractedAssignment: Decodable {
    let title: String
    let dueISO8601: String?

    enum CodingKeys: String, CodingKey {
        case title
        case dueISO8601 = "due_iso8601"
    }
}
