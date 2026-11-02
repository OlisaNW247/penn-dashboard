# Giving the tree better context to reason with (research, 2026-11-02)

Written 2026-11-02 on `v8` at Marco's request, after the first phone build
of the tree work (`docs/TREE_IMPROVEMENT_PLAN.md` → Status). His verdict
on that build, in his words: the model reasons poorly; before each call it
needs to prioritise recent announcements when the question is about today
or recency, and it is not doing that; when the question is a general one
it can lean on the syllabus and the rest. Olisa's case from the recording:
he asked whether he had class today, he did not (an Ed post from the day
before said so), and the tree said he did.

This page is research, not a plan that has been agreed. Part 1 is what
the code does today, with line references so nobody has to re-derive it.
Part 2 is what the literature says works, with sources. Part 3 is the
order I would do it in, with what each step costs. Part 4 is how to know
it worked. Paths: `Kit/` is `LowHangingFruitKit/Sources/LowHangingFruitKit/`,
`UI/` is `LowHangingFruitKit/Sources/LowHangingFruitUI/`.

## 1. What the model is given today

The messages are assembled in `backend/supabase/functions/_shared/prompt.ts:214-266`,
in this order:

1. The system instructions (`prompt.ts:34-156`).
2. The cached context document the phone built
   (`Kit/Assistant/AssistantContextDocument.swift:200-232`): a header,
   `# CLASSES` (code, name, grading categories; **no meeting times**),
   `# WORK` (one line per item, due time with the student's UTC offset,
   done/outstanding, sorted by due date, **not windowed**: past, done and
   far-future items are all there), and an empty `# ANNOUNCEMENTS`
   (`UI/AssistantContextAssembly.swift:143`; announcements arrive as work
   items). Byte-stable on purpose, for the prompt cache, so it never
   reads a clock and has no "today" marker.
3. `COURSE STRUCTURE`: the registrar's components and a "Sections:"
   sentence with weekly days, times and room (`prompt.ts:239-247`,
   `_shared/catalog.ts:741-748`). **This is the only place the weekly
   schedule exists**, and only for Penn catalog codes.
4. `COURSE PROFILES`, the syllabus extractions, as JSON (`prompt.ts:249-252`).
5. The conversation history (last 3 exchanges from the phone, capped at
   6,000 characters; server cap 10 turns / 8,000; `Kit/Assistant/ConversationHistory.swift:39-40`,
   `prompt.ts:302-311`).
6. The user message: `Current date: <askedAt>` as a UTC instant, then the
   excerpts block, then `QUESTION:` (`prompt.ts:259-263`).

The excerpts block (`UI/BackendAssistantResponder.swift:387-496`) opens
with the student's local date, time and zone (`:543-555`), then a header
and, when they apply, an Ed note and a recency note (`:564-579`), then up
to 8 passages of at most 1,500 characters, 3 per document, each tagged
`[n] COURSE · kind · posted Oct 3 · "title": body` (`:487`). Only Ed
posts and announcements carry a `posted` date (`:651`, `:670-683`);
syllabus, page, file and website passages have no date at all.

How the 8 passages are chosen:

- **BM25** (`Kit/Knowledge/CourseSearch.swift:172-207`, `BM25Index.swift`)
  over 160-220 word passages, `score = BM25 × kindBoost × componentBoost`.
  Syllabus ×1.35 when the query has a policy word (policy, late, grading,
  attendance, exam, midterm, office hours), else ×1.1 (`:246-248`).
  Announcement and Ed ×1.4 only when the query literally contains
  announce, said, posted, update, news, cancel, reschedul, moved or change
  (`:253-255`). "Today", "tomorrow" and "class" boost nothing. A pool of
  `max(limit×6, 30)` is reranked by Apple's sentence embedding when it is
  loaded (0.65 BM25 + 0.35 cosine, `:289-309`), then cut to 8. **There is
  no time decay anywhere in scoring.**
- **RecencyIntent** (`Kit/Assistant/RecencyIntent.swift`) is regex keyword
  matching with two kinds. `.news` (`:83-86`, `:116-120`, `:146-178`)
  fires on a recency word, or a posting noun plus a time phrase, and
  yields a look-back window in days. `.meeting` (`:91-93`, `:132-139`) fires
  on a meeting noun plus a presence word or a near-time word, 14-day
  window, at most 4 posts. Picks come only from Ed posts and
  announcements, first passage only, newest first, and are placed
  **in front of** BM25's hits (`BackendAssistantResponder.swift:427-464`,
  `:605-648`). `.news` may take all 8 slots, leaving none for the
  syllabus. Its output is a kind and a window, never a target date.
