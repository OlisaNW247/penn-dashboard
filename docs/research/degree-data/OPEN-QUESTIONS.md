# Open questions and captures (2026-11-26)

What phase 1 could not settle, what the owner can capture (signed in or
simply in a browser), and what only an advisor can say. `SOURCES.md`
explains why so much is unsettled: this session could reach GitHub and
web-search summaries, and no Penn page.

## 1. Captures the owner can do signed in

Ordered by value to the planner. Rules for every capture: do it in your
own browser; this project never handles your PennKey. Before anything
enters the repo or a chat, **remove or mask**: your name, Penn ID,
PennKey, email, date of birth, advisor names, every grade and GPA, and
any token (the 32-character Path token in POST bodies, `Authorization`
or `X-AUTH-TOKEN` headers, cookies). Course codes you took are personal
too: for shape captures replace them with invented codes, or keep the
capture off the repo and describe it. A capture is used to learn a
shape or a rule, never committed as data.

To read a network response: open the browser's developer tools, Network
tab, filter "Fetch/XHR", do the action, click the request, copy the
Response (and the request Payload when asked).

### 1.1 Your own audit, raw (highest value)

- **Where:** `https://courses.upenn.edu/` (Path@Penn), sign in, Degree
  Audit. In Network, the POST whose URL contains `page=dgw-server`.
- **Copy:** the full response JSON for one degree, and the request
  payload's key names (not the token value).
- **Why:** the phone rebuilds the audit field by field and today sends
  blocks with an empty `value`. The planner needs to know whether Penn's
  response carries, per block, the scribe code (`Req_value`, e.g.
  `U-SEAS-SSH`, `U-WLAS`), per rule a stable id (`Rule_id`), and any
  sharing qualifiers (`NONEXCLUSIVE`, `ShareWith`), exceptions, and the
  "applied elsewhere" markers. If the codes are there, joining an audit
  to a program pack (`DESIGN.md` section 7) is exact instead of by title.
- **Mask:** name, ids, grades, GPA lines, token; replace course codes if
  the file is to be shared.
- **The easy way (2026-11-26):** paste `capture-audit-shape.js` (beside
  this file) into the browser console on Path@Penn while signed in. It
  asks the page for your audit the way the page does and prints an
  inventory of field names, with example values only for short ALL-CAPS
  codes that are not course codes and not in your record. No name, id,
  token, course, title, grade, number or sentence is printed. Tested
  against a fake page seeded with marker secrets, none of which appeared.

### 1.2 What-if audits for the coordinated programs and for Wharton

- **Where:** Path@Penn, Explore Programs (or the what-if in Degree
  Audit). Run a what-if for: a plain Wharton BS concentration; the M&T
  Wharton program (Penn Labs read it as `WU_BS_MANT` and `WU_BS_MAT_U`);
  LSM; NHCM; Huntsman's Wharton side; and one College major.
- **Copy:** each response (the audit), plus the request payload shape.
- **Why:** Path's public templates are of a single-degree student. The
  coordinated variants exist only here. No Wharton template of any kind
  was readable in phase 1, so the Wharton block codes, share targets and
  header caps (`RULES.md` section 4) are all unverified from the scribe.
- **Mask:** as 1.1. These run against your record, so they contain your
  courses.

### 1.3 The course popup inside the audit worksheet

- **Where:** in the Degree Audit worksheet, click a course code under
  "Still needed" (and one you have taken). A panel opens with the
  course's title, description, attributes, sometimes prerequisites and
  sections.
- **Copy:** the network request it makes (URL, payload) and the response.
- **Why:** structured prerequisites are the largest gap in every source
  (`SOURCES.md`, "What no source provides"). Degree Works has a
  course-information call that returns prerequisites and attributes as
  data; whether Path passes it through is unknown. One capture settles
  it.
- **Mask:** token only; this response is about a course.

### 1.4 Does Penn's what-if take future courses ("Look Ahead")?

- **Where:** Path@Penn what-if and "PATH Plans"; and, on campus or the
  Penn VPN, the Degree Works dashboard at
  `https://degreeworks-prod-j.isc-seo.upenn.edu:9904/worksheets` (the CIS
  advising tool's instructions say students can open it and use its
  three-dot menu, "Class History"; as of September 2022).
- **Look for:** a "Look Ahead" or "future classes" box, a "What-If" tab,
  a GPA calculator, saved plans. Note which exist. If a look-ahead
  exists, add one invented future course and capture the request payload.
- **Why:** if Penn's own engine will audit a planned schedule, Smooth can
  check its plan against Penn instead of against its reading of Penn.
  That would be the strongest test the planner could have.
