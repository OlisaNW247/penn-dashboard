# 03 - Data routes and Penn policy (degree-progress research)

Researcher notes, 2026-11-09. Research only: nothing was signed into, no student data fetched, no app code written.
Labels: [read directly] = I fetched the page text myself; [search summary only] = only a WebSearch snippet/summary, page not opened; [inferred] = my reasoning.
Important limitation: almost every primary source (Penn, thedp, ed.gov, canvas.instructure.com) was unreachable from this sandbox (see Blocked hosts). Most Penn claims are therefore search-summary only.

## Route A - Read Path@Penn with the student's own session

**What it needs:** a WebView sign-in to Path@Penn through WebLogin + Duo, then the cookies/session reused for HTTP calls to whatever backend serves the degree audit.

**Same identity provider as Canvas?** [search summary only] Penn's Two-Step pages say Two-Step is required for any Penn web resource that prompts for PennKey and password via WebLogin ("Two-Step is only required for resources accessed through Penn's WebLogin system"). Path@Penn is a PennKey login, so it very likely uses the same WebLogin/IdP + Duo [inferred]. No page I could see names the Path@Penn IdP host explicitly. Sources: https://www.isc.upenn.edu/node/4279, https://www.isc.upenn.edu/node/4292 (not opened).
- Duo "trusted browser" lasts 60 days, no rolling restart [search summary only, same ISC pages]. Implication [inferred]: if Smooth's Canvas renewer already clears Duo through a trusted-browser cookie, a Path@Penn sign-in in the same WebView cookie jar would plausibly not re-prompt Duo within that window; needs a device test (cannot do here).

**Session timeout:** Nothing found. Search returned only generic vendor docs. Open question.

**Bot detection / terms against automation:** No Path@Penn-specific statement found. See Policies (AUP, password sharing). [search summary only]

