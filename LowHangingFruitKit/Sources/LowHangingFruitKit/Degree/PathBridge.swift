import Foundation

// Degree progress, v12. Path@Penn's advising page runs the audit itself; this
// app loads that page in a hidden WebView, lets the page sign in, and calls the
// page's own functions through `callAsyncJavaScript`. What follows is the
// contract on both sides of that bridge: the page addresses, the script bodies
// (which are the privacy boundary) and the lenient decoder for what they
// return. See docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md, "The rewrite contract".

public enum PathPage {
    public static let host = "courses.upenn.edu"
    public static let homeURL = URL(string: "https://courses.upenn.edu/")!
    public static let authHost = "3scale-public-prod-path-authentication-anon.apps.k8s.upenn.edu"

    /// Where the student can see Penn's own audit. Path@Penn's advising page
    /// has no deep link, so this is the home page.
    public static let officialAuditURL = homeURL

    /// Cloudflare's interstitial titles. A hidden WebView that lands on one
    /// cannot proceed, and the caller should say so rather than wait.
    public static func looksLikeChallenge(title: String) -> Bool {
        let lowered = title.lowercased()
        return lowered.contains("just a moment") || lowered.contains("attention required")
    }
}

/// JavaScript BODIES for `WKWebView.callAsyncJavaScript(_:arguments:in:contentWorld:)`.
///
/// Each is the body of an async function: it may `await` and `return`, receives
/// its arguments as named variables, and returns a JSON string. These strings
/// are the privacy boundary of the feature. The student's record also holds an
/// id, an id proof, a first name, flags and per-term course lists, and the
/// audit response carries Penn's rendered HTML and a translator's debug trail;
/// none of that may reach Swift, so each script rebuilds its answer from an
/// allowlist instead of deleting what it dislikes. A denylist would pass
/// through whatever Penn adds next. The scripts avoid even naming the dropped
/// fields, which is what `PathBridgeTests` pins.
public enum PathScripts {
    /// Reports whether the page's three globals exist and whether sign-in has
    /// produced a token (a boolean only, never the token). Deliberately has no
    /// "page not ready" guard: it exists to say so.
    public static let readiness: String = """
    try {
      var pageReady = typeof sam !== "undefined" && typeof fose !== "undefined" && typeof foseDgwClient !== "undefined";
      var tokenReady = false;
      if (pageReady) { tokenReady = !!(sam.auth && sam.auth.token); }
      return JSON.stringify({ page: pageReady, token: tokenReady, title: String(document.title || "").slice(0, 80) });
    } catch (e) {
      return JSON.stringify({ page: false, token: false, title: "" });
    }
    """

    /// Opens the page's own sign-in popup, exactly as its Sign in button does,
    /// so the popup keeps its opener and can hand the token back.
    public static let openSignIn: String = """
    if (typeof sam === "undefined" || typeof fose === "undefined") { return JSON.stringify({ error: "page not ready" }); }
    try {
      var popup = window.open(sam.config.authURL, "sam-authenticate", sam.config.authWindowFeatures);
      return JSON.stringify({ opened: popup ? true : false });
    } catch (e) {
      return JSON.stringify({ error: String((e && e.message) || e).slice(0, 120) });
    }
    """

    /// The student's current curriculum entries, string fields only.
    public static let degrees: String = """
    if (typeof sam === "undefined" || typeof fose === "undefined") { return JSON.stringify({ error: "page not ready" }); }
    try {
      if (!sam.user.getProperty("pers")) { await sam.user.fetch(); }
      var rec = sam.user.getProperty("pers");
      if (!rec || !Array.isArray(rec.cur)) { return JSON.stringify({ error: "no record" }); }
      var bestTerm = "";
      var bestEntries = [];
      for (var i = 0; i < rec.cur.length; i++) {
        var holder = rec.cur[i];
        if (!holder || typeof holder !== "object") { continue; }
        for (var term in holder) {
          var entries = holder[term];
          if (Array.isArray(entries) && entries.length > 0 && String(term) > bestTerm) {
            bestTerm = String(term);
            bestEntries = entries;
          }
        }
      }
      var out = [];
      for (var j = 0; j < bestEntries.length; j++) {
        var entry = bestEntries[j];
        var strings = {};
        if (entry && typeof entry === "object") {
          for (var key in entry) {
            if (typeof entry[key] === "string") { strings[key] = entry[key]; }
          }
        }
        out.push(strings);
      }
      return JSON.stringify({ term: bestTerm, degrees: out });
    } catch (e) {
      return JSON.stringify({ error: String((e && e.message) || e).slice(0, 120) });
    }
    """

