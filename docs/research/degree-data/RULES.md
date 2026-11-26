# Penn degree rules found (2026-11-26)

The rules read during phase 1, by school and by kind. Read `SOURCES.md`
first for what each source is and how it was reached.

## How to read a rule

Every rule has an id, the rule in one sentence, a quote, where the quote
came from, the catalog year or cohort it applies to, and a status.

| Status | Meaning |
|---|---|
| **VERIFIED (scribe)** | Read by this session in a real Path@Penn audit XML template held in Penn Labs' public test fixtures ([GH] `pennlabs/penn-courses` @ `4111d6f`, `backend/tests/degree/fixtures/`, cloned 2026-11-26). The quote is the XML's own attributes and text. These fixtures are "real audits trimmed to the blocks under test"; the catalog year is the block's `Cat_yr_start`. |
| **VERIFIED (CIS)** | Read in the CIS Advising Handbook's source ([GH] `cis-advising-handbook/cis-advising-handbook.github.io` @ `e705b22`, 2026-11-09). An official department page, quoted exactly. |
| **VERIFIED (page, 2026-11-26)** | The words are on an official Penn page that a GitHub runner read on 2026-11-26 (`scripts/penn-catalog/verify-rules.mjs`, 579 pages). The quote is the page's own text; the Source says whether it was read live or from the Internet Archive because the live page answered 403. |
| **CORRECTED (page, 2026-11-26)** | The official page says something different from what the rule used to claim. The rule now states what the page says, with the page's words, and a `Was:` line gives the old claim. |
| **PARTLY VERIFIED (page, 2026-11-26)** | Some of the rule's claims or quoted fragments are on the page and others were not found; the rule says which is which. |
| **CODE (unofficial)** | Read in code that encodes an official page: IRS ([GH] `upenn/irs` @ `8f15aa5`) or Penn Labs ([GH] as above). Exact as to the code; the official page behind it was not read. |
| **REPORTED** | From a web-search summary on 2026-11-26. **The page was not fetched; the quoted words are as the search tool returned them and are UNVERIFIED as verbatim text.** Good enough to know the rule exists and where it lives; not good enough to ship in a record's `quote` field. |
| **CONFLICTING** | Sources disagree; both sides are given. |

The session that first wrote this file could not open any Penn page, so
every REPORTED rule came from a search summary. That is no longer true of
most of them: on 2026-11-26 a GitHub runner crawled 579 official pages and
searched them for every quoted fragment of the 73 rules that were REPORTED,
CONFLICTING or CODE (unofficial). It read `catalog.upenn.edu`,
`undergrad-inside.wharton.upenn.edu` (with the 2025-26 handbook PDF),
`academics.engineering.upenn.edu`, `www.nursing.upenn.edu` and several
single pages live; `www.college.upenn.edu`, `srfs.upenn.edu`,
`www.math.upenn.edu`, `figs.sas.upenn.edu` and `psychology.sas.upenn.edu`
answered 403 live and were read from the Internet Archive. `SOURCES.md` →
"Runner crawl, 2026-11-26" has the host list and the failures. A rule
still marked REPORTED or CODE (unofficial) was not found in those pages.

Counts: 108 rules. 32 are verified first-hand from files (22 from scribe
templates, 10 from the CIS handbook). Of the 73 that were reported or read
in code, 44 are now VERIFIED (page), 20 PARTLY VERIFIED, 4 CORRECTED, 1
CONFLICTING (CD-05, two official pages disagree), 3 remain CODE
(unofficial) and 1 remains REPORTED. Three rules were added from the same
pages (SEAS-41, WH-19, WH-20), all VERIFIED (page): 47 VERIFIED (page) in
all. The attribute tables follow in section 7.

---

## 1. University-wide

**U-01. Course-number levels.** 0001-3999 undergraduate; 4000-4999 mixed,
primarily undergraduate; 5000-5999 mixed, primarily graduate; 6000-9899
graduate; 9900-9999 graduate individual study.
Quote: "4000-4999 Mixed courses primarily for Undergraduate students";
"5000-5999 Mixed courses primarily for Graduate students"; "6000-9899
Graduate courses"; "9900-9999 Graduate individual study
(thesis/dissertation) courses".
Source: `https://srfs.upenn.edu/student-records/transcript-key` (archive
copy; the live page answered 403). `catalog.upenn.edu/undergraduate/policies-procedures/course-exam/`
was not among the pages that carried these words.
Cohort: all, from Summer 2022. Status: PARTLY VERIFIED (page, 2026-11-26).
The four upper bands are confirmed word for word; the "0001-3999
Undergraduate courses" line and "Effective Summer 2022" were not found in
the text the run printed, so the first band is still as reported.

**U-02. Four-digit numbers began Summer 2022.**
Quote: "Starting in Summer 2022, all courses across Penn transitioned from
3-digit course numbers to 4-digit numbers." "In many cases the translation
... is straightforward. E.g., in CIS we have appended a `0` ... However,
some departments have taken the opportunity to reorganize their courses
more substantively."
Source: [GH] CIS handbook `4-digit-conversion.md`
(`https://advising.cis.upenn.edu/4-digit-conversion/`). Status: VERIFIED
(CIS). The crosswalk is `assets/json/3d_to_4d_course_translation.json`.

**U-03. Term codes.** Penn: `YYYY10` spring, `YYYY20` summer, `YYYY30`
fall. Penn Labs: `YYYYA`, `YYYYB`, `YYYYC`. The scribe names the COVID
terms as `202010, 202020, 202030, 202110`.
Quote: "@ @ (With DWPASSFAIL = Y AND DWTERM <> 202010, 202020, 202030,
202110 )". Source: [GH] fixture `BIOL-BA.xml`, DEGREE block header.
Status: VERIFIED (scribe).

**U-04. A passed course cannot be repeated for credit.**
Quote: "A student may not repeat for credit any course in which a passing
grade (D or better) has been received."
Source: `https://www.math.upenn.edu/undergraduate/retaking-course-college-and-university-policies`
(archive copy; the live page answered 403). SEAS, read live at
`https://academics.engineering.upenn.edu/ugrad/student-handbook/`: "A
student may not repeat a course already passed (D or better)."
Status: VERIFIED (page, 2026-11-26).

**U-05. Dual-degree students must complete the requirements of both schools.**
Quote: "Dual-degree students must complete the requirements of both
schools in order to graduate."
Source: `https://undergrad-inside.wharton.upenn.edu/graduation-action-items/`
(read live).
Was: "A student in two schools must meet both schools' standing rules",
quoted as "students enrolled in more than one school must meet both
schools' rules" from `catalog.upenn.edu/undergraduate/policies-procedures/grade-gpa/`.
That wording and that page's text were not found; the closest official
sentence is about graduation, not standing.
Status: CORRECTED (page, 2026-11-26).

**U-06. Transfer credit versus equivalent credit; XCAT; grade floor.**
Credit earned before enrolling is transfer credit; credit earned
elsewhere while enrolled is "equivalent credit" (credit away, study
abroad). Requests go through XCAT. Minimum grade C. Credit away must be
approved before the course is taken.
Quotes: "XCAT is the online External Credit Approval Tool used to
determine credit at Penn for transfer, credit away and study abroad
courses for all students across all four undergraduate schools."; "A
minimum grade of C is required for a course to be eligible for transfer
credit."; "a student must secure approval for credit away courses through
the XCAT system BEFORE taking them."
Sources: `https://www.college.upenn.edu/academics/academic-options/campus-options/xcat-external-credit-approval-tool`
and `https://www.college.upenn.edu/equivalent-credit` (archive copies; the
live pages answered 403). The College's own definition: "When students
receive College credit for courses or other types of academic work done
elsewhere, it is referred to as equivalent credit." Not found:
`catalog.upenn.edu/undergraduate/policies-procedures/transfers/`.
Status: VERIFIED (page, 2026-11-26).

**U-07. Taking the Penn course forfeits the matching AP credit.**
Quote: "Students with AP credit who take the equivalent course at Penn
forfeit the AP credit".
Source: `https://academics.engineering.upenn.edu/ugrad/student-handbook/`
(read live; the same handbook's `.../transfer-academic-opportunities/advanced-placement/`
page was also read).
Status: VERIFIED (page, 2026-11-26).

**U-08. AP equivalents depend on the entering year.**
Quote: "Mathematics BC♦ 5 Math 1400 (1 c.u.) (Students entering 2024 and
earlier) Math 1300 (1 c.u.) (Students entering 2025 onward)".
Source: `https://admissions.upenn.edu/how-to-apply/first-year-applicants/pre-college-credits`
(read live).
Status: VERIFIED (page, 2026-11-26). Note the consequence: MATH 1300 is on
the SEAS no-credit list (SEAS-05), so the same AP score is worth nothing
to a BSE for a 2025 entrant.

**U-09. Submatriculation: each side caps the shared courses.**
Quote: "the undergraduate school and the graduate program/school limit
the number of courses that may concurrently satisfy requirements in both
degrees."
Source: `https://provost.upenn.edu/for-staff/graduate-program-admins/submatriculation/`
(read live).
Status: VERIFIED (page, 2026-11-26). School caps: CAS-18, SEAS-38, WH-13.

