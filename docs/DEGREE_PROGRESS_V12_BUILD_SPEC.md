# Degree progress, v12: build spec (2026-11-09)

Olisa's decision (2026-11-09, after `docs/DEGREE_PROGRESS_RESEARCH_2026-11-09.md`):
use the student's Path@Penn login. Build, on the `v12` line, a screen where a
student sees their degree progress and what their standing would be if they
switched or added a degree, major, concentration or minor. No course
recommendations or ordering in this version. "Extremely smooth and user
friendly"; it must fit Smooth's vibe (lowercase, the least text that works,
Marco's colours on paper).

This file is the contract three implementers build against at once, so the
Kit types below are an API, not a sketch: use these names and signatures.
Everything here is written without a Swift toolchain; the GitHub runner
(`.github/workflows/tests.yml`, now triggered on `v12`) is the compiler.

## What is known about the data source, and what is not

### Observed on 2026-11-10, and it replaces most of what follows

Olisa captured his own Path@Penn session in Chrome's developer tools: hosts,
paths, parameter and field NAMES, value lengths and JSON shapes only. No
token, id, name, course or grade is recorded here or anywhere in the repo.
**The guesses below this section were wrong about the host and the sign-in.**
They stay as history until the code that implements them is replaced.

- **There is no separate Degree Works host in the student's path.** The
  advising page and the audit are both served by `https://courses.upenn.edu/`
  (CourseLeaf's "FOSE" front end with a student module it calls "SAM"),
  behind Cloudflare. The audit arrives through a proxy route on that host.
- **Sign-in is a 32-character `authtoken`, sent as the form body of each
  POST**, not a cookie: the request's `Cookie` header held only analytics,
  consent and Cloudflare cookies. Requests carry `X-Requested-With:
  XMLHttpRequest` and `Content-Type: application/x-www-form-urlencoded`.
  The token is not in `localStorage`, `sessionStorage`, `document.cookie` or
  any global reachable to depth 3, so it is in the page's markup or closed
  over by its script (open question 1).
- **Calls the page makes** (all `/api/?…` on that host), in order:
  `page=fose&route=load-filter-data`, `page=fose&route=promoted` (the public
  class search), then `page=sisproxy&action=studentdata` (POST, body
  `authtoken`), `page=fose&route=sam-ext-dictionaries`,
  `page=sisproxy&term_code=<6 chars>&action=advisingdata`, the audit
  `page=dgw-server&action=student&method=whatif&name_=<first name>&explain=&id=<24 chars>&levl=<level>&degc=<degree code>`,
  and a keep-alive `page=sisproxy&role=keepalive&pers_id=<24 chars>&pers_id_proof=<30 chars>&action=cart_read`.
  The student is identified by that 24-character id, not the Penn ID.
- **Storage:** `sessionStorage["sam-user-record"]` (shape not yet captured)
  and `localStorage["lastActivityTime"]`.
- **The audit response** is CourseLeaf's translation of the Degree Works
  audit, not the Degree Works dashboard JSON:
  `{ blocks: [{ id, type, title, completionPercent, actionsMap, courseReqCopy: { members: [node…] }, blockhtml }], legendHtml, degreeInfo: { level, degree, program, term, major, minor, college, conc } }`.
  Block `type` was `DEGREE`, `MAJOR`, `OTHER`, `CL_SYNTHETIC_BLOCK` and
  `N/A`; block ids look like two letters and six digits, or a word. A node's
  `type` is `term`, `header`, `sublist`, `comment` or `course`, nested to
  depth 4 through `members`; `completionPercent` is 0 to 100;
  `completionIconName` is `completed`, `registered` or `partial`, and its
  absence on a `course` node means an option still open. A `course` node
  carries `courseCode`, `title` / `titleLong` / `titleShort`, `hours` and
  `hoursCalculated` (strings) and **no grade field**. A `sublist` may carry
  `membersNeeded`, `coursesNeeded`, `hoursNeeded`, `details`, `infoText`.
  `conc` is `NCON` for "no concentration". The DEGREE block holds a comment
  of the form "N CU are required. You currently have N. You still need N
  more." `explanations`, `actionsMap` and `decisions` are the translator's
  debug trail; `blockhtml` is Penn's rendering, the one place a grade could
  sit, and the app never reads it.
- **In the code:** `Degree/PathAuditDecoder.swift` decodes this shape into
  the existing `DegreeAudit` model (fixture `path-audit-synthetic.json`,
  invented data). `DegreeWorksEndpoints`, `DegreeWorksTokens`,
  `DegreeWorksRequests`, `DegreeWorksSessionReader`, `DegreeWorksClient`,
  `DegreeWorksTokenStore` and `DegreeWorksAuditDecoder` describe a system
  the student never touches and are to be replaced, not corrected.

### What the page's own script says (read 2026-11-10)

Excerpts of the two public script files, `/sam/core.js` (65 kB) and
`/fose.js` (1.3 MB), fetched in Olisa's browser. They are the same for every
visitor and carry nothing personal. They answer four of the five questions.

- **Sign-in.** `sam.config.authURL` is
  `https://3scale-public-prod-path-authentication-anon.apps.k8s.upenn.edu/api/v1/leepfrogAuthn/login`.
  `sam.auth.launch()` opens it with `window.open(authURL, 'sam-authenticate',
  'height=600,width=800,…')`; the popup runs Penn's SSO. When the main window
  regains focus, `handleWindowFocus` closes the popup and, if
  `sam.auth.token` is set, calls `sam.user.fetch()`. The mode is `token`
  (`sam.auth.setMode('token')`), `sam.config.tokenParameter` is `authtoken`,
  and `sam.config.sessionTimeout` is 86400 seconds. `setToken(token, expires,
  options)` keeps the token in `sam.auth.token` and, unless
  `options.skipSave`, in a `samauthtoken` cookie; no such cookie was present
  in the captured session, so the hand-off saves nothing. **Not seen:** the
  popup's last page and how it reaches `setToken` (there is no `postMessage`
  listener in `core.js`, so it is presumably `window.opener.sam.auth…`).
  `sam` is a top-level lexical binding, not a property of `window`.
