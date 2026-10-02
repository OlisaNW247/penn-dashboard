-- ---------------------------------------------------------------------
-- course_documents.kind gains 'ed': Ed Discussion ingestion
-- (docs/ED_DISCUSSION.md). A course's Ed announcements, pinned threads
-- and staff posts are shared material exactly like a Canvas announcement,
-- sourced from a different site, so they ride the same table and the same
-- pipeline (manifest diffing, `ask` retrieval) with one more allowed
-- value, as 'website' did in 20260907180000_websites.sql. Student posts
-- are never uploaded, and 'ed' is never profile or syllabus input (see
-- `_shared/profile.ts`).
--
-- Additive, and safe to apply before any client sends 'ed': it only widens
-- the set of accepted values, no existing row can violate it, and a client
-- that never sends 'ed' never notices. Same drop-and-re-add pattern as the
-- 'website' migration (Postgres has no ALTER CHECK); `if exists` so a
-- re-run is harmless.
-- ---------------------------------------------------------------------
alter table public.course_documents drop constraint if exists course_documents_kind_check;
alter table public.course_documents add constraint course_documents_kind_check
  check (kind in ('home', 'syllabus', 'assignment', 'announcement', 'module', 'page', 'website', 'ed'));
