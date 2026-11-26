# v11 extensions: what to build after the agent connection (2026-11-11)

_A choosing document. Written the morning after Problem Set 7 went through
(Canvas submission 357257138), from `CLAUDE.md`, `ROADMAP.md`, the v11 plan
(`docs/AGENT_CONNECTION_PLAN_V11_2026-11-07.md`), the research
(`docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md`), the listing checklist
(`docs/CONNECTOR_LISTING_CHECKLIST_2026-11-10.md`), the day-planner and
tree-context research, `backend/PROTOCOL.md` → "The agent connection", and
the code the claims below cite. Documents only: nothing here was built,
compiled or deployed, and every estimate is mine, not a measurement. Where a
claim rests on something outside the repo (a platform's behaviour, a
price), it says so._

## The facts every section leans on

- **We pay for no model calls the agent makes.** The agent's model runs on
  the student's own Claude (or ChatGPT) plan; `ask` and extraction are the
  only model bills (`DAY_PLANNER_RESEARCH` §4: about $2 a month at 200
  students for pooled extraction). So "server cost" below means Supabase
  function invocations, database rows and Storage, which are small, and I
  have not priced them against the plan we are on.
- **The agent can read and propose, nothing else.** Tools:
  `list_courses`, `list_work`, `get_assignment`, `search_course_material`,
  `get_facts`, `get_announcements`, `get_ed_posts`, `propose_submission`,
  `begin_file_upload`, `append_file_chunk`, `finish_file_upload`,
  `draft_status` (`_shared/agentTools.ts:460-792`). There is no submit tool
  and no Canvas proxy, by decision (plan, Decisions 1).
- **Limits that exist:** 20 open drafts per student (`MAX_OPEN_DRAFTS`,
  `agentDrafts.ts:19`), 100,000 characters of text, 1.5 MB of file
  (`agentTools.ts:141-145`), 2,000 of note. **Limits that do not:** the
  `agent_rate_check` calls are in `agent-auth` only (grep: no caller in
  `mcp/`), so tool calls and draft creation have no rate limit at all.
- **Scopes exist and are per connection:** `read draft offline_access`,
  stored in `agent_connections.scopes`
  (`migrations/20261108090000_agent_connection.sql:69-78`); the sign-in
  grants whatever the client asked for (`agentAuth.ts:111-118`).
- **The phone submits only to Canvas.** `AgentDraftSubmitter.unsupportedReason`
  (`LowHangingFruitKit/.../Agent/AgentDraftSubmitter.swift:53-59`) refuses
  anything not sourced `canvas`/`canvasModules`, anything that is not an
  assignment, anything marked nothing-to-submit.
- **Verified live so far:** Claude reads, drafts and uploads a file; the
  phone renders markdown to PDF; one file submit to Canvas. **Never run:** a
  text submit, a URL submit, a repeat refused by hand (the plan says so,
  line 232), the `smooth://link` tap from the Claude iPhone app, ChatGPT,
  `propose_submission` through the Claude directory's reviewers.

---

## 1. ChatGPT as a second client

- **The student gets:** "I can use Smooth from ChatGPT too."
- **Needs:** almost nothing new. The checklist table shows every OAuth and
  discovery item met, including RFC 9207 `iss`, CIMD with ChatGPT's client
  id shapes, DCR, and all three annotation hints on every tool
  (`CONNECTOR_LISTING_CHECKLIST` lines 16-45). Open gaps are small: the
  `403`/`_meta["mcp/www_authenticate"]` step-up for a `read`-only token (gap
  1, and our sign-in never produces such a token today), optional per-tool
  `securitySchemes`, and a server icon. The real blocker is not code: which
  ChatGPT plans may add a custom MCP server is unconfirmed (checklist
  lines 70-76; the research table, §6, has Plus/Pro "conflicting" and Penn's
  ChatGPT Edu limited to Wharton with an approved-connector list).
- **Costs:** 0 engineering days to try (Marco adds the URL and signs in);
  perhaps 0.5 day for the step-up error and the icon if it works. No
  server cost.
