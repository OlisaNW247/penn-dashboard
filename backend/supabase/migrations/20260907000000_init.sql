-- LHF backend schema, v1. See backend/PROTOCOL.md for the wire contract this
-- schema serves; this file is the storage half of that contract and should
-- not drift from it without updating both.
--
-- Design note that governs every choice below: principle 2 of the protocol
-- is that only *course-level* material is shared -- syllabus, pages,
-- modules, assignment descriptions, announcements -- and never anything
-- student-specific (grades, completions, submission state, names,
-- transcripts). That is why `course_documents` has no `submitted` column:
-- submission state is a per-student fact and has no business living in a
-- table keyed only by course + source id and readable by every enrolled
-- student. Stripping it happens again defensively in the sync function and
-- in the manifest validator, but the schema itself should make it
-- impossible to accidentally persist by simply not having a column to put
-- it in.

-- ---------------------------------------------------------------------
-- courses: one row per Canvas course site, shared across every student
-- enrolled in it. The Canvas numeric course id is the sharing key (protocol
-- principle 3), so it is the primary key here rather than a surrogate.
-- ---------------------------------------------------------------------
create table public.courses (
  course_id          text primary key,
  code               text not null,
  name               text not null,
  url                text,
  term               text,
  first_seen_at      timestamptz not null default now(),
  last_full_sync_at  timestamptz,
  -- Set true by the upload step when a syllabus/home/page document's
  -- content hash changes, so extract-profile knows which courses need a
  -- fresh course_profiles row without re-deriving that from document
  -- history every time it runs.
  profile_stale      boolean not null default false
);