**U-10. How the scribe expresses double counting (the semantics every
school's template uses).** A rule or block with no `NONEXCLUSIVE`
qualifier shares with nothing; `NONEXCLUSIVE (MAJOR)` lets it share with
any other MAJOR block, `(OTHER = U-SEAS-WREE)` with that block,
`(THISBLOCK)` with rules in its own block; a `STANDALONEBLOCK` is audited
outside the degree's shared pool, so its courses also count elsewhere.
Quote: "Rules with no targets may not double count with anything, which
is DegreeWorks' default." and "STANDALONEBLOCK counts as a target: it
marks a block DegreeWorks evaluates outside the degree's shared pool of
courses ... That is how the College's General Education Foundations
block, a CS concentration and every minor work."
Source: [GH] Penn Labs `degree/utils/double_counts.py`,
`parse_path_audit.py`. Status: CODE (unofficial). Penn Labs flags its own
assumption: "within a block, courses are exclusive unless THISBLOCK says
otherwise ... the audit does not state it". Generic Degree Works guides
agree that "NONEXCLUSIVE is the same as Share and ShareWith" [SEARCH].
Not found in the 579 pages read on 2026-11-26 (these are statements about
the audit language, which no policy page makes).

**U-11. Plan-level limits the audits cannot state (Penn Labs' reading).**
A course may be claimed by at most two degrees; undergraduate and
graduate degrees share at most 3 CU, and only courses numbered 5000 or
above.
Quote: `max_degree_claims: int = 2`, `graduate_cu_limit: Decimal =
Decimal(3)`, `min_graduate_number: int = 5000`.
Source: [GH] `degree/utils/composition.py`. Status: PARTLY VERIFIED (page,
2026-11-26). Confirmed by official pages: the limit of two degrees (SEAS-30,
"No course may be triple counted, i.e., counted for more than two
degrees/majors.") and the 3 CU of graduate courses for Engineering
accelerated masters (SEAS-38) and Wharton (WH-13); the College allows 4
(CAS-18), so the single limit of 3 is not the College's. The 5000 floor was
not found in the 579 pages read on 2026-11-26; it remains as coded.

---

## 2. Penn Engineering (SEAS)

### 2.1 From the scribe (catalog year 2027 blocks)

**SEAS-01. A BSE needs at least 37 CU.**
Quote: `Name="CLASSESCREDITS" Credits="37" Label="Minimum Total Credits
Required"`. Source: [GH] `CMPE-BSE-2026.xml` and `MEAM-BSE-GEN.xml`,
DEGREE block. Status: VERIFIED (scribe).

**SEAS-02. Half the degree must be earned at Penn: 18.5 CU.**
Quote: `Name="MINRES" Credits="18.5" Label="Minimum Credits Earned from
University of Pennsylvania"`. Source: same. Status: VERIFIED (scribe).

**SEAS-03. Each major has its own minimum CU, residency and GPA.**
CSCI: 29 CU, 14.5 at Penn; CMPE: 29 CU, 15 at Penn; MEAM: 30 CU, 15 at
Penn; all "Minimum Major GPA of 2.0 Required".
Quote: `Credits="29" Label="Minimum Credits Requirement"`, `Name="MINRES"
Credits="14.5"`, `Name="MINGPA" MinGPA="2"`. Source: [GH]
`CSCI-BSE-NCON.xml`, `CMPE-BSE-2026.xml`, `MEAM-BSE-GEN.xml`. Status:
VERIFIED (scribe).

**SEAS-04. General Electives (SSH) is its own 7-CU block.**
Quote: block `Req_type="OTHER" Req_value="U-SEAS-SSH" Title="General
Electives"`, `Credits="7" Label="Minimum Credits Requirement"`. Rules: 
"Engineering Ethics (LAWM 5060 sections titled Technology Law and Ethics
only)" 1 CU from `CIS 4230, CIS 5230, EAS 2030, LAWM 5060`; "Humanities
or Social Science" 4 CU `@ @ (With ATTRIBUTE=EUHS,EUSS)`; "Humanities,
Social Science, or Technology in Business and Society" 2 CU
`(With ATTRIBUTE=EUHS,EUSS,EUTB)`. Source: [GH] `CMPE-BSE-2026.xml`.
Status: VERIFIED (scribe).

**SEAS-05. Courses a BSE degree never counts (the no-credit list as the
scribe holds it).**
Quote: `MAXCLASS Classes="0"`: "ASTR 0001, EAS 5030, 5050, CIT @, DYNM @,
FNCE 0001, 0002, HCMG 0001, MATH 1300, 1510, 1700, MGMT 0004, MKTG 0001,
MED 0000:9999, MSCI 0000:9999, NSCI 0000:1019, 1021:2009, 2011:2019,
2021:3009, 3111:4009, 4011:4019, 4021:9999, OIDD 0001, PHYS 0000:0049,
0052:0139, STAT 0000:4049, 4051:4219, 4221:4290, CHEM 001:001 (With
DWTERM < 202220 )"; and separately `COLL 0@`, `MSCI @`, `NSCI @`, and
`@ @ (With DWAGE > 8 )` (courses older than eight years).
Source: [GH] `CMPE-BSE-2026.xml`, DEGREE block, tags `ALDCED`,
`MXCLHCOLL`, `MXCLHMSCI`, `MXCLHNSCI`, `MXCLHDW`. Status: VERIFIED
(scribe). IRS encodes the same list from the handbook (`suhSaysNoCredit`:
subjects CIT, MSCI, DYNM, MED; STAT below 4300 except 4050 and 4220; PHYS
below 0140 except 0050 and 0051; plus "CHEM 1011", "PHYS 1100"), with
small differences from the scribe: CONFLICTING in detail (CHEM 1011 and
PHYS 1100 are in IRS's list and not in this template; the handbook's two
hosts also differ, see `SOURCES.md` S22).

**SEAS-06. Pass/fail: at most 4 CU in the degree, none in the major.**
Quote: DEGREE block `MAXCREDIT Credits="4"` on "@ @ (With DWPASSFAIL = Y
AND DWTERM <> 202010, 202020, 202030, 202110 )"; MAJOR block the same
qualifier with `Credits="0"`. Source: [GH] `CMPE-BSE-2026.xml`,
`CSCI-BSE-NCON.xml`. Status: VERIFIED (scribe). Handbook side (REPORTED):
"Engineering students may only take four courses pass/fail during their
academic career. Only one course per semester may be taken P/F." "The
only courses which may be taken P/F are SS/H and Free Electives."
(`.../undergraduate-policies/pass-fail/`, an old-host page.)

**SEAS-07. What a SEAS major block may share with.**
Quote: MAJOR block header `NONEXCLUSIVE` "(MAJOR)", "(MINOR)", "(CONC)".
Source: [GH] `CSCI-BSE-NCON.xml`, `CMPE-BSE-2026.xml`, `MEAM-BSE-GEN.xml`.
Status: VERIFIED (scribe). Meaning: a course in the major may also count
toward another major, a minor or a concentration; it does **not** name
the SSH block, so a major course does not also fill SSH unless the SSH
side says so (SEAS-08).

**SEAS-08. What the SSH block may share with.**
Quote: `NONEXCLUSIVE` "(OTHER = U-SEAS-WREE)", "(CONC)", and "(MAJOR =
AFRC, MAJOR = ANCH, MAJOR = ANTH, ... MAJOR = URBS, MAJOR = VLST, MAJOR =
MELC, MAJOR = FIGS, MAJOR = LAWS)" (about sixty College majors by code).
Source: [GH] `CMPE-BSE-2026.xml`, tag `AFLBLX`. Status: VERIFIED
(scribe). Meaning: SSH courses double count with a **College second
major** and with the writing block, and with no engineering major. This
is the machine form of "an SSH course may count toward a College major".

**SEAS-09. The writing course sits inside SSH and shares within it.**
Quote: Group "Writing Course" with `NONEXCLUSIVE (THISBLOCK)`; three
options "Social Sciences Writing Course" (`WRIT 0160, WRIT 0170, ...`),
"Humanities Writing Course" (`WRIT 0020, WRIT 0100, ...`), "Tech,
Business, and Society Writing Course" (`WRIT 0210, WRIT 0220, WRIT 0310,
WRIT 0400, WRIT 0650, WRIT 0740`). Source: [GH] `CMPE-BSE-2026.xml`.
Status: VERIFIED (scribe). So the writing seminar counts as one of the 7
SSH CU, in the category its number maps to.

**SEAS-10. CSCI technical electives: at most 1 CU restricted.**
Quote: "Restricted or Unrestricted Technical Electives" `Credits_begin=1`
`@ @ (With ATTRIBUTE=EUCR), @ @ (With ATTRIBUTE=EUCU)`; "Unrestricted
Technical Electives" `Credits_begin=5` `@ @ (With ATTRIBUTE=EUCU)`.
Source: [GH] `CSCI-BSE-NCON.xml`. Status: VERIFIED (scribe). The handbook
says the same in words: "Students can have at most 1 CU of **restricted**
courses in their Technical Electives. The remaining CUs must be fulfilled
with **unrestricted** courses. For courses that are marked **ask**, the
undergrad chair will determine whether the course is unrestricted,
restricted or cannot count." ([GH] `tech-electives.md`, "Rules for
students entering Fall 2024 and later". VERIFIED (CIS).)

**SEAS-11. CSCI technical electives, students entering before Fall 2024.**
Quote: "Students can have **no more than one CU of 1000-level
coursework** among their Technical Electives. ... Only courses that are
marked as **yes** in the table below, or that are marked **ask** and have
been approved by the undergrad chair, can be used as TEs."
Source: [GH] `tech-electives.md`. Status: VERIFIED (CIS). The JSON field
is `status_prefall24`.

**SEAS-12. A course missing from the CIS list is undecided, not
refused.**
Quote: "If the course you are interested in is not listed, that does not
necessarily mean that it does not count; it simply means that we have not
considered the course yet."
Source: [GH] `tech-electives.md`. Status: VERIFIED (CIS). The CSCI list
also serves ASCS and ARIN: "everything approved (i.e.,
yes/unrestricted/restricted) on the CSCI list below *does count* as a
Technical Elective for these degrees as well"; NETS technical electives
"have different rules".

**SEAS-13. CSCI area lists are overlays, not extra courses.**
Quote: header qualifiers `Name="MINCLASS" Classes="1" Label="Area List -
Networking"` "NETS 1500, 2120, CIS 4510, 5510, 4550, 5550, 5050, 5530,
3310"; "Area List - Databases" "CIS 4500, 5500, 4550, 5550, 2450, 5450";
"Area List - Distributed Systems" "NETS 2120, CIS 4410, 5410, 4500, 5500,
5050, 2450, 5450"; "Area List - Machine Learning/AI" "CIS 4190, 5190,
4210, 5210, 5200, 2450, 5450, 6200"; "Area List - Project" "NETS 2120,
CIS 3500, 4120, 5120, 4410, 5410, 4500, 5500, 4521, 5521, 4550, 5550,
4600, 5600, 5050, 5530, ESE 3500, CIS 3410".
Source: [GH] `CSCI-BSE-NCON.xml`, MAJOR header. Status: VERIFIED
(scribe). Penn Labs' reading: "These constrain the courses already
applied rather than competing for them". This confirms `policy.ts`'s
area-list rule and gives the lists (the planner's fixture has an older
Networking list without CIS 3310).

**SEAS-14. Courses that never count as a CIS elective.**
Quote: `Except`: "CIS 1050, CIS 1060, CIS 1070, CIS 1250, CIS 1600, CIS
2610, CIS 3333, CIS 4230, CIS 5230, CIS 7980, @ 2960, @ 2970" on "CIS
Elective" (`CIS 0099:9999, ESE 3500, NETS 1000:5999`); the 2000-level
elective takes `CIS 2000:9999, ESE 3500, NETS 2000:5999` with the same
exclusions less the 1000-level ones.
Source: [GH] `CSCI-BSE-NCON.xml`. Status: VERIFIED (scribe). `@ 2960`
and `@ 2970` are the study-abroad placeholder numbers in any subject.

