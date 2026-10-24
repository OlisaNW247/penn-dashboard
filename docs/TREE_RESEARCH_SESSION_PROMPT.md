# Session prompt: deep research on improving the tree (ask)

Paste everything below the line into a new session opened on this repo.

---

You are the overseer on this project (read the "Overseer / doer split" at the
end of `CLAUDE.md` and work that way: delegate bulk reading to `Explore`
agents on haiku or sonnet, write briefs that stand alone, read targeted line
ranges yourself). Before anything else, read `CLAUDE.md` top to bottom, then
`ROADMAP.md`, then `docs/ANNOUNCEMENTS_FOR_ASK_PLAN.md`. Treat every claim in
them as something to re-check against the code; when they disagree, the code
wins and fixing the line is part of the job. There is no Swift toolchain in
the cloud container: nothing you write compiles until Olisa runs
`swift test --no-parallel` on his Mac, so this session is **research and a
plan, not code**, unless he says otherwise. Push to `v8` only, with
`git pull --rebase origin v8` before every push (another session may be
pushing too), commits as `OlisaNW247 <olisanwogugu@gmail.com>` ending with the
two trailer lines the other sessions use (`Co-Authored-By: Claude Fable 5.1
<noreply@anthropic.com>` and a `Claude-Session:` line for this session).
Never deploy an Edge Function, apply a migration, change a project secret or
spend credits without Olisa's explicit go. The publishable key and project
URL in the repo are public by design; nothing else is.

**The request** (Olisa, 2026-10-24): "do deep research on how we can improve
the tree feature". The tree is **ask**, the chat about your classes
(`AssistantView`; the server path `backend/supabase/functions/ask/index.ts`
for Penn, the on-device `OnDeviceAssistantResponder` as fallback). Spend
real time on it (an hour of research is fine), then present a ranked plan.
Do not start implementing before Olisa has read the plan.

**Where the tree stands today, so you do not rediscover it:**

- Retrieval is on the phone (`CLAUDE.md` → "ask: retrieval is on the
  phone"): BM25 over passages (`CourseSearch`, `BM25Index`,
  `QueryExpansion`, `CourseMatcher`), up to eight 1,500-character excerpts
  sent with a byte-stable context document (`AssistantContextDocument`; the
  prompt-cache trap in `CLAUDE.md` explains why it never reads a clock), a
  recency rule for "what's new" questions (`RecencyIntent`, 2026-10-20),
  follow-up scoping (`FollowUpRetrieval`), and source chips
  (`CitationLinks`). The server adds only the registrar sections
  (`catalog_courses`) and answers with `openai/gpt-4.1-mini`, hedged by
  `z-ai/glm-5.3-flash` after 5 s (the model section of `CLAUDE.md`; every
  request writes an `ask_outcomes` row, never the question).
- What the phone holds is the limit. As of 2026-10-23 the pool has, per
  class: syllabus, home page, the 40 newest pages' bodies, module titles,
  assignment descriptions, **Canvas announcements from this term (the
  first ever, 2026-10-23: 63 posts)**, and **Ed announcements and pinned
  posts** (the Ed reader was fixed the same day: paging, anonymous posts
  dropped). Canvas Files (slides, readings, PDFs) are **not** ingested by
  the phone; the Chrome extension (`chrome-extension/`,
  `docs/CHROME_EXTENSION.md`) is built to collect them and nothing has
  run in a real Chrome yet. Server exam dates (`v8-server-exam-dates`)
  are merged but `sync` v13 is not deployed.
- The backend's document rules changed on 2026-10-23 (`sync` v12):
  announcements and Ed posts are "window" kinds, exempt from the
  complete-set retire rule, aged out at 120 days on read, capped at 150
  per class on download (`backend/supabase/functions/_shared/manifest.ts`,
  `backend/PROTOCOL.md`).