- **Due-date questions deliberately do not fire recency**
  (`RecencyIntent.swift:34-38`). "What's due tomorrow" is answered from the
  unwindowed `# WORK` lines plus the local-date line. No code selects or
  filters those lines by the asked-about day; it rests entirely on the
  model reading ISO timestamps against the date line.
- The server passes excerpts through verbatim (`prompt.ts:259-262`). Its
  prompt says the weekly schedule never says whether a class meets on a
  given day (`:83-98`), prefer the newer excerpt when two disagree
  (`:109-112`), prefer excerpts for policy questions (`:100-105`). It says
  nothing about how to read "today / tomorrow / this week" against the
  work list, and the date appears twice in different forms (UTC
  `Current date:` and the local line).

### Why Olisa's question failed, read against this

"Do I not have cis 2620 class today?" shares no BM25 term with "No
lectures this week but quiz on Monday". Before the `.meeting` kind the
only retrieval was BM25, so the post was never sent, and the model
answered from the one place meeting times exist, `COURSE STRUCTURE`. The
`.meeting` kind (2026-11-02) fixes this one shape by keyword. It does not
fix the class of problem: nothing classifies the question's time frame,
nothing resolves "today" to a date before retrieval, nothing weights
freshness in scoring, and nothing tells the model, in computed words,
that a post newer than the schedule exists. The weekly schedule and the
posts are never put side by side by code; the model is left to notice.

## 2. What the literature says

Every source below points the same way: decide the time frame and the
freshness in deterministic code before the model call, and hand the
model a pre-ordered, labelled context with an explicit authority rule.
A smarter model or a second model call is not what the evidence
recommends. ("Verified" means the abstract or doc page was read on
2026-11-02; "unverified" means a search summary only.)

**Intent classification and routing.** Adaptive-RAG (Jeong et al., KAIST,
NAACL 2024, arXiv:2403.14403, verified) classifies each query and routes
it to no retrieval, single-step or multi-step retrieval, and beats a
one-size pipeline on accuracy and cost. Our classes are few (class
meeting, due this day, recent news, policy/general, specific fact), so a
rule-based classifier is a legitimate baseline at zero latency; a
model-based router would add a server round trip for no shown gain.
Self-RAG (arXiv:2310.11511) needs a fine-tuned model and does not apply.

**Time-aware ranking.** TempRALM (Gade and Jetcheva, 2024,
arXiv:2401.13222) adds a temporal relevance term beside semantic
relevance, no retraining, up to 74% over ATLAS on its benchmark
(unverified numbers). MRAG (Zhang et al., Findings of EMNLP 2025,
arXiv:2412.15540, verified) is training-free: split the question into
content and a temporal constraint, retrieve, then rank with separate
semantic and temporal scores; about +9% top-1 answer recall on
TempRAGEval. A half-life recency prior blended with similarity
(Grofsky 2025, arXiv:2509.19376, verified) took "newest relevant item in
top 10" from 0.00 to 0.60 on a narrow corpus, with the author's own
warning that gains are parameter-sensitive: **tune the half-life per
intent, never apply decay globally** (a late policy is not fresher for
being reposted). FreshLLMs (Vu et al., Google 2023, arXiv:2310.03214,
verified) is the direct precedent for our excerpts block: dated evidence
in the prompt, ordered by date, +49 points strict accuracy on time-varying
questions over vanilla GPT-4.

**Date resolution before retrieval.** No single canonical paper; MRAG's
temporal-constraint extraction is the nearest. The repeated finding is
that the model should not do the calendar arithmetic. Test of Time
(Fatemi, Kazemi et al., DeepMind, ICLR 2025, arXiv:2406.09170, verified)
separates temporal semantics from arithmetic and finds both the
arithmetic and the order of facts move accuracy. So "today", "tomorrow",
"this Thursday", "this week" should become ISO dates on the phone, and
every passage should carry an absolute date **and** a precomputed
relative age ("posted 2026-11-01, yesterday").

**Hybrid retrieval and labelled chunks.** Anthropic's Contextual Retrieval
(engineering post, 2024-09, verified) prepends a short situating context
to each chunk before indexing; top-20 retrieval failures fell 5.7% →
3.7% with contextual embeddings and 2.9% with contextual BM25 too. For
us the situating text is cheap and needs no model: "Ed post, CIS 2620,
posted 2026-11-01". It gives BM25 date and kind tokens to match and the
model a label. Reciprocal rank fusion of BM25 and embeddings is the
standard merge (Elastic's BEIR figures, vendor, +18% NDCG over BM25
alone). Rerankers (Cohere Rerank v3.5/4) do not weight dates themselves,
add a network hop, and I found no evidence they help on a corpus of a
few thousand passages; defer.

