# 06 - Beyond Penn: degree-audit landscape and portability

Researched 2026-11-09. Labels: [read directly] = I fetched the page or code; [search summary only] = only a search snippet/summary; [inferred] = my reasoning.
Most university hosts were not fetchable from this session (see Blocked hosts), so much is [search summary only]. The strongest primary evidence is GitHub code (topic 5).

## 1. Market: how common is Degree Works and what are the alternatives

**No authoritative Degree Works customer count exists in what I could reach.**
- Ellucian overall: "more than 2,900 customers in 50 countries, 22 million students" on its About page [search summary only] (ellucian.com/emea-ap/about-us). Older Ellucian blog says "over 2,500 institutions" [search summary only] (ellucian.com/blog/discover-why-over-2500-institutions-choose-ellucian). A 2015 WVNET newsletter says 2,400 institutions in 40 countries [search summary only]. These are whole-company counts (Banner, Colleague, etc.), not Degree Works.
- Degree Works specific: TrustRadius, citing HG Insights install data, lists ~695 installations (~78% education) [search summary only]. Datanyze tracks "199+" sites running Degree Works and "43+" for uAchieve [search summary only]; those count detected websites and undercount. AppsRunTheWorld has a "Ellucian Degree Audit & Planning" customer list (page not readable here) [search summary only].
- [inferred] Order of magnitude: several hundred US institutions on Degree Works, concentrated at Banner schools (data comes nightly from Banner per many campus pages, [search summary only]). Degree Works is the plausible #1 stand-alone audit product by count, but no source states a share.
- Ellucian is adding AI planning to Degree Works via its acquisition of EduNav's Smart Plan; U of Hawaii launches Degree Works Spring 2026 [search summary only] (hawaii.edu/its-banner/communications/degree-works/).

**Student information system (SIS) share, North America, Jan 2025 (ListedTech estimate):** Banner 24%, Colleague 11%, Jenzabar 11%, PeopleSoft 10%, Anthology 10%, Workday 3% [search summary only] (listedtech.com/blog/north-american-sis-highered-market-share-january-2025-update/). Banner+Colleague = 35%. A vendor page claims Banner at 1,400+ US institutions (ibl.ai; marketing) [search summary only].

**Alternatives**
- uAchieve / DARS (CollegeSource): "100+ colleges" use uAchieve Degree Audit per a CollegeSource press release (undated); whole CollegeSource line "2,000+" [search summary only]. Student app named "uAchieve Self-Service" (K-State calls it DARS; UC Davis, Oregon, Miami OH also) [search summary only] (k-state.edu/registrar/dars; ema.ucdavis.edu/uAchieve; status.uoregon.edu/service/degree-guide).
- Stellic: vendor claims 80+ universities (trade piece; marketing) [search summary only]. Started at CMU (signed June 2017, first customer; undergrad release Apr 2, 2018, replacing "Ironsoft") [search summary only] (cmu.edu/es/stellic/communications/2017-06-01.html). Newer adopters: Cornell (phased, replacing homegrown DUST; 7 colleges, institution-wide targeted by 2028), Columbia (College, SPS, Engineering), Johns Hopkins (project 2023), Delaware (live Dec 2024), Nebraska Omaha (moving from Degree Works by catalog year), Utah (modernization page) [search summary only] (it.cornell.edu/news/stellic-expands-seven-colleges-and-schools; info.stellic.jhu.edu; udel.edu/udaily/2024/december/stellic-goes-live; unomaha.edu/enterprise-systems/stellic). Trend: Stellic is taking share from Degree Works/homegrown at research universities [inferred].
- PeopleSoft/Oracle Academic Advisement: built-in "Advisement Report" is the audit; used at Pitt, Calgary, URI, Cal State campuses [search summary only] (docs.oracle.com/cd/G11181_01/cs92pbr35/eng/cs/lsaa/AcademicAdvisementReportsAtoZ-ab7ea3.html; registrar.pitt.edu).
- Workday Student: calls it "Academic Progress"/APR; 140+ customers (190+ institutions) signed, 85 live as of Oct 2025 (Workday press release) [search summary only] (newsroom.workday.com/2025-10-15-...). WashU, WPI, Suffolk use it.
- Homegrown: Cornell DUST (CALS, ~20 years, being replaced), Stanford Axess Degree Progress, Harvard AAR in my.harvard, Brown ASK, Yale (vendor-based), Dartmouth (DartWorks = Degree Works) [see table].
- EAB Navigate planner, Coursedog (has a Degree Works integration; its Course Demand Projections reads audit data, GET only, via Degree Works services APIs with a stateless token URL) [search summary only] (coursedog.com/integrations/ellucian-degreeworks). No share figures found for EAB or Coursedog planners.
- Catalog platforms (for topic 4): one report puts Modern Campus (Acalog) at 42%, CourseLeaf at 25%, Watermark 16%, Instructure 10% [search summary only, date/methodology unknown] (listedtech.com catalog-management article); Gartner page says CourseLeaf has 500+ institutions.