- Known weaknesses already on record (read them before proposing them
  again): `CLAUDE.md` → Known gaps ("ask cannot read Canvas Files", "The
  summary sent with every ask question carries completion state", the
  recency rule not yet asked on a phone, ask's work pool after the
  2026-10-20 merge), `ROADMAP.md` → Next (hands-free voice mode with
  spoken answers was set aside on 2026-10-22; dictate-then-send shipped),
  Phase 4 of `docs/ANNOUNCEMENTS_FOR_ASK_PLAN.md` (one Canvas path on the
  phone) and its deferred `posted_at` migration.
- Privacy is a hard boundary (`docs/PRIVACY.md`, the "Privacy posture"
  paragraph in `CLAUDE.md`): the question and the excerpts go to the
  server; the student's name, grades, completions, due-date edits and
  earlier turns do not. Any proposal that sends more (history, the whole
  knowledge base, the ledger) is a privacy-policy change and must be
  labelled as one, with the exact sentence of `docs/PRIVACY.md` it would
  alter.

**What to research, with evidence from the code and from live data:**

1. **Answer quality on real questions.** Build a set of 20 to 30 questions
   a Penn student actually asks (deadlines, late policy, exam room and
   date, grading weights, "what did my professor say this week", "what do
   I need for lab", office hours, a concept from lecture). For each, trace
   what the phone would retrieve today and whether the pool even holds the
   answer. The live pool can be read through the Management API
   (`POST /v1/projects/ynetfjixexksxqrrkwsg/database/query`; counts,
   kinds, lengths and dates only, never a document body in the plan) and
   `ask_outcomes` tells you latency, hedge rate and empty answers over the
   last weeks. Classify each failure: not in the pool, in the pool but not
   retrieved, retrieved but the model answered badly, or answered but
   unverifiable (no source chip).
2. **Retrieval.** Is BM25 over 160-220-word passages the right unit for
   syllabi tables, Ed threads and announcement lists? Where would a cheap
   on-device embedding (`NLEmbedding`, already loaded lazily; the trap
   about it blocking the main thread is in `CLAUDE.md`) or a hybrid
   rerank help, and what does it cost on a phone? What does the unscoped
   retry do on real course codes (`CourseMatcher`)? Measure with the
   test fixtures and, if Olisa agrees, with his phone's
   `course-knowledge.json` read off the device (Commands in `CLAUDE.md`).
3. **Coverage.** The largest gap is Canvas Files. Lay out the options with
   their privacy cost: extension-collected files (what is built, what is
   missing, `docs/CHROME_EXTENSION.md` → Status), a phone path for PDFs
   named like a syllabus or schedule only, or server-side extraction. Say
   what `docs/PRIVACY.md` would have to say for each.
4. **The model side.** Read `ask/index.ts` and the `ask-canary` loop. Is
   the system prompt doing the right things (refusals when the excerpt is
   missing, dates, the sections block)? Would a cheaper or better model, a
   different hedge, or a two-step (retrieve-then-answer with a re-query)
   improve the median first word (1.9 to 3.0 s today) or correctness?
   Anything here is measured on `ask-canary` before `ask`, and a deploy
   needs Olisa's go.
5. **Product.** What should the tree do that it cannot: proactive answers
   (a daily "what changed" card), per-class memory of what the student
   asked, quick actions from an answer (open the post, add the task,
   set a reminder), spoken answers. Keep each to one paragraph with the
   privacy note.

**Deliverable:** `docs/TREE_IMPROVEMENT_PLAN.md`, committed and pushed to
`v8`, and a `ROADMAP.md` → Next entry pointing at it. The plan has: the
question set with its per-question verdict (a table), the failure
classification counts, a ranked list of improvements with for each the
expected effect, the files it touches, whether it needs a server deploy
or a privacy-policy change, a test prediction, and a risk; and an explicit
"not worth doing" list with reasons. Rank by effect on real questions per
hour of work, not by novelty. Write in the register of `CLAUDE.md`: prose
that says why, dated, no code in the plan. End by telling Olisa the three
things you would do first and what you need from him (a phone read, a
canary run, a decision).
