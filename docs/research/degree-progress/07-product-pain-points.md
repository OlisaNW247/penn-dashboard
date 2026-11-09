# 07 - Product context: Path@Penn pain points and what a good version looks like

Researched 2026-11-09. Labels: [read directly] = I fetched the page/file; [search summary only] = from a WebSearch result summary (the tool paraphrases pages, so quoted phrases are as the summary reproduced them, not verified against the full article); [inferred] = my reasoning.

Overall evidence quality: thin on student voice. No r/UPenn thread and no full DP article was readable (hosts blocked). Penn's own advising pages acknowledging worksheet errors are the strongest pain-point evidence, but only via snippets.

## 1. Path@Penn complaints and praise

**Worksheet inaccuracy (strongest signal)**
- Penn CIS advising handbook admits Path worksheets have errors: a required course can be missing, a non-qualifying course can be listed as qualifying, some students get a 37-unit worksheet when they should have 40. Quote: "There are a variety of small issues with the current versions of the degree worksheets in Path. Sometimes a course that satisfies a requirement is missing from the worksheet". It recommends checking the registrar's requirement list instead. Page is ~2022 vintage, may be outdated. https://advising.cis.upenn.edu/worksheet/ [search summary only]
- Same site: a wrong graduation date in Path can stop the senior audit email arriving. https://advising.cis.upenn.edu/senior-audit/ [search summary only]
- Wrong worksheet version by entry year: SEAS handbook says students who entered before Fall 2020 cannot switch to the "Entered Fall 2020 or later" worksheet. https://academics.seas.upenn.edu/ugrad/student-handbook/faq/which-worksheet-should-i-use/ [search summary only]
- [inferred] Because a department publishes a page telling students to cross-check against the registrar list, "ignore the worksheet / verify with advisor" is the de facto norm. I found no source that literally says advisors tell students to ignore it.

**Missing check marks drive behavior**
- DP opinion, Sept 2026: "Students were there because a missing check mark on their Path@Penn degree audits made this class the easiest way to get a green light." Argues for dropping general education requirements. Opinion, not audit-error reporting. https://www.thedp.com/article/2026/09/penn-general-requirement-exploration-optimization [search summary only]
- [inferred] Students optimize for the green check, so a tool that shows "what is missing" prominently shapes course choice. Accuracy matters more than polish.

**Usability at launch / registration stress**
- DP, April 2022, "'Not as efficient': Students criticize Path@Penn as difficult to navigate". Students hoped for better than Penn InTouch but were disappointed in advance registration; two resorted to Penn Course Plan to build mock schedules; a Penn administrator blamed the coding company; the release landed right before advance registration. Some found the interface more navigable and nicer looking (the only praise found). https://www.thedp.com/article/2022/04/path-at-penn-difficult-to-navigate-advance-registration-fall-2022 [search summary only]
- DP 2022 coverage also says students found it "complicated to create mock schedules through Path@Penn". Same URL. [search summary only]
- SCUE white paper (DP, Jan 2025): students reported "frustration" and "difficulty" with Penn's course planning project, difficulty navigating/registering, and confusing sector tags causing few sector-fulfilling options. https://www.thedp.com/article/2025/01/penn-scue-white-paper-released-2025-analysis [search summary only]
- DP, Feb 2025, Path Plans launch: Path Plans lets students add courses they are considering for future semesters and validate them against primary degree requirements. The College says it is a "course planning tool, not an academic or degree planning tool" and distinct from Degree Audit. Registrar warns validated courses may not run that semester. https://thedp.com/article/2025/02/path-at-penn-releases-new-application ; College guidance https://www.college.upenn.edu/node/201 [search summary only]
- DP column, Nov 2025, "Path@Penn needs AI" (Piper Slinka-Petka): proposes a chatbot that answers questions like how many more courses are needed to finish a degree. Penn has not been reported to build it. https://www.thedp.com/article/2025/11/ai-chatbot-in-path-at-penn-course-registration [search summary only]
- DP 2019 opinion on the old Penn InTouch worksheet: it did not show courses already taken, forcing students to juggle browser tabs. https://www.thedp.com/article/2019/11/penn-intouch-path-registration-advance-ivy-league-harvard-yale [search summary only]
- DP 2021 column: replacement will do little if advisors do not learn to use it. https://www.thedp.com/article/2021/10/upenn-in-touch-academic-planning-pennant-ngss [search summary only]

**What-if / double counting**
- Penn's Path shows worksheets only for declared programs; other majors are viewable under "Explore Programs" (the closest to what-if). https://apps.srfs.upenn.edu/secure/Pennant-Training/Students/Degree-Audit/Explore-Programs-in-PATH.pdf [search summary only]
- No Penn-specific student complaint about what-if or double counting found. [search summary only]. [inferred] Gap is real for a phone tool: Explore Programs is separate from the planner, and Path Plans is not degree-aware beyond validating primary requirements.

