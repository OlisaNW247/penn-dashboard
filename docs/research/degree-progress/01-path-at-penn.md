# Path@Penn: what it offers students (research notes)

Date: 2026-11-09. Method: web search snippets only. No Penn page was fetched (all *.upenn.edu hosts are blocked here), and nothing was signed into. Every claim below is therefore [search summary only] or [inferred]; none is [read directly].

## Findings

1. The degree audit is a set of "worksheets": a requirements checklist, one per degree, second major or minor, found in the "Degree Audit" section of Path@Penn. [search summary only] https://advising.cis.upenn.edu/worksheet/

2. The Degree Audit section shows only worksheets for the student's currently declared programs. Other majors/degrees can be viewed under "Explore Programs", which shows how existing coursework maps to their requirements. This is functionally a what-if, but I found no official page that calls it "what-if". [search summary only] https://advising.cis.upenn.edu/worksheet/ ; https://apps.srfs.upenn.edu/secure/Pennant-Training/Students/Degree-Audit/Explore-Programs-in-PATH.pdf . A third-party page (aws-citrix.ungerboeck.com/pennpath) claims "what-if scenarios", but it looks like SEO filler, so treat it as unverified.

3. How a student runs an audit: from the Path@Penn page, click "Degree planning and audit" in the "Academic Planning and Registration" block, then the "Degree Audit" button; a drop-down switches between degrees. [search summary only] https://apps.srfs.upenn.edu/secure/Pennant-Training/Students/Degree-Audit/Perform-a-Degree-Audit-in-PATH.pdf ; https://www.college.upenn.edu/interpreting-degree-audit

4. What the audit shows: for College (Arts & Sciences) students, percentage bars for progress on each part of the degree; blocks can be opened to see individual courses and attributes. [search summary only] https://www.college.upenn.edu/interpreting-degree-audit ; Explore Programs PDF above.

5. Planner: a "Path Plans" tool lets students build potential schedules across future semesters, validate them against primary degree requirements, and save snapshots. It is reached via the "Primary Plan" button. The snippet gave no URL for the Penn page that says this; the Penn training PDF https://apps.srfs.upenn.edu/secure/Pennant-Training/Students/PATH-Planner/PATH-Creating-Plans.pdf exists. [search summary only]

6. Course search: Courses@Penn replaced Courses InTouch (May 2022); registration (advance registration, course selection) happens in Path@Penn. [search summary only] https://almanac.upenn.edu/articles/ngss-launch-of-pathpenn-and-advisingpenn ; https://srfs.upenn.edu/registration-catalog-calendar/course-registration

7. History: Path@Penn replaced Penn InTouch, launched 14 March 2022 with Advising@Penn, as part of NGSS (Next Generation Student Systems); runs from Student Registration & Financial Services. Pennant is the umbrella for the Banner-based student systems. [search summary only] https://almanac.upenn.edu/articles/ngss-launch-of-pathpenn-and-advisingpenn ; https://news.upenn.edu/news/pennant-student-accounts-records-financial-aid ; https://srfs.upenn.edu/path-at-penn

8. Platform, core: Penn chose Ellucian's Banner suite in 2014 (NGSS) to replace the legacy Student Records System. [search summary only] https://almanac.upenn.edu/archive/volumes/v60/n05/ngss.html . Penn's data-warehouse documentation references "Banner tables" (term-effective). [search summary only] https://provider.www.upenn.edu/computing/da/dw/pennant-student-records/st_degree_term.e.html

9. Platform, degree audit: the best evidence is a Penn job listing for a "Degree Planning and Audit Scribe" saying requirements will be set up in the "to-be-implemented Ellucian Degree Works product" during the Banner transition (c. 2020, undated listing). This is circumstantial and pre-launch. No source I found states that the live Path@Penn audit is Degree Works. No source mentions Stellic or uAchieve for Penn. Verdict: Banner is well supported; Degree Works for the audit is likely [inferred] but unconfirmed. Do not state it as fact. https://www.timeshighereducation.com/unijobs/listing/193750/degree-planning-and-audit-scribe/ [search summary only]

