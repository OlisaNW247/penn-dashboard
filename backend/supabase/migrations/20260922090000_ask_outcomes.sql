-- ---------------------------------------------------------------------
-- ask_outcomes: per-request telemetry for `ask`'s streamed answer -- the
-- "measure" half of the measure-fix-verify loop this migration exists for.
-- The real incident it is built to catch happening again, and go unnoticed
-- for a day, is 2026-09-14's: `z-ai/glm-5.3-flash` is a thinking model that
-- can spend the whole `MAX_TOKENS` cap on hidden reasoning and stream zero
-- `delta.content`, and until now the only trace of that was a
-- `console.warn` line in the function log that nobody was watching. This
-- table is deliberately separate from `ask_usage` above: `ask_usage` is a
-- day-granularity aggregate the quota check reads back, kept indefinitely;
-- this is a per-request row meant for debugging and rollup queries, with
-- no promise it is kept forever, and it is never read by any RPC a client
-- calls -- only ever written by `ask`/`ask-canary` and queried by hand.
--
-- Same "never store the content" discipline PROTOCOL.md's principle 2
-- states for course material extends here to the question and the answer:
-- this table has no column that could hold either. `detail` exists purely
-- to carry an error class or an upstream error message (already capped at
-- 400 characters by `_shared/openrouter.ts`'s `readErrorBody` before it
-- ever reaches here, and capped again to 200 on the way in) -- never the
-- question, the context document, the excerpts, or the model's answer.
-- `probe` tags a row as belonging to a specific `ask-canary` harness run
-- (or a hand-tagged call to production `ask` via the `x-lhf-probe`
-- header) rather than a real student's question; null for every ordinary
-- request.
-- ---------------------------------------------------------------------
create table public.ask_outcomes (
  id                 bigserial primary key,
  user_id            uuid not null references auth.users (id) on delete cascade,
  at                 timestamptz not null default now(),
  model              text not null,
  outcome            text not null check (outcome in (
    'answered', 'empty', 'upstream_error', 'quota', 'timeout', 'client_error'
  )),
  prompt_tokens      integer,
  completion_tokens  integer,
  reasoning_tokens   integer,
  cached_tokens      integer,
  content_chars      integer not null default 0,
  delta_count        integer not null default 0,
  latency_ms         integer,
  first_delta_ms     integer,
  upstream_status    integer,
  detail             text,
  probe              text
);

create index ask_outcomes_at_idx on public.ask_outcomes (at desc);

alter table public.ask_outcomes enable row level security;

-- No policies at all, on purpose -- like `directory_cache`
-- (20260907180000_websites.sql), this table has no legitimate reader
-- other than the service-role client inside `ask`/`ask-canary`, and there
-- is nothing here scoped to "the caller's own rows" the way `ask_usage`'s
-- `ask_usage_select_own` policy is: a request's outcome trail is a system
-- diagnostic, not something principle 4 promises a student can read back
-- about themselves. The explicit `revoke` below is belt-and-braces in the
-- same spirit as `directory_cache`'s comment on the same point: a
-- table-level grant that was never issued can't be leaked open later by a
-- policy-writing bug, so this is stated outright rather than left as
-- merely "nobody happened to grant it yet."
revoke all on public.ask_outcomes from anon, authenticated;
grant all on public.ask_outcomes to service_role;
-- `id bigserial` backs itself with a sequence that is a distinct grantable
-- object from the table (see the same note on `course_websites_id_seq` in
-- 20260907180000_websites.sql) -- service_role needs USAGE on it directly
-- or every INSERT relying on the default `id` fails with "permission
-- denied for sequence" despite the table grant above looking complete.
grant usage, select on sequence public.ask_outcomes_id_seq to service_role;

-- ---------------------------------------------------------------------
-- record_ask_outcome(): the only way ask_outcomes rows are written,
-- service_role-only for the same reason record_ask_usage is -- it takes
-- p_user_id as a parameter rather than reading auth.uid(), because the
-- `ask`/`ask-canary` edge functions run as service_role and already know
-- which user's request they just finished handling. Every column but
-- user_id/model/outcome is nullable and defaults to null (content_chars
-- and delta_count default to 0, matching the table's own defaults, since
-- those two are always known by the time this is called -- there is no
-- "didn't measure it" case for a count the caller itself is accumulating).
-- ---------------------------------------------------------------------
create function public.record_ask_outcome(
  p_user_id uuid,
  p_model text,
  p_outcome text,
  p_prompt_tokens integer default null,
  p_completion_tokens integer default null,
  p_reasoning_tokens integer default null,
  p_cached_tokens integer default null,
  p_content_chars integer default 0,
  p_delta_count integer default 0,
  p_latency_ms integer default null,
  p_first_delta_ms integer default null,
  p_upstream_status integer default null,
  p_detail text default null,
  p_probe text default null
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.ask_outcomes (
    user_id, model, outcome, prompt_tokens, completion_tokens, reasoning_tokens,
    cached_tokens, content_chars, delta_count, latency_ms, first_delta_ms,
    upstream_status, detail, probe
  )
  values (
    p_user_id, p_model, p_outcome, p_prompt_tokens, p_completion_tokens, p_reasoning_tokens,
    p_cached_tokens, coalesce(p_content_chars, 0), coalesce(p_delta_count, 0), p_latency_ms, p_first_delta_ms,
    p_upstream_status, p_detail, p_probe
  );
$$;

revoke execute on function public.record_ask_outcome(
  uuid, text, text, integer, integer, integer, integer, integer, integer, integer, integer, integer, text, text
) from public;
grant execute on function public.record_ask_outcome(
  uuid, text, text, integer, integer, integer, integer, integer, integer, integer, integer, integer, text, text
) to service_role;
