# Agent connection for v11: the agent reads Smooth, Smooth submits

_Design record and plan, written 2026-11-07 from research only. Nothing in
it is built or compiled. It supersedes `docs/AGENT_SUBMISSION_PLAN.md` on
the docs-only branch `research/agent-canvas-via-smooth` (2026-10-30), whose
report `docs/research/agents-acting-on-canvas-via-smooth.md` still holds
the sourced reasoning for everything rejected below. Same register as
`docs/CHROME_EXTENSION.md`: why first, then how._

## The owner's ask (2026-11-07)

Marco: "a connection for an agent to have all the context to your classes
and the possibility to submit assignments." Two halves, and they are not
the same size:

- **Context.** Everything the tree sees: the work list with done state, the
  syllabi and course pages, announcements, Ed posts, the pooled facts, the
  course profiles. This half is nearly free: v10 already assembles all of
  it, on the phone (`AssistantContextDocument`), on the laptop (the Chrome
  extension's collector) and on the server (pooled documents and facts).
- **Submit.** Smooth has never written to Canvas. This half is new code,
  a new class of bug (a submission is not undoable the way a completion
  swipe is), and the half every policy in sight has an opinion about.

## What changed since the October research

The 2026-10-30 report ranked six architectures and reached "Smooth submits,
the agent only thinks". That verdict stands. What moved is the ground
under it, and every change points the same way: do it on the laptop first.

1. **The Chrome extension exists and is live** (`docs/CHROME_EXTENSION.md`;
   unlisted on the Chrome Web Store since 2026-11-05, store id
   `jkegbcingmdidfegpmhgcagfhnnacoil`). It runs inside the student's own
   signed-in Chrome, with host permissions for `canvas.upenn.edu`,
   Gradescope and Ed, fetching with `credentials: "include"`. That browser
   holds the live Canvas session and Duo's trust, the two things October
   proved cannot be lent. It also already ports the Kit's pure logic to
   JavaScript (`chrome-extension/src/core/`: `Term`, `CourseCode`, dedup,
   the ICS parser, the Canvas API shapes, pairing, and the snapshot
   crypto). It is strictly read-only today: no `POST` to Canvas, no CSRF
   handling, `permissions` are `storage` and `alarms` only.
2. **Phone and laptop already share an end-to-end encrypted snapshot**
   (`Sync/SyncSnapshot.swift`, `chrome-extension/src/core/syncSnapshot.js`;
   `pair` and `device-sync` in `backend/PROTOCOL.md`). Format 1 carries
   `completions`, `dueEdits`, `manual` and `workList` (id, course, title,
   dueAt, kind, source, url, done), AES-256-GCM under a key `K` the QR
   carries in its URL fragment. The server stores ciphertext it cannot
   read, 2 MB per device row. This is the channel the agent connection
   should ride, because it keeps PROTOCOL principle 2 ("never the work
   list") true for the server while giving a device the student owns the
   whole list.
3. **The context half is richer and already leaves the phone.** The
   context document (`# CLASSES`, `# WORK` with done / outstanding /
   cancelled / nothing to submit per item, `# ANNOUNCEMENTS`) goes to the
   server with every question, unstored; `docs/PRIVACY.md` line 45 already
   says so. Pooled documents and the `course_facts` table are server-side
   and course-level. An agent given the same material gets what the tree
   gets.
4. **Penn has written the rule down.** Wharton's "Agentic AI Guidelines"
   (support.wharton.upenn.edu, last modified 2026-11-04): "A PennKey user
   session is NOT an appropriate mechanism to access Penn systems and is
   prohibited"; users "may not grant Agentic AI access to their PennKey
   user session through computer use mechanisms or otherwise"; services
   should "present a Model Context Protocol (MCP) interface". Wharton,
   not university-wide, but it is the clearest statement Penn has made,
   and it describes exactly the split below: the agent never touches the
   session, and the thing it talks to is an MCP server.
5. **Instructure has drawn its line too.** The Canvas API Policy
   (effective 2025-08-12, read 2026-11-07) bars connecting to the APIs
   "through model context protocol servers or other technologies not
   approved by Instructure" (section 3(i)), and using them "on behalf of
   any third party". A product that completed Canvas courses for students
   ("Einstein") went offline after Instructure's cease-and-desist
   (Inside Higher Ed, 2026-03-23). There is still no sanctioned student or
   third-party agent path; IgniteAI Agent (2026-03-12) is for educators.
   So: the MCP server must serve Smooth's own data, never proxy Canvas
   calls, and the submission must be the student's act, not the agent's.
6. **Claude is the reachable client; ChatGPT is not, for individuals.**
   Custom remote connectors are available on every Claude plan (Free gets
   one; support.claude.com, read 2026-11-07), and local MCP servers run in
   Claude Desktop (`.mcpb` bundles) and Claude Code. ChatGPT's custom MCP
   is Business, Enterprise and Edu only, with Pro limited to read and
   fetch; Plus is unresolved. Claude in Chrome is generally available on
   paid plans (since about 2026-08-26) but offers no way for an extension
   or page to hand it tools; WebMCP (`document.modelContext`) is an origin
   trial in Chrome 149, not stable.
7. **MCP 2026-07-28 is stateless and has a confirmation primitive.** A tool
   can return `resultType: "input_required"` and get the answer on the
   retry (Multi Round-Trip Requests). Supabase documents an official
   pattern for hosting a remote MCP server on Edge Functions
   (`createMcpHandler`, Streamable HTTP, `verify_jwt` off, no sampling),
   and Supabase Auth can act as the OAuth 2.1 server. Neither is needed
   for Phase 1.
8. **Apple is not an agent channel.** iOS 27's App Intents and App Schemas
   feed Siri; there is no API for Claude or ChatGPT to call a third-party
   app's intents. Siri/Shortcuts stay a separate, on-device nicety
   (ROADMAP → Next), not part of this plan's critical path.
9. **Anthropic's usage policy (effective 2026-11-12)** forbids
   "submit[ting] AI-assisted work without proper permission or
   attribution" and makes the user responsible for what agents do through
   connected systems. Apple's 5.1.2(i) requires explicit permission before
   personal data is shared with third-party AI.

## Decisions the plan takes (owner to confirm or overrule)

1. **Draft and review, never do and submit.** The agent gets no submit
   tool, on any server, ever. It proposes a submission; the student reads
   it in Smooth and taps submit; Smooth performs the POST with the
   student's own session. This is what makes the product defensible under
   items 4, 5 and 9 above, and it is also what makes it reviewable by
   Apple and the Chrome Web Store. The wrong version, a `submit_assignment`
   tool "with a confirmation prompt in the agent", puts the button in the
   agent's UI and the liability on Smooth.
2. **Laptop first, cloud later.** Phase 1 is a local MCP server for Claude
   Desktop and Claude Code, paired to the phone like the extension is. The
   remote connector for claude.ai and the Claude iPhone app (Phase 4)
   needs plaintext on the server and so a rewrite of PROTOCOL principle 2,
   `docs/PRIVACY.md`, and a consent screen; it should wait until the
   laptop version has shown students want it.
3. **The extension submits, not the phone, in the first version.** The
   browser already has the session and Duo trust, the code is JavaScript
   with a fast dev loop, and the extension already collects the submission
   state it will need to verify its own work. The phone-side
   `CanvasSubmissionClient` from the October plan moves to Phase 3 and
   shares the same draft inbox.
4. **Claude-first.** Build to the MCP spec so ChatGPT works where its
   plans allow; test and document against Claude Desktop, Claude Code and
   claude.ai only.
5. **Penn only**, as the backend is. The MCP server keys on the backend's
   anonymous account like the extension does.
6. **Scope of submission types**: text entry and URL first; file upload
   second; media, annotation, Classic Quizzes never in v11; New Quizzes,
   LTI and Gradescope rows deep-link to the page and say so.

## Architecture

```
                 ┌──────────────────────┐
                 │  Supabase (blind)    │   pooled docs, facts, profiles
   phone ◄──────►│  device-sync blobs   │◄──────► Chrome extension (reads Canvas,
   (K)           │  pair, sync, ask     │          submits on tap)  (K)
                 └──────────┬───────────┘
                            │ E2E blob + pooled reads
                 ┌──────────┴───────────┐
                 │  smooth-mcp (local)  │  paired device, holds K
                 │  Node, stdio MCP     │  tools: list_work, get_assignment,
                 │  Claude Desktop/Code │  search_material, get_facts,
                 └──────────────────────┘  propose_submission, draft_status
```

Three devices, one student, one key. The MCP server is a third paired
device. It decrypts the phone's and the extension's snapshots locally,
reads pooled course material and facts through the same backend calls the
extension makes (identity resolves to the owner, `_shared/auth.ts`), and
exposes typed, read-only tools plus one write that only ever creates a
**draft** inside the encrypted blob. The extension (later the phone) shows
the draft and does the submission. The server never sees a draft in
plaintext, never talks to Canvas, and stores nothing new in plaintext.

### Tools (Phase 1 read set)

- `list_courses()`: code, shown name, Canvas course id, grading categories
  from the profile.
- `list_work(view: "todo" | "all" | "prev", course?)`: the dashboard's
  three views computed from `workList` + `completions` + `dueEdits` +
  `manual`, the same rules as `DashboardViewModel` (port the view rules;
  the extension already ports `Term` and dedup).
- `get_assignment(id)`: title, course, due (local and ISO), status, kind,
  Canvas URL, the pooled description and attachment names from
  `course_documents`, the facts that target it, and `submittable:
  text | url | file | none | external` derived from the assignment's
  `submission_types`.
- `search_course_material(query, course?, kind?)`: BM25 over the pooled
  documents (port the fetch-free half of `CourseSearch`; no embedding).
- `get_facts(course?, since?)`: the `course_facts` rows for the student's
  courses, in the wire shape of `PROTOCOL.md` → Facts.
- `get_announcements(course?, days?)` and `get_ed_posts(course?)` from the
  pooled documents of those kinds.
- `ask_smooth(question)` is **deliberately absent** in Phase 1: the agent
  is itself the model, and the point of the connection is to hand it the
  material. Revisit if agents keep asking questions the tree answers
  better (it has course profiles and the frozen prompt).

### The one write: `propose_submission`

`propose_submission(assignment_id, kind: "text" | "url", body)` appends a
`Draft` to the MCP device's own snapshot (format 2, below) and returns its
id. `draft_status(id)` reads back `proposed | seen | submitted | declined`
from the other devices' snapshots. There is no `submit`, `edit_due`,
`complete` or any other write. A later `propose_file_submission` carries a
file (Phase 3).

### Snapshot format 2

Format 1 is extended, never replaced; both decoders must accept unknown
fields, and the phone's `SyncSnapshot` decoder must be checked for that
**before** any device writes format 2 (a strict `Decodable` would drop the
whole blob on students' phones).

- `drafts[]`: `{ id, assignmentId, course, kind, body | url, proposedAt,
  proposedBy: deviceId, agent?: string, status, statusAt }`.
- `submissions[]`: `{ draftId, assignmentId, canvasSubmissionId, attempt,
  submittedAt, by: "extension" | "phone" }`. Written **before** the POST
  with `canvasSubmissionId: null`, then updated; a draft with any
  `submissions[]` row is never submitted again (idempotency lives here,
  not in Canvas, which happily records a second attempt).

The 2 MB cap per device row is enough for text and URL drafts; files are
why Phase 3 needs its own encrypted row (`draft_files`, ciphertext only,
same shape as `device_sync_blobs`, with a size cap and a TTL).

### Pairing a second device: the key problem

Today `K` is generated by the device, carried in the QR fragment, and the
phone keeps exactly one key (`SyncKeyStore.save/load`). A second device
pairing with its own `K` would overwrite the phone's and break the
extension. Fix in the `pair` protocol, server-blind:

- The new device's QR carries its code and an ephemeral X25519 public key
  (`pk`) instead of `k`.
- The phone, on `claim`, if it already holds `K`, wraps `K` to `pk`
  (HPKE-style: X25519 + HKDF + AES-GCM) and sends `wrappedKey` in the
  claim; the server stores it on the `device_links` row and returns it to
  the device on `status`. If the phone holds no `K` yet, it adopts the
  device's `k` as today (back-compatible: a QR may carry both).
- The server sees a wrapped key it cannot open. Nothing else changes.

This is the one protocol change Phase 1 needs, and it benefits the
extension too (a second laptop).

### The submit path in the extension (Phase 2)

- A `drafts` badge in the popup; a review sheet showing the assignment,
  the draft body, the agent's name, and a single **submit** button; a
  **decline** that records `declined`.
- The POST: `POST /api/v1/courses/:cid/assignments/:aid/submissions` with
  `submission[submission_type]` and `submission[body]` or
  `submission[url]`, `credentials: "include"`, and `X-CSRF-Token`. Two
  unknowns a spike must settle before any UI is built (Phase 0):
  1. Whether Canvas accepts a cookie-session POST to `/api/v1` with the
     header (`lib/canvas/request_forgery_protection.rb`'s `verified_request?`
     reads as yes; `in_app?` was not read).
  2. Where the token comes from: the `_csrf_token` cookie needs the
     `cookies` permission (a new permission, store re-review), or the
     assignment page's `ENV.AUTHENTICITY_TOKEN` can be read from a fetched
     page body with no new permission. Prefer the second if it works.
- After the POST, re-read the submission (`include[]=submission`, which
  the collector already does) and write the `submissions[]` row; the
  phone then shows "turned in" through the completion it already derives.
- A failed POST leaves the `submissions[]` row with `canvasSubmissionId:
  null` and an `error`; the sheet offers "open in Canvas" and never
  retries on its own.

### Where the code lives

- `agent/smooth-mcp/`: a Node 22 package, `@modelcontextprotocol/sdk`
  stdio server, importing `chrome-extension/src/core/*` as a workspace
  dependency (move nothing; add a root `package.json` workspace or a
  relative import, whichever the extension's test runner tolerates).
  Distributed two ways: `npx smooth-mcp` for Claude Code, and a `.mcpb`
  bundle for Claude Desktop (one click, pairing QR shown in a local page
  the server opens).
- `backend/supabase/functions/pair/`: the `wrappedKey` field;
  `PROTOCOL.md` in the same commit.
- `chrome-extension/src/`: format 2 encode/decode, the drafts UI, the
  submit client (`adapters/canvasSubmit.js`), and `core/submitRules.js`
  (pure: which kinds an assignment accepts, idempotency check).
- Phone: `SyncSnapshot` tolerant decoding and format 2 fields; a
  "proposed by your agent" line on the card and the draft text in the
  opened card (read-only in Phase 2); `docs/PRIVACY.md`.

## Phases, each verifiable alone

**Phase 0: decide and spike (days).** Owner confirms the six decisions.
The CSRF spike: a throwaway script run from the extension's service-worker
console against a sandbox assignment in a course Marco controls (a
self-created Canvas free-for-teacher course works if Penn's does not);
record the answer to both unknowns in this file. Check the phone's
`SyncSnapshot` decoder for unknown-field tolerance. Done when the two
unknowns have dated answers here.

**Phase 1: read-only MCP server (about a week).** `smooth-mcp` with the
read tools; pairing with the wrapped key; `pair` change deployed with
Olisa's go; `node --test` for every pure function (view rules, tool
schemas, snapshot format 2 decode) and one end-to-end run: Claude Desktop
lists Marco's real work and answers "what's due this week in PHYS 0151"
from pooled material. `PROTOCOL.md` and `PRIVACY.md` updated (what the
MCP device holds, that it is the student's own machine, how unpairing
deletes it). Done when the e2e run is recorded here with the date.

**Phase 2: drafts and the extension submit (one to two weeks).**
`propose_submission` for text and URL; format 2 on the extension and the
phone (tolerant); the review sheet; the submit client; idempotency tests;
store update with whatever permission the spike required. Verification:
one real text submission to a sandbox assignment, never a graded one,
then a second `propose_submission` for the same draft is refused. Done
when both are recorded here.

**Phase 3: files, phone, Siri (later, independent pieces).**
`propose_file_submission` with an encrypted `draft_files` row and the
three-step Canvas upload (`/submissions/self/files`, 30-minute pending
window, step 3 GET); phone-side review and `CanvasSubmissionClient` so a
student without the laptop open can still submit; App Intents for "what's
due tomorrow" on-device (unrelated code, shares nothing).

**Phase 4: the remote connector (only if asked for).** A Supabase Edge
Function MCP server (`createMcpHandler`, stateless) for claude.ai and the
Claude iPhone app. Needs: the phone to push a plaintext snapshot the
server stores under an explicit opt-in (the end of principle 2 as written;
rewrite it and `PRIVACY.md` and add the 5.1.2(i) consent screen in one
commit); OAuth 2.1 with PKCE where the authorization step is the pairing
flow (the browser shows a code, the phone approves it, the page completes
the redirect), because anonymous GoTrue users have no login to show a
consent page to; deletion wired into `delete-account`. Never a write tool.

## Limits and risks, stated on purpose

- **Instructure 3(i).** The MCP server serves Smooth's pooled data and the
  student's own list; it does not connect to Canvas APIs. The extension's
  submit is the student's act in their own browser, the same footing as
  every read it does today. This is a reading of the policy, not a
  ruling; keep the posture quiet and personal, not marketed as "AI does
  your homework".
- **Academic integrity is the student's exposure; Smooth makes it one
  tap.** The review sheet should say so in one line, once, and the draft
  should be visibly attributed to the agent on the phone's card.
- **Penn's own guideline is about the session, which this never lends.**
  The saved-PennKey re-login Smooth already does sits closer to that text
  than anything in this plan; that is a separate conversation to have, not
  a reason to change this design.
- **Unsupported types** (New Quizzes, LTI, Gradescope, media, annotation):
  `get_assignment` says `external` and the sheet deep-links. Refuse
  outright rather than fail half-way.
- **Duplicate submissions** are the new worst bug: record first, POST
  second, never retry automatically, and treat the `submissions[]` row as
  the lock.
- **The store.** A new `cookies` permission triggers Chrome Web Store
  re-review and a permissions warning on update; the spike decides whether
  it is needed at all.
- **Nothing here has compiled or run.** By the project's rule, none of it
  is done, including the ports this plan assumes are reusable.

## Rejected again, briefly

Cookie export (bearer credential leaves the device, no renewal, breaks
`PRIVACY.md`), the phone as a proxy (30-second pushes, no background
path), an autonomous submit tool anywhere, and an MCP server that proxies
Canvas API calls (the thing Instructure's 3(i) names). The October report
has the sources.

## Sources read for this revision (2026-11-07)

Wharton Agentic AI Guidelines (2026-11-04); Instructure Canvas API Policy
(2025-08-12) and the IgniteAI Agent press release (2026-03-12); Inside
Higher Ed on "Einstein" (2026-03-23); Canvas Submissions and File Uploads
API docs; `lib/canvas/request_forgery_protection.rb`; MCP specification
2026-07-28 (authorization, elicitation) and its release post; Claude
custom-connector support and authentication docs; OpenAI custom MCP docs
(help page itself returned 403); Chrome WebMCP developer page; Supabase
BYO-MCP and OAuth Server guides; Anthropic Usage Policy (effective
2026-11-12); App Store Review Guidelines 5.1.2(i); Apple WWDC26 newsroom.
Claims marked as search summaries in the research notes were not re-read.
