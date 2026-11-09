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

    public init(name: String, school: String, schoolName: String? = nil, title: String? = nil,
                status: String? = nil, pausedUntil: String? = nil, page: String? = nil,
                appStore: String? = nil, numbers: Numbers? = nil, today: Today? = nil,
                messages: [Message]? = nil, checklist: [ChecklistStep]? = nil,
                tips: [String]? = nil, generatedAt: String? = nil) {
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
