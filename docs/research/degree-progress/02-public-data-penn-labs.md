# 02 - Public data without student login (Penn Labs, catalog)

Researched 2026-11-09. Source for code reading: shallow `git clone` of https://github.com/pennlabs/penn-courses (master, last commit 2026-11-08), read locally; paths below are relative to the repo root. (The api.github.com tree endpoint was refused for this session, but raw/clone worked.) Labels: [read directly], [search summary only], [inferred].

## Findings

1. **Licence is MIT, code only.** [read directly] `LICENSE`: "MIT License, Copyright (c) 2020 Penn Labs", standard permission grant. It covers the software. It says nothing about the data the software holds (course data comes from Penn's registrar OpenData; degree data from Path@Penn). [inferred] MIT does not give Smooth rights to Penn's catalog/requirement data; treat data reuse as unresolved and ask Penn Labs / Penn.

2. **Course fields exposed by the public course API.** [read directly] `backend/courses/urls.py` mounts under `base/` (`backend/PennCourses/urls.py`): `<semester>/courses/`, `<semester>/search/courses/`, `<semester>/courses/<full_code>/`, `<semester>/search/sections/`, `<semester>/sections/<full_code>/`, `<semester>/pre-ngss-requirements/`, `attributes/`, `restrictions/`. `CourseListSerializer` fields (`courses/serializers.py`): id, title, description, semester, num_sections, course_quality, instructor_quality, difficulty, work_required, recommendation_score, credits (plus a code field). `CourseDetailSerializer` adds: syllabus_url, **prerequisites**, crosslistings, pre_ngss_requirements, attributes, restrictions, sections. None of these course views set `IsAuthenticated` (only `UserView` and `FriendshipView` do in `courses/views.py`). [inferred] so they are public, consistent with Smooth's existing use; I could not test live (penncoursereview.com blocked).

3. **Prerequisites are free text, not structured.** [read directly] `backend/courses/models.py`, `Course.prerequisites = models.TextField(blank=True, help_text="Text describing the prereqs for a course, e.g. 'CIS 120, 160' for CIS-121.")`. No parser for it exists in the backend (grep for "prereq" in .py finds only models.py and serializers.py). It is just passed through. The help-text example shows it is not even in a regular grammar ("CIS 120, 160"). Data is imported from Penn's registrar OpenData API (`backend/courses/registrar.py`, uses OIDC client credentials `OPEN_DATA_CLIENT_ID`), which Penn Labs holds credentials for; Smooth cannot call it without its own credentials. [read directly]

4. **Semesters offered.** [read directly] There is no "semesters offered" or `last_offered` field. Semester is a path segment: `base/{semester}/courses/` with semester like `2025C` (A spring, B summer, C fall; `Course.semester` help_text). A `Course` row exists per (course, semester), so history = query each past semester. `BaseCourseMixin.get_semester/filter_by_semester` (`courses/views.py`) also accept `current` and `all`; `all` returns the most recent row per `full_code` (ordered `-semester`, distinct) and is commented "Only used for Penn Degree Plan"; it rejects `days`, `time`, `instructor_quality` params. [inferred] "Is X offered in spring?" can be answered by checking the last 2-3 spring semesters; `courses` list only includes courses with sections (`sections__isnull=False`), and `all` loses the per-semester detail. Also `Course.parent_course` / `topic` link a course to its most recent previous-semester offering (`courses/models.py`). Review endpoints (`backend/review/urls.py`: `course/<code>`, `course_plots/`, `instructor/`, `department/`, `autocomplete`) are decorated `IsAuthenticated` in `review/views.py` (3 hits at lines 135, 354, 498), so likely need login; not confirmed which. [read directly for decorators, inferred for mapping]

5. **course_quality** is exposed in list/detail/section serializers [read directly] (aggregated review rating, from the cached review data).

6. **Penn Degree Plan (PDP) app exists: `backend/degree/`.** [read directly] Files: `models.py` (1048 lines), `serializers.py`, `views.py`, `urls.py`, `management/commands/{fetch_degrees,fetch_degrees_from_path,load_degrees,load_dual_programs,list_degrees,deduplicate_rules}.py`, `utils/{path_client,parse_path_audit,parse_degreeworks,degreeworks_client,degree_logic,double_counts,model_utils,composition,departments}.py`, `data/dual_programs/`.

7. **Degree data is NOT public through the API.** [read directly] `backend/degree/views.py`: `DegreeViewset`, `MajorViewset`, `MinorViewset`, `DualProgramViewset` (all `ReadOnlyModelViewSet`) have `permission_classes = [IsAuthenticated & InPDPBeta]`; `InPDPBeta` raises PermissionDenied unless the user is in `PDPBetaUser`. Router (`degree/urls.py`, no trailing slash): `/degrees`, `/majors`, `/minors`, `/dual-programs`, `/degreeplans`, `/docked`, `/degreeplans/<id>/fulfillments`, `onboard-from-transcript/<id>`, `satisfied-rule-list/...`. The comment "After Beta: remove this permission entirely" suggests it may open later. [inferred]

8. **Where Penn Labs gets requirements: Path@Penn's unauthenticated endpoints, not the catalog.** [read directly] `backend/degree/utils/path_client.py` docstring: "A client for the degree endpoints Path@Penn exposes at courses.upenn.edu. Path@Penn proxies DegreeWorks, and unlike the DegreeWorks server itself these endpoints need no authentication: the audits they return are what-if runs against a dummy student record (Stu_id="*", Stu_name="*Test"), so they describe the degree template and contain no student data." `BASE_URL = "https://courses.upenn.edu/api/"`; POST `?page=fose&route=programs-v2-list` (payload `{"srcdb": "202630", "programsType": ""}`) returns programs with codes like `CMPE-BSE`, `ANTH-BA-ARC`, `MATH-MINOR`; route `programs-v2-info` (`{"srcdb","programCode"}`) returns metadata incl. `sis_prog_code` (e.g. EU_BSE) and **`audit_xml`** (DegreeWorks audit XML). Term code maps to a catalog year (202630 serves the 2027 catalog, per `fetch_degrees_from_path.py` help). Client sends browser-like headers and defaults to 0.5 s between requests. Older path: `fetch_degrees.py` uses DegreeWorks with `PENN_ID`, `X_AUTH_TOKEN`, `REFRESH_TOKEN` env vars, i.e. a logged-in student's token (do NOT replicate this; the newer client replaced it). [read directly] Caveat: courses.upenn.edu was not reachable here, so I have not verified the endpoints still work, and whether scraping them is permitted by Penn's terms is unknown. [inferred] This is the only machine-readable requirements source found, and it is a clear candidate for "public template data, no login", but it needs a legal/ToS check and a human to test it from an unblocked network.

9. **Catalog (catalog.upenn.edu) structure and exports.** [search summary only] Search results list `https://catalog.upenn.edu/undergraduate/` ("2026-27 Undergraduate Catalog"), a program list PDF (`/undergraduate/programs/programs.pdf`), `/undergraduate/undergraduate.pdf` (full catalog PDF; indexed text showed a 2023-24 footer), and `/undergraduate/arts-sciences/majors/majors.pdf`. The `*.pdf` per section pattern is typical of CourseLeaf print exports. [inferred] I found no evidence of a JSON/XML "ribbit" API for Penn, and could not test (host blocked); the catalog's own vendor was not confirmed. Not read: any program page's actual requirement table (so "CU", "select N of" layout is [inferred] from general CourseLeaf convention only). No GitHub mirror of Penn catalog requirements was located within this pass.

10. **College general requirements are changing.** [search summary only] College of Arts & Sciences gen-ed has "Sectors of Knowledge" (7 sectors, one course each, sector courses listed in Path@Penn) and "Foundational Approaches" (which can double-count). A May 2026 Daily Pennsylvanian item (https://www.thedp.com/article/2026/05/penn-dean-struck-college-arts-sciences-curriculum-foundations) reports faculty approved a revised framework ("College Foundations", simplified gen-ed, Class of 2031 referenced). So requirements differ by entering year; any planner must key on catalog year. Total 36 CU appears in transfer admissions text; SEAS category details not researched. Source: https://www.college.upenn.edu/interpreting-degree-audit and https://www.college.upenn.edu/node/234 (search snippets only).

11. **How to parse prereq strings (e.g. "CIS 1200 AND (MATH 1400 OR MATH 1410)").** [inferred] Since Penn Labs only gives free text, a planner would need its own small grammar: tokenize course codes with a regex (`[A-Z]{2,4}\s?-?\d{3,4}`), handle `AND/OR/,/;`, parentheses, "or equivalent", "permission of instructor", co-requisites, and the shorthand "CIS 120, 160" (inherit the department). Expect a long tail that fails to parse; the sound design is parse-what-you-can plus a flagged "unparsed prerequisite" fallback. Note Penn moved to 4-digit course numbers (CIS 1200, formerly 120), so crosswalk is needed: `courses/management/commands/load_crosswalk.py` exists in penn-courses (name only; not read). [read directly for filename]

12. **Other open data.** SRFS timetable / registrar requirement lists / print PDFs: not reachable (all *.upenn.edu blocked). [search summary only] catalog PDFs exist as in item 9. Penn's own OpenData API (used by Penn Labs) needs registered client credentials. [read directly]

## How Penn Degree Plan encodes requirements

All from `backend/degree/models.py` [read directly] (class `Degree`, `Rule`, `DoubleCountRestriction`, `ProgramComponent`, etc.).

**Degree** (per program, major, concentration, year; unique constraint `["program","degree","major","concentration","year"]`):
- `program` CharField, choices `EU_BSE` Engineering BSE, `EU_BAS`, `AU_BA` College BA, `WU_BS` Wharton BS, `NU_BSN` Nursing, `EM_MSE` (submatriculant masters)
- `degree` ("BSE"), `major` ("BIOL"), `major_name`, `concentration` (code, null), `concentration_name`
- `year` IntegerField ("effective year, e.g., 2023")
- `rules` ManyToManyField("Rule", related_name="degrees")
- `credits` DecimalField(max_digits=4, decimal_places=2, null=True): "minimum number of CUs required for this degree"

**Rule** (a tree; deduplicated so one rule can belong to many degrees):
- `title` CharField(200)
- `num` PositiveSmallIntegerField(null): "minimum number of courses or subrules required"
- `credits` DecimalField(null): "minimum number of CUs required for this rule. Only non-null if this is a Rule leaf."
- `q` TextField(max_length=1000): "String representing a Q() object that returns the set of courses satisfying this rule. Non-empty iff this is a Rule leaf." A stringified Django `Q(...)`, parsed back by a Lark grammar in `utils/model_utils.py` (`q_object_parser`, and `json_parser` for `q_json`).
- `block_type`, `block_value`: audit block the rule came from (e.g. MAJOR / CMPE, OTHER / U-SEAS-SSH)
- `share_targets` JSONField(default=list): double-count permissions as `[{"kind": ..., "value": ...}]` from the audit's ShareWith (NONEXCLUSIVE) qualifiers; "An empty list means this rule may not double count with anything."
- `transfer_credit_allowed` BooleanField(default=True): whether AP/IB/transfer credit counts
- `parent` ForeignKey("self", null=True, related_name="children")

**Evaluation** (`Rule.evaluate(full_codes)`): leaf: runs `Course.objects.filter(q, full_code__in=full_codes)`, counts distinct full codes and sums `Course.credits`, then requires `total_courses >= num` and/or `total_credits >= credits`. Non-leaf: counts satisfied children; if `num` is None all children must pass, else at least `num` ("select N of"). `check_belongs(full_code)` asks if a course can count toward a leaf. So a requirement like "select 2 of {CIS 1210, CIS 1600, ...}" is a leaf with `num=2` and a `Q(full_code__in...)` / department / number-range filter. Wildcards (`@`) in audit course nodes map to `Q(department__code=...)`, `full_code__startswith`, `code__gte/lte` (`utils/parse_path_audit.py: parse_course`). Attribute-based requirements (e.g. sectors) use `With` qualifiers parsed by `parse_with` into attribute Q filters (not read in detail). [inferred for the sector link]

**Double counting**: two layers. (1) Per-rule `share_targets` resolved at request time in `utils/double_counts.py` (symmetric: if A names a block containing B, B may share with A). (2) `DoubleCountRestriction` model (`max_courses`, `max_credits`, FK `rule`) serialized on `DegreeDetailSerializer.double_count_restrictions`. Submatriculants capped at `MAX_SHARED_GRADUATE_CREDITS = Decimal(3)` and courses numbered 5000+ (`utils/degree_logic.py`).

**Additional models**: `ProgramComponent` / `Major` / `Minor` (own-block rules only, for second majors and minors), `ProgramVariant` (`rules`, `suppressed_rules`), `DualProgram` (`left_programs`, `right_programs`, `cu_floor`, `max_shared_cu`), `DegreePlan` (per-user), `Fulfillment` (`degree_plan`, `full_code`, `semester`, `rules`, `unselected_rules`, `legal`, `level`; semester `_TRAN` = transfer credit), `DockedCourse`.

**Not encoded**: prerequisites or when-offered ordering. Rules are only set-membership/count/CU thresholds over courses. [inferred] A prerequisite-aware, offering-aware ordering is something Smooth would have to add itself on top of the free-text prereqs and per-semester course lists.

## Sources
- https://github.com/pennlabs/penn-courses (cloned; files cited above)
- https://catalog.upenn.edu/undergraduate/ , /undergraduate/programs/programs.pdf , /undergraduate/undergraduate.pdf , /undergraduate/arts-sciences/majors/majors.pdf [search summary only]
- https://www.college.upenn.edu/node/234 , https://www.college.upenn.edu/interpreting-degree-audit [search summary only]
- https://www.thedp.com/article/2026/05/penn-dean-struck-college-arts-sciences-curriculum-foundations [search summary only]

## Blocked hosts
catalog.upenn.edu, all *.upenn.edu (incl. ngss.srfs.upenn.edu: ENOTFOUND, one try), courses.upenn.edu (assumed blocked under *.upenn.edu, not tested), penncoursereview.com, thedp.com, etc. api.github.com tree endpoint refused ("GitHub access not enabled"); raw.githubusercontent.com and git clone worked.

## Open questions
1. Do the Path@Penn `programs-v2-*` endpoints still work unauthenticated, and do Penn's terms allow Smooth to read them? (Needs a test from an unblocked network plus Penn ISC/Penn Labs contact.)
2. Is the course API semester endpoint public without a token in production (live test needed)? Does any response carry cross-semester offering history cheaply?
3. Will Penn Labs open the `/degrees` endpoints after PDP beta, or share a data dump (the model is MIT-licensed code, but data terms are unstated)?
4. What is the catalog's vendor/export format and does each program page have a stable print URL?
5. How does the new College Foundations curriculum map to audit blocks for classes of 2029-2031?
6. Quality of `prerequisites` text across departments (sample needed) and 3-digit to 4-digit crosswalk.
