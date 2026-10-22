-- ---------------------------------------------------------------------
-- The Smooth Chrome extension (docs/CHROME_EXTENSION.md, build step 4):
-- who collected a document, the 'file' document kind, laptop-to-phone
-- pairing, and the end-to-end encrypted sync blobs.
--
-- Additive and re-runnable: every statement is `if not exists` or a
-- drop-and-re-add of a check (Postgres has no ALTER CHECK, same pattern as
-- 20261002090000_ed_kind.sql), and the new column has a default, so every
-- existing row and every shipped client keeps working untouched.
-- ---------------------------------------------------------------------

-- course_documents.collector: which client uploaded the row. 'phone' is the
-- default and is what every row written before this migration, and every
-- shipped build that sends no `client`, means. The complete-set rule in
-- `sync` (a fully-synced course's live documents absent from the client's
-- id list are marked gone) only retires 'phone' rows when the phone is the
-- one reporting, because the phone cannot see announcements, pages past
-- its 40-body cap or files and would otherwise erase everything the
-- extension pooled on its next hourly sync. The wrong fix would have been
-- to exempt kinds, as `ed` is exempted: the phone does upload pages, and
-- an extension copy of page 41 is the same kind.
alter table public.course_documents add column if not exists collector text not null default 'phone';
alter table public.course_documents drop constraint if exists course_documents_collector_check;
alter table public.course_documents add constraint course_documents_collector_check
  check (collector in ('phone', 'extension'));

-- course_documents.kind gains 'file': text extracted in the browser from a
-- Canvas File (PDF, plain text). Phones never receive it unless their
-- manifest request says `acceptsKinds` includes "file" (a strict Codable
-- enum there would fail the whole manifest decode), and it is never
-- profile input (see `_shared/profile.ts`).
alter table public.course_documents drop constraint if exists course_documents_kind_check;
alter table public.course_documents add constraint course_documents_kind_check
  check (kind in ('home', 'syllabus', 'assignment', 'announcement', 'module', 'page', 'website', 'ed', 'file'));

-- pairings: a short-lived, single-use code an extension asks for and a
-- phone claims. `code` is 128 random bits (base64url), the key, so it
-- cannot be guessed within its ten minutes. One row per waiting device
-- user: `start` deletes that caller's old rows first.
create table if not exists public.pairings (
  code           text primary key,
  device_user_id uuid not null references auth.users (id) on delete cascade,
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null
);
create index if not exists pairings_device_user_id_idx on public.pairings (device_user_id);

-- device_links: the extension's own anonymous user -> the phone's user.
-- The device user is the primary key: a device belongs to exactly one
-- owner. Every function resolves a linked device to its owner (see
-- `_shared/auth.ts`), so enrollments and the ask quota stay one student's.
-- Both sides cascade on user deletion: deleting either auth user removes
-- the link, and `delete-account` removes the device users explicitly.
create table if not exists public.device_links (
  device_user_id uuid primary key references auth.users (id) on delete cascade,
  owner_user_id  uuid not null references auth.users (id) on delete cascade,
  created_at     timestamptz not null default now()
);
create index if not exists device_links_owner_user_id_idx on public.device_links (owner_user_id);

-- device_sync_blobs: one encrypted snapshot per device per owner. The
-- server never parses `ciphertext` (base64 of AES-256-GCM output keyed by a
-- key the server never sees); it stores and returns it. `device_id` is a
-- client-chosen label, restricted to a conservative charset and length.
create table if not exists public.device_sync_blobs (
  owner_user_id uuid not null references auth.users (id) on delete cascade,
  device_id     text not null check (device_id ~ '^[A-Za-z0-9_-]{8,64}$'),
  ciphertext    text not null,
  updated_at    timestamptz not null default now(),
  primary key (owner_user_id, device_id)
);

-- Service role only. RLS is on with no policy for anon or authenticated,
-- so even a stray grant would return zero rows; the explicit revoke is
-- there because Supabase's default privileges hand anon/authenticated
-- table grants on every new public table, and "no policy" should not be
-- the only thing standing between a client and ciphertext or live codes.
-- (The init migration grants select on enrollments to those roles and
-- relies on its own-rows policy; these tables have no such legitimate
-- direct reader.)
alter table public.pairings enable row level security;
alter table public.device_links enable row level security;
alter table public.device_sync_blobs enable row level security;

revoke all on public.pairings, public.device_links, public.device_sync_blobs from anon, authenticated;
grant all on public.pairings, public.device_links, public.device_sync_blobs to service_role;
