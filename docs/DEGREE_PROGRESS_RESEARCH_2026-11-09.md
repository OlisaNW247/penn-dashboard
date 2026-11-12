# Degree progress in Smooth: research and recommendation (2026-11-09)

Research only. Nothing was built, deployed or changed live. Nobody signed
in to anything, and no student's data was fetched. Source notes with labels
and URLs are in `docs/research/degree-progress/` (an index is at
`00-INDEX.md` there). Every factual claim below carries one of three labels:
**[read]** (a page or source file was read directly), **[search]** (a search
summary only; the page itself was blocked from this container), or
**[inferred]**.

One thing to know first: this container's network refused every Penn host
(`*.upenn.edu`, including `path.at.upenn.edu`, `catalog.upenn.edu`,
`courses.upenn.edu`, `advising.cis.upenn.edu`), Penn Labs' sites, Reddit,
the Daily Pennsylvanian, Stellic and Ellucian. GitHub and Apple's developer
site were readable. So the Penn-specific claims rest on search summaries plus
Penn Labs' source code, which turned out to be the best evidence about Penn
anyway. A cloud environment named `penn-dashboard` now exists with those
hosts allowed; this session could not move onto it, but a new session started
on it can read the Penn pages directly.

## The recommendation

Build it, Penn first, **without any Path@Penn login**, in this order:

1. **Requirement templates from Path@Penn's own public endpoints.** Penn
   Labs' Penn Degree Plan does not transcribe the catalog. It POSTs to
   `https://courses.upenn.edu/api/?page=fose&route=programs-v2-list` and
   `programs-v2-info` with no credentials and receives, per program, the
   Degree Works audit XML for a dummy student (`Stu_id="*"`), which is the
   registrar's actual rule logic with no student data in it **[read]**
   (`backend/degree/utils/path_client.py` in github.com/pennlabs/penn-courses).
   That is the source Smooth should pool, parsed by a port of Penn Labs'
   MIT-licensed parser, into a public table like `catalog_courses`.
   The engine then runs the real rules, not a hand copy of them.
2. **The student's record stays on the phone and starts as a list they
   mark.** Current classes are already known from Canvas; past terms are a
   few taps of chips per semester. Later phases can seed past courses from
   Canvas (`enrollment_state=completed`, the same session model Smooth
   already uses) and accept an audit PDF the student shares.
3. **Code decides, nothing else.** The audit engine is pure Swift with a
   test per rule, like `FactApplication`. A model may only extract (for
   example a prerequisite sentence into a structure, with a verbatim quote
   and code-checked course codes) and explain. This is the project's
   existing stance and the literature read here supports it **[search]**.
4. **Never say "you will graduate".** Every screen says what Smooth's reading
   found and points at Path@Penn as the official audit, with a one-tap link.

**Is the first version worth shipping alone?** Yes, narrowly: a requirement
list with "met · in progress · open" per rule, driven by templates for a few
programs plus marked courses, is already more legible than Path@Penn's
worksheet on a phone, and it feeds the tree ("can I still do a CIS minor?").
The what-if planner is where the value is, and it is phase 3, not phase 1.

**The one finding that would change this.** If Penn or Penn Labs says the
`courses.upenn.edu` endpoints are not for third-party use, the template
source becomes hand-curated catalog rules for a handful of programs, upkeep
becomes the main cost, and the feature should shrink to "a checklist for
your declared major" or be dropped. Ask before Phase 2 (see Experiments).

## What Path@Penn offers today

- **Worksheets.** The degree audit is a checklist per declared degree, second
  major or minor, under Degree planning and audit → Degree Audit, with
  percentage bars per block for College students **[search]** (CIS advising
  `/worksheet/`, College "Interpreting your degree audit", SRFS training PDF).
- **What-if.** Nothing is called that. "Explore Programs" maps a student's
  existing coursework onto another program's worksheet **[search]**. "Path
  Plans" (Feb 2025) builds future-semester schedules and validates them
  against the primary degree only; the College calls it "a course planning
  tool, not an academic or degree planning tool" **[search]** (DP, Feb 2025).