**SEAS-15. CSCI senior project runs as two named courses.**
Quote: "Senior Project #1" `CIS 4000, CIS 4100`; "Senior Project #2"
`CIS 4010, CIS 4110`. Source: [GH] `CSCI-BSE-NCON.xml`. Status: VERIFIED
(scribe). The fall-then-spring order is stated in the course description
("The project continues during two semesters; students must enroll in CIS
401 during the second semester", [RUN] Penn Labs detail for CIS 4000).

**SEAS-16. The CS minor is 6 CU and stands alone.**
Quote: block `MINOR CSCI` `Credits="6"`, header `STANDALONEBLOCK`.
Source: [GH] `CSCI-MINOR.xml`. Status: VERIFIED (scribe).

### 2.2 From the CIS handbook

**SEAS-17. Credit limit and overloads.**
Quote: "CU limit increases must be requested _each_ semester." "Students
pursuing multiple undergraduate degrees (not dual-majors, and not
Accelerated Masters students) can receive a CU increase for Advance
Registration. All other students can only request an increase at the
beginning of the semester". "Generally, you need a 3.0 GPA and
demonstrated ability to handle _X_ CUs if you want a limit of _X+1_ CUs."
"If you are eligible, you can submit a CU limit raise request for 6 or
6.5 CUs. CU limits of 7 CUs require a SEAS Petition, and are rarely
granted."
Source: [GH] `cu-limit.md` (`https://advising.cis.upenn.edu/cu-limit/`).
Status: VERIFIED (CIS). School page (REPORTED): "The typical full-time
load is 4.0 to 5.5 course units"; the department may raise "from 5 to 6
cu or 5.5 to 6.5 cu (one cu increment) if the student is in good academic
standing (a 3.0 gpa or better and no outstanding incompletes)"; "If a
student wishes to increase their CU limit by more than 1 CU, or wishes to
request an extraordinary overload (e.g., 7 CUs), this request must also
be reviewed by the Penn Engineering Petitions Committee."
(`.../academic-policies/enrollment/`; part from the dev mirror).

**SEAS-18. Engineering minors: graded only, two "specified" courses at
most shared.**
Quote: "none of the courses in the minor can be pass/fail, or that no
more than two _specified_ courses on your CPG can be double-counted
towards a minor." "A course is **specified** on your CPG if there is a
requirement that can be fulfilled by _only_ that single course."
Source: [GH] `minor.md`. Status: VERIFIED (CIS). Handbook (REPORTED):
"Engineering minors consist of at least 6 course units, all of which must
be taken for a grade." "No more than two courses in the engineering minor
may be double counted with courses specified on the student's Course
Planning Guide."

**SEAS-19. No minor from your own department.**
Quote: "CSCI students cannot do a minor in Computer Science, Data
Science, or Digital Media Design." Source: [GH] `minor.md`. Status:
VERIFIED (CIS).

**SEAS-20. Concentrations: one per degree, no extra courses, no
substitutions.**
Quote: "There is a **limit of one concentration per degree**." "a
concentration does not require any extra classes ... you can draw them
from _anywhere_ on your CPG." "The set of courses that count towards each
concentration is fixed, and substitutions are not allowed." "For CIS
degrees, **only students in the CSCI and CMPE programs** can currently
declare concentrations."
Source: [GH] `concentration.md`. Status: VERIFIED (CIS).

**SEAS-21. Substitutions need a form before the course is taken.**
Quote: "You can submit a Core Requirement Substitution Form to take a
more advanced CIS course in place of CIS 1100." "**Approval is not
guaranteed**, so make sure you do this **before** you take the course".
An unapproved swap fails the senior audit unless there is "an approved
Core Course Substitution Form or an approved Petition for Action".
Source: [GH] `degree-requirements.md`, `senior-audit.md`. Status:
VERIFIED (CIS).

**SEAS-22. Credit away: three limits students miss.**
Quote: "you cannot use credit from courses you took while still in high
school, or the summer after high school, unless the course was taken at
Penn"; "you cannot use credit away to replace a course you failed at
Penn". CIS grants `CIS 2970` / `CIS 2980` for advanced courses with no
Penn twin ("CIS 2980 credit is given for major-related courses and can be
used in the Engineering category; CIS 2970 is awarded for courses that do
not qualify") and `CIS 0000` as "a 'free CIS credit'. It can be used as a
1000-level CIS Elective ..., Technical Elective, or Free Elective."
Source: [GH] `xcat.md`. Status: VERIFIED (CIS).

**SEAS-23. The worksheet is the certifying record, and it can be wrong.**
Quote: "Path worksheets also employ an auto-assignment of courses to
degree requirements, which is sometimes not particularly intelligent
(e.g., it will put a course into a Free Elective slot when it could count
elsewhere); and there is no way for students to rearrange courses". "they
are the official documentation of a student's degree and are being used
to certify graduation." (Section dated "last updated 16 September 2022".)
Source: [GH] `worksheet.md`. Status: VERIFIED (CIS), old. It bears on how
far the planner should trust where the audit put a course.

### 2.3 From IRS (code that encodes the SEAS handbook)

**SEAS-24. SS/H depth: two courses in one subject.**
Quote: `const depthKeys = Array.from(counts.keys()).filter(k =>
counts.get(k)! >= 2)`; exceptions coded: "EAS 5450" with "EAS 5460"; and
`// "BEPP 2500 may be used as SS Depth along with ECON 0110 (ECON 010)"`.
Source: [GH] `degree_requirements.ts`, `RequirementSshDepth`. Status:
PARTLY VERIFIED (page, 2026-11-26). Handbook, read live at
`https://academics.engineering.upenn.edu/ugrad/student-handbook/courses-registrations/course-requirements/social-science-and-humanities-courses/`:
"a student should choose courses of personal interest which will provide
in-depth study (2 or more courses) of at least one subject". The
handbook's exception reads "BPUB 2500 may be used as SS Depth along with
ECON 0110" (the code names the course BEPP 2500). The EAS 5450 with EAS
5460 exception was not found in the 579 pages read; it remains as coded.

**SEAS-25. Category definitions the handbook fixes (Math, Natural
Science, Engineering, TBS).** Encoded as definitive in IRS:
Math = subject ENM, or MATH numbered 1400 and up except "1100, 1234,
1248, 1300, 1510, 1700, 1720, 1800, 2100, 2800", or "CIS 1600", "CIS
2610", "CIS 3333", "ESE 2030", "ESE 2100", "ESE 3010", "ESE 4020", "ESE
5420", "ESE 5300", "PHIL 1710", "PHIL 4723", "STAT 4300", "STAT 4310",
"STAT 4320", "STAT 4330". Engineering = subjects "ENGR, TCOM, NETS, BE,
CBE, CIS, ESE, MEAM, MSE, IPD, NANO, ROBO, SCMP, BIOT, DATS" below 6000,
less a not-engineering list ("CIS 1050", "CIS 1060", "CIS 1070", "CIS
1250", "CIS 4230", "CIS 5230", "CIS 7980", "ESE 1120", "MEAM 1100", "MEAM
1470", ...), less Math, and never numbers 2960 or 2970. TBS = a fixed
list ("CIS 1070", "CIS 1250", "CIS 4230", "CIS 5230", "MGMT 2370", "OIDD
2360", "WH 1010", "LAWM 5060", EAS numbers 2020 ... 5950, ...).
Source: [GH] `degree_requirements.ts`, `suhSaysMath`, `suhSaysEngr`,
`suhSaysTbs` ("this IS intended to be a definitive classification").
Status: PARTLY VERIFIED (page, 2026-11-26). The handbook's Course
Category Lists page (`https://academics.engineering.upenn.edu/ugrad/student-handbook/courses-registrations/course-categories/`,
read live) confirms: Engineering courses are "all undergraduate and
5000-level graduate courses (including ENGR, TCOM, and NETS courses)
offered by Penn Engineering"; "Any engineering course numbered 2960 or
2970" is excepted; "CIS (CSE): 1050, 1060, 1070, 1250, 1600, 2610, 3333,
4230, 5230, 7980" are excepted; and Math is "MATH: Any course from MATH
1400 or above, except the following: 1700, 1720, 1800, 2100, 2800" (the
code also excludes MATH 1510, which the page does not). The code's full
subject list, its Math add-ons and the TBS list were not matched line by
line, so they remain as coded. Social Science and Humanities are coded as
"NOT an exhaustive list, and should be used in addition to course
attributes".

**SEAS-26. Attributes can be missing; the handbook wins.**
Quote: "MANUAL HACKS DUE TO ATTRIBUTES MISSING IN CURRICULUM MANAGER";
"add EUCR/EUCU attributes, which only entered use in Spring 2024";
`'has deprecated attribute ' + CourseAttribute.MathNatSciEngr` (EUMS).
Source: [GH] `degree_requirements.ts`. Status: CODE (unofficial). Bears
on trusting an attribute index alone. Not found in the 579 pages read on
2026-11-26.

**SEAS-27. Half-credit labs and 1.5-CU courses.**
Quote: `CoursesWithLab15CUs = ["BIOL 1101", "BIOL 1102", "PHYS 0150",
"PHYS 0151", "PHYS 0170", "PHYS 0171", "ESE 1120"]`;
`StandaloneLabCourses05CUs = ["BIOL 1123", "CHEM 1101", "CHEM 1102",
"PHYS 0050", "PHYS 0051", "MEAM 1470"]`.
Source: [GH] `degree_requirements.ts`. Status: CODE (unofficial); not found in the 579 pages read on 2026-11-26.
The scribe agrees on a 0.5-CU lab slot: "Natural Science Lab"
`Credits_begin=0.5` (`BIOL 1124, CHEM 1101, MEAM 1470, PHYS 0050`,
[GH] `CMPE-BSE-2026.xml`, VERIFIED (scribe)).

### 2.4 From the SEAS handbook and school pages (search summaries)

**SEAS-28. Dual degree with another school: at least 46 CU.**
Quote: "The number of required course units is specific to each program,
but the minimum requirement for any dual degree student with Engineering
is 46 course units."
Source: `https://academics.engineering.upenn.edu/ugrad/student-handbook/`
(read live; the same words are on `.../programs-options/dual-degrees-and-special-programs/`),
and `https://www.seas.upenn.edu/dual-degrees/` ("The number of course
units required is specific to each program, but the minimum requirement is
46 course units"). The handbook also says: "All dual degrees with
engineering require a minimum of 46 course units". Status: VERIFIED (page,
2026-11-26).
**Not in `policy.ts` today.**

**SEAS-29. Dual degree eligibility.**
Quotes: "only students of demonstrated ability and a 3.0 cumulative GPA
or higher will be considered for dual degree status"; "a minimum of eight
(8) Penn course units"; "students applying from the Wharton School
require a minimum GPA of 3.4 for consideration". Source: `https://academics.engineering.upenn.edu/ugrad/student-handbook/`
(read live). Status: VERIFIED (page, 2026-11-26).

**SEAS-30. No triple counting.**
Quote: "No course may be triple counted, i.e., counted for more than two
degrees/majors." Source: `https://academics.engineering.upenn.edu/ugrad/student-handbook/`
(read live; also on `.../programs-options/dual-majors/`).
Status: VERIFIED (page, 2026-11-26). Matches `policy.ts` `crossDegree.maxPerDegree` and U-11.

**SEAS-31. For a dual degree whose home school is Engineering, no-credit courses count toward neither degree.**
Quote: "Dual degree students whose home school is Engineering may not apply
No Credit courses towards either degree or towards the 46 CU minimum."
Source: `https://academics.engineering.upenn.edu/ugrad/student-handbook/`
(read live).
Was: "No-credit courses count toward neither degree" for any dual degree;
the page limits the sentence to dual-degree students whose home school is
Engineering.
Status: CORRECTED (page, 2026-11-26).

**SEAS-32. Wharton and Engineering together require a statistics
sequence.**
Quote: "a one-year probability and statistics sequence which may be
satisfied with either ESE 3010/4020 or STAT 4300/4310". Source:
`https://academics.engineering.upenn.edu/ugrad/student-handbook/` (read
live); the catalog's Wharton curriculum page (read live) lists "STAT 4300
Probability or ESE 3010 Engineering Probability". Status: VERIFIED (page,
2026-11-26). Penn Labs' M&T encoding has the same
pairs ("Probability" `ESE-3010 | STAT-4300`, "Statistical Inference"
`STAT-4310 | ESE-4020`, [GH] `mt.py`).

**SEAS-33. Dual major inside SEAS.**
Quotes: "They must satisfy the requirements for each major. Only one senior
design project is required for dual majors in engineering"; "They must
take a minimum of 22 Engineering courses". Source:
`https://academics.engineering.upenn.edu/ugrad/student-handbook/programs-options/dual-majors/`
(read live). Status: VERIFIED (page, 2026-11-26).

**SEAS-34. Summer limit: 4 CU a summer, Penn and elsewhere together.**
Quotes: "Students may take a maximum of 4 course units (CUs) during the
summer term, whether the courses are taken at Penn, another institution,
or a combination of both."; "Students taking summer courses may not
exceed 4 course units (CUs) for the 11-Week Session and no more than 2
CUs for Summer Session I or Summer Session II." Source:
`https://academics.engineering.upenn.edu/ugrad/student-handbook/academic-policies/enrollment/`
(read live). Status: VERIFIED (page, 2026-11-26).
**Disagrees with `policy.ts`**, which holds `summerPerTerm: 2,
maxSummerTotal: 4` and reads the 4 as a lifetime total (the project notes
say "2 cu a summer and 4 in all"). The page says 4 is per summer term and
2 is per Summer Session I or II, and states no cap across summers.

**SEAS-35. Credit away.**
Quotes: "Penn Engineering students may take up to 4 course units (CUs) for
credit at other institutions"; "A minimum grade of 'C' is required";
"no credit will be granted for courses taken at two-year institutions";
"Credit Away courses may only be taken during the summer term."; study
abroad courses "numbered 2960 or 2970 ... may NOT be used in the
'Engineering' category". Source:
`https://academics.engineering.upenn.edu/ugrad/student-handbook/` (read
live; also `.../transfer-academic-opportunities/`). Status: VERIFIED
(page, 2026-11-26).

**SEAS-36. Free electives.**
Quote: "any course offered by the University to undergraduates may be
taken as a free elective for an Engineering degree unless it is in the No
Credit list"; "effective Fall 2021 STAT 4050 and STAT 4220 can only be
used as free electives". Source:
`https://academics.engineering.upenn.edu/ugrad/student-handbook/` (read
live; also `.../course-categories/free-electives-and-no-credit-courses/`).
Status: VERIFIED (page, 2026-11-26).

**SEAS-37. TBS may replace up to two SSH courses; ethics adds no units.**
Quote: "may choose to substitute up to two of the required social science
and humanities courses with approved courses from the Technology in
Business and Society course category". The claim that the Ethics Requirement "adds no units ... because it can
double-count toward social science, humanities, or TBS" was not found.
Source: `https://academics.engineering.upenn.edu/ugrad/student-handbook/`
(read live; the substitution sentence on the SSH page reads "may choose to
substitute up to two of social science and humanities courses with
approved courses from the Technology in Business and Society course
category"). Status: PARTLY VERIFIED (page, 2026-11-26): the TBS
substitution is confirmed, the ethics sentence is still as reported.
Consistent with SEAS-04.

**SEAS-38. Accelerated master's: three graduate CU may count twice.**
Quote: "Students may double count up to three course units (CUs) of
graduate courses to fulfill both undergraduate and graduate degree
requirements." Source:
`https://academics.engineering.upenn.edu/ugrad/student-handbook/` (read
live). Status: VERIFIED (page, 2026-11-26).
IRS caps cross-degree double counts at 3 (`doubleCountedCourses.length <
3`, CODE).

**SEAS-39. Good standing and pace.**
Quotes: "a minimum cumulative GPA of 2.0"; "Academic progress is defined
as averaging a minimum of eight successfully completed course units each
academic year." Source:
`https://academics.engineering.upenn.edu/ugrad/student-handbook/` (read
live). Status: VERIFIED (page, 2026-11-26).

**SEAS-40. Per-major elective rules in the catalog (examples).**
Artificial Intelligence BSE: "Must be from one of the following approved
lists: SEAS Engineering (EUNG), CIS Restricted Technical Electives
(EUCR), and CIS Unrestricted Technical Electives (EUCU)", at most 1 CU at
the 1000 level. Electrical Engineering BSE: "Intermediate ESE Electives are 2000+ level
with an EUNG course attribute (exclude attribute EUMA)". MSE: "MSE
Elective (MSE 0000-4999)". Source:
`https://catalog.upenn.edu/undergraduate/programs/{artificial-intelligence-bse,electrical-engineering-bse,materials-science-engineering-bse}/`.
Status: PARTLY VERIFIED (page, 2026-11-26): the three quoted elective
rules are on the catalog pages (read live); the Artificial Intelligence
"at most 1 CU at the 1000 level" was not checked. The scribe form of the
CMPE equivalents is VERIFIED: "Intermediate CIS or ESE Elective"
`CIS 2000:5999, ESE 2000:5999` except `ESE 4020, ESE 5420`; "Professional
Elective Course" `ENGR 5400, EAS 5450, EAS 5950, MGMT 2370, OIDD 2360, @ @
(With ATTRIBUTE=EUNS,EUMA,EUNG)` ([GH] `CMPE-BSE-2026.xml`).

**SEAS-41. Engineering course load: 4.0 to 5.5 CU typical; a department may add 1 CU; 6.5 CU maximum for dual-degree students and seniors; more goes to the Petitions Committee.**
Quotes: "The typical full-time course load for an undergraduate engineering
student in good standing ranges from 4.0 to 5.5 course units (CUs)."; "First-semester students are not permitted to register for more than
5.5 CUs."; "Departments may approve an increase for up to 1 CU (compared
to the semester immediately preceding), as long as the student is in good
academic standing (e.g., GPA of at least 3.0, no Incompletes on their
record, and all grades submitted)."; "No course load increases will be
considered during advance registration except for those made by dual
degree students and seniors who need more CUs to graduate on time (6.5 CU
maximum)."; "If a student wishes to increase their CU limit by more than 1
CU, or wishes to request an extraordinary overload (e.g., 7 CUs), this
request must also be reviewed by the Penn Engineering Petitions
Committee. Be advised that such requests are granted in exceptional
circumstances only." Source:
`https://academics.engineering.upenn.edu/ugrad/student-handbook/academic-policies/enrollment/`
(read live). Cohort: current. Status: VERIFIED (page, 2026-11-26). The
summer limits on the same page are SEAS-34. SEAS-17 (the CIS handbook)
quotes older school-page wording ("from 5 to 6 cu or 5.5 to 6.5 cu") that
this run did not find on the live page; the wording above is the live
page's.

---

## 3. College of Arts and Sciences

### 3.1 From the scribe (BA templates, catalog year 2027)

**CAS-01. Degree totals and residency.**
Quote: `CLASSESCREDITS Credits="36" Label="Minimum Total Credits
Required"`; `MINRES Credits="18"`; `Name="LASTRES" Needed="5" Label="Last
5 Courses Taken in Residence"`. Source: [GH] `BIOL-BA.xml`, DEGREE block.
Status: VERIFIED (scribe) for a Biology BA; the total varies by major
(CAS-13).

**CAS-02. An Arts and Sciences floor inside the total.**
Quote: `MINCREDIT Credits="31" Label="Arts and Sciences 31 CU
Requirement"` over "AAMW @, AFRC @, AFST @, ..." (the list ends "ENVS @,
@ @ (With ATTRIBUTE = AU16)" per Penn Labs' parser note). Source: [GH]
`BIOL-BA.xml`. Status: VERIFIED (scribe) for Biology; the number is per
major. `AU16` is "College 16 CU Requirement": "any course with the
attribute AU16 ('College 16 CU') in Path@Penn counts as an Arts &
Sciences credit" (REPORTED, catalog College curriculum page).

**CAS-03. ROTC courses do not count.**
Quote: `MAXCLASS Classes="0"` "MSCI @, NSCI @" (tag `MXCLH_ROTC`).
Source: [GH] `BIOL-BA.xml`, `CSCI-BA.xml`. Status: VERIFIED (scribe).

**CAS-04. Pass/fail: 8 CU in the degree, none in Foundations or the
major.**
Quote: DEGREE `MAXCREDIT Credits="8"` on "@ @ (With DWPASSFAIL = Y ...)";
block `U-GE-FND` and MAJOR blocks the same with `Credits="0"`. Source:
[GH] `BIOL-BA.xml`. Status: VERIFIED (scribe). Policy side (REPORTED):
"Students may take no more than 8 c.u. pass/fail"; "Courses taken to
fulfill any Foundational Approach Requirement, the Sector Requirement,
the Major Requirement or a minor cannot be taken pass/fail."
(`https://www.college.upenn.edu/pass-fail`).

**CAS-05. Foundations: six classes, no AP or transfer credit, shares
with everything.**
Quote: block `OTHER U-GE-FND` "General Education, Foundations",
`Classes="6" Label="Minimum Classes Requirement"`; `MAXCLASS Classes="0"`
on "@ @ (With DWTRANSFERSCHOOLID = EQIVAP, EQIVIB, EQIVEX, EQIVAS )";
`MAXCLASS Classes="0"` on "@ @ (With DWGRADELETTER = S )";
`STANDALONEBLOCK`. Rules: "Foreign Language" `(With ATTRIBUTE=AULL)` with
a `MINGRADE`; "Quantitative Data Analysis" `AUQD`; "Formal Reasoning and
Analysis" `AUFR`; "Cross Cultural Analysis" `AUCC`; "Cultural Diversity
in the U.S." `AUCD`; "Writing Course" `WRIT 0000:0991, WRIT 0998` except
`WRIT 135@, WRIT 138@`. Source: [GH] `BIOL-BA.xml`. Status: VERIFIED
(scribe). Policy side (REPORTED): "With the exception of the Foreign
Language Requirement, none of these requirements may be satisfied with
advanced placement credit (including A-Levels, IB and other similar
credit based on external examination)."

**CAS-06. A College major shares with other majors and concentrations.**
Quote: MAJOR header `NONEXCLUSIVE` "(MAJOR)", "(CONC)". Source: [GH]
`BIOL-BA.xml`, `MATH-BA-GEN.xml`, `CSCI-BA.xml`. Status: VERIFIED
(scribe). The scribe sets no numeric cap; departments add theirs
(CAS-12).

**CAS-07. Major minimums are per major.**
Biology 17 CU, 8 at Penn; Mathematics 13 CU, 7 at Penn; Computer Science
BA 12 CU, 6 at Penn; each "Minimum Major GPA of 2.0 Required"; Biology
caps `BIOL 3999` at 1 CU; Mathematics allows at most one course with
attribute `AMOR` and sets `MINGRADE 2.0`. Source: [GH] the three
fixtures. Status: VERIFIED (scribe).

### 3.2 From College policy pages and books (search summaries)

**CAS-08. Foundational Approaches may double count, but not with each
other.**
Quote: "Courses may be double counted between a Foundational Approach and
the Sector Requirement, and between a Foundational Approach and the
major, but not among two or more Foundational Approaches." Source:
`https://catalog.upenn.edu/undergraduate/arts-sciences/curriculum/` (read
live); the same sentence is on the College's double-counting policy page
(archive copy; the live page answered 403). Cohort: current curriculum
(through the Class of 2030). Status: VERIFIED (page, 2026-11-26).
Consistent with the scribe's `STANDALONEBLOCK` (CAS-05).

**CAS-09. Major and Sector.** Two generations of the rule:
(a) older books: "most students may double count no more than one course
toward both the Major and the Sector Requirement"; "Students with a
double major may double count one course for each major" (policy PDFs
such as `C24.pdf`); (b) current page: "Each major has a designated Sector
that will be auto-completed upon the declaration of the major. The
remaining Sectors must be fulfilled by non-major courses."; "Majors which
have two Sectors auto-completed include, but are not limited to,
Neuroscience, Biology, Biophysics and Earth Science."; "If a student
declares a second major that auto-completes the same Sector as their
first major, a major advisor will make an exception to auto-complete a
different Sector." Source (b):
`https://catalog.upenn.edu/undergraduate/arts-sciences/curriculum/` (read
live) and `https://ppe.sas.upenn.edu/study/curriculum/ppe-policies` (the
first sentence); the College's double-counting page carries all three
(archive copy). Status: PARTLY VERIFIED (page, 2026-11-26): (b) is
confirmed word for word. (a) was not found: the policy books are not among
the pages read, and the College's degree-requirements page says only
"Students who declare more than one major should consult with each major
advisor regarding rules for any potential double-counting between the two
majors" (archive copy). The two are **different rules for different
cohorts**, which is why the College publishes a policy book per class
(`SOURCES.md` S20). Which class changed over is still unverified.

**CAS-10. One course, one sector.**
Quote: "One course cannot be used to fulfill more than one Sector".
Source: `https://catalog.upenn.edu/undergraduate/arts-sciences/curriculum/`
(read live). Status: VERIFIED (page, 2026-11-26).

**CAS-11. General education and minors share freely.**
Quote: "There is no limit to the number of courses that may be double
counted between General Education Requirements and requirements for a
minor." Source: `https://catalog.upenn.edu/undergraduate/arts-sciences/curriculum/`
(read live). Status: VERIFIED (page, 2026-11-26).

**CAS-12. Departments may tighten double counting.**
Quote: "Major departments may have additional rules limiting double
counting between more than one major." (`https://catalog.upenn.edu/undergraduate/arts-sciences/curriculum/`,
read live.) Examples, from `https://psychology.sas.upenn.edu/node/221`
(archive copy; the live page answered 403): Psychology minor "three of
the PSYC courses in the PSYC minor must count only in the PSYC minor";
Consumer Psychology minor "two of the four PSYC courses in the CNPS minor
must count only in the CNPS minor, not in any other", and "There is no
limit to the number of courses from the PSYC minor and CNPS minor that can
double count with the College Sector and Foundation requirements, if
appropriate."
Was: PPE "does not allow double counting of courses in the major"
(summary). `https://ppe.sas.upenn.edu/study/curriculum/ppe-policies` (read
live) says the opposite: "PPE does not place any restrictions on double
counting towards another major beyond the College requirements" and "Up to
three courses from the PPE major can count towards a minor".
The AP-waiver sentence ("The AP waiver does NOT count towards the courses
required for the PSYC or CNPS minor.") was not found.
Status: PARTLY VERIFIED (page, 2026-11-26), with the PPE item CORRECTED
as above.

**CAS-13. Total CU depends on the major: 32 to 36.**
Quote: "The total number of course units needed for graduation varies
between 32 and 36 depending on the number of course units required in the
major." (`https://www.college.upenn.edu/credits-needed-major`, archive
copy; the live page answered 403.) "Complete the course units (c.u.)
needed to earn the degree (32-36 c.u.), typically 20 courses outside the
major"; "16 courses in the Arts & Sciences outside the major: Complete 16
c.u." (`https://catalog.upenn.edu/undergraduate/arts-sciences/curriculum/`,
read live; the first of the two is an unbroken span of the page's
sentence, the second a prefix of it); "Students who are completing more
than one major must use their largest major to calculate the number of
overall c.u." (`https://www.college.upenn.edu/majors`, archive copy).
Status: VERIFIED (page, 2026-11-26). Compare CAS-01/02, where the scribe
states the same idea per major (36 and 31 for Biology).

**CAS-14. Course load.**
Quote: "First-year students in the College are limited to 4.5 c.u. for the
first semester. After the first semester, College students are limited to
5.5 c.u. per semester. Starting in their third semester, students can
request to raise these limits ... The transcript should show good
performance (a g.p.a. of 3.3 or better) in 5 c.u. and contain no
outstanding Incompletes."; "No student will be allowed to register for
more than 7.5 c.u. in a term."
Source: `https://www.college.upenn.edu/courseload` (archive copy; the live
page answered 403).
Was: "first-year students are capped at 4.5 c.u." (the page limits that to
the first semester) and the 3.3 GPA read as "old": it is on the current
page, not only in a 2016 book.
Status: CORRECTED (page, 2026-11-26).

**CAS-15. Language requirement by placement.**
Quote: department pages: Chinese: "(receiving a score of 650 or above in
the placement exam)"; "these external exam scores are not accepted by the
Chinese Language Program for placement, credit, or fulfillment of the
language requirement." (`https://web.sas.upenn.edu/chinese/requirements/`,
read live.) "The only students exempt from having a placement score are
those who have never studied the language before." is on the Nursing BSN
handbook's degree-requirements page
(`https://www.nursing.upenn.edu/students/handbooks-forms/bsn-handbook/degree-requirements/`,
read live), not a College page. Not found: "students who score between
600 and 640 can be exempted from the Language Requirement if they pass an
oral exam" (policy book `C27policybookV3.pdf`).
Source also named: `https://figs.sas.upenn.edu/placement-exams` (read as
an archive copy; no quoted fragment was confirmed there). Status: PARTLY
VERIFIED (page, 2026-11-26); thresholds differ by language.

