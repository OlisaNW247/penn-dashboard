# McGraw Hill Connect and ALEKS: student-side technical surface

Research limits, read first: in this session WebFetch could not resolve any host outside a small allow-list (mheducation.com, apps.apple.com, chromeboard.com, elearning.ufl.edu all failed with ENOTFOUND). Everything below therefore rests on WebSearch result summaries and on GitHub code-search fragments (via `gh api search/code`, which returned file text but could not open whole repos). No McGraw Hill page was read in full, and no live endpoint was probed. Items are labeled DOCUMENTED (vendor/school page, as summarized by search), OBSERVED-BY-THIRD-PARTY (code in a public repo, which is one author's claim), or INFERRED (mine).

## 1. How do students sign in to Connect and ALEKS? (accounts, Canvas LTI, SSO, MFA, identity platform)

### Takeaway
Two paths exist. Most college students reach Connect and ALEKS through the Canvas LTI 1.3 ("LTI Advantage") launch, which needs a one-time pairing of the Canvas course to a McGraw Hill account (create or sign in), after which Canvas launches go straight in. A student can also sign in directly with a McGraw Hill email/password (browser code shows `accounts.mheducation.com`; the PreK-12 portal is `my.mheducation.com`). I found no documentation of institutional "sign in with" SSO, MFA, or the identity vendor.

### Cited Findings
- Connect via Canvas: the student opens the Connect link in the Canvas course (navigation or an assignment link), then creates an account or signs in with an existing one. A school email that matches an existing account prompts login to that account. After choosing a registration option (access code, purchase, etc.) the student clicks "Complete Registration," which finishes the Canvas-to-Connect "single sign-on pairing"; the student returns to Canvas to start assignments. DOCUMENTED (search summary) — [McGraw Hill: how to pair an account in Canvas as a student](https://www.mheducation.com/highered/support/knowledge/connect-how-to-pair-an-account-in-canvas-as-a-student.html); see also [Connect student registration, LTI Advantage](https://www.mheducation.com/highered/support/knowledge/connect-student-registration-lti-advantage)
- Schools describe two integration generations: older LTI 1.1 and the LTI Advantage (1.3) integration; one school says students who used Connect before Fall 2023 follow separate pairing instructions. Another warns one Connect course should map to only one Canvas course shell. DOCUMENTED — [UFL McGraw Hill Connect page](https://lss.at.ufl.edu/instructor-help/teaching-and-learning-tools/tool-finder/items/mcgraw-hill-connect.html), [Rutgers McGraw Hill Campus page](https://canvas.rutgers.edu/external-apps/mcgraw-hill-campus/), [SPU LTI 1.3 note](https://spu.atlassian.net/wiki/x/fJ8tAg)
- Direct sign-in for PreK-12 student accounts is at `my.mheducation.com` with username and password (case-sensitive password); a "Simplified Login" short-code variant exists for younger students. DOCUMENTED — [Access Your McGraw Hill Student Account](https://www.mheducation.com/prek-12/support/knowledge/my-mheducation-com-student-login.html), [Simplified Login](https://www.mheducation.com/prek-12/support/knowledge/my-mheducation-com-student-simplified-login.html). This is the PreK-12 portal; the college-level Connect login host below differs.
- The college Connect login URL seen in public code is `https://accounts.mheducation.com/login?app=connect.mheducation.com&redirectUrl=https://caas.mheducation.com/caas/heclr/launchConnect`. OBSERVED-BY-THIRD-PARTY (a Playwright script that logs in with env-var credentials; two other repos in the answer-automation category use the same URL, not described further here) — [ignuslabs/OpsResearch automated_collector.js](https://github.com/ignuslabs/OpsResearch/blob/main/automated_collector.js). Another McGraw Hill link on a public page uses `https://accounts.mheducation.com/mg/auth?app=access…` for MH Medical, so `accounts.mheducation.com` is the shared account host across McGraw Hill products (INFERRED from two examples).
- Connect has a student "new Connect" app host, `newconnect.mheducation.com` (todo route `/student/todo`). The LTI launch from Canvas opens `newconnect.mheducation.com/student/todo` in a new tab (iframe says "Your Connect assignment has been launched in a new tab") plus an `sso.router.integration.prod.mheducation.com/app/#/connect/coversheet` page; SmartBook itself runs at `learning.mheducation.com/static/awd/index.html`. OBSERVED-BY-THIRD-PARTY (field notes in an automation repo with a live 2026 run; the repo is an answer-automation project, cited only for URL routing) — [hcswint7/Muse-Spark-Python SMARTBOOK_AUTOMATION_GUIDE.md](https://github.com/hcswint7/Muse-Spark-Python/blob/main/docs/browser_skills/SMARTBOOK_AUTOMATION_GUIDE.md)
- ALEKS via Canvas: the ALEKS tool is in course navigation (not enabled by default). A student with an existing ALEKS login picks "Yes, I want to use my existing ALEKS account" and enters ALEKS login name and password to link; a new student needs a class code (10 characters) and may enter a 20-character access code or buy one. Afterwards the Canvas link returns the student to ALEKS without credentials. Some schools instead have students register at `aleks.com` ("Sign Up Now"). DOCUMENTED — [McGraw Hill ALEKS Canvas LTIA access-code guide (PDF)](https://www.mheducation.com/content/dam/mhe/highered/documents/support/aleks/student/canvas-ltia-access-code-new.pdf), [Rutgers ALEKS in Canvas](https://canvas.rutgers.edu/documentation/external-apps/aleks-getting-started-for-instructors/), [UNM](https://canvasinfo.unm.edu/external-apps/instructor/aleks-instructor/how-to-enable-aleks-and-pair-your-course-in-canvas.html)
- ALEKS login page is `https://www.aleks.com/login`; McGraw Hill login target used by a community extension is `https://my.mheducation.com/login/` (i.e. ALEKS accounts and McGraw Hill accounts are separate login targets). OBSERVED-BY-THIRD-PARTY — [LaganYT/InterALEKS content.js](https://github.com/LaganYT/InterALEKS/blob/main/content.js)
- MFA: McGraw Hill's official student sign-in pages surfaced no mention of MFA; two third-party "login guide" sites claim optional two-step verification. Treat as unverified. — [legalunitedstates.com guide](https://legalunitedstates.com/mcgraw-hill-login/) (low-quality aggregator)

### Inferences
- A student whose Canvas course uses LTI 1.3 can launch Connect/ALEKS without ever typing a McGraw Hill password in the Canvas flow after pairing (INFERRED from "single sign-on pairing" wording). Smooth can therefore not assume a stored McGraw Hill credential exists, and a Canvas-only session would need to perform the LTI launch (the Ed pattern) to mint a Connect session.
- The login host `accounts.mheducation.com` is a different origin from `newconnect.mheducation.com`; the redirect through `caas.mheducation.com/caas/heclr/launchConnect` hints at a central auth service ("caas" plausibly "credentials/authentication as a service"; INFERRED, unconfirmed).

### Gaps
- Which identity platform (Okta, Auth0, ForgeRock, other) sits behind `accounts.mheducation.com`: not found. `login.mheducation.com` as a hostname was not confirmed by any source (GitHub code search returned nothing for it).
- Whether MFA exists for college student accounts, and whether any institution-level "Sign in with" SSO (SAML/Google/Microsoft) exists for Connect: no official source found.
- Could not read the McGraw Hill support articles in full (fetch blocked); details above are from search-engine summaries.

## 2. Connect student web-app architecture and endpoints

### Takeaway
The new Connect student app at `newconnect.mheducation.com` is a single-page-style app with a `/student/todo` assignment list, backed by a JSON assignments API that needs a short-lived bearer JWT minted from a long-lived session cookie. One third-party repo (a personal planner project) documents this two-layer auth and claims it works against live Connect (verified 2026-08-25). The exact assignments endpoint path and JSON field names could not be retrieved.

### Cited Findings
- Per the source comment in a student-planner project's Connect connector: "Auth is two-layer: the long-lived ERIGHTS cookie mints a 5-minute MH_TOKEN JWT via POST /caas/heclr/coire/refreshToken; the assignments API wants that JWT as a Bearer header plus the person_xid from its payload. Refresh and fetch therefore happen inside one pull() - a pasted token is always already dead. Endpoints verified live 2026-08-25." The connector's base is `https://newconnect.mheducation.com`; its `_refresh` returns `(bearer_token, person_xid)`, decodes the JWT payload (base64/json), and raises LoginRequired if the ERIGHTS session can no longer mint tokens. OBSERVED-BY-THIRD-PARTY — [mrsoftskin/schoolhub src/brain/connectors/sites.py](https://github.com/mrsoftskin/schoolhub/blob/main/src/brain/connectors/sites.py) (read as code-search fragments; the full file was not opened)
- The same project tells users to open `https://newconnect.mheducation.com/student/todo`, find the "todo request" in DevTools Network, and copy the cURL; "The ERIGHTS cookie is the one that matters." Its cookie set for a host named `connect.mheducation.com` in a test includes `MHSession`, which suggests older/other cookie names (test fixture, may be synthetic). OBSERVED-BY-THIRD-PARTY — [schoolhub sites.py (login_hint)](https://github.com/mrsoftskin/schoolhub/blob/main/src/brain/connectors/sites.py), [tests/test_sync.py](https://github.com/mrsoftskin/schoolhub/blob/main/tests/test_sync.py)
- The connector applies a "rolling window" to Connect items so far-future/past items stay out of the calendar, and the project's browser extension reads cookies for `newconnect.mheducation.com` and `.mheducation.com`, pushing them to a local app. It parses due dates as ISO timestamps with `Z`, converted to the user's timezone (a `due.replace("Z", "+00:00")` fragment). OBSERVED-BY-THIRD-PARTY — [schoolhub browser-extension/background.js](https://github.com/mrsoftskin/schoolhub/blob/main/browser-extension/background.js), [manifest.json](https://github.com/mrsoftskin/schoolhub/blob/main/browser-extension/manifest.json)
- Student-facing documentation of the To Do and calendar: Assignments menu includes a To Do list of work due in the next 48 hours plus a calendar showing due dates by day/week/month with color coding; the assignment panel shows start/end date, points, attempts allowed. DOCUMENTED but 2019–2023 guides, not the current redesign — [2021 Student Guide to Using Connect and SmartBook](https://info.mheducation.com/rs/128-SJW-347/images/2021_Student_Guide_to_Using_Connect_and_SmartBook.pdf), [2023 Student Guide to SmartBook](https://info.mheducation.com/rs/128-SJW-347/images/2023_Student_Guide_to_SmartBook.pdf), [Connect: Getting to Know Connect (students)](https://www.mheducation.com/highered/support/knowledge/connect-getting-to-know-connect-for-students.html)
- Connect uses several hosts in a launch: `newconnect.mheducation.com` (dashboard/todo), `sso.router.integration.prod.mheducation.com` (coversheet, post-LTI), `learning.mheducation.com` (SmartBook player), `caas.mheducation.com` (auth/launch). OBSERVED-BY-THIRD-PARTY — [Muse-Spark guide](https://github.com/hcswint7/Muse-Spark-Python/blob/main/docs/browser_skills/SMARTBOOK_AUTOMATION_GUIDE.md), [OpsResearch](https://github.com/ignuslabs/OpsResearch/blob/main/automated_collector.js)
- Public tracker/analytics lists show Connect pages load third-party tooling such as Pendo, New Relic and reCAPTCHA (domain-level tracker catalog entries found in a code search; not verified against newconnect specifically). — [duckduckgo/tracker-radar entries returned for pendo.io / newrelic.com / recaptcha.net](https://github.com/duckduckgo/tracker-radar) (weak evidence)

### Inferences
- The `ERIGHTS` cookie plus a 5-minute JWT is a pattern Smooth could replicate in principle: WKWebView login (or LTI launch) -> save cookies -> POST refreshToken -> call assignments API. But the claim rests on one hobby repo; it should be re-verified against a real account before any design depends on it.
- The "5-minute JWT" means Smooth would need a token mint on every poll; this is similar to the Ed token flow, but cookie-to-token minting happens server-side rather than from localStorage (INFERRED).
- Cookies are set on `.mheducation.com` (the extension subscribes to that parent domain), which suggests WKWebView can capture them with `WKHTTPCookieStore` like Canvas (INFERRED).

### Gaps
- The assignments endpoint path, query params, and JSON schema (names for title, due date, status, score) were not recoverable; the search tool returns only matching fragments, and the repo itself was not readable in this session (GitHub access to that repo is not enabled for the session). A next step with working GitHub/Chrome access: read `sites.py`'s `ConnectConnector.pull()` and `parse()` directly.
- No Stack Overflow, Reddit or blog write-up of Connect's internal API was found in the (limited) search.
- ALEKS-style quiz/homework state and SmartBook progress representation in the API: unknown.

## 3. ALEKS student web app: login, assignments page, endpoints

### Takeaway
ALEKS is a separate, older product with its own login (`www.aleks.com/login`, ALEKS login name + password, class code). Its student Assignments page is a server-rendered/legacy-style table (type, start date, due date, score, details). I found no endpoint documentation or scraper for it.

### Cited Findings
- Student Assignments view: assignments are listed in a table with type, start date, due date, score and details, sorted by due date; instructors can grant student-specific extensions via an "Exceptions" tool, so student dates can differ from class dates. DOCUMENTED (search summary) — [ALEKS: Accessing ALEKS Assignments](https://www.mheducation.com/support/aleks-support-center/knowledge/aleks-assignments-student-view.html), [Ask an ALEKS Implementation Manager on extensions and exceptions (Apr 2026)](https://www.mheducation.com/highered/blog/2026/04/ask-an-aleks-implementation-manager-josef-torres-on-extensions-and-exceptions.html)
- In Canvas-integrated ALEKS courses, instructors can set start/due/final-submission dates in Canvas, and ALEKS gradebook sync to Canvas is optional. DOCUMENTED — [Liberty/McGraw Hill ALEKS date-editing PDF](https://www.mheducation.com/unitas/school/explore/sites/liberty/chba/luo-chba-edit-dates.pdf), [ALEKS Canvas page](https://www.mheducation.com/highered/explore/liberty/aleks-canvas.html)
- Respondus LockDown Browser is supported for ALEKS (including Chromebooks), i.e. instructors can lock down proctored ALEKS assessments. DOCUMENTED — [ALEKS: Respondus LockDown Browser for Chromebooks](https://www.mheducation.com/support/aleks-support-center/knowledge/respondus-lockdown-browser-now-available-for-aleks-on-chromebooks)
- ALEKS privacy policy snapshot (2019) exists in a public archive of policies; no technical endpoint content. — [citp/privacy-policy-historical aleks.com.md](https://github.com/citp/privacy-policy-historical)

### Inferences
- Because the Assignments table has per-student due dates (Exceptions), any calendar feed from Canvas would show class dates, not the student's; reading ALEKS directly would be the only way to get the student's true due date (INFERRED).

### Gaps
- No ALEKS endpoint names, no JSON API evidence, no scraper repo found (GitHub searches "aleks scraper", "aleks.com assignments" returned nothing relevant). Whether the ALEKS student page is HTML or XHR/JSON is unknown.
- Session lifetime and cookie names for ALEKS: unknown.

## 4. Official API, developer program, partner API, calendar export

### Takeaway
I found no public student-facing API, developer program, or ICS/iCal export for Connect or ALEKS. The official integration surface is institutional: LTI 1.3 (Advantage) for launch and grade passback to the LMS.

### Cited Findings
- No mention of an API or data export in McGraw Hill's Connect assignments/exams support library or student guides found; searches for an official calendar subscribe/export in Connect or ALEKS returned nothing. DOCUMENTED absence only in the sense that search found none — [Connect assignments and exams resources](https://www.mheducation.ca/higher-education/learning-solutions/support-implementation/connect/assignments-exams)
- McGraw Hill's published integration is LTI Advantage 1.3 with grade sync to LMS gradebooks (Canvas, Blackboard, D2L); a Google Workspace Marketplace add-on "ALEKS2Canvas Gradebook" exists as a third-party instructor tool for moving ALEKS gradebook to Canvas. DOCUMENTED / third-party — [UCLA McGraw Hill page](https://dts.ucla.edu/initiatives/bruin-learn-center-excellence/academic-tech-tools/mcgraw-hill), [ALEKS2Canvas add-on](https://workspace.google.com/marketplace/app/aleks2canvas_gradebook/395204078880)
- Connect has an in-app Calendar view for students (day/week/month); a Ramapo document about "linking a Connect calendar with Google Calendar" is for Ramapo's own campus portal "Connect", not McGraw Hill (INFERRED from the URL path `ramapo.edu/connect`) — [Ramapo PDF](https://www.ramapo.edu/connect/wp-content/uploads/sites/248/2022/10/Link-a-Connect-Calendar-with-a-Google-Calendar-Fa22.pdf)
- The 1EdTech ReadAnywhere document indicates standards-based LTI integration of McGraw Hill products, not an API for students. — [1EdTech ReadAnywhere PDF](https://www.1edtech.org/sites/default/files/media/docs/2024/ReadAnywhere.pdf)

### Inferences
- The only sanctioned per-student due-date path may be Canvas itself: when an instructor links a Connect assignment into Canvas (LTI deep link), the Canvas assignment and its due date appear in the Canvas calendar feed that Smooth already reads (INFERRED; depends on school/instructor setup, and the ALEKS "Exceptions" caveat above). This could cover a large fraction of Connect usage with no McGraw Hill integration at all.

### Gaps
- Could not confirm LTI deep-link/grade-passback behavior in detail or whether Connect-linked Canvas assignments carry accurate due dates and submitted status in Canvas (needs a real Canvas course).
- No evidence either way on an undocumented or partner API (McGraw Hill "developer portal"): search returned nothing.

## 5. McGraw Hill mobile apps

### Takeaway
The student mobile app for Connect content is "ReadAnywhere" (iOS App Store id 1237370775), focused on offline eBook and SmartBook reading/assignments. I found no evidence it lists assignment due dates or sends due-date push notifications.

### Cited Findings
- ReadAnywhere lets students download eBook chapters and SmartBook 2.0 assignments for offline work, with later sync; sign-in uses McGraw Hill credentials; available on iOS. DOCUMENTED (search summary) — [McGraw Hill ReadAnywhere page](https://www.mheducation.com/readanywhere.html), [Read Anywhere App article](https://www.mheducation.com/highered/ideas/study-tips/read-anywhere-app-3), [App Store listing](https://apps.apple.com/us/app/-/id1237370775) (not opened)
- A GO guide states GO assignments are not supported in ReadAnywhere, only GO eBooks (that is the McGraw Hill GO product). DOCUMENTED — [GO Canvas student guide](https://www.mheducation.com/content/dam/mhe/highered/documents/support/go/canvas-student-guide.pdf)
- A 2015 article says the Connect mobile dashboard listed upcoming assignments and tests (historical). — [EdSurge 2015](https://www.edsurge.com/n/2015-03-10-connect-goes-mobile-for-nontraditional-learners)
- App Store privacy label for ReadAnywhere in at least one regional listing: Usage Data and Diagnostics, not linked to identity. Separate: a 2024 class action alleged McGraw Hill's Sharpen app shared user data with third parties (not ReadAnywhere). — [App Store listing (regional)](https://apps.apple.com/ag/app/readanywhere/id1237370775), [Bloomberg Law](https://news.bloomberglaw.com/litigation/mcgraw-hill-app-user-data-disclosed-to-third-parties-suit-says)

### Inferences
- Because the only phone surface is an eBook/SmartBook reader, students likely rely on the web To Do page or LMS for due dates; a Smooth to-do feed would be a real gap-filler (INFERRED).

### Gaps
- Mobile app backend hostnames, whether the app shows a To Do list, and push notifications: not found (App Store and McGraw Hill pages could not be fetched; no traffic analysis found). ALEKS has no separate mobile app that I found (not confirmed either way).

## 6. Precedents: open source, extensions, planner apps, takedowns

### Takeaway
Reading Connect assignments (not answers) has at least one working open-source precedent (a personal "schoolhub" planner with browser extension and server-side connector) and a Discord bot; no commercial planner with documented McGraw Hill sync and no legal letters or shutdowns were found. Answer-automation tools are abundant, which shapes McGraw Hill's posture.

### Cited Findings
- schoolhub (mrsoftskin): personal school-hub app whose browser extension (MV3, host permission `https://*.mheducation.com/*`) harvests cookies for Connect and pushes them to a local server; the server mints the 5-min token and pulls assignments into a unified deadline calendar. Small hobby project; its notes say endpoints were verified live 2026-08-25. OBSERVED-BY-THIRD-PARTY — [schoolhub extension README](https://github.com/mrsoftskin/schoolhub/blob/main/browser-extension/README.md), [sites.py](https://github.com/mrsoftskin/schoolhub/blob/main/src/brain/connectors/sites.py)
- whostinlon/connect-bot: "A discord bot made to check McGraw Hill Connect and retrieve assignments" (1 star, last push 2022-04-11; historical, probably stale). — [GitHub search result](https://github.com/whostinlon/connect-bot) (repo contents not readable here)
- InterALEKS (LaganYT): MV3 extension for ALEKS adding Enter-key actions, redirects and settings; permissions `storage`; host access to `*.aleks.com` and `*.mheducation.com`; version 2025.10.08. It does not read assignments. Chrome Web Store listing reportedly ~310 users. — [InterALEKS manifest.json](https://github.com/LaganYT/InterALEKS/blob/main/manifest.json), [chromeboard listing](https://chromeboard.com/extension/interaleks-obfahomodlignbjbgmajolpjicingedm)
- A multi-LMS "homework notifier" in a tutoring-business repo lists `mheducation.com` among sites its tool recognizes. OBSERVED — [jiujiastudy cc_external.py](https://github.com/jiujiastudy/jiujiastudy/blob/main/tools/cc_external.py) (weak; no detail on how it reads it)
- Commercial planners: no source found documenting Shovel, myHomework, Todoist or Notion integrations with Connect or ALEKS (searches returned none).
- Legal/takedown: no source found of cease-and-desist letters or shutdowns against Connect/ALEKS planner tools. McGraw Hill's terms of use prohibit "any robot, spider, agent, artificial intelligence (AI), other automatic device or program or manual process to access, monitor, scrape, crawl, data mine, harvest, frame or mirror, deep link" and limit use to "own internal use for educational purposes only." DOCUMENTED (search-snippet quote, clause truncated) — [McGraw Hill Terms of Use](https://www.mheducation.com/about-us/policy-center/terms-use.html), [international version](https://mheducation.com/terms-use/international.html). This is a contract risk for Smooth and for students, independent of technical feasibility; a school agreement can override public terms.
- Existence only: public repos and commercial-looking sites offering SmartBook/Connect/ALEKS auto-answer bots exist (several GitHub repos; at least one site lists a "McGraw Hill Connect/ALEKS solver"), including ones that drive a real Chrome over the DevTools port; they are relevant only as the reason McGraw Hill invests in anti-automation. Not described further.

### Inferences
- The pattern "capture cookie, mint token, call JSON" has been done by a single hobbyist and so is technically workable at small scale; at App Store scale, McGraw Hill's terms (no scraping/AI agents) and potential response (blocking, letters) are the main risks (INFERRED).

### Gaps
- No Chrome Web Store listing for a Connect assignments tool found (search surface limited). "HistA" (Connect extension, 4 users) and "Solvex" appeared in extension indexes but I could not open them or confirm their function; Solvex's name suggests a solver, so ignore.
- Reddit, Stack Overflow, Hacker News: nothing relevant surfaced; not exhaustively searched.

## 7. Anti-automation and session constraints

### Takeaway
Little hard evidence. Automation scripts exist against both the login page and the app, so Connect is evidently scriptable from a real browser, but I found no documentation of Akamai/Cloudflare/PerimeterX, CSP/frame-blocking, or device limits. The access token is short-lived (5 minutes per one repo), the session cookie is long-lived.

### Cited Findings
- Connect session design (via one repo): long-lived `ERIGHTS` cookie, 5-minute `MH_TOKEN` JWT. OBSERVED-BY-THIRD-PARTY — [schoolhub sites.py](https://github.com/mrsoftskin/schoolhub/blob/main/src/brain/connectors/sites.py)
- The login page has been driven by Selenium and Playwright in public scripts (username/email box typed into), implying no hard block on automated browsers at least in those runs; for the app, a Playwright attach over CDP to a normal Chrome worked in 2026 field notes. OBSERVED-BY-THIRD-PARTY — [OpsResearch](https://github.com/ignuslabs/OpsResearch/blob/main/automated_collector.js), [Muse-Spark guide](https://github.com/hcswint7/Muse-Spark-Python/blob/main/docs/browser_skills/SMARTBOOK_AUTOMATION_GUIDE.md)
- McGraw Hill supports Respondus LockDown Browser for ALEKS and Connect-style proctored exams, so lockdown affects only instructor-enabled proctored assessments. DOCUMENTED — [ALEKS Respondus note](https://www.mheducation.com/support/aleks-support-center/knowledge/respondus-lockdown-browser-now-available-for-aleks-on-chromebooks)
- A public tracker catalog lists reCAPTCHA among domains McGraw Hill properties load; not verified for the login page. (weak) — [duckduckgo/tracker-radar](https://github.com/duckduckgo/tracker-radar)

### Inferences
- Because the Canvas LTI launch opens Connect in a new tab/window (not in an iframe: "launched in a new tab"), WKWebView would need to handle `target=_blank` windows and third-party cookie rules; a hidden LTI launch like Ed's may be harder (INFERRED from the launch behavior).
- WKWebView login on `accounts.mheducation.com` is plausible but a CAPTCHA or bot-score challenge could appear on the first sign-in (INFERRED from reCAPTCHA presence; unverified).

### Gaps
- Bot-detection vendor (Akamai, Cloudflare, PerimeterX, etc.), CSP / X-Frame-Options, WKWebView compatibility, device/session concurrency limits, the ERIGHTS cookie lifetime, and ALEKS session lifetime: all unknown and need a hands-on test with a real account (outside this session's constraints, which forbid logging in).
