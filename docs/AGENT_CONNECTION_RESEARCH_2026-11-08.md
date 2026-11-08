# Agent connection: how to set it up correctly

_Research write-up, 2026-11-08, for the v11 agent connection. Nothing here is
built or compiled. It feeds `docs/AGENT_CONNECTION_PLAN_V11_2026-11-07.md`
(the decisions and phases) and `docs/AGENT_CONNECTION_SESSION_PROMPT.md`
(the brief for the session that builds it). Five research passes produced
it: MCP hosting on Supabase, OAuth for anonymous users, the Canvas write
path from iOS, client reach and policy, and a survey of this repo. Each
claim below says whether a page was READ, only seen as a search SUMMARY,
or read from this REPO. Re-read a page before quoting it to Apple or
Instructure._

## 0. What the owner wants, in one paragraph (2026-11-08)

Marco: connect Claude (or ChatGPT, where its plans allow) to Smooth so the
agent has all the context of your classes, can draft assignments including
files, and the student reviews and submits from the Smooth app. The agent
never submits. It should work from the Claude apps he already uses, phone
included, so the connector is a cloud one. Penn only to start. Text, URL
and file submissions.

## 1. The shape, and why

```
  Claude (web, iPhone, Desktop, Code, Duet) ── OAuth ──► agent-auth (Edge Fn)
          │  MCP over HTTPS, bearer token                       │ phone approves
          ▼                                                     ▼
   mcp (Edge Fn, stateless) ──reads──► agent_snapshots (per-student work list, plaintext, opt-in)
          │                            course_documents, course_facts, course_profiles (pooled, exist)
          └──propose_submission──────► agent_drafts (+ Storage for files)
                                                 │ phone polls on open / refresh loop
                                                 ▼
                                      Smooth on the phone: card says "drafted by Claude",
                                      review sheet, Submit ──► Canvas (cookie + CSRF)
```

Three things make this the correct shape rather than the cheapest one:

- **The agent reads Smooth's data, never Canvas.** Instructure's API policy
  3(i) bars "model context protocol servers … not approved by Instructure"
  that connect to its APIs (READ, instructure.com/policies/api-policy,
  effective 2025-08-12). An MCP server that serves the student's own work
  list and pooled course material is not connecting to Canvas's APIs. One
  that proxied `/api/v1` calls would be the thing the clause names.
- **The submission is the student's act on the student's device.** Wharton's
  Agentic AI Guidelines (READ, support.wharton.upenn.edu/help/agentic-ai-guidelines,
  modified 2026-11-04): a PennKey session "is NOT an appropriate mechanism"
  for agent access and users "may not grant Agentic AI access to their
  PennKey user session". OpenAI's usage policy (READ via Wayback, effective
  2026-11-20) bars "automation of high-stakes actions in sensitive areas
  without human review", naming "submissions" and education. Anthropic's
  (READ, effective 2026-11-12) bars submitting "AI-assisted work without
  proper permission or attribution" and holds the user responsible for
  agent actions. Review-then-tap satisfies all three by construction, and
  no agent-side submit tool can.
- **The cloud connector is the one students will use.** Claude custom
  connectors run from Anthropic's cloud "across every Claude client,
  including claude.ai, Claude Desktop, Cowork, and the mobile apps", on
  Free (one connector), Pro, Max, Team and Enterprise (READ,
  support.claude.com article 11175166). A local `.mcpb` server would only
  reach Claude Desktop on a Mac.

The cost of the cloud shape is one honest privacy change: to answer an
agent while the phone is asleep, the server has to hold a readable copy of
the student's work list. Today it never does (PROTOCOL principle 2). Section
7 says exactly what gets stored and how it is disclosed.

## 2. Hosting the MCP server on Supabase

Sources: READ supabase.com/docs/guides/getting-started/byo-mcp;
github.com/supabase/server `docs/mcp.md`; ts.sdk.modelcontextprotocol.io v2
pages; modelcontextprotocol.io spec 2026-07-28 transports and tools;
claude.com/docs/connectors/building (+ `/authentication`, `/testing`,
`/review-criteria`, `/mcpb`).