- **Could go wrong:** ChatGPT's handling of the chunked-upload tools is
  unknown (the PUT hint in `begin_file_upload` assumes a shell, which
  ChatGPT's connector surface may not have, so files might be capped at the
  24 KB inline limit); its prompts around a non-read-only write tool are
  unseen; and a plan that cannot add connectors makes the whole thing moot
  for most students. Few Penn students outside Wharton can use it.
- **Verdict: do next, as a 30-minute test by Marco, before any engineering.**
  The checklist says nothing on our side is known to be missing; the answer
  to "does it matter" is the plan question, which only he can look up
  signed in. Do not build ChatGPT-specific behaviour until a student can
  actually connect.

## 2. Directory listings (claude.ai and ChatGPT)

- **The student gets:** "I found Smooth in Claude's connector list and
  tapped add" instead of pasting `https://smooth-agent.vercel.app/functions/v1/mcp`.
- **Needs:** from the checklist (lines 133-157): a current, *served* privacy
  page (`docs/site/privacy.html` still says Low Hanging Fruit and is not
  hosted; the metadata points at a GitHub view of `docs/PRIVACY.md`
  → `agentMetadata.ts` `service_documentation`), terms of service (none
  exist), a support URL, a square logo at a stable URL, public documentation,
  a publisher identity (Stem Forward Co. or Marco), seven compliance
  acknowledgements (Claude), and a **reviewer path**, because both reviews
  want a test account without MFA and ours is a Penn student's phone.
  The reviewer path is the one engineering item: a fixed, revocable code in
  `agent-auth` that approves itself against a demo snapshot, modelled on the
  app's "Preview with sample data" (checklist lines 120-131). ChatGPT adds
  organisation identity verification and five positive/three negative
  prompts with a screen recording.
- **Costs:** the pages and logo are about 1-2 days of Marco/Olisa and are
  owed to the App Store anyway; the reviewer path about 1.5 days
  engineering plus its tests. Claude's listing is free to a paid account;
  the scan lists it as "Community" by default. No server cost.
- **Could go wrong:** the reviewer path is a second way in and has to be
  built so it can never reach a real student's data (a demo `user_id` that
  no real account can hold, rate-limited, revocable with an env var).
  Claude's reviewers might not accept `propose_submission` carrying
  `readOnlyHint: false` / `destructiveHint: false` (checklist line 39;
  `LHF_MCP_PROPOSE_HINT` flips it without a deploy). A listing also widens
  the population before the abuse caps in §13 exist, and invites the
  academic-integrity question publicly (§14).
- **Verdict:** privacy page, terms and support page **now** (they serve the
  App Store listing too); the Claude directory submission **later**, after
  §13 and after a few students have used the pasted URL; ChatGPT's
  directory **no** (identity verification, an organisation owner, and a
  plan question that §1 has not answered).

## 3. "Ask the agent" from inside Smooth

- **The student gets:** a button on the opened card, "work on this in
  Claude", that opens their Claude with the assignment already named, so
  they do not type "do problem set 7" and hope it finds the right one.
