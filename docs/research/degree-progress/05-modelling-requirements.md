# 05. Modelling degree requirements (research, 2026-11-09)

Research only; no app code. Labels: **[read directly]** = I read the primary text (raw source or page body); **[search summary only]** = only a search-result snippet or the fetch tool's summary; **[inferred]** = my reasoning.

Network reality in this session was narrower than briefed: WebFetch worked for github.com and raw.githubusercontent.com only. Vendor docs, Oracle, Ellucian guides, arXiv and registrar PDFs all failed with ENOTFOUND (see Blocked hosts). So Scribe, uAchieve, PeopleSoft and Stellic claims are **search-summary only**; the Penn Labs claims are **read directly** from source code, and they turn out to be the best evidence about Penn specifically, because Penn Labs parses the real Path@Penn Degree Works audit XML.

## 1. How audit systems represent rules

### 1.1 Ellucian Degree Works "Scribe"

- Rules live in **blocks** (DEGREE, MAJOR, MINOR, CONC, OTHER, plus a "block header" with catalog-year range and requirement id). Coursedog's generator emits "both the requirement rules as well as a 'block header'". [search summary only] https://coursedog.freshdesk.com/support/solutions/articles/48001225188-requirements-using-the-scribe-generator
- Class-count rule syntax, from a published CUNY block: `3 classes in CIS 2100, 2200, 3200, 4500, CP 6200, 7100` inside BEGIN/END. [search summary only] (transfer-app.qc.cuny.edu requirements page). Prairie View's guide gives `3 Classes in HIST @`. [search summary only]
- **Wildcards**: `@` matches any subject or number. `@ @ with Attribute CG08` means any course with that attribute (SUNY Cortland FAQ). [search summary only] Penn's own audit uses the same form: the College credit requirement ends `ENVS @, @ @ (With ATTRIBUTE = AU16)`. [read directly] https://raw.githubusercontent.com/pennlabs/penn-courses/master/backend/degree/utils/parse_path_audit.py (docstring of `parse_course_list`, regex `WILDCARD_WITH_ATTRIBUTE`).
- **Qualifiers**: `MinGrade B` after a course list (Coursedog example `2 Classes in BIO 151, 189` / `MinGrade B`). [search summary only] Others named in the Penn Labs parser: `<Except>` nodes (courses a rule explicitly does not accept), `With` restrictions such as `DWRESIDENT`, `DWGRADE`, `DWCOURSENUMBER`, `DWPASSFAIL`, `DWAGE`, and `Credits`/`Classes` caps used for transfer credit (`block_allows_transfer_credit` reads a `Classes` or `Credits` cap). [read directly]
- **Rule types seen in Penn's XML**: `Course`, `Subset`, `Group` (with `NumGroups`, i.e. "1 Group in ..."), `Complete`, `Incomplete`, `Noncourse`, `Block`, `Blocktype`, plus conditional `If/Else` (`ROP` evaluation against major/concentration/program). Course rules carry `Classes_begin` and `Credits_begin`. [read directly] parse_path_audit.py.
- **Double counting**: two reserved words, EXCLUSIVE (aka DontShare) and NONEXCLUSIVE (aka ShareWith). Blocks are exclusive by default; a rule can opt out with a qualifier; using both on one rule is an error; `ShareWith (MAJOR, MINOR)` and `DEGREE` target other blocks. [search summary only] Technical Guide / Scribe User Guide excerpts via search (technodocbox.com Degree Works Technical Guide; docplayer DegreeWorks Scribe User Guide). Penn's version, [read directly] in double_counts.py: share targets are `{"kind": THISBLOCK | ANYBLOCK | MAJOR | OTHER, "value"?}`; "Rules with no targets may not double count with anything, which is DegreeWorks' default"; "within a block, courses are exclusive unless THISBLOCK says otherwise"; sharing is symmetrical; a block marked `STANDALONEBLOCK` is evaluated outside the shared pool.
- **Exceptions / substitutions** are applied per student by trained staff, not in the Scribe source: Force Complete (does not satisfy credits), Substitution, Also Allow (adds a course to a list), Remove Course / Change the Limit, Apply Here (move a course between requirements). [search summary only] Montana State, Wayne State, Missouri State, SJU pages from search. A failure mode is documented: a UCA change log shows electives removed from a major block because of a ShareWith in the Gen-Ed block, called misadvising by a reviewer. [search summary only] https://uca.edu/registrar/degree-works-modification-page/
- Attributes are institution-configured (a single `ATTRIBUTE` value must be defined in a config table to be usable with `WITH`). [search summary only]