**Context order and the authority rule.** Lost in the Middle (Liu et al.,
TACL 2024, arXiv:2307.03172, verified): accuracy is highest with the
relevant evidence at the start or end and falls in the middle, and falls
as the context grows. OpenAI's GPT-4.1 prompting guide (verified):
instructions at both the beginning and the end of the context; Markdown
or `ID | TITLE | CONTENT` delimiters do well, JSON poorly (our
`COURSE PROFILES` is JSON); the model follows instructions literally and,
on conflict, "tends to follow the one closer to the end of the prompt".
Anthropic's guidance (verified, Claude-specific but structural): one
block per document with source and date metadata, documents above the
question. The knowledge-conflicts survey (Xu et al., EMNLP 2024,
arXiv:2403.08319) names "outdated information" as a conflict type and
reports a bias toward frequent, standing evidence over a single outlier
(unverified), which is exactly a weekly schedule against one cancellation
post.

**Two-pass and agentic retrieval.** Rewrite-Retrieve-Read
(arXiv:2305.14283) and HyDE (arXiv:2212.10496) each add a model call
before retrieval; HyDE targets vocabulary mismatch in open-domain dense
retrieval, not a temporal override. A first call that decides what to
fetch costs a full round trip (1-3 s) against Olisa's ten-second rule
and the 5 s hedge. A rule-based planner on the phone gives most of the
benefit at zero latency; keep a second pass for the rare multi-class or
multi-hop question, if those appear in the outcomes.

**Evaluation.** RAGAS (arXiv:2309.15217) measures faithfulness and
relevance, not temporal correctness: an answer faithfully built from the
stale schedule scores well. FreshQA's design is the template: classify
questions by how fast the answer changes, include false premises, grade
strict and relaxed. Grofsky's Latest@k ("is the newest relevant post in
the context") is the retrieval metric we lack.

## 3. What I would do, in order

Each step is independent and can be measured on its own. Costs are
on-phone unless said.

1. **A time-frame resolver on the phone** (`Kit`, pure, tested). Input:
   the question, the student's local `Date` and zone. Output: an intent
   (`classMeeting`, `dueOn(dayRange)`, `recentNews(window)`,
   `policy`, `specific`), and for the first three an absolute date range
   ("today" = 2026-11-02; "tomorrow"; "this week" = through Sunday;
   weekday names = the next such day; "tonight" = today). Replace
   `RecencyIntent`'s kind-plus-window with this, keeping its word lists
   as the first classifier. Zero latency. Everything below reads it.
2. **A freshness term in scoring, per intent.** For `classMeeting` and
   `recentNews`, blend a half-life decay on the post's `postedAt` into
   the score for dated kinds (ed, announcement), half-life a few days;
   for `policy` and `specific`, no decay and the existing syllabus boost
   raised. For `dueOn`, retrieval is secondary (the work list answers);
   send posts from the range's course set that mention the item. This is
   MRAG/TempRALM in twenty lines of `CourseSearch`; measurable with
   Latest@8 in `swift test`.
3. **Per-intent budgets instead of "picks in front".** `classMeeting`:
   the course's newest dated posts (14 days, up to 4) **and** a computed
   line with the weekly schedule for the asked day, side by side, then
   BM25 fills to 8. `policy`: syllabus passages first, at least 4 slots
   reserved, dated posts only if they match the policy words. `recentNews`:
   as today, but cap at 6 so two BM25 hits survive. `dueOn`: filter the
   `# WORK` lines to the resolved range in the *user message* (never in
   the cached document, which stays byte-stable), as a short computed
   list, with the date line. The model then reads "due 2026-11-03" next
   to "tomorrow is 2026-11-03" rather than doing arithmetic across 400
   lines.
4. **Dated, situated passage labels.** Every passage gets kind, course,
   absolute date and relative age in its label, and syllabus/page/file
   passages get the document's `updatedAt` so a "newer wins" rule can
   compare them. At ingest, prepend the same one-line situating text to
   the indexed passage (Contextual Retrieval without a model). Changes
   `CourseKnowledgeStore` on-device only; the pool on the server is
   untouched.