**CAS-16. Mutually exclusive courses.**
Quote: Wharton's incompatible-courses page (read live) says "only one such
course can be taken" and lists "BEPP 1000/ECON 010 and ECON 0100/001 or
ECON 0200/002" and "MATH 1410/114, MATH 1610/116, and MATH 1510/115"; its
2025-26 handbook lists "STAT 1010 and STAT 1110" and "MATH 1410, MATH
1610, and MATH 1510". The Engineering handbook page on math courses says:
"If courses are mutually exclusive, you can only receive credit for one of
them, even if you take more than one."
Source: `https://undergrad-inside.wharton.upenn.edu/incompatible-courses/`,
`https://undergrad-inside.wharton.upenn.edu/wp-content/uploads/2025/06/2025-26_Handbook.pdf`,
`https://academics.engineering.upenn.edu/ugrad/student-handbook/courses-registrations/course-categories/`.
Was: a College rule, "won't grant credit for both", read from the College's
courseload page with the examples "STAT 1010 and 1110" and "MATH 1410 and
MATH 1510". No College page says this; the lists are Wharton's and
Engineering's. (The catalog's STAT page marking STAT 1010 and STAT 1110 as
mutually exclusive was not read.)
Status: CORRECTED (page, 2026-11-26).

**CAS-17. Dual degree with the College.**
Quotes: "To be eligible to apply for a dual degree, students must have
completed at least 4 course units in each of their first two semesters at
Penn."; "Applicants should have a cumulative g.p.a. of 3.3 or better";
"Students who transfer to Penn with junior standing are not eligible".
Source: `https://www.college.upenn.edu/dual-degree` (archive copy; the live
page answered 403). The same page says the Engineering degree's total
"may be as high as 46" course units. Not found: the older books' "at least
14 College courses outside the major" and "between 37 and 48" course
units. Status: PARTLY VERIFIED (page, 2026-11-26); the last two figures
are from older books and remain unverified for current classes.