### 1.2 uAchieve / DARS
No uAchieve vendor encoding found. Search gave only: programs are "a list of reusable requirements" with sub-requirements as test building blocks (Miami University description), and double-count limits recorded per program, with exceptions entered on the requirement the course will fulfill (UC Santa Cruz). [search summary only] Treat as unknown.

### 1.3 PeopleSoft Academic Advisement (Oracle)
Three layers built in order: **course lists** (CLST explicit list; DLST derived list = a subset of the student's own record), **requirements** with **line items** whose line type chooses the test, and **requirement groups** on top. A Line Item Parm page links course lists, derived lists and conditions to a line. [search summary only] https://docs.oracle.com/cd/G11181_01/cs92pbr35/eng/cs/lsaa/UnderstandingAcademicAdvisementConcepts-ab7f49.html and CSU Channel Islands guides. Sequential-restriction line types require ordered course lists. Exact line-type names not read.

### 1.4 Stellic
Requirement tree: a parent requirement with sub-requirements; dashed outline = several courses could satisfy, solid = a specific course; one course can show in several places; unmatched courses listed at the bottom. Planner is term-by-term drag and drop, draws on what-if requirements, and warns when prerequisites are missing or the course "is not typically offered during that term". Student tags (Honors, TRIO) exist; how course tags work in the tree was not found. [search summary only] UNK, U Delaware, UW-La Crosse, Walsh pages. stellic.com is blocked.

## 2. Open formats and libraries

### 2.1 Penn Labs "Penn Degree Plan" (penn-courses `backend/degree`) [read directly]
Files: https://raw.githubusercontent.com/pennlabs/penn-courses/master/backend/degree/models.py (1048 lines), utils/double_counts.py, utils/degree_logic.py, utils/parse_path_audit.py.

- **Rule tree**. `Rule` is a node, deduplicated and shared across degrees. Fields: `title`; `num` ("minimum number of courses or subrules required"); `credits` ("minimum CUs ... Only non-null if this is a Rule leaf"); `q` (a serialized Django Q object, "non-empty iff this is a Rule leaf", normalised before serialising); `parent` FK; `block_type`/`block_value` (the Path@Penn audit block it came from); `share_targets` (JSON list); `transfer_credit_allowed`.
- **Evaluation**. Leaf: filter `Course` by the Q over the student's course codes, de-duplicate by `full_code`, require `count >= num` and `sum(credits) >= credits` (either or both). Branch: count satisfied children `>= num`; `num` null means all children. A leaf can have both `num` and `credits` (e.g. "2 courses and 2 CU").
- **Matching is by filter, not list**. The Q can be `full_code in [...]`, department, number range, or `attributes__code__in=[...]` (course attributes). Explicit lists are just a Q over codes. Cross-listings: a course "counts once, however many semesters it was offered in"; there is a `canonical` course cache (`prewarm_canonical_cache`).
- **Manual override**: `Fulfillment.overrides` = "Rules this course is manually overridden to count for, bypassing the normal Q filter check".
- **Double counting has three layers.** (a) Per-rule `share_targets` parsed from the audit's ShareWith, resolved at request time into "which leaf rules may share a course" (`resolve_double_counts`), symmetrical. (b) `DoubleCountRestriction(rule, other_rule, max_courses, max_credits)`, non-directional, violated if shared courses or shared CU exceed the cap. (c) Plan-level caps the audits cannot state: `DualProgram.max_shared_cu`, a two-claim limit, and a hard-coded 3 CU graduate sharing cap for submatriculants (4+1), citing the SEAS handbook.
- **Allocation is a greedy assignment, not a solver.** `get_priority_rule`: "If the rule is explicitly mentioned, returns that rule. Else, returns the rule with the highest required CU count." Then `allocate_rules` per course in the order taken, then `rebalance_allocations` "moves courses onto short rules when another course can take their place, without leaving any rule worse off or breaking double counting limits". Each `Fulfillment` stores `rules` (selected), `unselected_rules` (eligible but not chosen) and `legal` ("isn't illegally double counted anywhere").
- **What-if**: a `DegreePlan` can hold several `degrees`, `majors`, `minors`, a `DualProgram`, and `ProgramVariant` (rules to add, `suppressed_rules`). A plan is copyable (`copy(new_name)`). What-if is therefore "another plan object", evaluated by the same code. Minors are "evaluated outside the shared course pool".
- **Gaps**: no prerequisite ordering or offering patterns in the degree models I read; `Fulfillment.semester` is just a label (YYYYx, `_TRAN` for transfer). The parser reads only `ATTRIBUTE`/`DWATTR` `With` clauses: "Other With clauses are not read, so they don't narrow" (so a MinGrade or similar qualifier is silently dropped). [read directly]

### 2.2 St. Olaf / degreepath "Hanson format" [read directly, raw README]
https://raw.githubusercontent.com/degreepath/stolaf-areas/master/README.md (via fetch summary of the README, so treat quotes as paraphrase) and https://github.com/degreepath/auditor. `course`, `requirement`, `of`/`count` (number, any, all; "greedy": "does not end the evaluation process when the count is reached"), `both`/`either`, and a `given`/`where`/`what`/`do` pipeline (filter by dept, level, semester, GE requirement, custom attributes; `do: count >= 6`, sum, average). `limit` with only `at_most`. A top-level `attributes` dictionary adds custom attributes. Double counting: no claims system; the README says there is "not currently a way to change this behavior. It remains to be seen if it is problematic". What-if: `python3 -m dp.server.whatif --student --code --catalog` and queued batch what-ifs. [search summary only on the auditor README]

### 2.3 selfint/degree-planner (Technion) [read directly via fetch of README and `src/app.d.ts`; comment text is the tool's quotation]
Per-program JSON tree. `Requirement` has `name`, labels, `courses` ("The courses that satisfy this requirement. If empty, courses will be taken from the nested requirements"), `points`, `count`, `amount` (number of nested requirements needed), `nested`, `overflow` ("Name of the requirement to overflow to"), and `hook` (code that modifies progress). `overflow` is the notable idea: surplus courses spill to a named requirement instead of being double counted. Explicit lists only.

### 2.4 UTD Nebula Planner [search summary only]
Nebula Labs Confluence: core validation uses **max-flow**; major validation uses a **greedy** algorithm because major rules did not fit max-flow; major validation assumes "courses always map 1:1 with requirements"; free electives evaluated last.

### 2.5 Others
- ethan42/pps: JSON Schema (draft 2020-12) per entity (course, program, specialization), referential integrity checked in `validate.py`; course record has `prerequisites` (required and recommended) and `offered_this_year`; graduation-rule structure not visible. [read directly, README only]
- csesoc/circles (UNSW), qu8n/pennplanner (archived, Penn MCIT, Supabase): README-level only; PennPlanner stores `semester_index` and `semester_course_ids` per user and warns on missing prerequisites. [read directly, README]
- ASEE paper on propositional logic for degree-requirement entry. [search summary only] https://peer.asee.org/5866.pdf
- No widely adopted standard JSON schema for degree rules was found. [search summary only]

### 2.6 Comparison

| | Scribe (Degree Works) | PeopleSoft AA | Penn Labs Rule tree | degreepath Hanson | selfint (Technion) |
|---|---|---|---|---|---|
| Structure | block, rules, groups, subsets | req group, requirement, line, course list | tree of Rule nodes (num/credits/q) | nested of/count, given/where/do | tree with courses/count/points/nested |
| Choose-N | `n Classes in`, `1 Group in` | line types [not read] | `num` on parent or leaf | `of: count` | `count`, `amount` |
| Credit totals | `Credits` | yes [unread] | `credits` on leaf | `sum` in `do` | `points` |
| Match by | list, `@` wildcard, `With ATTRIBUTE`, Except | course list, derived list | Q filter (code, dept, range, attribute) | list or `where` filter, custom attributes | explicit list |
| Cross-listing | catalog equivalence [unread] | [unread] | canonical course, `full_code` dedupe | [unread] | none seen |
| Double count | Exclusive default, ShareWith per rule/block | [unread] | `share_targets` + pair caps `max_courses`/`max_credits` + plan caps | none; `limit at_most`; "consumes" matches | `overflow` to a named requirement |
| Qualifiers (grade etc.) | MinGrade, MinGPA, MaxCredits | [unread] | dropped by parser | filters on grade/graded | none |
| Per-student exceptions | Force/Substitute/Also Allow/Remove | [unread] | `overrides` | none | `hook` |
| Allocation | engine assigns by rule order and sharing | [unread] | greedy + rebalance | greedy `of` | greedy [inferred] |
| What-if | re-run audit on another block | [unread] | another DegreePlan with variants | whatif server | swap tree |

## 3. The planning half

- **Prerequisites as DAG**: the standard formulation is topological sort; "Parallel Courses" (LeetCode 1136) computes the minimum number of semesters by BFS levels, each level one semester. Cycles are detected and rejected. [search summary only] educative.io pages. This ignores offerings and credit caps, so it is a lower bound, not a plan. [inferred]
- **Constraint solvers**: an INFORMS mixed-integer degree-planning paper puts a prerequisite in an earlier term; a CP paper (arXiv cs/0110007, balanced academic curriculum with per-period load limits) reports that IP solved only small instances and argues constraint solving copes better; WPI minimises extra credits; an ILP with conditional constraints (Charoenruengkit, 2018 ACM conference paper). [search summary only] No Penn-scale open planner using a solver was found.
- **Existing product behaviour**: Stellic does not generate an order; it validates a student's drag-and-drop plan and warns for missing prerequisites and "not typically offered" terms. [search summary only] PennPlanner, Nebula and Circles do the same (validate, not generate). [search summary only / README]
- **Requirement-to-course assignment is itself a matching problem**: UTD uses max-flow for core and greedy for majors; Penn Labs uses greedy plus a rebalance pass; both note greedy can fail when one course could serve two shortfalls. [read directly (Penn Labs), search summary only (UTD)]
- **Common failure, double counting**: Penn Labs states that a Path@Penn audit's ShareWith is "written about the blocks of that one audit", so two separately scraped audits each sharing with (MAJOR) would share without limit, which is why it adds plan-level caps. [read directly] Degree Works: a ShareWith in one block silently removed elective credit from another (UCA). [search summary only] degreepath: no way to stop a rule consuming every match. [search summary only]
- [inferred] A minimal planning design for Smooth: (1) allocate courses to requirements first (verify legality), (2) build the prerequisite DAG over remaining courses, (3) place courses per term by earliest-feasible greedy with fall-only and spring-only flags and a CU cap, ordering by longest remaining chain first; fall back to a small CP/ILP only if greedy reports infeasible. Offering patterns need Penn-specific data (see Open questions).

## 4. Should a model decide what counts?

Evidence for "no":
- TravelPlanner: GPT-4-Turbo had a 0.6% final pass rate on multi-constraint plans (one leaderboard mirror says 4.44%); most plans violated at least one constraint. [search summary only] https://arxiv.org/pdf/2402.01622
- RuleArena (ACL 2025): real rule sets (airline baggage, NBA trades, tax); o1-preview about 50-60% on easiest level, most models under 10% on hardest; failure modes are rule recall errors, rule misuse and computation errors; performance improves with external tools. [search summary only] https://aclanthology.org/2025.acl-long.27
- "Can LLMs Follow Simple Rules?" (RULES): nearly all tested models inadequate. "When Instructions Multiply": accuracy falls as simultaneous constraints grow. RuleWeaver: errors in multi-step integration even when the right rules are retrieved. [search summary only]
- Aurora (FIU, SAC 2026) puts prerequisites and credit limits in a Prolog engine and uses the LLM only for query parsing and explanations; latency figures conflict between sources, so no accuracy claim is made here. [search summary only] https://arxiv.org/abs/2602.17999
- Practitioner guidance (vendor, weak): ground answers in the audit system, route graduation-critical cases to a human, stale catalogs are a common failure. [search summary only] ibl.ai. AdvisingWise: human-in-the-loop. [search summary only]
- Products: no technical description of an LLM deciding audits was found for Stellic or Degree Works; Hawaii says AI is "under development" for Degree Works via Smart Plan. [search summary only] I found no evidence that either vendor lets a model decide what counts. [inferred from absence]

Evidence for extraction: structured extraction from HTML course pages (arXiv 2603.13562) and schema-valid JSON benchmarks exist, but I found no paper measuring LLM extraction of degree rules specifically. [search summary only]

**Verdict**: nothing I found argues against "code decides, the model extracts and explains" for degree rules; it supports it, and the item that matters is verification. [inferred] The same guards as DAY_PLANNER Part 2 transfer: an extracted rule must carry a verbatim quote from the source page, referenced course codes must exist in the catalog, and a human (Marco, Olisa) reviews a diff before a rule enters the shipped data. Because Penn Labs shows Path@Penn serves the real Degree Works audit XML, the better question is whether LLM extraction is needed at all for the core rules; it may only be useful for prose policy (section 5). [inferred]

## 5. Penn specifics

- College sector rule: a different course in each of the sectors, seven courses in all; "One course cannot be used to fulfill more than one Sector". [search summary only] https://www.college.upenn.edu/node/234
- Foundational Approach: may double count with the major and with a Sector, but not among two or more courses within the Foundational Approach requirement. [search summary only] DP articles and https://www.college.upenn.edu/node/254
- Sector and major: each major auto-completes a designated sector; remaining sectors must be non-major courses; departments state "no more than one course can count towards both the major and a sector" (PPE) and Psychology says only one major course can double count in the Sectors. These are department rules and differ by major. [search summary only] https://ppe.sas.upenn.edu/node/323, https://psychology.sas.upenn.edu/node/221
- Minors: "no limit to the number of courses that may be double counted between General Education Requirements and requirements for a minor". [search summary only] https://www.college.upenn.edu/node/254
- Course attributes: the Path@Penn Course Attribute search is how sector and Foundational Approach courses are found ("College-Sector"). The audit uses `With ATTRIBUTE = <code>` (example `AU16` above), so attributes are coded, not free text. [search summary only] plus [read directly] for the audit syntax.
- The DP guide for fall 2026 (March 2026) lists courses that double count "based on data provided on Path@Penn"; the snippet did not show the table. The DP has published this guide every cycle since 2018, which suggests the data changes each term. [search summary only] https://www.thedp.com/article/2026/03/penn-double-count-courses-general-education-foundational-sectors-fall-2026
- Dual or submatriculant programs add caps not in any audit (3 CU graduate sharing for SEAS 4+1; M&T, Huntsman, LSM, VIPER as `DualProgram`). [read directly] models.py, degree_logic.py. Penn Labs code names this "Path@Penn cannot express this".

## 6. Recommended rule shape for Smooth (minimal JSON) [inferred from sections 1-2]

Principles: a tree; leaf match by filter; explicit sharing; every rule carries provenance.

```json
{
  "id": "cis-bse.core",
  "title": "CIS core",
  "source": {"kind": "path_audit|handbook|manual", "block": "MAJOR:CMPE", "quote": "...", "asOf": "2026-11-09"},
  "block": {"type": "MAJOR", "value": "CMPE"},
  "need": {"courses": 5, "credits": null},        // both allowed; null = no test
  "of": null,                                      // child rule ids with "need.rules": N, or null for leaf
  "match": {                                       // leaf only; OR over entries, AND inside one
    "any": [
      {"codes": ["CIS-1200","CIS-1210"]},
      {"dept": "CIS", "numberRange": [2000, 5999]},
      {"attribute": "AU16"}
    ],
    "except": ["CIS-4990"],
    "minGrade": null
  },
  "share": [{"kind": "ANYBLOCK"}, {"kind": "THISBLOCK"}],   // default: [] = exclusive
  "caps": [{"withRule": "gened.sector.society", "maxCourses": 1, "maxCredits": null}],
  "allowTransfer": true
}
```

Needs beyond that, each tied to a finding:
1. **Equivalence table** (cross-listings, canonical code) kept outside rules (Penn Labs `canonical`).
2. **Per-student overrides** stored separately and never in the shared rule data: force-complete, substitute, also-allow (Degree Works exception types; Penn Labs `overrides`). Fits the ledger principle.
3. **Allocation result as data**: per course `selected`, `eligible_unselected`, `legal` (Penn Labs Fulfillment), so the UI can show "also counts toward X, not applied".
4. **Plan-level caps** separate from rules (dual programs, 4+1), as Penn Labs found audits cannot state them.
5. **Course facts** for planning: prerequisite expression, offered terms (observed, with a confidence flag), credits. Not part of rules.
6. **What-if** = a second plan (set of blocks plus variant) evaluated by the same engine and diffed; no separate code path.
7. **Unparsed-qualifier flag**: if an audit rule has qualifiers the engine does not implement (MinGrade, DWRESIDENT...), mark the rule "approximate" rather than dropping it silently as Penn Labs does.
8. Allocator: greedy with a rebalance pass first; Penn Labs shows it works at Penn scale; keep a max-flow option if rebalance leaves a shortfall. [inferred]

## Sources
- Penn Labs, penn-courses `backend/degree`: https://raw.githubusercontent.com/pennlabs/penn-courses/master/backend/degree/models.py ; .../utils/double_counts.py ; .../utils/degree_logic.py ; .../utils/parse_path_audit.py [read directly]
- https://github.com/degreepath/stolaf-areas , https://github.com/degreepath/auditor , https://github.com/selfint/degree-planner , https://github.com/ethan42/pps , https://github.com/qu8n/pennplanner , https://github.com/csesoc/circles , https://github.com/UTDNebula/planner (Confluence: nebula-labs.atlassian.net) [README/summary]
- Scribe/Degree Works: https://coursedog.freshdesk.com/support/solutions/articles/48001225188-requirements-using-the-scribe-generator ; https://uca.edu/registrar/degree-works-modification-page/ ; Degree Works Technical Guide (technodocbox.com) ; DegreeWorks Scribe User Guide (docplayer.net) ; Montana State, Wayne State, Missouri State exception guides [snippets]
- PeopleSoft: https://docs.oracle.com/cd/G11181_01/cs92pbr35/eng/cs/lsaa/UnderstandingAcademicAdvisementConcepts-ab7f49.html [snippet]
- Stellic via UNK, U Delaware, UW-La Crosse (kb.uwlax.edu/163157) [snippets]
- Planning: educative.io "Parallel Courses"; arXiv cs/0110007; INFORMS inte.2026.0325; WPI "Guiding Course Selection via Degree Evaluation Optimization" [snippets]
- LLM reliability: https://arxiv.org/pdf/2402.01622 (TravelPlanner); https://aclanthology.org/2025.acl-long.27 (RuleArena); https://arxiv.org/pdf/2311.04235 (RULES); https://arxiv.org/abs/2602.17999 (Aurora); https://arxiv.org/html/2511.05706v1 (AdvisingWise) [snippets]
- Penn: https://www.college.upenn.edu/node/234 ; /node/254 ; https://ppe.sas.upenn.edu/node/323 ; https://psychology.sas.upenn.edu/node/221 ; DP double-count guides 2018-2026 (https://www.thedp.com/article/2026/03/penn-double-count-courses-general-education-foundational-sectors-fall-2026) [snippets]
- Repo: docs/DAY_PLANNER_RESEARCH_2026-11-03.md Part 2 [read directly]

## Blocked hosts (ENOTFOUND or proxy refusal, not retried)
www.usg.edu, studylib.net, www.slideserve.com, coursedog.freshdesk.com, www.wpunj.edu, banadmin.jefferson.edu, docs.oracle.com, arxiv.org (brief said it works; it did not here). curl through the proxy was also refused for usg.edu and studylib.net. As briefed: *.upenn.edu, thedp.com, stellic.com etc. were not attempted.

## Open questions
1. Exact Scribe wording for MinGrade/ShareWith/Group is only seen second-hand. Does a licensed Scribe Language guide (Jefferson hosts 5.0.1) get fetched once a host is allowed? Needed only if Smooth parses Scribe text rather than the XML.
2. Can Smooth legitimately obtain Path@Penn audit XML (what Penn Labs reads via `path_client`), or must the rules be hand-built from the College handbook? This decides whether an LLM is needed at all. Penn Labs' client shows authentication is involved; not read.
3. Where do offered-term patterns for Penn courses come from (course catalog history, Penn Labs `courses` data)? "Typically offered" is observed, not promised.
4. Prerequisite expression format at Penn (free text in catalog); parsing it is the one extraction task where an LLM plus code verification looks justified. Not researched here.
5. The DP's fall 2026 double-count table was not visible; is the same attribute data exposed by Path@Penn so that it can be derived rather than copied?
6. No evidence on how well LLMs extract degree rules from catalog prose; would need a small bench like DAY_PLANNER Part 7.
7. uAchieve and PeopleSoft line-type names remain unread; low priority since Penn uses Degree Works.
