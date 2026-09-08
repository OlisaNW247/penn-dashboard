-- Proves the RLS policies and the two ask_usage functions in
-- supabase/migrations/20260907000000_init.sql behave as PROTOCOL.md
-- requires. Run against a scratch database after local_auth_stub.sql and
-- the migration:
--
--   psql ... -f test/local_auth_stub.sql
--   psql ... -f supabase/migrations/20260907000000_init.sql
--   psql ... -v ON_ERROR_STOP=1 -f test/rls.test.sql
--
-- Every check is a `DO $$ ... RAISE EXCEPTION ... $$` block so a failure
-- aborts the script with a nonzero exit and a message naming what failed,
-- rather than silently printing a wrong row count that only a human would
-- notice.

\set ON_ERROR_STOP on

-- Two students and two courses, set up as the service role (which bypasses
-- RLS, matching how the sync/delete-account functions actually write).
set role service_role;

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'), -- student A
  ('22222222-2222-2222-2222-222222222222'); -- student B

insert into public.courses (course_id, code, name) values
  ('100', 'PHYS 151', 'Physics 151'),
  ('200', 'CIS 121', 'Data Structures');

insert into public.course_documents
  (id, course_id, course_code, kind, source_id, title, text, content_hash, fetched_at, gone_at)
values
  ('syllabus:100:1', '100', 'PHYS 151', 'syllabus', '1', 'Syllabus', 'live doc in course A', 'h1', now(), null),
  ('page:100:2',     '100', 'PHYS 151', 'page',     '2', 'Old page', 'gone doc in course A', 'h2', now(), now()),
  ('home:200:3',     '200', 'CIS 121',  'home',     '3', 'Home',    'live doc in course B', 'h3', now(), null);

-- Only student A is enrolled in course A; nobody is enrolled in course B.
insert into public.enrollments (user_id, course_id) values
  ('11111111-1111-1111-1111-111111111111', '100');

reset role;

set role service_role;
insert into public.course_profiles (course_id, profile, source_hash) values
  ('100', '{"latePolicy":"no late work"}'::jsonb, 'src-hash-100'),
  ('200', '{"latePolicy":"24 hour grace"}'::jsonb, 'src-hash-200');
reset role;

-- One catalog_courses row, deliberately not linked via any course's
-- catalog_code -- this table's whole point is that it needs no enrollment
-- gate (see the 20260907120000_catalog.sql migration's RLS comment), so
-- whether a course row happens to reference it is irrelevant to who can
-- read it.
set role service_role;
insert into public.catalog_courses (catalog_code, semester, title) values
  ('PHYS-0151', '2026C', 'Principles II');
reset role;

-- Impersonate student A the way PostgREST would: set the JWT claims GUC and
-- assume the `authenticated` role for the rest of the transaction.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);

do $$
declare
  n int;
begin
  select count(*) into n from public.course_documents where course_id = '100' and gone_at is null;
  if n <> 1 then
    raise exception 'expected student A to see 1 live doc in course A, saw %', n;
  end if;
end $$;

do $$
declare
  n int;
begin
  select count(*) into n from public.course_documents where id = 'page:100:2';
  if n <> 0 then
    raise exception 'expected student A NOT to see the gone doc in course A, saw %', n;
  end if;
end $$;

do $$
declare
  n int;
begin
  select count(*) into n from public.course_documents where course_id = '200';
  if n <> 0 then
    raise exception 'expected student A NOT to see any doc in course B (not enrolled), saw %', n;
  end if;
end $$;

do $$
declare
  n int;
begin
  select count(*) into n from public.courses where course_id = '200';
  if n <> 0 then
    raise exception 'expected student A NOT to see course B row, saw %', n;
  end if;
end $$;

do $$
declare
  n int;
begin
  select count(*) into n from public.course_profiles where course_id = '100';
  if n <> 1 then
    raise exception 'expected student A to see course A''s profile row, saw %', n;
  end if;
  select count(*) into n from public.course_profiles where course_id = '200';
  if n <> 0 then
    raise exception 'expected student A NOT to see course B''s profile row, saw %', n;
  end if;
end $$;

-- catalog_courses is the one table in this schema with no enrollment gate
-- at all -- student A can read it despite not being enrolled in any course
-- linked to it, because it's public registrar data, not shared-because-
-- enrolled course material.
do $$
declare
  n int;
begin
  select count(*) into n from public.catalog_courses where catalog_code = 'PHYS-0151';
  if n <> 1 then
    raise exception 'expected student A to see the catalog_courses row despite no enrollment link, saw %', n;
  end if;
end $$;

-- Writes: no INSERT policy exists for authenticated, so this must fail.
do $$
begin
  begin
    insert into public.course_documents
      (id, course_id, course_code, kind, source_id, title, text, content_hash, fetched_at)
    values
      ('page:100:9', '100', 'PHYS 151', 'page', '9', 'Injected', 'should not be allowed', 'h9', now());
    raise exception 'authenticated was able to INSERT into course_documents -- RLS/grant hole';
  exception
    when insufficient_privilege then
      -- expected: no INSERT grant for authenticated at all.
      null;
  end;
end $$;

