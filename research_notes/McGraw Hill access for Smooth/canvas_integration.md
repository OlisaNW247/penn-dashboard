# McGraw Hill courseware (Connect, ALEKS, SIMnet) and Canvas: what already reaches Canvas

> Method limitation, read first: every WebFetch call failed in this session (`getaddrinfo ENOTFOUND` for www.mheducation.com, mheducation.com and trainme.erau.edu; the harness said to stop trying other hosts). All findings below therefore come from WebSearch result summaries, which paraphrase the cited pages. I did not read any full page. Quoted phrases are as the search summaries reproduced them. Treat the claims as "documented per search summary of the cited URL" and re-verify the load-bearing ones (especially the due-date and calendar questions) by fetching the primary pages once mheducation.com is allowed in the session network settings. Searches run 2026-11-02.

## 1. How does Connect integrate with Canvas today (LTI 1.3 / LTI Advantage, deep linking, AGS) and what happened to the LTI 1.1 integration?

### Takeaway
The current McGraw Hill integration is "LTI Advantage" (LTIA, LTI 1.3), launched from a McGraw Hill tool link inside the Canvas course (Modules, not course nav, at many schools). The older LTI 1.1 "McGraw-Hill Connect" link is being migrated away from with a McGraw Hill migration tool; some schools set their own retirement dates in 2025-2026, but McGraw Hill's own admin page listed the Canvas LTI 1.1 sunset as "TBD" in the snippet I saw.