-- ---------------------------------------------------------------------
-- course_documents: the shared material itself. Rows are never deleted on
-- a normal sync -- a document that disappears from a fully-synced course's
-- feed is marked `gone_at` rather than dropped, mirroring the on-device
-- ledger's "nothing is ever silently lost" rule and letting the client
-- reason about "did this really go away" versus "did I just not upload it
-- this run". `gone_at is null` is the definition of "live".
-- ---------------------------------------------------------------------
create table public.course_documents (
  id                 text primary key,
  course_id          text not null references public.courses (course_id) on delete cascade,
  -- Denormalized alongside course_id: it is part of the wire shape and
  -- callers (ask's context builder, profile extraction) want the human
  -- course code without a join back to `courses` for every document.
  course_code        text not null,
  kind               text not null check (kind in ('home', 'syllabus', 'assignment', 'announcement', 'module', 'page')),
  source_id          text not null,
  title              text not null,
  url                text,
  text               text not null,
  content_hash       text not null,
  updated_at         timestamptz,
  fetched_at         timestamptz not null,
  due_at             timestamptz,
  points_possible    double precision,
  first_seen_at      timestamptz not null default now(),
  gone_at            timestamptz
);

-- Every read path in the protocol ("live docs for these courses") filters
-- on course_id with gone_at is null; a partial index keeps that cheap and
-- keeps gone documents (expected to accumulate and never be deleted) out
-- of the index entirely.
create index course_documents_live_by_course_idx
  on public.course_documents (course_id)
  where gone_at is null;

-- ---------------------------------------------------------------------
-- course_profiles: the extract-profile output, one row per course. Kept
-- separate from `courses` (rather than a jsonb column there) so a profile
-- rebuild is a single-row upsert independent of the sync path's writes to
-- `courses`, and so `source_hash` can record exactly what input produced
-- this profile without overloading course_documents' own hashes.
-- ---------------------------------------------------------------------
create table public.course_profiles (
  course_id     text primary key references public.courses (course_id) on delete cascade,
  profile       jsonb not null,
  source_hash   text not null,
  model         text,
  updated_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- enrollments: the *only* place a user id and a course id meet. Per the
-- protocol's recorded limitation, this is asserted by the client (listing
-- a course in a manifest call *is* the enrollment proof) rather than
-- proven against Canvas, because proving it would require the server to
-- hold Canvas credentials, which principle 1 forbids outright. This table
-- is intentionally the sole gate `is_enrolled()` below consults.
-- ---------------------------------------------------------------------
create table public.enrollments (
  user_id         uuid not null references auth.users (id) on delete cascade,
  course_id       text not null references public.courses (course_id) on delete cascade,
  section_ids     text[] not null default '{}',
  first_seen_at   timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  primary key (user_id, course_id)
);

create index enrollments_course_id_idx on public.enrollments (course_id);

-- ---------------------------------------------------------------------
-- ask_usage: per-user, per-UTC-day request/token counters backing both the
-- per-user daily quota and the global monthly quota in the protocol. A day
-- granularity row (rather than one row per request) keeps this table's
-- size bounded by users x days rather than users x questions, which
-- matters because "questions and answers are never stored" -- there is
-- deliberately nothing here to reconstruct a conversation from.
-- ---------------------------------------------------------------------
create table public.ask_usage (
  user_id             uuid not null references auth.users (id) on delete cascade,
  day                 date not null,
  requests            integer not null default 0,
  prompt_tokens       bigint not null default 0,
  completion_tokens   bigint not null default 0,
  updated_at          timestamptz not null default now(),
  primary key (user_id, day)
);

-- ---------------------------------------------------------------------
-- is_enrolled(): the single predicate every read policy below is built on.
-- security definer + a pinned search_path so it can be called from a policy
-- on `courses`/`course_documents`/`course_profiles` (which the calling role
-- does not otherwise have direct SELECT rights on rows of, until the
-- predicate says yes) while still only ever consulting the caller's own
-- enrollment rows -- auth.uid() is the caller, not a parameter, so there is
-- no way to pass someone else's identity through it.
-- ---------------------------------------------------------------------
create function public.is_enrolled(p_course_id text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.enrollments e
    where e.course_id = p_course_id
      and e.user_id = auth.uid()
  );
$$;

grant execute on function public.is_enrolled(text) to authenticated;

-- ---------------------------------------------------------------------
-- record_ask_usage(): the only way ask_usage rows are written. Restricted
-- to service_role (see grants below) because it takes p_user_id as a
-- parameter rather than reading auth.uid() itself -- the ask edge function
-- runs with the service key and already knows which user it just answered
-- for, and letting an ordinary authenticated caller invoke this directly
-- would let them inflate or (if they discovered another user's id) forge
-- another student's usage counters.
-- ---------------------------------------------------------------------
create function public.record_ask_usage(
  p_user_id uuid,
  p_prompt_tokens bigint,
  p_completion_tokens bigint
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.ask_usage (user_id, day, requests, prompt_tokens, completion_tokens, updated_at)
  values (p_user_id, (now() at time zone 'utc')::date, 1, coalesce(p_prompt_tokens, 0), coalesce(p_completion_tokens, 0), now())
  on conflict (user_id, day) do update
    set requests          = public.ask_usage.requests + 1,
        prompt_tokens     = public.ask_usage.prompt_tokens + excluded.prompt_tokens,
        completion_tokens = public.ask_usage.completion_tokens + excluded.completion_tokens,
        updated_at        = now();
$$;

revoke execute on function public.record_ask_usage(uuid, bigint, bigint) from public;
grant execute on function public.record_ask_usage(uuid, bigint, bigint) to service_role;

-- ---------------------------------------------------------------------
-- ask_usage_counts(): backs both quota checks the protocol describes --
-- ASK_DAILY_LIMIT is per user per UTC day (today_requests, scoped to
-- p_user_id), ASK_MONTHLY_GLOBAL_LIMIT is across all users for the current
-- calendar month (month_requests, deliberately *not* scoped to p_user_id).
-- Also service_role-only: exposing "how many requests has every user made
-- this month" to ordinary callers is a usage-pattern leak with no upside.
-- ---------------------------------------------------------------------
create function public.ask_usage_counts(p_user_id uuid)
returns table (today_requests integer, month_requests bigint)
language sql
security definer
set search_path = public
stable
as $$
  select
    coalesce((
      select au.requests
      from public.ask_usage au
      where au.user_id = p_user_id
        and au.day = (now() at time zone 'utc')::date
    ), 0) as today_requests,
    coalesce((
      select sum(au.requests)
      from public.ask_usage au
      where date_trunc('month', au.day) = date_trunc('month', (now() at time zone 'utc')::date)
    ), 0) as month_requests;
$$;

revoke execute on function public.ask_usage_counts(uuid) from public;
grant execute on function public.ask_usage_counts(uuid) to service_role;

-- ---------------------------------------------------------------------
-- Row Level Security. The blanket rule for this schema: every write goes
-- through a function running as service_role (which bypasses RLS
-- entirely), so there are deliberately zero INSERT/UPDATE/DELETE policies
-- for anon or authenticated anywhere below -- not "policies that are hard
-- to satisfy", an actual absence, so a bug in a policy expression can
-- never accidentally open a write path. Reads are the only thing
-- authenticated users are ever allowed to do directly against these
-- tables, and only to material they are enrolled in (or their own private
-- rows for enrollments/ask_usage).
-- ---------------------------------------------------------------------
alter table public.courses enable row level security;
alter table public.course_documents enable row level security;
alter table public.course_profiles enable row level security;
alter table public.enrollments enable row level security;
alter table public.ask_usage enable row level security;

-- Schema-level and table-level SELECT grants. Per Supabase convention these
-- are intentionally broad (the API roles can "see" the tables); RLS above
-- is what actually decides which rows come back, and for `anon` no policy
-- below ever names that role, so every one of these SELECTs returns zero
-- rows for an anonymous, unauthenticated caller -- there is no separate
-- "anon has no grants at all" special case to keep in sync.
grant usage on schema public to anon, authenticated, service_role;
grant select on public.courses, public.course_documents, public.course_profiles, public.enrollments, public.ask_usage
  to anon, authenticated;

-- service_role is the only writer (sync, delete-account and extract-profile
-- all run as the service role) and it bypasses RLS entirely on a real
-- Supabase project, so it needs the ordinary table privileges RLS would
-- otherwise gate -- there is no policy to write for it, only a grant.
grant all on public.courses, public.course_documents, public.course_profiles, public.enrollments, public.ask_usage
  to service_role;

create policy courses_select_enrolled
  on public.courses
  for select
  to authenticated
  using (public.is_enrolled(course_id));

create policy course_documents_select_enrolled_live
  on public.course_documents
  for select
  to authenticated
  -- "live" is part of the read policy, not just an application-level
  -- filter: a gone document is shared material the client should treat as
  -- withdrawn, and there is no legitimate reason for any student's client
  -- to ever download it again.
  using (gone_at is null and public.is_enrolled(course_id));

create policy course_profiles_select_enrolled
  on public.course_profiles
  for select
  to authenticated
  using (public.is_enrolled(course_id));

create policy enrollments_select_own
  on public.enrollments
  for select
  to authenticated
  using (user_id = auth.uid());

create policy ask_usage_select_own
  on public.ask_usage
  for select
  to authenticated
  using (user_id = auth.uid());