- **SDK.** `createMcpHandler` + `McpServer` from `@modelcontextprotocol/server`
  v2 (not `@supabase/server`, which only supplies auth middleware). Builds a
  fresh server per request, so it is stateless. Deno: `deno add
  npm:@modelcontextprotocol/server`. Minimums per Supabase: CLI 2.117.0,
  `@modelcontextprotocol/server` ^2.0.0, `zod` ^4.3.6. v1 of the SDK is in
  maintenance; do not start there.
- **Protocol eras.** Spec 2026-07-28 removed sessions, the GET stream and
  `initialize`; each JSON-RPC message is its own POST with
  `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers. Claude's docs
  still name the 2025-03-26 / 06-18 / 11-25 authorization specs, so keep
  `createMcpHandler`'s default `legacy: 'stateless'`, which serves old-style
  `initialize` clients without sessions. Return 405 on GET and DELETE.
  Never mint `Mcp-Session-Id`.
- **Auth belongs in front of the handler.** Do the bearer check in the HTTP
  handler (opaque token hash lookup, audience, scope, expiry), then call
  `handler.fetch(request, { authInfo })`; tools read `ctx.http?.authInfo`.
  Do not use `withSupabase({ auth: 'user' })`: our tokens are not Supabase
  JWTs (section 3 says why). `[functions.mcp] verify_jwt = false` in
  `config.toml` is required, or the gateway 401s discovery before our code
  runs. Note `backend/scripts/deploy-function.mjs` sends `verify_jwt: true`
  for every deploy (REPO, line 217): it needs a per-function override.
- **Headers.** Requests must carry `Accept: application/json,
  text/event-stream`. Validate `Origin` loosely (Claude's egress is
  `160.79.104.0/21`; an over-strict check causes initialize timeouts).
- **Limits.** Edge Functions: 150 s wall clock on Free (400 s paid), 150 s
  idle, **2 s CPU per request**, 256 MB; request body size is not
  documented. Claude: 240 s tool timeout, about 150,000 characters per tool
  result on claude.ai and Desktop, 25,000 tokens in Claude Code. The 2 s CPU
  cap is the risk for base64 file decoding; measure it.
- **Tool results.** Content types are `text`, `image`, `audio`,
  `resource_link`, embedded `resource`; `structuredContent` with
  `outputSchema` is allowed. Claude documents support for text and image
  results only, so return long documents (a syllabus) as paged `text` with a
  `page`/`cursor` argument and a "next page" hint, never as a link the model
  would have to fetch. Put execution errors in the result with `isError:
  true`, not in JSON-RPC errors.
- **Annotations.** Every tool gets a `title` (name ≤ 64 characters, `[A-Za-z0-9_.-]`)
  and `readOnlyHint: true` on the reads. Read-only tools can run without a
  per-call prompt in Claude; others prompt ("Allow always" per tool). Research
  mode runs connector tools without further approval, which is one more
  reason the only write creates a draft and nothing else. There is no
  documented "non-destructive write" hint; test what Claude shows for
  `propose_submission` with and without `destructiveHint`.
- **Descriptions** describe what the tool does; no instructions to Claude,
  no promotional text (directory review rejects both). Don't depend on
  `instructions` from `initialize`; the modern era has no handshake.
- **Testing.** `supabase functions serve mcp` →
  `http://127.0.0.1:54321/functions/v1/mcp`. MCP Inspector (Node ≥ 22.19):
  `npx @modelcontextprotocol/inspector --server-url <url> --transport http`
  (web UI with OAuth support) or `--cli … --method tools/list`. Claude Code:
  `claude mcp add --transport http smooth <url>` then `/mcp` to sign in.
  claude.ai against a tunnel (ngrok or Cloudflare Tunnel) with auth on.
  Claude's `clientInfo` name varies; never branch on it.

## 3. OAuth for students who have no login