**CAS-18. Submatriculation: at most 4 graduate CU count twice.**
Quote: "In any submatriculation program, a maximum of 4 c.u. at the
graduate level may be included toward both the B.A. and the M.A." and
"Some graduate programs may permit fewer than four courses to be double
counted." Source: `https://catalog.upenn.edu/undergraduate/arts-sciences/curriculum/`
(read live; the full sentence is on the College's double-counting page,
archive copy). The "eight courses" an earlier summary reported is the
B.A./J.D. rule on the same page: "For students in the B.A./J.D.
submatriculation program, no more than eight courses in all can be double
counted toward both degrees." Status: VERIFIED (page, 2026-11-26).

**CAS-19. Credit away.**
Quote: "Students pursing a degree in the College may take no more than 5
c.u. at another college or university. The maximum amount of credit away
that can be transferred for one summer is 4 c.u."; "Penn credit will not
be awarded for courses taken at another school during the academic year
(fall and spring)." Source: `https://www.college.upenn.edu/equivalent-credit`
and `https://srfs.upenn.edu/student-records/external-credit` (archive
copies; the live pages answered 403). Status: VERIFIED (page,
2026-11-26).

**CAS-20. Residency.**
Quote: "At least half the course units in the major must be taken at Penn.
Some departments require more." (`https://catalog.upenn.edu/undergraduate/arts-sciences/curriculum/`,
read live); "No student may graduate with a B.A. from the University of
Pennsylvania without having completed at Penn at least one-half of the
total number of required course units." (`https://www.college.upenn.edu/equivalent-credit`,
archive copy). Source: those two pages. Status: VERIFIED (page,
2026-11-26); the scribe's `MINRES` values (CAS-01, CAS-07) are the same
rule, VERIFIED. (The SEAS handbook's one-half sentence is about transfer
students, not the College.)

