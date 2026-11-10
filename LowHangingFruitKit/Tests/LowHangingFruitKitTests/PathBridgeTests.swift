import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Path@Penn bridge")
struct PathBridgeTests {
    private static let garbage: [String] = ["not json", "{}", "[]", ""]

    @Test("readiness decodes the three fields and refuses garbage")
    func readiness() {
        let good = PathBridgeDecoder.readiness("{\"page\":true,\"token\":false,\"title\":\"Demo\"}")
        #expect(good == PathBridgeDecoder.Readiness(page: true, token: false, title: "Demo"))
        for text in Self.garbage {
            #expect(PathBridgeDecoder.readiness(text) == nil)
        }
    }

    @Test("opened is true only when the script says so")
    func opened() {
        #expect(PathBridgeDecoder.opened("{\"opened\":true}"))
        #expect(!PathBridgeDecoder.opened("{\"opened\":false}"))
        for text in Self.garbage {
            #expect(!PathBridgeDecoder.opened(text))
        }
    }

    @Test("error returns the message only when present and non-empty")
    func error() {
        #expect(PathBridgeDecoder.error("{\"error\":\"page not ready\"}") == "page not ready")
        #expect(PathBridgeDecoder.error("{\"error\":\"\"}") == nil)
        for text in Self.garbage {
            #expect(PathBridgeDecoder.error(text) == nil)
        }
    }

    @Test("degrees keeps string entries and drops one with no degree code")
    func degrees() {
        let json = "{\"term\":\"202610\",\"degrees\":[{\"degc\":\"BSX\",\"levl\":\"UG\",\"coll\":\"EC\",\"major\":\"AAAA,BBBB\",\"conc\":\"NCON\",\"program\":\"XX_BA\"},{\"degc\":\"\",\"levl\":\"UG\"},{\"levl\":\"UG\"}]}"
        let result = PathBridgeDecoder.degrees(json)
        #expect(result.count == 1)
        #expect(result[0].majors == ["AAAA", "BBBB"])
        #expect(result[0].concentrations.isEmpty)
        #expect(result[0].raw["program"] == "XX_BA")
        for text in Self.garbage {
            #expect(PathBridgeDecoder.degrees(text).isEmpty)
        }
    }

    @Test("auditData needs a non-empty blocks array")
    func auditDataGate() {
        #expect(PathBridgeDecoder.auditData("{\"blocks\":[]}") == nil)
        #expect(PathBridgeDecoder.auditData("{\"error\":\"x\"}") == nil)
        for text in Self.garbage {
            #expect(PathBridgeDecoder.auditData(text) == nil)
        }
    }

    @Test("auditData round-trips into the audit decoder")
    func auditRoundTrip() throws {
        let json = """
        {"blocks":[{"id":"AB123456","type":"DEGREE","title":"Demo degree","completionPercent":50,
        "courseReqCopy":{"members":[{"type":"course","courseCode":"EXMP 1000","title":"Demo course","hours":"1","completionIconName":"completed","completionPercent":100}]}}],
        "degreeInfo":{"level":"UG","degree":"BSX","program":"XX_BA","term":"202610","major":"AAAA","college":"EC","conc":"NCON"}}
        """
        let data = try #require(PathBridgeDecoder.auditData(json))
        let audit = try PathAuditDecoder.decode(data, fallbackGoals: nil, isWhatIf: false, now: Date(timeIntervalSince1970: 0))
        #expect(audit.blocks.count == 1)
        #expect(audit.courses.map(\.code) == ["EXMP 1000"])
        #expect(audit.goals.degree == "BSX")
    }

    @Test("programs are sorted by title ignoring case, empties dropped")
    func programs() {
        let json = "{\"programs\":[{\"code\":\"B-1\",\"title\":\"beta\"},{\"code\":\"\",\"title\":\"No code\"},{\"code\":\"A-1\",\"title\":\"Alpha\"},{\"code\":\"C-1\",\"title\":\"Charlie\"}]}"
        let result = PathBridgeDecoder.programs(json)
        #expect(result.map(\.code) == ["A-1", "B-1", "C-1"])
        for text in Self.garbage {
            #expect(PathBridgeDecoder.programs(text).isEmpty)
        }
    }

    @Test("programInfo splits the minor program list and needs a code")
    func programInfo() {
        let json = "{\"program\":{\"prog_code\":\"DEMO-1\",\"prog_name\":\"Demo\",\"prog_type\":\"major\",\"levl_code\":\"UG\",\"degc_code\":\"BSX\",\"majr_code\":\"AAAA\",\"minr_code\":\"\",\"conc_code\":\"\",\"coll_code\":\"EC\",\"sis_prog_code\":\"XX_BA\",\"minor_sis_prog_codes\":\"XX_BA, YY_BA,\"}}"
        let info = PathBridgeDecoder.programInfo(json)
        #expect(info?.code == "DEMO-1")
        #expect(info?.degree == "BSX")
        #expect(info?.sisProgram == "XX_BA")
        #expect(info?.minorSisPrograms == ["XX_BA", "YY_BA"])
        #expect(PathBridgeDecoder.programInfo("{\"program\":{\"prog_code\":\"\"}}") == nil)
        for text in Self.garbage {
            #expect(PathBridgeDecoder.programInfo(text) == nil)
        }
    }