- **Copy:** screenshots of the menus with your name masked; the request
  payload shape; whether the dashboard loads at all for a student today.
- **Mask:** as 1.1.

### 1.5 The Degree Works JSON audit (only if 1.4's dashboard opens)

- **Where:** the dashboard above; Network tab; the call to `/api/audit`.
- **Copy:** the top-level key names and one block's structure with values
  masked.
- **Why:** this is the un-translated Degree Works JSON (Penn Labs' old
  loader read it). It may carry per-class attributes and qualifier
  arrays that CourseLeaf's translation drops.

### 1.6 XCAT

- **Where:** the External Credit Approval Tool, reached from
  `https://www.college.upenn.edu/academics/academic-options/campus-options/xcat-external-credit-approval-tool`.
- **Look for:** a browsable list of pre-approved equivalencies
  ("precedents") by department or by outside school, without filing a
  request.
- **Copy:** whether such a list exists, its columns, and a few rows for
  CIS, MATH and a Wharton department.
- **Why:** it decides whether transfer and study-abroad credit can ever
  be planned from data, or only noted as "needs approval".
- **Mask:** your own requests.

### 1.7 Program worksheets behind PennKey

- **M&T:** `https://fisher.wharton.upenn.edu/student-life/resources-for-current-students/`
  names a "Course Planning Guide" with an "M&T Wharton worksheet" and an
  Excel worksheet per engineering major. Save them if they need sign-in.
- **SEAS:** the Course Planning Guide (CPG) for your entering year and
  major, from your department or Path. The handbook's minor rule is
  written in terms of "specified" CPG courses.
- **Huntsman / LSM / NHCM:** each program's planning worksheet, if a
  friend in the program can share the blank form.
- **Why:** these are the requirement sheets for programs the public
  templates do not cover. Blank forms contain nothing personal.

### 1.8 Penn Degree Plan (Penn Labs), if you have beta access

- **Where:** Penn Labs' Penn Degree Plan, signed in with your Penn Labs
  account.
- **Look for:** whether your account is in the beta; what the app shows
  as double-count rules for your two degrees; whether it handles an
  uncoordinated dual degree at all.
- **Why:** a second independent reading of the same rules, and the
  opening for the conversation in section 4.

## 2. Public pages this session could not fetch, which the owner can open and save

No sign-in needed. "Save" means File, Save As (HTML) or download the PDF.
A GitHub runner could fetch most of these too; the catalog pages answered
runners with an empty 202 on 2026-11-16, so those need a browser.

| # | What | URL | Why |
|---|---|---|---|
| 1 | Path@Penn program templates (a console call, signed out, in a private window on `courses.upenn.edu`) | see the snippet below | Confirms the most important source (S01) is live and public, and yields the CSCI and Wharton templates |
| 2 | Wharton Undergraduate Handbook 2025-26 (and 2026-27 if posted) | `https://undergrad-inside.wharton.upenn.edu/wp-content/uploads/2025/06/2025-26_Handbook.pdf` | One file with every Wharton rule in `RULES.md` section 4, including the GEBS and pass/fail conflicts |
| 3 | The whole attribute index as one PDF | `https://catalog.upenn.edu/attributes/attributes.pdf` and `https://catalog.upenn.edu/attributes/` | The official code list and names |
| 4 | The undergraduate catalog PDF | `https://catalog.upenn.edu/undergraduate/undergraduate.pdf` | Every program page and policy page in one file; note the year on its cover |
| 5 | Your programs' catalog pages | `https://catalog.upenn.edu/undergraduate/programs/computer-science-bse/`, `.../wharton/curriculum/`, your concentration's page | Footnotes and "by petition" notes |
| 6 | SEAS handbook pages | `https://academics.engineering.upenn.edu/ugrad/student-handbook/academic-policies/enrollment/`, `.../programs-options/dual-degrees-and-special-programs/`, `.../courses-registrations/course-categories/` (and its Free Electives page), `.../course-requirements/social-science-and-humanities-courses/`, `.../academic-policies/transfer-academic-opportunities/` | Summer limit, 46-CU floor, no-credit list, SSH rules, credit away |
| 7 | College policy book for a current class and the double-counting page | `https://www.college.upenn.edu/sites/default/files/2026-05/C29policybookFormatting2025Final.pdf`; `https://www.college.upenn.edu/advising-resources/policies-and-procedures/policies-governing-courses-and-registration/policies-governing-double-counting-courses`; the per-major table at `.../policies-governing-curriculum/arts-and-sciences-cu-total-cu-sector-completed-major-concentration` | Major and sector rules by class; submatriculation cap conflict |
| 8 | Wharton pages | `.../double-counting-courses/`, `.../incompatible-courses/`, `.../course-load/`, `.../senior-capstone/`, `.../business-breadth/`, `.../pass-fail/`, `.../dual-degree-wharton/`, `.../external-exam-credit/` under `https://undergrad-inside.wharton.upenn.edu` | Exact wording for the records the planner uses |
| 9 | Catalog mirrors | `https://upenn-public.courseleaf.com/attributes/`, `https://upenn-preview.courseleaf.com/` | If these load without a challenge, a runner can use them |
| 10 | Catalog machine endpoints (guesses to test) | `https://catalog.upenn.edu/ribbit/index.cgi?page=getcourse.rjs&code=CIS%201210`, `https://catalog.upenn.edu/undergraduate/programs/computer-science-bse/index.xml` | Whether the catalog has an XML door; unverified |
| 11 | Catalog archive index | `https://catalog.upenn.edu/archive/` | Which prior years exist, in which formats |
| 12 | Penn Labs API docs | `https://penncoursereview.com/api/documentation/` | The authoritative endpoint list and any terms |
| 13 | Path course search with an attribute filter | on `https://courses.upenn.edu/`, signed out, choose a "Course Attribute" in the search and capture the `route=search` payload | The criteria field name for attribute search, so a runner can list an attribute's courses from Penn directly |
| 14 | Nursing BSN handbook | `https://www.nursing.upenn.edu/students/handbooks-forms/bsn-handbook/degree-requirements/` and `.../courses-exam-related-policies/` | Nursing rules and the new sector names |
| 15 | Coordinated-program pages | the URLs in `SOURCES.md` S28 | Each program's own sheet |