**CAS-21. Retaking.**
Quote: "Students who receive an F in a course may retake the course for
credit." Source: Class of 2025 policy book. Status: REPORTED. See U-04.
Not found in the 579 pages read on 2026-11-26 (the closest page is
Wharton's, "Students cannot retake for credit any course in which a
passing grade (D or better) was received", which is U-04 and WH-16).

**CAS-22. Class of 2031 and later: a different curriculum.**
Quotes: "students are required to complete at least 36 credits in
total"; students distribute 20 credits across the three divisions
"Natural Sciences, Social Sciences, and Humanities & the Arts", with 12
in one, 5 in a second and 3 in a third; Foundations "consists of six
specific courses or course types"; language "two courses or demonstrated
fluency in a language other than English"; "information on this page
applies to students beginning as first-years in Fall 2027 and beyond";
"at least 30 credits overall within the School of Arts and Sciences".
Press: "Courses offered by Penn's three other undergraduate schools,
however, will not fulfill the general education requirements." Source:
`https://www.college.upenn.edu/academics/new-curriculum-class-2031-later/new-curriculum-distribution`
(archive copy; the live page answered 403); the last quote is the Daily
Pennsylvanian. Status: PARTLY VERIFIED (page, 2026-11-26): the 36
credits, the three divisions, the Fall 2027 cohort and the 30 credits
within Arts and Sciences are confirmed word for word. Not found: the
12/5/3 split, "six specific courses or course types", the language
sentence and the press sentence (the `/new-curriculum-foundations` page
answered 404 in the archive).

---

## 4. Wharton

No Wharton audit template was readable (Penn Labs' fixtures have none),
so nothing here is verified from the scribe. Block codes known from Penn
Labs' code ([GH] `mt.py`, `lsm.py`): `U-WFYF` First-Year Foundations,
`U-WBUS` Business Fundamentals, `U-WLAS` Liberal Arts and Sciences,
`U-WBBR2` Business Breadth; capstone rule tests attribute `WUCP`.

**WH-01. 37 CU for a single degree.**
Quote: "All Wharton single-degree undergraduate students must complete a
minimum of 37 course units and meet the curricular requirements described
below." Source: `https://catalog.upenn.edu/undergraduate/wharton/curriculum/`
(read live). Status: VERIFIED (page, 2026-11-26).

**WH-02. Cross-Cultural Perspectives: 2 CU may also count as general
education.**
Quote: "Two CUs satisfying the Cross-Cultural Perspectives requirement
may also double-count as Humanities; Social Sciences; Natural Sciences,
Math, and Engineering (NSME); and Flex General Education (FGE)." Source:
`https://undergrad-inside.wharton.upenn.edu/double-counting-courses/`
(read live). Status: VERIFIED (page, 2026-11-26). Matches `policy.ts`
(`crossCultural+liberal`, cap 2).

**WH-03. Language courses taken at Penn also count as Humanities and
FGE.**
Quote: "Courses taken at Penn that satisfy the Foreign Language
requirement may also double-count as Humanities and FGE." Source: as
WH-02 (read live). Status: VERIFIED (page, 2026-11-26). Note the limits
`policy.ts` does not hold: only **at Penn**, and only Humanities and FGE
(not Social Science or NSME).

**WH-04. Second concentration.**
Quotes: "Up to 1 CU from a second concentration can double-count as a
Business Breadth." (`.../double-counting-courses/`); "Students may not
double-count courses between concentrations."
(`.../concentrations-faq/`); "may apply three course units of
concentration courses to Unrestricted Electives" (catalog curriculum
page); "Students pursuing a second concentration may apply three of the
concentration courses here." (`.../unrestricted-electives/`). Source:
`https://undergrad-inside.wharton.upenn.edu/` pages named, and
`https://catalog.upenn.edu/undergraduate/wharton/curriculum/`, all read
live. Status: VERIFIED (page, 2026-11-26).

**WH-05. Business breadth.**
Quotes: "Business Breadth Three upper-level course units from three
different Wharton departments outside of the student's concentration
required." (catalog curriculum page); "No more than 1 CU from any
department (with the exception of WH courses) may count toward Business
Breadth." (`.../business-breadth/`, footnote 2, also the 2025-26
handbook); "Business Breadth courses may not be double counted toward any
other requirements except for one course in the second concentration.";
"Note: All Business Breadth courses must be taken for a grade, not
pass/fail." If the concentration is housed in one department but includes
other departments' courses: "Business Breadths must be taken outside of
the home department and may not include approved concentration courses."
Source: `https://undergrad-inside.wharton.upenn.edu/business-breadth/`
(full text printed in the run), `https://catalog.upenn.edu/undergraduate/wharton/curriculum/`,
all read live. Status: VERIFIED (page, 2026-11-26). The breadth subjects,
from Penn Labs: `ACCT, BEPP, FNCE, HCMG, LGST, MGMT, MKTG, OIDD, REAL,
STAT, WH` (CODE; not matched on the page, which lists "Upper-level,
non-fundamental Wharton course (with the exception of WH 1508/1500, HCMG
1010, MGMT 1110, MGMT 1170, MGMT 1980, OIDD 1050)").

**WH-06. Global Economy, Business and Society, and Technology, Innovation and Analytics courses share with nothing.**
Quotes: "Global Economy, Business, and Society courses may not be
double-counted toward any other requirement and must be taken at the
undergraduate course level for a letter grade, not pass/fail." (2025-26
handbook, `https://undergrad-inside.wharton.upenn.edu/wp-content/uploads/2025/06/2025-26_Handbook.pdf`,
read live; the "no petitions" wording for this category was read on the
first run of the same day on `https://undergrad-inside.wharton.upenn.edu/global-economy-business-society/`,
whose text this run did not print); "Technology, Innovation, and Analytics
courses may not be counted toward any other requirement and must be taken
at the undergraduate course level for a letter grade, not pass/fail.
Students should wait until sophomore year or later to take these courses.
Only the courses below will satisfy this requirement (no petitions will be
considered)." (`https://undergrad-inside.wharton.upenn.edu/technology-innovation-analytics/`,
read live). Status: VERIFIED (page, 2026-11-26). **Disagrees with
`policy.ts`**, whose `petitionPairs` offers GEBS (group `wharton.flex`) with
the concentration as something an advisor may approve; the dry run printed
"petition: MGMT 1110 ... Global Economy, Business and Society + ...
General Management Electives". Wharton says neither category may count
toward any other requirement, so that petition should not be offered.

**WH-07. Senior capstone.**
Quotes: "Senior Capstone One course with attribute WUCP required" (0.5
CU, catalog curriculum page); "Note that students must have completed WH
1010, WH 2010 and MGMT 3010 to be eligible to enroll in a capstone course.
For all senior capstone courses offered in fall 2027 and beyond, students
must also complete all business fundamentals as a prerequisite."; "MGMT
3880 Venture Acceleration Lab no longer fulfills the senior capstone
requirement, as of Fall 2026 offering." Source:
`https://undergrad-inside.wharton.upenn.edu/senior-capstone/`, catalog
(both read live). Status: VERIFIED (page, 2026-11-26). Matches `policy.ts`
`capstoneRule` (which adds the Leadership Journey courses; the page
confirms WH 1010, WH 2010 and MGMT 3010 as prerequisites). For dual-degree
students see WH-19.

**WH-08. Course load.**
Quotes: "the standard course load is 4 to 5 CUs per semester" (catalog);
"Wharton students are limited to a maximum of 5.5 course units (CUs) for
the first semester." (`.../transfers/registration/`); "Students must be
approved for more than 5.5 CUs of enrollment."; "The Petitions Committee
will not normally approve enrollment more than 1 CU above the total from
the semester immediately prior to the requested overload semester."; "The
minimum course load is 4 course units (CUs) per term". Source:
`https://undergrad-inside.wharton.upenn.edu/course-load/` (full text
printed), catalog, all read live. Status: VERIFIED (page, 2026-11-26). No
6.5 figure and no GPA condition appear on Wharton's page; `policy.ts`'s
`approved: 6.5` is the SEAS number (SEAS-41). Wharton adds that "students
enrolled in dual degrees (undergraduate or graduate) with a home school of
Wharton will be allowed more flexibility with CU increases than
single-degree students".

**WH-09. Pass/fail.**
Quotes: "Wharton students may not choose to take a course pass/fail in
their first semester at Penn."; "Students may take a maximum of three
courses on a pass/fail basis."; "Unrestricted Electives may be taken
pass/fail unless they are being counted toward a second concentration or
a minor." Source: `https://undergrad-inside.wharton.upenn.edu/pass-fail/`,
`.../unrestricted-electives/`, 2025-26 handbook, all read live. Status:
VERIFIED (page, 2026-11-26). The earlier "CONFLICTING" flag is resolved:
the pass/fail page says "All three Cross-Cultural Perspectives courses
and second-concentration courses counting as Unrestricted Electives must
be taken for a grade", and the breadth page says "All Business Breadth
courses must be taken for a grade, not pass/fail"; neither says the
electives in general must be graded.

**WH-10. Foreign language.**
Quotes: "Students must complete two semesters at the beginner level or the
equivalent in a language other than English in order to graduate."; the
ways to satisfy it: "By receiving a required score on one of the AP or IB
exams", "By completing the appropriate Cambridge A-Level Examination at a
grade deemed satisfactory by the language group", "Successful completion
of a test given by a language department or by the Penn Language Center",
"Completion of two semesters at the beginner level in a Penn foreign
language or American Sign Language (ASL)". Source:
`https://undergrad-inside.wharton.upenn.edu/foreign-language-requirement/`
and the 2025-26 handbook, read live. Not found: "Students in the School of
Nursing and Wharton may fulfill the language requirement with a
qualifying score of 450+ in the in-person placement exam." Status: PARTLY
VERIFIED (page, 2026-11-26).

**WH-11. Liberal arts and sciences.**
Quote: "In addition to the foreign language requirement, a minimum of 7
CUs from the categories listed below are necessary to fulfill the liberal
arts and sciences component of the curriculum." Attribute codes read on
the pages: "The Humanities attribute code in Path@Penn is WUHM", WUNM for
Natural Sciences, Math, Engineering, WUSS for Social Science, "WUCN for
non-U.S. CCPs and WUCU for U.S. cultural diversity CCPs". The Flex Gen Ed
code `WUFG` was not found. Source:
`https://undergrad-inside.wharton.upenn.edu/liberal-arts-and-sciences/`,
`.../las-course-list/` (read live). Status: PARTLY VERIFIED (page,
2026-11-26).

**WH-12. Courses from a dual degree or a minor may fill liberal arts.**
Quote: "Students pursuing uncoordinated dual degrees and departmental
minors in the College or SEAS may have courses from those programs also
fill Wharton's liberal arts and sciences requirements, provided the
courses are approved for Wharton." Source:
`https://undergrad-inside.wharton.upenn.edu/double-counting-courses/`
(read live). Status: VERIFIED (page, 2026-11-26). This is the Wharton side
of the cross-degree rule.

**WH-13. Submatriculation.**
Quote: "Students completing accelerated Master's or sub-matriculation
programs are typically limited to a maximum of three courses that can be
double-counted between the undergraduate and graduate degrees." Source:
`https://undergrad-inside.wharton.upenn.edu/double-counting-courses/`
(read live). Status: VERIFIED (page, 2026-11-26).

**WH-14. Uncoordinated dual degree.**
Quotes: "students applying for uncoordinated dual degrees must have a
minimum cumulative GPA of 3.40"
(`https://undergrad-inside.wharton.upenn.edu/dual-degree-wharton/`);
"applicants must complete at least four (4) course units (CU) per
semester at Penn (fall and spring semesters only)"
(`.../internal-transfer/`); "unlike coordinated dual-degree programs, an
uncoordinated dual degree does not have a specialized curriculum." (2025-26
handbook). All read live. Status: VERIFIED (page, 2026-11-26). Wharton's
own CU total for a dual-degree student was not found.

**WH-15. Incompatible courses.**
Quote: "If you complete two courses that are incompatible, only the first
course that was taken will count toward degree requirements." (2025-26
handbook; the live page `https://undergrad-inside.wharton.upenn.edu/incompatible-courses/`
says the same and adds "The subsequent incompatible course will be dropped
from the transcript and neither the grade nor the credit from the second
courses will be counted."). Pairs on the pages: "Students cannot obtain
credit for both BEPP 2500 and ECON 2100", "Students cannot obtain credit
for both FNCE 1010 and ECON 2200", "Students cannot obtain credit for both
STAT 1010 and STAT 1110" (2025-26 handbook). Source: as named, read live.
Status: VERIFIED (page, 2026-11-26). Penn Labs' M&T encoding lists
`BEPP-2500 | BEPP-2508 | ECON-2100` as alternatives for Managerial
Economics (CODE), consistent.

**WH-16. Retaking a failed course.**
Quote: "If a course is retaken, the new grade will not replace the
original F, both grades will be counted toward the cumulative GPA, and the
student will receive credit for the repeated course." Source:
`https://undergrad-inside.wharton.upenn.edu/failing/` (read live; also the
2025-26 handbook). Status: VERIFIED (page, 2026-11-26).

**WH-17. AP, Class of 2029 on.**
Quote: "For the Class of 2029 and beyond, AP scores will not result in
credit for MATH 1400". Source: `https://undergrad-inside.wharton.upenn.edu/itdd-faq/`
(read live). Status: VERIFIED (page, 2026-11-26). Consistent with U-08.

**WH-18. Business courses abroad.**
Quote: "business courses can only be taken at Wharton-approved study
abroad programs". Source: 2025-26 handbook
(`https://undergrad-inside.wharton.upenn.edu/wp-content/uploads/2025/06/2025-26_Handbook.pdf`,
read live). Status: VERIFIED (page, 2026-11-26).