## 2. How schools expose audits to students

**Degree Works**
- Student UI: "Responsive Dashboard" SPA (replaced "Classic"; many schools retired Classic ~2018-2024) with Audit, What-If, Plans (planner), GPA calculators (Graduation/Term/Advice), and "Save as PDF" [search summary only] (e.g. wm.edu/offices/registrar/announcements/degreeworks-responsive-dashboard.php; aum.edu manual PDF). Audit is divided into blocks (Degree, Major, Minor, Concentration, Insufficient Grade, In-progress, Notes).
- URL pattern: `https://<host>/<instance>/responsiveDashboard/` (Arkansas State: dw-prod.ec.astate.edu/JBORO/responsiveDashboard/) [search summary only].
- **Back-end JSON, confirmed in working code** [read directly] (raw.githubusercontent.com/Aaryan-Kapoor/degreeworks-cli/main/src/degreeworks/config.py, client.py, auth.py; Kennesaw State):
  - `GET https://degreeworks.kennesaw.edu/api/audit` with query `studentId, school, degree, is-process-new=false, audit-type=AA, auditId=, include-inprogress=true, include-preregistered=true, aid-term=`; header `Accept: application/vnd.net.hedtech.degreeworks.dashboard.audit.v1+json`.
  - `GET /api/course-link?discipline=&number=` returns course info (prereqs, sections, schedules per README).
  - Referer used: `/worksheets/WEB31`. Auth: browser SSO login captured as cookies; `X-AUTH-TOKEN` is a JWT (about 90 min, `sub` = student ID) and a `REFRESH_TOKEN` (about 8 h) with `Bearer+` prefix.
  - So the path at KSU is `/api/...` not `/responsiveDashboard/api/...`; the exact prefix varies by deployment/version [inferred]. Parameters school/degree/audit-type are per-institution (e.g. school US, degree BS).
- SSO: Degree Works usually sits behind campus SSO (CAS, Shibboleth/SAML, or Entra, depending on school; UConn moved Shibboleth into CAS; Hartford routes via self-service portal) [search summary only]. KSU: SSO via real browser [read directly]. No Ellucian doc on SSO found.
- Documented student API: none found. Search for "Degree Works API" returned only user guides [search summary only]. Ellucian Ethos: no source shows Ethos exposing Degree Works audit; vendors (Coursedog) integrate through Degree Works' own services API instead [search summary only]. Ellucian developer docs host not reachable; Ethos coverage remains unconfirmed.

**Stellic**
- SSO: member of InCommon (Shibboleth), any SAML IdP (ADFS, Azure AD, Okta, Ping, Google), CAS, LDAPS (discouraged); loads no student data until SSO is configured; SSO attributes can drive roles [search summary only] (learn.stellic.com/integration-guide/integration-sso; host blocked here).
- Product has "Degree Progress and Audit" and planning views (learn.stellic.com/advisor-docs/student-profiles/degree-progress-and-audit) [search summary only]. Stellic's marketing "Under the Hood" page exists. No public student API or PDF-export documentation found; Cornell notes Stellic is not a replacement for PeopleSoft Campus Solutions (it reads SIS data) [search summary only]. I found no public GitHub client for Stellic (only unrelated repos named Stellic) [read directly, gh search].

**uAchieve**: "uAchieve Self-Service" web app, audit shown as HTML with printable/PDF output; Miami OH and K-State have support guides [search summary only] (support.ksu.edu/TDClient/30/Portal/KB/ArticleDet?ID=1151). No API found. Older versions were Java/DARS-style; web-based at e.g. ASA fully implemented Aug 2018 [search summary only].

