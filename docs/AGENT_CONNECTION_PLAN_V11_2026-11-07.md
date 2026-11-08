# Agent connection for v11: the agent reads Smooth, Smooth submits

_Design record and plan. Written 2026-11-07 from research only; revised
2026-11-08 after Marco confirmed the direction. Nothing in it is built or
compiled. `docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md` has the mechanics
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
7. _(mine, to confirm)_ **Drafts reach the phone by polling**, on open and
   in the 5-minute refresh, with a local notification when one is found.
   The app has no remote push, and adding APNs is a project of its own.
8. _(mine, to confirm)_ **Our own small authorization server**, not Supabase
   Auth's OAuth server: students have no login to show a consent page to,
   so the phone approves each connection (pairing as authorization), and
   the tokens are opaque and only good at the MCP endpoint (research §3).

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
   research §8.
1. **Backend**: tables with RLS, `agent-auth`, `mcp` read tools,
   `agent-snapshot`, tests, deploy with Olisa's go. Done when claude.ai
   answers from Marco's real work.
2. **Phone, opt-in**: the connect-an-agent screen, the approve sheet, the
   snapshot upload, revoke, `PRIVACY.md`. Done when the iPhone-app flow
   works end to end on Marco's phone.
3. **Drafts**: `propose_submission`, polling, the chip, the sheet. Done when
   a draft from claude.ai shows on the card within one refresh.
4. **Submit**: `CanvasSubmissionClient`, the attempt store, text and file
   submissions on a sandbox, then one low-stakes Penn assignment Marco
   picks. Done when the verify GET agrees and a repeat is refused.
5. **Ship**: PROTOCOL, PRIVACY, review notes, CLAUDE.md, the directory
   listing. Version and upload are Marco's call.

## Limits and risks, stated on purpose

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
