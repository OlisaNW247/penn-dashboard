import Foundation

/// What the ambassador server tells the app about one ambassador
/// (`GET /a/{code}/plan.json`): who they are, their own numbers, the post
/// written for today with their own tracked link in it, the onboarding
/// checklist and the message bank. Only their own rows, never another
/// person's, and never a founder's contact: the server builds this from the
/// code alone.
///
/// Decoded leniently. Every field the page can live without is optional, so
/// an older app keeps working when the server grows a field, and a newer app
/// shows what it has when the server is older. The one hard requirement is
/// `name` and `school`, which is how the app knows the code was real.
public struct AmbassadorPlan: Codable, Equatable, Sendable {
    public struct Numbers: Codable, Equatable, Sendable {
        public var linkOpens: Int
        public var linkOpensRecent: Int
        public var schoolScans: Int
        public var schoolScansRecent: Int
        public var drops: Int
        public var posts: Int
        /// The window "recent" counts over, in days.
        public var days: Int

        public init(linkOpens: Int = 0, linkOpensRecent: Int = 0, schoolScans: Int = 0,
                    schoolScansRecent: Int = 0, drops: Int = 0, posts: Int = 0, days: Int = 14) {
            self.linkOpens = linkOpens
            self.linkOpensRecent = linkOpensRecent
            self.schoolScans = schoolScans
            self.schoolScansRecent = schoolScansRecent
            self.drops = drops
            self.posts = posts
            self.days = days
        }
    }

    /// The post written for today. `kind` is the template's kind (`anon`,
    /// `gc`, `ig`, `dm`, `rest`); `channel` is the tracked-link channel it
    /// was filled for (`fizz`, `sidechat`, `yikyak`, `gc`, …), nil on a rest
    /// day; `platform` is the human word for it.
    public struct Today: Codable, Equatable, Sendable {
        public var dayIndex: Int
        public var kind: String
        public var channel: String?
        public var platform: String
        public var text: String

        public init(dayIndex: Int, kind: String, channel: String?, platform: String, text: String) {
            self.dayIndex = dayIndex
            self.kind = kind
            self.channel = channel
            self.platform = platform
            self.text = text
        }

        /// A rest day carries words but nothing to post.
        public var isRest: Bool { kind == "rest" || channel == nil }
    }

    public struct Message: Codable, Equatable, Sendable, Identifiable {
        public var key: String
        public var label: String
        public var channel: String
        public var text: String
        public var id: String { key }

        public init(key: String, label: String, channel: String, text: String) {
            self.key = key
            self.label = label
            self.channel = channel
            self.text = text
        }
    }

    public struct ChecklistStep: Codable, Equatable, Sendable, Identifiable {
        public var key: String
        public var label: String
        public var hint: String?
        public var done: Bool
        public var id: String { key }

        public init(key: String, label: String, hint: String? = nil, done: Bool) {
            self.key = key
            self.label = label
            self.hint = hint
            self.done = done
        }
    }

    /// One of the ambassador's school's poster designs, in the server's
    /// display order. `image` is an https URL to a picture the student can
    /// share or print; `scans` is how many times that design's QR code has
    /// been scanned, when the server says.
    public struct Poster: Codable, Equatable, Sendable, Identifiable {
        public var key: String
        public var name: String
        public var image: String
        public var scans: Int?
        public var id: String { key }

        public init(key: String, name: String, image: String, scans: Int? = nil) {
            self.key = key
            self.name = name
            self.image = image
            self.scans = scans
        }

        /// https only: a plain-http or custom-scheme URL from a server is
        /// never loaded or handed to the share sheet.
        public var imageURL: URL? { AmbassadorPlan.httpsURL(image) }
    }

    /// How many poster ideas this ambassador has sent, against the server's
    /// two limits (a daily one and a total one), when it reports them.
    public struct Ideas: Codable, Equatable, Sendable {
        public var sent: Int
        public var limit: Int?
        public var dailyLimit: Int?

        public init(sent: Int, limit: Int? = nil, dailyLimit: Int? = nil) {
            self.sent = sent
            self.limit = limit
            self.dailyLimit = dailyLimit
        }
    }

    public var name: String
    public var school: String
    public var schoolName: String?
    public var title: String?
    public var status: String?
    public var pausedUntil: String?
    public var page: String?
    public var appStore: String?
    public var numbers: Numbers?
    public var today: Today?
    public var messages: [Message]?
    public var checklist: [ChecklistStep]?
    public var tips: [String]?
    public var generatedAt: String?
    /// The three fields below arrived with the poster gallery; an older server
    /// omits them and the page hides what it cannot show.
    public var posters: [Poster]?
    public var dashboard: String?
    public var ideas: Ideas?