Sources: READ claude.com/docs/connectors/building/authentication and
`/lazy-authentication`; claude.ai/oauth/mcp-oauth-client-metadata;
code.claude.com/docs/en/mcp; developers.openai.com/apps-sdk/build/auth;
modelcontextprotocol.io spec authorization; RFC 8628; supabase.com
oauth-server guides; OWASP QRLJacking (SUMMARY); USENIX Sec '25 QR-login
study (SUMMARY).

**The problem.** Students are anonymous Supabase users: no email, no
password. The only thing that proves "this is the student" is the phone,
which holds the refresh token in its Keychain. Every client runs the
browser-redirect authorization-code flow and expects a consent page.

**What the clients demand.**
- Claude: sign-in starts only on a **401** with `WWW-Authenticate: Bearer
  resource_metadata="…"`; the header is ignored on a 200. The protected
  resource metadata's `resource` must equal the MCP URL exactly, and only
  the first `authorization_servers` entry is used. PKCE S256 always. Redirect
  URI `https://claude.ai/api/mcp/auth_callback` for web, Desktop and mobile.
  Client identity: CIMD (`client_id` =
  `https://claude.ai/oauth/mcp-oauth-client-metadata`, `token_endpoint_auth_method`
  `none`) when the AS metadata advertises
  `client_id_metadata_document_supported: true` and `"none"` in
  `token_endpoint_auth_methods_supported`; otherwise DCR, which registers a
  new client per connection. Advertise `offline_access` to get refresh
  tokens. Token endpoint must accept `application/x-www-form-urlencoded`,
  return `invalid_grant` for dead refresh tokens, rotate refresh tokens, and
  answer within 10 s (30 s for refresh). Discovery cached about 5 minutes.
- Claude Code: own CIMD, loopback redirect `http://localhost:<port>/callback`
  and `http://127.0.0.1/callback` (match ignoring port).
- ChatGPT: PRM + AS with S256; CIMD `https://chatgpt.com/oauth/client.json`
  preferred, DCR supported; redirect
  `https://chatgpt.com/connector_platform_oauth_redirect` when the AS sets
  `authorization_response_iss_parameter_supported: true` and returns `iss`
  on every response; `resource` on both authorize and token; `iss` must match
  across PRM and AS metadata exactly. Do not advertise OIDC scopes (we have no
  email).
- MCP spec: `resource` (RFC 8707) on authorize and token; the server
  validates audience and never passes tokens through; exact redirect-URI
  match; SSRF guard when fetching a CIMD URL.

**The flow: pairing as authorization.** RFC 8628 (device grant) does not fit:
the clients never poll a device endpoint. The pattern that fits is QR login
(WhatsApp Web, Discord): the browser shows a code, the trusted phone
approves it, the browser proceeds.

```
Claude  → POST /mcp (no token)                 mcp: 401 + resource_metadata
Claude  → GET PRM, GET AS metadata             CIMD supported, S256, "none"
Claude  → GET /authorize?client_id=<CIMD>&redirect_uri&code_challenge&resource&scope&state
  AS: fetch + validate CIMD (SSRF-safe), exact redirect_uri match
  AS: insert pending(id, code, nonce_hash, params, expires 5 min); Set-Cookie nonce
  AS: page shows: short code, 2-digit match number, QR, "Open Smooth" button (smooth://link?c=…)
Student → taps / scans; Smooth opens
Smooth  → POST agent-auth {action:"lookup", c} + Supabase JWT   → client host, scopes, match choices
Student → "Claude wants to read your classes. Did you just start this?" picks the number
Smooth  → POST {action:"approve", c, picked} + JWT   AS: bind user, mint one-time code (60 s)
Page    → polls /status (cookie)               AS: 302 redirect_uri?code&state&iss
Claude  → POST /token (form) code + verifier + resource → opaque access + refresh
Claude  → POST /mcp  Authorization: Bearer …   mcp: hash lookup, aud/scope/expiry, act as student
```

Pitfalls the design must answer: bind the pending request to the browser
with an HttpOnly, Secure, SameSite=Lax nonce cookie (store its hash);
relayed-code phishing (QRLJacking) is why the phone asks "did you just start
this?" and shows a number to match; one-time codes, 5-minute pending TTL,
60-second auth code, rate limits per user and IP; show the client's hostname
on the page and on the phone; never auto-redirect to an unknown client.