10. Sign-in: PennKey username/password via Penn WebLogin, then Duo two-step verification, is documented for Canvas at Penn (https://infocanvas.upenn.edu/canvas-login/ ; https://infocanvas.upenn.edu/two-step-verification-for-canvas/) [search summary only]. A 2019 DP article describes the same two-step requirement for Penn InTouch. For Path@Penn the PennKey login is described in news and SRFS snippets. That Path@Penn and Canvas share one identity provider is [inferred] from both using PennKey WebLogin; the SAML/Shibboleth detail and the hostname idp.pennkey.upenn.edu are not confirmed by any snippet. Session lifetime: no Penn source found.

11. Export, API, app: I found nothing on a PDF/print export of the audit, nothing on a student-facing JSON API, "Pennant data" for students, or an official Path@Penn mobile app. The old DP coverage says the new system is mobile-device compatible (a responsive web site, not an app). [search summary only; absence of evidence only] https://www.thedp.com/article/2022/03/path-at-penn-is-now-live . Whether the web UI is Banner/Degree Works self-service that calls JSON endpoints is [inferred] unknowable without signing in, which is out of scope.

12. Known limitations (official): the CIS advising page (last updated September 2022) says worksheets can omit courses that satisfy a requirement, list ones that do not, and auto-assign courses poorly (e.g. to free electives). It tells students the registrar's list is the definitive source and to work from that "until Path worksheets are more accurate". [search summary only] https://advising.cis.upenn.edu/worksheet/ . The CIS senior-audit page lists wrong graduation dates in Path as a cause of missing audit results. [search summary only] https://advising.cis.upenn.edu/senior-audit/ . Student press: usability complaints at launch. [search summary only] https://www.thedp.com/article/2022/04/path-at-penn-difficult-to-navigate-advance-registration-fall-2022

## Sources

- https://advising.cis.upenn.edu/worksheet/ : CIS worksheet page, scope, Explore Programs, accuracy warning (Sept 2022).
- https://advising.cis.upenn.edu/senior-audit/ : CIS senior audit common problems.
- https://www.college.upenn.edu/interpreting-degree-audit : College guide to reading the audit.
- https://apps.srfs.upenn.edu/secure/Pennant-Training/Students/Degree-Audit/Perform-a-Degree-Audit-in-PATH.pdf : SRFS how-to for running an audit.
- https://apps.srfs.upenn.edu/secure/Pennant-Training/Students/Degree-Audit/Explore-Programs-in-PATH.pdf : SRFS Explore Programs guide.
- https://apps.srfs.upenn.edu/secure/Pennant-Training/Students/PATH-Planner/PATH-Creating-Plans.pdf : SRFS planner guide.
- https://srfs.upenn.edu/path-at-penn : SRFS Path@Penn landing page.
- https://almanac.upenn.edu/articles/ngss-launch-of-pathpenn-and-advisingpenn : launch announcement.
- https://almanac.upenn.edu/archive/volumes/v60/n05/ngss.html : NGSS choosing Ellucian.
- https://news.upenn.edu/news/pennant-student-accounts-records-financial-aid : Pennant news.
- https://provider.www.upenn.edu/computing/da/dw/pennant-student-records/st_degree_term.e.html : data warehouse, Banner tables.
- https://www.timeshighereducation.com/unijobs/listing/193750/degree-planning-and-audit-scribe/ : job listing naming Degree Works.
- https://infocanvas.upenn.edu/canvas-login/ and /two-step-verification-for-canvas/ : Canvas PennKey + Duo.
- https://www.thedp.com/article/2022/03/path-at-penn-is-now-live ; https://www.thedp.com/article/2022/04/path-at-penn-difficult-to-navigate-advance-registration-fall-2022 : student press.

## Blocked hosts

All *.upenn.edu pages above were seen only as search snippets. Reading them directly would tell us: the exact audit/what-if menu labels and screenshots (the SRFS PDFs sit under /secure/, so may need a login anyway); whether any export or print option exists; the Path@Penn sign-in URL and IdP; session timeout; and any vendor name on SRFS/NGSS pages. thedp.com was blocked, so the 2025 DP items surfaced by search (a Path@Penn "AI chatbot" piece, Nov 2025, apparently an opinion column, and a Feb 2025 "releases new application" piece) were not read; I do not know what the latter describes.

## Open questions

- Is the live audit actually Ellucian Degree Works? Look for an NGSS/SRFS page, a Penn job posting for current Degree Works admins, or the page footer/URL pattern in the audit itself (needs a signed-in student).
- Is the CIS "worksheets are inaccurate" warning still current in late 2026?
- Does the audit offer print/PDF, and do the pages load data from JSON endpoints?
- What did the Feb 2025 DP "Path@Penn releases new application" article describe?
- Do Canvas and Path@Penn share the same IdP session (single sign-on), and how long does it last?