- **The student record.** `sam.user.fetch()` POSTs
  `api/?page=sisproxy&action=studentdata` with the token as form data
  (`sam.fetch.jsonCompat`, which also adds `_pers_id`, `_pers_id_proof`,
  `_pers_real_id`). `sam.user.getProperty('pers')` then holds `id`,
  `idProof`, `fn`, `levl`, `clas`, `cur` (per term: `major`, `degc`, `conc`,
  `levl`) and `coll`; the record also holds `reg`, `cart` and `hist`.
- **The audit.** `foseDgwClient.fetchStudentAudit({ method, degree, explain })`
  (a global `var`) builds the query `action=student`, `method` (default
  `whatif`), `name_` = `pers.fn`, `explain`, `id` = `pers.id`, `levl`, `degc`,
  and POSTs JSON `{ authtoken, degreeInfo: degree, cart, reg, plan,
  currentSrcdb }` to `api/?page=dgw-server&…`. `cart`, `reg` and `plan` are
  the student's cart, registered and planned courses, taken from the record,
  so the audit counts them. `degree` is one of the student's degree
  descriptions (`d.info` with `degc`, `levl`, `coll`, `major`, `conc`,
  `program`, `minor`; comma-joined when several) plus a `title`.
- **What-if.** The same function with a changed `degree`. The page names the
  changes: `new-program` (`degc`, `levl`, `coll`, `major`, `conc`, `program`
  from a catalogue entry's `degc_code`, `levl_code`, `coll_code`,
  `majr_code`, `conc_code`, `sis_prog_code`), `add-major`, `add-minor`
  (allowed when one of the entry's `minor_sis_prog_codes` is among the
  degree's programs) and `add-conc`.
- **The program catalogue.** `fose.serverAPI.call('programs-v2-list', { srcdb,
  programsType })` and `'programs-v2-info'`; `foseDgwClient.fetchProgramReqs`
  reads one program's requirements from
  `api/?page=dgw-server&action=program&program=…&currentSrcdb=…`. These are
  the public endpoints Penn Labs' importer uses.

**Design consequence.** The app should not imitate these requests. It should
load `https://courses.upenn.edu/` in the hidden WebView it already uses for
Canvas renewals (same data store, so the PennKey session and Duo trust carry
over), let the page run its own sign-in, and then call the page's own
functions (`sam.user.fetch()`, `foseDgwClient.fetchStudentAudit(…)`,
`fose.serverAPI.call('programs-v2-list', …)`) with `callAsyncJavaScript`,
taking back only the JSON `PathAuditDecoder` reads. The token then never
leaves the WebView and nothing about Penn's request format is hard-coded.
The popup needs `javaScriptCanOpenWindowsAutomatically` and a
`WKUIDelegate` that returns a child WebView built from the configuration
WebKit hands it, or `window.opener` is nil.

**Still open:** (1) the popup's last page (only a device run with
`DebugDegreeLog` will show it); (2) the exact shape of the degree
descriptions the advising page passes (`d.info`), and of a
`programs-v2-list` entry; (3) whether Cloudflare's check on
`courses.upenn.edu` passes in a hidden WebView (a `cf_clearance` cookie was
present in the browser).

