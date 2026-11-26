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
| **CODE (unofficial)** | Read in code that encodes an official page: IRS ([GH] `upenn/irs` @ `8f15aa5`) or Penn Labs ([GH] as above). Exact as to the code; the official page behind it was not read. |
| **REPORTED** | From a web-search summary on 2026-11-26. **The page was not fetched; the quoted words are as the search tool returned them and are UNVERIFIED as verbatim text.** Good enough to know the rule exists and where it lives; not good enough to ship in a record's `quote` field. |
| **CONFLICTING** | Sources disagree; both sides are given. |

All URLs under `catalog.upenn.edu`, `*.wharton.upenn.edu`,
`*.engineering.upenn.edu`, `college.upenn.edu` and `nursing.upenn.edu`
were UNREACHED from this session. "Fetched" below therefore means
"search result retrieved", except where a [GH] or [RUN] source is named.

Counts: 105 rules. 32 are verified first-hand (22 from scribe templates,
10 from the CIS handbook), 6 are read in code, and 67 are reported from
search summaries (several of those marked conflicting). The attribute
tables follow in section 7.

---

## 1. University-wide

**U-01. Course-number levels.** 0001-3999 undergraduate; 4000-4999 mixed,
primarily undergraduate; 5000-5999 mixed, primarily graduate; 6000-9899
graduate; 9900-9999 graduate individual study.
Quote: "0001-3999 · Undergraduate courses" under "Effective Summer 2022";
"4000-4999 Mixed courses primarily for Undergraduate students";
"5000-5999 Mixed courses primarily for Graduate students"; "6000-9899
Graduate courses · 9900-9999 Graduate individual study
(thesis/dissertation) courses".
Source: `https://srfs.upenn.edu/student-records/transcript-key`, also
`https://catalog.upenn.edu/undergraduate/policies-procedures/course-exam/`.
Cohort: all, from Summer 2022. Status: REPORTED.

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
(quoting the university bulletin); SEAS: "A student may not repeat a
course already passed (D or better)."
(`.../student-handbook/undergraduate-policies/repeating-a-course/`).
Status: REPORTED.

**U-05. A student in two schools must meet both schools' standing rules.**
Quote (search summary, not verbatim): "students enrolled in more than one
school must meet both schools' rules".
Source: `https://catalog.upenn.edu/undergraduate/policies-procedures/grade-gpa/`.
Status: REPORTED, wording UNVERIFIED.

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
Sources: `https://www.college.upenn.edu/academics/academic-options/campus-options/xcat-external-credit-approval-tool`,
`https://catalog.upenn.edu/undergraduate/policies-procedures/transfers/`,
`https://srfs.upenn.edu/student-records/external-credit`. Status:
REPORTED.

**U-07. Taking the Penn course forfeits the matching AP credit.**
Quote (summary): "Students with AP credit who take the equivalent course
at Penn forfeit the AP credit".
Source: SEAS handbook `.../transfer-academic-opportunities/advanced-placement/`.
Status: REPORTED, wording UNVERIFIED.

**U-08. AP equivalents depend on the entering year.**
Quote (summary): AP Calculus BC 5 "awards MATH 1400 for students entering
2024 and earlier, and MATH 1300 for students entering 2025 onward".
Source: `https://admissions.upenn.edu/how-to-apply/first-year-applicants/pre-college-credits`.
Status: REPORTED. Note the consequence: MATH 1300 is on the SEAS
no-credit list (SEAS-05), so the same AP score is worth nothing to a
BSE for a 2025 entrant.

**U-09. Submatriculation: each side caps the shared courses.**
Quote: "the undergraduate school and the graduate program/school limit
the number of courses that may concurrently satisfy requirements in both
degrees."
Source: `https://provost.upenn.edu/for-staff/graduate-program-admins/submatriculation/`.
Status: REPORTED. School caps: CAS-18, SEAS-29, WH-13.

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

**U-11. Plan-level limits the audits cannot state (Penn Labs' reading).**
A course may be claimed by at most two degrees; undergraduate and
graduate degrees share at most 3 CU, and only courses numbered 5000 or
above.
Quote: `max_degree_claims: int = 2`, `graduate_cu_limit: Decimal =
Decimal(3)`, `min_graduate_number: int = 5000`.
Source: [GH] `degree/utils/composition.py`. Status: CODE (unofficial);
agrees with SEAS-24 and SEAS-29.

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
CODE (unofficial). Handbook (REPORTED): depth is "in-depth study (2 or
more courses) of at least one subject".

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
Status: CODE (unofficial). Social Science and Humanities are coded as
"NOT an exhaustive list, and should be used in addition to course
attributes".

