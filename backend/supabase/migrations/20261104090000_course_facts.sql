-- Phase 2 of the "composed day" (docs/DAY_PLANNER_RESEARCH_2026-11-03.md):
-- server-side fact extraction. A fact is one thing a course document says
-- that changes a student's work: a new task, or a cancel / reschedule /
-- scope change / note on an item the course already has (or a
-- `needs_review`). The extractor, its prompt and its checks are
-- `_shared/facts.ts`; this migration is where the results live.
--
-- Facts are COURSE-LEVEL and carry nothing personal. They are derived from
-- pooled course material (a course document every enrolled classmate already
-- shares), keyed by the numeric Canvas course id like everything else in the
-- pool, and they have no user id anywhere: not on a fact, not on the
-- extraction that produced it, not on the budget row that counted it. Which
-- student's upload happened to trigger an extraction is deliberately not
-- recorded. They are deleted with the course material: every table below
-- cascades from `courses` / `course_documents`.
--
-- Four tables and one function:
--   - course_fact_extractions: one row per (document_id, content_hash),
--     written even when the model found nothing, so a document is paid for
--     at most once per revision. It is also the outcome record for the call
--     (model, tokens, cost, latency, accepted/rejected counts, reject
--     reasons), the way `ask_outcomes` is for `ask`, and holds none of the
--     document's text or the model's quotes.
--   - course_facts: one row per accepted fact, with a monotonically
--     increasing `seq` the manifest serves as a cursor ("facts since N").
--   - fact_extraction_budget: per-course per-UTC-day counters.
--   - claim_fact_extraction(): the atomic "is this still pending, and is
--     there budget" step, run before the model call.
--   - course_documents.posted_at: when the post was made. Ed's `updatedAt`
--     is the last edit, not the post date (EXTRACT_FACTS_BENCH, "What the
--     bench taught"), and a relative date ("by Friday") resolves from the
--     post date, so the extractor needs one. Nullable: nothing sends it yet.
--
-- Idempotent on purpose (scripts/deploy-facts.mjs applies it through the
-- Management API and may be re-run): `if not exists` on tables, columns and
-- indexes, `create or replace` on the function, drop-then-create on the policy.
-- Never edit a table definition here after it has been applied; add a new
-- migration instead, because `if not exists` skips a changed table silently.
--
-- Apply this BEFORE deploying the functions that call it. `sync` only writes
-- `posted_at` when a client sends one, so it keeps working if deployed
-- first; `extract-facts` and the manifest's facts read fail soft (they log
-- and carry on) if the tables are missing, so neither order breaks a sync.

alter table public.course_documents
  add column if not exists posted_at timestamptz;

-- ---------------------------------------------------------------------
-- course_fact_extractions
-- ---------------------------------------------------------------------
-- status:
--   pending         the claim function made the row and has not decided yet
--   running         a model call is in flight (or died: see the 5 minute
--                   staleness rule in claim_fact_extraction)
--   done            finished; `fact_count` may be 0
--   failed          the model call or the parse failed; retried until
--                   `attempts` reaches 3, then left as it is (given up)
--   skipped_budget  a budget cap said no; tried again on a later call, so a
--                   day's exhausted course is picked up the next UTC day
create table if not exists public.course_fact_extractions (
  id                 bigint generated always as identity primary key,
  document_id        text not null references public.course_documents (id) on delete cascade,
  content_hash       text not null,
  course_id          text not null references public.courses (course_id) on delete cascade,
  status             text not null default 'pending' check (status in (
    'pending', 'running', 'done', 'failed', 'skipped_budget'
  )),
  attempts           integer not null default 0,
  fact_count         integer not null default 0,
  rejected_count     integer not null default 0,
  -- {"quote_not_in_text": 2, ...}: counts by reason, never the rejected
  -- facts themselves.
  reject_reasons     jsonb not null default '{}'::jsonb,
  model              text,
  prompt_tokens      integer,
  completion_tokens  integer,
  reasoning_tokens   integer,
  -- OpenRouter's own `usage.cost` when the response carries it, in USD;
  -- null when it does not. Never a guess from a price list.
  cost_usd           numeric(12, 6),
  latency_ms         integer,
  -- An error class or a budget reason, already capped by the caller. Never
  -- document text or model output.
  detail             text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (document_id, content_hash)
);

create index if not exists course_fact_extractions_course_idx
  on public.course_fact_extractions (course_id, status);

