# Canvas authentication, session mechanics and the submission API, as they bear on a non-browser client acting as the student (notes written 2026-10-30)

Method note: canvas-lms source was read from the `master` branch via raw.githubusercontent.com (WebFetch summaries of the files, not line-by-line reads, so quoted names are accurate but exact line numbers are not given). Several files named in the brief (`authlogic_mods.rb`, `pseudonym_session.rb`) turned out to contain no timeout or IP logic; the session timeout lives elsewhere and I could not open it (see Gaps). Master may differ from the build Penn runs.

## 1. The `canvas_session` cookie: issuance, lifetime, binding, server-side checks

### Takeaway
Canvas keeps login state in a Rails encrypted-cookie session (`_normandy_session`) with a default 1-day `expire_after`, an instance-level timeout an admin/Instructure can change, and a 2-week single-use "remember me" token. In the files read there is no IP or user-agent binding; the cookie is checked only against server-side state (last_logged_out, CAS/OIDC expiry, suspension). Caveat: I did not find the `SessionsTimeout` source or the `canvas_session` name itself, so exact idle-vs-absolute semantics are unconfirmed.

### Cited Findings
- Session cookie key in source is `_normandy_session`; `expire_after` defaults to `1.day` (`config[:expire_after] ||= 1.day`), `expires` set nil so the shorter of session expiry or `expire_after` applies; values can be overridden at runtime from Consul config; `secure`/`same_site: :none` are set only when `force_ssl` is on; the file hooks `Autoextend.hook(:EncryptedCookieStore, :SessionsTimeout)` but does not define timeout behaviour — [session_store.rb](https://raw.githubusercontent.com/instructure/canvas-lms/master/config/initializers/session_store.rb)
- Cookie session is consulted only if JWT and access-token auth did not authenticate the request (`PseudonymSession.find_with_validation`); the session is invalidated if it predates the user's `last_logged_out`, the CAS ticket expired, the OIDC token expired, or the pseudonym is suspended; for API/JSON requests this raises `LoggedOutError` (401-style), otherwise redirect to login — [authentication_methods.rb](https://raw.githubusercontent.com/instructure/canvas-lms/master/lib/authentication_methods.rb)
- In the same file there is no `/api` path check on session lookup; cookie auth is attempted for any request not token-authenticated — [authentication_methods.rb](https://raw.githubusercontent.com/instructure/canvas-lms/master/lib/authentication_methods.rb) (summary tool noted `api_request?` is defined elsewhere)
- `PseudonymSession`: remember-me lasts 2 weeks (`remember_me_for 2.weeks`), stored as a `SessionPersistenceToken` that is single-use (consumed and replaced on each use); `last_request_at_threshold` is `LAST_REQUEST_WINDOW` (10 minutes); `remote_ip` is an accessor but "no IP or user-agent checks" were found in this file; no idle timeout enforced in this file; session lookup cached in `Rails.cache` for `pseudonym_session_cache_ttl` (default 5 s) — [pseudonym_session.rb](https://raw.githubusercontent.com/instructure/canvas-lms/master/app/models/pseudonym_session.rb)
- `authlogic_mods.rb` contains no session expiry, IP/UA, or `session_timeout` logic; it only reorders the `persist_by_cookie` callback so the session cookie takes precedence over the remember-me cookie, and tolerates read-only DB errors — [authlogic_mods.rb](https://raw.githubusercontent.com/instructure/canvas-lms/master/config/initializers/authlogic_mods.rb)
- After a login that used a remember-me token, `session[:used_remember_me_token]` is set and `require_password_session` forces a password re-login for sensitive actions — [application_controller.rb](https://raw.githubusercontent.com/instructure/canvas-lms/master/app/controllers/application_controller.rb)
- Community reports (older, unofficial) on the instance-wide inactivity timeout: a 2018-era admin thread says default is 48 hours; a University of Illinois help page says Canvas idle default is 24 hours; the timeout is changed by the Instructure CSM, not by an end user; one forum report says CAS may log out after an hour or two while Canvas itself stays for up to 24 hours — [community thread](https://community.canvaslms.com/t5/Archived-Questions/Canvas-session-timeout-setting/m-p/148249), [Illinois](https://answers.uillinois.edu/112599), [CAS thread](https://community.canvaslms.com/t5/Archived-Questions/ARCHIVED-CAS-Session-Logs-Users-Out-Even-While-Active/td-p/81717). (These URLs came from search results; I could not re-fetch the community pages, so the figures are second-hand and mutually inconsistent, 24h vs 48h.)
- Canvas mobile apps can be configured with a session duration (minimum 20 minutes) per a Canvas deploy note quoted in search results — [search result summary, Instructure community](https://community.canvaslms.com/t5/Canvas-Question-Forum/Inactivity-timeout/m-p/540044) (weak: not read directly).

### Inferences
- Because no IP/UA binding appeared in `pseudonym_session.rb`, `authlogic_mods.rb` or `authentication_methods.rb`, a session cookie replayed from another IP/UA would probably work until it expires or is invalidated, but this is not proven: the Rails cookie store, an upstream WAF, or Instructure cloud infrastructure could add checks I did not see. Needs an empirical test.
- Whether Penn's instance uses 1 day, 24h idle, or 48h is unknown; the app's existing "24 hours after last save" rule matches the 1-day `expire_after` default.
- Server-side invalidation on logout (`last_logged_out`) means a student logging out in a browser kills all cookie copies (inference from the code path above).

### Gaps
- Could not locate `SessionsTimeout` / the `session_timeout` Setting/account setting source (the `lib/canvas/sessions_timeout.rb` path I guessed 404'd), so idle-vs-absolute is unconfirmed.
- Nothing found on `log_session_id` or `_legacy_normandy_session` cookies; cookie named `canvas_session` not seen in source (the code key is `_normandy_session`; the live name may be set via Consul config).
- Penn's actual timeout value is not published anywhere I found.

## 2. Cookie-authenticated API calls and CSRF

### Takeaway
Canvas does not restrict `/api/v1` to tokens: a request with only a session cookie falls through to cookie auth. Non-GET cookie-authenticated requests must carry a valid CSRF token (form param or `X-CSRF-Token` header validated against a cookie-held secret); the CSRF check is skipped only for API requests that are not "in_app".

### Cited Findings
- Authentication order is JWT, then access token (Bearer header or `access_token` param), then session cookie — [authentication_methods.rb](https://raw.githubusercontent.com/instructure/canvas-lms/master/lib/authentication_methods.rb)
- `verified_request?` returns true if protection is off, the request is GET/HEAD, `(api_request? && !in_app?)`, or the token from the form param or the `X-CSRF-Token` header validates against the cookies via `CanvasBreachMitigation::MaskingSecrets.valid_authenticity_token?` — [request_forgery_protection.rb](https://raw.githubusercontent.com/instructure/canvas-lms/master/lib/canvas/request_forgery_protection.rb)
- `api_request?` is defined by `API_REQUEST_REGEX = %r{\A/api/}`; `protect_from_forgery with: :exception` is on; an `InvalidAuthenticityToken` with a blank `_csrf_token` cookie redirects to login with `needs_cookies=1` — [application_controller.rb](https://raw.githubusercontent.com/instructure/canvas-lms/master/app/controllers/application_controller.rb)
- `masked_authenticity_token` runs at the start of `load_user` to ensure the CSRF cookie is set — [authentication_methods.rb](https://raw.githubusercontent.com/instructure/canvas-lms/master/lib/authentication_methods.rb)

### Inferences
- A cookie client that GETs any Canvas page receives the `_csrf_token` cookie; it can then send its (unmasked) value as `X-CSRF-Token` on POSTs. This is how Canvas's own web UI JavaScript calls `/api/v1`. Likely works for submissions, but not tested here.
- The definition of `in_app?` was not found; if it is true for cookie-authenticated requests, CSRF applies to them (which is the standard browser case). This is the reading consistent with the browser UI working, not a verified fact.

### Gaps
- `in_app?` definition and the `CanvasBreachMitigation::MaskingSecrets` implementation (cookie name, token format) not read.
- Controller-side `submissions_api_controller#create` permission checks beyond "active student enrollment" not read.

## 3. Access tokens, developer keys, OAuth2, mobile

### Takeaway
Tokens are either user-generated (manual) or OAuth2 via an institution-issued developer key. Admins can block students from making manual tokens, and Penn appears to (per the project's own finding). OAuth2 requires the institution to issue a developer key, so a third-party app cannot unilaterally get tokens for Penn.

### Cited Findings
- Account setting "Restrict students from creating personal access tokens" blocks users holding only a student role; a Nov 2025 release note extended it to observers ("Restrict students and observers…"); a 2024 "Admin Manage Access Tokens" option was removed per Sept 2025 notes — [Deploy Notes 2025-11-05](https://community.canvaslms.com/t5/Canvas-Releases/Canvas-Deploy-Notes-2025-11-05/ta-p/661038), [Deploy Notes 2025-09-10](https://community.canvaslms.com/t5/Canvas-Releases/Canvas-Deploy-Notes-2025-09-10/ta-p/654577) (from search-result summaries; pages not opened)
- The restriction blocks only manual token creation; students still make API calls through developer keys and mobile apps — [Student use of API thread](https://community.canvaslms.com/t5/Canvas-Question-Forum/Student-use-of-API/m-p/646466) (search summary; page body was not retrievable)
- Several universities say user tokens "circumvent multi-factor authentication and university SSO" and warn that AI agents can overload the API — [UNH/PSU KB](https://td.usnh.edu/TDClient/60/Portal/KB/Article/5520/Canvas-User-API-Token-Access-UNH-PSU) and [UM System](https://tdx.umsystem.edu/TDClient/66/MOOnline/KB/PrintArticle?ID=2193) (search-result summaries)
- OAuth2: the institution's admin issues the developer key (Canvas Cloud admins manage them); flow is `GET login/oauth2/auth` (client_id, response_type=code, state, redirect_uri) then `POST login/oauth2/token` with `authorization_code`; keys issued after Oct 2015 give access tokens expiring after 1 hour; refresh via `grant_type=refresh_token` (same refresh token reused); manual tokens are for testing only, and asking other users to paste a token violates the API policy, multi-user apps must use OAuth; native apps catch the `code` from the webview redirect — [OAuth2 docs](https://canvas.instructure.com/doc/api/file.oauth.html)
- Tokens: `load_pseudonym_from_access_token` rejects expired/deleted tokens, checks `authorized_for_account?`, and for developer keys with `require_scopes` enforces scope patterns; includes are stripped unless the key has `allow_includes` — [authentication_methods.rb](https://raw.githubusercontent.com/instructure/canvas-lms/master/lib/authentication_methods.rb)
- Project's own finding (in-repo, not external): Penn shows "+ New Access Token" disabled with the tooltip "Your Canvas administrators have chosen to limit your ability to generate your own access token" — `/Users/marcoopertti/penn-dashboard/CLAUDE.md`
- Instructure API policy (effective Dec 15, 2024): applications must disclose actions taken on behalf of users at registration, and may not "Use the APIs on behalf of any third-party" ; unapproved connection technologies are restricted, "using model context protocol servers or other technologies not approved by Instructure"; use that violates a customer's academic integrity policy is prohibited if the user knows or should know it; GAI use must be disclosed to customers/users; Instructure may revoke tokens for excess load — [Instructure API Policy](https://www.instructure.com/policies/canvas-api-policy)

### Inferences
- A developer key for Penn would need Penn's Canvas admins (or Instructure CSM) to create/enable it; no self-service path for a student-facing app. The Canvas Student app presumably uses an Instructure-run mobile key (inference; not documented in what I read).
- The cookie path is not covered by developer-key scopes or the student-token restriction; the policy language above still applies to any "application" regardless of the auth mechanism (inference).

### Gaps
- Mobile developer key specifics (how Canvas Student gets tokens at Penn) not found.
- Penn-specific developer-key policy not found.
- Developer-key "scopes" list and enforcement for student-role calls not read.

## 4. The Submissions API and which assignments can be done by API

### Takeaway
Students can submit text, URL, uploaded files, media recording and student annotation via one endpoint, and upload files in a three-step flow. Classic Quizzes have start/complete endpoints; New Quizzes, LTI external tools (including Gradescope) have no student submission API.

### Cited Findings
- `POST /api/v1/courses/:course_id/assignments/:assignment_id/submissions` (also section variant): caller must be an actively enrolled student; `submission[submission_type]` required and must be among the assignment's submission types else 400. Types: `online_text_entry` (`body`, sanitized like UI), `online_url` (`url`, http/https), `online_upload` (`file_ids[]`), `media_recording` (`media_comment_id`, `media_comment_type` audio/video), `basic_lti_launch` (`url`; requires assignment type online or external_tool), `student_annotation` (`annotatable_attachment_id`). No API to list user files, none to create media comments; Google Docs not supported — [Submissions API](https://canvas.instructure.com/doc/api/submissions.html)
- File upload: three steps — POST file metadata to the context endpoint, get `upload_url` and `upload_params` (signature valid 30 min), POST multipart to `upload_url` without the access token, then confirm via 201 `Location` or authenticated GET on 3XX redirect. Students use `/api/v1/courses/:course_id/assignments/:assignment_id/submissions/self/files` — [File Uploads](https://canvas.instructure.com/doc/api/file.file_uploads.html). The doc shows only bearer-token examples and does not say whether cookies work.
- Classic Quizzes: `POST /api/v1/courses/:course_id/quizzes/:quiz_id/submissions` starts a submission (409 if one exists); `GET .../quizzes/:quiz_id/submission` returns current; `POST .../submissions/:id/complete` submits (needs `attempt` and `validation_token`); the page documents no student answer endpoint (it points to a separate Quiz Submission Questions reference not read here) — [Quiz Submissions API](https://canvas.instructure.com/doc/api/quiz_submissions.html)
- New Quizzes: community reports say the REST API exposes only quizzes/items/reports, not student responses; no official student-submission endpoint was found — [community idea](https://community.canvaslms.com/t5/Canvas-Ideas/API-Student-Responses-to-Questions-in-New-Quizzes-and-Grades/idi-p/614516), [dev thread](https://community.canvaslms.com/t5/Canvas-Developers-Group/How-get-all-answers-from-a-quiz-using-the-API/m-p/459034) (search summaries, unofficial)

### Inferences
- External Tool (LTI) assignments, New Quizzes, and Gradescope-linked assignments are completed inside the tool's own UI/session (LTI launch), so a Canvas API client cannot complete them; Gradescope would need its own Gradescope session (it is a separate product). Not directly sourced beyond the absence of any such endpoint in the docs read.
- Discussion-assignment submissions go through the Discussion Topics API (post entries); I did not fetch that doc, so treat as unverified.

### Gaps
- Discussions API, Quiz Submission Questions API, and an explicit "which types cannot be submitted via API" statement were not retrieved.
- Whether `submissions/self/files` accepts cookie+CSRF is untested.

## 5. Reading submission state

### Takeaway
Submission state is readable per assignment, per user, or in bulk, with documented fields.

### Cited Findings
- `GET .../assignments/:assignment_id/submissions/:user_id`, `GET .../assignments/:assignment_id/submissions`, and `GET /api/v1/courses/:course_id/students/submissions` (filters `student_ids[]`, `assignment_ids[]`, `workflow_state`, `submitted_since`, `graded_since`, `grouped`); `include[]` options include `submission_history`, `submission_comments`, `rubric_assessment`, `visibility`, `course`, `user`, `read_status` — [Submissions API](https://canvas.instructure.com/doc/api/submissions.html)
- Fields: `workflow_state` (`submitted`, `unsubmitted`, `graded`, `pending_review`), `submitted_at` (present only when an actual submission exists), `missing`, `late`, plus `late_policy_status`, `points_deducted`, `seconds_late` — [Submissions API](https://canvas.instructure.com/doc/api/submissions.html)
- The `submission` include on assignments (`GET .../assignments?include[]=submission`) was not verified in what I fetched.

### Inferences
- Tokens with `require_scopes` strip `include` params unless `allow_includes` (see section 3), which affects token clients but not cookie clients.

### Gaps
- Assignments API `include[]=submission` docs not fetched.

## 6. Institutional and vendor controls on third-party access

### Takeaway
Instructure's API policy restricts acting on behalf of third parties, unapproved connectors, and uses that violate a school's academic-integrity policy, and requires GAI disclosure. Penn states PennKey passwords must not be shared. I did not find a Penn page explicitly covering storing the password in an app, so that remains a policy question for Penn.

### Cited Findings
- See Instructure API policy quotes in section 3 — [Instructure API Policy](https://www.instructure.com/policies/canvas-api-policy)
- Penn Almanac (April 4, 2017): sharing your PennKey password is a policy violation; "you are expected to follow Penn's Acceptable Use Policy and—not share your password—with anyone" — [Almanac](https://almanac.upenn.edu/articles/sharing-your-pennkey-password-is-not-smart)
- Penn's "Protect your PennKey" page, via search summary: never share your password; sharing is a violation of University policy; you remain responsible for anything done with your PennKey; compromised passwords should be changed and reported to security@isc.upenn.edu — [PennKey Support](https://pennkeysupport.upenn.edu/node/16) (redirects to isc.upenn.edu/pennkey; the redirected page did not itself contain this text when fetched, so treat as search-snippet-level)
- Penn's Acceptable Use of Electronic Resources policy is the referenced policy, but I could not fetch it (guessed URL 404'd) — [Computing Policies landing, linked from](https://isc.upenn.edu/pennkey)

### Inferences
- A password held in the phone Keychain and sent only to Penn's login page is arguably not "sharing" with a person, but an external AI agent using the resulting session on the student's behalf is a different matter: the agent acts as the student with the student's full privileges, which falls within "you remain responsible for anything done with your PennKey" (inference).
- Canvas Terms of Use were not retrieved; the Instructure API policy is the only vendor document read.

### Gaps
- Instructure Canvas Terms of Use / Acceptable Use Policy text for end users not retrieved.
- Penn Acceptable Use Policy text, and any Penn guidance on password managers or apps storing PennKey, not found.

## 7. Academic integrity

### Takeaway
Penn's Code is framed around "unauthorized assistance"; instructors define it per course, and Penn teaching guidance treats submitted AI-generated content as a Code violation unless authorized. I could not retrieve the Code text itself.

### Cited Findings
- Penn CETLI guidance quoted in search results: under the Code "students may not use unauthorized assistance in their academic work", with instructors deciding what that means; another Penn teaching page says submitting work containing AI-generated content "will be considered a violation of Penn's Code of Academic Integrity" and suspected use is referred to the Center for Community Standards & Accountability — [CETLI academic integrity syllabus page](https://cetli.upenn.edu/resources/syllabus/academic-integrity-syllabus/) (search-snippet-level; secondary source says OSC vs CSA conflict between pages)
- Instructure API policy prohibits use that conflicts with a customer's academic-integrity policy when the user knows or should know — [Instructure API Policy](https://www.instructure.com/policies/canvas-api-policy)

### Inferences
- An agent that produces and submits work on a student's behalf is exposed on both the Penn "unauthorized assistance" axis (course-dependent) and the Instructure policy axis; an agent that only submits work the student authored is a narrower question not answered by these sources.

### Gaps
- The actual Code of Academic Integrity (catalog.upenn.edu) text and any Penn-wide generative AI policy were not retrieved.

## 8. Shibboleth/SAML, Duo and re-login

### Takeaway
Duo's "remember me" is a browser-cookie trust, usually 30 days, tied to the browser that set it; nothing found indicates it is portable across clients. Typical IdP session lifetimes at Penn were not found.

### Cited Findings
- Duo remembered-device trust is a browser cookie; lasts 30 days at many schools (Berkeley: "30 days or until you clear the browser cookies"); only works for the browser used to set it; durations vary (Oregon: 7-day trusted cookie); clearing cookies resets trust — [Dartmouth KB](https://services.dartmouth.edu/TDClient/1806/Portal/KB/Article/64944/Undo-Duo-s-Remember-me-for-30-Days-Setting), [Georgia Southern](https://its.georgiasouthern.edu/duo/?p=1020), [UIowa](https://its.uiowa.edu/node/4941), [Berkeley](https://calnet.berkeley.edu/news/new-changes-duo-browser-workflow) (search-snippet-level)
- A Penn Medicine (PMACS) page says "Remember me for 30 days" is offered at the Duo prompt for Office 365 and the clock restarts on use; a new browser/device re-prompts — [PMACS](https://www.med.upenn.edu/pmacs/emailnotifications/penn-office-365-two-factor-authentication) (search-snippet-level; Penn-wide Duo setting for the Canvas SAML flow not confirmed)
- Project's own observation (in-repo): on 2026-09-27 a hidden-WebView renewal through the saved PennKey password completed in 8 seconds and re-issued Duo's 30-day `browsertrust` cookie — `/Users/marcoopertti/penn-dashboard/CLAUDE.md`

### Inferences
- Because trust is browser-cookie based and WebKit cookie jars are per-app/profile, an agent running elsewhere would not carry the trust unless the cookie is exported with it; whether Duo additionally binds it to a user agent/IP is not documented in what I read, so unknown.

### Gaps
- Shibboleth `idp_session` lifetime at Penn, SAML `SessionNotOnOrAfter` values, and Penn's Duo trust duration for the Canvas login were not found.