**PeopleSoft / Workday**: student-initiated "Advisement Report" (PS) and "Academic Progress" (Workday) inside the SIS; HTML/PDF only for students [search summary only]; no public student APIs found.

## 3. Peer schools

| School | Audit system | Evidence |
|---|---|---|
| Harvard | Academic Advising Report (AAR) + What If? report, inside my.harvard (PeopleSoft-based, not Degree Works) | [search summary only] registrar.fas.harvard.edu/academic-advising-report-aar |
| Yale | "Yale Degree Audit" (block-based, rolled out ~2011-12 after pilot at Berkeley/Morse colleges; interface refresh 2023; vendor not stated in snippets, "blocks" wording suggests Degree Works) | [search summary only] registrar.yale.edu/degree-audit-faqs; yaledailynews.com 2011 piece. Vendor [inferred] |
| Princeton | TigerHub (PeopleSoft Campus Solutions); no public degree-progress page found | [search summary only] |
| Columbia | Stellic (Columbia College, Engineering, SPS, used for graduation clearance); start date not found | [search summary only] sishelp.sis.columbia.edu/content/stellic-degree-audit-resources-arts-and-sciences-departments |
| Cornell | Moving from homegrown DUST (CALS) to Stellic, phased; 7 colleges by 2025 news, institution-wide target 2028 | [search summary only] it.cornell.edu/news/stellic-expands-seven-colleges-and-schools |
| Brown | ASK (Advising Sidekick) "Degree Progress" tab: concentration declarations and course plans; no classic audit found | [search summary only] ithelp.brown.edu advisors working with concentration declarations |
| Dartmouth | DartWorks Degree Audit = Degree Works, via DartHub (previously Banner Student menu); started 2011 | [search summary only] registrar.dartmouth.edu/students/systems-tools-forms/dartworks/dartworks-degree-audit |
| Stanford | Axess "Degree Progress" report (GER/writing/language; older critique) and Carta (course planning/exploration); homegrown/PeopleSoft | [search summary only] studentservices.stanford.edu/my-academics/earn-my-degree/undergraduate-degree-progress; news.stanford.edu/stories/2020/10/carta-transition-outlined |
| MIT | No current student audit page confirmed; WebSIS and registrar "undergraduate degree requirements"; MIT is enhancing student systems | [search summary only] unreliable |
| CMU | Stellic (first customer, 2017-18), replaced Ironsoft audit | [search summary only] cmu.edu/es/stellic |
| Others seen | UT Austin "UT Direct" audit (browser extension exists); Northeastern (graduatenu); Johns Hopkins, Delaware, Chicago (Stellic); UC Davis, Kansas State, Oregon (uAchieve) | see topic 5 / above |

Peer set is fragmented: at least 3 Stellic, 1-2 Degree Works, 2-3 PeopleSoft-based, 2 homegrown. [inferred] No single integration covers Penn's peers.

## 4. Portable vs Penn-specific

**What a "Penn-first" design assumes** (requirements from public catalog + student-marked courses + public course API for prereqs/offerings). Penn side not verified by me (all *.upenn.edu blocked); other agents cover it.

**Portable [inferred unless noted]**
- Core engine: requirement tree (all-of / n-of / credit buckets / attribute rules), course status (taken, in progress, planned), prerequisite graph, "what's remaining" and next-term offerings. Model is school-agnostic.
- Catalogs mostly come from Modern Campus Acalog, Leepfrog CourseLeaf, Coursedog, or school-built sites [search summary only]; requirement text is semi-structured HTML/print, no standard schema. Parsing per school; AI/LLM-assisted extraction plus human review is the realistic route. I found no public XML/API doc for CourseLeaf or Acalog (not verified; vendor docs may require login).
- Student-marked courses and a self-serve planner avoid any SSO integration, so they port to any school without school cooperation.
- Canvas link: Smooth already works with Canvas at 220 schools (from the brief); Canvas course lists could seed "taken" courses [inferred].

