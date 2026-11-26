# How Smooth should organise and store Penn's degree rules (2026-11-26)

Phase 2. Written after the inventory (`SOURCES.md`) and the rules
(`RULES.md`). Nothing here is built. It ends with a recommendation, a
schema, example records for real rules, a refresh pipeline and a build
order.

## 1. What the inventory changes about the problem

Three findings decide most of the design.

1. **Penn already publishes its counting rules in machine form.** The
   public Path@Penn program templates (`SOURCES.md` S01) are the scribe
   blocks themselves: requirements, eligible courses, exclusions,
   residency, pass/fail caps, and `NONEXCLUSIVE` share targets that say
   what may double count with what. `policy.ts` guesses these from label
   text ("^area list", "wharton.crossCultural"). The template states them.
   So most of "the rule set" is not something to author. It is something
   to fetch, parse and key by program and catalog year.
2. **What the templates do not say is small and is prose.** Load limits,
   summer caps, the 46-CU floor for two degrees, capstone order, which
   pairs need a petition, mutually exclusive courses, placement. About
   thirty facts per school, each living in one handbook page, each
   changing perhaps once a year. That part must be written by a person
   and must carry its citation.
3. **Rules are keyed by cohort, three different ways.** The scribe by
   catalog year (`Cat_yr_start`), the College by graduating class (one
   policy book per class, a new curriculum for the Class of 2031), CIS by
   entering term ("entering Fall 2024 and later"), Wharton by handbook
   year and sometimes by capstone term ("offered in fall 2027 and
   beyond"). Any store has to take a student's cohort and a date and
   return the rule that applies.

And one constraint: this session verified first-hand only what GitHub
holds. Sixty-seven of the 105 rules are search-reported. The design
therefore has to make "how sure are we, and where does it say so" a field
on every record, not a comment.

## 2. Data or code?

| Thing | Data or code | Why |
|---|---|---|
| Which courses fill a requirement (lists, ranges, attributes, exclusions) | Data | Changes every term; Penn owns it; thousands of rows. |
| Share targets (what may double count with what) | Data | Stated by the scribe per block and per catalog year. |
| Caps ("at most 2 CU", "at most 1 CU restricted", pass/fail limits) | Data | Numbers with a scope; they differ by school and cohort. |
| Loads, summer limits, CU floors | Data | Numbers with a scope. |
| Mutually exclusive sets, no-credit lists | Data | Lists. |
| Sequencing facts ("A in the term before B", "fundamentals before capstone") | Data (a small fixed vocabulary of relations) | The facts change; the kinds of relation do not. |
| Approval status of a counting (automatic, petition, not allowed) and who decides | Data | It is exactly what an answer must cite. |
| The *meaning* of a share target, a cap, a sequence relation | Code | A dozen primitives; each needs an algorithm in the planner. |
| Matching a course against an eligibility expression | Code | `matches()` already exists in `planner.ts`. |
| Choosing and scheduling | Code | The planner. |
| Reading the student's audit into slots | Code | `requirements.ts`. |

The test for the boundary: a Penn rule change should be a data diff. If
a rule cannot be said in the schema, add a primitive to the code and a
record that uses it, never an `if` on a label in `policy.ts`.

## 3. Designs considered

### A. Keep the audit plus a hand-coded policy (today)

`policy.ts` grows a function per rule. Cheap, and it is how the first
plan got right. It fails on every axis the owner named: one student's
schools only, no provenance, no cohort keying, rules found by regex on
labels, and each correction is a code change and a deploy. The five
disagreements in `RULES.md` section 8 are what this costs.

### B. Hand-authored rule files for everything

Write every requirement and rule as YAML in the repo, as IRS does in
TypeScript for CIS. Complete control and reviewable diffs. But IRS is
5,838 lines for one department and its authors run the audits; four
schools, about 100 majors and a new catalog every July is a job, not a
feature. And it would re-type what S01 serves.

### C. Scribe-first packs: generate from Penn's templates, overlay by hand

A workflow fetches the public template for each program and catalog
year, parses it into a normalized "program pack" (JSON), and a small
hand-written overlay holds what the scribe does not say. Files are the
record; diffs are reviewable. This is Penn Labs' architecture
(`parse_path_audit.py` plus `data/dual_programs/`), which shows it is
workable, and their parser is MIT-licensed and can be ported.
Weaknesses: it rests on an undocumented endpoint (S01) that this session
could not call; coordinated programs are not in the public templates;
IfStmt branches need student facts.

### D. A Postgres knowledge base

Normalized tables in the existing Supabase project (`kb_course`,
`kb_attribute`, `kb_requirement`, `kb_share`, `kb_policy`, `kb_source`),
loaded by a workflow, queried by the planner. Gives SQL, joins and
partial reads. Costs: migrations and a loader that need a person's go
each time, a database credential on a GitHub runner or a second
function to ingest, and data that is harder to diff and review than a
file. The planner works in memory on a few hundred courses; it does not
need a query engine.

### E. Fetch per request with a cache (how `catalog.ts` works now)

No store at all: ask Penn Labs and CIS on each request. Always fresh, no
pipeline. But 7.7 s of a 25 s budget went on it in the live dry run
([RUN]), it cannot reach the catalog (202) or anything needing a
browser, nothing is reviewed before the planner trusts it, and there is
nowhere to put a citation.

### F. Depend on Penn Labs' degree API

Their `/api/degree/` already has parsed rules and share targets. It is
gated to their beta users (`IsAuthenticated & InPDPBeta`), has no data
licence, and would make Smooth's planner as available as another
student project's server. Worth a conversation with Penn Labs
(`OPEN-QUESTIONS.md`), not a dependency.

### Comparison

| | A code | B hand files | C scribe packs + overlay | D Postgres | E live fetch | F Penn Labs API |
|---|---|---|---|---|---|---|
| Covers all four schools | no | in theory | yes (single degrees) | as loaded | courses only | yes |
| Provenance per rule | no | yes | yes | yes | no | no |
| Cohort keying | no | by hand | native (catalog year) | yes | no | yes |
| Rule change = data diff | no | yes | yes | yes | n/a | n/a |
| Review before trust | code review | PR | PR | harder | none | none |
| Work to keep current | per rule | very high | low (generated) + small | as C plus ops | none | none |
| Inside 25 s | yes | yes | yes (static reads) | yes | 7.7 s today | unknown |
| New infrastructure | none | none | one branch, two workflows | tables, loader, secret | none | account |
| Main risk | wrong and silent | never finished | endpoint goes away | ceremony | budget, 202 | gated, no licence |

## 4. Recommendation

**C, served as static files, with the overlay bundled in the function.**
Three layers, each with its own source, cadence and store.

| Layer | What | Source | Changes | Store |
|---|---|---|---|---|
| 1. Course facts | Per course: code, title, CU, attributes, cross-lists, seasons offered, grade modes, level restriction; the attribute index; the CIS technical-elective list; the 3-to-4-digit crosswalk | Penn Labs API (S03), Path search (S02), CIS JSON (S07) | every term, some weekly | Generated JSON on an orphan branch `penn-data`, fetched by the function and cached per isolate |
| 2. Program packs | Per program and catalog year: blocks, requirements, eligibility, header rules, share targets | Path templates (S01); hand variants for coordinated programs | yearly, with trickle edits | Generated JSON on `penn-data`, one file per program-year |
| 3. Policy overlay | What the scribe does not say: loads, summer, floors, sequencing, approvals, exclusive sets, placement notes | Handbooks and policy pages, read by a person | a few records a year | Hand-written JSON in the code tree beside the planner, bundled at deploy, covered by the Deno tests |

Why files on a branch and not tables: this project already serves a
public policy file from an orphan branch (`update-manifest`) for the same
reasons that apply here. The data is public and holds nothing about a
student, a pull request shows exactly what changed, GitHub's web UI can
revert a bad change from a phone, no service credential leaves Supabase,
and no deploy is needed when Penn adds a course to an attribute. The
planner reads at most a handful of small files per cold isolate, which is
far inside the budget. Move layer 1 to Postgres only if a real need for
queries appears (for example, the phone asking "what carries WUGE this
fall" directly).

Why the overlay is bundled and not on the branch: it is the part a person
writes, so it should be reviewed and tested like code, and a wrong
record should fail a test before it reaches a student. It is small. It
changes rarely. A `disabled` list on the branch (rule ids to ignore) is
enough of an emergency brake without a deploy.

The student's audit stays the authority (section 7). The packs fill what
the audit does not say, and never overrule what it does.

## 5. Schema

Written as TypeScript types because the planner is TypeScript; the files
are JSON validated against these.

### 5.1 Common parts

```ts
/** Every record carries at least one. An answer cites `url` and `quote`. */
interface Provenance {
  sourceId: string;            // "S24" in SOURCES.md, or a pack's own id
  url: string;
  /** Verbatim from the page or file. Empty only when via = "scribe". */
  quote: string;
  fetched: string;             // "2026-11-26"
  via: "scribe" | "runner" | "browser" | "github" | "search";
  /** verified: a person or a script read the quote at the url on `fetched`.
   *  reported: second-hand (a search summary). inferred: our reading. */
  confidence: "verified" | "reported" | "inferred";
  edition?: string;            // "2025-26 handbook", "catalog 2027", "C29"
}

/** Who a record applies to. Every field narrows; absent means any. */
interface Scope {
  school?: "AS" | "EU" | "WU" | "NU";      // Penn's college codes
  program?: string;                         // "EU_BSE", "WU_BS", "AU_BA"
  major?: string;                           // "CSCI"
  concentration?: string;
  coordinated?: "MT" | "HUNTSMAN" | "LSM" | "VIPER" | "NHCM";
  /** Scribe catalog years, inclusive. */
  catalogYears?: { from?: number; to?: number };
  /** Entering term codes, for rules keyed that way. */
  entered?: { from?: string; before?: string };   // "202430"
  /** Graduating class, for College books and Nursing. */
  classOf?: { from?: number; to?: number };
  /** The rule holds for terms in this range (capstone "from fall 2027"). */
  terms?: { from?: string; to?: string };
}
```

### 5.2 Eligibility (extends `Eligibility` in `types.ts`)

```ts
type Eligibility =
  | { kind: "courses"; codes: string[] }
  | { kind: "pattern"; pattern: string }                       // "CIS 2@", "@ 2960"
  | { kind: "range"; subject: string; from: number; to: number }
  | { kind: "subject"; subjects: string[] }
  | { kind: "number"; numbers: number[] }
  | { kind: "attribute"; codes: string[] }
  | { kind: "list"; list: string; statuses: string[] }         // "cis-te", ["unrestricted"]
  /** Scribe restrictions on the record, not the course. */
  | { kind: "record"; test: "passFail" | "transfer" | "olderThanYears" | "takenBefore" | "takenAfter"; value?: string | number };
```

A requirement accepts a course that matches any `anyOf` and no `exclude`.

### 5.3 Program packs (layer 2)

```ts
interface ProgramPack {
  code: string;                 // Path code "CSCI-BSE-NCON"
  sisProgram: string;           // "EU_BSE"
  catalogYear: number;          // 2027
  title: string;
  blocks: Block[];
  provenance: Provenance;       // via "scribe", url = the endpoint, fetched date, srcdb
}

interface Block {
  type: "DEGREE" | "MAJOR" | "MINOR" | "CONC" | "OTHER";
  code: string;                 // Req_value: "CSCI", "U-SEAS-SSH"
  reqId?: string;               // Req_id: "RA002291"
  title: string;
  minCu?: number;               // CLASSESCREDITS
  minClasses?: number;
  minCuAtPenn?: number;         // MINRES
  lastClassesAtPenn?: number;   // LASTRES
  minGpa?: number;              // MINGPA
  /** MAXCLASS / MAXCREDIT: caps and outright exclusions. */
  caps: { max: number; unit: "cu" | "courses"; match: Eligibility[]; tag?: string }[];
  /** MINCLASS / MINCREDIT with a label: overlays that count courses already applied. */
  overlays: { label: string; need: number; unit: "cu" | "courses"; anyOf: Eligibility[] }[];
  share: ShareTarget[];         // block-level NONEXCLUSIVE
  standalone: boolean;          // STANDALONEBLOCK
  requirements: Requirement[];
}

type ShareTarget =
  | { with: "thisBlock" }
  | { with: "anyBlock" }
  | { with: "blockType"; type: Block["type"] }                 // (MAJOR)
  | { with: "block"; type: Block["type"]; code: string };      // (OTHER = U-SEAS-WREE), (MAJOR = AFRC)

interface Requirement {
  id: string;                   // stable: block Req_id + Rule_id (or LabelTag), as the scribe gives them
  labelTag?: string;            // "SNRNFL"
  label: string;                // Penn's words
  /** group: need `pick` of the children (all when absent). */
  kind: "course" | "group";
  pick?: number;
  need?: { amount: number; unit: "cu" | "courses" };
  anyOf?: Eligibility[];
  exclude?: Eligibility[];
  share?: ShareTarget[];        // rule-level NONEXCLUSIVE, added to the block's
  /** IfStmt the template could not decide: both branches kept. */
  when?: { left: string; op: string; right: string };
  children?: Requirement[];
}
```

Coordinated programs are a `ProgramVariant`: `{ coordinated, base:
sisProgram, suppress: [{ block?, contains? }], add: Block[], cuFloor,
allowedMajors, provenance }`, written by hand the way Penn Labs does.

### 5.4 Course facts (layer 1)

```ts
interface CourseFact {
  code: string;                 // "BEPP 2500"
  title: string;
  cu: number;
  cuOptions?: number[];         // variable credit
  attributes: string[];
  crosslists: string[];
  /** Terms seen with sections, newest first: ["2027A", "2026C", "2026B", ...]. */
  offered: string[];
  gradeModes: ("letter" | "passFail" | "su")[];    // QS / QP / QU
  /** From Path restrictions: "UG" only, "GR" only, schools. */
  restrictions?: { levels?: string[]; schools?: string[]; text?: string };
  formerly?: string;            // 3-digit code
}
interface AttributeFact { code: string; name: string; school: string | null; courses?: string[] }
```

One file per academic year for courses, one for attributes, one per
curated list (`cis-te.json` carries both `status` and `status_prefall24`).
Each file has a header `{ generated, sources: Provenance[] }`.

### 5.5 Policy overlay (layer 3)

```ts
type Approval =
  | { status: "automatic" }
  | { status: "petition"; decidedBy: string; how?: string }    // "Wharton Undergraduate Petitions Committee"
  | { status: "notAllowed" };

type PolicyRecord = { id: string; scope: Scope; provenance: Provenance[]; note?: string } & (
  /** Two requirements, named by block code and optional label test, may or may not share a course. */
  | { kind: "share"; a: Selector; b: Selector; approval: Approval; capCu?: number; onlyIf?: Eligibility[] }
  /** How many degrees or majors may claim one course. */
  | { kind: "claims"; max: number }
  | { kind: "totalFloor"; cu: number; excluding?: Eligibility[] }
  | { kind: "load"; term: "semester" | "firstSemester" | "summer" | "summerSession";
      standardCu: number; steps: { upToCu: number; approval: Approval; needs?: string }[] }
  | { kind: "limit"; what: "passFail" | "creditAway" | "graduateShared" | "minorSpecified";
      max: number; unit: "cu" | "courses"; per?: "career" | "term" | "summer" }
  | { kind: "sequence"; relation: "before" | "termBefore" | "sameTerm"; first: Selector; then: Selector }
  | { kind: "exclusive"; sets: string[][]; countsFirstOnly?: boolean }
  | { kind: "placement"; requirement: Selector; text: string }
  | { kind: "noCount"; match: Eligibility[] }
);

/** Points at requirements without naming a student. */
type Selector =
  | { block: string; label?: string }       // "U-WLAS", /cross-cultural/i as a string
  | { attribute: string }                   // requirement that tests WUGE
  | { group: string };                      // fallback: today's SlotGroup names
```

Rules for records: an `id` never changes (`RULES.md` ids are the seed);
every record has provenance; `confidence: "reported"` records may inform
a note but may not make the planner refuse something; when two records
match, the narrower scope wins, then the newer edition.

## 6. Example records for rules found in phase 1

Program pack fragments, as the generator would write them from
`CSCI-BSE-NCON.xml` (SEAS-07, SEAS-10, SEAS-13, SEAS-14):

```json
{
  "code": "CSCI-BSE-NCON", "sisProgram": "EU_BSE", "catalogYear": 2027,
  "blocks": [{
    "type": "MAJOR", "code": "CSCI", "title": "Major in Computer Science",
    "minCu": 29, "minCuAtPenn": 14.5, "minGpa": 2.0,
    "caps": [{ "max": 0, "unit": "cu", "match": [{ "kind": "record", "test": "passFail" }], "tag": "MXPFCOVID2" }],
    "share": [{ "with": "blockType", "type": "MAJOR" }, { "with": "blockType", "type": "MINOR" }, { "with": "blockType", "type": "CONC" }],
    "standalone": false,
    "overlays": [{
      "label": "Area List - Networking", "need": 1, "unit": "courses",
      "anyOf": [{ "kind": "courses", "codes": ["NETS 1500", "NETS 2120", "CIS 4510", "CIS 5510", "CIS 4550", "CIS 5550", "CIS 5050", "CIS 5530", "CIS 3310"] }]
    }],
    "requirements": [{
      "id": "CSCI/technical-electives/unrestricted", "kind": "course",
      "label": "Unrestricted Technical Electives",
      "need": { "amount": 5, "unit": "cu" },
      "anyOf": [{ "kind": "attribute", "codes": ["EUCU"] }]
    }, {
      "id": "CSCI/engineering/cis-elective-2000", "kind": "course",
      "label": "CIS Elective at the 2000 Level or Above",
      "need": { "amount": 3, "unit": "cu" },
      "anyOf": [{ "kind": "range", "subject": "CIS", "from": 2000, "to": 9999 },
                { "kind": "courses", "codes": ["ESE 3500"] },
                { "kind": "range", "subject": "NETS", "from": 2000, "to": 5999 }],
      "exclude": [{ "kind": "courses", "codes": ["CIS 2610", "CIS 3333", "CIS 4230", "CIS 5230", "CIS 7980"] },
                  { "kind": "number", "numbers": [2960, 2970] }]
    }]
  }],
  "provenance": { "sourceId": "S01", "url": "https://courses.upenn.edu/api/?page=fose&route=programs-v2-info",
    "quote": "", "fetched": "2026-11-26", "via": "scribe", "confidence": "verified", "edition": "catalog 2027 (srcdb 202630)" }
}
```

The SSH block's sharing with College majors (SEAS-08) is one line of the
same pack: `"share": [{ "with": "block", "type": "OTHER", "code":
"U-SEAS-WREE" }, { "with": "block", "type": "MAJOR", "code": "AFRC" }, ...]`.

Overlay records. Confidence is honest: most are `reported` until a
runner or a person re-reads the page.

```json
[
 { "id": "WH-02", "kind": "share",
   "scope": { "school": "WU" },
   "a": { "attribute": "WUCN|WUCU" }, "b": { "block": "U-WLAS" },
   "approval": { "status": "automatic" }, "capCu": 2,
   "provenance": [{ "sourceId": "S24",
     "url": "https://undergrad-inside.wharton.upenn.edu/double-counting-courses/",
     "quote": "Two CUs satisfying the Cross-Cultural Perspectives requirement may also double-count as Humanities; Social Sciences; Natural Sciences, Math, and Engineering (NSME); and Flex General Education (FGE).",
     "fetched": "2026-11-26", "via": "search", "confidence": "reported" }] },

 { "id": "WH-06", "kind": "share",
   "scope": { "school": "WU" },
   "a": { "attribute": "WUGE" }, "b": { "group": "any" },
   "approval": { "status": "notAllowed" },
   "provenance": [{ "sourceId": "S25",
     "url": "https://undergrad-inside.wharton.upenn.edu/wp-content/uploads/2025/06/2025-26_Handbook.pdf",
     "quote": "Global Economy, Business, and Society courses may not be double-counted toward any other requirement.",
     "fetched": "2026-11-26", "via": "search", "confidence": "reported", "edition": "2025-26 handbook" }],
   "note": "Wording from a search summary. Until verified this only removes the petition suggestion; it never blocks an audit-stated match." },

 { "id": "SEAS-17", "kind": "load",
   "scope": { "school": "EU" }, "term": "semester", "standardCu": 5.5,
   "steps": [
     { "upToCu": 6.5, "approval": { "status": "petition", "decidedBy": "the student's department", "how": "CU limit raise request, each semester" }, "needs": "3.0 GPA and a prior semester at one CU less" },
     { "upToCu": 7, "approval": { "status": "petition", "decidedBy": "Penn Engineering Petitions Committee" } } ],
   "provenance": [{ "sourceId": "S07", "url": "https://advising.cis.upenn.edu/cu-limit/",
     "quote": "If you are eligible, you can submit a CU limit raise request for 6 or 6.5 CUs. CU limits of 7 CUs require a SEAS Petition, and are rarely granted.",
     "fetched": "2026-11-26", "via": "github", "confidence": "verified" }] },

 { "id": "WH-08", "kind": "load",
   "scope": { "school": "WU" }, "term": "semester", "standardCu": 5.5,
   "steps": [{ "upToCu": 6.5, "approval": { "status": "petition", "decidedBy": "Wharton Undergraduate Petitions Committee" }, "needs": "an academic justification and plan; normally at most 1 CU above the prior semester" }],
   "provenance": [{ "sourceId": "S24", "url": "https://undergrad-inside.wharton.upenn.edu/course-load/",
     "quote": "Students must be approved for more than 5.5 CUs of enrollment.",
     "fetched": "2026-11-26", "via": "search", "confidence": "reported" }] },

 { "id": "SEAS-34", "kind": "load",
   "scope": { "school": "EU" }, "term": "summer", "standardCu": 4, "steps": [],
   "provenance": [{ "sourceId": "S22",
     "url": "https://academics.engineering.upenn.edu/ugrad/student-handbook/academic-policies/enrollment/",
     "quote": "Students may take a maximum of 4 course units (CUs) during the summer term, whether the courses are taken at Penn, another institution, or a combination of both.",
     "fetched": "2026-11-26", "via": "search", "confidence": "reported" }] },

 { "id": "SEAS-28", "kind": "totalFloor",
   "scope": { "school": "EU" }, "cu": 46,
   "excluding": [{ "kind": "list", "list": "seas-no-credit", "statuses": ["no"] }],
   "provenance": [{ "sourceId": "S22",
     "url": "https://academics.engineering.upenn.edu/ugrad/student-handbook/programs-options/dual-degrees-and-special-programs/",
     "quote": "the minimum requirement for any dual degree student with Engineering is 46 course units.",
     "fetched": "2026-11-26", "via": "search", "confidence": "reported" }],
   "note": "Applies when the student holds an EU degree and a degree in another school." },

 { "id": "SEAS-30", "kind": "claims", "scope": {}, "max": 2,
   "provenance": [{ "sourceId": "S22",
     "url": "https://ugrad.seas.upenn.edu/student-handbook/programs-options/dual-majors-2-penn-engineering-programs/",
     "quote": "No course may be triple counted, i.e., counted for more than two degrees/majors.",
     "fetched": "2026-11-26", "via": "search", "confidence": "reported" }] },

 { "id": "WH-07", "kind": "sequence", "relation": "before",
   "scope": { "school": "WU", "terms": { "from": "202730" } },
   "first": { "block": "U-WBUS", "label": "fundamentals|leadership journey" },
   "then": { "attribute": "WUCP" },
   "provenance": [{ "sourceId": "S24", "url": "https://undergrad-inside.wharton.upenn.edu/senior-capstone/",
     "quote": "For all senior capstone courses offered in fall 2027 and beyond, students must also complete all business fundamentals as a prerequisite.",
     "fetched": "2026-11-26", "via": "search", "confidence": "reported" }] },

 { "id": "SEAS-15", "kind": "sequence", "relation": "termBefore",
   "scope": { "school": "EU", "major": "CSCI" },
   "first": { "block": "CSCI", "label": "Senior Project #1" },
   "then": { "block": "CSCI", "label": "Senior Project #2" },
   "provenance": [{ "sourceId": "S03", "url": "https://penncoursereview.com/api/base/2026C/courses/CIS-4000/",
     "quote": "The project continues during two semesters; students must enroll in CIS 401 during the second semester.",
     "fetched": "2026-11-16", "via": "runner", "confidence": "verified" }] },

 { "id": "WH-15", "kind": "exclusive", "scope": { "school": "WU" },
   "sets": [["BEPP 2500", "ECON 2100"], ["FNCE 1010", "ECON 2200"], ["STAT 1010", "STAT 1110"]],
   "countsFirstOnly": true,
   "provenance": [{ "sourceId": "S24", "url": "https://undergrad-inside.wharton.upenn.edu/incompatible-courses/",
     "quote": "", "fetched": "2026-11-26", "via": "search", "confidence": "reported" }],
   "note": "No quote: the page was only summarised. Must be read before use." },

 { "id": "SEAS-18", "kind": "limit", "what": "minorSpecified",
   "scope": { "school": "EU" }, "max": 2, "unit": "courses",
   "provenance": [{ "sourceId": "S07", "url": "https://advising.cis.upenn.edu/minor/",
     "quote": "no more than two _specified_ courses on your CPG can be double-counted towards a minor.",
     "fetched": "2026-11-26", "via": "github", "confidence": "verified" }] }
]
```

A cohort-keyed list rule (SEAS-10 and SEAS-11) needs no overlay record at
all: the 2027 pack already says "1 CU from EUCR or EUCU, 5 CU from EUCU",
and an older pack will say what applied to that catalog year. Where the
audit gives no attribute, the CIS list stands in:
`{ "kind": "list", "list": "cis-te", "statuses": ["unrestricted"] }`, with
`status_prefall24` chosen when `scope.entered.before = "202430"`.

## 7. How this sits beside the student's audit

The audit is Penn's reading of one student. The packs are Penn's rules
for anyone. Order of authority, highest first:

1. **The student's audit**: which requirements exist, what is met, what
   is still needed, which courses Penn applied where, and any "advice"
   course list. Exceptions and approved petitions show up only here.
2. **The program pack** for the same program and catalog year: adds what
   the phone's translation of the audit does not carry or carries only as
   words: share targets, overlays (area lists), caps, exclusions,
   residency minimums. Joined to audit rules by block type, block title
   and label (the audit JSON the phone sends has empty block `value`s
   today; see `OPEN-QUESTIONS.md` for capturing `Req_value`).
3. **The policy overlay**: cross-cutting rules no block states.
4. **Course facts**: what exists, what it carries, when it runs.

When 1 and 2 disagree (a requirement the pack does not have, a different
need), the audit wins and the planner adds a note ("your audit differs
from Penn's published template for catalog 2025; I followed your audit").
The pack never removes a course Penn applied. A what-if for a program the
student has no audit for can be planned from the pack alone, marked as
an estimate, which saves a Path read and a possible Duo push.

Catalog years need one mapping: the audit's `catalogYear` is a term code
("202430") and a pack's is the scribe year (2027 for srcdb 202630). The
generator writes both on each pack.

## 8. How the planner consumes it, and what leaves `policy.ts`

`Slot` gains three fields filled by `requirements.ts` from the pack:
`blockCode`, `share: ShareTarget[]`, and `overlayOf?: string` (an area
list is an overlay on its block, not a slot competing for a course).
`Policy` stays an interface, but `pennPolicy` becomes
`buildPolicy(knowledge, degrees, cohort)`:

| Today in `policy.ts` | Becomes |
|---|---|
| `withinDegree(a, b)`: regex on "area list", pairs of `wharton.*` groups | Share targets on the two slots (`thisBlock`, `block`, `blockType`), plus overlay `share` records with `approval: automatic`. Area lists stop being slots at all. |
| `withinDegreeCap` (`crossCultural+liberal`, 2) | `capCu` on the matching `share` record (WH-02). |
| `petitionPairs` | `share` records with `approval: petition` and a named decider; `notAllowed` records remove a suggestion (WH-06). Each petition in the output can now say who decides and cite the page. |
| `crossDegree.maxPerDegree` | `claims` record (SEAS-30), plus per-block share targets across degrees (SEAS-08: SSH with a College major). |
| `loads` (5.5 / 6.5 / 2 / 4, one set for everyone) | `load` records per school and term kind; for two schools the planner takes the stricter standard load and lists both approval paths. |
| `sequences.immediatelyBefore` (regex on "#1" / "#2") | `sequence` records with `termBefore`. |
| `capstoneRule` | `sequence` record WH-07 with its `terms.from`. |
| (missing) | `totalFloor` (46 CU for two degrees with Engineering), `noCount` and block `caps` (no-credit list, MBA and 5000+ limits), `exclusive` sets, `limit` records for pass/fail and credit away, residency (`minCuAtPenn`). |
| `SlotGroup` and `groupFor()` in `requirements.ts` | Kept only as a fallback selector when no pack matches the audit. |

`catalog.ts` shrinks to "read `courses/{year}.json`, `attributes.json`
and the lists from the `penn-data` branch, cache per isolate, fall back
to Penn Labs live when the file is missing or older than a threshold".
Offered seasons then come from three years of terms rather than three
semesters, and summer offerings become known.

Every planned course can carry the provenance of the rule that let it
count twice or that placed it, so the explanation step can say "Wharton's
double-counting page" with a link, and say "reported, not yet verified"
where that is the truth.

## 9. Refresh pipeline

Four scheduled workflows on GitHub runners, each ending in a pull request
against `penn-data` with a plain-language summary; a person merges.
Nothing here needs a Supabase credential.

| Workflow | Fetches | Cadence | Diff summary a reviewer sees |
|---|---|---|---|
| `penn-data-courses` | Penn Labs `/attributes/`, per-semester lists for the last nine terms, attribute searches for the codes any pack or record names; Path `details` for restrictions and grade modes on courses the planner offered recently | weekly; daily in advance-registration weeks | "EUCU: +3 -1. 14 new courses in 2027A. BEPP 2500 no longer offered in summer." |
| `penn-data-programs` | Path `programs-v2-list`, then `programs-v2-info` for each undergraduate program and minor of the current and prior four catalog years; parsed by a TypeScript port of Penn Labs' parser | monthly; weekly in July and August when the new catalog lands | "CSCI-BSE 2027: Area List - Networking + CIS 3310. 2 programs added." |
| `penn-data-lists` | CIS technical-elective JSON and crosswalk from GitHub raw | weekly | "cis-te: STAT 4800 added as unrestricted." |
| `penn-rules-watch` | Every URL named in an overlay record's provenance; checks the record's `quote` still appears in the page text (whitespace-normalized); upgrades `reported` to `verified` when a runner finds the quote for the first time | weekly | Opens an issue per miss: "WH-08: quote not found at course-load/ (page changed or wording was never exact)". |

What needs a person: (a) anything behind the catalog's 202 wall, until a
mirror or a headless browser is shown to work; (b) the yearly handbooks
(Wharton PDF each June, College policy book per class, SEAS handbook
edits): read the diff the watcher flags and edit the record; (c)
coordinated-program variants; (d) the first verification pass over the
67 reported rules. If `programs-v2` proves unreachable from runners, the
fallback is a browser capture by the owner once per catalog year for the
programs Smooth's students actually have (the app could even report
which program codes are in use, as a count with no user id).

Change detection for generated data is the pull-request diff itself. For
safety the generator refuses to open a PR that deletes more than a set
share of any file (a failed fetch must not read as "Penn removed 400
courses"), the same idea as the ledger's "refuses a suspiciously empty
fetch".

## 10. Testing

- **Parser:** the seven Penn Labs audit fixtures (MIT) as golden inputs;
  assertions for each construct seen (`MINCLASS` overlay, `Except`,
  wildcard, range, `With ATTRIBUTE`, `NONEXCLUSIVE` at block and rule,
  `STANDALONEBLOCK`, transfer ban, pass/fail cap).
- **Schema:** every record validates; every record has provenance with a
  URL and a date; no record is `verified` with `via: "search"`; no
  `reported` record carries `notAllowed` into a hard refusal; ids are
  unique and present in `RULES.md`.
- **Parity:** on `degree-audits-synthetic.json`, the data-built `Policy`
  gives the same answers as today's `pennPolicy` for every slot pair,
  except a listed set of intended changes (the five in `RULES.md`
  section 8). This is the test that lets `policy.ts` be deleted.
- **Planner goldens:** the existing synthetic-audit plans, re-run with a
  frozen copy of the packs in `backend/test/fixtures/penn-data/`.
- **Live dry run:** `scripts/penn-catalog/dry-run.ts` already plans on a
  runner; point it at the branch files and print which records and packs
  each decision used.
- **Watcher self-test:** a record with a deliberately wrong quote must
  raise an issue.

## 11. Build order, most value first

0. **One verification run (a day).** Extend `fetch.mjs` with the fetch
   list at the end of `SOURCES.md`: confirm `programs-v2` answers a
   runner, save `/attributes/` whole, fetch the Wharton handbook PDF and
   the SEAS and College pages, and check the quotes of the dozen rules
   the planner already depends on. Everything below is safer after this.
1. **Overlay as data (two to three days).** The schema in 5.5, records
   for the rules `policy.ts` holds plus the missing ones (46-CU floor,
   per-school loads, SEAS summer limit, GEBS, language "at Penn"), the
   parity test, and `buildPolicy`. Fixes known wrong answers with no new
   infrastructure.
2. **Course facts on a branch (two days).** Removes the 7.7 s live fetch,
   adds real offering history, grade modes and summer terms, and gives
   the attribute index a reviewed home.
3. **Program packs for SEAS and Wharton (a week).** Port the parser, add
   `blockCode`/`share`/`overlayOf` to slots, retire `groupFor` regexes
   for those schools. This is the principled replacement the owner asked
   for, proven first on the case already understood.
4. **College and Nursing packs, minors, second majors.** Mostly free once
   3 works; the College needs the sector auto-completion table and the
   per-class policy keying.
5. **Coordinated programs.** Port Penn Labs' four variants (with
   thanks and their licence), write NHCM from its pages, verify each
   against one signed-in what-if capture.
6. **Citations in answers.** Pass provenance through `PlanResult` so the
   explanation can link Penn's page and say how sure the app is.
7. **Planning from packs without a Penn read**, for what-ifs, and the
   College's Class of 2031 curriculum when its template appears in Path.

## 12. The privacy line

Nothing in any of the three layers is about a student: course facts,
program templates of a dummy record, and published policies. The
generator never signs in and never reads an audit. The `penn-data` branch
and the overlay can be public because there is nothing private in them.
The student's audit keeps the path it has now (phone to function, stored
nowhere), and the function's reads of pack files name a program and a
catalog year, never a person. Two things to hold to: captures the owner
makes signed in (`OPEN-QUESTIONS.md`) are masked before they enter the
repo and are used to learn shapes, never committed as data; and if the
app ever reports which program codes are in use so the pipeline knows
what to fetch, it reports counts, not users. `docs/PRIVACY.md` needs no
change for this design, because nothing new leaves the phone.

One thing that is not privacy but belongs beside it: the data is Penn's.
Store codes, numbers, titles and short quoted rules with their source,
not course descriptions or whole pages, and settle the terms question in
`OPEN-QUESTIONS.md` before the branch grows.