- **Course search** is Courses@Penn at `courses.upenn.edu`, a CourseLeaf
  product (the `page=fose` API is CourseLeaf's) **[inferred from the URL
  shape; read in Penn Labs' client]**.
- **The product.** Penn runs Ellucian Banner (chosen 2013-14 under NGSS;
  Pennant is the umbrella) **[search]**. The audit is **Ellucian Degree
  Works**: Penn Labs' parser reads Degree Works XML (`Block`, `Req_type`,
  `RuleType`, `NONEXCLUSIVE` qualifiers) from Path@Penn's responses, and
  Penn Labs' older client called
  `degreeworks-prod-j.isc-seo.upenn.edu:9904/api/audit` with Degree Works'
  `X-AUTH-TOKEN` and `REFRESH_TOKEN` cookies **[read]**
  (`parse_path_audit.py`, `degreeworks_client.py`). No Penn page says so in
  words; a pre-launch job listing names "the to-be-implemented Ellucian
  Degree Works product" **[search]**.
- **Sign-in.** PennKey through Penn WebLogin plus Duo, the same login Canvas
  at Penn documents **[search]**; that it is literally the same identity
  provider host Smooth renews is **[inferred]** and needs one phone check.
  Session lifetime: nothing published. Degree Works' own tokens at another
  school last about 90 minutes with an 8-hour refresh **[read]**
  (a student's CLI for Kennesaw State).
- **Export.** No Penn page mentions saving the audit as PDF **[search]**.
  Degree Works' standard dashboard has "Save as PDF" at other schools
  **[search]**, so it probably exists at Penn; unconfirmed.
- **Known limits, from Penn itself.** The CIS advising page (September 2022)
  says a course that satisfies a requirement can be missing from the
  worksheet, a non-qualifying one can be listed, and students should work
  from the registrar's list "until Path worksheets are more accurate"
  **[search]**. Whether that is still current is open.

## The public data

| Data | Where | Shape | Label |
|---|---|---|---|
| Degree requirements, every undergrad program, minors, masters | `courses.upenn.edu` `programs-v2-list` / `programs-v2-info` | Degree Works audit XML per program and catalog year | [read] in Penn Labs' code; live behaviour untested here |
| Course title, credits, description, **prerequisites (free text)**, attributes, sections per semester | Penn Labs API `penncoursereview.com/api/base/{semester}/courses/{CODE}/`, public | JSON; Smooth's server already calls it | [read] serializers |
| Which semesters a course ran | Same API, one row per course per semester; `parent_course` links offerings | Query past semesters | [read] |
| Catalog pages | `catalog.upenn.edu`, CourseLeaf-style, print PDFs per section | HTML and PDF, no API found | [search] |
| Penn Labs' parsed degree data | `/api/degree/degrees` etc. | Behind `IsAuthenticated & InPDPBeta`, with a comment "After Beta: remove this permission entirely" | [read] |

Penn Labs' code is MIT-licensed **[read]**; the licence covers the code,
not Penn's data. Prerequisites are free text with no parser anywhere in
Penn Labs' backend (help text example: "CIS 120, 160") **[read]**. Penn's
own OpenData API needs Penn-issued credentials **[search]**. The College's
general education is being revised ("College Foundations", approved May
2026, from the Class of 2031) **[search]**, so templates must be keyed by
catalog year, which the audit XML carries (`Cat_yr_start`) **[read]**.

## Getting the student's record onto the phone

Ranked by value against risk and cost. Confidence is in how sure the
research is about the facts, not about the product call.

| Route | Value | Risk | Cost | Confidence |
|---|---|---|---|---|
| A. Mark courses taken (chips per term; current classes prefilled from Canvas) | Medium: enough for progress and what-if | None new | Low: UI plus a store | High |
| B. Canvas past courses (`/api/v1/courses?enrollment_state=completed&include[]=term`, student's own session) | Medium: seeds route A; no AP/transfer credit, only courses with a Canvas site | Low: same trust model as today; the app today deliberately discards past enrolments | Low–medium: one new client call, a term mapper | High on the API [read in canvas-lms source]; medium on what Penn's Canvas returns for old terms |
| C. Audit or transcript PDF the student shares | High: the official allocation, course by course | Low policy risk (the student's own file); parsing is heuristic per layout | Medium: PDFKit text, a parser, fixtures | Medium: Penn's PDF layout unseen |
| D. Read Path@Penn / Degree Works with the saved PennKey, like Canvas | Highest: live audit | Highest: 5.2.2 permission, Penn's password-sharing policy in spirit, fragile tokens and hosts, Duo in a hidden WebView | High | Medium on mechanics [read, Penn Labs' old client]; low on policy |
| E. Partnership with Penn Labs or Penn | Could unlock parsed requirements or sanctioned data | Depends on them | Low to ask | Low |

Notes on D, so nobody has to re-derive them:

- Smooth's `CanvasSessionRenewer` fills Penn's identity-provider form and
  taps Duo; the same WebLogin should reach Path@Penn, and Duo's trusted
  browser lasts about 60 days **[search]**, so a second Penn site in the same
  cookie jar would likely not re-prompt. Unverified on a phone.
- Degree Works then needs its own tokens (`X-AUTH-TOKEN`, `REFRESH_TOKEN`)
  which the browser flow sets; Penn Labs' client took them from a logged-in
  student and the team replaced that path with the public one **[read]**.
- Penn's PennKey pages say never share your password with anyone and that
  sharing violates University policy **[search]**. Smooth keeps the
  student's own password on their own phone and types it into Penn's own
  page, which is what it already does for Canvas; reading a second system
  with it widens what a compromised phone exposes. The Acceptable Use Policy
  and the student-records policy could not be read **[search]**; no Penn
  statement on scraping was found either way. Four US schools ban
  registration bots; none was found acting against a read-only audit reader
  **[search]**.
- Federal FERPA gives the student the right to inspect their own record; a
  student using their own app is not a school disclosure **[inferred]**, and
  FERPA does not grant a technical channel.

Penn already blocks student Canvas access tokens (CLAUDE.md, Traps), which
is why everything Canvas goes through the session. Route D would be the
same kind of path, with less cover.

## Privacy and the App Store

- **On-device, always:** the program chosen, catalog year, courses marked,
  the engine's allocation, overrides, any imported PDF, any Path@Penn
  session. Own SwiftData store file (the `AppliedFactStore` pattern), never
  the ledger schema, never purged on Canvas disconnect (it is the student's
  own work), not in the laptop sync's first version.
- **Pooled safely:** requirement templates per program and catalog year,
  and course facts for planning. Same class as `catalog_courses`: readable by
  every authenticated caller, written only by the server, no student column
  anywhere.
- **PRIVACY.md** needs one bullet for version 1 (drafted in note 04). If the
  tree is ever given degree facts, the "Questions you ask the tree" paragraph
  and the posture paragraph in `CLAUDE.md` change in the same commit.
- **Apple 5.1.1** (quoted in note 04) is satisfied by the bullet: the data
  comes directly from the user and stays on the phone. **5.2.2** says "ensure
  that you are specifically permitted to do so under the service's terms of
  use. Authorization must be provided upon request" **[read]**. That applies
  to reading `courses.upenn.edu` (ask first) and squarely to route D.

## Modelling requirements

What audits actually encode, and what Smooth should copy **[read, Penn Labs
parser and models; search for Scribe]**:

- A **tree** of blocks (DEGREE, MAJOR, MINOR, CONC, OTHER) and rules of type
  `Course` (N classes and/or N credits in a list), `Group` (N of these
  subrules), `Subset`, and conditionals (`IfStmt` on major, concentration,
  program, GPA).
- **Matching by filter, not only by list:** explicit codes, `DEPT @`
  wildcards, number ranges, and attributes (`@ @ (With ATTRIBUTE = AU16)`),
  with `Except` lists. Penn's sector and Foundational Approach rules are
  attribute rules **[search + read]**.
- **Double counting is explicit:** blocks are exclusive by default; a rule
  or block opts in with `ShareWith` / `NONEXCLUSIVE` naming THISBLOCK,
  ANYBLOCK, MAJOR or a block. Penn Labs adds pair caps (`max_courses`,
  `max_credits`) and plan-level caps audits cannot state (3 CU graduate
  sharing for 4+1; dual programs) **[read]**.
- **Qualifiers** like MinGrade, residency and age exist; Penn Labs drops
  them silently. Smooth should mark such a rule "approximate" instead.
- **Substitutions and exceptions** are per student, applied by advisors
  (Force Complete, Substitution, Also Allow) **[search]**; Smooth's
  equivalent is a per-student override stored on the phone.
- **Allocation** (which requirement a course counts for) is itself a
  matching problem. Penn Labs uses greedy by largest shortfall plus a
  rebalance pass, and records per course `selected`, `unselected` (eligible,
  not applied) and `legal` **[read]**. Another student planner uses max-flow
  for core and greedy for majors **[search]**. Greedy plus rebalance is
  enough to start; keep max-flow as the fallback if rebalance leaves a gap.
- **The planning half** (order, offerings, credit cap) is in nobody's audit
  model. Commercial tools validate a student's drag-and-drop plan and warn
  ("not typically offered this term") rather than generate one **[search]**.
  The sketch in note 09 shows a greedy term filler ordered by prerequisite
  chain, with fall-only and spring-only flags and a CU cap, works on a toy
  program, and exposed one gap: credit shortfalls need their own fill rule.
- **No open standard** for degree rules exists **[search]**; the comparison
  table in note 05 covers Scribe, PeopleSoft, Penn Labs, St. Olaf's
  degreepath and a Technion planner. The recommended JSON rule shape is in
  note 05 section 6: a tree, `need {courses, credits}`, a `match` with codes,
  department ranges and attributes, `share` targets, pair `caps`, and a
  `source.quote` on every rule.

**Should a model ever decide what counts?** No. Multi-constraint benchmarks
put frontier models near the floor (TravelPlanner 0.6% final pass; RuleArena
under 10% on hard real rule sets) **[search]**, and one advising system puts
prerequisites in Prolog and uses the model only to parse and explain
**[search]**. Nothing found argues against the stance in
`docs/DAY_PLANNER_RESEARCH_2026-11-03.md` Part 2. Because the audit XML is
the real rules, a model is not needed for the core at all; it is useful for
prerequisite prose, with the same guards as facts: a verbatim quote,
catalog-valid codes, and a human diff before the data ships.

## Beyond Penn

- Degree Works is on the order of several hundred US institutions,
  concentrated at Banner schools (Banner is about a quarter of North American
  student systems) **[search]**; no vendor count exists. Stellic claims 80+
  and is winning research universities (CMU, Columbia, Cornell, Johns
  Hopkins, Delaware) **[search]**; uAchieve "100+"; Workday 85 live
  **[search]**. Penn's peers are split: Dartmouth on Degree Works, Columbia,
  Cornell and CMU on Stellic, Harvard and Princeton PeopleSoft-based, Yale
  likely Degree Works, Stanford and Brown homegrown **[search]**.
- Schools expose audits as an SSO web app, HTML or PDF for students, with no
  documented student API anywhere. Degree Works' dashboard has JSON behind
  it (`/api/audit` with a vendor `Accept` type), but the path prefix and
  parameters vary per school **[read]**.
- **Portable:** the rule tree, the engine, the planner, the marked-courses
  flow, the Canvas seed. **Per school:** the requirement data, course codes
  and term codes, prerequisite syntax, any audit import. So the design is
  portable and the data is Penn-only, like everything else server-side
  today. Schools with a public course API make near-copies easy (UIUC,
  Berkeley via Berkeleytime, UCLA with OAuth) **[search]**. A Degree Works
  reader, if ever built, would cover some schools and none of the Stellic
  peers.

## Product and design

**What students find painful** (evidence is thin, all **[search]**): the
worksheet is wrong often enough that a department tells students to check
the registrar's list; students chase "a missing check mark" (DP, Sept 2026);
launch coverage called Path@Penn "not as efficient" and hard to navigate,
with students building mock schedules in Penn Course Plan instead (DP, April
2022); the 2025 SCUE white paper reports frustration and confusing sector
tags; a Nov 2025 DP column asks for a chatbot that answers "how many more
courses". Penn Labs' own Degree Plan is a gated beta whose open issues
include double counting and double majors **[read]**: the data is the hard
part, not the UI.

**When students care.** The two weeks before advance registration (Spring
2027: Oct 26 to Nov 9, 2026, course selection Nov 17; Fall: late March to
early April; LPS calendar, other schools may differ **[search]**), the
spring-of-sophomore-year major declaration, and dual-degree windows.

**Recurring UI conventions** (Degree Works, Stellic, Penn Degree Plan): a
progress ring or bar with a percentage; status colours for complete, in
progress, planned, missing; a collapsible checklist with "n of N"; course
chips; semester columns; tabs per program; on phones, swipe between plan and
requirements. Every vendor warns the wheel is "a guideline".

**Three concepts in Smooth's style** (lowercase, the least text that works,
Marco's colours on paper):

1. **the ring.** A row in Profile → classes, "degree", opens a screen with
   one teal ring ("31 of 40 cu") and the requirement list underneath, each
   rule a row: name, "3 of 5", a thin bar in the rule's colour (teal met,
   marigold in progress, rule-grey open). Tap a rule: the chips that count
   and the chips that could. Footer in muted ink: "smooth's reading ·
   official audit on path@penn ↗". Marking a course is a chip grid per
   term, the `CoursePicker` idiom.
2. **what if.** The same screen with a `SmoothSegmentPicker`: progress ·
   what if. Pick a second program from a search; the list shows the delta
   only: "+7 courses · fits by spring 2029 at 5 cu", then the suggested
   order as term cards ("fall 2027: cis 1210, cis 2400, …"), each course a
   chip with "fall only" or "needs cis 1200" under it when relevant. A
   grape "what if" tag on the ring so the two views never look alike.
3. **the tree knows.** No new screen first. The tree gets a `# DEGREE` block
   and answers "can I still do a cis minor?" or "what's left for my major?"
   from the engine's result, with a chip to the degree screen; and a
   seasonal one-line dashboard card during advance registration
   ("registration nov 17 · 3 requirements open"), styled like the feedback
   card, dismissible.

Recommended order: 1, then 3 (it needs a PRIVACY.md change), then 2. A
static mockup of concepts 1 and 2 is published beside this report, marked
as a mockup.

## Phases, and the decision each needs

Sizing uses the tree plan's units: hours for a session with a toolchain,
tests included, with a predicted Swift test delta that the Mac's count wins.

**Phase 0: settle the unknowns (no app code; 1 to 2 days).**
Confirm the `courses.upenn.edu` endpoints from a laptop and save the XML
for three programs; run Penn Labs' `fetch_degrees_from_path --dry-run` on
them to see what their parser keeps and drops; ask Penn Labs and ISC the
terms question in writing; one phone pass on Path@Penn (see Experiments).
*Decision:* go ahead with the public endpoints, or fall back to hand-curated
templates for a few programs.

**Phase 1: progress, on-device (about 30 to 40 hours).**
Kit: `Degree/` with `DegreeProgram`, `Requirement` tree, `TakenCourse`,
pure `RequirementAudit.evaluate` and the allocator, `DegreePlanStore` in
its own store file; a `Term` to `2026C` mapper. UI: `AppState+Degree`,
`DegreeProgressView`, a `DashRoute.degree` reached from Profile → classes,
chip grids for marking courses, `SampleData.degreeProgress()` so App
Review's preview shows it, `FeatureFlags.degreeProgress`. Templates for
three programs bundled as JSON (CIS BSE, one College BA, one minor), each
with its source quote and catalog year. PRIVACY.md bullet. Prediction: +80
to +110 Swift tests, +6 suites; no backend change; no deploy.
*Decision:* which three programs; whether the screen ships behind the flag
in 3.5 or waits for Phase 2's data.

**Phase 2: pooled templates for every program (about 20 to 30 hours plus a
deploy).** Backend: `degree_programs` table copying `catalog_courses`'s RLS,
`_shared/degree.ts` porting the parts of Penn Labs' parser Smooth needs,
served by a small function or a direct read (not through `sync`, which every
install calls), refreshed per catalog year. Phone: a lossy wire decoder, the
bundled JSON becomes a cache. Prediction: +30 Deno, +15 Swift; one migration
and one function deploy at the owner's go.
*Decision:* Penn's answer from Phase 0; who owns the yearly refresh.

**Phase 3: what-if and the planner (about 40 to 60 hours).** Course facts
per semester from Penn Labs' API (credits, offered terms as observed,
prerequisite text), a prerequisite extractor with quote and code checks (a
model may extract here; code verifies), the planner (fill shortfalls in
courses and in credits, order by chain, respect offerings and a CU cap,
report what could not be placed), the what-if view, the delta line, term
cards. Prediction: +120 Swift tests including a frozen regression set of
real programs; +20 Deno if offerings are served.
*Decision:* whether planned courses may ever become dashboard items (no:
they would need a ledger source, which is closed), and the CU cap default.