**SEAS-26. Attributes can be missing; the handbook wins.**
Quote: "MANUAL HACKS DUE TO ATTRIBUTES MISSING IN CURRICULUM MANAGER";
"add EUCR/EUCU attributes, which only entered use in Spring 2024";
`'has deprecated attribute ' + CourseAttribute.MathNatSciEngr` (EUMS).
Source: [GH] `degree_requirements.ts`. Status: CODE (unofficial). Bears
on trusting an attribute index alone.

**SEAS-27. Half-credit labs and 1.5-CU courses.**
Quote: `CoursesWithLab15CUs = ["BIOL 1101", "BIOL 1102", "PHYS 0150",
"PHYS 0151", "PHYS 0170", "PHYS 0171", "ESE 1120"]`;
`StandaloneLabCourses05CUs = ["BIOL 1123", "CHEM 1101", "CHEM 1102",
"PHYS 0050", "PHYS 0051", "MEAM 1470"]`.
Source: [GH] `degree_requirements.ts`. Status: CODE (unofficial). The
scribe agrees on a 0.5-CU lab slot: "Natural Science Lab"
`Credits_begin=0.5` (`BIOL 1124, CHEM 1101, MEAM 1470, PHYS 0050`,
[GH] `CMPE-BSE-2026.xml`, VERIFIED (scribe)).

### 2.4 From the SEAS handbook and school pages (search summaries)

**SEAS-28. Dual degree with another school: at least 46 CU.**
Quote: "The number of required course units is specific to each program,
but the minimum requirement for any dual degree student with Engineering
is 46 course units."
Source: `https://academics.engineering.upenn.edu/ugrad/student-handbook/programs-options/dual-degrees-and-special-programs/`;
also `https://www.seas.upenn.edu/dual-degrees/`. Status: REPORTED.
**Not in `policy.ts` today.**

**SEAS-29. Dual degree eligibility.**
Quotes: "only students of demonstrated ability and a 3.0 cumulative GPA
or higher will be considered for dual degree status"; "a minimum of eight
(8) Penn course units"; "students applying from the Wharton School
require a minimum GPA of 3.4 for consideration". Source: as SEAS-28.
Status: REPORTED.

**SEAS-30. No triple counting.**
Quote: "No course may be triple counted, i.e., counted for more than two
degrees/majors." Source: SEAS dual majors page
(`.../programs-options/dual-majors-2-penn-engineering-programs/`).
Status: REPORTED. Matches `policy.ts` `crossDegree.maxPerDegree` and U-11.

**SEAS-31. No-credit courses count toward neither degree.**
Quote: "No Credit courses may not be applied towards either degree or
towards the 46 CU minimum." Source: as SEAS-28. Status: REPORTED.

**SEAS-32. Wharton and Engineering together require a statistics
sequence.**
Quote: "a one-year probability and statistics sequence which may be
satisfied with either ESE 3010/4020 or STAT 4300/4310". Source:
`https://www.seas.upenn.edu/dual-degrees/` (also reported on Wharton's
dual-degree page). Status: REPORTED. Penn Labs' M&T encoding has the same
pairs ("Probability" `ESE-3010 | STAT-4300`, "Statistical Inference"
`STAT-4310 | ESE-4020`, [GH] `mt.py`).

**SEAS-33. Dual major inside SEAS.**
Quotes: "Students must satisfy the requirements for each major and take a
minimum of 22 Engineering courses."; "Only one senior design project is
required for dual majors in engineering". Source: dual majors page.
Status: REPORTED.

**SEAS-34. Summer limit: 4 CU a summer, Penn and elsewhere together.**
Quotes: "Students may take a maximum of 4 course units (CUs) during the
summer term, whether the courses are taken at Penn, another institution,
or a combination of both."; (summary) "up to 4 CUs in the 11-week
session, and up to 2 CUs each in Summer Session I or II". Source:
`.../academic-policies/enrollment/` and the old
`.../undergraduate-policies/course-load/`. Status: REPORTED.
**CONFLICTING with `policy.ts`**, which holds `summerPerTerm: 2,
maxSummerTotal: 4` and reads the 4 as a lifetime total (the project notes
say "2 cu a summer and 4 in all"). As reported, 4 is per summer and 2 is per
half-summer session.

