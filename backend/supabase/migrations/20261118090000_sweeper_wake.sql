-- ---------------------------------------------------------------------
-- The Sweeper wake (docs/SERVER_SWEEPER_DESIGN_2026-11-17.md §2). The phone
-- cannot be relied on to wake itself a few minutes before an alarm (iOS runs
-- background refresh when it likes), so it uploads a short list of minutes
-- at which it would like a silent nudge, and a once-a-minute job on the
-- server sends that nudge through Apple's push service. The nudge carries
-- nothing; on waking the phone looks at Canvas itself and cancels an alarm
-- for work that has been handed in.
--
-- What this table may hold is the whole privacy argument of the feature: a
-- device token and a list of minutes. NO column may ever name a course, an
-- assignment, a title, a URL, a grade, a completion or a submission state;
-- test/sweeper_wake.test.sql pins the column list so a later migration
-- cannot add one quietly. The moments are the only per-student fact, and
-- they are never logged.
--
-- Service role only, like the agent tables: no policy for `anon` or
-- `authenticated`, so the Data API can neither read nor write it.
-- Additive and re-runnable.
-- ---------------------------------------------------------------------

create table if not exists public.sweeper_wakes (
  device_token  text primary key,                           -- APNs token, hex, 64..200 chars (function-enforced)
  user_id       uuid not null references auth.users (id) on delete cascade,
  environment   text not null check (environment in ('production', 'development')),
  moments       timestamptz[] not null default '{}',        -- at most 24, minute grain, at most 48 h ahead (function-enforced)
  plan_hash     text,                                       -- the phone's 16 hex chars, so a repeat upload is recognisable
  updated_at    timestamptz not null default now(),
  last_sent_for timestamptz,                                -- the newest moment a push was claimed for (minute grain)
  failures      smallint not null default 0                 -- failed sends in a row (a 200 or an upload resets it); the tick deletes the row at 3
);
create index if not exists sweeper_wakes_user_idx on public.sweeper_wakes (user_id);

alter table public.sweeper_wakes enable row level security;
revoke all on public.sweeper_wakes from anon, authenticated;
grant all on public.sweeper_wakes to service_role;

-- The claim, in ONE statement, so two ticks that overlap (a slow one and the
-- next minute's) cannot both send for the same row: the row lock the UPDATE
-- takes makes the second tick wait, and when it resumes Postgres re-checks
-- the outer WHERE against the row's new version, which now reads
-- `last_sent_for = at_minute` and fails. That is why the `last_sent_for`
-- test is repeated in the outer WHERE: with it only in the subselect, the
-- second tick would update the row again after the wait (the subselect is
-- not re-evaluated). The test is `< at_minute` (or null), not the design's
-- `is distinct from`: it is the same once-per-minute rule, and additionally
-- a late claim for an older minute can never re-claim a row already claimed
-- for a newer one, which `is distinct from` would allow for two moments in
-- adjacent minutes.
--
-- `security definer`, service role only: the function writes the table, and
-- an `anon` or `authenticated` caller through /rest/v1/rpc must not be able
-- to burn every row's claim for a minute.
create or replace function public.claim_sweeper_wakes(at_minute timestamptz, max_rows integer)
returns table (device_token text, environment text, user_id uuid)
language sql
security definer
set search_path = public
as $$
  update public.sweeper_wakes w
     set last_sent_for = at_minute
   where w.device_token in (
           select s.device_token
             from public.sweeper_wakes s
            where at_minute = any (s.moments)
              and (s.last_sent_for is null or s.last_sent_for < at_minute)
            order by s.device_token
            limit greatest(max_rows, 0)
              for update skip locked
         )
     and (w.last_sent_for is null or w.last_sent_for < at_minute)
  returning w.device_token, w.environment, w.user_id;
$$;
revoke execute on function public.claim_sweeper_wakes(timestamptz, integer) from public, anon, authenticated;
grant execute on function public.claim_sweeper_wakes(timestamptz, integer) to service_role;

-- The tick's two writes to a claimed row, as single statements for the same
-- reason the claim is one: each must act on the row as it is now. A prune
-- that read the moments and wrote them back would overwrite, with a stale
-- list, one the phone uploaded in between. Service role only, like the claim.
create or replace function public.prune_sweeper_moments(tokens text[], before timestamptz)
returns integer
language sql
security definer
set search_path = public
as $$
  with changed as (
    update public.sweeper_wakes w
       set moments = array(select m from unnest(w.moments) m where m >= before)
     where w.device_token = any (tokens)
       and exists (select 1 from unnest(w.moments) m where m < before)
    returning 1
  )
  select count(*)::integer from changed;
$$;
revoke execute on function public.prune_sweeper_moments(text[], timestamptz) from public, anon, authenticated;
grant execute on function public.prune_sweeper_moments(text[], timestamptz) to service_role;

create or replace function public.bump_sweeper_failure(token text)
returns smallint
language sql
security definer
set search_path = public
as $$
  update public.sweeper_wakes w
     set failures = w.failures + 1
   where w.device_token = token
  returning w.failures;
$$;
revoke execute on function public.bump_sweeper_failure(text) from public, anon, authenticated;
grant execute on function public.bump_sweeper_failure(text) to service_role;

-- The clock. pg_cron calls the function through pg_net once a minute
-- (Supabase has no scheduled functions of its own). Both extensions are
-- enabled here, each in its own block that tolerates their absence: a bare
-- postgres:16 (backend/scripts/sql-check.sh) has neither, and the check must
-- still pass there, and on a project that has not enabled them yet the
-- migration still applies, with a notice, and the job is created by a
-- re-run once they are on (Integrations -> Cron in the dashboard).
do $do$
begin
  execute 'create extension if not exists pg_cron';
exception when others then
  raise notice 'pg_cron is not available here (%); the sweeper-wake-tick job is not scheduled', sqlerrm;
end
$do$;

do $do$
begin
  execute 'create extension if not exists pg_net';
exception when others then
  raise notice 'pg_net is not available here (%); the sweeper-wake-tick job is not scheduled', sqlerrm;
end
$do$;

-- `cron.schedule(name, schedule, command)` replaces a job of the same name,
-- so this is safe to run again. The URL and the tick secret are read from
-- Vault at each run and are created by hand once (`vault.create_secret`),
-- never in a migration: `sweeper_wake_tick_url` (the function's /tick URL)
-- and `sweeper_wake_tick_secret` (a random value that is also set as the
-- function secret LHF_SWEEPER_TICK_SECRET). A dedicated secret rather than
-- the service-role key, because any role that can log in to the database can
-- read a Vault value while the request waits, and a secret that can only
-- trigger a tick is the smaller blast radius. pg_net's default timeout is 2
-- seconds; the tick answers before it sends, and 5 seconds is the margin.
do $do$
begin
  if to_regnamespace('cron') is not null and to_regnamespace('net') is not null then
    perform cron.schedule(
      'sweeper-wake-tick',
      '* * * * *',
      $cmd$ select net.http_post(
              url     := (select decrypted_secret from vault.decrypted_secrets where name = 'sweeper_wake_tick_url'),
              headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'x-sweeper-tick-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sweeper_wake_tick_secret')),
              body    := '{}'::jsonb,
              timeout_milliseconds := 5000) $cmd$
    );
  else
    raise notice 'cron or net schema missing; the sweeper-wake-tick job is not scheduled';
  end if;
end
$do$;