Console snippet for row 1 (paste in the developer console on
`https://courses.upenn.edu/`, signed out; it mirrors what Penn Labs'
open-source client sends):

```js
const call = (route, payload) =>
  fetch(`/api/?page=fose&route=${route}`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-requested-with": "XMLHttpRequest" },
    body: encodeURIComponent(JSON.stringify(payload)),
  }).then((r) => r.json());
const list = await call("programs-v2-list", { srcdb: "202630", programsType: "" });
console.log(list.length, list.slice(0, 5));
const info = await call("programs-v2-info", { srcdb: "202630", programCode: "CSCI-BSE" });
console.log(Object.keys(info)); copy(info.audit_xml);   // then paste into a file
```

If it works signed out, the response contains no student data (a dummy
record), and can be shared as is.

## 3. What could not be settled

1. **Is `programs-v2` reachable from a GitHub runner, and for how long?**
   Everything in `DESIGN.md` layer 2 rests on it. Penn Labs runs it from
   their servers; this session could not call it. Test: row 1 above, then
   the same from `fetch.mjs`.
2. **What are the terms?** No robots file or terms page for
   `courses.upenn.edu` or `catalog.upenn.edu` was read. Penn Labs' code
   is MIT; their data carries no licence. Whether a public repository may
   hold a derived copy of Penn's requirement data is a question for Penn
   (the Registrar or ISC) and a courtesy question for Penn Labs.
3. **Exact wording of 67 rules.** Every REPORTED rule in `RULES.md` needs
   its page read. The dozen the planner already depends on first: WH-02,
   WH-03, WH-05, WH-06, WH-07, WH-08, SEAS-17, SEAS-28, SEAS-30, SEAS-32,
   SEAS-34, CAS-09.
4. **SEAS summer limit.** Reported as 4 CU per summer (2 per half
   session). `policy.ts` holds 2 a summer and 4 in all, "read from the
   official SEAS and Wharton pages on 2026-11-15". One of the two
   readings is wrong; the runner's saved `seas-enrollment.html` (artifact
   of run 43781154209) has the answer.
5. **Wharton's summer limit and Wharton's CU total for a dual degree.**
   Not found anywhere.
6. **Which school's load rule governs a student in two schools.** SEAS
   allows a department to raise to 6.5; Wharton sends anything over 5.5
   to its Petitions Committee. For an uncoordinated dual degree the home
   school presumably decides; not stated in anything read.
7. **GEBS and TIA double counting.** WH-06 is a search summary of the
   handbook. Does the bar also cover Technology, Innovation and
   Analytics? Is a concentration course that carries `WUGE` simply
   counted once, or may an advisor allow both?