do $$
begin
  begin
    insert into public.catalog_courses (catalog_code, semester, title)
    values ('CIS-9999', '2026C', 'Injected');
    raise exception 'authenticated was able to INSERT into catalog_courses -- RLS/grant hole';
  exception
    when insufficient_privilege then
      null;
  end;
end $$;

rollback;

-- Anonymous callers: no policy anywhere names `anon`, so every SELECT
-- returns zero rows even though the role does have table-level SELECT
-- privilege (RLS, not the grant, is what's doing the work here).
begin;
set local role anon;
select set_config('request.jwt.claims', '', true);

do $$
declare
  n int;
begin
  select count(*) into n from public.course_documents;
  if n <> 0 then
    raise exception 'expected anon to see zero course_documents rows, saw %', n;
  end if;
end $$;

do $$
declare
  n int;
begin
  select count(*) into n from public.courses;
  if n <> 0 then
    raise exception 'expected anon to see zero courses rows, saw %', n;
  end if;
end $$;

do $$
declare
  n int;
begin
  -- catalog_courses' policy names only `authenticated` (see the migration's
  -- RLS comment) -- being public registrar data doesn't mean it's served
  -- to a caller with no session at all.
  select count(*) into n from public.catalog_courses;
  if n <> 0 then
    raise exception 'expected anon to see zero catalog_courses rows, saw %', n;
  end if;
end $$;

rollback;

-- Student A cannot read student B's private rows even though both are
-- `authenticated` -- enrollments/ask_usage policies key on auth.uid(), not
-- on role membership.
set role service_role;
insert into public.enrollments (user_id, course_id) values
  ('22222222-2222-2222-2222-222222222222', '200');
reset role;

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);

do $$
declare
  n int;
begin
  select count(*) into n from public.enrollments where user_id = '22222222-2222-2222-2222-222222222222';
  if n <> 0 then
    raise exception 'expected student A NOT to see student B''s enrollment row, saw %', n;
  end if;
end $$;

do $$
declare
  n int;
begin
  select count(*) into n from public.enrollments where user_id = '11111111-1111-1111-1111-111111111111';
  if n <> 1 then
    raise exception 'expected student A to see their own enrollment row, saw %', n;
  end if;
end $$;

rollback;

-- record_ask_usage / ask_usage_counts, exercised as service_role (the only
-- role granted EXECUTE on them -- see the migration's grant comments).
set role service_role;

select public.record_ask_usage('11111111-1111-1111-1111-111111111111'::uuid, 100::bigint, 50::bigint);
select public.record_ask_usage('11111111-1111-1111-1111-111111111111'::uuid, 20::bigint, 10::bigint);
select public.record_ask_usage('22222222-2222-2222-2222-222222222222'::uuid, 5::bigint, 5::bigint);

do $$
declare
  r record;
begin
  select * into r from public.ask_usage
    where user_id = '11111111-1111-1111-1111-111111111111' and day = (now() at time zone 'utc')::date;
  if r.requests <> 2 then
    raise exception 'expected 2 requests recorded for student A today, got %', r.requests;
  end if;
  if r.prompt_tokens <> 120 or r.completion_tokens <> 60 then
    raise exception 'expected token totals 120/60 for student A, got %/%', r.prompt_tokens, r.completion_tokens;
  end if;
end $$;

do $$
declare
  r record;
begin
  select * into r from public.ask_usage_counts('11111111-1111-1111-1111-111111111111'::uuid);
  if r.today_requests <> 2 then
    raise exception 'expected today_requests=2 for student A, got %', r.today_requests;
  end if;
  if r.month_requests <> 3 then
    raise exception 'expected month_requests=3 (global, all users this month), got %', r.month_requests;
  end if;
end $$;

do $$
declare
  r record;
begin
  -- A user with no rows at all: functions must return zeros, not null/error.
  select * into r from public.ask_usage_counts('33333333-3333-3333-3333-333333333333'::uuid);
  if r.today_requests <> 0 then
    raise exception 'expected today_requests=0 for a user with no usage, got %', r.today_requests;
  end if;
  -- month_requests is global, so it still reflects the other two users.
  if r.month_requests <> 3 then
    raise exception 'expected month_requests=3 (global) regardless of caller, got %', r.month_requests;
  end if;
end $$;

reset role;

-- Direct RPC of the service-role-only functions must be refused to
-- ordinary authenticated callers -- these take a user id as a parameter
-- rather than trusting auth.uid(), so letting anyone call them would let a
-- student forge or read another student's quota usage.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);

do $$
begin
  begin
    perform public.record_ask_usage('11111111-1111-1111-1111-111111111111'::uuid, 1::bigint, 1::bigint);
    raise exception 'authenticated was able to call record_ask_usage directly -- grant hole';
  exception
    when insufficient_privilege then
      null;
  end;
end $$;

do $$
begin
  begin
    perform public.ask_usage_counts('11111111-1111-1111-1111-111111111111'::uuid);
    raise exception 'authenticated was able to call ask_usage_counts directly -- grant hole';
  exception
    when insufficient_privilege then
      null;
  end;
end $$;

rollback;

\echo 'rls.test.sql: all checks passed'