### Before the capture (history)

Read directly from Penn Labs' MIT-licensed source
(github.com/pennlabs/penn-courses, `backend/degree/utils/degreeworks_client.py`)
and a student's Degree Works CLI (github.com/Aaryan-Kapoor/degreeworks-cli,
`parser.py`, `client.py`, `config.py`, `auth.py`). None of it has been
observed against Penn's live system from this project; every constant is in
ONE place (`DegreeWorksEndpoints`) so Marco's capture session changes
constants, not code.

- Penn's audit is Ellucian Degree Works at
  `https://degreeworks-prod-j.isc-seo.upenn.edu:9904`. Penn Labs POSTed
  `/api/audit` with cookies `X-AUTH-TOKEN` (a JWT; `sub` is the student id;
  about 90 minutes elsewhere), `REFRESH_TOKEN` (about 8 hours) and `NAME`,
  and headers `Host` and `Origin`.
- The dashboard's own audit call elsewhere is
  `GET /api/audit?studentId&school=UG&degree=BSE&is-process-new=false&audit-type=AA&auditId=&include-inprogress=true&include-preregistered=true&aid-term=`
  with `Accept: application/vnd.net.hedtech.degreeworks.dashboard.audit.v1+json`.
- Penn Labs' what-if body: `{"studentId", "isIncludeInprogress": true,
  "isIncludePreregistered": true, "isKeepCurriculum": false, "school": "UG",
  "degree": "BSE", "catalogYear": "2025", "goals": [{"code":"MAJOR","value":"CIS"},
  {"code":"CONC","value":...},{"code":"PROGRAM","value":"EU_BSE"},{"code":"COLLEGE","value":"EU"}],
  "classes": []}`. A minor is `{"code":"MINOR","value":"MATH"}`.
- `POST /api/goals` takes and returns a list of collections
  `{id, description, isExpandable, goals: [{name, description, entityName,
  choices: [{key, description, isVisibleInWhatif}], selectedChoices: [...],
  ruleGoalCode, ...}]}`; collection 0 holds catalogYear, program, school,
  college, degree (indices 0 to 4); collection 1 (`curriculumCollection`)
  holds major, concentration, minor (0 to 2). Selecting a program and
  re-posting narrows the later choices.
- Audit JSON (dashboard v1): top level `auditHeader` (has `studentName`,
  `studentEmail`, `degreeworksGpa`, `percentComplete`: NEVER store the
  first three), `blockArray[]` (`requirementId`, `requirementType`,
  `requirementValue`, `title`, `percentComplete`, `ruleArray[]`),
  `classInformation.classArray[]` and `inProgress.classArray[]`
  (`discipline`, `number`, `courseTitle`, `credits`, `letterGrade`, `term`,
  `inProgress` "Y"/"N", `transfer` "T"), `degreeInformation.degreeDataArray[0]`
  (`degreeLiteral`, `catalogYearLit`, `studentLevelLiteral`). A rule:
  `label`, `ruleType` (Course, Group, Subset, IfStmt, Complete, Incomplete,
  Noncourse, Block, Blocktype), `percentComplete`, `inProgressIncomplete`
  "Yes", `classesApplied`, `creditsApplied`, `requirement` (`classesBegin`,
  `creditsBegin`, `numberOfGroups`, `courseArray`), `classesAppliedToRule.classArray[]`,
  `advice.courseArray[]` (`discipline`, `number`, `title`, `credits`),
  `proxyAdvice.textList`, nested `ruleArray`. Numbers often arrive as
  strings ("100").
- Entry URL for the SSO hop is unknown. First guess: the dashboard root
  `/worksheets/` on the Degree Works host, which should bounce to Penn
  WebLogin (SAML) and back with the two token cookies set. Second guess:
  Path@Penn's "Degree planning and audit" link. Both are constants.
- Penn term codes are Banner `YYYYTT` (`202630` = fall 2026), the same form
  `Term(code:)` already parses. Another school's audit used `YYYYMM`; the
  decoder keeps the raw string and parses `Term?` when it can.

## Rules that bind every file

- Nothing personal leaves the phone. The audit is read with the student's
  own session and kept in a JSON file in Application Support
  (`degree-audit.json`, complete-until-first-unlock on iOS). Tokens go in
  the Keychain, this-device-only. Nothing reaches the backend, the laptop
  sync, iCloud or the tree in this version. `docs/PRIVACY.md` gets a section.
- Never store or decode the student's name, email, GPA or letter grades.
  The decoder does not have fields for them. Grades are not needed.
- Never log a token, cookie value, URL query string, student id or page
  body. DEBUG shape logs hold JSON key names only.
- Penn only (`CanvasInstallation.penn`), behind `FeatureFlags.degreeProgress`,
  never in preview or demo mode (fixtures instead), foreground only, no
  background wake work.
- Disconnecting Canvas clears the tokens, the file and the preferences.
- No new `Assignment.Source`, no ledger change, no SwiftData model. Nothing
  from this feature becomes a dashboard card.
- Copy: lowercase, the least text that works. The words "graduate",
  "on track", "eligible" never appear. Status words are exactly `met`,
  `in progress`, `open`. The footer always names the official audit:
  "path@penn's reading · official audit ↗".
- Code comments explain why, in prose. Tests are swift-testing. Every new
  `UserDefaults.lhf` key ends in `V1`.

## Kit API (target `LowHangingFruitKit`, folder `Sources/LowHangingFruitKit/Degree/`)

```swift
// DegreeAudit.swift
public struct DegreeGoals: Codable, Sendable, Hashable {
    public var school: String?        // "UG"
    public var college: String?       // "EU"
    public var program: String?       // "EU_BSE"
    public var degree: String?        // "BSE"
    public var majors: [String]       // ["CIS"]
    public var concentrations: [String]
    public var minors: [String]
    public var catalogYear: String?   // "2025"
    public init(school: String? = nil, college: String? = nil, program: String? = nil, degree: String? = nil,
                majors: [String] = [], concentrations: [String] = [], minors: [String] = [], catalogYear: String? = nil)
    /// "computer science, bse" style one-liner built from descriptions the
    /// caller passes; falls back to codes. Lowercase.
    public func title(descriptions: [String: String]) -> String
}