**SEAS-35. Credit away.**
Quotes: "Penn Engineering students may take up to 4 course units for
credit at other institutions."; "A minimum grade of 'C' is required";
"no credit will be granted for courses taken at two-year institutions";
"Credit Away courses may only be taken during the summer term."; study
abroad courses "numbered 2960 or 2970 ... may NOT be used in the
'Engineering' category". Source: `.../transfer-academic-opportunities/`
and the old `courses-at-other-institutions/`. Status: REPORTED.

**SEAS-36. Free electives.**
Quote: "any course offered by the University to undergraduates may be
taken as a free elective for an Engineering degree unless it is in the No
Credit list"; "effective Fall 2021 STAT 4050 and STAT 4220 can only be
used as free electives". Source:
`.../courses-registrations/course-categories/free-electives/`. Status:
REPORTED.

**SEAS-37. TBS may replace up to two SSH courses; ethics adds no units.**
Quote: "may choose to substitute up to two of the required social science
and humanities courses with approved courses from the Technology in
Business and Society course category". (Summary) the Ethics Requirement
"adds no units ... because it can double-count toward social science,
humanities, or TBS". Source:
`.../course-requirements/social-science-and-humanities-courses/`. Status:
REPORTED. Consistent with SEAS-04.

**SEAS-38. Accelerated master's: three graduate CU may count twice.**
Quote: "Students may double count up to three course units (CUs) of
graduate courses to fulfill both undergraduate and graduate degree
requirements." Source:
`.../programs-options/submatriculation-engineering/`. Status: REPORTED.
IRS caps cross-degree double counts at 3 (`doubleCountedCourses.length <
3`, CODE).

**SEAS-39. Good standing and pace.**
Quote (summary): "a minimum cumulative GPA of 2.0"; "an average of eight
completed course units per academic year". Source:
`.../academic-policies/`. Status: REPORTED, wording UNVERIFIED.

**SEAS-40. Per-major elective rules in the catalog (examples).**
Artificial Intelligence BSE: "Must be from one of the following approved
lists: SEAS Engineering (EUNG), CIS Restricted Technical Electives
(EUCR), and CIS Unrestricted Technical Electives (EUCU)", at most 1 CU at
the 1000 level. Electrical Engineering BSE: intermediate ESE electives
"2000+ level with an EUNG attribute (excluding EUMA)". MSE: "an MSE
elective (MSE 0000-4999)". Source:
`https://catalog.upenn.edu/undergraduate/programs/{artificial-intelligence-bse,electrical-engineering-bse,materials-science-engineering-bse}/`.
Status: REPORTED (summaries; wording UNVERIFIED). The scribe form of the
CMPE equivalents is VERIFIED: "Intermediate CIS or ESE Elective"
`CIS 2000:5999, ESE 2000:5999` except `ESE 4020, ESE 5420`; "Professional
Elective Course" `ENGR 5400, EAS 5450, EAS 5950, MGMT 2370, OIDD 2360, @ @
(With ATTRIBUTE=EUNS,EUMA,EUNG)` ([GH] `CMPE-BSE-2026.xml`).

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
`https://www.college.upenn.edu/degree-requirements`. Cohort: current
curriculum (through the Class of 2030). Status: REPORTED. Consistent with
the scribe's `STANDALONEBLOCK` (CAS-05).

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
`.../policies-governing-courses-and-registration/policies-governing-double-counting-courses`
and the per-major table at
`.../arts-and-sciences-cu-total-cu-sector-completed-major-concentration`.
Status: REPORTED; the two are **different rules for different cohorts**,
which is why the College publishes a policy book per class (`SOURCES.md`
S20). Which class changed over is UNVERIFIED.

**CAS-10. One course, one sector.**
Quote: "One course cannot be used to fulfill more than one Sector".
Source: as CAS-09 (b). Status: REPORTED.

**CAS-11. General education and minors share freely.**
Quote: "There is no limit to the number of courses that may be double
counted between General Education Requirements and requirements for a
minor." Source: as CAS-09 (b). Status: REPORTED.

**CAS-12. Departments may tighten double counting.**
Quote: "Major departments may have additional rules limiting double
counting between more than one major." Examples: Psychology minor "three
of the PSYC courses in the PSYC minor must count only in the PSYC minor";
Consumer Psychology minor "Two of the four PSYC courses must count ONLY
towards the CNPS minor, but it's OK to use a PSYC course for a sector or
foundational requirements"; "The AP waiver does NOT count towards the
courses required for the PSYC or CNPS minor."
(`https://psychology.sas.upenn.edu/node/221`); PPE "does not allow double
counting of courses in the major" (summary,
`https://ppe.sas.upenn.edu/study/curriculum/ppe-policies`). Status:
REPORTED.