**Build our own authorization server; do not use Supabase Auth's.**
Supabase Auth's OAuth 2.1 server exists (authorize → developer-hosted consent
page → `approveAuthorization` → redirect) and anonymous users are ordinary
`authenticated` users, so it might work, but: its tokens are user-scoped
Supabase JWTs that also work against PostgREST and RLS, so a leaked
connector token is as powerful as the phone; its docs show no RFC 8707
`resource` handling; it documents DCR only, not CIMD; and its consent page
wants a browser session we don't have, so we would write the pairing logic
anyway. A custom AS is about five endpoints (two metadata documents,
authorize, token, revoke) plus lookup/approve/status for the phone, with
tokens stored as SHA-256 hashes.

**Token design.** Opaque 256-bit access and refresh tokens, hashed at rest
with `user_id`, `client_id`, `resource`, `scope`, `connection_id`,
`expires_at`. Access 1 hour; refresh 30 to 90 days, rotated, with reuse
detection revoking the family. Scopes `read` and `draft`; no `write` scope
exists. 401 for expired/revoked/wrong audience; 403 `insufficient_scope` for
step-up. Many connections per student (claude.ai, iPhone, Desktop, Code),
one row each, keyed by the issuing authorization, not the client id; Smooth
shows a "connected apps" list with last-used time and revoke. RFC 7009
`/revoke`. Revoke everything on Canvas disconnect and account deletion.

**One open mechanics question: where the metadata lives.** RFC 8414
discovery for an issuer with a path (`https://<ref>.supabase.co/functions/v1/agent-auth`)
is conventionally `https://<ref>.supabase.co/.well-known/oauth-authorization-server/functions/v1/agent-auth`,
a root path Edge Functions cannot serve. The MCP spec also lists the
path-appended forms (`<issuer>/.well-known/oauth-authorization-server` and
`<issuer>/.well-known/openid-configuration`), which a function can serve.
The PRM is fine: the 401 header names its URL explicitly, and Supabase's own
guide points it at `/mcp/oauth-protected-resource`. Phase 0 must check that
Claude accepts a path-appended AS metadata URL; if not, serve the two static
metadata JSON files from a domain we control (the issuer becomes that
origin; the endpoints inside it point at the functions).

**Mobile.** No primary source says which browser the Claude iPhone app
uses for OAuth. Safari drops script-initiated custom-scheme redirects
without a user gesture, so the page's "Open Smooth" is a real button; also
show the QR (laptop case) and a typed 8-character code (fallback, RFC 8628's
consonant alphabet). After approval the page polls and redirects itself;
the student returns to Claude by hand, so the page says so. Test on a
device in Phase 0.

## 4. The phone submits: Canvas write path, read from source

Sources: READ canvas-lms master `lib/canvas/request_forgery_protection.rb`,
`app/controllers/application_controller.rb` (`in_app?` line 2942,
`api_request?` 2357), `lib/authentication_methods.rb` (CSRF cookie refreshed
on every request, 192; `LoggedOutError` → 401, 448),
`gems/canvas_breach_mitigation/.../masking_secrets.rb`,
`app/controllers/submissions_controller.rb`, `submissions_api_controller.rb`
(`create_file` 694), `files_controller.rb` (184), `lib/inst_fs.rb`,
`lib/api/v1/attachment.rb`, `app/models/submission.rb` (1970),
`ui/shared/apollo-v3/index.js`, `app/graphql/mutations/create_submission.rb`,
`doc/api/file_uploads.md`, `config/routes.rb`.

**Cookie-session writes work, with the header Canvas's own UI sends.**
`verified_request?` passes GET/HEAD, passes bearer API calls
(`api_request? && !in_app?`), and otherwise needs `X-CSRF-Token` (or the
form param). A `canvas_session` request is in-app, so a POST to `/api/v1`
needs the header. The header value is the `_csrf_token` cookie value,
percent-decoded, as is; the cookie already holds the masked token and the
server unmasks both sides. The cookie is re-set on every request, so GET
first, then read the current value from the jar. Canvas's React UI does
exactly this for `/api/graphql` (`X-CSRF-Token: getCookie('_csrf_token')`,
`credentials: 'same-origin'`). No Origin/Referer check exists in Canvas's
override; send same-origin values anyway. Failure shapes: 422 JSON =
CSRF/validation; 401 = dead session; HTML or 3xx = a controller
`flash + redirect` (locked assignment, empty text body) and must be treated
as failure, never followed.

