# Session brief: build the agent connection (v11)

_Paste this into a fresh session. It assumes no memory of the research
session that wrote it. Written 2026-11-08._

## Read first, in this order

1. `CLAUDE.md` top to bottom (especially "Overseer / doer split", "Test
   baseline", the traps) and `ROADMAP.md` → Now and Next.
2. `docs/AGENT_CONNECTION_PLAN_V11_2026-11-07.md`: the decisions and phases.
3. `docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md`: how every piece works,
   with source citations and the seven things still unverified.
4. `backend/PROTOCOL.md` (principles, `pair`, `device-sync`, Facts) and
   `docs/PRIVACY.md`.

## What you are building, in one paragraph

A student turns on "connect an agent" in Smooth. In Claude (web, iPhone,
Desktop, Code; ChatGPT where its plans allow) they add Smooth as a
connector; the sign-in page shows a code, Smooth on the phone approves it.
From then on the agent can read the student's work list with done state,
their courses, the pooled syllabi, pages, announcements, Ed posts and facts,
and can **propose** a submission (text, URL or a file). The draft appears on
the assignment card in Smooth as "drafted by Claude"; the student opens it,
reviews, taps submit; Smooth submits to Canvas with the student's own
session. The agent never submits. Penn only.

## Standing rules (from the owner and CLAUDE.md)

- The agent gets **no** submit tool, no edit tool, no completion tool, on
  any server, ever. The only write is `propose_submission`, which creates a
  draft.
- The server never talks to Canvas. The MCP server serves Smooth's own data
  (Instructure's API policy 3(i) bars MCP servers that proxy its APIs).
- Cookies, the PennKey password, grades and the student's name never leave
  the phone. The one new thing the server holds is the opted-in student's
  work list (fields listed in the research, section 7), and `PRIVACY.md`,
  `PROTOCOL.md` and the opt-in screen change in the same commit as the code.
- **A change that has not been compiled is not done.** Say so plainly.
  `cd LowHangingFruitKit && swift test --no-parallel` is the gate (current
  baseline in CLAUDE.md → Test baseline; a lower count has lost work).
  `cd backend && deno task test && deno task check` for the backend. The
  Chrome extension's `node --test` suite is untouched by this work.
- Work on a branch off `v10` (`agent/connection-v11`), in its own worktree
  created by hand from `v10`'s tip (the `isolation: "worktree"` option bases
  on a stale `main`). Never push to or merge into `v10` without Marco's
  explicit approval. Commit messages: short imperative subject, prose
  paragraphs on the reasoning and what was rejected, the Co-Authored-By
  line CLAUDE.md names.
- Install only the newest build on Marco's phone, and check whether another
  thread (Codex) has a build on it first. The Mac's disk fills with
  `.build` and DerivedData; ask before deleting caches.
- Deploys to the live Supabase project need Olisa's go and a Management API
  token from his account (`~/lhf-bench/supabase.token` when present; it is
  revoked after each run). `backend/scripts/deploy-function.mjs` sends
  `verify_jwt: true` for every function; the `mcp` and `agent-auth`
  functions need `false`, so extend the script with a per-function flag
  before the first deploy.
- Keep on-screen copy minimal. No status prose. "drafted by Claude" and
  "review and submit" are about the right length.
- Overseer/doer split: plan and review yourself, delegate implementation to
  `implementer` (Sonnet) with standalone briefs naming `path:line`, verify
  security-sensitive pieces (the authorization server, the Canvas write
  path, RLS) with `verifier`. Two failed revision rounds on a task means
  stop and say what is wrong.

## Phase 0: spikes, before any UI (target: two days)

Each spike ends with a dated answer written into
`docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md` → section 8.

1. **Canvas cookie + CSRF POST from URLSession.** A DEBUG-only launch
   argument (`-LHFSubmitSpike <courseID> <assignmentID>`) that runs the
   preflight GET, reads `_csrf_token` from the saved jar (or from the GET's
   `Set-Cookie`, since cookie handling is off in the clients), POSTs an
   `online_text_entry` of "spike", and prints the status, body and the
   verify GET as `LHF-SUBMIT` lines. Run it against a sandbox: a Canvas
   Free-for-Teacher course with a student test user (the clients take a
   base URL) or a Penn course Marco controls. **Never a graded assignment.**
   Also record whether `_csrf_token` was in the jar before the GET.
2. **AS metadata discovery.** A stub `agent-auth` function serving
   `<issuer>/.well-known/oauth-authorization-server` and
   `/.well-known/openid-configuration`, and a stub `mcp` returning 401 with
   `resource_metadata` pointing at `<mcp>/oauth-protected-resource`. Add it
   to claude.ai as a custom connector and record whether Claude fetches the
   path-appended metadata. If not, decide the static host for the two JSON
   documents (the issuer becomes that origin).
3. **Phone hand-off from Claude's in-app browser.** On the stub authorize
   page, an "Open Smooth" button to `smooth://link?c=test`. Run the add-
   connector flow from the Claude iPhone app on Marco's phone and record
   whether Smooth opens (the app needs a `link` host branch that just logs).
4. **File argument size.** With MCP Inspector and then claude.ai, call a stub
   `propose_submission` with `file_base64` at 256 KB, 1 MB, 1.5 MB, 3 MB;
   record what the client sends and the Edge Function's CPU time to decode
   and write to Storage.
5. **Write-tool prompt.** Record what claude.ai shows for the stub
   `propose_submission` with no hint, `destructiveHint: false`, and
   `destructiveHint: true`.

## Phase 1: backend (reads, auth, snapshot)

Files: `backend/supabase/functions/mcp/`, `agent-auth/`, `agent-snapshot/`,
`_shared/agentTokens.ts`, `_shared/agentSnapshot.ts`, a migration
`2026MMDD_agent_connection.sql`, `backend/PROTOCOL.md`, `backend/test/*.test.ts`.

- **Tables** (all RLS by owner, all in `deleteUserData` in `_shared/db.ts`):
  `agent_connections` (id, user_id, client_id, client_name, scopes,
  created_at, last_used_at, revoked_at), `agent_tokens` (hash, kind
  access|refresh, connection_id, resource, expires_at, rotated_from),
  `agent_pending_auth` (id, code, match_number, nonce_hash, params jsonb,
  user_id nullable, auth_code_hash, expires_at), `agent_snapshots`
  (user_id PK, courses jsonb, work_list jsonb, manual jsonb, written_at),
  `agent_drafts` (Phase 3 can add it; design it now).
- **`agent-auth`**: AS metadata (CIMD supported, S256, `none`,
  `offline_access`, `read draft` scopes, `authorization_response_iss_parameter_supported`),
  `authorize` (CIMD fetch with SSRF guard, exact redirect-URI match, pending
  row + nonce cookie, the page with code / match number / QR / "Open
  Smooth" / typed-code fallback), `status` (cookie-bound poll → 302 with
  `code`, `state`, `iss`), `token` (form-encoded; code + PKCE + `resource`;
  refresh with rotation and reuse detection), `revoke`, and the phone's
  `lookup` / `approve` (Supabase JWT via `requireUser`). Token lifetimes and
  shapes per research section 3.
- **`mcp`**: `createMcpHandler` from `@modelcontextprotocol/server` v2,
  stateless, bearer check in front (hash lookup, audience = the MCP URL,
  scope, expiry), 401 + `WWW-Authenticate` with `resource_metadata` and
  `scope`. Tools, each with `title` and `readOnlyHint: true`: `list_courses`,
  `list_work(view, course?)` (the dashboard's todo / all / prev rules, ported
  from `DashboardViewModel` — write the rule once in `_shared` with tests
  against the Swift fixtures' expectations), `get_assignment(id)` (snapshot
  item + pooled `course_documents` description/attachment names + facts
  targeting it + `submittable: text|url|file|none|external` from the pooled
  assignment document's submission types where present),
  `search_course_material(query, course?, kind?, page?)` (Postgres full-text
  over `course_documents`; paged text), `get_facts(course?, since?)`,
  `get_announcements(course?, days?, page?)`, `get_ed_posts(course?, page?)`.
  Serve long texts paged, under 150,000 characters. Errors as `isError`
  results.
- **`agent-snapshot`**: `put` from the phone (Supabase JWT), validated shape
  (research section 7's field list, Canvas assignment URLs only, size cap),
  `delete` on opt-out. `verify_jwt` stays true here.
- **Config and deploy**: `[functions.mcp]` and `[functions.agent-auth]`
  `verify_jwt = false` in `config.toml`; `deploy-function.mjs` per-function
  `verify_jwt`. Deploy with Olisa's go; smoke-test with throwaway users and
  delete them through `delete-account`.
- **Tests**: token hashing/rotation/reuse, PKCE verification, redirect-URI
  matching, CIMD validation, pending-auth binding and expiry, the view
  rules, snapshot validation, RLS (psql), `deleteUserData` covering the new
  tables. Then MCP Inspector against `supabase functions serve`, then Claude
  Code (`claude mcp add --transport http smooth <url>`), then claude.ai.

Done when: claude.ai, connected through the phone approval, lists Marco's
real work and answers "what's due this week in PHYS 0151" from pooled
material; the run is recorded in the plan with the date.

## Phase 2: phone, opt-in and snapshot

Files: `LowHangingFruitUI/SettingsPage.swift` (accounts section, 109-181,
after `ProfileLaptopRow` ~172), new `AgentConnectionsView.swift` and
`AgentLinkApproveSheet.swift`, `AppState+AgentConnection.swift`,
`BackendClient.swift` (new calls), `RootView.swift:107-116` (`.onOpenURL`,
add a `link` host branch), `LowHangingFruitKit/Sync/PairingLink.swift`
(or a sibling `AgentLinkRequest` parser; `PairingLink` is deliberately
strict), `FeatureFlags.swift` (`agentConnection`), `SharedDefaults.swift`
(opt-in key, snapshot cursor), `docs/PRIVACY.md`, `App/Info.plist` only if
the scheme needs anything new (it does not: `smooth` exists).

- Profile → accounts → **connect an agent**: the opt-in screen (exact fields
  shared, recipients by name, retention, revoke, policy link, its own
  affirmative tap); the connected-apps list with last used and revoke; the
  typed-code fallback field.
- The approve sheet for `smooth://link?c=…`: client host, scopes, "did you
  just start this?", the match-number choice, approve / not now.
- Snapshot upload on the same hooks as `deviceSyncPass`
  (`AppState+DeviceSync.swift:225`; callers `ContentView.swift:775`,
  `RootView.swift:186`), throttled, foreground only, built from the same
  source as `syncWorkList` (line 311) plus the fields section 7 lists.
  Opt-out deletes the server row. Canvas disconnect revokes connections and
  deletes the row (`AppState.disconnectCanvas`, `AppState.swift:5016`; today
  it deliberately leaves the backend identity alone, keep that).
- Tests: the parser, the snapshot builder's field set (nothing extra, no
  grades), opt-in flag round trips through `UserDefaults.lhf` with a scratch
  suite.

Done when: on Marco's phone, the whole add-connector flow from the Claude
iPhone app ends in a working connection, the connected-apps list shows it,
revoke works, and `swift test --no-parallel` is at or above baseline.

## Phase 3: drafts, from the agent to the card

Files: `mcp/` (`propose_submission`, `draft_status`), `agent-drafts/`
function (phone `list`, `mark`), Storage bucket `agent-drafts` (private),
`AppState+AgentDrafts.swift`, `AssignmentCardView.swift` (`body` 148,
`content` 214, `expandedDetail` 320-437: chip near `sourceText` 360-364,
draft section between 375 and 378), new `DraftReviewSheet.swift`,
`DashboardViewModel.swift` (a `draft` on `DashItem`), a local notification
on a new draft during a foreground refresh, `docs/PRIVACY.md`.

- `propose_submission(assignment_id, kind: text|url|file, body?, url?,
  file_base64?, file_name?, mime_type?, note?)` with the cap from the spike
  stated in the description; one draft per call; returns the draft id.
  `draft_status(id)` returns `proposed|seen|submitted|declined|failed`.
- The phone polls drafts on launch and in the refresh loop; `seen` on open;
  the card chip reads "drafted by <client name>"; the opened card shows the
  preview (text inline; a file through QuickLook) and **review and submit**;
  the sheet shows exactly what will be submitted, the assignment and due
  date, one integrity line, Submit, Decline.
- Tests: draft decoding, state machine, the card's chip rule, the sheet's
  content from a fixture draft.

Done when: a draft proposed from claude.ai shows on the card on Marco's
phone within one refresh and the sheet renders it; Decline round-trips to
`draft_status`.

## Phase 4: the submit path

Files: `LowHangingFruitKit/CanvasAPI/CanvasSubmissionClient.swift` (new;
follow `CanvasCourseContentClient.swift:138-150` for auth and
session-expiry mapping; `CanvasAuth.apply` at `Canvas/CanvasAccessToken.swift:371`),
a `MultipartBody` helper (none exists), `Persistence/SubmissionAttemptStore.swift`
(SwiftData, its own store, the `AppliedFactStore` pattern at
`Persistence/AppliedFactStore.swift:36`; wire into `AppState` like
`AppState.swift:500-502`), `DraftReviewSheet.swift` (Submit), tests with
fixtures for every response shape in research section 4.

- Preflight GET → CSRF from the jar or the GET's `Set-Cookie` → attempt row
  written → POST (text / URL / three-step file upload per file, then the
  `online_upload` POST) → verify GET → `submitted` with id and attempt, or
  `failed`. 422 → refresh the token value, retry once. 401 → session dead,
  stop. 400 / HTML / 3xx → fail, show the message, offer "open in canvas".
  **Never auto-retry the POST.** A draft with an attempt row is refused.
- The card reads "turned in" through the completion the Canvas poll already
  derives; the attempt row is the ledger of what Smooth did.
- Done when: one real text submission and one file submission land on a
  sandbox assignment from Marco's phone, the verify GET agrees, a second
  Submit on the same draft is refused, and both runs are recorded with the
  date. Then one Penn assignment Marco chooses, low stakes, resubmission
  allowed.

## Phase 5: ship

`PROTOCOL.md` principle 2 rewritten; `docs/PRIVACY.md` agents section;
`docs/appstore/REVIEW_NOTES.md` describing the opt-in screen and that the
agent never submits; `ROADMAP.md` Done recently; CLAUDE.md "What the app
does", Branches, Test baseline; the Claude directory submission once the
connector is stable (`claude.com/docs/connectors/building/submission`).
Version bump and upload are Marco's call.

## Report back

Diffs, test counts before and after, what ran on the phone and when, each
Phase 0 answer with its date, and the open questions, in the register
CLAUDE.md asks for. No narration.