**CAS-13. Total CU depends on the major: 32 to 36.**
Quote: "The total number of course units needed for graduation varies
between 32 and 36, depending on the number of credits required in the
major." "typically 20 courses outside the major"; "16 of the 20 credits
outside the major must be Arts and Sciences courses"; "Students who are
completing more than one major must use their largest major to calculate
the number of overall c.u." Source: College policy books (`C21-2.pdf` to
`C23.pdf`) and
`https://catalog.upenn.edu/undergraduate/arts-sciences/curriculum/`.
Status: REPORTED. Compare CAS-01/02, where the scribe states the same
idea per major (36 and 31 for Biology).

**CAS-14. Course load.**
Quote (summary): "The 5.5 c.u. limit applies after the first semester,
and first-year students are capped at 4.5 c.u."; raising it "generally
requires a 3.3 GPA and no outstanding Incompletes" (a 2016 book). Source:
`.../policies-governing-courses-and-registration/courseload`, `C16.pdf`.
Status: REPORTED; the GPA figure is old and UNVERIFIED for current
classes.

**CAS-15. Language requirement by placement.**
Quote: "students who score between 600 and 640 can be exempted from the
Language Requirement if they pass an oral exam" (policy book); department
pages: "a placement score of 650 or above is needed for exemption".
"The only students exempt from having a placement score are those who
have never studied the language before." Chinese: "these external exam
scores are not accepted by the Chinese Language Program for placement,
credit, or fulfillment of the language requirement." Source:
`C27policybookV3.pdf`; `https://figs.sas.upenn.edu/placement-exams`;
`https://web.sas.upenn.edu/chinese/requirements/`. Status: REPORTED;
thresholds differ by language.

**CAS-16. Mutually exclusive courses.**
Quote (summary): the College "won't grant credit for both"; examples
"STAT 1010 and 1110" and "MATH 1410 and MATH 1510". Source:
`.../policies-governing-courses-and-registration/courseload`. Status:
REPORTED, wording UNVERIFIED. The catalog's STAT page also marks "STAT
1010 and STAT 1110 as mutually exclusive".

**CAS-17. Dual degree with the College.**
Quotes: "To be eligible to apply for a dual degree, students must have
completed at least 4 course units in each of their first two semesters at
Penn."; "Applicants should have a cumulative g.p.a. of 3.3 or better";
"Students who transfer to Penn with junior standing are not eligible";
older book: "students who have been accepted to dual degree programs must
complete at least 14 College courses outside the major, including courses
for the Foundational Approaches, Sector Requirements and Free Electives";
older book: "the total number of course units for both degrees is between
37 and 48". Source: `https://www.college.upenn.edu/dual-degree`,
`.../policies-governing-academic-options/policies-governing-dual-degree`,
`C27policybookV3.pdf`. Status: REPORTED; the last two figures are from
older books and UNVERIFIED for current classes.

**CAS-18. Submatriculation: at most 4 graduate CU count twice.**
Quote: "In any submatriculation program, a maximum of 4 c.u. at the
graduate level may be included toward both the B.A." (sentence cut by the
search tool) and "Some graduate programs may permit fewer than four
courses to be double counted." Source: College double-counting page.
Status: REPORTED. A different search summary of the 2026 policy book
spoke of a cap of "eight courses" in a submatriculation section:
CONFLICTING and unresolved; read the C29 book.

**CAS-19. Credit away.**
Quote: "Students pursing a degree in the College may take no more than 5
c.u. at another college or university. The maximum amount of credit away
that can be transferred for one summer is 4 c.u."; (summary) no Penn
credit for courses taken elsewhere "during the academic year (fall and
spring)". Source: `https://www.college.upenn.edu/equivalent-credit`.
Status: REPORTED.

**CAS-20. Residency.**
Quote (summary): "at least half of the major's course units must be
taken at Penn"; "students must complete at least one-half of the courses
required for graduation at Penn". Source: College policy books. Status:
REPORTED; the scribe's `MINRES` values (CAS-01, CAS-07) are the same
rule, VERIFIED.