**What is it built on?**
- Penn selected Ellucian Banner in 2013 [search summary only; ecampusnews 2013, https://www.ecampusnews.com/it-leadership/2013/11/12/university-pennsylvania-selects-banner-ellucian-help-provide-vital-services-students-university-community/].
- Path@Penn is the student portal of "Pennant", which runs on Ellucian Banner; Pennant includes Degree Works and CourseLeaf PATH (advisor course-choice tool) [search summary only; srfs.upenn.edu "Guide to Advising@Penn" https://srfs.upenn.edu/sites/default/files/publisher/Guide-to-Advising-at-Penn.pdf and CourseLeaf case study https://www.courseleaf.com/insights/case-studies/upenn/, both not opened]. That guide is ~5 years old and says many advisors lack Degree Works access.
- Counter-signals: a 2019 DP snippet said "Leepfrog Technologies" would build PATH (Leepfrog = CourseLeaf's former name, so consistent, not conflicting [inferred]). A Penn registrar job posting (undated) mentions "to-be-implemented Ellucian Degree Works" and requirements being translated from Catalog and Curriculum Manager "into the student-facing degree audit" [search summary only]. A search-result LLM wiki claiming Degree Works was unreliable; ignore.
- Student guide "Perform a Degree Audit in PATH": "From Path@Penn, click Degree planning and audit under Academic Planning and Registration"; clicking a block shows courses and attributes [search summary only, https://apps.srfs.upenn.edu/secure/Pennant-Training/Students/Degree-Audit/Perform-a-Degree-Audit-in-PATH.pdf]. College page: "Interpreting Your Degree Audit in Path@Penn" mentions percentage bars [search summary only, https://www.college.upenn.edu/interpreting-degree-audit]. CIS advising warns worksheets "have a variety of small issues" and the registrar's list is definitive [search summary only, https://advising.cis.upenn.edu/worksheet/].
- Verdict [inferred]: the audit is most probably Ellucian Degree Works (Banner-integrated), with Path@Penn as an SSO front door. Banner Self-Service 9 and Degree Works web are Ellucian products; I did not verify Penn's deployment or endpoints, and I did not find Penn-specific documentation of a Degree Works JSON API (generic knowledge that Degree Works' newer UI calls JSON services is NOT cited here and must not be relied on). Degree Works student UIs commonly require CSRF/session handshakes and a SAML hop, so a cookie-replay client would be fragile [inferred].

**Blocks:** no documented API; unverified endpoints; undocumented terms; possible UI changes (a Banner/Degree Works upgrade would break a scraper); Duo re-prompts; ToS/policy risk (below).
**Cost/benefit [inferred]:** the only route to the authoritative requirement-by-requirement audit, but the highest fragility and policy exposure.

## Route B - Student shares or uploads their own audit PDF/print

- No Penn-specific evidence found for "Save as PDF" on the Path@Penn audit. The Penn QRG (search summary) says nothing about print/export. Other schools' Degree Works guides describe a "Save as PDF" button or browser print-to-PDF (e.g. https://registrar.uky.edu/sites/default/files/2025-02/print-degree-audit-students.pdf, https://www.ferris.edu/HTMLS/administration/academicaffairs/mydegree/dwcontent/pdfs-docs/SaveasPDF.pdf) [search summary only; non-Penn]. Browser print-to-PDF from a web page is generally available [inferred].
- Unofficial transcript: Penn says most students/alumni (class of 1988+) can view unofficial transcripts for free in Path@Penn at any time; paid official electronic PDF transcripts are sent after ordering via Path@Penn [search summary only, https://srfs.upenn.edu/student-records/transcripts, https://catalog.upenn.edu/undergraduate/academic-resources/transcripts/]. No confirmed "download PDF" button on the free unofficial view. Holds can block viewing.
- Viability [inferred]: lowest policy risk (student's own file, no credential use, no automation), works offline in-app via iOS file picker / Share Sheet / PDFKit text extraction. Costs: manual step each time, layout varies by school/catalog year, parsing is a heuristic (needs on-device parsing; a transcript yields courses taken but not requirement mapping, an audit PDF yields requirements met/unmet). Also a good fallback if Route A is unavailable. A WebView "print this page to PDF" assisted flow is a middle path [inferred].

## Route C - Derive from Canvas (existing session, no token)

Docs fetched via the open-source Canvas LMS code comments on GitHub because canvas.instructure.com was blocked.
- GET /api/v1/courses: `enrollment_state` accepts active, invited_or_pending, completed; "respects section, course, and term date overrides". include[]: `term` ("enrollment term information"), `total_scores` (student computed_* grade fields, "ignored if the course hides final grades"), `concluded` (course concluded, considering course and term dates) [read directly, https://raw.githubusercontent.com/instructure/canvas-lms/master/app/controllers/courses_controller.rb; first 100k of 212k chars read]. Official docs page (not reachable): https://canvas.instructure.com/doc/api/courses.html.
- Enrollments: user's own enrollments allowed ("Currently, only a root level admin user can return other users' enrollments"; own are fine). state[] includes completed, current_and_concluded and others; grades object has current_grade/final_grade/current_score/final_score, "Only included if user has permissions to view this grade" [read directly, https://raw.githubusercontent.com/instructure/canvas-lms/master/app/controllers/enrollments_api_controller.rb]. Official page: https://canvas.instructure.com/doc/api/enrollments.html.
- Cookie-session API access (no token) is not covered in what I read; Canvas generally accepts session cookies for same-origin API calls but with CSRF requirements on writes; GETs are fine [inferred, matches what Smooth already does for current courses; check repo].
- Limits [inferred]: only courses that had a Canvas site and where the student was enrolled; hidden/unpublished or hidden-grade courses; older terms may be missing if Penn concluded/archived them or restricted past-course access; no transfer/AP/IB credit, no credit units, no requirement mapping, no grade-mode (pass/fail), no withdrawals as such; course name/code like "CIS 1200-001 202430" must be parsed (term code 202430 -> Fall 2024; Penn convention 10=Spring, 20=Summer, 30=Fall, inferred) and cross-listed sections add noise. Good for a "courses taken" list and for matching against requirement lists from Penn Courses/registrar data; not a degree audit.
- Terms: Canvas API use with the student's own session is the same trust model already in Smooth.

## Route D - Partnership / official data

- 2013: DP reported PennApps Labs worked with ISC (owner of Penn InTouch data) to expose course data via an API using PennKey logins [search summary only, https://www.thedp.com/article/2013/10/penn-course-data-api].
- Penn Labs' `registrar` repo is archived, "DEPRECATED: Use the Penn OpenData Course Catalog service instead" [search summary only, https://github.com/pennlabs/registrar]. Penn OpenData is an ISC service with a token required (Python SDK "Validated API token required"; SwaggerHub spec under UPennISC) [search summary only, https://pypi.org/project/PennSDK/0.1.1, https://beta.pkg.go.dev/github.com/penn-automate/penn-opendata-api]. This is catalog data, not student records.
- Penn Labs ships "Penn Degree Plan" (PDP) in github.com/pennlabs/penn-courses ("Powering Penn Course Review, Penn Course Plan, Penn Course Alert, and Penn Degree Plan") [read directly, repo landing page]; where PDP gets requirements was not stated [read directly: not mentioned; not found elsewhere]. A 2021 DP article said Penn Labs must rebuild its API to work with Path@Penn [search summary only, https://www.thedp.com/article/2021/09/penn-intouch-replacement-path-course-registration].
- No evidence found of any official program giving student-built apps access to individual student records (audit/transcript). OpenData appears limited to institutional/catalog data [inferred]. Next step: email the registrar/ISC and Penn Labs directly. Contact for privacy questions: privacy@upenn.edu [search summary only].

## Policies (all search summary unless marked)

- **PennKey password sharing** (Penn PennKey Support, https://pennkeysupport.upenn.edu/node/16): users should "never, under any circumstances, share your PennKey password with anyone"; sharing "is also a violation of University policy"; "you are still responsible for anything done using your PennKey." Almanac: https://almanac.upenn.edu/articles/sharing-your-pennkey-password-is-not-smart. These paraphrases came from the search summary; exact quoting unverified.
  - Relevance [inferred]: Smooth storing the student's own password on their own device, in Keychain, and entering it into Penn's own sign-in page is not "sharing with someone" in the literal sense, but a published app that handles the password is a third party in spirit; the Smooth team should get a written read from ISC/Information Security. This risk already exists for Canvas and is not increased by Path@Penn alone, but a degree-record feature raises the sensitivity of what a compromised session exposes.
- **Policy on Acceptable Use of Electronic Resources** (https://catalog.upenn.edu/pennbook/policy-acceptable-use-electronic-resources/, also Faculty Handbook V.H): overarching policy; violating the General Standards "may be subject to disciplinary action". Could not read the text for any clause about automated access or credential delegation.
- **Policy on the Confidentiality of Student Records** (Faculty Handbook IV.J, https://catalog.upenn.edu/faculty-handbook/iv/iv-j/; Almanac v56 n25): describes rights and responsibilities under FERPA; directory information may be released unless student opts out (name, addresses, phone, enrollment status). Questions: privacy@upenn.edu.
- **Screen scraping Penn systems:** no Penn statement found either way. [search summary only]
- **FERPA framing** (federal): students have the right to inspect and review their own education records; schools have the obligations (access, amend, limit disclosure without consent). From school FERPA pages consistent with 34 CFR 99.10-99.12 (not the ed.gov text, which was blocked; official source: https://studentprivacy.ed.gov). [search summary only] A student retrieving their own record via their own app is the student exercising access, not a school disclosure [inferred, standard reading]. But: FERPA does not create a right to use any technical channel (the school may require its own portal), does not override Penn's AUP/credential policy, and does not protect Smooth's own handling; if Smooth ever sends records to its servers, the team should treat them as sensitive student data (keep on-device, as with the password). Recommend legal review.

## Ranking [inferred]
1. B (student-provided PDF, on-device parse): safest, buildable now.
2. C (Canvas past courses): cheap, consistent with existing trust model, partial data; use for "courses taken".
3. A (Path@Penn session replay): richest data, but unverified endpoints, fragility, policy gray area, test device needed.
4. D (official access): ask, but expect catalog-only data.

## Sources
- https://advising.cis.upenn.edu/worksheet/ (search)
- https://www.college.upenn.edu/interpreting-degree-audit (search)
- https://apps.srfs.upenn.edu/secure/Pennant-Training/Students/Degree-Audit/Perform-a-Degree-Audit-in-PATH.pdf (search)
- https://srfs.upenn.edu/sites/default/files/publisher/Guide-to-Advising-at-Penn.pdf (search)
- https://www.courseleaf.com/insights/case-studies/upenn/ (search)
- https://srfs.upenn.edu/student-records/transcripts (search)
- https://www.isc.upenn.edu/node/4279 , /node/4292 (search)
- https://pennkeysupport.upenn.edu/node/16 ; https://almanac.upenn.edu/articles/sharing-your-pennkey-password-is-not-smart (search)
- https://catalog.upenn.edu/pennbook/policy-acceptable-use-electronic-resources/ (search)
- https://catalog.upenn.edu/faculty-handbook/iv/iv-j/ (search)
- https://github.com/pennlabs/registrar ; https://github.com/pennlabs/penn-courses (read)
- https://www.thedp.com/article/2013/10/penn-course-data-api ; /2021/09/penn-intouch-replacement-path-course-registration (search)
- https://pypi.org/project/PennSDK/0.1.1 (search)
- https://raw.githubusercontent.com/instructure/canvas-lms/master/app/controllers/courses_controller.rb ; .../enrollments_api_controller.rb (read)

## Blocked hosts (ENOTFOUND, not retried)
canvas.instructure.com (despite the brief saying allowed), studentprivacy.ed.gov, www.ed.gov, catalog.upenn.edu, www.thedp.com, www.ecampusnews.com, www.courseleaf.com, plus the *.upenn.edu hosts per brief. The session network allowlist would need to add canvas.instructure.com, ed.gov hosts and courseleaf.com for a re-check.

## Open questions
1. Is the Path@Penn audit Degree Works, and which endpoints does it call? Needs a signed-in browser inspection by a student/owner (not done here).
2. Does Path@Penn share the Canvas WebLogin session/Duo trusted-browser cookie, and what is its idle/absolute timeout?
3. Does Path@Penn offer audit print/PDF export, and what does the page look like for different schools?
4. Does Penn Labs' Degree Plan use registrar-provided requirement data, and could Smooth reuse the Penn Courses API?
5. Will ISC/Information Security or the Registrar give a written position on third-party apps holding a student's PennKey and reading Path@Penn?
6. Exact wording of the AUP and PennKey pages (only summaries seen).