public enum RuleStatus: String, Codable, Sendable { case met, inProgress, open, info }

public struct AuditCourse: Codable, Sendable, Hashable, Identifiable {
    public let code: String           // "CIS 1200" (discipline + space + number)
    public let title: String
    public let credits: Double?
    public let termCode: String?      // raw, e.g. "202630"
    public var term: Term? { termCode.flatMap(Term.init(code:)) }
    public let isInProgress: Bool
    public let isTransfer: Bool
    public var id: String { "\(code)|\(termCode ?? "")" }
}

public struct AdviceCourse: Codable, Sendable, Hashable, Identifiable {
    public let code: String; public let title: String?; public let credits: Double?
    public var id: String { code }
}

public struct AuditRule: Codable, Sendable, Equatable, Identifiable {
    public let id: String             // stable path id "block.rule.index"
    public let label: String          // as Degree Works wrote it; the view lowercases
    public let ruleType: String
    public let percentComplete: Double?
    public let status: RuleStatus
    public let needCourses: Int?      // requirement.classesBegin
    public let needCredits: Double?   // requirement.creditsBegin
    public let appliedCount: Int?     // classesApplied
    public let appliedCredits: Double?
    public let applied: [AuditCourse]
    public let advice: [AdviceCourse]
    public let adviceText: String?    // proxyAdvice.textList joined
    public let children: [AuditRule]
}