**CAS-21. Retaking.**
Quote: "Students who receive an F in a course may retake the course for
credit." Source: Class of 2025 policy book. Status: REPORTED. See U-04.

**CAS-22. Class of 2031 and later: a different curriculum.**
Quotes: "students are required to complete at least 36 credits in
total"; students distribute 20 credits across the three divisions
"Natural Sciences, Social Sciences, and Humanities & the Arts", with 12
in one, 5 in a second and 3 in a third; Foundations "consists of six
specific courses or course types"; language "two courses or demonstrated
fluency in a language other than English"; "information on this page
applies to students beginning as first-years in Fall 2027 and beyond".
Press: "Courses offered by Penn's three other undergraduate schools,
however, will not fulfill the general education requirements." Source:
`https://www.college.upenn.edu/academics/new-curriculum-class-2031-later/new-curriculum-distribution`
and `/new-curriculum-foundations`; the last quote is the Daily
Pennsylvanian. Status: REPORTED. One summary said "at least 30 credits
overall within the School of Arts and Sciences"; a second search could
not find the 30: UNVERIFIED.

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
below." Source: `https://catalog.upenn.edu/undergraduate/wharton/curriculum/`.
Status: REPORTED.

**WH-02. Cross-Cultural Perspectives: 2 CU may also count as general
education.**
Quote: "Two CUs satisfying the Cross-Cultural Perspectives requirement
may also double-count as Humanities; Social Sciences; Natural Sciences,
Math, and Engineering (NSME); and Flex General Education (FGE)." Source:
`https://undergrad-inside.wharton.upenn.edu/double-counting-courses/`.
Status: REPORTED. Matches `policy.ts` (`crossCultural+liberal`, cap 2).

**WH-03. Language courses taken at Penn also count as Humanities and
FGE.**
Quote: "Courses taken at Penn that satisfy the Foreign Language
requirement may also double-count as Humanities and FGE." Source: as
WH-02. Status: REPORTED. Note the limits `policy.ts` does not hold: only
**at Penn**, and only Humanities and FGE (not Social Science or NSME).

**WH-04. Second concentration.**
Quotes: "Up to 1 CU from a second concentration can double-count as a
Business Breadth."; "Students may not double-count courses between
concentrations."; catalog footnote (summary): students "may apply three
course units of concentration courses to Unrestricted Electives". Source:
WH-02's page, 2025-26 handbook, catalog curriculum page. Status:
REPORTED.

**WH-05. Business breadth.**
Quotes: "Business Breadth requires three upper-level course units from
three different Wharton departments outside of the student's
concentration."; (summary) "no more than 1 CU from any department (except
WH courses)"; "Business Breadth courses may not be double counted toward
any other requirements except for one course in the second
concentration."; all breadth courses "must be taken for a grade". If the
concentration is housed in one department but includes other departments'
courses, breadth "cannot include approved concentration courses"
(summary). Source:
`https://undergrad-inside.wharton.upenn.edu/business-breadth/`, catalog.
Status: REPORTED. The breadth subjects, from Penn Labs: `ACCT, BEPP,
FNCE, HCMG, LGST, MGMT, MKTG, OIDD, REAL, STAT, WH` (CODE).

**WH-06. Global Economy, Business and Society courses share with
nothing.**
Quote (summary of the 2025-26 handbook): "Global Economy, Business, and
Society courses may not be double-counted toward any other requirement."
Source: `.../wp-content/uploads/2025/06/2025-26_Handbook.pdf`. Status:
REPORTED, wording UNVERIFIED. **CONFLICTING with `policy.ts`**, whose
`petitionPairs` offers GEBS (group `wharton.flex`) with the concentration
as something an advisor may approve; the dry run printed "petition: MGMT
1110 ... Global Economy, Business and Society + ... General Management
Electives". If the handbook says what the summary says, that petition
should not be offered. Whether the same holds for Technology, Innovation
and Analytics is UNVERIFIED.

**WH-07. Senior capstone.**
Quotes: "One course with attribute WUCP required" (0.5 CU); "For all
senior capstone courses offered in fall 2027 and beyond, students must
also complete all business fundamentals as a prerequisite."; "MGMT 3880
Venture Acceleration Lab no longer fulfills the senior capstone
requirement, as of Fall 2026 offering." Source:
`https://undergrad-inside.wharton.upenn.edu/senior-capstone/`, catalog.
Status: REPORTED. Matches `policy.ts` `capstoneRule` (which adds the
Leadership Journey courses, also reported as prerequisites).

