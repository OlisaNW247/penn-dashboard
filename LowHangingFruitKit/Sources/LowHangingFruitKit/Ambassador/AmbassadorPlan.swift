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
        /// Students who have set Smooth up at the ambassador's school, and
        /// how many of them in the last `days`. Absent from an older server.
        public var schoolInstalls: Int?
        public var schoolInstallsRecent: Int?

        public init(linkOpens: Int = 0, linkOpensRecent: Int = 0, schoolScans: Int = 0,
                    schoolScansRecent: Int = 0, drops: Int = 0, posts: Int = 0, days: Int = 14,
                    schoolInstalls: Int? = nil, schoolInstallsRecent: Int? = nil) {
            self.linkOpens = linkOpens
            self.linkOpensRecent = linkOpensRecent
            self.schoolScans = schoolScans
            self.schoolScansRecent = schoolScansRecent
            self.drops = drops
            self.posts = posts
            self.days = days
            self.schoolInstalls = schoolInstalls
            self.schoolInstallsRecent = schoolInstallsRecent
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
        /// The follow-up the ambassador posts under their own post, where the
        /// pitch lives so the post itself can read like any other. Optional
        /// because an older server sends none, and then nothing new shows.
        public var reply: String?

        public init(dayIndex: Int, kind: String, channel: String?, platform: String, text: String,
                    reply: String? = nil) {
            self.dayIndex = dayIndex
            self.kind = kind
            self.channel = channel
            self.platform = platform
            self.text = text
            self.reply = reply
        }

        /// A rest day carries words but nothing to post.
        public var isRest: Bool { kind == "rest" || channel == nil }
    }

    public struct Message: Codable, Equatable, Sendable, Identifiable {
        public var key: String
        public var label: String
        public var channel: String
        public var text: String
        /// The follow-up reply to post under this message; absent from an
        /// older server, in which case the row shows only the message.
        public var reply: String?
        public var id: String { key }

        public init(key: String, label: String, channel: String, text: String, reply: String? = nil) {
            self.key = key
            self.label = label
            self.channel = channel
            self.text = text
            self.reply = reply
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

    /// What the founders have learned works on the anonymous apps: one line
    /// of lead, a few steps and worked examples. Written by the server and
    /// never by the app, so every field degrades: a missing `steps` is empty
    /// and a malformed example is dropped, not the whole playbook.
    public struct Playbook: Codable, Equatable, Sendable {
        public struct Example: Codable, Equatable, Sendable, Identifiable {
            public var key: String
            public var title: String
            public var post: String
            public var reply: String?
            public var score: String?
            public var why: String?
            public var id: String { key }

            public init(key: String, title: String, post: String, reply: String? = nil,
                        score: String? = nil, why: String? = nil) {
                self.key = key
                self.title = title
                self.post = post
                self.reply = reply
                self.score = score
                self.why = why
            }
        }

        public var lead: String
        public var steps: [String]
        public var examples: [Example]

        public init(lead: String, steps: [String] = [], examples: [Example] = []) {
            self.lead = lead
            self.steps = steps
            self.examples = examples
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lead = (try? c.decodeIfPresent(String.self, forKey: .lead)) ?? ""
            steps = (try? c.decodeIfPresent([String].self, forKey: .steps)) ?? []
            if let boxes = try? c.decodeIfPresent([LossyElement<Example>].self, forKey: .examples) {
                examples = boxes.compactMap(\.value)
            } else {
                examples = []
            }
        }
    }

    /// How to post on the anonymous apps, taught in the anonymous-chats sheet
    /// (2026-11-22). Every field degrades: a malformed kind or example is
    /// dropped, never the plan. `AmbassadorGuidance.bundled` is the copy used
    /// when the server sends none.
    public struct Guidance: Codable, Equatable, Sendable {
        public struct Example: Codable, Equatable, Sendable {
            public var text: String
            public var reply: String?

            public init(text: String, reply: String? = nil) {
                self.text = text
                self.reply = reply
            }
        }

        /// One way to post: a label, one example the ambassador rewrites in
        /// their own words, and at most one line of how. A kind with no label
        /// or no example is dropped by the lossy list decode, not the plan.
        public struct Kind: Codable, Equatable, Sendable, Identifiable {
            public var key: String
            public var label: String
            public var example: Example
            public var how: String?
            public var id: String { key }

            public init(key: String, label: String, example: Example, how: String? = nil) {
                self.key = key
                self.label = label
                self.example = example
                self.how = how
            }

            private enum CodingKeys: String, CodingKey { case key, label, example, how }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                key = try c.decode(String.self, forKey: .key)
                label = try c.decode(String.self, forKey: .label)
                example = try c.decode(Example.self, forKey: .example)
                how = (try? c.decodeIfPresent(String.self, forKey: .how)) ?? nil
            }
        }

        /// One closing line under both kinds.
        public var footer: String?
        public var kinds: [Kind]

        public init(footer: String? = nil, kinds: [Kind] = []) {
            self.footer = footer
            self.kinds = kinds
        }

        private enum CodingKeys: String, CodingKey { case footer, kinds }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            footer = (try? c.decodeIfPresent(String.self, forKey: .footer)) ?? nil
            if let boxes = try? c.decodeIfPresent([LossyElement<Kind>].self, forKey: .kinds) {
                kinds = boxes.compactMap(\.value)
            } else {
                kinds = []
            }
        }
    }

    /// A post the founders wrote for this ambassador to copy.
    public struct Suggestion: Codable, Equatable, Sendable, Identifiable {
        public var id: Int
        public var text: String
        public var reply: String?
        public var ts: String?

        public init(id: Int, text: String, reply: String? = nil, ts: String? = nil) {
            self.id = id
            self.text = text
            self.reply = reply
            self.ts = ts
        }
    }

    /// What the server will take as a screen recording's stills or a post's
    /// result, and how much of each limit this ambassador has used.
    public struct Captures: Codable, Equatable, Sendable {
        public struct Feed: Codable, Equatable, Sendable {
            public var framesPerRecording: Int?
            public var frameBytes: Int?
            public var sentToday: Int?
            public var dailyLimit: Int?
            public var stored: Int?
            public var limit: Int?

            public init(framesPerRecording: Int? = nil, frameBytes: Int? = nil, sentToday: Int? = nil,
                        dailyLimit: Int? = nil, stored: Int? = nil, limit: Int? = nil) {
                self.framesPerRecording = framesPerRecording
                self.frameBytes = frameBytes
                self.sentToday = sentToday
                self.dailyLimit = dailyLimit
                self.stored = stored
                self.limit = limit
            }
        }

        public struct Results: Codable, Equatable, Sendable {
            public var imageBytes: Int?
            public var sentToday: Int?
            public var dailyLimit: Int?
            public var stored: Int?
            public var limit: Int?

            public init(imageBytes: Int? = nil, sentToday: Int? = nil, dailyLimit: Int? = nil,
                        stored: Int? = nil, limit: Int? = nil) {
                self.imageBytes = imageBytes
                self.sentToday = sentToday
                self.dailyLimit = dailyLimit
                self.stored = stored
                self.limit = limit
            }
        }

        public struct Style: Codable, Equatable, Sendable, Identifiable {
            public var key: String
            public var label: String
            public var id: String { key }

            public init(key: String, label: String) {
                self.key = key
                self.label = label
            }
        }

        public var feed: Feed?
        public var results: Results?
        public var styles: [Style]?

        public init(feed: Feed? = nil, results: Results? = nil, styles: [Style]? = nil) {
            self.feed = feed
            self.results = results
            self.styles = styles
        }

        /// Each part is read with `try?`, so a wrongly shaped `feed` costs the
        /// feed row its count and nothing else.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            feed = (try? c.decodeIfPresent(Feed.self, forKey: .feed)) ?? nil
            results = (try? c.decodeIfPresent(Results.self, forKey: .results)) ?? nil
            if let boxes = try? c.decodeIfPresent([LossyElement<Style>].self, forKey: .styles) {
                styles = boxes.compactMap(\.value)
            } else {
                styles = nil
            }
        }
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
    /// Arrived with the tracking work (2026-11-18); an older server omits all
    /// three and the page shows none of the parts they feed.
    public var playbook: Playbook?
    public var suggested: [Suggestion]?
    public var captures: Captures?
    /// The ambassador's own tracked share link per channel (`gc` is the group
    /// chats'), added 2026-11-21 for the group-chat task. Decoded with `try?`
    /// so a wrongly shaped one reads as absent and the plan still decodes.
    public var links: [String: String]?
    /// How to post (2026-11-22); nil from an older server.
    public var guidance: Guidance?

    public init(name: String, school: String, schoolName: String? = nil, title: String? = nil,
                status: String? = nil, pausedUntil: String? = nil, page: String? = nil,
                appStore: String? = nil, numbers: Numbers? = nil, today: Today? = nil,
                messages: [Message]? = nil, checklist: [ChecklistStep]? = nil,
                tips: [String]? = nil, generatedAt: String? = nil,
                posters: [Poster]? = nil, dashboard: String? = nil, ideas: Ideas? = nil,
                playbook: Playbook? = nil, suggested: [Suggestion]? = nil, captures: Captures? = nil,
                links: [String: String]? = nil, guidance: Guidance? = nil) {
        self.guidance = guidance
        self.links = links
        self.playbook = playbook
        self.suggested = suggested
        self.captures = captures
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
        playbook = (try? c.decodeIfPresent(Playbook.self, forKey: .playbook)) ?? nil
        if let boxes = try? c.decodeIfPresent([LossyElement<Suggestion>].self, forKey: .suggested) {
            suggested = boxes.compactMap(\.value)
        } else {
            suggested = nil
        }
        captures = (try? c.decodeIfPresent(Captures.self, forKey: .captures)) ?? nil
        links = (try? c.decodeIfPresent([String: String].self, forKey: .links)) ?? nil
        guidance = (try? c.decodeIfPresent(Guidance.self, forKey: .guidance)) ?? nil
    }

    /// An element that decodes to nil instead of throwing.
    fileprivate struct LossyElement<T: Decodable>: Decodable {
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