    public init(name: String, school: String, schoolName: String? = nil, title: String? = nil,
                status: String? = nil, pausedUntil: String? = nil, page: String? = nil,
                appStore: String? = nil, numbers: Numbers? = nil, today: Today? = nil,
                messages: [Message]? = nil, checklist: [ChecklistStep]? = nil,
                tips: [String]? = nil, generatedAt: String? = nil,
                posters: [Poster]? = nil, dashboard: String? = nil, ideas: Ideas? = nil) {
        self.posters = posters
        self.dashboard = dashboard
        self.ideas = ideas
        self.name = name
        self.school = school
        self.schoolName = schoolName
        self.title = title
        self.status = status
        self.pausedUntil = pausedUntil
        self.page = page
        self.appStore = appStore
        self.numbers = numbers
        self.today = today
        self.messages = messages
        self.checklist = checklist
        self.tips = tips
        self.generatedAt = generatedAt
    }

    /// Decoded by hand only so that one malformed poster entry (a missing
    /// image, a number where a name should be) drops that poster and not the
    /// whole plan: the plan is the page's one source, and a gallery typo on
    /// the server must not sign anyone out of today's post. Every other field
    /// decodes exactly as the synthesized version did (`encode(to:)` is still
    /// synthesized from the same keys). The new `ideas` and `dashboard` fields
    /// are read with `try?`, so a wrongly shaped one reads as absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        school = try c.decode(String.self, forKey: .school)
        schoolName = try c.decodeIfPresent(String.self, forKey: .schoolName)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        pausedUntil = try c.decodeIfPresent(String.self, forKey: .pausedUntil)
        page = try c.decodeIfPresent(String.self, forKey: .page)
        appStore = try c.decodeIfPresent(String.self, forKey: .appStore)
        numbers = try c.decodeIfPresent(Numbers.self, forKey: .numbers)
        today = try c.decodeIfPresent(Today.self, forKey: .today)
        messages = try c.decodeIfPresent([Message].self, forKey: .messages)
        checklist = try c.decodeIfPresent([ChecklistStep].self, forKey: .checklist)
        tips = try c.decodeIfPresent([String].self, forKey: .tips)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
        if let boxes = try? c.decodeIfPresent([LossyElement<Poster>].self, forKey: .posters) {
            posters = boxes.compactMap(\.value)
        } else {
            posters = nil
        }
        dashboard = (try? c.decodeIfPresent(String.self, forKey: .dashboard)) ?? nil
        ideas = (try? c.decodeIfPresent(Ideas.self, forKey: .ideas)) ?? nil
    }

    /// An element that decodes to nil instead of throwing.
    private struct LossyElement<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    fileprivate static func httpsURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The public live scan dashboard for this school, https only.
    public var dashboardURL: URL? {
        dashboard.flatMap(AmbassadorPlan.httpsURL)
    }

    /// The first name, for "hey maya".
    public var firstName: String {
        name.split(whereSeparator: { $0 == " " }).first.map(String.init) ?? name
    }

    /// The school's display name, lowercased the way every Smooth label is.
    public var schoolLabel: String {
        (schoolName ?? school).lowercased()
    }

    /// Whether reminders are paused on the server (the page's pause buttons,
    /// or the app's). `pausedUntil` is an ISO instant; a date that will not
    /// parse reads as not paused rather than as paused forever.
    public func isPaused(at now: Date = Date()) -> Bool {
        guard let pausedUntil else { return false }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let until = parser.date(from: pausedUntil) ?? plain.date(from: pausedUntil)
        guard let until else { return false }
        return until > now
    }

    public static func decode(_ data: Data) throws -> AmbassadorPlan {
        try JSONDecoder().decode(AmbassadorPlan.self, from: data)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

/// The anonymous campus apps an ambassador can pick as theirs. The daily
/// post's "anon" days are filled for this one; a school usually has one that
/// is actually used, and posting to the others is noise.
public enum AmbassadorAnonApp: String, CaseIterable, Codable, Sendable, Identifiable {
    case fizz
    case sidechat
    case yikyak

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fizz: return "fizz"
        case .sidechat: return "sidechat"
        case .yikyak: return "yik yak"
        }
    }
}