**WH-08. Course load.**
Quotes: "the standard course load is 4 to 5 CUs per semester"; "Wharton
students are limited to a maximum of 5.5 course units (CUs) for the first
semester."; "Students must be approved for more than 5.5 CUs of
enrollment."; the Petitions Committee "will not normally approve
enrollment more than 1 CU above the total from the semester immediately
prior"; minimum 4 CU per term. Source:
`https://undergrad-inside.wharton.upenn.edu/course-load/`. Status:
REPORTED. No 6.5 figure and no GPA condition were found for Wharton;
`policy.ts`'s `approved: 6.5` is the SEAS number.

**WH-09. Pass/fail.**
Quotes: "Wharton students may not choose to take a course pass/fail in
their first semester at Penn."; "Students may take a maximum of three
courses on a pass/fail basis."; "Unrestricted Electives may be taken
pass/fail unless they are being counted toward a second concentration or
a minor." Source: `.../pass-fail/`, `.../requirements/unrestricted-electives/`.
Status: REPORTED; the search tool flagged the pass/fail page as old and
the handbook as saying electives "must be taken for a grade":
CONFLICTING, unresolved.

**WH-10. Foreign language.**
Quotes: "Students must complete two semesters at the beginner level in a
language other than English, or demonstrate equivalent proficiency
through AP, IB, A-Level exams, or departmental placement tests."
(summary); "Students in the School of Nursing and Wharton may fulfill the
language requirement with a qualifying score of 450+ in the in-person
placement exam." Source: 2025-26 handbook;
`https://figs.sas.upenn.edu/placement-exams`. Status: REPORTED.

**WH-11. Liberal arts and sciences.**
Quote: "A minimum of 7 CUs from the categories listed below are necessary
to fulfill the liberal arts and sciences component of the curriculum,
plus the foreign language requirement". Attribute codes for searching:
`WUHM` Humanities, `WUSS` Social Science, `WUNM` Natural Sciences, Math,
Engineering, `WUCN` and `WUCU` Cross-Cultural, `WUFG` Flex Gen Ed.
Source: `.../liberal-arts-and-sciences/`, `.../las-course-list/`.
Status: REPORTED.

**WH-12. Courses from a dual degree or a minor may fill liberal arts.**
Quote: "Students pursuing uncoordinated dual degrees and departmental
minors in the College or SEAS may have courses from those programs also
fill Wharton's liberal arts and sciences requirements, provided the
courses are approved for Wharton." Source: double-counting page. Status:
REPORTED. This is the Wharton side of the cross-degree rule.

**WH-13. Submatriculation.**
Quote: "Students completing accelerated Master's or sub-matriculation
programs are typically limited to a maximum of three courses that can be
double-counted between the undergraduate and graduate degrees." Source:
double-counting page. Status: REPORTED.

**WH-14. Uncoordinated dual degree.**
Quotes: "students applying for uncoordinated dual degrees must have a
minimum cumulative GPA of 3.40"; "applicants must complete at least four
(4) course units (CU) per semester at Penn (fall and spring semesters
only)"; "unlike coordinated dual-degree programs, an uncoordinated dual
degree does not have a specialized curriculum." Source:
`.../dual-degree-wharton/`, handbook. Status: REPORTED. Wharton's own CU
total for a dual-degree student was not found.

**WH-15. Incompatible courses.**
Quote (summary): pairs include BEPP 2500 with ECON 2100, FNCE 1010 with
ECON 2200, STAT 1010 with STAT 1110; "when two incompatible courses are
completed, only the first counts toward degree requirements". Source:
`https://undergrad-inside.wharton.upenn.edu/incompatible-courses/`.
Status: REPORTED, wording UNVERIFIED. Penn Labs' M&T encoding lists
`BEPP-2500 | BEPP-2508 | ECON-2100` as alternatives for Managerial
Economics (CODE), consistent.

**WH-16. Retaking a failed course.**
Quote: "the new grade will not replace the original F, both grades will
be counted toward the cumulative GPA". Source: `.../retaking-courses/`,
`.../failing/`. Status: REPORTED.

**WH-17. AP, Class of 2029 on.**
Quote: "For the Class of 2029 and beyond, AP scores will not result in
credit for MATH 1400". Source: 2025-26 handbook. Status: REPORTED.
Consistent with U-08.

**WH-18. Business courses abroad.**
Quote (summary): "business courses can only be taken at Wharton-approved
study abroad programs". Source: handbook. Status: REPORTED, wording
UNVERIFIED.