    /// Runs one audit for the given `degreeInfo` and returns it cut down to the
    /// fields `PathAuditDecoder` reads. Argument: `degreeInfo`, an object of strings.
    public static let audit: String = """
    if (typeof sam === "undefined" || typeof fose === "undefined") { return JSON.stringify({ error: "page not ready" }); }
    try {
      if (!sam.user.getProperty("pers")) { await sam.user.fetch(); }
      var sent = {};
      if (degreeInfo && typeof degreeInfo === "object") {
        for (var k in degreeInfo) {
          if (typeof degreeInfo[k] === "string") { sent[k] = degreeInfo[k]; }
        }
      }
      var result = await foseDgwClient.fetchStudentAudit({ method: "whatif", degree: sent, explain: false });
      if (!result || result.error) {
        return JSON.stringify({ error: String((result && result.error) || "no audit").slice(0, 120) });
      }
      var plainKeys = ["type", "id", "label", "completionPercent", "completionIconName", "courseCode", "title", "titleLong", "titleShort", "hours", "hoursCalculated", "membersNeeded", "coursesNeeded", "hoursNeeded", "details", "infoText", "seeBlockId"];
      var keepNode = function (node, depth) {
        var kept = {};
        for (var a = 0; a < plainKeys.length; a++) {
          var value = node[plainKeys[a]];
          if (typeof value === "string" || typeof value === "number") { kept[plainKeys[a]] = value; }
        }
        if (Array.isArray(node.members) && depth < 8) {
          var inner = [];
          for (var b = 0; b < node.members.length; b++) {
            var child = node.members[b];
            if (child && typeof child === "object") { inner.push(keepNode(child, depth + 1)); }
          }
          kept.members = inner;
        }
        return kept;
      };
      var blocks = [];
      var rawBlocks = Array.isArray(result.blocks) ? result.blocks : [];
      for (var c = 0; c < rawBlocks.length; c++) {
        var block = rawBlocks[c];
        if (!block || typeof block !== "object") { continue; }
        var keptBlock = {};
        var blockKeys = ["id", "type", "title", "completionPercent"];
        for (var d = 0; d < blockKeys.length; d++) {
          var bv = block[blockKeys[d]];
          if (typeof bv === "string" || typeof bv === "number") { keptBlock[blockKeys[d]] = bv; }
        }
        var members = [];
        var request = block.courseReqCopy;
        if (request && Array.isArray(request.members)) {
          for (var e2 = 0; e2 < request.members.length; e2++) {
            var m = request.members[e2];
            if (m && typeof m === "object") { members.push(keepNode(m, 1)); }
          }
        }
        keptBlock.courseReqCopy = { members: members };
        blocks.push(keptBlock);
      }
      var info = {};
      var infoSource = (result.degreeInfo && typeof result.degreeInfo === "object") ? result.degreeInfo : sent;
      for (var ik in infoSource) {
        if (typeof infoSource[ik] === "string") { info[ik] = infoSource[ik]; }
      }
      return JSON.stringify({ blocks: blocks, degreeInfo: info });
    } catch (e) {
      return JSON.stringify({ error: String((e && e.message) || e).slice(0, 120) });
    }
    """

    /// Penn's program catalogue: code and title only.
    public static let programs: String = """
    if (typeof sam === "undefined" || typeof fose === "undefined") { return JSON.stringify({ error: "page not ready" }); }
    try {
      var response = await fose.serverAPI.call("programs-v2-list", { srcdb: fose.srcdb.getSelected().code, programsType: "" });
      var rows = [];
      var source = Array.isArray(response) ? response : ((response && Array.isArray(response.programs)) ? response.programs : []);
      for (var i = 0; i < source.length; i++) {
        var row = source[i];
        if (row && typeof row === "object") {
          rows.push({ code: String(row.code || ""), title: String(row.title || "") });
        }
      }
      return JSON.stringify({ programs: rows });
    } catch (e) {
      return JSON.stringify({ error: String((e && e.message) || e).slice(0, 120) });
    }
    """

    /// One catalogue entry's codes, without its requirement template.
    /// Argument: `code`.
    public static let programInfo: String = """
    if (typeof sam === "undefined" || typeof fose === "undefined") { return JSON.stringify({ error: "page not ready" }); }
    try {
      var info = await fose.serverAPI.call("programs-v2-info", { srcdb: fose.srcdb.getSelected().code, programCode: code });
      if (!info || typeof info !== "object") { return JSON.stringify({ error: "no program" }); }
      return JSON.stringify({ program: {
        prog_code: String(info.prog_code || ""),
        prog_name: String(info.prog_name || ""),
        prog_type: String(info.prog_type || ""),
        levl_code: String(info.levl_code || ""),
        degc_code: String(info.degc_code || ""),
        majr_code: String(info.majr_code || ""),
        minr_code: String(info.minr_code || ""),
        conc_code: String(info.conc_code || ""),
        coll_code: String(info.coll_code || ""),
        sis_prog_code: String(info.sis_prog_code || ""),
        minor_sis_prog_codes: String(info.minor_sis_prog_codes || "")
      } });
    } catch (e) {
      return JSON.stringify({ error: String((e && e.message) || e).slice(0, 120) });
    }
    """