### Cited Findings
- McGraw Hill's official LTIA instructor guide describes a three-phase process starting with launching the McGraw Hill LTIA tool from the LMS; the instructor needs the Instructor role to register, and the tool may be named differently per LMS. — [McGraw Hill LTIA 1.3 instructor guide (PDF)](https://www.mheducation.com/content/dam/mhe/highered/documents/support/connect/ltia-1.3-lms-integration-experience-overview-instructor-guide.pdf) (via search summary)
- In Canvas the LTI 1.3 tool is activated through the Modules feature (add it from a module's "+" or three-dot menu as "McGraw Hill Integration") rather than the course navigation bar; some schools still allow course navigation. — [Seattle Pacific Univ. "McGraw Hill LTI 1.3 Integration in Canvas"](https://spu.atlassian.net/wiki/spaces/ETMH/pages/36544380/McGraw+Hill+LTI+1.3+Integration+in+Canvas); [Boise State migration tool page](https://talk-boisestate.atlassian.net/wiki/spaces/LTS/pages/2472050719/McGraw+Hill+Migration+Tool+for+Canvas+LTIA+1.3)
- McGraw Hill provides a migration tool that launches automatically the first time the LTI 1.3 tool is opened in a course; afterwards the old LTI 1.1 link (named "McGraw-Hill Connect") should be disabled in the course menu. — [Boise State](https://talk-boisestate.atlassian.net/wiki/spaces/LTS/pages/2472050719/McGraw+Hill+Migration+Tool+for+Canvas+LTIA+1.3); [McGraw Hill "Connect Canvas migration tool"](https://www.mheducation.com/highered/support/knowledge/connect-canvas-migration-tool.html)
- McGraw Hill's migration tool fails if a Canvas assignment's due date falls after the matching Connect due date (Canvas rejects conflicting due dates); fix by adjusting dates and restarting. — [McGraw Hill Connect Canvas migration tool](https://www.mheducation.com/highered/support/knowledge/connect-canvas-migration-tool.html) (via search summary)
- McGraw Hill's administrator page for LTIA listed "Canvas | McGraw Hill Connect LTI 1.1 | TBD" for the LTI 1.1 sunset. — [McGraw Hill Connect and LTI Advantage – Administrators](https://www.mheducation.com/highered/support/knowledge/ltia-admin.html) (via search summary)
- School-set dates: Univ. of Illinois announced an upgrade of its Connect integration to LTI 1.3 (page shows an Aug 5, 2026 date); a Seattle Pacific page labels the old tool "McGraw-Hill Connect (retired August 2026)"; Framingham State published a "Summer 2025" LTI 1.1 to 1.3 migration notice. — [Canvas@Illinois](https://answers.illinois.edu/162247); [SPU transition page](https://spu.atlassian.net/wiki/spaces/ETMH/pages/36544239/McGraw+Hill+Transition+Existing+Canvas+Course+from+LTI+1.1+to+LTI+1.3); [Framingham State](https://framingham.teamdynamix.com/TDClient/1792/ServiceHub/KB/Article/165850/McGraw-Hill-Migration-LTI-1-1-to-LTI-1-3-Summer-2025). I did not verify the dates were applied.
- McGraw Hill markets LTI Advantage as the LMS integration, with grade sync (AGS-style) described in its "Grade Sync" troubleshooting articles. — [What is LTI Advantage (LTIA)?](https://www.mheducation.com/highered/support/knowledge/what-is-lti-advantage-ltia.html); [Grade Sync: Troubleshoot Grade Sync in LTI Advantage](https://www.mheducation.com/highered/support/knowledge/grade-sync-troubleshoot-grade-sync-in-lti-advantage.html)
- Penn Canvas info site (Penn's own) says Canvas connects to external tools via LTI, lists McGraw-Hill Connect among integrable course content, says any instructor can enable a Penn-supported tool in their own course, and says Penn runs a security/privacy review (VSTAR) before a third-party tool is installed. — [infocanvas.upenn.edu/tools/tools-in-canvas](https://infocanvas.upenn.edu/tools/tools-in-canvas/); [enabling a tool in Canvas](https://infocanvas.upenn.edu/tools/enabling-a-tool-in-canvas/)

### Inferences
- LTI 1.3 + AGS + Deep Linking are the standard components of "LTI Advantage"; McGraw Hill's product naming (LTIA) implies all three are used, but I did not see McGraw Hill's own text confirming each service by name (no Names and Role Provisioning confirmation either way).
- For Penn in Nov 2026, new or migrated sections are most likely LTI 1.3; some sections may still be on LTI 1.1 if instructors have not run the migration. Not confirmed for Penn.

### Gaps
- No page read in full (fetch blocked). No 1EdTech certification registry check was done for McGraw Hill.
- Penn's actual installed McGraw Hill tool version (1.1 vs 1.3) and any Penn retirement date: not found.
- Whether NRPS (roster) is used: not found.

## 2. Do Connect assignments become Canvas assignments with due dates, and do due dates sync (direction, timing)?

### Takeaway
Per multiple school guides, once the instructor pairs/"syncs" the Connect section and deploys assignments, Connect assignments appear in Canvas as ordinary Canvas assignments (external tool) and the Connect due date is the source of truth, edited in Connect not Canvas. Propagation of later Connect date changes is not clearly documented; at least one guide says a re-sync is needed after date changes.

### Cited Findings
- Stonehill guide: McGraw-Hill Connect content (textbook readings or other assignments) is added to Canvas as an Assignment. — [Stonehill: Accessing Third Party Publisher Tools in Canvas](https://stonehill.teamdynamix.com/TDClient/1841/Portal/KB/PrintArticle?ID=154634) (via search summary)
- Assignments reach Canvas only when the instructor deploys them; "once the deployment finishes, the assignments will be available in Canvas"; an undeployed (unlinked) assignment will not appear. — [CSU Chico](https://support.csuchico.edu/TDClient/1984/Portal/KB/ArticleDet?ID=114811); [Liberty/McGraw Hill "repair an unlinked Connect assignment" (PDF)](https://www.mheducation.com/unitas/highered/services/schools/liberty/digital-training-series-repair-an-unlinked-connect-assignment.pdf) (via search summary)
- McGraw Hill's grade sync article: assignments must be deployed to the LMS and students must complete account pairing before sync starts automatically. — [Troubleshoot Grade Sync in LTI Advantage](https://www.mheducation.com/highered/support/knowledge/grade-sync-troubleshoot-grade-sync-in-lti-advantage.html) (via search summary)
- Lewis-Clark State College service desk says Connect due dates are inherited into Canvas and instructors should not edit them in Canvas. — [LETU/LCSC: How to Complete a Manual Sync between Connect and Canvas](https://servicedesk.letu.edu/TDClient/2460/Portal/KB/Article/121828/How-to-Complete-a-Manual-Sync-between-Connect-and-Canvas) (via search summary; note the host is servicedesk.letu.edu, so the institution attribution in the summary may be wrong)
- Embry-Riddle guide: instructor opens McGraw-Hill Connect in the Canvas course, chooses "Sync with my Connect section", and a grade sync is needed again after any date change; dates are changed in Connect via "Manage dates" (bulk or individual). — [ERAU Syncing to Canvas](https://trainme.erau.edu/mcgraw-hill-instructor/sync); [ERAU Due Dates](https://trainme.erau.edu/mcgraw-hill-instructor/due_dates)
- McGraw Hill official: due dates are set and managed in Connect (Manage Assignments, Assignment Actions, bulk or per-assignment). — [Connect: set and manage due dates](https://www.mheducation.com/highered/support/knowledge/connect-set-and-manage-due-dates-for-your-connect-course.html); [set-and-manage-due-dates PDF](https://www.mheducation.com/content/dam/mhe/highered/documents/support/connect/set-and-manage-due-dates-new.pdf)
- Arkansas State advises instructors to confirm due dates and grading settings in Canvas after adding Connect activities, implying dates are not guaranteed to match. — [A-State KB](https://kb.astate.edu/books/learning-technology/page/using-mcgraw-hill-connect-in-canvas) (via search summary)
- McGraw Hill's SIMnet LTIA page (a different product) lists start date, due date, end date and title changes as NOT supported by that integration. — [SIMnet LTI Advantage (v1.3)](https://help.simnetonline.com/manager/integrations/lti-advantage-v1.3)
- Older copies of Connect assignments can create duplicate gradebook columns; a Connect assignment with zero total points will not pass back. — [Framingham State: Automatically pass back zeroes](https://framingham.teamdynamix.com/TDClient/1792/ServiceHub/KB/PrintArticle?ID=167725) (via search summary)

### Inferences
- Direction appears to be Connect to Canvas for dates (Connect authoritative), with an explicit instructor sync/deploy step; whether a later date edit in Connect updates the Canvas due date automatically, or needs a re-sync, is contradictory/unclear (ERAU says re-sync; LCSC says dates are inherited).
- If assignments are real Canvas assignments, Smooth's existing Canvas calendar/API path should already see them (see Q3), but with the risk that a stale Canvas date lags a Connect-side change or extension.

### Gaps
- No McGraw Hill primary statement, read in full, that a Connect due-date change propagates to Canvas automatically and when (on change, nightly, on re-sync). This is the single most important thing to verify.
- Whether Connect creates the Canvas assignment via Deep Linking content-item selection (instructor-driven) vs. automatic creation: not confirmed.
- Per-student extensions in Connect (see Q6) reaching Canvas as due-date overrides: not found.

## 3. Do these show in the Canvas ICS feed and assignments API, and what hostnames appear?

### Takeaway
No source I found explicitly says Connect items appear in the Canvas calendar feed or API, but Canvas treats LTI-launched assignments as normal published assignments with due dates, which show on the calendar. Hostnames and `external_tool_tag_attributes.url` values were not found in any source.

### Cited Findings
- Canvas community answer: any published assignment with a due date should show on the Canvas calendar automatically (and the course's calendar toggle must be on). — [Canvas Community: Canvas Calendar and Assignments](https://community.canvaslms.com/t5/Canvas-Question-Forum/Canvas-Calendar-and-Assignments/td-p/539248) (via search summary)
- Connect content is added to Canvas as an Assignment (Stonehill, see Q2). — [Stonehill](https://stonehill.teamdynamix.com/TDClient/1841/Portal/KB/PrintArticle?ID=154634)
- Penn State notes Canvas's To Do list and Dashboard list view were showing incorrect items in January 2025; the Calendar is the alternative. — [Penn State IT notice, Jan 21 2025](https://www.it.psu.edu/?p=239160) (via search summary)

### Inferences
- Because Connect items become Canvas assignments with due dates (Q2), they should appear in the course calendar ICS feed and in `GET /api/v1/courses/:id/assignments` with `submission_types: ["external_tool"]`. This is inference from how Canvas treats LTI assignments, not documented for McGraw Hill specifically.
- Items not deployed to Canvas, or with no due date, will not appear in the calendar feed.

### Gaps
- Actual hostnames (connect.mheducation.com, newconnect.mheducation.com, lti.mheducation.com, aleks.com, mhcampus) in `external_tool_tag_attributes.url`: no source found. Must be confirmed empirically with a Penn student's Canvas API response.
- Whether the ICS event URL/description carries any McGraw Hill link: not found.

## 4. Does submission/completion state reach Canvas (AGS passback timing, submitted_at, auto-zero)?

### Takeaway
Scores are passed back by LTI grade sync; McGraw Hill states that by default a zero is sent to the LMS at the due date (or at an extended/late date) for incomplete work. Whether Canvas records `submitted_at` or `workflow_state: submitted` on passback is not documented in what I found.

### Cited Findings
- By default, if a student does not complete an assignment, a zero is automatically sent to the LMS at the due date (or after any exception/late-submission date), even if the student never opened it; manually graded items do not get an automatic zero until graded. — [McGraw Hill: Troubleshoot Grade Sync in LTI Advantage](https://www.mheducation.com/highered/support/knowledge/grade-sync-troubleshoot-grade-sync-in-lti-advantage.html) (via search summary); an instructor-facing mirror: [Framingham State: Automatically pass back Zeroes to Canvas Gradebook after Assignment Due Date](https://framingham.teamdynamix.com/TDClient/1792/ServiceHub/KB/PrintArticle?ID=167725)
- Sync begins only after assignments are deployed and the student has paired their McGraw Hill and LMS accounts. — [Troubleshoot Grade Sync](https://www.mheducation.com/highered/support/knowledge/grade-sync-troubleshoot-grade-sync-in-lti-advantage.html)
- A Connect assignment with zero total points will not pass back. — [Framingham State](https://framingham.teamdynamix.com/TDClient/1792/ServiceHub/KB/PrintArticle?ID=167725)

### Inferences
- A score of 0 posted at the due date is indistinguishable, in Canvas, from a genuine zero; a Smooth rule that treats "score present" as "turned in" would misfire on these auto-zeros. A safer signal is score > 0 or `submitted_at` present.
- Whether a student's in-progress or completed (pre-deadline) work posts a score immediately or only at/after the due date is not documented in what I read.

### Gaps
- Timing of non-zero score posting (on submission vs. at due date vs. instructor-triggered sync), `submitted_at` behaviour, and Canvas "pending/auto-submit" handling: not found.

## 5. Which cases are NOT covered (no pairing, link-only, ALEKS, SIMnet, Inclusive Access) and how common are they?

### Takeaway
Connect without Canvas pairing, link-only integrations, SIMnet (due dates unsupported), and ALEKS (typically gradebook columns, not per-assignment items by default) leave gaps. I found no prevalence data.

### Cited Findings
- Pairing is an instructor action; a student cannot use the Canvas integration unless the instructor enables the tool and syncs the section. Prerequisite: a Connect course must already be set up. — [Univ. of Wisconsin KB, McGraw Hill Campus in Canvas](https://kb.wisconsin.edu/dle/109740); [UF Connect page](https://elearning.ufl.edu/instructor-help/teaching-and-learning-tools/canvas-learning-tools/learning-tools/mcgraw-hill-connect.php) (via search summary)
- ALEKS has its own LTI 1.3 tool, launched from the Canvas course, pairing a Canvas shell with an ALEKS class; gradebook sync is optional and enabled in ALEKS Gradebook Setup. — [Rutgers: ALEKS getting started for instructors](https://canvas.rutgers.edu/documentation/external-apps/aleks-getting-started-for-instructors/); [McGraw Hill: instructor Canvas adding ALEKS 1.3 tool (PDF)](https://www.mheducation.com/content/dam/mhe/highered/documents/support/aleks/instructor-canvas-adding-aleks-1-3-tool.pdf)
- ALEKS can sync either one total-grade column (renamable, point value settable) or selected categories, in which case each ALEKS assignment becomes its own Canvas gradebook item; ALEKS weights apply only to the total. — [Rutgers ALEKS guide](https://canvas.rutgers.edu/documentation/external-apps/aleks-getting-started-for-instructors/); [McGraw Hill ALEKS Gradebook](https://www.mheducation.com/support/aleks-support-center/knowledge/classic-aleks---gradebook.html) (via search summary)
- ALEKS "Sync Time" setting exists for Canvas but its effect is not explained in the summaries; the Brightspace guide has a "Synchronize on assignment due dates" option that withholds grades until each due date passes. — [ALEKS Brightspace tool guide (PDF)](https://www.mheducation.com/content/dam/mhe/highered/documents/support/aleks/instructor-brightspace-adding-aleks-1-3-tool.pdf)
- SIMnet's LTI Advantage integration does not support due date, start date, end date or title changes. — [SIMnet LTIA v1.3](https://help.simnetonline.com/manager/integrations/lti-advantage-v1.3)
- McGraw Hill Campus is a separate Canvas integration (a link/materials product). — [Univ. of Wisconsin: Canvas Integration, McGraw Hill Campus](https://kb.wisconsin.edu/dle/109740)

### Inferences
- With ALEKS "total grade" mode, Canvas gets one column (probably no per-assignment due dates), so Smooth would see at most a single item; per-assignment items only if the instructor syncs categories. Due dates for those Canvas items are not documented.
- Inclusive-access-only or link-only courses (student just gets a Connect section URL) create nothing in Canvas; Smooth cannot see them without McGraw Hill access.

### Gaps
- No prevalence figures for any case.
- Connect Master, Sharpen/ReadAnywhere, Achieve-style (Macmillan, not McGraw Hill) integrations with Canvas: not researched in these results. Note "Achieve" is a Macmillan product name; I did not research it.

## 6. Student reminders/extensions in Connect

### Takeaway
Extensions are an instructor feature in Connect; I found no documentation of student reminder emails or mobile-app notifications.

### Cited Findings
- Instructors can give per-student or bulk extensions (start date, due date, time limit, attempts) inside Connect; extensions do not change the student's grade; instructors can edit start dates of active assignments. — [Connect assignment extensions](https://www.mheducation.com/highered/support/knowledge/connect-assignment-extensions.html); [How do I manage student extensions (PDF)](https://www.mheducation.com/content/dam/mhe/highered/documents/support/connect/how-do-i-manage-student-extensions.pdf); [McGraw Hill Connect webinar FAQ 2026](https://www.mheducation.com/content/dam/mhe/blog/higher-ed/2026/pdfs/faq-discover-whats-next-connect-webinar.pdf) (via search summary)
- Grade sync sends the zero at the extension/late date rather than the original due date (see Q4).

### Inferences
- A student's real deadline can differ from the Canvas due date (per-student Connect extension) and possibly is not reflected in Canvas's per-student view unless pushed as an override; unconfirmed.

### Gaps
- Student reminder emails, Connect student app/ReadAnywhere notifications: no source found.

## 7. Evidence of Penn courses using McGraw Hill Connect/ALEKS

### Takeaway
Penn's own Canvas info page lists McGraw-Hill Connect as an integrable LTI tool, but I found no Penn course syllabus or bookstore list naming Connect or ALEKS for ACCT, ECON, CHEM, MATH or intro business courses.

### Cited Findings
- Penn's Canvas info site lists McGraw-Hill Connect among course content that can be integrated via LTI and describes the enablement and VSTAR review process; contact canvas@pobox.upenn.edu. — [infocanvas.upenn.edu tools in Canvas](https://infocanvas.upenn.edu/tools/tools-in-canvas/); [enabling a tool in Canvas](https://infocanvas.upenn.edu/tools/enabling-a-tool-in-canvas/) (via search summary)
- Search for Penn syllabi/course pages naming Connect or ALEKS returned only other universities (Penn State, UT Dallas, Rutgers-Camden, UConn etc.). — [example: Penn State World Campus ALEKS 360 requirement](https://student.worldcampus.psu.edu/course-catalog/course/2241/21138) (not Penn)
- Mandel's "Economics: The Basics" (McGraw Hill, with Connect assignable problems) is authored by a Wharton senior fellow; this does not establish ECON 0100 adoption. — [McGraw Hill product page](https://mheducation.com/highered/product/m-economics-basics/M9781260226768.html)

### Inferences
- Penn's own repo notes (CLAUDE.md in this project) show Penn courses ACCT 1010, ECON 0100, MATH 1400, PHYS 0151 exist in the pool; whether they use McGraw Hill is unknown. The best check is empirical: look at the `external_tool_tag_attributes.url` hosts in real Penn students' Canvas assignment data (or the server's `course_documents` of kind assignment).

### Gaps
- Penn course-level adoption: not found. Penn Bookstore / Inclusive Access lists: not found via search; not fetched.

## Suggested next step for the caller
Re-run the fetches once mheducation.com, trainme.erau.edu, infocanvas.upenn.edu and community.canvaslms.com are allowed, specifically: (a) the McGraw Hill LTIA instructor guide PDF and "Grade Sync" article for due-date propagation and score-posting timing; (b) the ERAU sync page; (c) the Canvas Guides for LTI AGS and `submitted_at`. Then verify empirically with one Penn student's real `GET /api/v1/courses/:id/assignments` response.