---

## 5. Nursing

**NU-01. Total CU by class.**
Quote: "40.5 course units (class of 2025 and prior) or 39 course units
(class of 2026) or 36 course units (class of 2027 and beyond)". Source:
`https://www.nursing.upenn.edu/students/handbooks-forms/bsn-handbook/degree-requirements/`.
Status: REPORTED.

**NU-02. Load.**
Quote (summary): maximum "5.5 course units in a fall or spring semester
and 2 course units per summer session"; a student "is not able to request
a max course units increase until add/drop/swap begins". Source:
`.../bsn-handbook/courses-exam-related-policies/`. Status: REPORTED.

**NU-03. Pass/fail.**
Quote: "Students in the School of Nursing may take up to four courses
pass/fail", one per semester, in listed categories (list not seen).
Source: as NU-02. Status: REPORTED.

**NU-04. Residency.**
Quote: "all students must complete at least 19.5 course units at the
University of Pennsylvania School of Nursing to be eligible for the BSN
degree". Source: BSN handbook. Status: REPORTED.

**NU-05. Sectors.** Names differ by source and year: a plan of study
lists "Arts and Letters, Society and Social Structures, Histories and
Traditions, Global and Cultural Studies, and Reasoning, Systems, and
Relationships" (matching attributes `NUAL, NUSS, NUHT, NUGC, NURS`); the
current catalog lists "The Planet & Our Climate", "Societies, Histories,
and Traditions", "Global Arts, Letters, & Cultures" and "Diversity,
Universality, Justice, & Equity", plus "one exploration course (1
c.u.)". Source: `nursing.upenn.edu` sample plan;
`https://catalog.upenn.edu/undergraduate/nursing/curriculum/`. Status:
CONFLICTING by cohort (the sector model changed with the 36-CU
curriculum); the attribute codes for the new sectors are UNVERIFIED.

**NU-06. Language and free electives.**
Quote (summary): "If the language proficiency is met, the remaining
course units become free electives." Source: catalog `nursing-bsn`.
Status: REPORTED, wording UNVERIFIED. Placement threshold: WH-10's 450+.

**NU-07. Minors.**
Quote: "A minor requires approximately six to nine courses, and depending
upon the specific minor, some courses may fulfill sector requirements or
free electives."; "minors are only available to traditional BSN
students". Source:
`.../bsn-handbook/special-academic-option-policies/`. Status: REPORTED.

**NU-08. Second degrees and the MSN.**
Quotes: "students who have already completed one undergraduate degree
are exempt from all sector requirements"; for BSN-MSN, "no more than
three non-clinical course units may count toward the MSN program before
the BSN is complete". Source: catalog nursing curriculum; BSN handbook.
Status: REPORTED.

---

## 6. Coordinated dual-degree programs

**CD-01. M&T: 46 CU; a Wharton side of its own.**
Quotes: "M&T students are required to take a minimum of 46 credit units
in order to graduate."; "EAS 2030: Engineering Ethics will fulfill a
Wharton requirement as well as the Penn Engineering Ethics requirement";
MGMT 2370 can fulfill "one of the two business breadth requirements" for
students not concentrating in management; a student who cannot hold a 3.0
GPA "for three consecutive semesters is dropped". Source:
`https://fisher.wharton.upenn.edu/learn/dual-degree/`. Status: REPORTED.
Penn Labs' encoding, read from "Path@Penn what-if audits for WU_BS_MANT
and WU_BS_MAT_U (2024 to 2026 catalogs, which agree)" ([GH] `mt.py`,
CODE): the M&T variant suppresses `U-WFYF`, `U-WBUS`, `U-WLAS`, `U-WBBR2`
and the `WUCP` capstone, and adds "Quantitative/Computational Skills"
(MATH 1400; MATH 1410 or 1610; ESE 3010 or STAT 4300; STAT 4310 or ESE
4020), an "Engineering Senior Design Course" in place of the Wharton
capstone, "Humanities/Social Science Requirements" 2 CU (`WUHM, WUSS`),
"Cross-Cultural Requirement" 2 CU, business breadth 2 CU, and the M&T
block (`OIDD-2340 | OIDD-3990`, `MGMT-2370`). `cu_floor: 46`.

