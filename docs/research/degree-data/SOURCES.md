# Penn degree data: every source found (2026-11-26)

Phase 1 of the degree-data research for the planner in
`backend/supabase/functions/_shared/degreePlanner/`. This file is the
inventory. `RULES.md` holds the rules read from these sources, `DESIGN.md`
the storage design, `OPEN-QUESTIONS.md` what is still unsettled and what the
owner can capture signed in.

## Live probe, 2026-11-26: S01 and S02 are verified from a GitHub runner

After this file was written, `scripts/penn-catalog/probe-path.mjs` called
Path@Penn's public endpoints from a GitHub runner (the `penn-catalog`
workflow, commits `795e210` and `b6e23cf`). No sign-in, browser-like
headers, 0.6 s between calls. What it settled, which overrides the
"UNREACHED live" notes in S01 and S02 below:

- **`programs-v2-list`** (term `202630`) answers 200 with 1,049 programs:
  118 `-MINOR`, 36 `-BA`, 17 `-BS`, the `-BSE` and `-BSE-<concentration>`
  codes, and the graduate programs.
- **`programs-v2-info`** answers 200 in about 0.1 s with the keys `key,
  prog_code, prog_name, prog_type, prog_parent, levl_code, degc_code,
  majr_code, minr_code, conc_code, coll_code, dept_code, sis_prog_code, hide,
  audit_xml, minor_sis_prog_codes`. A code that does not exist answers `{}`
  with status 200, so an empty object is "no such program", not an error.
  The real codes differ from the obvious ones: computer science is
  `CSCI-BSE-NCON` (and `-ARIN`, `-COGS`, `-CBI`, `-CMV`, `-DATS`, `-SFF`,
  `-SYS`; there is no bare `CSCI-BSE`), management is `MGMT-BS-GEN` (and
  `-MNMT`, `-ORGS`, `-SMGT`), finance is `FNCS-BS`; `ECON-BA` does not
  exist under that name.