**Penn-specific (or per-school)**
- The requirement encoding itself (every school's programs, catalog-year rules, double-counting policies).
- Course API: Penn's source; each school has its own codes, term codes, cross-listing, prerequisite syntax.
- Audit ingestion (if ever): vendor and SSO differ. A Degree Works reader is portable across Degree Works schools only partly (school/degree/audit-type parameters vary; URL prefix varies) and does nothing for Stellic/uAchieve/PeopleSoft/Workday [inferred from topic 5 code].
- Server-side features are Penn-only today (from the brief), so portability would need per-school data pipelines.

**Near-copy candidates (public catalog + public/near-public course API)**
1. **University of Illinois Urbana-Champaign**: Course Explorer with a supported XML/REST API (Technology Services supports "Course Explorer web application and API"); wrappers exist on PyPI (`uiuc-api`) and npm (`uiuc`) [search summary only] (help.uillinois.edu ServiceDet?ID=554; pypi.org/project/uiuc-api). Auth requirement for API not confirmed. Catalog is public.
2. **University of Waterloo**: Open Data API v3 (openapi.data.uwaterloo.ca) with a Courses endpoint by term/subject/catalog number; free, key required; public catalog [search summary only] (uwaterloo.ca/api; uwaterloo.atlassian.net UWAPI). Canadian; the "220 US universities" Canvas base is US, so lower priority [inferred].
3. **Berkeley / UCLA**: official APIs exist but need keys/OAuth (Berkeley SIS API app_id/app_key; UCLA developer portal OAuth); Berkeleytime is an open-source student project wrapping Berkeley data [search summary only] (docs.berkeleytime.com; developer.api.ucla.edu/api-catalog). Moderate difficulty: keyed, but student-project precedent. Berkeley's public Academic Guide is the catalog.
4. UW (Seattle): official Student Web Service API not verified (not searched); skip until checked.
5. Northeastern: sandboxnu/graduatenu is a student project that models degree requirements and schedules [read directly: README; data source not stated] (github.com/sandboxnu/graduatenu).
Ranking by ease [inferred]: UIUC > Berkeley (open-source precedent) > UCLA > Waterloo.

## 5. Precedent: third-party/student apps reading audits

All [read directly] from GitHub unless noted.
- **degreeworks-cli** (Aaryan-Kapoor, KSU, updated Oct 2026): read-only Python CLI + Claude Code skill; `dw login` opens a browser for KSU SSO, captures cookies; calls `/api/audit` and `/api/course-link`; builds schedules from audit + sections. Disclaimer: not affiliated with Ellucian/KSU; GET only. README footnote says KSU advisors approved plans made with it without being told they were AI-generated. Does not discuss KSU terms/policy. (github.com/Aaryan-Kapoor/degreeworks-cli, 5 stars)
- **Degreeworks-Scraper** (justcare21, Morgan State): Android WebView captures page HTML after the student logs in and posts it to a FastAPI server that parses GPA/courses/remaining requirements for a chatbot. (Dec 2025)
- **Degree-Audit-Plus** (Longhorn-Developers, UT Austin, MIT license): browser extension (WXT, Chromium/Firefox) that parses the UT Direct audit page into a dashboard/planner; detects expired sessions, can run a new audit; "not affiliated with or endorsed by UT". 17 stars, active Oct 2026.
- Others (descriptions only, code not read): Degreeworks_helper (CUNY web app), DegreeActuallyWorks (Georgia Tech), CypherVII-Schedule-Advisor, DegreeWorksAutomator (console script injection, 2019), degreeWorksAuditChecker (staff script, 2017), via `gh search repos`.
- Pattern [inferred]: three approaches: (a) session-cookie API client, (b) in-page browser extension, (c) HTML capture in a WebView. All are student-run, local-first, with the student's own login; none is a commercial product, none documents a school response.
- School reactions: I found no case of a school supporting, tolerating, or blocking a Degree Works/Stellic audit reader specifically [search summary only]. Closest policy analogues: Buffalo, Brown, Georgia Tech, Georgia State prohibit scripts/bots for registration (Banner) under acceptable-use/conduct policies with sanctions (lost registration access, discipline); Chicago warned students about add/drop scripts [search summary only] (registrar.buffalo.edu/registration/policies/automated-process.php; registrar.gatech.edu/node/41). These target registration load, not read-only audit pulls; whether they reach audit access is [inferred] unclear. An Emory library notice treats scraping from student accounts as a violation (PitchBook, different product). Degree Works access is described as restricted to authorized users on campus pages. Risk for a commercial app holding student SSO sessions is higher than for personal tools [inferred].
- Vendor-sanctioned path: Coursedog reads Degree Works via school-granted services API [search summary only]; that route requires the school.

## Sources
- https://ellucian.com/blog/discover-why-over-2500-institutions-choose-ellucian
- https://Ellucian.com/emea-ap/about-us
- https://www.appsruntheworld.com/customers-database/products/view/ellucian-degree-audit-planning
- https://tr-web.dev.trustradius.com/products/ellucian-degree-works/reviews
- https://www.datanyze.com/market-share/other-vertical-industries-software--437/ellucian-degree-works-market-share
- https://www.datanyze.com/market-share/education-management--78/collegesource-uachieve-market-share
- https://listedtech.com/blog/north-american-sis-highered-market-share-january-2025-update/
- https://ibl.ai/resources/comparisons/banner-vs-peoplesoft.md
- https://newsroom.workday.com/2025-10-15-Workdays-Higher-Education-Momentum-Accelerates-as-Over-650-Institutions-Worldwide-Turn-to-AI-to-Navigate-Uncertainty-and-Transform-the-Student-Experience
- https://www.hawaii.edu/its-banner/communications/degree-works/
- https://coursedog.com/integrations/ellucian-degreeworks
- https://learn.stellic.com/integration-guide/integration-sso
- https://www.cmu.edu/es/stellic/communications/2017-06-01.html
- https://it.cornell.edu/news/stellic-expands-seven-colleges-and-schools
- https://sishelp.sis.columbia.edu/content/stellic-degree-audit-resources-arts-and-sciences-departments
- https://www.udel.edu/udaily/2024/december/stellic-goes-live
- https://unomaha.edu/enterprise-systems/stellic
- https://www.k-state.edu/registrar/dars ; https://support.ksu.edu/TDClient/30/Portal/KB/ArticleDet?ID=1151
- https://docs.oracle.com/cd/G11181_01/cs92pbr35/eng/cs/lsaa/AcademicAdvisementReportsAtoZ-ab7ea3.html
- https://wm.edu/offices/registrar/announcements/degreeworks-responsive-dashboard.php
- https://registrar.yale.edu/degree-audit-faqs
- https://registrar.fas.harvard.edu/academic-advising-report-aar
- https://registrar.dartmouth.edu/students/systems-tools-forms/dartworks/dartworks-degree-audit
- https://studentservices.stanford.edu/my-academics/earn-my-degree/undergraduate-degree-progress
- https://github.com/Aaryan-Kapoor/degreeworks-cli (config.py, client.py, auth.py read via raw.githubusercontent.com)
- https://github.com/justcare21/Degreeworks-Scraper
- https://github.com/Longhorn-Developers/Degree-Audit-Plus
- https://github.com/sandboxnu/graduatenu
- https://registrar.buffalo.edu/registration/policies/automated-process.php ; https://registrar.gatech.edu/node/41
- https://uwaterloo.ca/api/ ; https://docs.berkeleytime.com/core/packages/sis-api.html ; https://developer.api.ucla.edu/api-catalog ; https://pypi.org/project/uiuc-api/

## Blocked hosts
ENOTFOUND on fetch (not retried): coursedog.freshdesk.com, learn.stellic.com, yaledailynews.com, it.cornell.edu, listedtech.com, www.ellucian.com, www.appsruntheworld.com, help.uillinois.edu, www.cmu.edu, registrar.dartmouth.edu. `gh api` on third-party repos returned 403 (use WebFetch/raw.githubusercontent.com instead). Pre-listed blocked: *.upenn.edu etc. not contacted.

## Open questions
1. Exact Degree Works JSON path prefix and payload shape across versions (`/api/audit` at KSU vs `/responsiveDashboard/api/...`); capture audit JSON schema from the CLI's tests/dump command.
2. Does Ellucian Ethos or the Degree Works "Services API" expose audits to students? Needs Ellucian docs access.
3. Stellic and uAchieve student-side endpoints, PDF export, and any API (needs vendor docs or a logged-in session).
4. Real Degree Works, Stellic, uAchieve institution counts (ask vendors; AACRAO/EDUCAUSE surveys).
5. Yale vendor, Columbia Stellic start date, MIT and Princeton current audit tools.
6. UIUC and UW API access terms; whether CourseLeaf/Acalog offer public export.
7. Whether any school has enforced against audit-reading tools; check each target school's acceptable-use policy and ask registrars.