5. **A computed verdict line for the model, when code can decide.** For
   `classMeeting`, shaped like: "Weekly schedule: <the course's sections
   sentence for the asked weekday>. Newer notice: 'No lectures this week
   but quiz on Monday' (Ed, posted 2026-11-01, yesterday). A dated post
   newer than the schedule overrides it." Written by the phone from the catalog schedule (which
   needs the sections sentence sent to the phone, or the phone's own
   class setup) and the newest matching post. The model then has nothing
   to notice, only to say. Put the authority rule at the **end** of the
   user message, right before `QUESTION:`, where the GPT-4.1 guide says
   conflicts resolve.
6. **Server prompt, one pass** (`prompt.ts`, a canary deploy): one
   `Current date` form only (the local line; drop the UTC instant or
   label it), a sentence on reading "today / tomorrow / this week"
   against the work list's dates, and the profiles as Markdown rather
   than JSON. Measured on `ask-canary` before `ask`.
7. **Defer**: rerankers, HyDE, a planning call, a fine-tuned router.
   None of the evidence found addresses this failure, and each costs
   latency or money we have budgets against.

Steps 1-5 are phone code, land in one `v8` branch, and ship with the
next build; nothing on the server changes until step 6. Steps 1, 2 and
4 are pure Kit and can be proven in `swift test` with a pinned clock;
3 and 5 need the schedule on the phone (today it is server-side only,
`catalog.ts:741-748`), which is the one design question to settle first:
send the sections sentence down with the course profiles, or build it
from the student's class setup.

## 4. How to know it worked

- **A frozen regression set in `swift test`** (30-60 cases): a passage
  set, a context document, and a pinned "now". Cases: schedule vs a
  later cancellation; schedule vs a later room change; schedule vs an
  *earlier*, stale cancellation that must not override; a policy question
  with a recent unrelated post; "tomorrow" and "this week" resolution
  across a month boundary and a Sunday; a deadline moved by an
  announcement; "no recent post, so use the schedule"; a false premise
  ("do I not have class" when there is one). Assert on structured
  outputs, not prose: the resolved range, the intent, which passages
  were sent and in what order, and Latest@8 (the newest relevant post is
  in the block). No model involved, so it runs on every push.
- **The same cases through `ask-canary`** with the existing
  `ask-probe.mjs` loop and a tag, graded strict on fields (class held
  yes/no, the date named, the post cited in `<sources>`), tracked across
  prompt versions in `ask_outcomes`. Needs `LHF_PROBE_SECRET`, which
  Olisa holds.
- **On a phone**, the recording's question and Marco's two shapes: a
  class-meeting question the day after a cancellation post, and "what's
  due tomorrow" after 8 pm Eastern. Record each in CLAUDE.md → Known
  gaps as the hand-off asks.

## Sources

- Jeong et al., Adaptive-RAG, NAACL 2024, https://arxiv.org/abs/2403.14403
- Asai et al., Self-RAG, 2023, https://arxiv.org/abs/2310.11511
- Gade & Jetcheva, TempRALM, 2024, https://arxiv.org/abs/2401.13222
- Zhang et al., MRAG, Findings of EMNLP 2025, https://arxiv.org/abs/2412.15540
- Grofsky, recency prior with half-life, 2025, https://arxiv.org/abs/2509.19376
- Vu et al., FreshLLMs / FreshQA, Google, 2023, https://arxiv.org/abs/2310.03214
- Ma et al., Query Rewriting for RAG, EMNLP 2023, https://arxiv.org/abs/2305.14283
- Gao et al., HyDE, ACL 2023, https://arxiv.org/abs/2212.10496
- Liu et al., Lost in the Middle, TACL 2024, https://arxiv.org/abs/2307.03172
- Fatemi, Kazemi et al., Test of Time, ICLR 2025, https://arxiv.org/abs/2406.09170
- Xu et al., Knowledge Conflicts for LLMs: A Survey, EMNLP 2024, https://arxiv.org/abs/2403.08319
- Es et al., RAGAS, 2023, https://arxiv.org/abs/2309.15217
- Anthropic, Contextual Retrieval, 2024-09, https://www.anthropic.com/engineering/contextual-retrieval
- Anthropic, prompting best practices, https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices
- OpenAI, GPT-4.1 prompting guide, https://developers.openai.com/cookbook/examples/gpt4-1_prompting_guide
- Elastic, hybrid retrieval on BEIR, https://www.elastic.co/search-labs/blog/improving-information-retrieval-elastic-stack-hybrid
- Cohere, Rerank docs, https://docs.cohere.com/docs/rerank
- Unverified, seen only in search summaries: RAGRouter-Bench (arXiv:2604.03455), the HoH outdated-information benchmark (2025).