**WH-19. Wharton-Engineering dual-degree students meet the capstone through their Engineering design project or thesis.**
Quote: "Wharton-Engineering dual-degree students (including M&T) will
satisfy the capstone requirement via their BAS or BSE degree design
project or thesis requirements." For Wharton-College dual-degree students
the same page says: "Wharton-College dual-degree students must complete
one of the Wharton capstone courses above."
Source: `https://undergrad-inside.wharton.upenn.edu/senior-capstone/`
(read live). Cohort: current. Status: VERIFIED (page, 2026-11-26).
**Not in `policy.ts` today**: the planner plans a separate Wharton
capstone.

**WH-20. Wharton credit away: 4 CU in all, 2 CU toward liberal arts, no business credit.**
Quotes: "Students who entered Penn as first-years can transfer a maximum of
4 CUs of credit away."; "A maximum of 2 CUs of credit away can count
toward Wharton's Liberal Arts and Sciences requirements."; "Wharton will
not grant any undergraduate business credit for study away at any
institution during the summer. This policy applies to all Penn
undergraduate students, regardless of home school."; "Penn will not grant
credit for study away during the fall or spring semesters or while
students are on a leave of absence."; "Students who entered Penn as
external transfers may not take summer courses for credit away." Source:
`https://undergrad-inside.wharton.upenn.edu/credit-away/` (read live; the
2 CU liberal-arts cap is also on `.../liberal-arts-and-sciences/`).
Cohort: current. Status: VERIFIED (page, 2026-11-26).

---

## 5. Nursing

**NU-01. Total CU by class.**
Quote: "40.5 course units (class of 2025 and prior) or 39 course units
(class of 2026) or 36 course units (class of 2027 and beyond)". Source:
`https://www.nursing.upenn.edu/students/handbooks-forms/bsn-handbook/degree-requirements/`
(read live). Status: VERIFIED (page, 2026-11-26).

**NU-02. Load.**
Quote: maximum "5.5 course units in a fall or spring semester and 2
course units per summer session"; "Students are not able to request a max
course units increase until add/drop/swap begins." The same passage gives
7.5 as the most course units a student may take in a given semester (the
start of that sentence was cut in the run's passage). Source:
`https://www.nursing.upenn.edu/students/handbooks-forms/bsn-handbook/courses-exam-related-policies/`
(read live). Status: VERIFIED (page, 2026-11-26).

**NU-03. Pass/fail.**
Quote: "Students in the School of Nursing may take up to four courses
pass/fail", one per semester, in listed categories (list not seen).
Source: as NU-02 (read live). Status: PARTLY VERIFIED (page, 2026-11-26):
the four-course limit is confirmed word for word; "one per semester" and
the categories were not found and remain as reported.

**NU-04. Residency.**
Quote: "all students must complete at least 19.5 course units at the
University of Pennsylvania School of Nursing to be eligible for the BSN
degree". Source: BSN handbook degree-requirements page
(`https://www.nursing.upenn.edu/students/handbooks-forms/bsn-handbook/degree-requirements/`,
read live). Status: VERIFIED (page, 2026-11-26).

**NU-05. Sectors.** Names differ by source and year: the BSN handbook
lists "Requirements by Sectors 6 c.u. Arts and Letters 1 c.u. Society and
Social Structures 1 c.u. Histories and Traditions 1 c.u. Global and
Cultural Studies 1 c.u. Reasoning, Systems, and Relationships 1 c.u. Free
Elective" (matching attributes `NUAL, NUSS, NUHT, NUGC, NURS`); the
current catalog lists "The Planet & Our Climate", "Global Arts, Letters, &
Cultures" and "Diversity, Universality, Justice, & Equity" (the handbook
carries "Societies, Histories, and Traditions"), plus "one exploration
course (1 c.u.)". Source:
`https://www.nursing.upenn.edu/students/handbooks-forms/bsn-handbook/degree-requirements/`;
`https://catalog.upenn.edu/undergraduate/nursing/curriculum/` (both read
live). Status: PARTLY VERIFIED (page, 2026-11-26): every sector name is on
a page, so the two models are real; which class year uses which, and the
attribute codes for either, were not read and remain as reported (the
sector model changed with the 36-CU curriculum).

**NU-06. Language and free electives.**
Quote: "If the language proficiency is met, the remaining course units
become free electives." Source:
`https://www.nursing.upenn.edu/students/handbooks-forms/bsn-handbook/degree-requirements/`
(read live). Status: VERIFIED (page, 2026-11-26). The 450+ placement
threshold WH-10 mentions for Nursing was not found.

**NU-07. Minors.**
Quote: "Depending upon the specific minor, some courses may fulfill sector
requirements or free electives."; "minors are only available to
traditional BSN students". Source:
`https://www.nursing.upenn.edu/students/handbooks-forms/bsn-handbook/special-academic-option-policies/`
(read live). Status: PARTLY VERIFIED (page, 2026-11-26): the two quoted
sentences are confirmed; "A minor requires approximately six to nine
courses" was not found as a whole sentence and remains as reported.

**NU-08. Second degrees and the MSN.**
Quotes: "students who have already completed one undergraduate degree
are exempt from all sector requirements"; "Students who are formally
enrolled in the BSN-MSN Program may take no more than three non-clinical
course units toward their MSN program prior to completing the" (the run's
passage ends there). Source: BSN handbook degree-requirements page
(`https://www.nursing.upenn.edu/students/handbooks-forms/bsn-handbook/degree-requirements/`,
read live). Status: VERIFIED (page, 2026-11-26).

---

## 6. Coordinated dual-degree programs

**CD-01. M&T: 46 CU; a Wharton side of its own.**
Quotes: "M&T students are required to take a minimum of 46 credit units
in order to graduate."; "EAS 2030: Engineering Ethics will fulfill a
Wharton requirement as well as the Penn Engineering Ethics requirement";
MGMT 2370 can fulfill "one of the two business breadth requirements" for
students not concentrating in management. Source:
`https://fisher.wharton.upenn.edu/learn/dual-degree/` (read live). Not
found: a student who cannot hold a 3.0 GPA "for three consecutive
semesters is dropped". Status: PARTLY VERIFIED (page, 2026-11-26).
Penn Labs' encoding, read from "Path@Penn what-if audits for WU_BS_MANT
and WU_BS_MAT_U (2024 to 2026 catalogs, which agree)" ([GH] `mt.py`,
CODE; not found in the pages read): the M&T variant suppresses `U-WFYF`,
`U-WBUS`, `U-WLAS`, `U-WBBR2` and the `WUCP` capstone, and adds
"Quantitative/Computational Skills" (MATH 1400; MATH 1410 or 1610; ESE
3010 or STAT 4300; STAT 4310 or ESE 4020), an "Engineering Senior Design
Course" in place of the Wharton capstone, "Humanities/Social Science
Requirements" 2 CU (`WUHM, WUSS`), "Cross-Cultural Requirement" 2 CU,
business breadth 2 CU, and the M&T block (`OIDD-2340 | OIDD-3990`,
`MGMT-2370`). `cu_floor: 46`. Wharton's own pages agree on the capstone
(WH-19) and on 2 CU of Humanities and/or Social Sciences and 2 CU of CCP
for "Management and Technology coordinated dual-degree students" (live
liberal-arts-and-sciences page).

**CD-02. LSM: 43 CU.**
Quotes: "The minimum number of course unit credits required to graduate
with both degrees is 43; in practice, students do more than that."
Source: `https://lsm.upenn.edu/information-and-suggestions-applicants`
(read live). Wharton's senior-capstone page lists "Vagelos Program in Life
Sciences and Management: LSMP 4210: LSM Capstone Course (1.0 CU)".
Status: PARTLY VERIFIED (page, 2026-11-26). Not found: LSMP 4210 as "a
two-semester (and two course unit) senior year Capstone course" (the
`/curriculum/lsm-specific-courses` page was not read). Penn Labs ([GH]
`lsm.py`, CODE; not found in the pages read): allowed College majors
`BIOL, BCHE, BIOP, CHEM, NRSC`; "Sector 1 is waived because the Wharton
degree requires economics, and the proseminar fulfills Sector 7"; LSM
students take "neither MGMT 3010 nor Wharton's senior capstone".
`cu_floor: 43`.

**CD-03. VIPER: 46 CU, three energy courses, two research summers.**
Quote: "Dual-degree students should complete at a minimum of 46 course
units (CUs)" was not found: `https://www.viper.upenn.edu/academics/dual-degree-curriculum`
answered 404 to the runner. What the SEAS handbook says of every
Engineering dual degree, read live: "the minimum requirement for any dual
degree student with Engineering is 46 course units". Also on the handbook's
Course Category Lists page: "Students in the VIPER program can use VIPR
1200/1210 as an Engineering Requirement, subject to any other conditions
or restrictions in a major (Also, this fulfills the Ethics Requirement for
VIPER students for any major.)". Status: PARTLY VERIFIED (page,
2026-11-26). Penn Labs ([GH] `viper.py`, CODE; not found in the pages
read): seminars `VIPR-1200`, `VIPR-1210`, `VIPR-1300`; an approved energy-course list of about 44 codes; "VIPER
courses also count toward either degree"; allowed majors
`PHYS, MATH, CHEM, EESC, BIOL` with `CSCI, CBE, MSE, MEAM, EE, CMPE, BE`,
"Biology and Bioengineering are open only to the Class of 2029 and
earlier". The scribe confirms VIPR 1200 and 1210 together satisfy SEAS
ethics (rule "VIPR 1200 and 1210", [GH] `CMPE-BSE-2026.xml`, VERIFIED).

**CD-04. Huntsman: International Studies BA, 14 program CU.**
Quote (the catalog page's own rows, read live at
`https://catalog.upenn.edu/undergraduate/programs/international-studies-ba/`):
"3 credit units in Area Studies in consultation with your Advisor"; "INSP
1001 Huntsman Program First-Year Seminar in International Studies and
Business 1"; "2 CU in International Studies: Attribute UNIS"; "2 CU in
International Business: Attribute WUIS"; "1 CU in either International
Studies or International Business"; "Senior Capstone 1 Select 1 CU from
the following: MGMT 4090 & INSP 4997 Huntsman Capstone". The 4 CU of
language row came before the run's passage and was not matched. Status:
PARTLY VERIFIED (page, 2026-11-26); the 14-CU total is the sum of these
rows with the language row. Penn Labs ([GH] `huntsman.py`, CODE; not found
in the pages read): "Path has no audit for it"; Arts and Sciences floor 24
CU; "Sector 1 is met by Wharton's economics requirement and Sector 4 by
INSP 1001"; capstone `INSP-4997 | INSP-4999`, management capstone
`MGMT-4090`.

**CD-05. NHCM.**
Quote: "Nursing and Health Care Management coordinated dual-degree
students must take 1 CU of Social Science and 1 CU of Humanities and 2 CU
of CCP courses to fulfill their liberal arts and sciences requirements."
Source: `https://undergrad-inside.wharton.upenn.edu/liberal-arts-and-sciences/`
(read live). The 2025-26 handbook PDF says "... 1 CU of Humanities and 3
CU of CCP courses ...", so the live page (2 CU) and the handbook (3 CU)
disagree. Status: CONFLICTING (pages disagree, 2026-11-26); the live page
is the later of the two. Total CU and the nursing side: not found. Not
encoded by Penn Labs.