public struct AuditBlock: Codable, Sendable, Equatable, Identifiable {
    public let id: String             // requirementId or "\(type):\(value)"
    public let type: String           // DEGREE, MAJOR, MINOR, CONC, OTHER, ...
    public let value: String
    public let title: String
    public let percentComplete: Double?
    public let rules: [AuditRule]
    public var status: RuleStatus     // derived: 100 → met; any rule inProgress → inProgress; else open
}

public struct DegreeAudit: Codable, Sendable, Equatable {
    public let goals: DegreeGoals
    public let isWhatIf: Bool
    public let percentComplete: Double?     // auditHeader.percentComplete
    public let degreeLabel: String?         // degreeInformation.degreeLiteral
    public let catalogYearLabel: String?
    public let blocks: [AuditBlock]
    public let courses: [AuditCourse]       // classInformation ∪ inProgress, deduped by id, sorted by term then code
    public let fetchedAt: Date
    /// Summary counts over every rule at every depth, excluding `.info`.
    public var ruleCounts: (met: Int, inProgress: Int, open: Int)
    public var creditsApplied: Double        // sum of courses' credits, in-progress included
}
```

```swift
// DegreeWorksAuditDecoder.swift
public enum DegreeWorksAuditDecoder {
    public enum Failure: Error, Equatable { case notJSON, noBlocks }
    /// Lenient: numbers as strings, missing arrays, unknown rule types kept
    /// as `.info`. Throws only when the body is not JSON or has no blockArray.
    public static func decode(_ data: Data, goals: DegreeGoals, isWhatIf: Bool, now: Date) throws -> DegreeAudit
    /// Key names only, for the DEBUG shape log: top-level keys, then the
    /// first block's keys, then the first rule's keys, then the first
    /// class's keys, each as "path: a, b, c". Never a value.
    public static func keyShape(of data: Data) -> [String]
    /// Status rule, exposed for tests.
    public static func status(percentComplete: Double?, inProgressIncomplete: String?, ruleType: String, appliedInProgress: Bool) -> RuleStatus
}
```

```swift
// DegreeWorksEndpoints.swift  (the ONE place every unverified constant lives)
public enum DegreeWorksEndpoints {
    public static let host = "degreeworks-prod-j.isc-seo.upenn.edu"
    public static let port = 9904
    public static var baseURL: URL          // https://host:port
    public static let dashboardPath = "/worksheets/"     // SSO entry, first guess
    public static let pathAtPennFallbackEntry = URL(string: "https://path.at.upenn.edu/")!
    public static let auditPath = "/api/audit"
    public static let goalsPath = "/api/goals"
    public static let studentPath = "/api/students/myself"  // best guess; lenient reader
    public static let auditAccept = "application/vnd.net.hedtech.degreeworks.dashboard.audit.v1+json"
    public static let authCookieName = "X-AUTH-TOKEN"
    public static let refreshCookieName = "REFRESH_TOKEN"
    public static let officialAuditURL = URL(string: "https://path.at.upenn.edu/")!   // the footer link
}

// DegreeWorksTokens.swift
public struct DegreeWorksTokens: Sendable, Equatable {
    public let authToken: String
    public let refreshToken: String?
    public init(authToken: String, refreshToken: String?)
    public var studentID: String?          // JWT `sub`
    public var authExpiresAt: Date?        // JWT `exp`
    public func isUsable(now: Date) -> Bool // authExpiresAt > now + 60 s, or no exp claim
    public static func from(cookies: [HTTPCookie]) -> DegreeWorksTokens?   // by name, any domain
    public var cookieHeader: String        // "X-AUTH-TOKEN=…; REFRESH_TOKEN=…"
    public var description: String         // redacted: "DegreeWorksTokens(auth: present, refresh: present)"
}
public enum JWTClaims {
    public static func payload(_ token: String) -> [String: Any]?   // base64url, no verification
    public static func subject(_ token: String) -> String?
    public static func expiry(_ token: String) -> Date?
}

