-- Adds course-website discovery and crawling on top of the schema in
-- 20260907000000_init.sql and 20260907120000_catalog.sql. The problem this
-- solves: a lot of Penn courses (all of CIS, for one) keep their real
-- material on an external course website rather than Canvas -- syllabus,
-- schedule, project specs, staff list -- and until now nothing in this
-- backend, and therefore nothing `ask` could see, knew those pages
-- existed. See PROTOCOL.md's course-website section and
-- `_shared/websites.ts`/`_shared/crawl.ts` for the discovery and crawl
-- logic this table and its sibling back.

-- ---------------------------------------------------------------------
-- course_websites: candidate and verified external course website URLs
-- for a Canvas course. A course can accumulate several rows -- a link
-- found on Canvas, an entry from the CIS Advising Handbook directory, a
-- guessed `~cisNNNN/current/` convention URL -- and `discover-websites`
-- verifies each independently rather than keeping only "the" website,
-- because more than one can turn out to actually resolve (a stale
-- `~bhusnur4/cis105/16fa/` link and a fresh `~cis1210/current/` one can
-- both be present as candidates; only the one that actually verifies for
-- the *current* semester becomes the crawl target).
--
-- `unique (course_id, url)` is the upsert key both the sync-time candidate
-- insert (from client-reported links) and discover-websites' own directory/
-- convention candidates go through -- the same URL discovered twice for
-- the same course (a student's Canvas page links it, and the CIS directory
-- also lists it) is one row, not two, with `confidence` taking the greater
-- of the two signals' worth (see `_shared/websites.ts`'s scoring and the
-- `ON CONFLICT ... DO UPDATE confidence = greatest` in sync's link
-- handling).
-- ---------------------------------------------------------------------
create table public.course_websites (
  id                   bigserial primary key,
  course_id            text not null references public.courses (course_id) on delete cascade,
  url                  text not null,
  -- Where this candidate came from, for debugging and for `ask`/dashboards
  -- that might one day want to explain why a site is trusted:
  --   canvas-link          -- found in a link the client reported from a
  --                            Canvas page/assignment/module/syllabus
  --   cis-directory        -- the CIS Advising Handbook's course directory
  --   convention           -- guessed `~cisNNNN/current/` pattern
  --   penn-labs-syllabus   -- `catalog_courses.syllabus_url` from Penn Labs
  source               text not null check (source in ('canvas-link', 'cis-directory', 'convention', 'penn-labs-syllabus')),
  confidence           integer not null default 0,
  -- candidate: not yet verified, or verification hasn't matched this term.
  -- verified: `verifyPage` matched both the course code and the current
  --   term within the last 7 days (`_shared/websites.ts`'s `verifyPage`,
  --   `discover-websites`'s 7-day recheck window).
  -- rejected: fetched successfully but did not match -- kept, rather than
  --   deleted, so discover-websites doesn't re-fetch a URL it already
  --   knows is wrong every single call; a rejected row can still become
  --   verified later (a stale URL a professor eventually points at the
  --   new semester after all).
  status               text not null default 'candidate' check (status in ('candidate', 'verified', 'rejected')),
  anchor_text          text,
  verified_term        text,
  verified_at          timestamptz,
  last_crawled_at      timestamptz,
  page_count           integer not null default 0,
  gradescope_course_id text,
  ed_course_id         text,
  created_at           timestamptz not null default now(),
  unique (course_id, url)
);

-- discover-websites' every query is "candidates/verified rows for this
-- course_id" or "the verified row(s) for this course_id ready to crawl" --
-- both filter on (course_id, status), so that's the index shape, mirroring
-- `course_documents_live_by_course_idx`'s reasoning in the init migration.
create index course_websites_course_status_idx
  on public.course_websites (course_id, status);

-- ---------------------------------------------------------------------
-- directory_cache: a tiny key/value cache so `discover-websites` fetches
-- the CIS Advising Handbook's course directory page at most once per 24h
-- total (across every student's discovery call, not once per student) --
-- see PROTOCOL.md and `discover-websites/index.ts`. Service-role only:
-- this is server bookkeeping about a public, non-course-specific web page,
-- not shared course material and not a student's data, so unlike every
-- other table in this schema there is no read policy for `authenticated`
-- at all -- an ordinary caller has no legitimate reason to read it, and
-- there is deliberately nothing here scoped to who's asking.
-- ---------------------------------------------------------------------
create table public.directory_cache (
  key         text primary key,
  body        text not null,
  fetched_at  timestamptz not null default now()
);

alter table public.course_websites enable row level security;
alter table public.directory_cache enable row level security;

grant select on public.course_websites to anon, authenticated;
grant all on public.course_websites to service_role;
-- `id bigserial` backs itself with a sequence that is a distinct grantable
-- object from the table -- `grant all on ... table` above does not imply
-- sequence privileges the way owning the table would, so service_role
-- (which writes this table but is not its owner) needs USAGE on the
-- sequence explicitly or every INSERT relying on the default `id` fails
-- with "permission denied for sequence" despite the table grant looking
-- complete.
grant usage, select on sequence public.course_websites_id_seq to service_role;
-- No grant to anon/authenticated at all for directory_cache -- there is no
-- row any caller other than service_role should ever see, and omitting
-- the grant (rather than granting it and relying solely on the RLS
-- policy-absence below) means even a future policy-writing bug can't leak
-- a row past a role that never had table-level SELECT to begin with.
grant all on public.directory_cache to service_role;

create policy course_websites_select_enrolled
  on public.course_websites
  for select
  to authenticated
  using (public.is_enrolled(course_id));

-- Deliberately no policy at all for directory_cache -- see the table
-- comment above. Note this table behaves differently from every other
-- RLS-protected table in this schema as a result: `course_websites` (and
-- `courses`, `catalog_courses`, ...) grant SELECT to `authenticated` and
-- then use a policy to filter which rows come back, so an unauthorized
-- query there simply returns zero rows; `directory_cache` was never
-- granted table-level SELECT for `authenticated` or `anon` at all (see the
-- grants above), so a query against it as either role is refused outright
-- with a permission error rather than silently returning empty -- proven
-- by `test/rls.test.sql`, which expects that error, not an empty result.

-- ---------------------------------------------------------------------
-- course_documents.kind gains 'website': a crawled course-website page is
-- shared material exactly like a Canvas page, just sourced differently,
-- and the protocol's document pipeline (manifest diffing, profile
-- staleness, `ask` retrieval) already generalizes over `kind` without
-- caring where a document came from -- so the same table, the same
-- pipeline, one more allowed value, rather than a parallel table
-- `discover-websites` and `ask` would both have to know about specially.
-- Postgres has no `ALTER CHECK`; a same-named constraint is dropped and
-- re-added rather than left to accumulate a second, redundant one.
-- ---------------------------------------------------------------------
alter table public.course_documents drop constraint course_documents_kind_check;
alter table public.course_documents add constraint course_documents_kind_check
  check (kind in ('home', 'syllabus', 'assignment', 'announcement', 'module', 'page', 'website'));

-- ---------------------------------------------------------------------
-- catalog_courses.syllabus_url: Penn Labs' own `syllabus_url` field
-- (often null), populated by `parsePennLabsCourse` in `_shared/catalog.ts`.
-- When present it's one more, often high-quality, website candidate for
-- `discover-websites` to verify -- see the `penn-labs-syllabus` source
-- value above.
-- ---------------------------------------------------------------------
alter table public.catalog_courses add column syllabus_url text;