    @Test("dictionaries keep string entries and flatten with majors winning")
    func dictionaries() {
        let json = "{\"majors\":{\"AAAA\":\"Demo Major\",\"SAME\":\"as major\"},\"degrees\":{\"BSX\":\"Bachelor X\",\"SAME\":\"as degree\"},\"levels\":{\"UG\":\"Undergraduate\"},\"colleges\":{\"EC\":\"Demo College\"},\"programs\":{\"XX_BA\":\"Demo Program\"}}"
        let result = PathBridgeDecoder.dictionaries(json)
        #expect(result?.degrees["BSX"] == "Bachelor X")
        let flat = result?.descriptions
        #expect(flat?["AAAA"] == "Demo Major")
        #expect(flat?["EC"] == "Demo College")
        #expect(flat?["SAME"] == "as major")
        #expect(PathBridgeDecoder.dictionaries("not json") == nil)
        #expect(PathBridgeDecoder.dictionaries("[]") == nil)
        #expect(PathBridgeDecoder.dictionaries("{\"error\":\"x\"}") == nil)
    }

    @Test("no script names a field the privacy rules forbid")
    func scriptsStayInsideTheAllowlist() {
        let forbidden: [String] = [
            "blockhtml", "legendHtml", "actionsMap", "explanations", "decisions", "audit_xml",
            "idProof", "pers.fn", "pers.id", "sam.auth.token ||", "hist", "cookie",
        ]
        for script in PathScripts.all {
            for word in forbidden {
                #expect(!script.contains(word), "a script contains \(word)")
            }
        }
        #expect(PathScripts.all.count == 7)
    }

    @Test("each script calls the page function it exists for")
    func scriptsCallThePage() {
        #expect(PathScripts.audit.contains("fetchStudentAudit"))
        #expect(PathScripts.degrees.contains("sam.user.fetch"))
        // `cur` is a history: an entry that is over carries an end term, and
        // the script must look at it (2026-11-10, the stale-chips build).
        #expect(PathScripts.degrees.contains("end_term"))
        #expect(PathScripts.degrees.contains("end <= bestTerm"))
        #expect(PathScripts.programs.contains("programs-v2-list"))
        #expect(PathScripts.programInfo.contains("programs-v2-info"))
        #expect(PathScripts.openSignIn.contains("sam.config.authURL"))
        #expect(PathScripts.dictionaries.contains("dictionaries()"))
    }

    @Test("readiness reports the token only as a boolean and has no not-ready guard")
    func readinessScript() {
        #expect(PathScripts.readiness.contains("!!(sam.auth && sam.auth.token)"))
        #expect(!PathScripts.readiness.contains("page not ready"))
        for script in [PathScripts.openSignIn, PathScripts.degrees, PathScripts.audit,
                       PathScripts.programs, PathScripts.programInfo, PathScripts.dictionaries] {
            #expect(script.contains("page not ready"))
        }
    }

    @Test("the audit script drops grade and GPA sentences in the page, by whole word")
    func auditScriptGuardsGradeText() {
        let script = PathScripts.audit
        for word in ["\"gpa\"", "\"grade\"", "\"grades\"", "\"graded\""] {
            #expect(script.contains(word), "the grade guard lacks \(word)")
        }
        // Words split on non-letters with a regex literal that has no
        // backslash, so "undergraduate" is never grade-related.
        #expect(script.contains("split(/[^a-z]+/)"))
        #expect(!script.contains("indexOf(\"grad"))
        // A comment is dropped whole, a label blanked, details and infoText omitted.
        #expect(script.contains("kept.type === \"comment\""))
        #expect(script.contains("kept.label = \"\""))
        #expect(script.contains("delete kept.details"))
        #expect(script.contains("delete kept.infoText"))
    }

    @Test("Cloudflare's interstitial titles are recognised")
    func challenge() {
        #expect(PathPage.looksLikeChallenge(title: "Just a moment..."))
        #expect(PathPage.looksLikeChallenge(title: "Attention Required! | Cloudflare"))
        #expect(!PathPage.looksLikeChallenge(title: "Path@Penn"))
        #expect(!PathPage.looksLikeChallenge(title: ""))
        #expect(PathPage.host == "courses.upenn.edu")
        #expect(PathPage.officialAuditURL == PathPage.homeURL)
    }
}