// DegreeWorksRequests.swift  (pure builders; the UI client adds the Cookie header)
public enum DegreeWorksRequests {
    public static func currentAudit(studentID: String, school: String, degree: String) -> URLRequest   // GET, Accept header
    public static func whatIfAudit(studentID: String, goals: DegreeGoals, keepCurriculum: Bool) -> URLRequest  // POST JSON, Penn Labs' body
    public static func goalsCatalog(selected: DegreeGoals) -> URLRequest   // POST /api/goals with the collections skeleton and selectedChoices filled from `selected`
    public static func studentSelf() -> URLRequest
    /// Body of the goals POST as Data, exposed for tests.
    public static func goalsPayload(selected: DegreeGoals) -> Data
}

// DegreeGoalCatalog.swift
public struct GoalChoice: Codable, Sendable, Hashable, Identifiable { public let key: String; public let description: String; public var id: String { key } }
public struct DegreeGoalCatalog: Codable, Sendable, Equatable {
    public var catalogYears: [GoalChoice]; public var programs: [GoalChoice]; public var schools: [GoalChoice]
    public var colleges: [GoalChoice]; public var degrees: [GoalChoice]
    public var majors: [GoalChoice]; public var concentrations: [GoalChoice]; public var minors: [GoalChoice]
    public static let empty: DegreeGoalCatalog
    /// Lenient decode of the /api/goals response (collections → goals by `name`, not by index when a name is present; index as fallback).
    public static func decode(_ data: Data) throws -> DegreeGoalCatalog
    public func description(forKey key: String) -> String?
}

// StudentSelfReader.swift
public enum StudentSelfReader {
    /// Best-effort read of /api/students/myself: finds school, degree, program,
    /// majors, minors and catalog year wherever they appear (keys named
    /// school/degree/program/major/minor/catalogYear, or goals-shaped arrays).
    /// Returns nil when nothing recognisable is found. Never reads name or email.
    public static func goals(from data: Data) -> DegreeGoals?
}

// DegreeWhatIf.swift
public struct DegreeWhatIfSummary: Sendable, Equatable {
    public let target: DegreeGoals
    public let met: Int; public let inProgress: Int; public let open: Int
    /// Courses the student already has that the target audit applied somewhere.
    public let alreadyCounting: [AuditCourse]
    /// Blocks only the target has (a new minor's block), for the header line.
    public let newBlocks: [AuditBlock]
}
public enum DegreeWhatIf {
    public static func summarize(current: DegreeAudit?, target: DegreeAudit) -> DegreeWhatIfSummary
    /// "+ math minor" / "switch to economics, ba": the header line for a target, from goals and descriptions.
    public static func headline(current: DegreeGoals?, target: DegreeGoals, descriptions: [String: String]) -> String
}