- **Wharton templates are readable**, which this file could not confirm
  before: `FNCS-BS` is 75,112 characters of audit XML with the blocks
  Degree, First-Year Foundations, Business Fundamentals, Liberal Arts and
  Sciences, Business Breadth and the concentration, and the qualifiers
  `MAXCREDIT` (17), `NONEXCLUSIVE` (13), `MAXCLASS` (8), `CLASSESCREDITS`
  (6), `SPMAXCREDIT` (3), `MINRES`, `MAXPASSFAIL`, `MINGPA`. Seen in it:
  `MINRES 19 Credits`; `MaxClasses 3 in @ 5000:9999`; `MaxClasses 1 in BEPP
  2500, 2508, ECON 2100`; `MaxClasses 0 in MSCI @` and `NSCI @`; `MaxCredits
  0 in @ @ (With DWPASSFAIL = Y ...) Except WH 1010`; `MaxClasses 0 in ...
  @ @ (With DWTRANSFERSCHOOLID = EQIVAP, EQIVIB, EQIVEX, EQIVAS)`;
  `ShareWith (MINOR)`; `ShareWith (OTHER = U-SCHOLARS)`. `MGMT-BS-GEN`,
  `NURS-BSN` (`MINRES 18`, `MINGPA 2`, pass/fail caps) and `MATH-MINOR`
  (the College's `AU..` sector and foundation attributes) answered the same
  way. A minor's `minor_sis_prog_codes` lists the degree programs it may
  attach to.
- **`search` and `details`** answer 200. `details` for a section carries
  `hours_html` (credit units), `attributes_detail` (names with codes, e.g.
  "CIS Unrestricted Technical Elective (EUCU)"), `xlist` ("Scheduled With
  CIS 5710"), `registration_restrictions` as tagged sentences (`cls` class
  level, `lvl` level, `maj` major, `col` division: "Students with a
  semester level of Freshman, Junior or Sophomore may not enroll",
  "Enrollment limited to students in the Wharton Undergraduate division")
  and **`prereqs_from_cim`**, prerequisites as markup with course codes
  (`CIS 4710` → `CIS 2400`). It is filled for some courses and empty for
  others (`STAT 4310`, `ACCT 1020`, `ASLD 0200`, `FNCE 2050`, `CIS 4000`
  were empty), so it narrows the prerequisite gap without closing it.

The prose pages and `catalog.upenn.edu`, which this probe did not cover
and which answered runners with an empty 202 on 2026-11-16, were read the
same day by the crawl described next.

## Runner crawl, 2026-11-26: the official prose pages were read from a GitHub runner

A second runner script, `scripts/penn-catalog/verify-rules.mjs`, crawled
579 official pages (2,503,844 characters) and searched them for every
quoted fragment of the 73 REPORTED, CONFLICTING and CODE rules in
`RULES.md` (177 fragments: 100 exact, 49 near, 28 missed). What the fetch
log shows:

- **Answered the runner directly (200, live):** `catalog.upenn.edu` (17
  pages; it answered an empty 202 on 2026-11-16 and read fine this time,
  with a browser User-Agent), `undergrad-inside.wharton.upenn.edu` (335
  pages), `academics.engineering.upenn.edu` (129 pages), the Nursing BSN
  handbook on `www.nursing.upenn.edu` (14 pages), and one page each on
  `admissions.upenn.edu`, `provost.upenn.edu`, `ppe.sas.upenn.edu`,
  `fisher.wharton.upenn.edu`, `web.sas.upenn.edu`, `lsm.upenn.edu` and
  `www.seas.upenn.edu`.
- **Answered 403 live, read from the Internet Archive:**
  `www.college.upenn.edu` (72 pages read), `srfs.upenn.edu` (2),
  `www.math.upenn.edu` (1), `figs.sas.upenn.edu` (1) and
  `psychology.sas.upenn.edu` (1). The College's 38 other tries and 103
  further queued URLs are not in the corpus (38 answered 404; 103 were
  left in the queue by the per-site cap).
- **Failed:** `https://www.viper.upenn.edu/academics/dual-degree-curriculum`
  (404, live), so the VIPER page behind CD-03 was not read; 17 URLs on the
  Engineering handbook answered 404 (16 of them `/feed/` addresses and
  `.../course-categories/free-electives/`, which is
  `.../free-electives-and-no-credit-courses/` today).
- **Page counts:** Wharton 335 and Engineering 129 (the crawl queue for each ended
  empty), the College 72, catalog 17,
  Nursing 14, other hosts 12 (10 hosts, `srfs` counted twice).
- **Wharton sitemap:** `https://undergrad-inside.wharton.upenn.edu/page-sitemap.xml`
  lists 355 pages; `wp-sitemap.xml` and `sitemap_index.xml` each list 2
  entries that point to sitemaps like it.
- **The 2025-26 Wharton handbook PDF** (`.../wp-content/uploads/2025/06/2025-26_Handbook.pdf`,
  94,925 characters) was read as text (the workflow installs `poppler-utils`) and searched with
  the pages.

So these hosts can be read from a runner, and every statement in this
file that says the handbooks, the College's policy pages or
`catalog.upenn.edu` cannot be reached from one is out of date (the note on S10
below keeps the 2026-11-16 observation as history). The
rules read this way carry `VERIFIED (page, 2026-11-26)` in `RULES.md`.

## Read this first: what this session could and could not reach

The session ran on the Default cloud environment, whose network allows only
Supabase hosts. Every Penn host and Penn Labs' host failed to resolve from
both the shell and the page-fetch tool (`getaddrinfo ENOTFOUND
catalog.upenn.edu`, the same for `penncoursereview.com`; `web.archive.org`
was refused). A saved environment named `penn-dashboard` allows eighteen
hosts (most of them Penn's and Penn Labs'), but a running session cannot be moved onto it
("this session's environment has settings attached to it that an approval
prompt cannot show in full"). So no Penn page was fetched from here. What
was reachable, and what every entry below rests on:

| Label | Meaning |
|---|---|
| **[GH]** | Read directly from a public GitHub repository cloned on 2026-11-26. The commit is given. This is first-hand reading of the file. |
| **[RUN]** | Read from this repo's own `penn-catalog` workflow log (run 43781154209, 2026-11-16 00:34 UTC), where a GitHub runner fetched the URL and printed its shape. First-hand, ten days old. |
| **[SEARCH]** | A web-search summary returned on 2026-11-26. The page itself was **not** fetched. Facts and quoted phrases are as the search tool reported them; they are leads with good odds, not verified text. Every such item must be re-read on the page (from a runner or a browser) before it is treated as a quote. |
| **UNREACHED** | Known to exist, nothing read. How to reach it is stated. |

The single most useful follow-up is to start a session on the
`penn-dashboard` environment (after adding the hosts listed at the end of
this file) or to extend `scripts/penn-catalog/fetch.mjs` with the URL list
in "Fetch list for a runner", and re-verify every [SEARCH] entry.

Nothing in this file is about any student. No sign-in was used anywhere.

---

## A. Machine-readable sources

### S01. Path@Penn public program templates (`courses.upenn.edu/api/`, routes `programs-v2-list` and `programs-v2-info`)

- **Owner:** Penn (Office of the University Registrar); the software is
  CourseLeaf PATH (Leepfrog), proxying Degree Works (Ellucian).
- **What it holds:** for every program in a catalog term (bachelor's
  degrees, concentrations, minors, masters), the **Degree Works audit of an
  empty dummy student**, as XML. That XML is the scribe requirement block
  rendered: blocks (DEGREE, MAJOR, MINOR, CONC, OTHER), rule trees
  (Course, Group, Subset, IfStmt), course lists with wildcards and ranges,
  attribute restrictions (`With ATTRIBUTE = EUCU`), `Except` lists, and the
  block header qualifiers that are Penn's counting rules in machine form:
  `CLASSESCREDITS` (minimum CU), `MINRES` (credits earned at Penn),
  `LASTRES`, `MINGPA`, `MAXCLASS` / `MAXCREDIT` (caps and outright
  exclusions, pass/fail limits, transfer-credit bans), `MINCLASS` /
  `MINCREDIT` (overlay requirements such as the CSCI area lists and the
  College's "Arts and Sciences 31 CU Requirement"), `NONEXCLUSIVE`
  (ShareWith: what may double count with what) and `STANDALONEBLOCK`.
- **Format and endpoints** (from Penn Labs' client, [GH]
  `pennlabs/penn-courses` @ `4111d6f`, `backend/degree/utils/path_client.py`):
  `POST https://courses.upenn.edu/api/?page=fose&route=programs-v2-list`
  with body = URL-encoded JSON `{"srcdb": "202630", "programsType": ""}`
  returns a list of `{code, title}`; codes look like `CMPE-BSE`,
  `ANTH-BA-ARC`, `MATH-MINOR`, `CIS-MSE-NCON`.
  `...&route=programs-v2-info` with `{"srcdb": "202630", "programCode":
  "CMPE-BSE"}` returns metadata including `sis_prog_code` (e.g. `EU_BSE`)
  and `audit_xml`. A term maps to a catalog year rather than being one
  ("202630 serves the 2027 catalog"); the year is read from the block's
  `Cat_yr_start`. Real sample (trimmed), [GH]
  `backend/tests/degree/fixtures/CSCI-BSE-NCON.xml`:

  ```xml
  <Block Cat_yr_start="2027" Cat_yr_stop="9999" College="EU" Major1="CSCI" Req_id="RA002291"
         Req_type="MAJOR" Req_value="CSCI" Title="Major in Computer Science" ...>
    <Header>
      <Qualifier Name="CLASSESCREDITS" Credits="29" Needed="29" Label="Minimum Credits Requirement" LabelTag="SUWEHG" .../>
      <Qualifier Name="NONEXCLUSIVE" Tag="GLBNKS" ...><SubText>(MAJOR)</SubText><Text>ShareWith </Text></Qualifier>
      <Qualifier Name="NONEXCLUSIVE" Tag="SWHMIN" ...><SubText>(MINOR)</SubText>...</Qualifier>
      <Qualifier Name="MINCLASS" Classes="1" Needed="1" Label="Area List - Networking" LabelTag="SNTVKA" ...>
        <SubText>NETS 1500, 2120, CIS 4510, 5510, 4550, 5550, 5050, </SubText>
        <SubText>5530, 3310</SubText><Text>MinClasses 1 in </Text></Qualifier>
    </Header>
    ...
    <Rule Label="Unrestricted Technical Electives" LabelTag="SNRNFL" RuleType="Course" Rule_id="3-1" ...>
      <Requirement Class_cred_op="OR" Connector="," Credits_begin="5">
        <Course Disc="@" Num="@" ...>
          <With Code="ATTRIBUTE" Connector="" Operator="="><Value>EUCU</Value></With>
        </Course>
      </Requirement>
    </Rule>
  </Block>
  ```
  (Abridged: attributes dropped where "..." appears, nothing altered.)
  Each block carries a requirement id (`Req_id="RA002291"`), each rule a
  `Rule_id` and a `LabelTag`, and each header qualifier a `Tag`: stable
  handles for joining a student's audit to its template, if the audit
  the phone receives keeps them (`OPEN-QUESTIONS.md` 1.1).
- **Access:** no sign-in, per Penn Labs' docstring: "unlike the DegreeWorks
  server itself these endpoints need no authentication: the audits they
  return are what-if runs against a dummy student record (Stu_id=\"*\",
  Stu_name=\"*Test\")". Penn Labs sends browser-like headers and waits
  0.5 s between calls. **Not called from this session (UNREACHED live).**
  Reach: unknown from a GitHub runner (the catalog host answered runners
  with an empty 202, and this host may sit behind the same wall); certain
  from a browser.
- **Currency:** live; edits to a catalog year keep arriving in later terms
  ("Several terms can serve the same catalog year, and later terms carry
  its later edits"). Penn Labs stores nothing older than catalog year 2018.
- **Authority:** the highest available for requirement structure and
  counting rules short of the student's own audit, because it is the same
  scribe the student's audit runs. Known holes, from Penn Labs' notes
  ([GH] `backend/degree/data/dual_programs/__init__.py`, `mt.py`,
  `huntsman.py`): the public audit is of a **plain single-degree student**,
  so coordinated-program variants (M&T, LSM, Huntsman's Wharton side) are
  not in it; "Huntsman's College degree has no Path audit at all"; IfStmt
  branches depend on student facts the template does not have.
- **Terms/robots:** not read. Undocumented endpoint; treat as revocable.
- **Gap it fills:** requirements per program and catalog year, exclusions,
  residency, pass/fail caps, double-counting policy. Nothing else gives
  these in machine form.
- **Verified:** code and seven real response fixtures read [GH] on
  2026-11-26; live call UNREACHED.

### S02. Path@Penn public course search (`courses.upenn.edu/api/`, routes `search` and `details`)

- **Owner:** Penn (Registrar), CourseLeaf FOSE.
- **What it holds:** every section of a term, and per section: credit
  (`hours_html`), cross-lists (`xlist`), **course attributes with names**
  (`attributes_detail`), **registration restrictions** (level, school),
  class notes, grade-mode options and per-college rules (`cart_opts`,
  `cart_opts_rules_json`), linked sections, meeting times, instructor,
  description. No separate prerequisite field was present in ten saved
  responses; prerequisites, where stated, are inside `description` or
  `registration_restrictions`.
- **Format and endpoints** ([GH] `jlumbroso/penn-path-scraper` @
  `4b205b7`, `src/api_client.py`, `src/types.py`; also [GH] Penn Labs
  `courses/management/commands/sync_path_status.py`):
  `POST https://courses.upenn.edu/api/?page=fose&route=search` with body
  `{"other": {"srcdb": "202530"}, "criteria": [{"field": "coll", "value":
  "E"}]}` (or `{"field": "keyword", "value": "CIS"}`) returns `{srcdb,
  count, results[]}`; `route=details` with `{"group": "code:CIS 1210",
  "key": "crn:12345", "srcdb": "202530", "matched": "crn:12345",
  "userWithRolesStr": "!!!!!!"}` returns one section's detail. School
  (`coll`) codes: A, C, D, E, F, G, L, M, N, S, V, W. Real sample fields,
  [GH] `tests/fixtures/api_samples/fall-2023-oidd2910-60251.json`:

  ```
  hours_html: "1"
  attributes_detail: "<ul><li>NU Sector ReaSys&amp;Relationship (NURS)</li>
     <li>WH UG BHEC Conc Electives (WUBE)</li>
     <li>Wharton UG Management Concentration Elec (WUMG)</li>...</ul>"
  registration_restrictions: "<p class=\"lvl\">Enrollment is limited to Undergraduate level students.</p>"
  clssnotes: "<p>Course must be taken for a grade.  Auditors need permission.  </p>"
  cart_opts: {"grade_mode": {"options": [{"value":"P","label":"Pass/Fail"}, {"value":"S","label":"Standard Letter Grade"}]}, "credit_hrs": {...}}
  ```
- **Access:** public, no sign-in (two independent open-source clients use
  it, one of them from a scheduled GitHub Actions workflow, so runners
  reached it in 2025). UNREACHED live from this session.
- **Currency:** live per term; historical terms back to at least 2020 are
  queryable (the scraper lists 202010 onward).
- **Authority:** the registrar's own schedule data. Attributes here are
  the same attributes the audit tests.
- **Gap it fills:** attribute names, per-section restrictions (who may
  enrol: "Undergraduate level students"), whether pass/fail is offered,
  variable credit, cross-lists; summer offerings (term `YYYY20`).
- **Verified:** client code and ten saved real responses read [GH].

### S03. Penn Labs course API (`penncoursereview.com/api/base/...`)

- **Owner:** Penn Labs (student organisation); data imported from Penn's
  OpenData registrar API (S06).
- **Endpoints** (already used by `catalog.ts`): `/{semester}/courses/`
  (list), `/{semester}/courses/{SUBJ-NUM}/` (detail),
  `/{semester}/search/courses/?attributes=WUGE`, `/attributes/`,
  `/restrictions/`, `/{semester}/search/sections/`,
  `/{semester}/pre-ngss-requirements/`; semester is `2027A` (A spring, B
  summer, C fall), `current` or `all`. API docs are served at
  `/api/documentation/` with an OpenAPI schema at `/api/openapi/` ([GH]
  `backend/PennCourses/urls.py`; not fetched).
- **Response shape, real** ([RUN] 2026-11-16): the list of 2027A is an
  array of 3,462 courses, 3,987,675 bytes, each `{id, title, description,
  semester, num_sections, course_quality, instructor_quality, difficulty,
  work_required, recommendation_score, credits}`. Detail adds
  `syllabus_url, prerequisites, crosslistings, pre_ngss_requirements,
  attributes[{code, school, description}], sections[...]`. `/attributes/`
  is an array of **870** `{code, school, description}` records, e.g.
  `{"code": "WUCN", "school": "WH", "description": "Wharton Core
  Cross-Cultural Perspective: Non-US"}`, `{"code": "AULL", "school": "SAS",
  "description": "COL-COURSE-Last Language"}`.
- **Re-checked facts:** no sign-in needed (confirmed [RUN]);
  `prerequisites` was `""` for both BEPP 2500 and CIS 4000 ([RUN]); the
  list endpoint carries no attributes; an attribute search returned 10
  WUGE courses for 2027A ([RUN]); a full dry run read 2,218 courses in
  7.7 s ([RUN]).
- **Authority:** secondary (a mirror), but the only attribute index
  reachable from a runner today. Lags the registrar by Penn Labs' import
  schedule. Courses only appear in a semester in which they have sections.
- **Caveats found:** grade-mode attributes ride along as attributes
  (`QS`, `QP`, `QU`, school `MODE`), so "pass/fail offered" is readable
  here; the `school` on an attribute is inferred from the code's first
  letters ([GH] `courses/util.py`, `identify_school`), not supplied by
  Penn.
- **Terms:** code is MIT; no data licence is stated. Unresolved.

### S04. Penn Labs "Penn Degree Plan" (code, hand data and a gated API)

- **Owner:** Penn Labs. Repo `pennlabs/penn-courses`, `backend/degree/`
  (13,789 lines on 2026-11-25).
- **What it holds that Penn does not publish in one place:**
  - A parser for S01's XML (`utils/parse_path_audit.py`, 960 lines) and
    the reading of scribe sharing semantics (`utils/double_counts.py`).
  - **Hand-encoded coordinated dual degrees**
    (`data/dual_programs/{mt,huntsman,lsm,viper}.py`): which single-degree
    blocks each program suppresses, the replacement rules, CU floors
    (`MT 46, LSM 43, VIPER 46`), allowed major pairs, VIPER's approved
    energy-course list, with the program page each was read from.
  - Plan-level policy the audits cannot state (`utils/composition.py`,
    `utils/degree_logic.py`): `max_degree_claims = 2`,
    `graduate_cu_limit = 3`, `min_graduate_number = 5000`,
    `forbid_grad_grad`.
  - A pre-med requirement set from Career Services (`data/premed.py`).
- **API:** `/api/degree/degrees`, `/majors`, `/minors`, `/dual-programs`,
  `/degreeplans` and friends. The degree, major, minor, dual-program and plan viewsets still carry
  `permission_classes = [IsAuthenticated & InPDPBeta]` on 2026-11-25
  ([GH] `degree/views.py`), so it is **not public**: a Penn Labs account
  approved for the beta is required.
- **How they obtained the data:** from S01 (current), from Degree Works
  with a signed-in student's token (older, `fetch_degrees.py`,
  `degreeworks_client.py`, base
  `https://degreeworks-prod-j.isc-seo.upenn.edu:9904`), and by hand for
  the coordinated programs.
- **Authority:** unofficial, careful, current (commits weekly). Its
  comments state its own assumptions, e.g. "within a block, courses are
  exclusive unless THISBLOCK says otherwise. That reading is what makes
  THISBLOCK meaningful, but the audit does not state it".
- **Licence:** MIT for code. The hand data files are code under that
  licence; the scraped requirement data is Penn's.
- **Verified:** [GH] read 2026-11-26.

### S05. Seven real audit XML templates in Penn Labs' tests

- `backend/tests/degree/fixtures/`: `BIOL-BA.xml`, `CMPE-BSE-2026.xml`,
  `CSCI-BA.xml`, `CSCI-BSE-NCON.xml`, `CSCI-MINOR.xml`, `MATH-BA-GEN.xml`,
  `MEAM-BSE-GEN.xml` ("real audits trimmed to the blocks under test",
  catalog year 2027 on most blocks). [GH]. These are the only S01
  responses this research could read, and the source of every "verified
  from scribe" rule in `RULES.md`. They are also ready-made parser test
  fixtures (MIT).

### S06. Penn OpenData registrar API (ISC)

- **Owner:** Penn ISC and the Registrar.
- **What it holds:** the registrar's section feed:
  `course_section_search`, `course_section_history_search`,
  `course_section_status/{term}/all`, with per section `attributes[]
  {attribute_code, attribute_desc}`, `crosslistings`, `credits`,
  `minimum_credit`/`maximum_credit`, `credit_connector`,
  `course_terms_offered` (seen value: "1 term: Either"), `course_level`,
  restrictions (`restriction_code`, `restriction_type`, `incl_excl_ind`),
  linked courses. Shape read from [GH] Penn Labs
  `tests/courses/test-opendata.json` and `courses/registrar.py`.
- **Access:** OAuth2 client credentials issued by Penn
  (`OPEN_DATA_CLIENT_ID`); documentation reported at
  `https://esb.isc-seo.upenn.edu/8091/documentation` [SEARCH]. Not public.
  Smooth has no credential; asking for one is a person's step and would
  put the project in front of ISC.
- **Authority:** the registrar's own feed; what S03 mirrors.
- **Verified:** shape [GH]; portal UNREACHED.

### S07. CIS Advising Handbook (source repository and site)

- **Owner:** Penn CIS department advising team. Site
  `https://advising.cis.upenn.edu`; source
  `github.com/cis-advising-handbook/cis-advising-handbook.github.io`
  (commit `e705b22`, 2026-11-09, "add STAT4800: unrestricted"; licence
  header "Copyright 2023 University of Pennsylvania", BSD-style).
- **Machine-readable files** (all [GH]):
  - `assets/json/37cu_csci_tech_elective_list.json`: 510 records
    `{course4d, title, status_prefall24, status}`; status counts on
    2026-11-09: unrestricted 298, no 143, restricted 56, ask 13;
    pre-fall-2024 statuses yes 350, no 147, ask 13. Its git history is the
    change log ("Changes since September 2022 are on github").
  - `assets/json/3d_to_4d_course_translation.json`: 9,628 entries
    `{"AAMW 425": {"_4d": "AAMW 6425", "title": ...}}`, the old 3-digit to
    4-digit course crosswalk.
  - `core.json`, `public.json`: CIS course directory by area with course
    site links; `_data/*.yml` area lists.
  - **Sibling files asked about:** there is no 40-CU JSON; the 40-CU
    technical-elective rules survive only in an HTML comment in
    `tech-electives.md`. No per-major JSON for ASCS, ARIN, NETS or DMD.
- **Prose pages with rules:** `tech-electives.md`, `cu-limit.md`,
  `minor.md`, `concentration.md`, `degree-requirements.md`, `xcat.md`,
  `senior-audit.md`, `worksheet.md`, `skip-1100.md`, `senior-thesis.md`,
  `lawm-5060.md`.
- **Authority:** official for CIS degrees; defers to the SEAS handbook and
  the catalog for school rules.
- **Reach:** GitHub from anywhere; the site from a runner (200, [RUN]).

### S08. IRS, "Institutional Requirements System" (`github.com/upenn/irs`)

- **Owner:** CIS Academic Advising, under the `upenn` GitHub organisation.
  One 5,838-line TypeScript file, `degree_requirements.ts` (commit
  `8f15aa5`, 2026-10-27). Live at `https://advising.cis.upenn.edu/irs`.
- **What it holds:** "an attempt to represent rulebooks like the SEAS
  Undergraduate Handbook, the CIS Advising Handbook and the Registrar's
  degree requirements in code instead of prose", for CSCI, ASCS, CMPE,
  ARIN, VIC, NETS, DMD, BE, EE, SSE, the CIS and DATS minors and four
  masters. In particular, as code:
  - the SEAS handbook's course categories (`suhSaysMath`, `suhSaysNatSci`,
    `suhSaysEngr`, `suhSaysSS`, `suhSaysHum`, `suhSaysTbs`) and the
    **No-Credit list** (`suhSaysNoCredit`);
  - the SS/H depth requirement, writing seminars mapped to H, SS or TBS,
    ethics courses, project electives, NETS and DMD elective lists, DATS
    minor buckets, 1.5-CU lab courses and 0.5-CU labs;
  - a cap of three cross-degree double counts for accelerated masters;
  - the attribute enum it trusts (`EUMA, EUNS, EUMS (deprecated), EUNG,
    EUSS, EUHS, EUTB, EUNE, AUWR, AULA, AULL, EUCR, EUCU, EMRT, EMRE`).
- **Also reveals:** Degree Works is directly reachable by students at
  `https://degreeworks-prod-j.isc-seo.upenn.edu:9904/worksheets` "on-campus
  or on the Penn VPN", with a **Class History** page; advisors also have a
  **Diagnostics Report** carrying each course's attributes ("Students
  don't have access to the Diagnostics Report"). And that the school
  works from a **course-attribute spreadsheet** exported from "Curriculum
  Manager" (columns `Primary Course, Course Title, Course, Attributes`),
  which is not public.
- **Authority:** "an unofficial tool. The University Registrar is the
  ultimate arbiter". Written by the people who run senior audits for CIS.
- **Verified:** [GH].

### S09. Community scraper and feed: `jlumbroso/penn-path-scraper`

- **Owner:** an individual Penn CIS faculty member's public repo (commit
  `4b205b7`, 2025-10-09). Scrapes S02 daily by GitHub Actions and exports
  static JSON (`api/v1/courses/{code}/index.json`, `terms/{term}/`) for
  GitHub Pages at `jlumbroso.github.io/penn-path-scraper`.
- **Value:** the best public documentation of S02's request and response
  shapes, with real fixtures; proof that a runner could reach
  `courses.upenn.edu` in 2025. The published feed itself was not read
  (UNREACHED) and its focus is enrolment, not attributes.

### S10. The University Catalog (CourseLeaf): `catalog.upenn.edu`

- **Owner:** Office of the University Registrar. "2026-27 Undergraduate
  Catalog" per the earlier research; one search result still titled the
  full PDF "2025-26", so the year on each page must be read when fetched.
- **Sections that matter** (all [SEARCH]; none fetched):
  - `/undergraduate/programs/{slug}/`: one page per major, concentration
    and minor (e.g. `computer-science-bse`, `finance-bs`,
    `international-studies-ba`, `nursing-bsn`, `nutrition-science-bsn`),
    each with a `{slug}.pdf` print twin. Requirement tables name
    attributes in words ("One course unit with attribute WUTI required").
  - `/undergraduate/{arts-sciences|engineering-applied-science|wharton|nursing}/curriculum/`
    and `/majors/`, `/minors/`; College sectors at
    `/undergraduate/arts-sciences/curriculum/general-education/sectors/`.
  - `/undergraduate/interdisciplinary/` and
    `/undergraduate/interdisciplinary/coordinated-dual-degree/`.
  - `/undergraduate/policies-procedures/{course-exam,grade-gpa,transfers}/`
    and `/pennbook/` (university policies).
  - `/undergraduate/academic-resources/scholars/`.
  - `/attributes/` ("Course Attributes A-Z") and `/attributes/{code}/`
    (the courses carrying one attribute, with `{code}.pdf` and an
    all-in-one `/attributes/attributes.pdf`).
  - `/courses/{subject}/` (course descriptions; mutually-exclusive notes
    live here, e.g. STAT) and `/courses/courses.pdf`.
  - `/undergraduate/undergraduate.pdf` (whole undergraduate catalog),
    `/archive/` (prior years' catalogs, HTML and PDF), `/azindex/`
    (lists yearly addenda), `/course-search/`, `/search/?P=CODE`.
- **Mirrors:** `https://upenn-public.courseleaf.com/attributes/` returned
  the same "Course Attributes A-Z" page title, and
  `https://upenn-preview.courseleaf.com/` shows a next-year preview
  (`/courses/`, `/undergraduate/programs/meam-minor/`) [SEARCH]. These
  are CourseLeaf's own hosts and may not sit behind Penn's bot wall.
- **Machine endpoints:** UNVERIFIED for Penn. CourseLeaf catalogs
  commonly answer `/ribbit/index.cgi?page=getcourse.rjs&code=CIS%201210`
  (the course "bubble" XML) and `{page}/index.xml`; a search found no
  confirmation either way and CourseLeaf's documented API ("CLAPI") is
  admin-gated at other schools. Test from a browser.
- **Access:** public. **On 2026-11-16 GitHub runners got `202` with 0
  bytes on every catalog URL** ([RUN]: `202 0B attributes-index.html`, the
  same for 4 program pages, 18 attribute pages and 18 course pages), which
  is a bot-challenge response, not content. **On 2026-11-26 a runner read
  17 catalog pages live with a browser User-Agent** (the policy pages, the
  Wharton and Nursing curriculum pages, program pages such as
  `artificial-intelligence-bse` and `international-studies-ba`), so the
  catalog is reachable from a runner with the right headers. The PDFs were
  not tried.
- **Authority:** the registrar's definitive statement of requirements per
  catalog year ("The University Registrar is the ultimate arbiter", S08).
  Prose, so weaker than S01 for machine use, but it is where footnotes
  and "by petition" notes live.
- **Changes:** yearly edition (announced each July in the Almanac), with
  addenda.

### S11. The 3-digit to 4-digit crosswalk

- Registrar's crosswalk CSV (pipe-delimited, columns `SRS_SUBJ_CODE,
  SRS_COURSE_NUMBER, NGSS_SUBJECT, NGSS_COURSE_NUMBER`) is held by Penn
  Labs in a private S3 bucket ([GH] `load_crosswalk.py`). The public
  equivalent is S07's `3d_to_4d_course_translation.json` (9,628 rows,
  "a best-effort attempt"). Needed for any pre-2022 history and for old
  rule texts. Effective date of 4-digit numbers: Summer 2022.

### S12. XCAT, the External Credit Approval Tool

- **Owner:** the College Office; used by all four undergraduate schools.
  Info pages `college.upenn.edu/.../xcat-external-credit-approval-tool`,
  `computing.sas.upenn.edu/xcat` [SEARCH].
- **What it holds:** each student's requests and departments' decisions
  for transfer, credit-away and study-abroad courses, plus departmental
  "precedents" (pre-approved equivalencies). PennKey only. Not a public
  equivalency table.
- **Gap it fills:** what an outside course becomes at Penn. Only a
  signed-in student sees it; see `OPEN-QUESTIONS.md`.

### S13. Penn Course Review (reviews)

- Ratings (`course_quality`, `difficulty`, `work_required`) ride on S03
  for free; the review endpoints proper need a Penn Labs login. Not needed
  for rules; useful only for ranking equal choices.

### S14. Degree Works itself (signed-in)

- Three doors, all needing PennKey: (a) Path@Penn's Degree Audit and
  Explore Programs (what the app drives through `PathPortal`; the audit
  arrives as CourseLeaf's translation, `page=dgw-server`); (b) the Degree
  Works dashboard at `degreeworks-prod-j.isc-seo.upenn.edu:9904` (campus
  or VPN; Class History for students per S08; its `/api/audit` JSON is
  what Penn Labs' old client read); (c) advisor-only views (Diagnostics
  Report with attributes).
- **What only it holds:** the student's applied courses, exceptions and
  petitions already granted, in-progress work, the "fall-through" list,
  and how the engine actually resolved sharing for this student.
- Whether Penn's Degree Works exposes **Look Ahead**, a GPA calculator or
  saved plans to students is UNVERIFIED (SRFS lists quick-reference
  guides named "Access your Degree Audit", "Explore Programs", "PATH
  Plans" [SEARCH]; none read).

### S15. Wharton syllabi service

- `https://apps.wharton.upenn.edu/syllabi/?term=202710&course=BEPP2500006`
  appeared as a `syllabus_url` in S03 [RUN]. Syllabi state prerequisites
  and incompatible courses in prose. Not explored; UNREACHED.

---

## B. Official prose sources, by owner

### S16. Catalog policy pages (university level)

`catalog.upenn.edu/undergraduate/policies-procedures/course-exam/`
(add/drop, auditing, course credit, withdrawal; course numbering),
`/grade-gpa/` (standing; "students enrolled in more than one school must
meet both schools' rules"), `/transfers/` (transfer credit before
enrolling versus "equivalent credit" while enrolled; internal transfer),
and `/pennbook/`. [SEARCH]. Authority: university-wide, each defers to the
schools for limits.

### S17. Registrar (SRFS) pages

`srfs.upenn.edu/student-records/transcript-key` (course-number levels,
"Effective Summer 2022"), `/student-records/external-credit`,
`/registration-catalog-calendar/rosters-timetables`,
`/quick-reference-guides-qrgs-students` (Path guides),
`/registrar/studentforms`, `/path-at-penn`; the NGSS project site
`ngss.srfs.upenn.edu`. [SEARCH].

### S18. Admissions: pre-college credit

`admissions.upenn.edu/how-to-apply/first-year-applicants/pre-college-credits`
(the AP/IB/A-level chart; e.g. AP Calculus BC 5 gives MATH 1400 for
students entering 2024 and earlier and MATH 1300 from 2025) and
`/transfer-applicants/eligibility-credit-guidelines`. [SEARCH]. Keyed by
entering year, which matters for the planner.

### S19. College of Arts and Sciences: policy site

`www.college.upenn.edu/advising-resources/policies-and-procedures/...`:
`policies-governing-curriculum/policies-governing-foundational-approaches`,
`.../policies-governing-major-requirement`,
`.../arts-and-sciences-cu-total-cu-sector-completed-major-concentration`
(a per-major table of A&S CU, total CU and the sector the major
auto-completes),
`policies-governing-courses-and-registration/policies-governing-double-counting-courses`,
`.../courseload` (load limits and the mutually-exclusive course list),
`policies-governing-academic-options/policies-governing-dual-degree`,
`policies-governing-graduation`; shortcuts `/degree-requirements`,
`/dual-degree`, `/pass-fail`, `/equivalent-credit`, `/ap-equivalence`,
`/double-counting-major-courses`, `/node/27` ("Sector Courses
Auto-completed by Major"). [SEARCH]. In the `penn-dashboard` environment's
allowlist.

### S20. College policy books, one per graduating class (PDF)

`www.college.upenn.edu/sites/default/files/files/C16.pdf`, `C19.pdf`,
`C21-2.pdf`, `C22-2.pdf`, `C23.pdf`, `C24.pdf`,
`Class%20of%202025%20Policies%20Final.pdf`, `C27policybookV3.pdf`, and
`/sites/default/files/2026-05/C29policybookFormatting2025Final.pdf`.
[SEARCH]. **This is the College's own versioning by cohort**: the rule
that applies to a student is the one in the book for their class. C26,
C28 and C30 were not found by search and probably exist.

### S21. College: new curriculum for the Class of 2031 and later

`www.college.upenn.edu/academics/new-curriculum-class-2031-later` with
`/new-curriculum-foundations` and `/new-curriculum-distribution`, and
`/collegefoundations` (the pilot). [SEARCH]. "applies to students
beginning as first-years in Fall 2027 and beyond". A second requirement
model the planner must be able to hold beside sectors and foundations.

### S22. SEAS Undergraduate Student Handbook

Current host `academics.engineering.upenn.edu/ugrad/student-handbook/`
with `academic-policies/` (`enrollment/`,
`transfer-academic-opportunities/`, `.../advanced-placement/`),
`courses-registrations/` (`course-requirements/social-science-and-humanities-courses/`,
`course-categories/` with `free-electives/`,
`social-sciences-and-humanities-breadth/`,
`reg-procedure-info/course-numbering-system/`), `programs-options/`
(`dual-degrees-and-special-programs/`, minors, dual majors, accelerated
master's), `faq/`. Older hosts still indexed and partly stale:
`ugrad.seas.upenn.edu/student-handbook/...` (the URLs the CIS handbook
links), `academics.seas.upenn.edu`, and a dev mirror
`academics-dev.seas.upenn.edu`. [SEARCH]; the runner fetched
`.../academic-policies/enrollment/` with 200 and 44,487 bytes ([RUN]) but
the body sits in an artifact this session could not download. Authority:
definitive for SEAS categories and policies (S07 and S08 defer to it).
The old and new hosts **disagree in places** (No-Credit list details,
course-number wording), so only the current host should be quoted.

### S23. SEAS departments

`be.engineering.upenn.edu/undergraduate/curriculum/{bse-requirements,bas-requirements}/`
and `.../program-options/minoring-electives/`;
`cbe.engineering.upenn.edu` (FAQ; Course Planning Guide PDFs under
`/wp-content/uploads/`); `www.cis.upenn.edu/undergraduate/...`;
`cmpe.seas.upenn.edu/curriculum-resources/` (CMPE concentrations);
`eent.engineering.upenn.edu/academics/undergraduate-minor/`;
`www.seas.upenn.edu/dual-degrees/` and `/dual-majors/`;
`ugradadm.seas.upenn.edu/majors-program-options/`. [SEARCH]. Departments
keep the approved-elective lists that the catalog states as attributes;
Course Planning Guides (CPGs) are the per-entering-year worksheets.

### S24. Wharton: Undergrad Inside

`undergrad-inside.wharton.upenn.edu/` pages: `curriculum/`,
`requirements/`, `business-fundamentals/`, `business-breadth/`,
`liberal-arts-and-sciences/`, `las-course-list/`,
`requirements/unrestricted-electives/`, `senior-capstone/`,
`concentrations/`, `concentrations-faq/`, `double-counting-courses/`,
`incompatible-courses/`, `course-load/`, `pass-fail/`,
`foreign-language-requirement/`, `external-exam-credit/`, `math/`,
`retaking-courses/`, `failing/`, `transfer-credits/`,
`dual-degree-wharton/`, `coordinated-dual-degree/`, `itdd-faq/`,
`submatriculation/`, `first-year-registration/`. [SEARCH]; the runner
fetched four of them with 200 ([RUN]: double-counting 106,379 B,
business-breadth 116,746 B, course-load 118,980 B, foreign-language
120,616 B). Authority: Wharton's working rules, current.

### S25. Wharton Undergraduate Student Handbook (PDF, yearly)

`undergrad-inside.wharton.upenn.edu/wp-content/uploads/2025/06/2025-26_Handbook.pdf`
and `.../2024/05/2024-25_Handbook.pdf`. [SEARCH]. One document with every
Wharton policy, an AP/IB appendix and the coordinated-program pointers; a
dated edition per year, so it is the natural thing to pin a Wharton rule
to. The 2026-27 edition was not found by search.

### S26. Wharton department and program pages

`fnce.wharton.upenn.edu/programs/undergraduate/`,
`hcmg.wharton.upenn.edu/programs/undergraduate/dual-degree-nursing-wharton/`,
`undergrad.wharton.upenn.edu/{flexible-curriculum,graduate-study,faq}/`.
[SEARCH]. Concentration course lists; the public marketing site is older
than Undergrad Inside and has contradicted it (a 21/9/5/2 split).

### S27. Nursing: BSN handbook and pages

`www.nursing.upenn.edu/students/handbooks-forms/bsn-handbook/` with
`degree-requirements/`, `courses-exam-related-policies/`,
`special-academic-option-policies/`, `information-for-incoming-students/`,
and a second path for the same handbook under
`/student-services/resources/handbooks-forms-policies/bsn-handbook/`
(`academic-regulations`); `/academics/undergraduate-programs/minors/`;
`/students/courses-registration/transfer-credit/`; plan-of-study PDFs
under `/live/files/`. [SEARCH]. Two live versions of the handbook exist;
quote one and note which.

### S28. Coordinated dual-degree programs: each program's own sheet

| Program | Pages | Evidence |
|---|---|---|
| M&T (SEAS + Wharton) | `fisher.wharton.upenn.edu/learn/dual-degree/`, `/student-life/resources-for-current-students/` (points to a "Course Planning Guide" with an "M&T Wharton worksheet" and per-major Excel worksheets) | [SEARCH]; Penn Labs' encoding [GH] `mt.py` |
| Huntsman (College + Wharton) | `huntsman.upenn.edu/academics/`, `/international-studies-major/` (planning worksheet), handbook PDF `/wp-content/uploads/2019/09/Huntsman-Academic-Handbook-Updated2019.pdf` (Class of 2023, dated); catalog `programs/international-studies-ba/` | [SEARCH]; [GH] `huntsman.py` |
| LSM (College + Wharton) | `lsm.upenn.edu/curriculum/{wharton-courses,college-courses,lsm-specific-courses}`, `/information-and-suggestions-applicants` | [SEARCH]; [GH] `lsm.py` |
| VIPER (College + SEAS) | `www.viper.upenn.edu/academics/dual-degree-curriculum`, `/students/curriculum/majors`, `/students/curriculum-advising` | [SEARCH]; [GH] `viper.py` |
| NHCM (Nursing + Wharton) | `www.nursing.upenn.edu/nursing-and-healthcare-management-coordinated-dual-degree/`, `hcmg.wharton.upenn.edu/...dual-degree-nursing-wharton/` | [SEARCH] |
| All | `catalog.upenn.edu/undergraduate/interdisciplinary/coordinated-dual-degree/`, `undergrad-inside.wharton.upenn.edu/coordinated-dual-degree/` | [SEARCH], not read |

Not found as separate requirement sheets (UNVERIFIED that they exist):
the seven-year Bio-Dental program, Vagelos Molecular Life Sciences
(`vagelosmls.sas.upenn.edu/curriculum/` exists [SEARCH]), the Vagelos
Scholars. Digital Media Design, NETS, Artificial Intelligence and
Computer and Cognitive Science are SEAS majors with ordinary catalog
pages and S01 templates, not dual degrees. Benjamin Franklin Scholars /
Integrated Studies / Joseph Wharton Scholars are honours overlays
(`catalog.upenn.edu/undergraduate/academic-resources/scholars/`).

### S29. Department pages that keep their own counting rules or lists

`psychology.sas.upenn.edu/node/221` ("Double counting rules for majors
and minors") and `/more-information-minors`;
`ppe.sas.upenn.edu/study/curriculum/ppe-policies`;
`www.math.upenn.edu/undergraduate/retaking-course-college-and-university-policies`
and `/math-majors-and-minors/mathematics-major`;
`earth.sas.upenn.edu/undergraduate/minors`;
`www.english.upenn.edu/courses/undergraduate/2024/fall/attributes` (a
department listing its courses by attribute per term). [SEARCH]. The
College's rule is "Major departments may have additional rules limiting
double counting", so these pages are where the binding limit often is,
one department at a time. There is no index of them.

### S30. Language placement pages

`figs.sas.upenn.edu/placement-exams`,
`figs.sas.upenn.edu/francophone/.../wharton-language-requirement-placement`,
`spanish.sas.upenn.edu/node/172` and `/undergraduate/.../placement`,
`figs.sas.upenn.edu/italian/.../placement`,
`web.sas.upenn.edu/chinese/requirements/` and
`/chinese-placement-proficiency-exam/`. [SEARCH]. Thresholds differ by
language and by school.

### S31. Submatriculation

`provost.upenn.edu/for-staff/graduate-program-admins/submatriculation/`,
SEAS handbook `programs-options/submatriculation-engineering/`, Wharton
`submatriculation/`, College double-counting page, LPS and department
pages (`www.ling.upenn.edu/graduate/masters`,
`anthropology.sas.upenn.edu/undergraduate/submatriculation-option`).
[SEARCH].

### S32. Other official pages used as leads

`careerservices.upenn.edu/academic-planning-for-medical-school/` (pre-med
course set, via [GH] `premed.py`); `global.upenn.edu/pennabroad/studyabroad/academic-information/`;
`almanac.upenn.edu` (catalog release notices); `www.courseleaf.com/insights/case-studies/upenn/`
(CourseLeaf's account of Penn's PATH).

---

## C. Press and community (leads only)

### S33. The Daily Pennsylvanian

Per-semester lists of College courses that double count across general
education (`thedp.com/article/2026/03/penn-double-count-courses-...-fall-2026`
and one per term back to 2022); the new College curriculum
(`/2026/04/penn-college-arts-sciences-new-undergraduate-curriculum`,
`/2026/05/penn-dean-struck-...-curriculum-foundations`, `/2025/11/...kite-key`).
[SEARCH]. Useful to notice changes; never a source for a rule.

### S34. API directories and old SDKs

`apis.io` listings of Penn Labs' APIs (reports the OpenAPI spec at
`penncourseplan.com/api/openapi/`); `penn-sdk` (Python/Node),
`penn-automate/penn-opendata-api` (Go), `pennlabs/registrar` (deprecated),
`pennlabs/pcr-api` (archived 2019). [SEARCH]. Confirm S06's shape; none
adds data.

### S35. Reddit and forums

Not reached (`reddit.com` is blocked and search returned none). The one
forum hit, a ten-year-old College Confidential thread on the language
exemption score, was used only to know which official page to look for.

---

## Coverage matrix

Rows are kinds of information; columns the sources that carry them. `M` =
machine-readable, `P` = prose, `(s)` = signed-in only, blank = not there.

| Kind | S01 Path programs | S02 Path search | S03 Penn Labs API | S04/S05 Penn Labs degree | S07 CIS | S08 IRS | S10 Catalog | S19-21 College | S22-23 SEAS | S24-26 Wharton | S27 Nursing | S28 Programs | S14 Degree Works |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Requirements per program and catalog year | M | | | M (parsed) | | M (CIS, ESE, BE) | P | P | P (CPGs) | P | P | P | M(s) |
| Eligible courses: lists, ranges, wildcards, exclusions | M | | | M | M (CSCI TE) | M | P | | P | P | | P | M(s) |
| Attribute membership (which courses carry a code) | | M | M | | | partial | P (`/attributes/`) | | | P (LAS list) | | | M(s, advisors) |
| Attribute code list and names | | M (names per course) | M (870) | | | M (SEAS subset) | P (A-Z) | | | | | | |
| CU per course, variable credit | | M | M | | | M (labs) | P | | | | | | M(s) |
| Cross-listings | | M | M | | | | P | | | | | | |
| Prerequisites, corequisites | | in prose fields | field mostly empty | | | | P (descriptions) | | | P (syllabi) | | | |
| Terms offered, summer | | M (per term) | M (per term) | | | | | | | | | | |
| Level restrictions (who may enrol) | | M | M (`/restrictions/`) | M (5000+ rule) | | | P | | P | P | | | |
| Pass/fail eligibility of a course | | M (`cart_opts`) | M (`QP`) | | | | | P | P | P | P | | |
| Pass/fail limits in a requirement | M (`MAXCREDIT`) | | | | P | M | | P | P | P | P | | M(s) |
| Double counting inside one degree | M (`NONEXCLUSIVE`) | | | M | P | partial | P | P | P | P | | P | M(s) |
| Double counting across two degrees | | | | M (hand) | | M (3 for masters) | | P | P | P | | P | |
| Major versus minor counting | M (`STANDALONEBLOCK`) | | | M | P | | | P | P | P | P | | |
| Coordinated dual-degree variants | | | | M (hand: 4 of 5) | | | P | | P | P | P | P | M(s) |
| Minimum CU, residency, GPA floors | M (`CLASSESCREDITS`, `MINRES`, `MINGPA`) | | | M | | | P | P | P | P | P | P | M(s) |
| Courses that never count (no-credit) | M (`MAXCLASS 0`) | | | | | M | | | P | | | | |
| Mutually exclusive courses | | | | | | partial | P (course pages) | P | | P (incompatible list) | | | |
| Load limits, overload approval | | | | | P | | | P | P | P | P | | |
| Summer limits | | | | | | | | P (credit away) | P | not found | P | | |
| AP / IB / transfer / study abroad | M (transfer ban per block) | | | M | P | | P | P | P | P | P | | (s) XCAT |
| Language requirement and placement | M (AULL, WUFL) | | | | | | | P | | P | P | | |
| Sequencing (capstone, senior design) | | | | | P | partial | P | | | P | | P | |
| Petitions and who grants them | | | | | P | | | P | P | P | | | |
| 3-digit to 4-digit crosswalk | | | | (S11) | M | M (uses it) | | | | | | | |
| Cohort keying (which rule for which class) | M (`Cat_yr_start`) | | | M | M (pre/post Fall 2024) | M | per edition | per class book | per CPG | per handbook year | per class | | M(s) |

## What no source provides

1. **Structured prerequisites.** Free text at best (course descriptions,
   syllabi); Penn Labs' field is mostly empty. Nothing lists corequisites
   as data.
2. **A typical-offering pattern.** "Offered every fall" is only inferable
   from past terms in S02/S03; the OpenData field `course_terms_offered`
   exists but needs credentials.
3. **Cross-degree double counting as data.** Each school states it in
   prose; only Penn Labs encodes it, by hand, for four coordinated
   programs. The uncoordinated case (the owner's) is prose in two
   handbooks that must be read together.
4. **Which petitions are routinely granted.** Advisors' practice is
   unwritten. The planner's "petition" label can cite the rule that
   requires approval, never the odds.
5. **Coordinated-program audits in public form.** Path's public templates
   are single-degree. M&T, LSM, NHCM and Huntsman variants exist only in a
   signed-in student's audit or what-if (Penn Labs read
   `WU_BS_MANT` and `WU_BS_MAT_U` that way).
6. **A public equivalency table** for transfer and study-abroad courses
   (XCAT is per-student).
7. **A complete index of department-level double-counting rules**
   (psychology, PPE and others each keep their own page).
8. **Placement outcomes.** What level a student places into is the
   department's exam result; no source predicts it.
9. **Wharton's summer limit and SEAS-versus-Wharton governance for a
   dual-degree student's load.** Not found in any page reached by search.
10. **Terms of use for scraping** `courses.upenn.edu` and
    `catalog.upenn.edu`, and a data licence from Penn Labs.

## Fetch list for a runner or the `penn-dashboard` environment

Hosts to allow that the saved environment lacks:
`courses.upenn.edu`, `undergrad-inside.wharton.upenn.edu`,
`academics.engineering.upenn.edu`, `www.nursing.upenn.edu`,
`fisher.wharton.upenn.edu`, `huntsman.upenn.edu`, `lsm.upenn.edu`,
`www.viper.upenn.edu`, `hcmg.wharton.upenn.edu`, `admissions.upenn.edu`,
`upenn-public.courseleaf.com`, `upenn-preview.courseleaf.com`,
`be.engineering.upenn.edu`, `psychology.sas.upenn.edu`,
`ppe.sas.upenn.edu`, `figs.sas.upenn.edu`, `provost.upenn.edu`.

First requests, in order of value: (1) S01 `programs-v2-list` for the
current term, then `programs-v2-info` for `CSCI-BSE`, one Wharton
concentration and one College major; (2) `/api/base/attributes/` saved
whole (870 rows); (3) the Wharton handbook PDF; (4) the SEAS handbook
pages named in S22; (5) the College double-counting, courseload, dual
degree and per-major table pages in S19 and the C29 policy book;
(6) `upenn-public.courseleaf.com/attributes/` to see whether the mirror
escapes the 202.
