-- ---------------------------------------------------------------------
-- Phase 3 of the agent connection: drafts. A draft is a submission an agent
-- proposed (text, a link, or a file) for the student to review in Smooth and
-- submit from the app; the agent never submits. The table was created in
-- 20261108090000_agent_connection.sql; this adds what the flow needs and the
-- private bucket that holds the files.
--
-- Files live in the private Storage bucket `agent-drafts`, at
-- `<user id>/<draft id>/<file name>`. There is deliberately NO policy on
-- storage.objects for anon or authenticated: with RLS on and no policy they
-- can read and write nothing, and the service role (the edge functions)
-- bypasses RLS. The phone never reads the bucket directly; `agent-snapshot`
-- hands it a signed URL good for two minutes. The wrong fix would be a
-- "users read their own folder" policy: it would put a second, unaudited
-- door on the student's own writing.
--
-- 1572864 bytes = the 1.5 MB decoded cap `propose_submission` already
-- enforces; the bucket limit is the backstop if that check is ever bypassed.
-- Additive and re-runnable.
-- ---------------------------------------------------------------------

alter table public.agent_drafts add column if not exists client_name text null;
alter table public.agent_drafts add column if not exists seen_at timestamptz null;
alter table public.agent_drafts add column if not exists decided_at timestamptz null;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('agent-drafts', 'agent-drafts', false, 1572864, null)
on conflict (id) do nothing;