// DegreeAuditStore.swift  (a JSON file, the CourseKnowledgeStore pattern; lossy load)
public struct DegreeSnapshot: Codable, Sendable, Equatable {
    public var current: DegreeAudit?
    public var whatIfs: [DegreeAudit]          // most recent first, at most 5
    public var catalog: DegreeGoalCatalog?
    public var lastShape: [String]             // DEBUG key shape, no values
    public static let empty: DegreeSnapshot
}
public struct DegreeAuditStore: Sendable {
    public let fileURL: URL
    public static func `default`() -> DegreeAuditStore        // Application Support/LowHangingFruit/degree-audit.json
    public init(directory: URL)
    public func load() -> DegreeSnapshot
    public func save(_ snapshot: DegreeSnapshot) throws
    public func clear()
}
```

## UI (target `LowHangingFruitUI`)

- `FeatureFlags.degreeProgress = true` (the kill switch; doc comment like the others).
- `DegreeWorksTokenStore` (Keychain, the `EdSessionTokenStore` pattern, one
  item holding both tokens as JSON; inert under the test runner).
- `DegreeWorksSessionReader` (hidden WebView, the `EdSessionLauncher` shape):
  bound to `LoginDataStores.canvas`, Keychain Canvas cookies injected first,
  loads `DegreeWorksEndpoints.baseURL + dashboardPath`, mobile Safari user
  agent, one `load`. Navigation delegate: on a `PennKeyLoginForm.isLoginForm`
  host run `PennKeyLoginForm.detectFormScript`; if a form is present and
  `PennKeyCredentialStore.load()` has a pair, run
  `fillAndSubmitScript` ONCE per launch (never twice, never resubmit the
  SAML form); on `PennKeyLoginForm.isDuo` hosts install
  `DuoPromptAutoTap` (user script and handler, exactly as
  `CanvasSessionRenewer` does at its lines ~886-933) and report `.needsDuo`
  if the 120 s cap passes; settle when a `didFinish` lands on
  `DegreeWorksEndpoints.host` plus a 3 s settle; then read cookies from the
  store and build `DegreeWorksTokens.from(cookies:)`. Outcomes:
  `landed(tokens)`, `needsDuo`, `noSession` (landed nowhere useful, no
  tokens), `timedOut`, `throttled` (one in flight; at most one per 10
  minutes unless forced), `noCanvasSession`. Hard timeout 60 s (120 s once
  Duo is reached). Nothing logged but host/path words.
- `DegreeWorksClient`: `URLSession` with the Cookie header from the tokens,
  `Origin: baseURL`, `Accept` for the audit. `fetchCurrentAudit(tokens:)`:
  (1) `studentSelf()` → `StudentSelfReader.goals` → if school and degree
  known, `currentAudit(...)` GET; (2) else `whatIfAudit(keepCurriculum: true)`
  with empty goals; (3) else `.needsGoals` so the UI asks the student to pick
  their degree once, then `whatIfAudit(keepCurriculum: true, goals: picked)`.
  A 401/403 → `.tokensRejected` (the reader relaunches once). Record
  `DegreeWorksAuditDecoder.keyShape` into the snapshot's `lastShape` and the
  DEBUG log on every successful decode. `fetchWhatIf(tokens:goals:)`,
  `fetchCatalog(tokens:selected:)`.
- `AppState+Degree.swift`: `@Published var degree: DegreeSnapshot`,
  `@Published var degreeStatus: DegreeStatus` (`idle`, `reading`,
  `waitingForDuo`, `needsCanvasSignIn`, `needsGoals`, `failed(String)`,
  `read(Date)`), `degreeStore`, `refreshDegreeAudit(force: Bool)`
  (Penn only, flag on, not fixture data, foreground only, stale after 12 h
  unless forced), `runWhatIf(_ goals: DegreeGoals)`, `loadDegreeCatalog(selected:)`,
  `pickCurrentGoals(_:)`, `clearDegreeData()` (called from `disconnectCanvas`
  next to `EdDiscussionCoordinator.clearCaches()`), and in preview or demo
  mode `degree = SampleData.degreeSnapshot()` with status `.read`. Status
  words for the screen: "reading path@penn…", "approve the duo push on this
  phone", "sign in to canvas", "pick your degree", "couldn't read path@penn ·
  retry", "read today" / "read yesterday" / "read nov 7".
- `DegreeProgressView.swift` (+ `DegreeRingView`, `DegreeBlockRow`,
  `DegreeRuleRow`, `DegreeCourseChips`): pushed on the dashboard stack via a
  new `DashRoute.degree`. Top: the page title "degree" in `lhfSerif(32)` and
  the status line in `smoothMuted`; a `SmoothSegmentPicker` with
  `progress · what if`. Progress: a teal ring (`creditsApplied` over the
  DEGREE block's credits when known, else `ruleCounts` met over total) with
  the program title under it ("computer science, bse · catalog 2024");
  then one row per block (DEGREE block last, titled "everything else"):
  lowercase title, "n of N" or "x of y cu" in mono, a thin bar in teal
  (met) / marigold (in progress) / rule-grey (open); tap to expand the
  block's rules; a rule row shows its applied courses as chips in
  `courseAccent(for:)` colours, in-progress chips with "· now", and open
  rules show advice course codes as ghost chips (dashed), no ordering, no
  advice prose. Footer: "path@penn's reading · official audit ↗" opening
  `DegreeWorksEndpoints.officialAuditURL`. Pull to refresh. What if: a grape
  "what if" tag on the ring, a picker button ("switch or add…") opening
  `DegreeWhatIfSheet` (stepped picker from the catalog: program → degree
  → major → concentration (optional) → minor (optional), each a list with
  a search field; "run"), then the same block list for the target with the
  headline from `DegreeWhatIf.headline` and one line
  "N met · M in progress · K open · J of your courses count"; recent
  what-ifs as chips above the list (from the snapshot). Empty states in
  the status words above, one line each, never a paragraph.
- Entry: the first row of `ProfileClassesSection` ("degree" with the
  one-line status or "31 of 40 cu" on the right, chevron), a
  `NavigationLink(value: DashRoute.degree)`; hidden when the flag is off, on
  a non-Penn install, or when the snapshot is empty and the status is idle
  outside preview (so no one at another school sees a dead row).
- `SampleData.degreeSnapshot()` for preview and demo: a CIS BSE audit with
  the five sample codes among its courses, one in-progress block, one
  what-if (a math minor). Invented data, obviously so.
- DEBUG: `-LHFShowDegree` pushes the route (the `-LHFShowGrades` pattern in
  `ContentView`); `DebugDegreeLog` keeps the last 30 shape lines in
  `UserDefaults.lhf` `debugDegreeLogV1` (key names only).

## Tests expected

Kit: `DegreeWorksAuditDecoderTests` (a synthetic fixture built from the key
names above, in `Tests/LowHangingFruitKitTests/Fixtures/degreeworks-audit-synthetic.json`;
statuses, string numbers, missing arrays, dedupe, no name/GPA/grade fields on
the output, keyShape has no values), `DegreeWorksTokensTests` (JWT subject and
expiry, cookie pick-up, redaction), `DegreeWorksRequestsTests` (GET query,
POST body byte-for-byte against Penn Labs' shape, goals payload),
`DegreeGoalCatalogTests`, `StudentSelfReaderTests`, `DegreeWhatIfTests`,
`DegreeAuditStoreTests` (round trip, lossy load, clear). UI:
`DegreeWiringTests` (flag off hides; fixture mode never calls the network and
shows sample; disconnect clears tokens, file and status; stale rule),
`DegreeCopyTests` (source scan: no "graduate", "on track", "eligible";
footer text present; status words exactly as listed),
`DegreeStructureTests` (the Profile row is first in the classes section and
gated; the route exists). Predicted: about +90 Swift tests, +10 suites. The
runner's count wins.

## Marco's capture brief (needs a Mac; hosts, paths and key names only)

The code above guesses every endpoint. One session on your own account turns
the guesses into facts. Record hostnames, paths, query parameter NAMES,
status codes and JSON KEY names. Never a token, a cookie value, a student id,
a name or a course list. Paste the result into the "What is known" section.

1. Safari, Develop → Show Web Inspector, Network tab, "Preserve log" on.
   Sign in to Path@Penn, open Degree planning and audit. Note the host the
   audit app runs on and whether the first URL on that host is `/worksheets/`
   or something else (this fixes `DegreeWorksEndpoints.dashboardPath`).
2. In the Network tab filter by that host: list every `/api/...` path the
   dashboard calls while loading your audit, in order, with method and the
   query parameter names (expected: something like `/api/students/myself`,
   then `/api/audit?studentId&school&degree&...`). Note the `Accept` request
   header on the audit call.
3. Storage tab, Cookies for that host: the cookie NAMES present (expected
   `X-AUTH-TOKEN`, `REFRESH_TOKEN`, maybe `NAME`). Do not copy values.
4. On the audit response: Preview → the top-level keys, the keys of one block,
   one rule and one class entry. Compare with the spec's list and note any
   difference (a different name for `classesAppliedToRule`, for instance).
5. Open What-If in the dashboard, pick a different major, run it: record the
   method, path and the request body's KEY names (expected the POST body in
   the spec, with `isKeepCurriculum`), and the `/api/goals` calls' shape.
6. In a fresh private window, go straight to
   `https://degreeworks-prod-j.isc-seo.upenn.edu:9904/worksheets/` and note
   where it redirects (WebLogin? Path@Penn?) and whether it lands on the
   dashboard after sign-in. This is the hidden WebView's path.
7. Then a DEBUG build on the phone: open Profile → classes → degree, wait for
   the status line, and read `debugDegreeLogV1` off the App Group plist
   (`CLAUDE.md` → Commands). It holds key names only.