**Not found:** r/UPenn threads (one result, https://r.datuan.dev/r/upenn, is a mirror index with no readable content), slowness complaints specific to the worksheet.

## 2. Penn Labs' Penn Degree Plan (PDP)

- Penn Labs lists penn-courses as powering "Penn Course Review, Penn Course Plan, Penn Course Alert, and Penn Degree Plan". https://github.com/pennlabs [search summary only]
- Access: gated beta. NoAccessModal text: "Your account doesn't have access to Penn Degree Plan yet. Stay tuned for the beta!" with a Logout button. Dev README says to add users under "PDP Beta Users" in Django admin. Requires an account (user object gates requests). https://raw.githubusercontent.com/pennlabs/penn-courses/master/frontend/degree-plan/components/NoAccessModal.tsx and .../frontend/degree-plan/README.md [read directly]
- Auth mechanism: the degree-plan package.json lists no auth library; the Platform/PennKey link is [inferred] from Penn Labs convention, not confirmed in code I read.
- No launch announcement, DP coverage, or student feedback found. [search summary only]
- Layout (FourYearPlanPage.tsx): desktop shows up to three resizable panes: Plan (semester columns), Requirements, Search; plus a "Dock" of saved courses. Phone layout (useIsPhone) is a swipeable four-tab view: plan / requirements / search / docked, with a tab bar showing docked count. Drag and drop uses react-dnd + HTML5 backend. Onboarding modal forces creating a degree plan first. https://raw.githubusercontent.com/pennlabs/penn-courses/master/frontend/degree-plan/components/FourYearPlanPage.tsx , package.json [read directly]
- Requirements presentation (Rule.tsx, ReqPanel.tsx): a collapsible recursive tree. Group headers show percent and a fill bar; leaves show "cus / credits" or "n/N"; "Pick N:" groups; animated check when progress == 1; per-leaf manual-override tag with popover. Multi-program plans get tabs (one per program), selected tab remembered. Program progress = average of top-level rules; Pick-N = average of N furthest children; leaf = min(credit ratio, count ratio). https://raw.githubusercontent.com/pennlabs/penn-courses/master/frontend/degree-plan/components/Requirements/Rule.tsx and ReqPanel.tsx [read directly]
- Double counting: the frontend lets one course count toward every rule it lists; no enforcement client-side. Open issue "[PDP] Double counting restrictions" (#630, Apr 2024). Other issues: "[PDP] Double major does not show" (#751, Nov 9 2025), "[PDP] Support minors and double majors" (#651), "Selecting Engineering Degree Doesn't Filter Out Majors Properly" (#683), "[PDP] Add overrides" (#627), migrating plans when requirements reload (#623). No issue mentions what-if or mobile. https://github.com/pennlabs/penn-courses/issues?q=is%3Aissue+degree [read directly]
- What-if: none visible in the code I read. [read directly] (absence in files read, not whole repo).
- Takeaway [inferred]: even Penn's best-resourced student dev team shipped an unfinished beta with double-major and double-count gaps as of Nov 2025; encoding Penn requirements accurately is the hard part, not the UI.

## 3. Competitors and reference designs

- Stellic (via school help pages): a progress bar split by status, green = completed, golden yellow = in progress, plus remaining/planned; hover shows credit detail; separate bar for non-course "milestones"; drag-and-drop planner whose progress reflects the official audit. Could not confirm a mobile app or an "on track" label. https://www.ou.edu/degreemanagement/stellic.html , https://uwm.edu/registrar/?p=1964 , https://www.uww.edu/advising/stellic [search summary only]
- Degree Works: percentage wheel ("degree progress") computed from checked boxes, may include in-progress and planned courses; schools warn to treat as a "general guideline". Legend: green circle/check = complete, half-filled blue circle = in progress, red/empty circle = not complete, with suggested courses for outstanding items. Symbols vary by school. https://www.farmingdale.edu/news/ram-program/2025/2025-09-12-anatomy-of-degreeworks-audit.shtml , https://www.lawrence.edu/sites/default/files/2024-11/Degree-Works_Guide_202001.pdf , https://sfasu.edu/degreeworks , https://www.fredonia.edu/sites/default/files/section/academics/registrar/_files/DegreeWorks_OVERVIEWFORADVISORS.pdf [search summary only]
- Indie iOS: "Degree Path" (free, requirement checklist plus next-semester course suggestions, iPad-oriented) https://apps.apple.com/us/app/id1662682581 ; "Degree Credit Planner" (Apr 2026, one-time purchase, checks if a registration plan still reaches graduation on time, almost no ratings) https://apps.apple.com/us/app/-/id6762043025 ; general planners Chipper, iStudiez Pro. No reliable reviews of degree-tracking apps. [search summary only]
- Open-source drag-and-drop Penn planner for MCIT/MSE-DS/MSE-AI (qu8n/pennplanner), archived as of May 1 2024 because Penn planned to roll out DegreeWorks that fall. https://github.com/qu8n/pennplanner [search summary only]
- Not researched/not found: Coursicle, Notion/Sheets templates (search did not surface them; skip or follow up).

**Recurring UI conventions**
1. Overall progress ring/bar plus a percentage (Degree Works wheel, PDP header fill, Stellic bar).
2. Segmented status by color: complete (green) / in progress (yellow or blue) / planned / not complete (red or gray). A legend is standard.
3. Requirements as a collapsible checklist/tree with "n of N" or "cu of cu" counts and a check at 100%.
4. Course chips inside requirements and semester columns for the planned order; drag-and-drop between semesters on desktop.
5. Multi-program switching via tabs (PDP) or separate audit blocks.
6. On phone (PDP): tabs/swipe between Plan and Requirements rather than side-by-side panes.
7. Cautions: wheels are "a guideline"; planned vs. official audit must be visibly distinguished [inferred].

## 4. When students care: calendar

Dates for 2026-27 come from the LPS calendar only, which says other schools may differ; the main undergraduate calendar was not found. https://lps.upenn.edu/about/academic-calendar [search summary only]

| When | Event | Source |
|---|---|---|
| Oct 26 - Nov 9, 2026 | Spring 2027 advance registration (LPS dates; today is the last day) | LPS calendar [search summary only] |
| Nov 17, 2026 | Spring 2027 course selection opens (LPS) | same |
| Nov 1 - Dec 15 | College dual-degree application window for spring (page may be outdated) | https://www.college.upenn.edu/node/220 [search summary only] |
| Mar 23 - Apr 6, 2027 | Fall 2027 advance registration (LPS dates stated for Fall 2026 on the page as Mar 23 - Apr 6; confirm the year) | LPS calendar [search summary only; year ambiguity] |
| Apr 14 | Fall course selection opens (as listed) | same |
| Apr 1 - May 15 | College dual-degree application window for fall (possibly outdated) | College page above |
| Spring of sophomore year (March; DP mentions an April 10 deadline) | College students declare major via Path "Declare/Update Field of Study" | https://www.college.upenn.edu/node/235 , https://www.college.upenn.edu/node/339 [search summary only] |
| End of first year; by fifth semester | College students declaring an Engineering major need 2 semesters at Penn and must declare by 5th semester; SEAS-admitted students declare at end of first year | https://www.college.upenn.edu/node/156 , https://admissions.upenn.edu/node/22 [search summary only] |
| After 2 semesters at Penn | Wharton uncoordinated dual-degree eligibility | https://undergrad-inside.wharton.upenn.edu/dual-degree [search summary only] |
| End of first year only | Transfer into M&T for current students | https://fisher.wharton.upenn.edu/apply/ [search summary only] |
| Add/drop, minor declaration, Wharton concentration deadline | Not found | n/a |

Registration launch complaints cluster at advance registration (2022 piece). [inferred] Peak use of a degree-progress screen is the 1-2 weeks before each advance registration window and right before major/dual-degree decisions.

Also noted: Fall 2026 start date differs between sources (Aug 25 per LPS vs Sept 2 per a third-party site); irrelevant here but unreliable.

## Sources
Listed inline. Primary reads: raw.githubusercontent.com/pennlabs/penn-courses frontend/degree-plan files (FourYearPlanPage.tsx, Rule.tsx, ReqPanel.tsx, NoAccessModal.tsx, README.md, package.json); github.com/pennlabs/penn-courses issue search; directory listings under frontend/degree-plan.

## Blocked hosts
No ENOTFOUND errors encountered because I did not fetch the blocked hosts; all of them (thedp.com, reddit.com, *.upenn.edu, etc.) were reached only through search snippets. WebSearch result summaries cannot be quoted verbatim with certainty.

## Open questions
- Exact 2026-27 university-wide advance registration dates (LPS dates only; Fall 2027 window year needs confirming).
- Actual student wording from r/UPenn and DP news about worksheet errors, slowness, what-if.
- Does Penn Degree Plan authenticate via Platform/PennKey, and is it open beyond beta? Is there any Penn Labs announcement?
- How often do worksheets mis-count in practice, and do advisors officially tell students to ignore them?
- Minor declaration timing, Wharton concentration deadline, add/drop dates.
- Coursicle, Notion and Google Sheets planners (not researched in depth); mobile Stellic UI.
- Does Penn expose any API or export of Path data (relevant to whether a phone app can import completed courses)? Not covered here.