**What this repo has** (REPO): `CanvasAuth.apply` attaches cookies with
`HTTPCookie.requestHeaderFields` (`Canvas/CanvasAccessToken.swift:371-379`);
`CanvasGradesClient` sets `httpShouldHandleCookies = false`, maps 401 and
HTML bodies to `sessionExpired` (`CanvasGradesClient.swift:180-195`);
`SessionCookieStore` keeps every Canvas cookie by name with a 24-hour max
age (`SessionCookieStore.swift:427, 569-585`), and `_csrf_token` is read
today only inside the gated token-minter's JavaScript
(`CanvasAccessToken.swift:223, 232`). There is **no multipart helper
anywhere** in Kit, UI or App. Whether `_csrf_token` is actually in the
saved jar on a real phone is unverified (only fixtures show it); if it is
not, one GET to `api/v1/users/self` before the POST re-issues it, and the
response's `Set-Cookie` has to be captured since cookie handling is off.

**Preflight, always.** `GET /api/v1/courses/:cid/assignments/:aid?include[]=submission&include[]=can_submit`.
Abort unless the intended type is in `submission_types`, `locked_for_user`
is false, `can_submit` is true, and attempts remain (`allowed_attempts`
−1/nil = unlimited; the limit error is a bare 400
`{"attempt":["you have reached the maximum …"]}`). Check `allowed_extensions`
client-side (lowercase, no dot). Not submittable through the API: anything
whose only route is `external_tool`, `online_quiz`, `discussion_topic`,
`on_paper`, `none`, `not_graded`, or `is_quiz_assignment: true` (New
Quizzes). Gradescope-linked rows presumably appear as `external_tool` with a
Gradescope URL in `external_tool_tag_attributes` (inference; test one).

**Text and URL.** `POST /api/v1/courses/:cid/assignments/:aid/submissions`,
JSON body `{"submission":{"submission_type":"online_text_entry","body":"<p>…</p>"}}`
or `{"submission":{"submission_type":"online_url","url":"https://…"}}`.
Exactly the documented keys per type; any other key is a 400. Expect 201
with Submission JSON: `attempt`, `submitted_at`, `workflow_state:
"submitted"`, `late`, `attachments`. Every POST is a new attempt.

**Files, three steps per file, all inside 30 minutes.**
1. `POST …/assignments/:aid/submissions/self/files` JSON
   `{"name","size","content_type","on_duplicate":"rename","submit_assignment":false}`,
   cookies + CSRF. Extension check happens here. Submission uploads do not
   count against the student's quota.
2. `POST <upload_url>` as `multipart/form-data`: `upload_params` entries in
   order, `file` last. **No Canvas cookie, no CSRF, no bearer.** The URL is a
   signed S3 or InstFS URL (`…/files?token=<JWT>`), or a Canvas URL whose
   controller skips CSRF. Do not auto-follow the redirect.
3. `GET <Location>` with cookies; read the File `id`.
Then `POST …/submissions` with `submission[submission_type]=online_upload`
and `submission[file_ids][]=<id>` per file.

**Verify.** `GET …/assignments/:aid/submissions/self`: `attempt` is previous
+ 1, `submitted_at` recent, `workflow_state` `submitted` (later `graded` /
`pending_review`), `attachments[]` holds the ids. If the 201 arrived but the
re-GET lags, re-GET a few times over a few seconds. **Never auto-retry the
POST after an ambiguous result**: a retry is a second attempt. 422 → refresh
the CSRF value and retry once; 401 → session dead, stop; 400 → show the
message, stop.