- **Needs:** phone only. A button beside "review and submit" on the opened
  card (`AssignmentCardView`, gated on `FeatureFlags.agentConnection` and
  at least one connection from `AppState.agentConnections`, which
  `agentDraftsPass` already refreshes) that opens a URL the student's
  Claude app or browser handles. Claude's `claude.ai/new?q=` prompt URL is
  my recollection of public behaviour, **not in the repo and not verified**;
  ChatGPT has a similar `?q=` form. Whether the Claude iPhone app takes the
  universal link or the Safari page does is a half-day test. The prompt
  should carry the class code, the title and the Smooth assignment id
  (`Assignment.id`, which is what `get_assignment` takes) and an instruction
  to use the connected Smooth tools, nothing else: no body text, no
  deadline reasoning. Nothing server-side changes. `PRIVACY.md` gets one
  line next to the feedback-form line ("the app adds nothing to the link"
  becomes "adds only the assignment's class and title, and only when you
  tap").
- **Costs:** 1-1.5 days including the iPhone check and the copy test. None
  on the server.
- **Could go wrong:** the title and class leave the phone through the
  student's own tap into a third party (Anthropic) that the student already
  chose; that is consistent with the posture but it is new text leaving the
  app by a URL, so say so in the policy and in the button's copy. The URL
  scheme can change without notice; the fallback is copying the prompt to
  the clipboard. If the student has two agents connected the button must
  ask which, not pick.
- **Verdict: do next.** It is the cheapest step that turns a connection that
  works into one students use; today the loop starts with the student
  leaving Smooth and describing the assignment from memory.

## 4. Drafts for Gradescope

- **The student gets:** "the PDF Claude wrote goes into Gradescope from my
  phone".
- **Needs:** a Gradescope write path that does not exist. The phone's
  Gradescope code reads (`GradescopeClient.swift`, `GradescopeReauthRule.swift`,
  cookie jar in the Keychain); `AgentDraftSubmitter.unsupportedReason`
  already refuses `.gradescope`, and the review sheet already says "this one
  can't be submitted online" and offers "open in gradescope". A real submit
  means scraping and POSTing Gradescope's own web form with a CSRF token,
  and for most Gradescope assignments a second step that maps PDF pages to
  the question outline, which only the student can do. Gradescope has no
  student API (CLAUDE.md "Gradescope has no student API").
- **Costs:** 4-6 days for a fragile first version, plus a permanent
  maintenance tail against a page that changes without notice, plus a
  terms-of-service reading I have not done.
- **Could go wrong:** a half-finished submission (uploaded, pages not
  assigned) is worse than none; Gradescope self-disconnects after 24 hours
  without a good sync (CLAUDE.md Traps), so the session is often absent when
  the student reaches the sheet; and handwritten-work assignments (the
  common case) are not an agent's output at all.
- **Verdict: no.** The part that is cheap and covers Gradescope is §8's
  "share the file out" (the student saves the rendered PDF and uploads it
  themselves); that is half a day and needs no new Gradescope code.

## 5. The agent proposing a day plan, written back to the dashboard

- **The student gets:** "Claude planned my week and it's on my list".
- **Needs:** a new write path into a ledger the design deliberately keeps
  deterministic. `DAY_PLANNER_RESEARCH` §2.4 decided that "the day" is a
  filter over facts applied to the ledger, not a model's output, and the
  composed-day work (`FactApplication`) already covers cancellations, moved
  dates and new tasks with a quoted source. A plan from the agent has no
  quote and no document behind it. The narrowest honest form is a new
  draft kind, `tasks`, that the student accepts in the same review sheet
  and that becomes ordinary manual tasks (the snapshot already carries
  `manual`, `agentSnapshot.ts:48`), never touching feed rows.
- **Costs:** 2-3 days (a draft kind, a sheet, the manual-task writer,
  tests). A day-planner chat in Claude needs none of it: the agent can
  already read `list_work` and advise.
- **Could go wrong:** a plan is stale in a day; accepted tasks clutter todo
  and create the second source of truth the research warned against;
  dated study tasks interact with the Sweeper (it skips manual and
  recurring, but a student will expect otherwise).
- **Verdict: no as a "plan on the dashboard"; later, if wanted at all, as
  "proposed tasks" the student accepts one by one.** The agent's strength
  here is the conversation, which already works, and the deterministic day
  is the thing Marco chose in 2026-11-03.

## 6. The agent reading Ed Discussion and answering follow-ups

- **The student gets:** "Claude knows what staff said on Ed".
- **Needs:** nothing; it exists. `get_ed_posts` returns the staff,
  announcement and pinned posts the phone pooled (`agentTools.ts:573`;
  `EdThreadFilter`; `docs/ED_DISCUSSION.md`). Student, private and anonymous
  posts never leave the phone, and `PRIVACY.md` promises it.
- **Costs / could go wrong:** reading student threads or posting back would
  need the student's Ed session on the server (it never goes there) or an
  agent write into Ed under the student's name. Both break the privacy line
  and Ed's own norms. The real weakness is freshness: Ed posts arrive on
  the phone's hourly sync, not live.
- **Verdict: no** for student threads and for posting. The staff-only read
  is as far as this goes. If staleness bites, the fix is the existing sync
  (Olisa's), not the agent.

## 7. Rendering LaTeX on the phone

- **The student gets:** physics and CS problem sets whose equations look
  like equations. Problem Set 7 shipped with the geometry stated in words
  because `DraftDocumentRenderer` says "Math in `$...$` is left as text:
  there is no TeX on the device" (`DraftDocumentRenderer.swift`, header
  comment). This is the one limit Marco's first real submission hit.
- **Options:**
  1. *Unicode math in the draft.* Tell the agent, in the `propose_submission`
     description and the begin-upload text, to write equations as Unicode
     (`x² + y²`, `∫`, `½mv²`) and not `$...$`. Free, today, works with the
     existing renderer, ugly for anything with fractions or matrices.
  2. *A bundled renderer.* KaTeX (open source; licence and size are from
     memory, not checked) in a WKWebView, render the markdown's math to
     HTML, then `WKWebView.createPDF` to a file. Works offline, stays on
     the phone (so `PRIVACY.md`'s "made on this phone and never passes
     through our server" stays true), no server. Needs the fonts bundled and
     a spike to prove an off-screen WKWebView paginates to US Letter at
     1-inch margins like the CoreText path does; the CoreText path would
     remain for plain text.
  3. *Server-side rendering.* Breaks the privacy sentence above (the
     student's solution would pass through our server) and adds a service.
     Rejected.
- **Costs:** option 1 is an afternoon and a deploy of `mcp` (Olisa's go).
  Option 2 is 3-5 days with the spike first. No server cost either way.
- **Could go wrong:** option 2's pagination and fonts are the unknowns; a
  WebView-rendered PDF can differ from what the sheet previews (the sheet
  previews the same PDF through PDFKit, so it would still show the truth);
  the app grows by the font files.
- **Verdict: option 1 do next (it is a text change); option 2 later, after
  a spike, if math-heavy students are the audience.** Marco's classes are
  exactly that audience, so I would not let it slide long.

## 8. File drafts beyond PDF (docx, images), and sharing a draft out

- **The student gets:** a Word file when the assignment wants `.docx`; and a
  way to take any draft out of Smooth.
- **Needs:** less than it looks. The upload path stores any mime type the
  agent names (`agentDrafts.ts:168`, `application/octet-stream` default) and
  the review sheet already handles "a file as a row with name, size and
  preview, QuickLook" (CLAUDE.md), which opens docx and images; the
  preflight already reads `allowed_extensions` and refuses a mismatch with a
  plain sentence ("canvas doesn't take .zip here · ask for a pdf file"). So a
  docx or a PNG from an agent that can produce one (Claude with code
  execution, then the signed `PUT` in `begin_file_upload`) probably works
  today and is unproven. What is missing is a *producer* on our side: the
  agent cannot emit docx bytes inline (the model limit of 2026-11-10), and
  there is no markdown-to-docx on the phone.
- **Add:** a "share" action on the review sheet (the iOS share sheet over
  the rendered PDF or the file), so the student can put the same draft into
  Gradescope, an email, a tutor's folder, or Pages. Half a day. It also
  answers §4 and keeps the agent from needing a submit path anywhere.
- **Costs:** share, 0.5 day. A phone-side markdown-to-docx writer, 3+ days
  (no library in the repo; I would not start it). Verifying that an
  agent-produced docx round-trips, 0.5 day of Marco's time.
- **Could go wrong:** a docx from a model can carry odd styles; images are
  the likeliest integrity and privacy surprise (a photo of handwritten work
  in the student's Storage until decided); the 1.5 MB cap rules out phone
  photos. Keep the cap.
- **Verdict:** share-out **later but cheap** (take it with §3 if there is
  room); docx/images **later**, test the existing path first; markdown-to-docx
  **no** for now.

## 9. Multiple agents per student and per-agent scopes

- **The student gets:** "my tutor bot can read but not draft".
- **Needs:** many connections per student already work (`agent_connections`
  is one row per connection; Claude web, iPhone, Desktop and Code each make
  one). Scopes are stored per connection but the sign-in grants whatever the
  client asked for (`agentAuth.ts:111-118`), and our clients ask for
  everything. A read-only choice needs the phone's approve sheet
  (`AgentLinkApproveSheet.swift`) to show "can propose drafts" as a switch
  that defaults on, and `approve` to carry the chosen subset into the
  connection and its tokens (`agentAuth.ts:348-396` already branches on
  `asksDraft`). `propose_submission` already answers "this connection
  cannot propose drafts" (`agentTools.ts:592`).
- **Costs:** 1-1.5 days across server and phone, plus tests; the checklist's
  step-up gap (gap 1) is worth closing alongside so a read-only student who
  later wants drafts gets a clear path instead of a bare tool error.
- **Could go wrong:** Claude may re-request `draft` on reconnect; a
  read-only connection still has the work list, which is the privacy-heavy
  part, so it is a safety valve for integrity and not for privacy. It
  multiplies states the Connections screen must explain, against the
  copy-minimal rule.
- **Verdict: later.** It is the right answer to a real question (§14) but
  no student has asked, and it costs a state the UI has to carry. Revisit if
  a listing brings in students who want tutoring only.

## 10. A "what did the agent do" audit view, and an attempt history

- **The student gets:** "I can see what Claude did and what I sent".
- **Needs:** two different things.
  - *Attempt history on the phone.* `AgentSubmitAttemptStore` already keeps,
    per attempt, draft id, assignment id, time, Canvas submission number and
    the agent's name, on the phone only. A list under Profile → connect an
    agent ("Problem Set 7 · submitted by you · drafted by Claude · 10:52 pm")
    needs no server change and no privacy change. 1 day.
  - *A server-side log of reads.* Today the server keeps only
    `last_used_at` per connection (`agentStorePostgrest.ts:306`); there is
    no record of which tools ran or which courses were read. Adding one is a
    new retained table about what the student looked at, which is more than
    `PRIVACY.md` keeps for `ask` ("neither questions nor answers are
    stored"). If wanted, keep counts only (reads and drafts per connection
    per day), not arguments.
- **Could go wrong:** a log of reads is itself sensitive and a new thing to
  delete on opt-out, disconnect and account deletion; counts are cheap to
  add to those paths, arguments are not.
- **Verdict:** phone-side history **later but cheap**; server-side tool log
  **no**, counts at most, and only if the abuse work in §13 wants them.

## 11. Class-level pooled agent notes

- **The student gets:** "my classmate's Claude found the late policy, I
  don't have to ask again".
- **Needs:** an agent write into the pool, which is where the privacy cost
  concentrates. The pool's facts are safe because each is a *quote from a
  pooled document*, produced by the server's own model once per revision,
  with no user id (`course_facts`; CLAUDE.md "Facts and structured sources";
  `extract-facts` checks the quote is found verbatim). An agent's note has
  no document behind it, is generated from one student's question, and, if
  accepted as a fact, is applied to every classmate's cards by
  `FactApplication` (a false "cancelled" hides an assignment from todo).
- **Costs / risks:** low engineering, high risk: poisoning (any student can
  inject a "fact" into a class), leakage (the note reveals what a student
  was stuck on), no way to retract from phones that already pulled it
  (CLAUDE.md Traps: deleting server-side facts does not retract them), and a
  hole in the "course material is pooled, the student's data is not"
  sentence.
- **Verdict: no.** Anything an agent can find is already in the pool,
  because the agent reads only the pool and the student's own snapshot. If
  the pool misses something, fix the extractor or the collector.

## 12. The Sweeper knowing a draft exists

- **The student gets:** at 10 minutes before an unsubmitted deadline, the
  alarm screen says "you have a draft waiting" and opens it.
- **Needs:** the phone already holds the drafts (`AppState.agentDrafts`,
  `agentDraftsCacheV1`, which keeps a content-free list so a relaunch draws
  chips). `BerserkTakeoverView` has three choices; a fourth, "review draft",
  would open the review sheet and not submit. The pure eligibility rule is
  `SweeperPlan.qualifies` (`SweeperPlan.swift:17-26`), which should not
  change: a draft does not make an item more or less alarming. The AlarmKit
  alert itself cannot carry it (its buttons are the system's; the Live
  Activity is drawn by the widget extension and has no access to the
  drafts cache).
- **Costs:** 1-1.5 days for the in-app takeover only; the widget Live
  Activity and the notification path are not worth the risk (blind
  background and extension code).
- **Could go wrong:** the worst moment to meet an unreviewed AI draft is ten
  minutes before it is due, when a student under pressure taps through.
  The review sheet's friction ("read it", a confirmation naming the kind)
  is the integrity design, and an alarm that routes into it must not
  shorten it. The takeover also has limits already recorded in Known gaps
  (a sheet over the takeover; only the in-app overlay).
- **Verdict: later.** Take it when real use shows students with drafts
  waiting at alarm time. The existing local notice per new draft
  (`AgentDraftNotices`) covers discovery.

## 13. Per-student cost caps and abuse limits

- **The student gets:** nothing visible, which is the point; a runaway
  agent cannot fill their card list or their phone with notices.
- **Needs:** server only. `mcp/` calls no rate check (the callers of
  `agent_rate_check` are `agent-auth/index.ts` and the store files). Add:
  per-connection tool-call limit per hour, a tighter per-student cap on
  `propose_submission` and `begin_file_upload` (today an agent that
  proposes, is declined and proposes again is bounded only by the 20 open
  drafts and 1.5 MB each), and a cap on bytes stored per student. Reuse
  `agent_rate_check` (Postgres, one-hour windows, fail-open) so it is a
  call-site change plus tests. Return the existing
  `429 slow_down` or a tool error saying what to do. Cost caps for model
  tokens do not exist because we do not pay for them.
- **Costs:** 0.5-1 day. Server cost: the point is to bound it. A heavy
  student at a few hundred tool calls a day is on the order of a million
  Edge Function invocations a month across 200 students at the extreme,
  which I have not priced against our plan; Storage is bounded by 20 drafts
  × 1.5 MB per student in the worst case and is deleted at the decision.
- **Could go wrong:** limits set too low break a legitimate long session
  (claude.ai issuing many `search_course_material` calls); fail-open means
  an outage of the counter removes the protection silently. Set generous
  numbers and log refusals.
- **Verdict: do next.** It is small, it protects the production database
  before a listing or ChatGPT widens the population, and the gap is real
  (grep of `mcp/`).

## 14. Institution-level concerns: Penn's rules, the integrity line, a course opt-out

- **What Smooth says today:** the review sheet carries one line,
  "this goes in under your name; read it" (`AgentLinkApproveSheet.swift:63`,
  the copy the review sheet uses), the card carries "drafted by claude", the
  agent's name is recorded with every attempt, and `PRIVACY.md` closes with
  "What you submit is your responsibility under your school's rules, and
  Smooth marks every draft with the assistant's name so that is never
  hidden." The plan's "Limits and risks" states the posture: academic
  integrity is the student's exposure and Smooth makes the act one tap;
  Instructure's 3(i) about MCP servers is read as not applying because the
  submission is the student's act in their own session ("a reading, not a
  ruling"); the Wharton note of 2026-11-04 says a PennKey session is not an
  appropriate mechanism for agent access, which is why the agent never
  holds one. I have not read Penn's Code of Academic Integrity or any
  course's policy for this document, so I make no claim about what it
  allows.
- **What a course opt-out would take:** a new profile field. The facts
  (`cancel`, `reschedule`, `new_task`, `scope_change`, `note`,
  `needs_review`) have no AI-policy type, and a grep of the backend and Kit
  for an AI policy finds nothing. `extract-profile` reads each syllabus once
  per revision; adding `aiPolicy` (`allowed | restricted | prohibited |
  unstated`, with a verbatim quote, the way facts require one) is a prompt
  and schema change plus a bench round like every earlier one
  (`docs/FACTS_PROMPT_OWNER_RULE_2026-11-05.md`), about 2-3 days with the
  bench, at cents per month.
- **Could go wrong:** policies are often per assignment ("no AI on exams,
  fine on homework"), so a course-level flag will be wrong in both
  directions; a "prohibited" label from a model misreading a syllabus
  insults a student who did nothing wrong, and an "allowed" one creates a
  false sense of cover. Smooth has no instructor side, so an "opt-out by the
  instructor" has nobody to opt out; it could only be inferred from text.
  Blocking would make Smooth the arbiter of a school's rules, which the
  posture ("quiet and personal") refuses.
- **Verdict: later, and informational only.** If built, show the syllabus's
  own sentence on the review sheet ("syllabus says: …") and never block.
  The cheaper step now is a sentence in the connect-an-agent disclosure
  that the student should check their course's rules. A course-level
  opt-out that blocks drafts: **no**.

## 15. Finds that were not on the list

- **Close the unverified before building more.** The submit path has run
  once, with a file. Text and URL submission have never touched Canvas;
  "a repeat is refused" is pinned by tests and the attempt record but not
  tried by hand; `smooth://link` from the Claude iPhone app is untried;
  `propose_submission` through the directory's reviewers is untried
  (plan lines 232-234, checklist line 106). A bug in the one path that
  writes to a student's Canvas is the worst bug in the product (plan:
  "Duplicate submissions are the new worst bug"). One careful evening on a
  low-stakes assignment Marco picks, text then URL then a deliberate second
  Submit tap. **Verdict: do next, first.**
- **Make the agent's instructions travel with the connection.** The tool
  descriptions are the only prompt Smooth controls (they "describe, they do
  not instruct", checklist line 42, a rule for the directories). Useful
  guidance (Unicode math, which draft kind to prefer, "state assumptions
  for figures you cannot see") has nowhere to live except as description
  text. Worth a small `get_started` read tool or MCP prompt, decided after
  seeing what students' Claudes get wrong; later.
- **Failed Gradescope and Ed cards say why.** Not an agent matter, noted
  because §4 will come back: the sheet already explains non-Canvas items in
  a sentence; no change needed.

---

## Ranked: do next (at most five)

1. **Close the unverified submit paths** (§15): text, URL, a manual repeat,
   the `smooth://link` tap. Half a day to a day of Marco's evening and a
   session; no new code unless it finds a bug. Everything else stands on it.
2. **Abuse caps on the MCP** (§13): rate-limit tool calls and draft creation,
   bound stored bytes per student. 0.5-1 day, needs an `mcp` deploy and
   Olisa's go.
3. **"Work on this in Claude" button on the card** (§3), plus the privacy
   sentence. 1-1.5 days, phone only, after a half-day check of how the
   Claude iPhone app takes a prompt URL.
4. **Try ChatGPT** (§1): Marco checks which plan allows a custom MCP server
   and connects it; engineering only if it works.
5. **Math that looks like math** (§7): the Unicode instruction in the tool
   descriptions now (an afternoon, same `mcp` deploy as 2), then a KaTeX
   renderer spike if his own classes keep needing it.

Cheap items to slot in if there is room: the phone's attempt history (§10),
share-out of a draft (§8), the privacy page, terms and support page (§2).
Held back on purpose: the Claude directory submission, per-agent scopes,
the Sweeper hook, the AI-policy line on the review sheet.

## Questions only Marco can answer

1. **Which ChatGPT plan do you have, and does it let you add a custom MCP
   server** (help.openai.com article 12584461, signed in)? It decides whether
   §1 and §2's ChatGPT half are worth a minute more.
2. **Who is the publisher of record for a directory listing and the terms of
   service, Stem Forward Co. or you, and do you want a reviewer path
   built** (a self-approving demo account)? The listing, the privacy page
   and the terms all hang on it, and it is a business decision with Olisa.
3. **Where is your line between informing and gating on academic
   integrity?** Today Smooth informs (a chip, a line, the agent's name). If
   you ever want it to say what a syllabus says about AI, or to offer a
   read-only connection, that is your call, and it changes what a public
   listing says about the product.