8. **College: which class changed from "one major course may count for a
   sector" to "the major auto-completes a sector"**, and the
   submatriculation cap (4 CU on the page, "eight courses" in a summary
   of the C29 book).
9. **The full attribute list.** 870 codes exist in Penn Labs' API; this
   session saw the names of about 60. One runner fetch settles it. Then:
   what `EURO`, `WUNG`, `NUTR` mean, and the codes for Nursing's new
   sectors.
10. **Whether the catalog has a machine door** (`ribbit`, `index.xml`),
    and whether CourseLeaf's mirror hosts escape the 202.
11. **Structured prerequisites.** See capture 1.3. If none exist, the
    planner keeps parsing prose and labelling the result "unverified".
12. **How faithfully the template's IfStmt branches can be resolved**
    without a student record (Penn Labs assumes "a sufficiently high GPA"
    and "the student does not have" an attribute).
13. **Catalog-year mapping.** The audit carries `catalogYear: "202430"`
    and the scribe `Cat_yr_start="2027"` for srcdb 202630. The rule
    (term to catalog year) is inferred from Penn Labs' comment, not read
    from Penn.
14. **Nursing in the scribe.** No Nursing template was read; whether
    BSN sectors appear as attribute rules like the College's is unknown.
15. **How current the CIS handbook's "worksheets have known issues" page
    is** (dated September 2022). It bears on how much to trust where an
    audit placed a course.

## 4. What needs a person at Penn

| Question | Who | Why it cannot be read |
|---|---|---|
| For a CS BSE plus Wharton BS uncoordinated dual degree: the Wharton CU total, which Wharton requirements an engineering course may fill "if approved for Wharton", and who approves | Wharton Undergraduate Division advisor | WH-12 says "provided the courses are approved for Wharton"; the approved set is not published |
| May a math course count as both the Calc III / linear algebra requirement and a technical elective; may a concentration course also fill GEBS or TIA | CIS undergraduate coordinator; Wharton advisor | `policy.ts` offers these as petitions; the scribe says no share by default; practice is unwritten |
| Which load rule applies to a dual-degree student, and whether 6.5 CU is routinely approved | Home-school advisor | Section 3 item 6 |
| Summer: how many CU a Wharton student may take, and whether Penn summer courses count toward the dual-degree floor | Wharton advisor | Not published where search could find it |
| Whether a language placement result can be planned on (placing into the second semester) | The language department | Placement is individual |
| May Smooth read and redistribute the public program templates and catalog data, and at what rate | Office of the University Registrar, ISC | Terms unread; the endpoint is undocumented |
| Would Penn Labs share their parsed degree data or let Smooth use the Penn Degree Plan API, and under what terms | Penn Labs directors | Their API is beta-gated and unlicensed for data |
| Is there a registrar export of course attributes (IRS reads a "Curriculum Manager" spreadsheet) that a student project may have | SEAS Academic Services or the Registrar | Staff-only today |
| OpenData credentials for a student project | ISC (`opendata-help@lists.upenn.edu` per its documentation, reported) | Needed for `course_terms_offered` and the registrar's own feed |

## 5. Leads not followed, so none is dropped

- The Wharton syllabi service (`apps.wharton.upenn.edu/syllabi/`) for
  prerequisites in prose.
- `jlumbroso.github.io/penn-path-scraper/api/v1/` (a community JSON feed
  of Path search data; read the repo, not the feed).
- Penn Labs' OpenAPI spec (reported at `penncourseplan.com/api/openapi/`).
- College policy books for classes 2026, 2028 and 2030 (URLs not found).
- Department pages beyond Psychology and PPE that set their own
  double-counting limits (Economics, Mathematics, Biology, Cognitive
  Science are the likely ones).
- SEAS department elective lists outside CIS (ESE, MEAM, MSE, CBE, BE
  pages; BE's `minoring-electives` page).
- The seven-year Bio-Dental program, Vagelos MLS and Vagelos Scholars
  requirement sheets.
- University (inter-school) minors: no single list with rules was found;
  the catalog's `/undergraduate/interdisciplinary/` page is the place.
- Study abroad: `global.upenn.edu/pennabroad/studyabroad/academic-information/`.
- Graduation application deadlines and any time limit on the degree: not
  searched to a result (the scribe's `DWAGE > 8` cap on SEAS degrees is
  the only time rule found).
- Reddit threads (host blocked; search returned none).
- The four prior `penn-catalog` run artifacts hold fetched Wharton and
  SEAS pages (`wharton-double-counting.html` and others) that this
  session could not download; a session with artifact access, or a
  re-run that prints page text to the log, would verify several rules
  at once.
