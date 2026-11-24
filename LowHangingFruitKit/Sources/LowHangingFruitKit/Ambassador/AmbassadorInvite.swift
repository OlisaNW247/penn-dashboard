import Foundation

/// What the ambassador server answers when an allowed ambassador adds a new
/// one (`POST /a/{code}/invite`, 200). Only `code` is required; every other
/// field is read with `try?`, so a server that grows or drops a field never
/// costs the new person's code, which is the one thing that cannot be asked
/// for again.
public struct AmbassadorInviteResult: Decodable, Equatable, Sendable {
    public var code: String
    public var page: String?
    public var welcome: String?
    public var schoolID: String?
    public var schoolName: String?
    public var isNewSchool: Bool

    public init(code: String, page: String? = nil, welcome: String? = nil,
                schoolID: String? = nil, schoolName: String? = nil, isNewSchool: Bool = false) {
        self.code = code
        self.page = page
        self.welcome = welcome
        self.schoolID = schoolID
        self.schoolName = schoolName
        self.isNewSchool = isNewSchool
    }

    private enum CodingKeys: String, CodingKey { case code, page, welcome, school }
    private enum SchoolKeys: String, CodingKey { case id, name, isNew }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        page = (try? c.decodeIfPresent(String.self, forKey: .page)) ?? nil
        welcome = (try? c.decodeIfPresent(String.self, forKey: .welcome)) ?? nil
        var id: String?
        var name: String?
        var isNew = false
        if let s = try? c.nestedContainer(keyedBy: SchoolKeys.self, forKey: .school) {
            id = (try? s.decodeIfPresent(String.self, forKey: .id)) ?? nil
            name = (try? s.decodeIfPresent(String.self, forKey: .name)) ?? nil
            isNew = ((try? s.decodeIfPresent(Bool.self, forKey: .isNew)) ?? nil) ?? false
        }
        schoolID = id
        schoolName = name
        isNewSchool = isNew
    }
}

/// The invite request's body, built purely so it can be tested.
public enum AmbassadorInvite {
    /// Trims everything. Nil when the name is empty, or when there is not
    /// exactly one usable school (an existing id, or a new school's name of
    /// 2 to 60 characters). Never sends both `school` and `schoolName`; an
    /// existing id wins if both were given. Empty optionals are left out.
    public static func body(name: String, schoolID: String?, schoolName: String?,
                            schoolHost: String?, contact: String?) -> [String: String]? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        var body: [String: String] = ["name": trimmedName]
        let id = (schoolID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = (schoolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty {
            body["school"] = id
        } else if (2...60).contains(newName.count) {
            body["schoolName"] = newName
        } else {
            return nil
        }
        let host = (schoolHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !host.isEmpty { body["schoolHost"] = host }
        let phone = (contact ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !phone.isEmpty { body["contact"] = phone }
        return body
    }
}