    /// The page's five code-to-name maps, string entries only.
    public static let dictionaries: String = """
    if (typeof sam === "undefined" || typeof fose === "undefined") { return JSON.stringify({ error: "page not ready" }); }
    try {
      var all = await foseStudentDataUtils.dictionaries();
      var strings = function (map) {
        var out = {};
        if (map && typeof map === "object") {
          for (var k in map) {
            if (typeof map[k] === "string") { out[k] = map[k]; }
          }
        }
        return out;
      };
      return JSON.stringify({
        majors: strings(all && all.majors),
        degrees: strings(all && all.degrees),
        levels: strings(all && all.levels),
        colleges: strings(all && all.colleges),
        programs: strings(all && all.programs)
      });
    } catch (e) {
      return JSON.stringify({ error: String((e && e.message) || e).slice(0, 120) });
    }
    """

    /// Every script, for tests that must hold for all of them.
    public static var all: [String] {
        [readiness, openSignIn, degrees, audit, programs, programInfo, dictionaries]
    }
}

/// Lenient decoding of the JSON strings the scripts return. Nothing here
/// throws: a malformed or surprising answer is nil, empty or false, and the
/// caller reports "couldn't read path@penn".
public enum PathBridgeDecoder {
    public struct Readiness: Equatable, Sendable {
        public let page: Bool
        public let token: Bool
        public let title: String

        public init(page: Bool, token: Bool, title: String) {
            self.page = page
            self.token = token
            self.title = title
        }
    }

    private static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any]
        else { return nil }
        return dict
    }

    private static func stringMap(_ value: Any?) -> [String: String] {
        var out: [String: String] = [:]
        guard let dict = value as? [String: Any] else { return out }
        for (key, entry) in dict {
            if let text = entry as? String { out[key] = text }
        }
        return out
    }

    public static func readiness(_ json: String) -> Readiness? {
        guard let root = object(json), let page = root["page"] as? Bool else { return nil }
        let token = (root["token"] as? Bool) ?? false
        let title = (root["title"] as? String) ?? ""
        return Readiness(page: page, token: token, title: title)
    }

    public static func opened(_ json: String) -> Bool {
        guard let root = object(json) else { return false }
        return (root["opened"] as? Bool) ?? false
    }

    public static func error(_ json: String) -> String? {
        guard let root = object(json), let message = root["error"] as? String, !message.isEmpty else { return nil }
        return message
    }

    public static func degrees(_ json: String) -> [StudentDegree] {
        guard let root = object(json), let entries = root["degrees"] as? [Any] else { return [] }
        var result: [StudentDegree] = []
        for entry in entries {
            let raw = stringMap(entry)
            guard let code = raw["degc"], !code.isEmpty else { continue }
            result.append(StudentDegree(raw: raw))
        }
        return result
    }

    /// The same JSON as `Data` when it carries a non-empty "blocks" array, so
    /// it can go straight into `PathAuditDecoder.decode`.
    public static func auditData(_ json: String) -> Data? {
        guard let root = object(json), let blocks = root["blocks"] as? [Any], !blocks.isEmpty else { return nil }
        return json.data(using: .utf8)
    }

    public static func programs(_ json: String) -> [PathProgramListing] {
        guard let root = object(json), let rows = root["programs"] as? [Any] else { return [] }
        var result: [PathProgramListing] = []
        for row in rows {
            guard let dict = row as? [String: Any], let code = dict["code"] as? String, !code.isEmpty else { continue }
            let title = (dict["title"] as? String) ?? ""
            result.append(PathProgramListing(code: code, title: title))
        }
        result.sort { left, right in
            let a = left.title.lowercased()
            let b = right.title.lowercased()
            if a != b { return a < b }
            return left.code < right.code
        }
        return result
    }

    public static func programInfo(_ json: String) -> PathProgramInfo? {
        guard let root = object(json), let dict = root["program"] as? [String: Any] else { return nil }
        func field(_ key: String) -> String { (dict[key] as? String) ?? "" }
        let code = field("prog_code")
        guard !code.isEmpty else { return nil }
        return PathProgramInfo(
            code: code,
            name: field("prog_name"),
            type: field("prog_type"),
            level: field("levl_code"),
            degree: field("degc_code"),
            major: field("majr_code"),
            minor: field("minr_code"),
            concentration: field("conc_code"),
            college: field("coll_code"),
            sisProgram: field("sis_prog_code"),
            minorSisPrograms: PathText.list(field("minor_sis_prog_codes"))
        )
    }

    public static func dictionaries(_ json: String) -> PathDictionaries? {
        guard let root = object(json), root["error"] == nil else { return nil }
        return PathDictionaries(
            majors: stringMap(root["majors"]),
            degrees: stringMap(root["degrees"]),
            levels: stringMap(root["levels"]),
            colleges: stringMap(root["colleges"]),
            programs: stringMap(root["programs"])
        )
    }
}
