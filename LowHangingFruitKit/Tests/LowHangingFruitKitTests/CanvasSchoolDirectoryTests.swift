import Foundation
import JavaScriptCore
import Testing
@testable import LowHangingFruitKit

@Suite("Canvas school search and sign-in evidence")
struct CanvasSchoolDirectoryTests {
    @Test("Relevant university wins for names, aliases and misspellings", arguments: [
        "Berkeley", "berkely", "UC Berkeley", "universty of california berkely"
    ])
    func berkeleyRanksFirst(_ query: String) {
        #expect(CanvasSchoolDirectory.bundledMatches(for: query).first?.host == "bcourses.berkeley.edu")
    }

    @Test("Specialized directory sites cannot enter university results")
    func excludesPrograms() throws {
        let remote = try CanvasSchoolDirectory.decode(Data("""
        [
          {"name":"UPENN Canvas Online Learning", "domain":"upenn-online.instructure.com"},
          {"name":"Berkeley Extension", "domain":"extension.instructure.com"}
        ]
        """.utf8))
        let penn = CanvasSchoolDirectory.merging(remote, query: "UPenn")
        #expect(penn.map(\.id) == ["upenn"])
        #expect(CanvasSchoolDirectory.merging(remote, query: "berkely").first?.host == "bcourses.berkeley.edu")
        #expect(!CanvasSchoolDirectory.merging(remote, query: "Berkeley").contains { $0.host == "extension.instructure.com" })
        #expect(CanvasSchoolDirectory.bundledMatches(for: "zzzzzz").isEmpty)
        #expect(CanvasSchoolDirectory.bundledMatches(for: "MIT").count == 1)
        #expect(CanvasSchoolDirectory.bundledMatches(for: "Michigan").first?.id == "umich")
    }

    @Test("Bundled US catalog covers at least 200 distinct safe Canvas sites")
    func nationalCatalog() {
        let schools = CanvasSchoolDirectory.bundledSchools
        #expect(schools.count >= 200)
        #expect(Set(schools.map(\.id)).count == schools.count)
        #expect(Set(schools.map(\.host)).count == schools.count)
        for school in schools {
            #expect(school.baseURL.scheme == "https")
            #expect(school.loginURL.scheme == "https")
            #expect(school.baseURL.user == nil && school.loginURL.user == nil)
            #expect(CanvasInstallation.custom(address: school.host) != nil)
        }
        var ownerByHost: [String: String] = [:]
        for entry in CanvasSchoolCatalog.entries {
            for host in entry.hostAliases {
                #expect(ownerByHost[host] == nil || ownerByHost[host] == entry.installation.id)
                ownerByHost[host] = entry.installation.id
            }
        }
    }

    @Test("Major universities and abbreviations are available without network", arguments: [
        "MIT", "Stanford", "UCLA", "UC Berkeley", "UCSD", "Caltech", "Duke",
        "Johns Hopkins", "Georgia Tech", "UIUC", "Ohio State", "Penn State",
        "UT Austin", "Texas A&M", "Rutgers", "UMass Amherst", "Howard", "NJIT",
        "Michigan", "University of Florida", "Wisconsin Madison", "Pitt"
    ])
    func majorSchoolsAreLocal(_ query: String) {
        #expect(!CanvasSchoolDirectory.bundledMatches(for: query).isEmpty)
    }

    @Test("Shared Canvas sites are searchable by campus without duplicate rows")
    func sharedCampuses() {
        let missouri = CanvasSchoolDirectory.bundledMatches(for: "Mizzou")
        let kansasCity = CanvasSchoolDirectory.bundledMatches(for: "UMKC")
        #expect(missouri.count == 1)
        #expect(missouri.first?.id == kansasCity.first?.id)
        #expect(CanvasSchoolDirectory.bundledMatches(for: "University of Wisconsin Milwaukee").count == 1)
        #expect(CanvasSchoolDirectory.bundledMatches(for: "Nebraska Omaha").count == 1)
    }

    @Test("Live aliases resolve to the bundled institution identity")
    func liveAliases() throws {
        let data = Data("""
        [
          {"name":"Columbia University", "domain":"courseworks2.columbia.edu"},
          {"name":"University of Michigan", "domain":"m.canvas.umich.edu"},
          {"name":"University of Missouri - Kansas City", "domain":"umsystem.instructure.com"}
        ]
        """.utf8)
        let remote = try CanvasSchoolDirectory.decode(data)
        #expect(remote.contains { $0.id == "columbia" })
        #expect(remote.contains { $0.id == "umich" })
        let merged = CanvasSchoolDirectory.merging(remote, query: "Mizzou")
        #expect(merged.filter { $0.host == "umsystem.instructure.com" }.count == 1)
    }