**CD-02. LSM: 43 CU.**
Quotes: "The minimum number of course unit credits required to graduate
with both degrees is 43; in practice, students do more than that.";
LSMP 4210 is "a two-semester (and two course unit) senior year Capstone
course". Source: `https://lsm.upenn.edu/information-and-suggestions-applicants`,
`/curriculum/lsm-specific-courses`. Status: REPORTED. Penn Labs ([GH]
`lsm.py`, CODE): allowed College majors `BIOL, BCHE, BIOP, CHEM, NRSC`;
"Sector 1 is waived because the Wharton degree requires economics, and
the proseminar fulfills Sector 7"; LSM students take "neither MGMT 3010
nor Wharton's senior capstone". `cu_floor: 43`.

**CD-03. VIPER: 46 CU, three energy courses, two research summers.**
Quote: "Dual-degree students should complete at a minimum of 46 course
units (CUs)". Source:
`https://www.viper.upenn.edu/academics/dual-degree-curriculum`. Status:
REPORTED. Penn Labs ([GH] `viper.py`, CODE): seminars `VIPR-1200`,
`VIPR-1210`, `VIPR-1300`; an approved energy-course list of about 44 codes; "VIPER
courses also count toward either degree"; allowed majors
`PHYS, MATH, CHEM, EESC, BIOL` with `CSCI, CBE, MSE, MEAM, EE, CMPE, BE`,
"Biology and Bioengineering are open only to the Class of 2029 and
earlier". The scribe confirms VIPR 1200 and 1210 together satisfy SEAS
ethics (rule "VIPR 1200 and 1210", [GH] `CMPE-BSE-2026.xml`, VERIFIED).

**CD-04. Huntsman: International Studies BA, 14 program CU.**
Quote (summary of the catalog page): "4 CU of language in one target
language, 3 CU of area studies, the INSP 1001 first-year seminar, 2 CU
each of UNIS and WUIS attribute courses, 1 CU of either international
studies or business, and a 1 CU senior capstone". Source:
`https://catalog.upenn.edu/undergraduate/programs/international-studies-ba/`.
Status: REPORTED. Penn Labs ([GH] `huntsman.py`, CODE): "Path has no
audit for it"; Arts and Sciences floor 24 CU; "Sector 1 is met by
Wharton's economics requirement and Sector 4 by INSP 1001"; capstone
`INSP-4997 | INSP-4999`, management capstone `MGMT-4090`.

**CD-05. NHCM.**
Quote: "NHCM students must take 1 CU of Social Science and 1 CU of
Humanities and 2 CU of CCP courses to fulfill their liberal arts and
sciences requirements." Source:
`https://undergrad-inside.wharton.upenn.edu/liberal-arts-and-sciences/`.
Status: REPORTED. Total CU and the nursing side: not found. Not encoded
by Penn Labs.

**CD-06. Coordinated programs own their completion rules.**
Quote: "coordinated dual-degree students should consult their program
advisors for degree completion policies and information." Source:
Wharton 2025-26 handbook. Status: REPORTED.

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

## 8. Where this disagrees with `policy.ts` today

| `policy.ts` | Finding | Rule |
|---|---|---|
| `loads.approved: 6.5` for every degree | True for SEAS (one-CU raise at 3.0 GPA; 7 by petition). Wharton: over 5.5 needs the Petitions Committee and normally at most +1 over the prior semester. College first-years: 4.5. | SEAS-17, WH-08, CAS-14 |
| `summerPerTerm: 2, maxSummerTotal: 4` read as "4 in all" | SEAS reports 4 **per summer**; 2 per half-summer session. Nursing 2 per session. Wharton not found. | SEAS-34, NU-02 |
| no total-CU floor for two degrees | 46 CU minimum for any dual degree with Engineering; no-credit courses excluded. | SEAS-28, SEAS-31 |
| `petitionPairs`: `wharton.flex` with concentration | Handbook reported to bar GEBS from any double count. | WH-06 |
| `withinDegree`: language with liberal arts, any | Only courses taken at Penn, and only Humanities and FGE. | WH-03 |
| area list with CIS elective, by label regex | Confirmed, and the scribe gives the lists as `MINCLASS` overlays. | SEAS-13 |
| `crossDegree.maxPerDegree: 1` | Confirmed ("No course may be triple counted"). | SEAS-30, U-11 |
| capstone after fundamentals | Confirmed for capstones from fall 2027. | WH-07 |
| nothing on SSH with a College major | SSH shares with College majors by scribe. | SEAS-08 |
| nothing on no-credit courses | The degree block excludes a list outright. | SEAS-05 |