**Phase 4: the student's record, richer (decisions, then 15 to 40 hours
each).** 4a Canvas past courses as a seed (new client call; still Penn's
session model). 4b Audit or transcript PDF import, on-device parse. 4c The
tree's `# DEGREE` block with the PRIVACY.md change. 4d Path@Penn reading:
only with a written position from Penn, and then as its own research.

## Risks

- **Penn policy.** Reading `courses.upenn.edu` is unauthenticated and
  template-only, and Penn Labs does it at 0.5 s intervals **[read]**, but
  Smooth is a published app, not a student club. Ask. Route D is the real
  exposure and is not in the plan.
- **Privacy.** Nothing personal leaves the phone in Phases 1 to 3. The two
  places this could slip are the tree's context document (uploaded on every
  question) and the laptop sync; both are explicit later decisions with a
  PRIVACY.md change first.
- **App Store.** Low for Phases 1 to 3 given the bullet; the preview must
  show the screen with sample data (App Review's only way in). Route D
  would need 5.2.2 authorization "upon request".
- **A wrong "you're on track".** This is the risk that matters. Mitigations
  built into the design: the engine runs the registrar's own rules from the
  audit XML, not a transcription; every rule shows its source quote and
  catalog year; any rule with a qualifier the engine does not implement is
  marked approximate and never counted as met; the screen never says
  "graduate" or "on track", only "met · in progress · open · approximate",
  with a count of approximate rules; the footer and the tree's answers
  always name Path@Penn as the official audit with a link; substitutions
  and advisor exceptions are explicitly out of Smooth's knowledge and the
  screen says so once; a frozen regression set of real programs and real
  course lists (the owners' own, kept off the repo) gates every change.
- **Upkeep each year.** Templates are keyed by catalog year from the XML;
  Phase 2 refreshes them when a new `srcdb` appears; a diff of rules between
  years is reviewed by a person before it serves; the College Foundations
  change for the Class of 2031 is the first real test.

## Cheap experiments that settle the biggest unknowns

From a phone (Olisa):

1. Open Path@Penn → Degree planning and audit. Does the page offer "Save as
   PDF" or a print button? Does the URL or any visible text say
   "degreeworks" or "responsiveDashboard"? Two screenshots settle route C's
   format and the product question.
2. Right after a Canvas login in Safari, open path.at.upenn.edu: does Duo
   prompt again? One data point on the shared session.
3. Open advising.cis.upenn.edu/worksheet/ and college.upenn.edu's
   "Interpreting your degree audit": is the inaccuracy warning still up?
4. Email Penn Labs (contact@pennlabs.org): is Degree Plan's degree data
   going to open after the beta, and what is their read of the
   `courses.upenn.edu` endpoints' terms? One paragraph.
5. Paste the real worksheet's block names for your own major (no courses or
   grades) so the first three templates match what students see.

Needs a Mac (brief for Marco):

1. In a terminal, POST to `https://courses.upenn.edu/api/?page=fose&route=programs-v2-list`
   with body `{"srcdb":"202630","programsType":""}` (URL-encoded JSON, the
   headers Penn Labs' `path_client.py` sends), then `programs-v2-info` with
   `{"srcdb":"202630","programCode":"CMPE-BSE"}`. Save the `audit_xml` for
   CMPE-BSE, one College BA and one minor into
   `docs/research/degree-progress/fixtures/` (they contain no student data;
   check `Stu_id="*"` before committing).
2. Clone github.com/pennlabs/penn-courses and run
   `python manage.py fetch_degrees_from_path --dry-run --srcdb 202630 --program CMPE-BSE`
   to see what their parser keeps, warns about and drops.
3. In Safari's Web Inspector, signed in as yourself, open the Degree Audit
   and note the hosts and whether the audit arrives as JSON or HTML. Record
   hostnames and paths only; never a token or a cookie.
4. Check "Save as PDF" on the audit and keep one page of the PDF layout
   (names of blocks only, courses redacted) for route C.

## Questions for Olisa and Marco

1. Does the public-endpoint route (templates from `courses.upenn.edu`) get
   a go for Phase 0, and who sends the Penn Labs and ISC emails?
2. Which three programs for Phase 1 (CIS BSE is the obvious first; which
   College major; which minor)?
3. Where does the entry point live: a Profile → classes row (recommended),
   a dashboard card, or a fourth header button (not recommended)?
4. Is the tree allowed to know the degree plan (a PRIVACY.md change) in
   Phase 1, or does that wait?
5. Should past courses ever be seeded from Canvas, given the app today
   deliberately reads only current enrolments?
6. Route D (reading Path@Penn with the saved PennKey): parked until Penn
   answers, or off the table?
7. Is Degree Progress Penn-only for good, like the rest of the server, or
   should the Kit be written so another school's templates could slot in?

## Sources

Every source, with its label, is in `docs/research/degree-progress/`:
01 Path@Penn, 02 public data and Penn Labs, 03 data routes and policy,
04 privacy and App Store (Apple's text quoted), 05 modelling, 06 beyond
Penn, 07 product pain points, 08 code seams, 09 the rules-engine sketch.
The most-cited primary sources, all read directly:

- github.com/pennlabs/penn-courses, `backend/degree/utils/path_client.py`,
  `parse_path_audit.py`, `degreeworks_client.py`, `models.py`,
  `double_counts.py`, `views.py`, `management/commands/fetch_degrees_from_path.py`;
  `frontend/degree-plan/`; `LICENSE` (MIT).
- github.com/Aaryan-Kapoor/degreeworks-cli (Degree Works JSON shape at one
  school).
- developer.apple.com/app-store/review/guidelines/ (5.1.1, 5.2.2).
- raw.githubusercontent.com/instructure/canvas-lms (`courses_controller.rb`,
  `enrollments_api_controller.rb`).
- This repo: `CLAUDE.md`, `ROADMAP.md`, `docs/PRIVACY.md`,
  `docs/DAY_PLANNER_RESEARCH_2026-11-03.md`, `backend/PROTOCOL.md`.