    @Test("Michigan is searchable offline by full name and common alias")
    func michigan() {
        for query in ["Michigan", "UMich", "u of m", "University of Michigan"] {
            #expect(CanvasSchoolDirectory.bundledMatches(for: query).contains {
                $0.id == "umich" && $0.host == "umich.instructure.com"
            })
        }
        #expect(CanvasSchoolDirectory.bundledMatches(for: "").isEmpty)
        #expect(CanvasSchoolDirectory.bundledMatches(for: "UPenn").first?.id == "upenn")
    }

    @Test("Directory preserves known origins and combines routes to the same Canvas site")
    func routes() throws {
        let data = Data("""
        [
          {"name":"Penn", "domain":"canvas.upenn.edu", "authentication_provider":"saml"},
          {"name":"Cornell", "domain":"canvas.cornell.edu"},
          {"name":"University of Michigan - Ann Arbor", "domain":"m.canvas.umich.edu", "authentication_provider":"3"},
          {"name":"Example University - Students", "domain":"example.instructure.com", "authentication_provider":"42"},
          {"name":"Example University - Guests", "domain":"example.instructure.com", "authentication_provider":"canvas"}
        ]
        """.utf8)
        let schools = try CanvasSchoolDirectory.decode(data)
        #expect(schools.count == 4)
        #expect(schools.contains(.penn))
        #expect(schools.first { $0.id == "cornell" }?.loginURL.host == "login.canvas.cornell.edu")
        #expect(schools.first { $0.id == "umich" }?.host == "umich.instructure.com")
        #expect(schools.first { $0.id == "umich" }?.loginURL.host == "canvas.umich.edu")
        let example = try #require(schools.first { $0.host == "example.instructure.com" })
        #expect(example.loginURL == example.baseURL)
        #expect(example.name == "Example University")
        #expect(!example.isVerified)
        #expect(Set(schools.map(\.id)).count == 4)
    }

    @Test("Aliases collapse but separate Canvas sites keep their own routes")
    func distinctSites() throws {
        let data = Data("""
        [
          {"name":"Example University", "domain":"example.instructure.com", "authentication_provider":"42"},
          {"name":"Example University Alias", "domain":"example.instructure.com", "authentication_provider":"42"},
          {"name":"Example University - Other Campus", "domain":"other.instructure.com", "authentication_provider":"saml"}
        ]
        """.utf8)
        let schools = try CanvasSchoolDirectory.decode(data)
        #expect(schools.count == 2)
        #expect(schools.first { $0.host == "example.instructure.com" }?.loginURL.path == "/login/42")
        #expect(schools.first { $0.host == "other.instructure.com" }?.loginURL.path == "/login/saml")
    }

    @Test("Malformed directory destinations are excluded, duplicates collapse")
    func unsafeRows() throws {
        let data = Data("""
        [
          {"name":"Bad", "domain":"http://example.edu"},
          {"name":"Bad", "domain":"example.edu/login"},
          {"name":"Bad", "domain":"user@example.edu"},
          {"name":"Bad", "domain":"127.0.0.1"},
          {"name":"Bad", "domain":"example.edu", "authentication_provider":"../other"},
          {"name":null, "domain":"example.edu"},
          {"name":"", "domain":"example.edu"},
          {"name":"Valid College", "domain":"college.instructure.com"},
          {"name":"Valid College", "domain":"college.instructure.com", "authentication_provider":null}
        ]
        """.utf8)
        let schools = try CanvasSchoolDirectory.decode(data)
        #expect(schools.count == 1)
        #expect(schools.first?.name == "Valid College")
    }

    @Test("Bundled and remote identity merge doesn't duplicate Penn")
    func merge() {
        let schools = CanvasSchoolDirectory.merging([.penn], query: "Penn")
        #expect(schools.filter { $0.id == "upenn" }.count == 1)
    }

    @Test("Search is encoded and does not attach login cookies")
    func request() throws {
        let request = CanvasSchoolDirectory.request(for: "  A & M + College  ")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "sso.canvaslms.com")
        #expect(components.queryItems?.first { $0.name == "search_term" }?.value == "A & M + College")
        #expect(components.queryItems?.first { $0.name == "per_page" }?.value == "100")
        #expect(!request.httpShouldHandleCookies)
        #expect(request.timeoutInterval == 12)
    }

    @Test("Authentication inspection rejects login pages and lookalike hosts")
    func inspectionBoundary() {
        for address in ["https://canvas.example.edu/login/saml", "https://canvas.example.edu/logout",
                        "https://canvas.example.edu.evil.test/", "https://sso.example.edu/",
                        "http://canvas.example.edu/"] {
            #expect(!CanvasLoginEvidence.canInspect(url: URL(string: address), expectedHost: "canvas.example.edu"))
        }
        #expect(CanvasLoginEvidence.canInspect(url: URL(string: "https://canvas.example.edu/courses/1"), expectedHost: "canvas.example.edu"))
    }

    @Test("Real authentication script rejects anonymous pages and accepts signed-in Canvas")
    func authenticationScript() throws {
        let context = try #require(JSContext())
        context.evaluateScript("var window = {};")
        #expect(context.evaluateScript(CanvasLoginEvidence.script)?.toBool() == false)
        for value in ["null", "0", "false", "true", "''", "'guest'", "-1", "1.5"] {
            context.evaluateScript("window.ENV = {current_user_id: \(value)};")
            #expect(context.evaluateScript(CanvasLoginEvidence.script)?.toBool() == false)
        }
        for value in ["123", "'123'"] {
            context.evaluateScript("window.ENV = {current_user_id: \(value)};")
            #expect(context.evaluateScript(CanvasLoginEvidence.script)?.toBool() == true)
        }
        #expect(context.exception == nil)
    }
}
