-- Adds a course-catalog layer on top of the Canvas-derived `courses` table:
-- registrar facts (description, credits, prerequisites, crosslistings,
-- grade modes, and -- the whole point -- the *components* a Canvas course
-- site can bundle, such as PHYS 0151's 1.0 CU lecture plus its 0.5 CU lab)
-- fetched from Penn Labs' public Penn Courses API. See _shared/catalog.ts
-- for the fetch/parse logic and PROTOCOL.md's "Catalog" section for the
-- full story of why this exists: a Canvas course site is one thing, a
-- registrar course can be several, and nothing before this told `ask` that.
--
-- Deliberately *not* keyed by Canvas course id, unlike every other table in
-- this schema. A registrar course (`PHYS-0151`) exists independent of any
-- Canvas site and is shared across every semester's offering identically --
-- there is exactly one row per catalog course, not one per enrolled
-- student's Canvas course id, and it is genuinely public data (Penn Labs
-- serves it with no auth at all) rather than pooled-because-many-students-
-- happen-to-share-a-Canvas-site the way `course_documents` is.

-- ---------------------------------------------------------------------
-- catalog_courses: one row per registrar course code, refreshed from Penn
-- Labs. `components` is the reason this table exists at all -- see
-- _shared/catalog.ts's `parsePennLabsCourse` for how it's derived from Penn
-- Labs' section list. Its shape is
--   [{ activity, label, sectionCount, credits, sectionIDs }]
-- where `activity` is Penn Labs' short code ("LEC", "LAB", "REC", ...),
-- `label` is the human word ("Lecture", "Lab", "Recitation", ...), and
-- `credits` is the *component's* credit units (the max across its
-- sections, since Penn Labs states credits per section, not per
-- component-as-a-whole) or null when no section in the group states one.
--
-- Review scores (course_quality, instructor_quality, difficulty,
-- work_required, and their section-level equivalents) are Penn Labs' own
-- aggregated Penn Course Review data, not the registrar's, and are
-- deliberately never stored here -- there is no column for them, the same
-- "make it impossible to accidentally persist" discipline the init
-- migration's comment applies to `course_documents.submitted`.
-- ---------------------------------------------------------------------
create table public.catalog_courses (
  catalog_code    text primary key,
  semester        text not null,
  title           text not null,
  description     text not null default '',
  credits         numeric(4,2),
  prerequisites   text not null default '',
  crosslistings   text[] not null default '{}',
  grade_modes     text[] not null default '{}',
  attributes      jsonb not null default '[]',
  components      jsonb not null default '[]',
  source          text not null default 'penn-labs',
  fetched_at      timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- courses.catalog_code: the join from a Canvas course site to the
-- registrar's course, derived from `catalogCode(courses.code)` in
-- _shared/catalog.ts (e.g. "PHYS 0151" -> "PHYS-0151"). Nullable on
-- purpose -- a course code CourseCode.parse (the iOS-side equivalent) or
-- this backend's own `catalogCode` couldn't confidently derive a registrar
-- code from is left unlinked rather than guessed at, exactly as a failed
-- `CourseCode.parse` on the client falls back to the raw descriptor rather
-- than inventing a code nothing else agrees with.
-- ---------------------------------------------------------------------
alter table public.courses add column catalog_code text;

create index courses_catalog_code_idx on public.courses (catalog_code) where catalog_code is not null;

-- ---------------------------------------------------------------------
-- Row Level Security. Unlike every other table in this schema,
-- `catalog_courses` needs no enrollment gate: it is public registrar data
-- (Penn Labs serves it to anyone, no auth, no key) rather than material
-- scoped to who happens to be enrolled in a given Canvas site, so every
-- authenticated caller may read every row. There are still zero write
-- policies -- the only writer is the `sync` function's service-role client,
-- matching the "every write goes through service_role" rule the init
-- migration's RLS comment establishes for the rest of this schema.
-- ---------------------------------------------------------------------
alter table public.catalog_courses enable row level security;

grant select on public.catalog_courses to anon, authenticated;
grant all on public.catalog_courses to service_role;

create policy catalog_courses_select_all
  on public.catalog_courses
  for select
  to authenticated
  using (true);
