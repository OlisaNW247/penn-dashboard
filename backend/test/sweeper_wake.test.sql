-- Checks 20261118090000_sweeper_wake.sql: the table holds exactly the eight
-- columns (a device token and minutes, nothing that could name a course, an
-- assignment or a state), the Data API roles cannot touch it or the claim
-- function, the claim hands a row out once per minute and never for a minute
-- it has no moment at, and the row goes with the account. Run after
-- local_auth_stub.sql and every migration.

\set ON_ERROR_STOP on

-- (a) the column list is pinned.
do $$
declare
  cols text;
begin
  select string_agg(column_name, ',' order by column_name) into cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'sweeper_wakes';
  if cols is distinct from 'device_token,environment,failures,last_sent_for,moments,plan_hash,updated_at,user_id' then
    raise exception 'sweeper_wakes columns changed: %', cols;
  end if;
end $$;

insert into auth.users (id) values ('e5555555-5555-5555-5555-555555555555');

set role service_role;

insert into public.sweeper_wakes (device_token, user_id, environment, moments) values
  (repeat('a', 64), 'e5555555-5555-5555-5555-555555555555', 'production',
     array['2026-11-20 04:34:00+00', '2026-11-20 04:46:00+00']::timestamptz[]),
  (repeat('b', 64), 'e5555555-5555-5555-5555-555555555555', 'development',
     array['2026-11-20 09:00:00+00']::timestamptz[]);

do $$
declare
  n integer;
  got record;
begin
  -- (b) a row is claimed once for its minute, and not twice.
  select count(*) into n from public.claim_sweeper_wakes('2026-11-20 04:34:00+00', 100);
  if n <> 1 then raise exception 'first claim returned % rows, expected 1', n; end if;
  select count(*) into n from public.claim_sweeper_wakes('2026-11-20 04:34:00+00', 100);
  if n <> 0 then raise exception 'second claim returned % rows, expected 0', n; end if;
  if (select last_sent_for from public.sweeper_wakes where device_token = repeat('a', 64)) <> '2026-11-20 04:34:00+00' then
    raise exception 'last_sent_for was not set to the minute';
  end if;

  -- (c) a minute no row has a moment at claims nothing, and the answer
  -- carries the token, the environment and the user.
  select count(*) into n from public.claim_sweeper_wakes('2026-11-20 04:35:00+00', 100);
  if n <> 0 then raise exception 'a minute with no moment claimed % rows', n; end if;
  select * into got from public.claim_sweeper_wakes('2026-11-20 09:00:00+00', 100);
  if got.device_token <> repeat('b', 64) or got.environment <> 'development'
     or got.user_id <> 'e5555555-5555-5555-5555-555555555555' then
    raise exception 'claim answered the wrong row';
  end if;

  -- (d) the next moment of the same row is claimable (a later minute), and an
  -- older minute is not claimable again once a newer one was.
  select count(*) into n from public.claim_sweeper_wakes('2026-11-20 04:46:00+00', 100);
  if n <> 1 then raise exception 'the second moment of a row was not claimable'; end if;
  update public.sweeper_wakes set last_sent_for = '2026-11-20 04:46:00+00' where device_token = repeat('a', 64);
  select count(*) into n from public.claim_sweeper_wakes('2026-11-20 04:34:00+00', 100);
  if n <> 0 then raise exception 'an older minute was claimed after a newer one'; end if;

  -- (e) max_rows bounds the claim.
  insert into public.sweeper_wakes (device_token, user_id, environment, moments)
    select repeat(to_hex(i), 64), 'e5555555-5555-5555-5555-555555555555', 'production', array['2026-11-21 10:00:00+00']::timestamptz[]
      from generate_series(1, 5) i;
  select count(*) into n from public.claim_sweeper_wakes('2026-11-21 10:00:00+00', 3);
  if n <> 3 then raise exception 'max_rows 3 claimed % rows', n; end if;
  select count(*) into n from public.claim_sweeper_wakes('2026-11-21 10:00:00+00', 3);
  if n <> 2 then raise exception 'the remainder claimed % rows, expected 2', n; end if;

  -- (f) the environment check refuses anything but the two values.
  begin
    insert into public.sweeper_wakes (device_token, user_id, environment) values (repeat('c', 64), 'e5555555-5555-5555-5555-555555555555', 'staging');
    raise exception 'an unknown environment was accepted';
  exception when check_violation then null;
  end;
end $$;

-- (g) anon and authenticated can neither read nor write the table, nor call
-- the claim function.
reset role;
do $$
declare
  r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    execute format('set role %I', r);
    begin
      perform 1 from public.sweeper_wakes;
      raise exception '% could read sweeper_wakes', r;
    exception when insufficient_privilege then null;
    end;
    begin
      insert into public.sweeper_wakes (device_token, user_id, environment)
        values (repeat('d', 64), 'e5555555-5555-5555-5555-555555555555', 'production');
      raise exception '% could insert into sweeper_wakes', r;
    exception when insufficient_privilege then null;
    end;
    begin
      perform public.claim_sweeper_wakes(now(), 10);
      raise exception '% could call claim_sweeper_wakes', r;
    exception when insufficient_privilege then null;
    end;
    reset role;
  end loop;
end $$;

-- (h) deleting the account deletes its rows.
delete from auth.users where id = 'e5555555-5555-5555-5555-555555555555';
do $$
begin
  if exists (select 1 from public.sweeper_wakes) then
    raise exception 'sweeper_wakes rows outlived the account';
  end if;
  raise notice 'sweeper_wake: all checks passed';
end $$;
