# Legal, policy and partnership risk of Smooth reading McGraw Hill Connect/ALEKS data

> Research notes, not legal advice. Date of research: 2026-11-02. Uncertainty flags are inline.
>
> **Source-access limitation (important for the report writer).** From this research session, `www.mheducation.com`, `icss.mheducation.com`, `web.archive.org`, `www.eff.org`, `infocanvas.upenn.edu`, `cetli.upenn.edu` and several other hosts did not resolve (the session's network allow-list blocked them; the proxy log shows 403 on CONNECT to `www.mheducation.com:443`). I therefore could NOT open McGraw Hill's Terms of Use pages myself. Everything below about McGraw Hill's terms comes from the search tool's summaries of those pages (some containing short quoted phrases) and is **unverified against the live page**. Treat quoted McGraw Hill wording as "reported by search summary", and re-fetch the pages once `mheducation.com`, `web.archive.org`, `infocanvas.upenn.edu` and `cetli.upenn.edu` are allowed. GitHub (api.github.com, raw.githubusercontent.com) and developer.apple.com were reachable and were read directly.

## 1. What do McGraw Hill's Terms say about automated access, scraping, bots, data mining, third-party account access, credential sharing and reverse engineering?

### Takeaway
Every McGraw Hill terms document surfaced prohibits robots/spiders/scrapers/data-mining or "automatic devices" without McGraw Hill's written permission, bars password sharing, and bars reverse engineering. One secondary source (a commercial cheating-bot vendor) claims the current US terms also name AI agents and browser extensions; that is unconfirmed. I could not read the primary pages, so exact wording and effective dates are unverified, and the dates found conflict.

### Cited Findings
- The main US Terms of Use live at `mheducation.com/about-us/policy-center/terms-use.html`. A search summary reports the license as "a limited, non-exclusive and non-transferable license to access and use the Services over the Internet ... for your own internal use for educational purposes only" and that materials may be used "only for your own personal study or research." — [McGraw Hill Terms of Use (via search summary, not opened)](https://www.mheducation.com/about-us/policy-center/terms-use.html)
- A search summary reports a "Restrictions on Use" section of the US terms that lists reverse engineering of the Services and efforts to circumvent or interfere with them among prohibited acts; the excerpt was truncated. — [McGraw Hill Terms of Use](https://www.mheducation.com/terms-use.html) (summary only)
- McGraw Hill's customer self-service portal terms (a different, older-looking document at a different subdomain) are reported to prohibit using or attempting to use any "deep-link," "scraper," "robot," "bot," "spider," "data mining," "computer code" or similar automated device/process to access, copy or monitor its pages or content without prior written consent, and to prohibit circumventing access limits. — [icss.mheducation.com Terms of Use](https://icss.mheducation.com/static/termsofuse) (summary only; this is the customer-service portal, not necessarily Connect/ALEKS)
- The McGraw Hill monthly rental membership agreement is reported to contain: "RESTRICTIONS ON USE. use any robot, spider, other automatic device or program or manual process to monitor, copy or reproduce the Services or any part thereof." — [Monthly rental membership agreement](https://www.mheducation.com/highered/monthly-rental-membership-agreement.html) (summary only)
- A 2022 school-district subscription agreement with McGraw Hill reportedly also bars robots/automated programs and says a separate written agreement with McGraw Hill can override the standard terms. — [Palm Beach BoardDocs copy of McGraw Hill School Subscription Agreement (Rev 02-15-2022)](https://go.boarddocs.com/fl/palmbeach/Board.nsf/files/DGLK424FFA40/$file/Terms%20of%20Service.pdf) (summary only)
- International terms (separate document) are reported to say access is limited to the named user and that "username/password sharing is not permitted", and that McGraw Hill may suspend or terminate an account if it suspects access has been shared; users are responsible for keeping their password and account confidential. — [International Terms of Use](https://www.mheducation.com/about-us/policy-center/terms-use/international) (summary only)
- ALEKS sign-up flows have the student accept the McGraw Hill Terms of Use and Privacy Policy ("Clicking 'Accept' means that you agree to the terms of the McGraw-Hill Education Terms of Use and Privacy Policy"); I found no separate, standalone ALEKS terms document, so ALEKS appears to be governed by the McGraw Hill Terms of Use (plus any institutional agreement). — [UToledo ALEKS registration instructions](https://www.utoledo.edu/it/aleks/ALEKS_Student_Registration_and_Access_Code_Purchase_New_Instructions.docx) (summary only)
- A cheating-bot vendor, Silent Student, claims McGraw Hill's Terms "last updated October 16, 2026" bar any "agent, robot, spider, or other automatic device or program" and also third-party AI agents or browser extensions (including ones that complete or submit assignments) unless McGraw Hill authorizes them in writing. Commercially interested, unverified. — [Silent Student McGraw Hill page](https://silentstudent.com/platforms/mcgraw-hill)
- **Date conflict:** the international terms page was reported as "Last updated: April 24, 2026" in one search and "May 8, 2024" in another; Silent Student says Oct 16, 2026 for the US terms. Note that Oct 16, 2026 is also the "Last Updated" date of Apple's App Review Guidelines as read directly (see section 5), so the vendor date may be a conflation. No date for the US terms was confirmed. — [International terms](https://www.mheducation.com/about-us/policy-center/terms-use/international); [Apple guidelines](https://developer.apple.com/app-store/review/guidelines/)
- Third-party (university IT) FAQ says sharing access codes violates McGraw Hill terms and can cost the student access. Not an official document. — [Connect FAQ PDF mirror](https://dev.studyabroadfoundation.org/Download_PDFS/B12RN0/995163/Mcgraw%20Hill%20Connect%20Frequently%20Asked%20Questions.pdf)

### Inferences
- Smooth's method (student signs in inside an in-app WebView; the app reads the student's own assignment pages) is not credential sharing in the sense of giving a password to a third-party server if the password stays on device, but it is arguably "automatic device or program ... to monitor, copy" and, if the Silent Student claim is right, an "agent/extension" acting on the student's account. A court or McGraw Hill would likely read the robot/automatic-device clause as covering it; the "own personal use" framing helps equitably but is not a clause-based defense.
- The consequence of breach is most plausibly account suspension for the student, a C&D or an App Store complaint to Apple rather than a lawsuit (see section 2), but the student-account risk falls on users, not Smooth, and matters for a student-facing product.

### Gaps
- Verbatim text of the current US Terms of Use ("Restrictions on Use", AI/agent language), its true effective date, and any Wayback snapshots: unreachable here. Re-fetch `https://www.mheducation.com/about-us/policy-center/terms-use.html` and Wayback copies.
- Whether Connect and ALEKS each have additional product-specific terms beyond the general Terms of Use: not found.
- Institution-specific McGraw Hill licence terms for Penn: not found.

## 2. Enforcement: lawsuits, takedowns, DMCA notices

### Takeaway
I found no McGraw Hill lawsuit, cease-and-desist or DMCA notice aimed at a tool or app that accesses Connect/ALEKS. McGraw Hill's visible enforcement is DMCA takedowns of pirated textbook PDFs on GitHub (many through anti-piracy agents). Absence of evidence is weak: C&D letters are rarely public, and my search was limited.

### Cited Findings
- I searched GitHub's public DMCA repository for McGraw Hill name variants and mheducation.com and got ~56 notice files (2015 through April 2026), then downloaded and grepped them for "connect.mheducation", "ALEKS", "scrap", "bot", "automat", "api", "homework", "cheat", "bypass", "circumvent". No notice mentions Connect, ALEKS, homework tools, scrapers or bots. The only match for "scrap" was a file URL naming an unrelated Python scraping book. — [github/dmca repo](https://github.com/github/dmca) (e.g. [2021-03-29](https://github.com/github/dmca/blob/master/2021/03/2021-03-29-mcgraw-hill.md))
- Typical notices target textbook PDFs: e.g. 2025-07-07 filed by Link-Busters.com for "McGraw Hill LLC books" (Numerical Methods for Engineers PDF); 2025-10-01 filed by Naxap Technology on behalf of McGraw Hill Education (India) for a Laxmikanth polity PDF; 2026-04-23 filed by Link-Busters for Rosen, Schildt and Schach titles. — [2025-07-07](https://github.com/github/dmca/blob/master/2025/07/2025-07-07-mcgraw-hill.md); [2025-10-01](https://github.com/github/dmca/blob/master/2025/10/2025-10-01-mcgraw-hill.md); [2026-04-23](https://github.com/github/dmca/blob/master/2026/04/2026-04-23-mcgraw-hill.md)
- One notice (2025-09-05, McGraw Hill LLC, "Linux: The Complete Reference") claimed anti-circumvention ("DRM has been removed"); GitHub stated it "did not find sufficient information to determine a valid anti-circumvention claim" but upheld other copyright claims. This is the only DMCA 1201 (anti-circumvention) claim found, and it concerned a pirated ebook, not login-based access. — [2025-09-05 notice](https://github.com/github/dmca/blob/master/2025/09/2025-09-05-mcgraw-hill.md)
- A search for McGraw Hill suits against Chegg/Course Hero over Connect content returned nothing; the news that surfaced concerned a Chapman professor's suit and Chegg's problems in Australia, not McGraw Hill. — [ABA Journal on Chapman case](https://abajournal.com/news/article/lawyer-a-chapman-prof-files-infringement-suit-to-learn-which-students-posted-exam-questions-online)
- Commercial Connect auto-answer bots openly operate (e.g. Silent Student, CanvasQuiz marketing pages), which suggests McGraw Hill has not shut such sites down, though these vendors are non-credible sources on enforcement. — [Silent Student](https://silentstudent.com/platforms/mcgraw-hill); [CanvasQuiz](https://canvasquiz.com/guides/can-mcgraw-hill-detect-ai/)

### Inferences
- McGraw Hill's demonstrated posture is copyright enforcement through agents; it has not (publicly) pursued interface-automation tools. A benign read-only due-date tool is a very different target than cheating bots, but if McGraw Hill ever objects it will probably be by letter or through Apple (section 5).
- My GitHub search used code search on name strings; notices that describe tools without naming McGraw Hill would not be found.

### Gaps
- Non-public C&D letters, Apple/Google store complaints and takedowns of apps or browser extensions that touch Connect: not discoverable. I did not search the Chrome Web Store or Apple store for Connect-related extensions removed at McGraw Hill's request.
- A search summary mentioned Pearson v. Chegg copyright litigation; I could not confirm it with a URL, so it is excluded.

## 3. Official routes: partner/developer programs, data APIs, LTI/Caliper, "McGraw Hill Plus", integrations; how a startup would approach

### Takeaway
McGraw Hill's documented integration surface is LTI 1.3 / LTI Advantage between Connect and LMSs (Canvas, Blackboard, D2L, Moodle): SSO, assignment linking and grade sync, run through institutions. I found no public developer API, developer portal or student-app partner program. The most practical "official" route may be data that already reaches Canvas via LTI, which Smooth already reads.

### Cited Findings
- Connect's LMS integration is built on IMS Global's LTI 1.3 (LTI Advantage); it provides single sign-on, assignment-level linking and gradebook sync; McGraw Hill lists Blackboard Learn, D2L Brightspace, Canvas and Moodle as supported; the architecture is IMS-certified. — [LTI Advantage page](https://www.mheducation.com/highered/support/knowledge/what-is-lti-advantage-ltia.html); [press release](https://www.mheducation.com/news-media/press-releases/mcgraw-hill-lti-advantage-connect-integrations.html)
- LTI Advantage grade sync reportedly sends zeros after the due date and can deploy assignments without a gradebook column in the LMS. LTIA is configured by the institution's LMS administrator, with a McGraw Hill Platform Integration Consultant if needed. — [LTI Advantage enhancements guide](https://www.mheducation.com/content/dam/mhe/highered/documents/connect/lti-advantage-enhancements-guide.pdf); [LMS integration page](https://www.mheducation.com/highered/services/learning-management-system-integration.html)
- Peer evidence on LMS calendar propagation: Pearson says MyLab/Mastering due dates show in the LMS calendar after the first grade sync for LTI 1.1 in any LMS and for Blackboard/Canvas via Access Pearson (LTI 1.3), but not for D2L, Moodle, Sakai or Schoology. Cengage lists Due Date Sync (MindTap, WebAssign) to the LMS. — [Pearson sync grades](https://help.pearsoncmg.com/integration/cg/instructor/content/sync_grades.htm); [Pearson add assignment links](https://help.pearsoncmg.com/integration/cg/instructor/content/add_assignment_links.htm); [Cengage LMS date sync](https://help.cengage.com/mindtap/mt-instructor/common/lms-sync-dates-general.html)
- Searches for a McGraw Hill technology/developer partner program, developer API, Caliper feed or student-app partnership returned nothing relevant (only content partnerships such as Binary Logic, and a job posting mentioning internal "ePaaS" APIs). — [Binary Logic partnership PR](https://mheducation.com/news-insights/press-releases/mcgraw-hill-announces-exclusive-partnership-with-binary-logic-leader-in-edtech-innovation-in-the-computing-and-ict-space.html); [McGraw Hill partnerships page (Canada mirror)](https://canada.magento.intl.prod.mheducation.com/partnerships)
- No documentation found for "McGraw Hill Plus" as a data-access route.

### Inferences
- Where a Penn instructor deploys Connect/ALEKS through LTI 1.3 in Canvas, an assignment may exist in Canvas with a due date and may appear in the Canvas calendar feed Smooth already reads, with no McGraw Hill access. By analogy with Pearson/Cengage this is plausible but unproven for McGraw Hill; completion state would not come through (zeros are posted only after the due date). This is the cheapest test to run: check a real Penn Connect/ALEKS section's Canvas calendar and assignment list.
- A direct integration would probably need a bespoke business-development conversation; the realistic entry points are McGraw Hill higher-ed sales/partnership contacts or a Penn instructional-technology office sponsoring it. I found no published BD contact or partner portal.

### Gaps
- Existence of a gated partner program, a Caliper endpoint, or student-data APIs for institutions (contract-only): not publicly documented as far as searched.
- Whether Penn deploys Connect/ALEKS via LTI 1.3 and whether items reach the Canvas calendar feed: needs a live check.
- Contact names or a partner application page: not found.

## 4. Precedents and case law: other publishers, student apps, user-authorized scraping

### Takeaway
I found no public precedent of a third-party student app formally partnering with Pearson, Cengage or Macmillan, nor any app publicly blocked by them, and none of them publishes an open student-app API that I could find. Case law is mixed: the CFAA is narrow after Van Buren and hiQ, but Facebook v. Power Ventures holds that user permission does not survive the platform's explicit revocation, and contract (ToS) claims remain separate.

### Cited Findings
- Pearson's own help pages describe due-date delivery via LMS integrations and a first-party Pearson student app showing due dates; no third-party API documented. — [Pearson sync grades](https://help.pearsoncmg.com/integration/cg/instructor/content/sync_grades.htm); [Pearson student app note](https://ccndweb.pearsoncmg.com/students/whats-new)
- Cengage help centre documents LMS due-date sync only; no third-party developer API surfaced. — [Cengage LMS date sync](https://help.cengage.com/mindtap/mt-instructor/common/lms-sync-dates-general.html)
- *Facebook v. Power Ventures*, 844 F.3d 1058 (9th Cir. 2016): Power aggregated users' social accounts using their credentials. The court said users' consent gave "at least arguable permission" initially, but after Facebook's cease-and-desist and IP block, continued access violated the CFAA; a ToS violation alone is not enough. — [Cato brief](https://www.cato.org/publications/legal-briefs/power-ventures-v-facebook); [EFF/ACLU rehearing post](https://www.eff.org/deeplinks/2016/08/do-over-please-eff-and-aclu-ask-ninth-circuit-revisit-two-dangerous-cfaa-rulings); [Mintz summary](https://www.mintz.com/insights-center/viewpoints/2826/2016-07-facebook-v-vachani-user-authorization-can-be-revoked)
- *hiQ v. LinkedIn* (9th Cir. 2022, on remand after *Van Buren v. United States*, 2021): panel again upheld the injunction; read "without authorization" as not applying to public websites. Commentators note Van Buren addressed "exceeds authorized access," so the extension is an inference; and hiQ concerned public, non-login data. — [Proskauer](https://www.proskauer.com/blog/taking-cue-from-the-supreme-courts-van-buren-decision-ninth-circuit-releases-new-opinion-holding-scraping-of-publicly-available-website-data-falls-outside-of-cfaa); [Fenwick](https://www.fenwick.com/insights/publications/hiq-labs-scrapes-by-again-the-ninth-circuit-reaffirms-that-data-scraping-does-not-violate-the-cfaa-1); [FBM](https://www.fbm.com/data-analytics/publications/what-recent-rulings-in-hiq-v-linkedin-and-other-cases-say-about-the-legality-of-data-scraping/)
- *Meta v. Bright Data* (N.D. Cal., Jan 23, 2024, No. 3:23-cv-00077): summary judgment for Bright Data on the contract claims; the terms did not bar logged-off scraping of public data, and Meta had not shown logged-in scraping of non-public data. Meta later dropped the case. The ruling turns on Meta's terms wording and on logged-off public data, so it is weak support for logged-in access to a student's private account. — [FBM analysis](https://www.fbm.com/data-analytics/publications/major-decision-affects-law-of-scraping-and-online-data-collection-meta-platforms-v-bright-data/); [Eric Goldman blog](https://blog.ericgoldman.org/archives/2024/01/game-on-bright-data-scores-major-victory-in-web-scraping-dispute-with-meta-guest-blog-post.htm); [MediaPost (case dropped)](https://www.mediapost.com/publications/article/393996/None)

### Inferences
- Smooth's facts (logged-in, private, user-authorized, on the user's own device) sit closest to Power Ventures, not hiQ: initial user-authorized access is arguably not "without authorization," but the safe-harbor ends if McGraw Hill sends an explicit revocation (C&D, IP/device blocking) and Smooth keeps going. Practical implication: a response plan for a C&D should exist before launch (turn the feature off).
- On-device reading by the user's own client (no Smooth server involvement) is a stronger fact pattern than Power Ventures (server-side access with stored credentials), but I found no case directly deciding that.
- Contract exposure is what actually matters: Bright Data won because Meta's wording did not cover the conduct; McGraw Hill's wording (robot/automatic device, possible AI-agent clause) is more directly on point, and the user-account click-through is a binding agreement for the student.

### Gaps
- Specific named third-party student apps and how each publisher treated them (e.g. Macmillan Achieve): no sources found; nothing on Macmillan at all.
- Any court case directly about a user-authorized app reading the user's own educational-platform account data.
- The primary opinions (Power Ventures, hiQ, Van Buren, Bright Data order) were not read directly; the claims above rest on law-firm/advocacy summaries.

## 5. Apple App Store Review Guidelines (5.2.2, 5.1.1, 5.1.2) and enforcement

### Takeaway
Guideline 5.2.2 requires that an app accessing or displaying content from a third-party service be "specifically permitted" by that service's terms, with authorization provided on request. If McGraw Hill's terms bar automated access, Smooth would not clearly satisfy 5.2.2 for McGraw Hill. I found no data on how strictly 5.2.2 is enforced against login-and-read apps like this.

### Cited Findings
- Guidelines page read directly, "Last Updated: October 16, 2026." **5.2.2 Third-Party Sites/Services:** "If your app uses, accesses, monetizes access to, or displays content from a third-party service, ensure that you are specifically permitted to do so under the service's terms of use. Authorization must be provided upon request." — [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **5.1.1(i) privacy policy:** must identify what data the app collects, how, all uses; confirm third parties give equal protection; explain retention/deletion and how users revoke consent. **5.1.1(iii) data minimization:** "Apps should only request access to data relevant to the core functionality of the app." **5.1.1(v) account sign-in:** social-network credentials must not be stored "off of the device," and the app "may only use such credentials or tokens to directly connect to the social network from the app itself while the app is in use." **5.1.1(vi):** "Developers that use their apps to surreptitiously discover passwords or other private data will be removed from the Apple Developer Program." — same page
- **5.1.2(i):** must disclose where personal data is shared with third parties, "including with third-party AI," and obtain explicit permission; data shared with third parties only to improve the app or serve ads. **5.1.2(ii):** data collected for one purpose may not be repurposed without further consent. — same page
- On forums, developers ask whether a licensed API satisfies 5.2.2 or whether each underlying website must authorize; Apple's stated remedy in anecdotal rejections is documentary proof of rights or removal of the content. — [Apple dev forum thread 821308](https://developer.apple.com/forums/thread/821308); [freelancer.cl anecdote (weak)](https://www.freelancer.cl/projects/mobile-phone/have-webview-ios-application-rejected/)
- WebView-wrapper apps are often rejected under 4.2 (minimum functionality), a separate issue. — [MobiLoud](https://www.mobiloud.com/blog/app-store-review-guidelines-webview-wrapper)

### Inferences
- 5.1.1(v)'s text is aimed at social networks, but its principle (credentials stay on device, used only to connect directly while in use) matches Smooth's on-device design; keeping any stored PennKey/McGraw Hill credentials device-only fits it.
- Risk is chiefly a reviewer or rights-holder complaint under 5.2.2 rather than routine screening; Smooth already passed review with Canvas/Gradescope per the project notes, but this research did not examine those services' terms, so that is not a safe analogy for McGraw Hill.
- If McGraw Hill complained to Apple, "Authorization must be provided upon request" puts the burden on Smooth; a written McGraw Hill permission (or a documented permissive clause) is the clean answer.

### Gaps
- Real-world enforcement statistics or case reports of 5.2.2 rejections for login/scraper apps: none found.
- The 5.2.2 clause was read once from the live page; a page-diff of earlier versions was not done.

## 6. FERPA / student-data privacy and McGraw Hill's privacy notice

### Takeaway
FERPA binds schools (and their agents); it gives a student the right to their own records and lets them consent to disclosure to a third party, so a student-directed, on-device app is not itself regulated by FERPA, but the school/McGraw Hill relationship is, and McGraw Hill's own terms treat it as a FERPA "School Official" for school-provided data. I could not read McGraw Hill's Privacy Notice.

### Cited Findings
- McGraw Hill's terms of service state it "will be considered a 'School Official' (as that term is used in FERPA)" and will comply with FERPA's confidentiality and release requirements for personally identifiable information; they refer to the separate Privacy Notice for data practices. — [McGraw Hill terms of service](https://www.mheducation.com/about-us/policy-center/terms-service.html) (summary only)
- FERPA school-official exception (34 CFR 99.31(a)(1)(i)(B)) lets schools outsource functions to third parties meeting the school's annual-notification criteria. — [Dept. of Education: who is a school official](https://studentprivacy.ed.gov/faq/who-school-official-under-ferpa); [Dept. of Education: online educational services](https://studentprivacy.ed.gov/resources/protecting-student-privacy-while-using-online-educational-services-requirements-and-best)
- Consent for a school to disclose records to a third party must be signed and dated, identify the records and purpose, and name the recipient (34 CFR 99.30); electronic signatures are permitted; a school is not obliged to release even with consent; the only party the institution must give records to is the student. — [34 CFR 99.30 (GovInfo)](https://govinfo.gov/content/pkg/CFR-2023-title34-vol1/pdf/CFR-2023-title34-vol1-sec99-30.pdf); [StudentPrivacy.ed.gov consent FAQ](https://studentprivacy.ed.gov/faq/what-must-consent-disclose-education-records-contain); [AACRAO](https://www.aacrao.org/resources/newsletters-blogs/aacrao-connect/article/ask-the-ferpa-professor-5-27-2024)

### Inferences
- Smooth reading a student's own page with the student's own login, keeping it on device, does not involve a school disclosing records to Smooth; FERPA is probably not the binding constraint. The binding constraints are McGraw Hill's terms (contract) and Apple's guidelines. This is an inference, not legal advice; confirm with counsel.
- The privacy posture Smooth already uses (data stays on device; nothing sent to a server) is the strongest answer to both McGraw Hill's privacy concerns and Apple 5.1.1/5.1.2; any server-side relay of Connect data (e.g. through the Chrome-extension sync or `ask`) would change that and the FERPA/contract analysis.

### Gaps
- McGraw Hill Privacy Notice text on third parties and student-authorized access: not retrieved.
- Whether Connect/ALEKS records are "education records" at Penn (likely, if Penn is the contracting school): not determined.

## 7. University of Pennsylvania angle

### Takeaway
I found no Penn policy specifically governing third-party apps that access courseware (Connect/ALEKS) accounts. Penn Canvas pages indicate a restrictive posture toward third-party access (student Canvas API tokens disabled from 2025) and a student-records confidentiality policy; neither page was opened directly.

### Cited Findings
- A search summary of Penn's Canvas site policies page says that "Beginning in 2025, Penn no longer permits student creation of API tokens in Canvas," citing security, data privacy risk and Acceptable Use; and that Canvas student data falls under Penn's Confidentiality of Student Records policy. — [Penn Canvas site policies](https://infocanvas.upenn.edu/policies/canvas-site-policies) (summary only, not opened)
- A Penn CETLI page reportedly says Penn's Office of Audit, Compliance & Privacy restricts unlicensed tools to protect student data; the specific restrictions were not visible. — [CETLI page](https://cetli.upenn.edu/bnjx) (summary only)
- The project's CLAUDE.md already notes Penn restricts student Canvas access-token creation (observed on the owner's settings page). — project file `/home/user/penn-dashboard/CLAUDE.md` (Traps: "Penn restricts student Canvas access tokens")

### Inferences
- The Penn token policy supports using the student's own web session (not tokens) as Smooth already does, and signals Penn would likely not welcome unsanctioned third-party access at the institutional level. It does not, on what I read, bind a student using their own login on their own phone.
- A vendor-review route (Penn Audit, Compliance & Privacy; instructional technology) exists in principle for tools used institutionally; Smooth is student-directed, so that review likely does not apply, but it would be part of any institution-sponsored route.

### Gaps
- Penn Acceptable Use, Confidentiality of Student Records and electronic-privacy policy texts: not read.
- Penn's own McGraw Hill/ALEKS contract and whether it limits student use of third-party tools: not found.