-- ---------------------------------------------------------------------
-- course_facts
-- ---------------------------------------------------------------------
create table if not exists public.course_facts (
  -- The cursor. Identity values are handed out in order but become visible
  -- in commit order, so a reader at cursor N can in principle miss a row
  -- numbered below N that committed late. The extractor inserts all of an
  -- extraction's facts in ONE statement, which shrinks that window to a
  -- single insert, and the manifest sends the highest `seq` it saw; a fact
  -- missed that way is still fixed by the next full read (`factsSince`
  -- absent). A client that wants zero risk can re-read from 0 now and then.
  seq                bigint generated always as identity primary key,
  extraction_id      bigint not null references public.course_fact_extractions (id) on delete cascade,
  course_id          text not null references public.courses (course_id) on delete cascade,
  document_id        text not null references public.course_documents (id) on delete cascade,
  content_hash       text not null,
  fact_type          text not null check (fact_type in (
    'new_task', 'cancel', 'reschedule', 'scope_change', 'note', 'needs_review'
  )),
  -- The sourceID the model named from the item index the extractor built:
  -- an assignment's Canvas source id, or "module:<source_id>" for a module.
  target_source_id   text,
  title              text,
  due_at             timestamptz,
  kind               text check (kind is null or kind in ('submission', 'preparation', 'event')),
  quote              text not null,
  confidence         text not null check (confidence in ('high', 'medium')),
  -- Copied from the document at extraction time so a fact reads on its own.
  posted_at          timestamptz,
  created_at         timestamptz not null default now()
);

create index if not exists course_facts_course_seq_idx on public.course_facts (course_id, seq);
create index if not exists course_facts_document_idx on public.course_facts (document_id);

-- ---------------------------------------------------------------------
-- fact_extraction_budget
-- ---------------------------------------------------------------------
-- One row per course per UTC day, counting extractions STARTED (a failed
-- call was still billed, so it is not refunded). No foreign key to
-- `courses` on purpose: the global monthly cap sums these rows, and a
-- course deleted mid-month must not hand its spend back to the cap.
-- Holds a course id and a count: nothing personal.
create table if not exists public.fact_extraction_budget (
  course_id    text not null,
  day          date not null,
  extractions  integer not null default 0,
  primary key (course_id, day)
);

create index if not exists fact_extraction_budget_day_idx on public.fact_extraction_budget (day);