**Fallbacks.** GraphQL `createSubmission` at `/api/graphql` is the same
mechanism (cookie + CSRF, same `submit_homework`, same attempts rule) and
still needs the REST file upload, so it buys nothing. A hidden WKWebView
driving the web form is the last resort.

**Where to test.** Never a graded Penn assignment. A Canvas Free-for-Teacher
course (canvas.instructure.com) with a student test user works because the
clients take a base URL; or a Penn course Marco controls. The first real
submission is Phase 4's acceptance test.

## 5. Drafts: from the agent to the card

**Receiving a file from the agent.** There is no interoperable client-to-server
file primitive in MCP: SEP-2356 (`inputFiles`) and SEP-2631
(`files/authorizeUpload`) were both closed (READ, the PRs; the work moved to
an experimental extension no host implements). The de facto pattern is
base64 in a tool argument: Google Drive's connector `create_file` takes
`base64Content` + `contentMimeType` (READ, its tool schema). ChatGPT has its
own `_meta["openai/fileParams"]` download URL (SUMMARY). No Claude document
states a size limit on tool arguments. So: `propose_submission` takes
`file_base64`, `file_name`, `mime_type` with a hard cap stated in the
description (start at 1.5 MB; Phase 0 measures what Claude.ai and the iPhone
app will actually send, and whether the Edge Function's 2 s CPU survives
the decode). The function writes bytes to a private Supabase Storage bucket
and the row keeps the path. A two-step signed-upload-URL design only if
testing shows Claude can issue a PUT, which the research doubts.

