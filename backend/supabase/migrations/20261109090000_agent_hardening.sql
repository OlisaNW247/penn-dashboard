-- ---------------------------------------------------------------------
-- Hardening for the agent connection (20261108090000_agent_connection.sql),
-- closing the three gaps PROTOCOL.md listed under Limitations:
--
--   1. `/phone deny` accepted any pending id from any signed-in student.
--      `agent_pending_auth.claimed_by` records which student last looked the
--      request up (by its typed code or its id), and `deny` now requires it.
--   2. No rate limits. `agent_rate_limits` and `agent_rate_check` count hits
--      per key per window in Postgres, because an Edge Function runs in many
--      isolates and an in-memory counter in each would multiply the limit by
--      however many happen to be warm.
--   3. Nothing swept expired rows. `agent_sweep_expired` does, called by
--      `agent-auth` on about one `/authorize` in fifty. pg_cron would be
--      better and needs the dashboard to enable; this is the no-dashboard
--      version.
--
-- Additive and re-runnable. Service role only, like every agent table.
-- ---------------------------------------------------------------------

alter table public.agent_pending_auth
  add column if not exists claimed_by uuid null references auth.users (id) on delete set null;

-- One row per key; `window_start` is when the current window opened.
-- Keys are written by the function as `<route>:<sha256 of the ip or user
-- id>`, never a raw address.
create table if not exists public.agent_rate_limits (
  key           text primary key,
  window_start  timestamptz not null default now(),
  count         integer not null default 0
);
create index if not exists agent_rate_limits_window_start_idx on public.agent_rate_limits (window_start);

alter table public.agent_rate_limits enable row level security;
revoke all on public.agent_rate_limits from anon, authenticated;
grant all on public.agent_rate_limits to service_role;

-- Counts one hit and answers whether it is within the limit. A single
-- INSERT ... ON CONFLICT DO UPDATE is atomic per key (the row lock makes two
-- racing callers count one after the other), so there is no read-then-write
-- gap to race through. An expired window restarts at 1 in the same
-- statement. A hit over the limit is still counted, which is harmless: the
-- window resets on its own clock, not on the last hit.
create or replace function public.agent_rate_check(p_key text, p_limit integer, p_window_seconds integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  insert into public.agent_rate_limits as r (key, window_start, count)
  values (p_key, now(), 1)
  on conflict (key) do update
    set count = case
          when r.window_start <= now() - make_interval(secs => p_window_seconds) then 1
          else r.count + 1
        end,
        window_start = case
          when r.window_start <= now() - make_interval(secs => p_window_seconds) then now()
          else r.window_start
        end
  returning r.count into v_count;
  return v_count <= p_limit;
end;
$$;

-- Deletes what nothing can use any more and returns how many rows went:
-- pending authorizations past their five minutes (which also covers
-- consumed and denied ones, whose codes expire inside that window), tokens
-- of either kind a day past their expiry (the day keeps a just-expired
-- refresh token answerable as "expired" rather than "unknown" for
-- diagnostics), and rate-limit rows idle for a day (no window is longer), and registered
-- clients older than 30 days that no connection or pending row names.
create or replace function public.agent_sweep_expired()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total integer := 0;
  v_n integer;
begin
  delete from public.agent_pending_auth where expires_at <= now();
  get diagnostics v_n = row_count;
  v_total := v_total + v_n;

  delete from public.agent_tokens where expires_at <= now() - interval '1 day';
  get diagnostics v_n = row_count;
  v_total := v_total + v_n;

  delete from public.agent_rate_limits where window_start <= now() - interval '1 day';
  get diagnostics v_n = row_count;
  v_total := v_total + v_n;

  -- Dynamically registered clients (RFC 7591) nothing has used for 30
  -- days: no connection of any state (a revoked one still names its client)
  -- and no pending authorization (whose params carry the id as clientId).
  delete from public.agent_clients c
  where c.created_at <= now() - interval '30 days'
    and not exists (select 1 from public.agent_connections k where k.client_id = c.client_id)
    and not exists (select 1 from public.agent_pending_auth p where p.params ->> 'clientId' = c.client_id);
  get diagnostics v_n = row_count;
  v_total := v_total + v_n;

  return v_total;
end;
$$;

revoke execute on function public.agent_rate_check(text, integer, integer) from public, anon, authenticated;
grant execute on function public.agent_rate_check(text, integer, integer) to service_role;
revoke execute on function public.agent_sweep_expired() from public, anon, authenticated;
grant execute on function public.agent_sweep_expired() to service_role;
