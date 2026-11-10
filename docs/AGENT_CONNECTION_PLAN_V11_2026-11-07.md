# Agent connection for v11: the agent reads Smooth, Smooth submits

_Design record and plan. Written 2026-11-07 from research only; revised
2026-11-08 after Marco confirmed the direction, and again that evening with
the Phase 0 and Phase 1 status (the backend is built and tested, not
deployed; see each phase's Status line). `docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md` has the mechanics
and sources; `docs/AGENT_CONNECTION_SESSION_PROMPT.md` is the brief for the
session that builds it. The 2026-10-30 research on
`research/agent-canvas-via-smooth` (docs only) holds the sourced reasons for
everything rejected here. Same register as `docs/CHROME_EXTENSION.md`: why
first, then how._

## The owner's ask

Marco (2026-11-07): "a connection for an agent to have all the context to
your classes and the possibility to submit assignments." Clarified
2026-11-08: it should work from the Claude or ChatGPT he already uses, on
the phone too; the agent drafts, reviews and uploads files; the student
reviews and submits from the Smooth app; the agent itself should not
submit. "You're just giving the context and the ability to upload
assignments, and you're giving all the different contexts that the app has,
and you're giving this all to an agent."

## The finding that still stands

The Canvas sign-in cannot be lent. What keeps Smooth signed in is a process
(a foreground WebView, Penn's IdP and Duo cookies, a saved PennKey
password), not a cookie, and no agent platform accepts an injected session
anyway. Penn has since said so in writing (Wharton, 2026-11-04: a PennKey
session is not an appropriate mechanism for agent access). So the agent's
output moves to where the sign-in already is: the agent proposes, the phone
submits.

## What changed between 2026-10-30 and today

1. The Chrome extension exists and is live (unlisted store), with
   JavaScript ports of the Kit's pure logic and an end-to-end encrypted
   phone sync. Useful code; no longer on the critical path (see decision 3).
2. The context half is already assembled: the context document the tree
   sends, pooled documents, `course_facts`, course profiles.
3. Penn's and Instructure's rules are written down (research §1), and both
   point at the same split: the agent never touches Canvas or the session,
   Smooth presents an MCP interface and the student performs the act.
4. Claude custom connectors reach every Claude client on every plan; ChatGPT
   custom connectors are workspace-only for individuals (research §6).
5. The Canvas write path is read from source: a cookie-session POST to
   `/api/v1` works with `X-CSRF-Token` set to the `_csrf_token` cookie
   value, which is what Canvas's own UI does (research §4).

## Decisions (confirmed by Marco, 2026-11-08, except where marked)

1. **Draft and review, never do and submit.** The agent gets no submit
   tool anywhere, ever. It proposes text, a URL or a file; the student
   reviews in Smooth and taps submit; Smooth POSTs with the student's own
   session. This is what keeps the design on the right side of Anthropic's,
   OpenAI's, Instructure's and Penn's texts, and it is what Apple and the
   student can see.
2. **Cloud connector first.** A remote MCP server on the Supabase backend,
   so claude.ai, the Claude iPhone app, Desktop, Code and Duet all reach it.
   The cost is one privacy change: the server stores the opted-in student's
   work list (fields in research §7), disclosed in an opt-in screen,
   `PRIVACY.md` and PROTOCOL principle 2 in the same commit. A local
   `.mcpb` server is a fallback only.
3. **The phone submits, with files.** The Smooth app gets the first Canvas
   write path (`CanvasSubmissionClient`): text, URL, and the three-step
   file upload. The extension is not on the critical path; it can learn to
   show drafts later.
4. **Claude first, by necessity.** Built to the MCP spec so ChatGPT works
   where its plans allow (Business, Enterprise, Edu; Penn's ChatGPT Edu is
   Wharton-only and allowlists connectors). Tested and documented against
   Claude. A Claude directory listing once stable.
5. **Penn only**, as the backend is.
6. **Submission types:** text entry, URL, file upload. Media, annotation,
   Classic Quizzes: not in v11. New Quizzes, LTI, Gradescope: the card says
   so and deep-links.
7. _(decided 2026-11-08 evening: Marco asked the session to decide each
   open item on feasibility and the goal)_ **Drafts reach the phone by
   polling**, on open and in the 5-minute refresh, with
   a local notification when one is found. The app has no remote push, and
   adding APNs is a project of its own.
8. _(decided 2026-11-08 evening, same basis; built and proven the same
   day)_ **Our own small authorization server**, not Supabase Auth's OAuth server: students have no login to
   show a consent page to, so the phone approves each connection (pairing
   as authorization), and the tokens are opaque and only good at the MCP
   endpoint (research §3). It exists as `agent-auth` and completed a
   Claude Code sign-in on a dev tunnel the same day (research §8).
9. _(decided 2026-11-08 evening, same basis; host changed later that night)_
   **A host we control in front of the two functions: a Vercel project on
   its free `*.vercel.app` subdomain**, running `backend/connector-front/`
   as one Edge Function (`backend/api/connector-front.ts`, `backend/vercel.json`).
   The first pick was Deno Deploy, for the language and the free tier, but
   its sign-ups were closed when Marco tried (2026-11-08 night); Marco
   already has a Vercel account (the CLI on his Mac holds a stale login),
   the front is plain fetch code so it ports with a ten-line adapter, and a
   custom domain can be attached later without changing the code. The
   production deployment is used on purpose: Hobby preview deployments
   carry Vercel Authentication, which would block Claude. `vercel login`
   once is the one thing that needs a person; the issuer and MCP URL then
   become `https://<project>.vercel.app/functions/v1/agent-auth` and
   `.../mcp`, and the functions are deployed with
   `LHF_AGENT_PUBLIC_BASE` set to that. Background:** Claude Code's sign-in step only reads the OAuth discovery
   documents at the *root* `.well-known` paths of the MCP URL's host
   (research §8 item 3), which `<ref>.supabase.co` cannot serve. So the
   MCP URL and the issuer have to live on a domain of ours (for example
   `mcp.<our domain>`) whose root answers
   `/.well-known/oauth-protected-resource/...` and
   `/.well-known/oauth-authorization-server/...` and forwards everything
   else to the Supabase functions: a Cloudflare Worker or any small proxy.
   Which domain, and whose account, is the question for Marco; until it is
   answered the backend can be deployed but no Claude client can sign in to
   it. (claude.ai may behave differently from Claude Code; the connector
   test on Marco's account will say.)

## Architecture

```
  Claude (web, iPhone, Desktop, Code, Duet) ── OAuth ──► agent-auth (Edge Fn): phone approves
          │ MCP over HTTPS, opaque bearer token
          ▼
   mcp (Edge Fn, stateless) ── reads ──► agent_snapshots (per-student work list, opt-in)
          │                              course_documents, course_facts, course_profiles (pooled)
          └── propose_submission ──────► agent_drafts (+ private Storage for files)
                                                   │ phone polls on open / refresh
                                                   ▼
                                  Smooth: card "drafted by Claude" → review sheet → Submit
                                                   │
                                                   ▼ cookie + X-CSRF-Token, student's own session
                                                Canvas
```

**Tools.** `list_courses`, `list_work(view, course?)`, `get_assignment(id)`,
`search_course_material(query, course?, kind?, page?)`, `get_facts`,
`get_announcements`, `get_ed_posts`, all read-only and annotated so; plus
`propose_submission(assignment_id, kind, body|url|file_base64…)` and
`draft_status(id)`. Nothing else, and nothing that proxies a Canvas call.

**Sign-in.** Claude hits the server, gets a 401 pointing at our metadata,
opens our authorize page; the page shows a code, a match number, a QR and an
"Open Smooth" button; the student approves on the phone; the page redirects
back to Claude with the code; Claude trades it for tokens. One row per
connection, revocable from Profile.

**The card.** A provenance chip ("drafted by Claude"), a preview in the
opened card, one button, **review and submit**, a sheet that shows exactly
what will be sent, Submit, Decline. An attempt row is written before the
POST and makes a second submit of the same draft impossible.

## Phases

Detailed, with files and acceptance tests, in the session brief.

0. **Spikes** (two days): the Canvas cookie + CSRF POST from URLSession on a
   sandbox assignment; metadata discovery and the phone hand-off from the
   Claude iPhone app; the file-argument size Claude will send; the prompt
   Claude shows for the write tool. Each ends with a dated answer in
   research §8. **Status 2026-11-08:** discovery answered for Claude Code
   (root paths required, decision 9) and the decode cost measured (1.5 MB in
   under 2 ms); the submit spike is built and compiled but needs a sandbox
   assignment; the iPhone hand-off, the claude.ai connector, what a model
   sends as a file and the write-tool prompt wait on Marco (the asks are
   listed under Limits and risks).
1. **Backend**: tables with RLS, `agent-auth`, `mcp` read tools,
   `agent-snapshot`, tests, deploy with Olisa's go. Done when claude.ai
   answers from Marco's real work. **Status 2026-11-08:** written, tested
   (Deno 818, the SQL check green, the authorization server reviewed) and
   committed on `agent/connection-v11`; a Claude Code sign-in completed
   against it on a dev tunnel and `tools/list` was served. Not deployed
   (Olisa's go, the token, and decision 9 first), so "answers from Marco's
   real work" is still open; it also needs the Phase 2 snapshot upload
   from the phone, since the server has no work list until a phone sends
   one. `backend/PROTOCOL.md` → "The agent connection" is the contract.
2. **Phone, opt-in**: the connect-an-agent screen, the approve sheet, the
   snapshot upload, revoke, `PRIVACY.md`. Done when the iPhone-app flow
   works end to end on Marco's phone.
3. **Drafts**: `propose_submission`, polling, the chip, the sheet. Done when
   a draft from claude.ai shows on the card within one refresh. **Status
   2026-11-09:** the backend half is built and tested (Deno 858, the SQL
   check green): `propose_submission` writes a row and, for a file, an
   object in the private `agent-drafts` bucket (20 open drafts per
   student); `agent-snapshot` gained `drafts` (the student's open drafts,
   file as a 120-second signed URL) and `draft` (seen / declined /
   submitted / failed, one-way, the file deleted at the decision);
   opt-out and account deletion remove everything. Migration
   `20261109100000_agent_drafts.sql`, not applied in production; the phone
   half (polling, chip, review sheet) is not built. The same day the
   hardening closed `agent-auth`'s three Limitations (rate limits in
   Postgres, a sweeper, approve and deny bound to the student's own
   lookup), also undeployed, and a scripted client
   (`backend/scripts/agent-e2e.mjs`) proved the live production path end
   to end.
4. **Submit**: `CanvasSubmissionClient`, the attempt store, text and file
   submissions on a sandbox, then one low-stakes Penn assignment Marco
   picks. Done when the verify GET agrees and a repeat is refused.
5. **Ship**: PROTOCOL, PRIVACY, review notes, CLAUDE.md, the directory
   listing. Version and upload are Marco's call.

## Limits and risks, stated on purpose

**Open asks for Marco (2026-11-08 evening; decisions 7, 8 and 9 were taken
by the session at his word, "decide based on feasibility and our goal", and
are recorded above). Later the same evening everything that can be scripted
was: the session cannot create accounts, sign in as him, or deploy to
production without Olisa's go, so each item below is now one person-step
followed by a command the session (or anyone) runs:**

1. **The connector front: DONE 2026-11-08 night.** Marco ran `vercel login`;
   `backend/connector-front/deploy.sh` created the project `smooth-agent`
   under his Vercel account and deployed. Live at
   `https://smooth-agent.vercel.app`: both root discovery documents answer
   with that host as issuer and resource, `/functions/v1/mcp` and
   `/register` forward to Supabase (which answers 404 until the functions
   are deployed), unknown paths get our 404. Two fixes the first deploy
   forced: Vercel's bundler refuses Deno's explicit `.ts` imports, so
   deploy.sh pre-bundles with esbuild; and it reads `export const config`
   only as a literal, so `api/connector-front.js` is a hand-written
   three-line file importing the bundle (otherwise it ran on Node as
   CommonJS and died on `import.meta`). The upstream `apikey` question
   (README) is still open until the functions exist.
2. **The functions: DONE 2026-11-08 night, at Olisa's go relayed by Marco
   ("Yes, deploy").** `node backend/scripts/deploy-agent.mjs --public-base
   https://smooth-agent.vercel.app/functions/v1` set `LHF_AGENT_PUBLIC_BASE`,
   applied the migration, deployed `agent-auth`, `mcp`, `agent-snapshot`
   (each version 1; verify_jwt false, false, true) and passed every smoke
   check through the front, so the Supabase gateway does **not** demand an
   `apikey` header on the public functions (`UPSTREAM_APIKEY` stays unset).
   Probed by hand afterwards: the authorize page renders its code and the
   `smooth://link`, `/register` mints an `smc_` id, a bogus code is
   `invalid_grant`, `/phone` and `agent-snapshot` refuse without a token.
   One live finding: Supabase's gateway rewrites an Edge Function's HTML to
   `text/plain` with a sandbox CSP on `supabase.co`, so the pages carry
   marker headers and the front restores the real ones (Traps).
3. **claude.ai.** Add the dev tunnel (alive at the time of writing,
   `https://1e28-2607-f470-6-1001-186d-8e5-da38-7223.ngrok-free.app/functions/v1/mcp`,
   dies with the Mac's sleep) or, after 1 and 2, the real host
   `https://smooth-agent.vercel.app/functions/v1/mcp` as a custom connector
   on his claude.ai account, or `claude /login` once in a terminal on the
   Mac. Then the three remaining Phase 0 answers can be taken (claude.ai
   discovery, what a model sends as `file_base64`, what Claude shows under
   each `destructiveHint`).
4. **A Canvas sandbox** for the submit spike (a Free-for-Teacher course with
   a student test user, signed in through the Mac build; **never a graded
   one**), then `-LHFSubmitSpike <courseID> <assignmentID>`; and **his
   phone on the cable** for the Debug install and the `smooth://link` tap
   (the phone was unreachable on 2026-11-08 evening). The link test also
   needs 2, since the phone looks the code up on the production backend.

- **Instructure 3(i)** names MCP servers that connect to its APIs. Ours
  serves Smooth's own data; the submission is the student's act in their
  own session, the same footing as every read today. A reading, not a
  ruling. Keep the posture quiet and personal.
- **Academic integrity is the student's exposure; Smooth makes it one
  tap.** One line on the review sheet, the chip on the card, and the
  agent's name recorded with every attempt.
- **The privacy change is real.** Opt-in only; the stored fields are the
  minimum; grades and names never; deletion on opt-out, disconnect and
  account deletion.
- **Duplicate submissions** are the new worst bug: attempt row first, POST
  second, never an automatic retry.
- **Unsupported types** refuse up front and deep-link, never fail half-way.
- **Nothing here has compiled or run.** By the project's rule, none of it
  is done, including the seven unverified items in research §8.

## Rejected

Cookie export, the phone as a proxy, an autonomous submit tool anywhere, an
MCP server that proxies Canvas APIs, and (2026-11-08) the laptop-first
design with the Chrome extension submitting: cheaper, but not what the
student would use. The October report has the sources for the first four.
