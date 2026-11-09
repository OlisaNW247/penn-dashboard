-- Checks 20261109090000_agent_hardening.sql: the rate function counts,
-- denies over the limit and restarts in a new window; the sweeper removes
-- what is expired and keeps what is live; both are service-role only.
-- Run after local_auth_stub.sql and every migration.

\set ON_ERROR_STOP on

set role service_role;

do $$
declare
  ok boolean;
begin
  -- (a) increments and denies over the limit.
  for i in 1..3 loop
    if not public.agent_rate_check('k1', 3, 3600) then raise exception 'hit % should be allowed', i; end if;
  end loop;
  if public.agent_rate_check('k1', 3, 3600) then raise exception 'hit 4 should be denied'; end if;
  if (select count from public.agent_rate_limits where key = 'k1') <> 4 then raise exception 'count not incremented'; end if;
  -- another key is independent.
  if not public.agent_rate_check('k2', 3, 3600) then raise exception 'k2 should be allowed'; end if;
  -- (b) a new window resets.
  update public.agent_rate_limits set window_start = now() - interval '2 hours' where key = 'k1';
  if not public.agent_rate_check('k1', 3, 3600) then raise exception 'new window should reset'; end if;
  if (select count from public.agent_rate_limits where key = 'k1') <> 1 then raise exception 'window did not restart at 1'; end if;
end $$;

-- Earlier test files leave their own expired rows behind; clear them so the
-- count below is exactly this file's.
select public.agent_sweep_expired();

insert into auth.users (id) values ('c3333333-3333-3333-3333-333333333333');

insert into public.agent_pending_auth
  (id, user_code, match_number, match_choices, nonce_hash, params, client_name, status, expires_at)
values
  ('sw-old', 'WXYZBCDF', 1, '{1,2,3}', 'n', '{}'::jsonb, 'c', 'pending', now() - interval '1 minute'),
  ('sw-live', 'GHJKLMNP', 1, '{1,2,3}', 'n', '{"clientId":"smc_used_by_pending"}'::jsonb, 'c', 'pending', now() + interval '5 minutes');

insert into public.agent_connections (id, user_id, client_id, client_name, scopes) values
  ('sw-conn', 'c3333333-3333-3333-3333-333333333333', 'smc_connected', 'c', '{}');

insert into public.agent_tokens (hash, kind, connection_id, resource, scopes, expires_at) values
  ('sw-tok-old', 'access', 'sw-conn', 'r', '{}', now() - interval '2 days'),
  ('sw-tok-recent', 'access', 'sw-conn', 'r', '{}', now() - interval '1 hour'),
  ('sw-tok-live', 'refresh', 'sw-conn', 'r', '{}', now() + interval '1 day');

insert into public.agent_rate_limits (key, window_start, count) values
  ('sw-rate-old', now() - interval '2 days', 1),
  ('sw-rate-new', now(), 1);

insert into public.agent_clients (client_id, client_name, redirect_uris, created_at) values
  ('smc_unused_old', 'c', '{}', now() - interval '31 days'),
  ('smc_connected', 'c', '{}', now() - interval '31 days'),
  ('smc_used_by_pending', 'c', '{}', now() - interval '31 days'),
  ('smc_unused_new', 'c', '{}', now() - interval '2 days');

do $$
declare
  n integer;
begin
  n := public.agent_sweep_expired();
  -- sw-old pending, sw-tok-old, sw-rate-old, smc_unused_old (k1/k2 rows are fresh).
  if n <> 4 then raise exception 'sweep removed %, expected 4', n; end if;
  if exists (select 1 from public.agent_pending_auth where id = 'sw-old') then raise exception 'expired pending survived'; end if;
  if not exists (select 1 from public.agent_pending_auth where id = 'sw-live') then raise exception 'live pending was removed'; end if;
  if exists (select 1 from public.agent_tokens where hash = 'sw-tok-old') then raise exception 'old token survived'; end if;
  if (select count(*) from public.agent_tokens where hash in ('sw-tok-recent', 'sw-tok-live')) <> 2 then raise exception 'recent/live token removed'; end if;
  if exists (select 1 from public.agent_rate_limits where key = 'sw-rate-old') then raise exception 'idle rate row survived'; end if;
  if not exists (select 1 from public.agent_rate_limits where key = 'sw-rate-new') then raise exception 'fresh rate row removed'; end if;
  if exists (select 1 from public.agent_clients where client_id = 'smc_unused_old') then raise exception 'unused old client survived'; end if;
  if (select count(*) from public.agent_clients where client_id in ('smc_connected', 'smc_used_by_pending', 'smc_unused_new')) <> 3 then
    raise exception 'a referenced or recent client was removed';
  end if;
end $$;

reset role;

-- (c) anon and authenticated cannot call or read.
do $$
declare
  r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    execute format('set role %I', r);
    begin
      perform public.agent_rate_check('x', 1, 1);
      raise exception '% could call agent_rate_check', r;
    exception when insufficient_privilege then null;
    end;
    begin
      perform public.agent_sweep_expired();
      raise exception '% could call agent_sweep_expired', r;
    exception when insufficient_privilege then null;
    end;
    begin
      perform 1 from public.agent_rate_limits;
      raise exception '% could read agent_rate_limits', r;
    exception when insufficient_privilege then null;
    end;
    reset role;
  end loop;
  raise notice 'agent_hardening: all checks passed';
end $$;
