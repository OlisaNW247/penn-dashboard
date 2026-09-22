-- ---------------------------------------------------------------------
-- ask_outcomes gets two more nullable timing columns, and
-- record_ask_outcome grows two more trailing default-null parameters to
-- carry them: pre_race_ms (everything from the start of the request up to
-- the moment the model race begins -- auth, body parsing, the quota check,
-- and loading enrollment/profiles/catalog) and race_ms (the hedge/fallback
-- race itself, from the first model call to a winning delta or a failure).
-- `ask/index.ts` already measures both in its per-request `timing` record
-- (2026-09-22's per-step timing work, added after a 50-run canary soak
-- found one request took 10.2s to its first delta with the hedge never
-- firing -- the hedge timer only watches the model call, so the time had
-- gone into the database reads before it, and nothing measured them) and
-- already logs them in a `console.log` line; this migration is what lets
-- the same two numbers land in the outcome row too, so a rollup query can
-- see the pre-race/race split without grepping function logs. Both
-- nullable and default null, like every other measurement column on this
-- table, so an old row, or a caller mid-deploy that hasn't started passing
-- them yet, is not itself an error.
-- ---------------------------------------------------------------------
alter table public.ask_outcomes
  add column pre_race_ms integer,
  add column race_ms integer;

-- The old 14-parameter overload is dropped rather than left alongside the
-- new 16-parameter one. PostgREST's RPC dispatch resolves which overload to
-- call by matching the named JSON keys in the request body against a
-- parameter list, and two overloads that agree on every parameter but the
-- two new ones invite exactly the kind of ambiguous match Postgres's own
-- overload-resolution rules refuse for named-argument calls (it would raise
-- "could not choose a best candidate function" rather than silently picking
-- one). This function has exactly one caller -- the service-role edge
-- functions in this repo -- so there is no compatibility reason to keep the
-- old signature callable while a newer one exists alongside it.
drop function public.record_ask_outcome(
  uuid, text, text, integer, integer, integer, integer, integer, integer, integer, integer, integer, text, text
);

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
  p_probe text default null,
  p_pre_race_ms integer default null,
  p_race_ms integer default null
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.ask_outcomes (
    user_id, model, outcome, prompt_tokens, completion_tokens, reasoning_tokens,
    cached_tokens, content_chars, delta_count, latency_ms, first_delta_ms,
    upstream_status, detail, probe, pre_race_ms, race_ms
  )
  values (
    p_user_id, p_model, p_outcome, p_prompt_tokens, p_completion_tokens, p_reasoning_tokens,
    p_cached_tokens, coalesce(p_content_chars, 0), coalesce(p_delta_count, 0), p_latency_ms, p_first_delta_ms,
    p_upstream_status, p_detail, p_probe, p_pre_race_ms, p_race_ms
  );
$$;

revoke execute on function public.record_ask_outcome(
  uuid, text, text, integer, integer, integer, integer, integer, integer, integer, integer, integer, text, text, integer, integer
) from public;
grant execute on function public.record_ask_outcome(
  uuid, text, text, integer, integer, integer, integer, integer, integer, integer, integer, integer, text, text, integer, integer
) to service_role;