**CD-06. Coordinated programs own their completion rules.**
Quote: "coordinated dual-degree students should consult their program
advisors for degree completion policies and information." Source: Wharton
2025-26 handbook (`https://undergrad-inside.wharton.upenn.edu/wp-content/uploads/2025/06/2025-26_Handbook.pdf`,
read live). Status: VERIFIED (page, 2026-11-26).

---

## 7. Attribute codes

### 7.1 The scheme

Attributes are four-character codes on course sections. The first letter
or two is the owning school ([GH] Penn Labs `courses/util.py`,
`identify_school`): `A` College (SAS), `B` LPS, `E` Engineering, `F`
Design, `G` Education, `L` Law, `MM` Medicine, `N` Nursing, `Q` grade
mode, `V` Veterinary, `W` Wharton. Other prefixes exist (`UNIS`, a
university-level International Studies code; `H...` graduate Arts and
Sciences; `MPBR`). Penn Labs' `/attributes/` lists **870** codes ([RUN]
2026-11-16); the catalog's "Course Attributes A-Z" is the official index.
The full list could not be downloaded in this session (the artifact host
is blocked); fetching `/api/base/attributes/` once from a runner settles
it. Second letter `U` marks undergraduate (`AU`, `EU`, `NU`, `WU`); `EM`
marks SEAS masters (`EMRT`, `EMRE`).

### 7.2 Families that degree rules test

Names are as the source gives them. Evidence: **S** = seen in a scribe
template [GH]; **P** = seen with its name in real Path or Penn Labs API
data ([GH] fixtures or [RUN]); **C** = named in code [GH]; **R** =
reported by search (catalog A-Z page), UNVERIFIED.

**College, general education**

| Code | Name | Evidence |
|---|---|---|
| AUSO | COL Sector - Society (Sector 1) | C, R |
| AUHT | COL Sector - History & Tradition (Sector 2) | C, R |
| AUAL | COL Sector - Arts & Letter (Sector 3) | C, R |
| AUHS | COL Sector - Humanities & Social Science (Sector 4) | R |
| AULW | COL Sector - Living World (Sector 5) | C, R |
| AUPW | COL Sector - Physical World (Sector 6) | C, R |
| AUNM | COL Sector - Natural Science Across Disciplines (Sector 7) | C, R |
| AUQD | College FND Quantitative Data Analysis | S, P |
| AUFR | COL-FND-Formal Reason&Analysis | S, P |
| AUCC | COL Foundational Appr. - Cross-Cultural Analysis | S, R |
| AUCD | COL Foundational Appr. - Cultural Diversity US | S, R |
| AUWR | COL Foundational Appr. - CritWriting Reqmnt | C, R |
| AULL | COL-COURSE-Last Language (the course that completes the requirement) | S, P |
| AULA | College advanced language (IRS: "SasAdvancedLanguage") | C |
| AULG | COL-COURSE-Language | R |
| AU16 | College 16 CU Requirement (counts as Arts & Sciences credit) | S, P |

College majors also own many `A...` codes for their electives (seen:
`ABB2, ABXD, ABAM, ABCM, ABAN, ABCB, ABEE, ABGD, ABGG, ABMD, ABMI, ABMC`
for Biology concentrations (S); `AMOR` Mathematics (S); `ACGC, ACGL,
ACGN` Cognitive Science; `ALCN` Logic minor; `ALNR` ASL; `APPC` PPE (P)).

**Engineering**

| Code | Name | Evidence |
|---|---|---|
| EUMA | SEAS Mathematics Elective | S, P |
| EUNS | SEAS Natural Science | S, P |
| EUNG | SEAS Engineering | S, P |
| EUMS | SEAS Math/Science/Engrng ("EAS-COURSE-Math/Science/Engrng"); IRS calls it deprecated | P, C |
| EUNE | SEAS No Engineering Req | P |
| EUHS | SEAS Humanities | S, P |
| EUSS | SEAS Social Science | S, P |
| EUTB | SEAS Tech, Business, Society | S, R |
| EUCU | CIS Unrestricted Tech Elective | S, P |
| EUCR | CIS Restricted Technical Elective ("only entered use in Spring 2024") | S, C |
| EMRT, EMRE | Robotics masters technical / general elective | C |
| EURO | seen in Penn Labs code only; meaning UNVERIFIED | C |

**Wharton**

| Code | Name | Evidence |
|---|---|---|
| WUGE | WH UG GEBS: Global Economy, Business, Society | C, R |
| WUTI | Technology, Innovation & Analytics | C, R |
| WUCP | Senior capstone | C, R |
| WUHM | Humanities | C, R |
| WUSS | Social Science | C, R |
| WUNM | WH UG NSME: Natural Science, Math, Engineering | P |
| WUFG | Wharton UG Core Flex GenEd | R |
| WUCN | Wharton Core Cross-Cultural Perspective: Non-US | P ([RUN]) |
| WUCU | Cross-Cultural Perspective: U.S. cultural diversity | C, R |
| WUFL | WH Foreign Lang Req | P ([RUN]) |
| WUIS | Huntsman international-studies business courses | C, R |
| WUMG | Wharton UG Management Concentration Elec | P |
| WUEI | Wharton UG Management Concentration ENTI Elec | P |
| WUBE | WH UG BHEC Conc Electives | P |
| WUOG | Wharton OIDD General Track | P |
| WUOM | Wharton OIDD Operations track (Penn Labs' model example) | C |
| WUNG | seen in Penn Labs code only; meaning UNVERIFIED | C |

Wharton concentrations each own elective codes of this kind; the catalog
A-Z page is the list.

**Nursing**

| Code | Name | Evidence |
|---|---|---|
| NUAL | NU Sector Arts & Letters | R |
| NUGC | NU Sector Global & Cultural Studies | R |
| NUHT | NU Sector History & Traditions | R |
| NURS | NU Sector ReaSys&Relationship (Reasoning, Systems & Relationships) | P |
| NUSS | NU Sector Society&Soc Struct | P |
| NUUN | NU Unassigned | R |
| NUWE | NU Nursing and Health Services Mgmt Minor WH Elec | P |
| NUTR | seen in Penn Labs code; presumably nutrition; UNVERIFIED | C |

**University and other**

| Code | Name | Evidence |
|---|---|---|
| UNIS | Huntsman / International Studies courses (university-level code) | C, R |
| QS | Grade Mode: Standard Lettr Grd | P |
| QP | Grade Mode: Pass/Fail | P |
| QU | Grade Mode: Stsfctry/Unstsftry | P |

A trap seen in real data: `NURS` (Nursing's Reasoning sector) rides on
BEPP 2500 and CIS 4000 ([RUN]), and `EUSS` on BEPP 2500. An attribute
says which requirement a school will accept a course for; it says nothing
about the course's home school.

### 7.3 Scribe pseudo-attributes (not course attributes)

`DWPASSFAIL` (taken pass/fail), `DWTERM` (term taken), `DWAGE` (years
since taken), `DWTRANSFERSCHOOLID` (`EQIVAP, EQIVIB, EQIVEX, EQIVAS`:
AP, IB, external exam, advanced standing), `DWGRADELETTER`, `DWCOLLEGE`,
`DWRESIDENT`, `DWGRADE`, `DWCOURSENUMBER`, `DWATTR` (same as
`ATTRIBUTE`). Source: [GH] fixtures and `parse_path_audit.py`. These are
how a template states rules about a student's record rather than about a
course.

---

## 8. What the pages settle about `policy.ts` (2026-11-26)

Read against the official pages the runner crawled on 2026-11-26 (579
pages; `SOURCES.md` → "Runner crawl, 2026-11-26"). Each bullet names the
rule that carries the quote.

**Corrected the same day.** The summer limit, the 46-CU floor, the
capstone, the flex fundamentals and the load wording below were all
changed in `policy.ts` on 2026-11-26 (commit `fc6ed1a`, "Correct five
planner rules against Penn's own pages"). The bullets, and the "Disagrees
with `policy.ts`" and "Not in `policy.ts` today" lines inside individual
rules, describe the file as it stood before that commit.

- **Summer.** `policy.ts` allows 2 CU a summer and 4 in all
  (`summerPerTerm: 2, maxSummerTotal: 4`). Engineering's page says
  "Students may take a maximum of 4 course units (CUs) during the summer
  term, whether the courses are taken at Penn, another institution, or a
  combination of both" and "no more than 2 CUs for Summer Session I or
  Summer Session II", and states no cap across summers. So the 4 is per
  summer and the 2 is per session. Rule: SEAS-34. Nursing's page says "2
  course units per summer session" (NU-02); Wharton's page states no
  summer load. For credit away, the College allows "4 c.u." for one summer
  (CAS-19) and Wharton 4 CU in all (WH-20).
- **No 46-CU floor in the planner.** Engineering requires it: "the minimum
  requirement for any dual degree student with Engineering is 46 course
  units", and no-credit courses do not count toward it for students whose
  home school is Engineering. Rules: SEAS-28, SEAS-31 (also CD-01 for
  M&T).
- **Capstone.** The planner plans a separate Wharton capstone. For a
  Wharton-Engineering dual-degree student (M&T included) the page says the
  capstone is satisfied "via their BAS or BSE degree design project or
  thesis requirements". Rule: WH-19 (and WH-07 for the other students).
- **Flex fundamental plus concentration.** The planner offers GEBS or TIA
  counted toward the concentration as a petition. Wharton's pages say
  neither may count toward any other requirement, and the TIA page adds
  "no petitions will be considered". Rule: WH-06.
- **Loads.** 5.5 CU is the standard maximum in both schools. Above it,
  Engineering lets a department approve 1 CU more than the preceding
  semester (6.5 CU maximum for dual-degree students and seniors who need
  it to graduate on time, and 7 CU only through the Petitions Committee),
  while Wharton requires approval from its Petitions Committee, which "will
  not normally approve enrollment more than 1 CU above the total from the
  semester immediately prior". `loads.approved: 6.5` for every degree is
  therefore the Engineering figure; Wharton's page states no 6.5 and no
  GPA condition. The College caps first-semester students at 4.5 and
  everyone at 5.5 after that unless an advisor approves a raise (3.3 GPA
  in 5 CU), with 7.5 as the most a College student may register for.
  Rules: SEAS-41, WH-08, CAS-14, NU-02.
- **Language with liberal arts** (`withinDegree`: any). Confirmed as only
  courses taken at Penn, and only Humanities and FGE. Rule: WH-03.
- **Triple counting** (`crossDegree.maxPerDegree: 1`). Confirmed: "No
  course may be triple counted, i.e., counted for more than two
  degrees/majors." Rule: SEAS-30 (U-11).
- **Capstone after fundamentals.** Confirmed for capstones offered from
  fall 2027, and the page adds WH 1010, WH 2010 and MGMT 3010 as
  prerequisites now. Rule: WH-07.
- **Area lists with a CIS elective, SSH with a College major, the
  no-credit list.** These rest on the scribe (SEAS-13, SEAS-08, SEAS-05);
  the crawl neither supports nor refutes the first two. For the third,
  the Engineering handbook's Course Category Lists page names the no-credit
  list ("Penn Engineering undergraduates may not use courses on this list
  toward their degree"), consistent with SEAS-05 and SEAS-31.