**Getting the draft to the phone.** Remote push does not exist in the app:
no `aps-environment`, no `registerForRemoteNotifications`, background modes
`fetch` only (REPO, `App/LHFApp.entitlements`, `Info.plist:52-54`). Adding
APNs is a project of its own. So the phone **polls**: on launch
(`RootView.swift:186`) and inside the 5-minute refresh (`ContentView.swift:775`),
the same hooks `deviceSyncPass` uses (`AppState+DeviceSync.swift:225`). A
draft found during a foreground refresh posts a local notification ("Claude
drafted PHYS 0151 HW 4"). This matches the product: the draft is waiting
when you open the app. Background wakes are off the table until the
background-refresh crash is fixed (CLAUDE.md trap).

**Where it shows.** The dashboard card (`AssignmentCardView.swift`, `body`
148, `content` 214) gets a provenance chip like the applied-fact "source
words" line (`sourceText`, 360-364). The opened card (`expandedDetail`,
320-437) gets a draft section between the fact rows (369-375) and the
source links (387-405): the agent's name, a preview (text inline, a file via
QuickLook), and one button, **review and submit**, opening a full-screen
sheet that shows exactly what will be submitted, the assignment and due
date, one line about academic integrity, Submit, Decline. Apple's HIG on
generative AI (READ): "Clearly identify when and where you use AI", let
people "dismiss new content" and "revert or retry", show "what's shared".
Patterns worth copying: a distinct drafts count on the dashboard (the
megaphone's unread-badge pattern), a provenance chip on every draft, the
human taps the final submit, dismiss/decline on every draft. Copy stays
minimal, in the owner's register.

**Draft states.** `proposed → seen → submitted | declined | failed`. The phone
marks `seen` when the card opens, writes a `SubmissionAttempt` row
(SwiftData, the `AppliedFactStore` pattern, its own store, never the ledger
schema) **before** the POST, then `submitted` with the Canvas submission id
and attempt, or `failed` with the error class. The agent can read
`draft_status`. A draft with an attempt row is never submitted twice.

## 6. Client reach, as of 2026-11-08

| Client | Custom remote MCP | Notes |
|---|---|---|
| Claude web, iPhone/Android, Desktop, Cowork | Yes, all plans (Free: one connector) | Added on web, usable everywhere (READ support article). Third-party guides say add on web first; mobile setup "beta" (SUMMARY). |
| Claude Code | Yes | `claude mcp add --transport http`; claude.ai connectors also surface there (READ). |
| Claude Duet | Unverified | No primary source found; assume the shared client. |
| ChatGPT Free | No | |
| ChatGPT Plus / Pro | Conflicting | Guides disagree on read-only vs full; OpenAI's own page returned 403/404 (SUMMARY). |
| ChatGPT Business / Enterprise / Edu | Yes, admin-gated | Penn's ChatGPT Edu is Wharton-run, MBA/PhD and Wharton-course students only; "Only Wharton-approved connectors may be used" (READ). |
| ChatGPT Apps directory ("plugins") | Submission path exists | Privacy policy with retention and recipients, transparent login, demo account (READ app-submission-guidelines). |
| Gemini consumer | Unverified, conflicting | Do not promise. |

Claude directory listing (claude.ai/directory/manage, paid plan to submit):
HTTPS + OAuth, `title` and `readOnlyHint`/`destructiveHint` on every tool,
privacy-policy and docs URLs, a populated test account, seven compliance
acknowledgments; auto-scanned and listed as "Community" by default (READ
claude.com/docs/connectors/building/submission). Worth doing once Phase 2
works, so students find "Smooth" by name instead of pasting a URL.

## 7. Privacy, disclosure, review

**What the server will hold, per opted-in student** (`agent_snapshots`, RLS by
`auth.uid()`, written by the phone, deleted on opt-out, Canvas disconnect and
account deletion): for each work item an opaque id, course code, title,
kind, due date (with the student's edits applied), done flag,
nothing-to-submit flag, the Canvas assignment URL (never a feed URL, which
carries a token), and source; the course list (code, shown name, Canvas
course id); manual tasks. **Never**: grades or scores, the student's name,
cookies or tokens, submission bodies other than the drafts the agent itself
created. Syllabi, pages, announcements, Ed posts and facts are already
pooled per course and are served through the student's `enrollments`.
Wharton's own data tiers (READ) allow a commercial agent "Low" data only
and prohibit FERPA-grade data; grades and names are the FERPA-type fields,
and they stay off. Retention: purge on disconnect; expire done items after
a fixed window (the "prev" view's horizon).

**Texts to change in the same commit as the behaviour:** PROTOCOL principle
2 becomes "…never the work list, unless the student turns on an agent
connection, in which case exactly these fields are stored for that student
alone"; `docs/PRIVACY.md` gets an "agents" section saying what is shared,
with whom (the agent provider the student chose, by name, plus Smooth's
server), why, how long, and how to stop it; App Review notes describe the
opt-in screen.

**Apple.** 5.1.2(i), verbatim (READ): "You must clearly disclose where
personal data will be shared with third parties, including with third-party
AI, and obtain explicit permission before doing so." 5.1.1(i)/(ii) require
the policy to cover retention and deletion and an easy way to withdraw
consent. Developers report rejections even with a consent screen when the
disclosure was vague about what and to whom (SUMMARY, forum threads
820209, 816140). So the opt-in screen lists the exact fields, names the
recipients, states retention and location, links the policy, has its own
affirmative tap, and the connections list has revoke. Whether a connector
counts as "third-party AI" is unresolved; treat it as if it does. No
published rejections for homework-helper apps were found; the integrity
exposure is Penn's, not Apple's.

**Instructure 2(E)** asks for GAI disclosure and that GAI-generated output be
labelled as such: the "drafted by Claude" chip and the review sheet's line
cover it for the agent's output; the app's own facts extraction is already
disclosed in `PRIVACY.md`.

## 8. What stays unverified until Phase 0

1. Canvas accepts the cookie + `X-CSRF-Token` POST from URLSession on a
   sandbox assignment (source says yes; never run).
2. `_csrf_token` is present in the phone's saved jar after a real login.
3. Claude accepts a path-appended AS metadata URL under
   `/functions/v1/agent-auth/`, or the metadata needs a static host.
4. The Claude iPhone app's OAuth browser lets a button open `smooth://link`.
5. The largest `file_base64` Claude.ai and the iPhone app will send, and
   the Edge Function's CPU time to decode and store it.
6. What Claude shows for `propose_submission` with and without
   `destructiveHint`.
7. Whether Claude speaks the 2026-07-28 wire format yet or only the 2025
   era (the handler serves both; this only matters for logging).

Everything else above is read from a primary source or this repo.