-- ---------------------------------------------------------------------
-- claim_fact_extraction(): decide, before the model call, whether this
-- (document, revision) should be extracted now. Returns
--   'claimed'         go ahead; the row is `running`, `attempts` is up by one
--                     and a unit of both budgets is spent
--   'not_pending'     already done, given up (3 attempts), or being worked on
--                     by another call (a `running` row younger than 5 minutes)
--   'skipped_budget'  a cap said no; the row is `skipped_budget`
--
-- The limits are parameters so the Edge Function can read them from its
-- environment (FACTS_COURSE_DAILY_LIMIT, FACTS_MONTHLY_GLOBAL_LIMIT,
-- FACTS_COURSE_MONTHLY_LIMIT); the defaults here, 60 per course per UTC day,
-- 400 per course per calendar month and 5000 per calendar month across all
-- courses, are what runs when it passes nothing. The 60 is not a
-- per-document limit: a course posts a handful of documents a week, so it is
-- only ever reached by a first sync of a big course, and then it spreads the
-- backlog over days instead of one bill. The monthly cap is read, not
-- serialized, exactly like `reserve_ask_usage`'s global limit: it can
-- overshoot by the number of calls in flight, which is right for a budget
-- guard that must never become a lock every course waits behind. The
-- per-course counter IS atomic (`insert ... on conflict do update ... where
-- extractions < limit` re-checks against the newest row version).
--
-- A placeholder row is inserted first, so two concurrent claims for a new
-- pair serialize on its row lock instead of both inserting and one hitting
-- the unique constraint.
--
-- SECURITY DEFINER with the service-role-only grant below, like every
-- function that takes ids as parameters.
create or replace function public.claim_fact_extraction(
  p_document_id text,
  p_course_id text,
  p_content_hash text,
  p_max_attempts integer default 3,
  p_course_daily_limit integer default 60,
  p_monthly_global_limit integer default 5000,
  p_course_monthly_limit integer default 400
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day date := (now() at time zone 'utc')::date;
  v_month_start date := date_trunc('month', (now() at time zone 'utc')::date)::date;
  v_status text;
  v_attempts integer;
  v_updated timestamptz;
  v_month bigint;
  v_course_month bigint;
  v_used integer;
begin
  insert into public.course_fact_extractions (document_id, content_hash, course_id, status)
  values (p_document_id, p_content_hash, p_course_id, 'pending')
  on conflict (document_id, content_hash) do nothing;

  select e.status, e.attempts, e.updated_at
    into v_status, v_attempts, v_updated
    from public.course_fact_extractions e
   where e.document_id = p_document_id
     and e.content_hash = p_content_hash
     for update;

  if v_status = 'done' then
    return 'not_pending';
  end if;
  if v_status in ('failed', 'running') and v_attempts >= p_max_attempts then
    return 'not_pending';
  end if;
  if v_status = 'running' and v_updated > now() - interval '5 minutes' then
    return 'not_pending';
  end if;

  select coalesce(sum(b.extractions), 0)
    into v_month
    from public.fact_extraction_budget b
   where b.day >= v_month_start
     and b.day < (v_month_start + interval '1 month')::date;

  if v_month >= p_monthly_global_limit then
    update public.course_fact_extractions
       set status = 'skipped_budget', detail = 'monthly global cap', updated_at = now()
     where document_id = p_document_id and content_hash = p_content_hash;
    return 'skipped_budget';
  end if;

  -- Per-course monthly sub-cap: a few accounts uploading junk revisions of
  -- one course's material can burn that course's allowance, never the global
  -- one every other course shares. Read, not serialized, like the global sum.
  select coalesce(sum(b.extractions), 0)
    into v_course_month
    from public.fact_extraction_budget b
   where b.course_id = p_course_id
     and b.day >= v_month_start
     and b.day < (v_month_start + interval '1 month')::date;

  if v_course_month >= p_course_monthly_limit then
    update public.course_fact_extractions
       set status = 'skipped_budget', detail = 'course monthly cap', updated_at = now()
     where document_id = p_document_id and content_hash = p_content_hash;
    return 'skipped_budget';
  end if;

  insert into public.fact_extraction_budget (course_id, day, extractions)
  values (p_course_id, v_day, 1)
  on conflict (course_id, day) do update
    set extractions = public.fact_extraction_budget.extractions + 1
    where public.fact_extraction_budget.extractions < p_course_daily_limit
  returning extractions into v_used;

  if v_used is null then
    update public.course_fact_extractions
       set status = 'skipped_budget', detail = 'course daily cap', updated_at = now()
     where document_id = p_document_id and content_hash = p_content_hash;
    return 'skipped_budget';
  end if;

  update public.course_fact_extractions
     set status = 'running', attempts = attempts + 1, detail = null, updated_at = now()
   where document_id = p_document_id and content_hash = p_content_hash;
  return 'claimed';
end;
$$;

revoke execute on function public.claim_fact_extraction(text, text, text, integer, integer, integer, integer)
  from public, anon, authenticated;
grant execute on function public.claim_fact_extraction(text, text, text, integer, integer, integer, integer)
  to service_role;

-- ---------------------------------------------------------------------
-- RLS and grants. Same rule as the rest of the schema: no INSERT/UPDATE/
-- DELETE policy for anyone, writes are the service role's alone.
-- `course_facts` is readable by enrolled students exactly like
-- `course_profiles` (the manifest reads it as the service role, but a
-- client reading PostgREST directly sees only its own courses). The other
-- three are diagnostics and counters nobody but the functions reads: RLS
-- on, no policy, and the explicit revoke because Supabase's default
-- privileges hand every new table to anon and authenticated
-- (20261027090000_revoke_usage_functions.sql has the story).
-- ---------------------------------------------------------------------
alter table public.course_facts enable row level security;
alter table public.course_fact_extractions enable row level security;
alter table public.fact_extraction_budget enable row level security;

revoke all on public.course_facts from anon, authenticated;
grant select on public.course_facts to authenticated;
revoke all on public.course_fact_extractions from anon, authenticated;
revoke all on public.fact_extraction_budget from anon, authenticated;

grant all on public.course_facts, public.course_fact_extractions, public.fact_extraction_budget
  to service_role;

-- Re-runnable: `create policy` has no `if not exists`.
drop policy if exists course_facts_select_enrolled on public.course_facts;
create policy course_facts_select_enrolled
  on public.course_facts
  for select
  to authenticated
  using (public.is_enrolled(course_id));
