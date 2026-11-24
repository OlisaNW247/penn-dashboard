# The agent connection, audited, and the personal-AI-account question

2026-11-24. For Olisa, about the work Marco built on `v11` (2026-11-07 to
11-17). An investigation only: no code changed, nothing deployed, no student
row read, no endpoint called as a user. Source notes are in
`docs/research/agent-audit/`. Each claim says whether it was read from the
code, read from the project's docs, checked live, or read from an outside
source.

## Summary

**What exists.** A finished "connected agent" feature. A student adds Smooth
as a connector inside Claude (claude.ai or the Claude apps). The phone
approves the connection. Claude can then read the student's classes, work
list and pooled course material through twelve tools, and leave a draft
(text, a link or a file) on an assignment. The student reviews the draft on
the phone and taps "submit to canvas". Smooth then sends it to Canvas with the
student's own session. It ran end to end once, on Marco's phone, on
2026-11-10.

It is **off in the app and on in the cloud.** 3.5.0 went live on the App Store
on 2026-11-23 at 20:59 UTC (checked live in Apple's public lookup), built with
`FeatureFlags.agentConnection = false`. The three backend functions are still
deployed: `agent-auth` v17, `mcp` v16 and `agent-snapshot` v13, since
2026-11-16. They still answer requests (checked live, see §1.2). They have no
server-side off switch.

**Is it safe as built?** The engineering is careful. Tokens are hashed. The
phone is the only thing that can approve a connection. No code path submits
without the student's tap, and a submission is never sent twice. The gaps are
elsewhere:

- **Consent.** After the 2026-11-11 trim, the consent screen says only
  "connect claude?" above three numbers. The app's privacy link points to a
  version of `PRIVACY.md` that has no agent section. Apple's 5.1.2(i) requires
  clear disclosure and explicit permission before data goes to a third-party
  AI, so the feature as built would likely fail review.
- **Approval phishing.** The approval can be phished.
- **Opt-out offline.** Turning the feature off while offline leaves the
  server's copy and every connection live.
- **Prompt injection.** Course material is self-asserted by any anonymous
  account, and the agent reads it as instructions-shaped text.

All of these can be fixed. The harder problem is policy, not code.

**The one decision.** Should Smooth ever be the thing that submits
AI-drafted coursework? My recommendation is no:

- Keep the reading half as a read-only connector, which is the shape both AI
  vendors sanction and the one Claude's directory lists.
- Retire drafts and phone-side submit.
- Meanwhile, stop the live backend from accepting connections, because nobody
  outside the team can use it and it holds a readable copy of Marco's work
  list.

This is a decision for you and Marco. Nothing has been changed.

**Personal accounts.**

- Smooth cannot run its own features on a student's Claude subscription.
  Anthropic forbids it in writing and has enforced it.
- On a ChatGPT plan it is partner-only.
- The sanctioned way to spend a student's own plan is the reverse direction:
  the student's Claude uses Smooth as a connector. That is exactly what Marco
  built.
- For Smooth's own "ask", the cheap, account-free routes are Apple's
  on-device model and Private Cloud Compute, plus Anthropic App Attest. Not
  account linking.
- A student's AI can still power parts of Smooth from the front: a daily
  brief, a study plan, summaries, Smooth cards inside the chat. The route
  with no server copy of the work list is Shortcuts. See Part 3.

---

## Part 1. What Marco built

### 1.1 The flow, in plain words

Sources: the code on `origin/v13` (identical to `v11` apart from the off-switch
guards), `docs/V11_RETURN_2026-11-11.md`, `backend/PROTOCOL.md` → "The agent
connection", and the screenshots in `docs/v11-ui/`.

1. **Connect.** In Claude's settings the student adds the connector
   `https://smooth-agent.vercel.app/functions/v1/mcp`. That address is a small
   Vercel proxy under Marco's account, `backend/connector-front/`, which
   forwards to Supabase. Claude runs a standard OAuth 2.1 sign-in against
   `agent-auth`, Smooth's own authorization server. Smooth's sign-in page shows
   a short code, a two-digit number, and an "Open Smooth" button.
2. **Approve on the phone.** Smooth opens on "connect claude?" with three
   numbers (`docs/v11-ui/light-12-approve-sheet.png`). Picking the matching
   number approves; a wrong one denies. Students have no Smooth login, so
   "the phone approves" is the identity. Approving turns on Profile →
   "connected agent" (`light-07-profile-agent-on.png`). Agents can be
   disconnected there one by one or all at once.
3. **The phone uploads the work list.** While the feature is on, the phone
   uploads the student's work list to the server (`agent_snapshots`), at most
   every 10 minutes and only in the foreground. The list is courses, work
   items (title, due date, done flag, Canvas ids and links) and own tasks.
   Grades, names and cookies are refused by the server.
4. **Claude reads and drafts.** The MCP server's tools, read from
   `_shared/agentTools.ts:490-794`:

   | Tool | What it returns or does |
   |---|---|
   | `list_courses` | course code, name, Canvas course id |
   | `list_work` | the snapshot's items for a view or course: id, course, title, due, done, kind |
   | `get_assignment` | one item, its source and link, the pooled description (up to 12,000 characters), up to 4 attached PDFs as text, and the facts that apply |
   | `search_course_material` | 600-character excerpts from pooled syllabi, pages, announcements, Ed posts, website and file documents |
   | `get_facts` | the course facts (cancelled, moved, new task…) |
   | `get_announcements` | pooled announcements, 8,000 characters each |
   | `get_ed_posts` | pooled Ed staff, announcement and pinned posts |
   | `draft_status` | the state of a draft it made |
   | `propose_submission` | **the write:** leaves a draft (text up to 100k characters, an https link, or a file up to 1.5 MB) on one item; at most 20 open |
   | `begin_file_upload`, `append_file_chunk`, `finish_file_upload` | upload a file for a draft in checksummed chunks or one signed PUT |

   No tool submits, marks anything done, or touches Canvas. The server never
   talks to Canvas.
5. **The draft reaches the card.** The phone polls for drafts every 5 minutes
   in the foreground. The card gets "drafted by claude" in grape, and the
   phone sends one local notification ("Claude drafted Problem Set 7").
6. **Review and submit.** "Review and submit" opens the review sheet
   (`light-14-review-text.png`, `light-15-review-textFileOnly.png`,
   `light-16-review-file.png`, `light-17-review-link.png`). The sheet shows
   the class, the title, "drafted by claude", the draft, and one line saying
   what Canvas takes. The student taps "submit to canvas", then confirms ("send
   problem set 7 as a pdf?").

   The phone then submits:
   - It makes a preflight GET for the assignment's rules.
   - It writes an attempt record to disk.
   - For a file, it uploads to Canvas's three-step upload slot.
   - It POSTs the submission once, never retried.
   - It makes a verify GET.

   A text draft for an assignment that only takes files is rendered to a PDF
   on the phone. The card then moves to prev as "submitted by you · drafted
   by claude" (`light-04-prev-submitted-by-you.png`). Outcome states are
   shown in `light-21` to `light-23`.

It worked once, for real. On 2026-11-10 at 22:52 ET, Claude drafted Marco's
PHYS 0151 Problem Set 7 from the pooled PDF. The phone rendered it and
submitted it to Canvas (submission 357257138, attempt 1, per commit `3f9d861`;
not fetched here). That is Marco's own work in a graded course. The project's
own rule for the first submit had been "a Canvas sandbox … never a graded
assignment" (CLAUDE.md Known gaps). It is worth knowing, not worth chasing.

### 1.2 State today

| Fact | Value | How known |
|---|---|---|
| Newest line | `origin/v13`, "Record v13's first green run: 4536 / 479" (2026-11-24). `claude/new-session-b3ylkg` is newer but is a work-in-progress session branch, not a line | git, read |
| Live app | **3.5.0, released 2026-11-23 20:59:10 UTC** | **checked live**, `itunes.apple.com/lookup?id=6783911002` |
| Flag in the 3.5.0 archive (`0615d3a`) | `agentConnection = false` | read from that commit |
| Deployed functions | `agent-auth` v17, `mcp` v16, `agent-snapshot` v13, `delete-account` v20, since 2026-11-16 02:48 UTC, four agent migrations applied | from CLAUDE.md on `v13`; **not checked live**, because no Supabase management token is on this Mac (`~/lhf-bench` does not exist) |
| Backend accepting requests | the front serves its OAuth discovery document (200), and an unsigned call to `/mcp` answers 401 with a `WWW-Authenticate` bearer challenge, i.e. the function is up and would accept a token | **checked live** 2026-11-24 04:07 UTC; no token sent, no sign-in started |
| Server-side switch | none. The functions read only `SUPABASE_*`, `LHF_AGENT_PUBLIC_BASE`, `LHF_MCP_PROPOSE_HINT`, `LHF_FRONT_CLIENT_IP_SECRET` | code, `grep Deno.env.get` |
| Data on the server | Marco's snapshot and connection are still there ("The server still holds Marco's snapshot and connection", CLAUDE.md Known gaps) | docs |

**What the phone shows with the flag off (3.5.0).** There is no Profile
section, `smooth://link` opens nothing, the snapshot and drafts passes don't
run, there is no chip, no review sheet and no notice. The two readers that
leaked a cached draft past the flag were closed on 2026-11-17
(`docs/V12_ISOLATION_2026-11-17.md`).

One cleanup is missing from 3.5.0. A one-shot pass that deletes the server
copy for a phone that had opted in (`agentOffSwitchCleanupPass`) was added only
on `v13` on 2026-11-24 (`0d92da7`), so it is **not in 3.5.0**. A 3.5.0 phone
that had opted in leaves its snapshot and connections live until a Canvas
disconnect. In practice that is Marco's phone only.

**What a `v11` build could still do.** A Debug build with the flag on (only
Marco's phone is recorded as ever having one) talks to the same live backend:

- it can approve new connections;
- it uploads its snapshot;
- it polls drafts;
- it submits to Canvas.

Nothing on the server tells it no. No `v11` build was ever uploaded to the
App Store. TestFlight is not recorded either way.

**Does the backend accept new connections while the app hides it?** Yes. Any
Claude user can add the URL and reach the sign-in page. A connection is only
approved from a phone running a build with the flag on, so in practice no new
student can connect. The endpoints, the token store and Marco's data are
still live and reachable.

### 1.3 Security and privacy review

A separate read-only review of the code (full notes in
`docs/research/agent-audit/security-review.md`). I re-checked findings 1, 3
and 5 in the source myself. The 2026-11-11 hostile test
(`docs/V11_TEST_BACKEND_2026-11-11.md`) had already found and fixed four
issues; the fixes are in the code.

**What is done well** (code):

- **Tokens.** Opaque 256-bit tokens, stored only as SHA-256 hashes. Access
  tokens last 1 hour, refresh tokens 60 days with rotation, and reusing a
  refresh token revokes the connection.
- **OAuth.** PKCE S256 only. Exact redirect matching. Tokens are bound to the
  MCP URL (RFC 8707). Every MCP call re-checks the connection's `revoked_at`.
- **Isolation between students.** Every query is scoped by the user id on
  the token row. No tool argument can name another student.
- **No submit without a tap.** The only caller of `CanvasSubmissionClient.submit`
  is the review sheet's confirmed button (`AgentDraftReviewSheet.swift:552`).
  The target ids come from the phone's own item, not from the agent.
- **No double submit.** The attempt record is written atomically before the
  POST, and the POST is never retried, not even after a 422. A crash between
  the record and the POST reads "check canvas" and never re-sends.
- **Grades and names stay off the server.** The server refuses them in the
  snapshot.

**Issues found** (severity is mine, for shipping as built):

| # | Severity | Where | Issue |
|---|---|---|---|
| 1 | **High (to ship)** | `AgentLinkApproveSheet.swift:11-17`, `ProfileAgentRows.swift`; `AgentConnectionCopy.privacyURL` (`AgentLinkApproveSheet.swift:29`) | **Consent does not meet Apple 5.1.2(i).** The approve sheet says only "connect claude?" and shows numbers. The line "shares your classes and work list with the agent's provider" and "reads your classes and work, proposes drafts" were removed on 2026-11-11 ("remove all of the little bullshit text"). The only disclosure is a link to `PRIVACY.md` **on branch `v10`**, which has no agent section (checked: 0 matches on `v10` and `main`). |
| 2 | High (pre-existing, made worse) | `sync/index.ts:348-358`, PROTOCOL "Limitations"; read by `agentToolsPostgrest.ts:177-343` | **Course enrollment is asserted by the client.** Any free anonymous account can claim a course and upload a document into its pool. Every classmate's agent then reads that document through four tools. A planted "ignore previous instructions…" reaches an agent that may also hold the student's Gmail or Drive connectors. Smooth's own tools can only produce drafts the student must review, but the student's other connectors are outside Smooth's control. |
| 3 | Medium | `AgentLinkApproveSheet.swift:152-181`, `agent-auth/index.ts:719`, `_shared/agentAuth.ts:238` | **Approval can be phished.** The name shown ("claude") is whatever the registering client chose. Any web page can open `smooth://link?c=…`. An attacker who starts a sign-in sees the number and can tell a victim "tap 48". The victim's work list then goes to the attacker. Number matching stops a relayed QR code, not a number someone tells you. The fix is to show the client's verified host and what it will read, and to require a fresh number. |
| 4 | Medium | `AppState+AgentConnection.swift:48-60`; `AppState.swift:5539` | **Opt-out offline leaves everything live.** Turning the feature off writes the local flag, then calls `deleteSnapshot` with `try?` and never retries. The off-switch cleanup does not catch this case, because it only runs while the opt-in is still true. Offline, the UI says off while the server copy and every connection stay live. The same applies to the delete on Canvas disconnect. |
| 5 | Medium | `migrations/20261109090000_agent_hardening.sql`; `agentTokens.ts:24` | **Nothing expires.** No server-side expiry for snapshots or connections. A refresh token renews for 60 days from each use, so an agent that keeps refreshing reads a stale work list indefinitely after the app is deleted or the phone is lost. The student has no account to revoke it from. |
| 6 | Medium | the three functions | **No server-side kill switch** (§1.2). Turning the feature off means removing the functions or changing code. |
| 7 | Low | `AppState+AgentDrafts.swift:112-120`, `AgentDraftSubmitter.swift:53-61` | **Old drafts resurface.** After draft A is submitted, an older open draft B for the same item surfaces on a card that is already done. A second Canvas attempt then takes two taps. The server never dedupes. |
| 8 | Low | `AgentSubmitAttemptStore.swift:67-80`, `AppState+AgentDrafts.swift:329` | **Two devices can submit the same draft.** Attempt records are per device, so two installs holding the same draft can each submit. Opting out erases the records even when the server delete failed. |
| 9 | Low | `_shared/agentDrafts.ts:226-257` | **Decided drafts are kept forever.** A decided draft keeps its body, link and note until opt-out or account deletion. Students' essays sit on the server indefinitely. |
| 10 | Low | `V11_TEST_BACKEND` items 5-12 | Left as designed: the draft cap overshoots under concurrency, `mcp` has no rate limit, two simultaneous refreshes revoke the connection, and replaying a used code does not revoke the tokens it already issued. |
| 11 | Low | `propose_submission` annotations | **Write tool not marked destructive.** The write tool is `destructiveHint: false` by default. Claude's directory wants writes marked. `LHF_MCP_PROPOSE_HINT=true` flips it. |
| 12 | Info | the front | **The proxy sees every bearer token in clear.** Vercel, under Marco's personal account, is in the trust path. |
| 13 | Info | `docs/appstore/CHECKLIST.md:267` | The example `changes` list for the update wall still reads "connect an agent", "drafts you review and submit". If it is copied as-is, the wall advertises a feature that is not in the build. The live manifest is clean. |

**What leaves the phone, and where it is stored.**

| Data | Where it goes | How long it stays | When it is deleted |
|---|---|---|---|
| Work list, courses, own tasks | `agent_snapshots` on the server, plaintext | replaced on each upload | opt-out, Canvas disconnect, account deletion (all three best-effort from the phone, issue 4) |
| Drafts (text, link, note) | the server | until opt-out or account deletion (issue 9) | as for the work list |
| Draft files | a private bucket | deleted once the student decides | stray uploads swept since 2026-11-16 |
| Everything an agent reads | the agent's provider (Anthropic or OpenAI) | under the provider's terms, which Smooth cannot shorten | not by Smooth |

**Is it disclosed honestly?**

- `docs/PRIVACY.md` on `v13` describes the feature accurately and says it is
  off in this build. Two problems: the app never links to that version, and
  its "a phone … asks the server once to delete" sentence is only true from
  `v13`, not in 3.5.0.
- `docs/appstore/REVIEW_NOTES.md` and the privacy label leave the agent out,
  which is correct for 3.5.0.

**Prompt injection, plainly.** Course text is untrusted, and partly anyone's
(issue 2). The agent can only make drafts, and the student must read and tap.
So Smooth's own worst case is a misleading draft, for example a phishing link
as a "link draft", or wrong content that a student submits without reading.
Data can still leave through the student's other connectors, which Smooth
cannot see.

### 1.4 Policy

Sources: `docs/research/agent-audit/apple-canvas-penn-policy.md` and
`ai-accounts-and-directories.md`. I re-read the three AI-vendor quotes on the
live pages on 2026-11-24.

- **OpenAI's Usage Policies** (effective 2026-11-20) list **"academic
  dishonesty"** as a prohibited use. They also prohibit "automation of
  high-stakes actions in sensitive areas without human review", naming
  "submissions" and education
  ([openai.com/policies/usage-policies](https://openai.com/policies/usage-policies/)).
  The human-review half is satisfied by the student's tap. The first half
  depends on each course.
- **Anthropic's Usage Policy** (effective 2026-11-12) bars users to
  "Plagiarize or submit AI-assisted work without proper permission or
  attribution" ([anthropic.com/legal/aup](https://www.anthropic.com/legal/aup)).
  Smooth's "drafted by claude" label is seen only inside Smooth; **Canvas and
  the instructor never see it.** The review sheet's line "this goes in under
  your name; read it" was also removed on 2026-11-11. So Smooth supplies no
  attribution where it would count.
- **Penn.** Penn has no university-wide AI rule; instructors decide what is
  "unauthorized assistance" (CETLI, *Creating AI policies*). The Code of
  Academic Integrity's own page answered 403 to our reader, so that text was
  not read directly. Wharton's Agentic AI Guidelines (modified 2026-11-04,
  cited in Marco's research §1) say a PennKey session "is NOT an appropriate
  mechanism" for agent access. Smooth's design keeps the session away from the
  agent, which honours the letter of that. A tool whose purpose is to turn an
  agent's draft into a Canvas submission in two taps sits uneasily with its
  spirit.
- **Apple.**
  - **5.1.2(i)**, clarified November 2025: you must "clearly disclose where
    personal data will be shared with third parties, including with
    third-party AI, and obtain explicit permission". This is issue 1.
  - **5.2.2**: you must be "specifically permitted to do so under the
    service's terms of use. Authorization must be provided upon request." This
    is a standing exposure of the whole app, which reads Canvas with a
    student's session. A write path raises the stakes.
  - No guideline addresses academic dishonesty.
- **Instructure.**
  - The API Policy (effective 2025-08-12) bars MCP servers "not approved by
    Instructure" that connect to its APIs, and use "on behalf of any
    third-party". Smooth's MCP server does not call Canvas; the phone does,
    in the student's own session. Marco's research calls this "a reading, not
    a ruling", and that is right.
  - Canvas told press it is "actively researching approaches for institutions
    and faculty to manage outside agent interaction with Canvas". Session-based
    writes are exactly what that would target.
- **Directory listings.**
  - **Claude's directory:** any paid plan can submit. It requires OAuth, a
    `title` and annotations on every tool, privacy and support URLs, a
    populated test account, and seven acknowledgements. Listings get an
    automated scan and appear as "Community".
  - **ChatGPT:** a verified publisher, a demo account without MFA, and
    explicit annotations. On ChatGPT Pro, custom MCP servers are **read/fetch
    only and web only** ("Full MCP is not available"), so `propose_submission`
    would not work there at all.
  - **The test account** is unsolved for both: the only sign-in is a Penn
    student's phone (`docs/CONNECTOR_LISTING_CHECKLIST_2026-11-10.md`).

### 1.5 Recommendation (a decision for you and Marco)

**Change, then ship later: as a read-only connector, without drafts or
submit.** Reasons:

1. **Policy.** The read half fits every rulebook above. The draft-and-submit
   half runs into OpenAI's "academic dishonesty", Anthropic's attribution
   rule (the label never reaches Canvas), per-course Penn rules, Instructure's
   stated interest in outside agents, and ChatGPT Pro's read-only limit.
2. **Product.** A student whose Claude can see every due date, syllabus,
   announcement and Ed post already gets most of the value. They can paste or
   upload the answer in Canvas themselves.
3. **Cost.** It removes Smooth's first and only Canvas write path, which is
   the riskiest code in the app and has run once.

If you and Marco want to keep drafts, the minimum is:

- an honest consent screen;
- the integrity line restored;
- never offering submit on quizzes or exams;
- the syllabus's own AI sentence shown on the review sheet (Marco's
  extension §14).

**What has to be true before any version ships:**

1. A consent screen that names the recipient (Anthropic or OpenAI), lists the
   exact data, says how long the server keeps it, links a served privacy page
   that contains the agent section, and has its own affirmative tap
   (issue 1).
2. Opt-out that retries until the server confirms the delete; server-side
   expiry of snapshots and connections after N days unused (issues 4, 5).
3. A server-side off switch (an env flag the three functions honour).
4. Approval that shows the client's verified host and what it gets
   (issue 3).
5. A plan for injected course text: at least label pooled text as untrusted
   in tool results, and stop serving material from a course the student
   cannot prove they are in (issue 2; this one also protects ask).
6. A test account path for directory review.
7. A hosted privacy page, support page and terms (ChatGPT requires terms).

**Should the deployed backend be turned off now?** I recommend yes:
undeploy, or add the off switch and set it. Nobody outside the team can use
it. It holds a live, readable copy of Marco's work list and his draft rows. It
is attack surface with no users. Turning it back on is a single deploy
(`deploy-agent.mjs`). This is a production change, so it needs Marco's go
and yours; I have not done it. If it stays up, at least ship the `v13`
off-switch cleanup in 3.5.1 and delete Marco's snapshot by hand.

---

## Part 2. A student's own Claude or ChatGPT, through Smooth

This starts from your `docs/AI_ACCOUNT_LINKING.md` (2026-10-21). Every claim
there was re-checked on 2026-11-23/24
(`docs/research/agent-audit/ai-accounts-and-directories.md`). The direction
holds; three things moved, and each is marked **new**.

| | Allowed? | What a student gets | Cost to Smooth | Privacy | Effort | Verdict |
|---|---|---|---|---|---|---|
| **(a) Smooth uses the student's subscription to answer in-app** | **Claude: no.** "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, Max, or Ultra plan credentials on behalf of their users"; developers "may not collect, store, or intermediate Claude.ai credentials or session tokens" ([code.claude.com legal](https://code.claude.com/docs/en/legal-and-compliance), re-read live; **new:** the list now names an "Ultra" plan). **ChatGPT: partner-only.** "Sign in with ChatGPT" plan usage launched 2026-09-29 with "a limited set of partners"; commercial apps "must submit an interest form" ([help.openai.com 20001542](https://help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites)); **new:** eligible tiers now read Go, Plus, Pro, Business | Answers on their own plan | none, if admitted | the question and context go to OpenAI under the student's account | weeks, only after admission | **Claude: cannot be built. ChatGPT: file the interest form, plan nothing.** |
| **(b) The student's own Claude/ChatGPT uses Smooth (connector)** | **Yes, the sanctioned shape.** Claude: an unlisted remote connector can be added by URL on every plan, Free included (one connector), and works on web, desktop and mobile ([add-unlisted](https://claude.com/docs/connectors/custom/add-unlisted.md)). ChatGPT: custom MCP is **read/fetch-only on Pro and web-only** ([help 12584461](https://help.openai.com/en/articles/12584461-developer-mode-and-mcp-apps-in-chatgpt)); full MCP is for Business/Enterprise/Edu | Their own Claude, knowing their classes; their plan pays | hosting only (Supabase, Vercel); no inference | breaks "the work list never leaves the phone" for those who opt in; disclosed | **built** (Marco's `v11`) | **Yes, read-only, Claude first** (Part 1.5). |
| **(c) Bring your own API key** | Anthropic: a user's own key "billed to the key owner" fits the terms; no resale or intermediation. OpenAI: no rule for a user's own key in a client. Apple: a key that "unlocks or enables functionality" was rejected under 3.1.1 in a paid app (forum thread 763884); free BYOK clients ship | ask on their own key | none | the key must never leave the phone (5.1.1(v), and the OpenCode key breach of 2026-10) | 1–4 weeks (the phone would have to build ask's prompt itself) | **Power-user extra at most; almost no student has a funded key.** |
| **(d) Platform routes, no account** | **Apple on-device model:** free; iPhone 15 Pro or later. **Private Cloud Compute:** open to third parties since iOS 27 (shipped 2026-09-14), free for Small Business Program developers under 2 million first-time downloads, with a per-user daily cap ([Apple newsroom](https://www.apple.com/newsroom/2026/06/apple-aids-app-development-with-new-intelligence-frameworks-and-advanced-tools/)). **Anthropic App Attest:** exists, in beta, iOS 27; installs call Claude "without shipping an API key or running a proxy", billed to **Smooth's** workspace ([docs](https://platform.claude.com/docs/en/manage-claude/app-attest.md)). Apple's ChatGPT integration: not open to apps | ask with no account at all | PCC: $0 at Smooth's size; App Attest: Smooth pays per token, as today | PCC stores no prompts; App Attest same data as today's ask, minus Smooth's server | PCC 2–3 weeks; App Attest similar | **PCC is the best free default for ask; App Attest only if the server should go.** |

**Recommendation.** Don't try to put a student's subscription behind Smooth's
own features. For Claude it is forbidden and enforced; for ChatGPT it is a
partner programme Smooth is not in. "Use your own Claude with Smooth" already
exists in the one sanctioned form, the connector Marco built. Ship it
read-only once the consent and switch work in Part 1.5 is done, and list it in
Claude's directory. For ask itself, keep paying (a small cached model costs
fractions of a cent per question) and add Private Cloud Compute as the free
path on iOS 27 phones.

---

## Part 3. Which parts of Smooth a student's own AI could power

Added 2026-11-24, at Olisa's ask: "the possibility of using personal Claude
to power some of a student's Smooth app … or ChatGPT or any other personal
AI". Notes: `docs/research/agent-audit/personal-claude-anthropic-routes.md`,
`personal-ai-apple-routes.md`, `personal-ai-other-providers.md`. The
surprising claims were re-read on the live pages.

**The short answer.** No consumer AI plan can sit *behind* Smooth's own
screens. A student's AI can sit *in front of* Smooth, and from there it can
do real work for the app: answer from the student's classes, show Smooth
cards inside the chat, run every morning, and write results back for Smooth
to display. So "powered by your own Claude" is buildable for some features,
as long as the AI app is where the thinking happens.

### 3.1 Routes that put the student's plan behind Smooth's own screens

| Route | Status | Why it does or doesn't work for students |
|---|---|---|
| Claude subscription login | **Forbidden** | "Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits" ([Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview)). No public application form or partner list; the legal page points to sales |
| Claude Platform OAuth, "Linked billing" (**new**, beta) | Exists, wrong audience | Users "click a Link your Claude organization button, sign in to Claude, and approve your app", and their organization pays ([overview](https://platform.claude.com/docs/en/manage-claude/oauth-apps/overview)). But the approver needs the Admin or Billing role in an organization that buys API credit directly. Subscription-only accounts are refused (403 `user_profile_not_billable`), and the Max/Ultra/Team monthly API credits "can't pay for these requests" ([linked billing](https://platform.claude.com/docs/en/manage-claude/oauth-apps/organization-billing-connections)). A student with Claude Pro cannot use it |
| ChatGPT plan usage ("Sign in with ChatGPT") | Partner-only | "We've launched with a limited set of partners"; commercial apps apply by interest form. The only documented redirect is a loopback on `127.0.0.1`, so a native iPhone app is not a documented target. Requests cannot carry a system prompt, which ask relies on |
| Gemini subscription | No route | Nothing spends a user's Gemini plan from another app. Firebase AI Logic bills the developer |
| Student pastes an API key | Possible, poor fit | Anthropic and OpenAI keys work but almost no student has a funded one. Max/Ultra plans include $100/$200 of monthly API credit, Pro and Free none ([credits](https://platform.claude.com/docs/en/about-claude/api-credits-for-subscribers)). Google's free key is ruled out by its own terms: "Do not submit sensitive, confidential, or personal information to the Unpaid Services" |
| "Sign in with OpenRouter" | Possible | The one self-serve, user-pays sign-in. The student must first buy credit (5.5% fee, $0.80 minimum). Needs an https callback on iOS. Smooth would have to build ask's prompt on the phone |
| Apple Intelligence "Extensions" (student picks Claude or ChatGPT system-wide) | Unconfirmed | Reported for iOS 27 by press; Apple's own pages read here do not mention it, and no source says another app's requests would go to the student's chosen provider. Check on an iOS 27 phone before counting on it |
| Anthropic App Attest, Apple Private Cloud Compute | Work, but not the student's account | App Attest is "billed to your workspace" (Smooth pays). Private Cloud Compute is Apple's model, free at Smooth's size |

### 3.2 Routes that put the student's AI in front of Smooth

| Route | Whose plan pays | Works on | What it can do for Smooth | Server copy of the work list? |
|---|---|---|---|---|
| **Connector, reading** (built: Marco's `v11`) | the student's | Claude: every plan, Free included, web, desktop and phone. ChatGPT: web only, read-only on Pro, full on Business/Edu (plan matrix not fully confirmed). Gemini: its help page says you can link an MCP server; which plans is unclear. Perplexity and Grok: paid plans, per secondary sources | The student's own AI answers questions about their classes | yes, for those who opt in |
| **Connector, Smooth cards in the chat** (MCP Apps) | the student's | "available for all users on Claude, Cowork, Claude Desktop, and Claude for iOS/Android" ([help](https://support.claude.com/en/articles/13454812-use-interactive-connectors-in-claude)); on iOS it renders in a web view. A custom connector's card may be marked "Unverified". Not device-tested | Smooth's week view or a card for one assignment, drawn inside Claude, with up to two actions | yes |
| **Connector, write-back** | the student's | same as reading | Claude writes a study plan, a summary of new announcements, or flashcards into Smooth through a write tool, and the app shows it. Directory rules allow this if read and write tools are separate and annotated | yes |
| **Scheduled tasks using the connector** | the student's, paid plans only | Claude Pro, Max, Ultra, Team, Enterprise: "run remotely, so they run on their cadence even when your computer is asleep" and can use "connected tools" ([help](https://support.claude.com/en/articles/13854387-schedule-recurring-tasks-in-claude-cowork)). ChatGPT also has scheduled tasks that can use connected apps | A morning brief: every day the student's Claude reads new posts and due dates and writes a brief into Smooth. The write tool must be set to "always allow" | yes |
| **Shortcuts** | the student's | Claude's iPhone app has an "Ask Claude" action for Siri, Spotlight, Share and Shortcuts, and it counts against the student's plan ([help](https://support.claude.com/en/articles/10263469-use-claude-app-intents-shortcuts-and-widgets-on-ios)). Apple's "Use Model" action can use ChatGPT | Smooth exposes actions such as "get my work list" and "save a note". A shortcut chains them with the AI step. Smooth could publish a ready-made shortcut. Whether Claude's reply passes cleanly to the next step is implied, not confirmed | **no**: phone to AI app directly |
| **Share sheet** | the student's | any AI app with a share extension | An "ask about this" button on a card hands the assignment's text to the student's AI app. The answer stays in that app | **no** |
| **Siri** (Apple's model, not the student's account) | nobody | iOS 27 | If Smooth exposes its items as app actions, Siri can answer "what's due this week" | no |

### 3.3 Feature by feature

| Smooth feature | Can the student's own AI power it? | How |
|---|---|---|
| ask, inside the app | **No**, on any consumer plan | Keep it on Smooth's key; add Private Cloud Compute as the free path |
| ask, as a hand-off | Yes | "ask in claude / chatgpt" through the share sheet or a shortcut; or the connector |
| A daily brief of what changed | Yes, Claude paid plans (ChatGPT likely) | Scheduled task + connector + a write-back tool |
| A study or day plan on the dashboard | Yes | Write-back tool; the app draws it |
| Summaries of long announcements, flashcards | Yes | Write-back tool, or a shortcut |
| Smooth's week inside the student's AI chat | Yes, Claude | MCP Apps card |
| Announcement task finding, course facts | No | These run for the whole class on the server, not per student |

### 3.4 Recommendation

1. **Start with Shortcuts and the share sheet.** Give Smooth a few app
   actions (work list, one assignment's text, save a note). This is the only
   route where the student's own Claude or ChatGPT works on their Smooth data
   with **no copy on Smooth's server**. It needs no approval from any AI
   company, works across providers, and also lets Siri answer from Smooth. It
   is roughly a week of work and nothing in it touches Canvas. Disclose it per
   Apple 5.1.2(i) on the screen that sets it up.
2. **Then the connector, read plus one write-back tool for notes and
   briefs**, not for submissions (Part 1.5). With an MCP Apps card and a
   documented "morning brief" scheduled task, this is the fullest form of
   "your own Claude powers Smooth". It needs the consent and off-switch work
   listed in Part 1.5, and a device test of the card on the iPhone app.
3. **Ask, at no cost:** file OpenAI's interest form, and ask Anthropic's sales
   contact what "previously approved" requires. Plan nothing on either.
4. **Skip** key pasting and Gemini's free key. Offer OpenRouter sign-in only
   if power users ask for it.

**Not confirmed:** the ChatGPT plan matrix for custom connectors (sources
conflict), MCP Apps for an unlisted connector on the iPhone app, Claude's
reply chaining to the next Shortcuts step, and whether iOS 27 Extensions
shipped. Each can be settled in minutes on a real phone.

---

## Questions for Olisa and Marco

1. Should Smooth ever submit AI-drafted work to Canvas, or should the agent
   only read? (The decision above.)
2. Do we turn off `agent-auth`, `mcp` and `agent-snapshot` now? And delete
   Marco's snapshot and draft rows by hand?
3. If drafts stay: are quizzes and exams excluded, does the integrity line
   come back, and do we show the syllabus's AI sentence?
4. Who publishes a directory listing: Stem Forward Co. or Marco? Who owns the
   Vercel front long term? It sits under Marco's personal account and sees
   every token.
5. How does a reviewer at Anthropic or OpenAI sign in without a Penn phone?
6. Has anyone at Penn (ISC, CETLI, Wharton) been asked about the connector?
   Should they be, before a listing makes it findable?
7. Course enrollment is self-asserted for all pooled material, not just the
   agent (issue 2). Is that worth fixing now for ask's sake?
8. Is a `v11` build on any phone besides Marco's (TestFlight, a friend's
   phone)?
9. Should 3.5.1 carry the `v13` off-switch cleanup, so Marco's 3.5.0 phone
   stops feeding a live snapshot?

## Sources and limits

- Code and docs: `origin/v13` at `1c5c4f6`, `origin/v11`,
  `origin/agent/connection-v11`, `origin/research/agent-canvas-via-smooth`
  (Marco's first research, 2026-10-30, superseded by
  `docs/AGENT_CONNECTION_PLAN_V11_2026-11-07.md`).
- `origin/claude/agent-operating-model-0lyx87` is unrelated: one commit of
  2026-07-20 that adds a generic "technical lead" CLAUDE.md for agent
  sessions, on a June 2026 base. Nothing about the agent connection.
- **Checked live** (read-only, no credentials): Apple's public lookup (3.5.0
  live), the connector front's discovery document (200), an unsigned call to
  `/mcp` (401), the live update manifest (floor 3.4.1, no agent wording).
- **From docs only:** function versions and deploy times, Marco's data on the
  server. Not checked: no management token on this Mac.
- **Not read:** Penn's Code of Academic Integrity page (catalog.upenn.edu
  answered 403); a current Instructure Acceptable Use Policy; OpenAI's Apps SDK
  submission page; the full Anthropic consumer terms. The App Store guidelines
  were read up to 5.2.5.
- Notes: `docs/research/agent-audit/security-review.md`,
  `apple-canvas-penn-policy.md`, `ai-accounts-and-directories.md`.
