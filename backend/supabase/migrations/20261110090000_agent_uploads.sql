-- ---------------------------------------------------------------------
-- Chunked, checksummed file uploads for the agent connection. A model cannot
-- emit one 144,000-character base64 argument, so `begin_file_upload`,
-- `append_file_chunk` and `finish_file_upload` stage a file here in 16 KB
-- pieces and `finish` assembles it into an ordinary draft. State is durable
-- because the edge function runs in many stateless isolates.
--
-- An upload not finished within 30 minutes (`expires_at`) is garbage and
-- `agent_sweep_expired` deletes it; chunks cascade. Staged Storage objects
-- (the direct signed-URL path) live in the private `agent-drafts` bucket
-- under `<user id>/uploads/<upload id>/` and are removed by the function.
-- Service role only, like every agent table. Additive and re-runnable.
-- ---------------------------------------------------------------------

create table if not exists public.agent_uploads (
  id             text primary key,
  user_id        uuid not null references auth.users (id) on delete cascade,
  connection_id  text not null,
  assignment_id  text not null,
  file_name      text not null,
  mime_type      text not null,
  total_bytes    integer not null check (total_bytes > 0),
  sha256         text not null,
  chunk_bytes    integer not null,
  chunks         integer not null check (chunks > 0),
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null
);
create index if not exists agent_uploads_user_id_idx on public.agent_uploads (user_id);
create index if not exists agent_uploads_connection_id_idx on public.agent_uploads (connection_id);
create index if not exists agent_uploads_expires_at_idx on public.agent_uploads (expires_at);

create table if not exists public.agent_upload_chunks (
  upload_id  text not null references public.agent_uploads (id) on delete cascade,
  index      integer not null check (index >= 0),
  data       bytea not null,
  sha256     text not null,
  primary key (upload_id, index)
);

alter table public.agent_uploads enable row level security;
alter table public.agent_upload_chunks enable row level security;
revoke all on public.agent_uploads, public.agent_upload_chunks from anon, authenticated;
grant all on public.agent_uploads, public.agent_upload_chunks to service_role;

-- 20261109090000_agent_hardening.sql plus one line: expired uploads (their
-- chunks cascade).
create or replace function public.agent_sweep_expired()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total integer := 0;
  v_n integer;
begin
  -- Not at `expires_at` itself: `status?go=1` on a row seen just before expiry
  -- mints an authorization code valid for AUTH_CODE_TTL_MS (60 s,
  -- _shared/agentTokens.ts) more, and deleting the row would kill it. The
  -- two minute margin is twice that TTL; change both together.
  delete from public.agent_pending_auth where expires_at <= now() - interval '2 minutes';
  get diagnostics v_n = row_count;
  v_total := v_total + v_n;

  delete from public.agent_tokens where expires_at <= now() - interval '1 day';
  get diagnostics v_n = row_count;
  v_total := v_total + v_n;

  delete from public.agent_rate_limits where window_start <= now() - interval '1 day';
  get diagnostics v_n = row_count;
  v_total := v_total + v_n;

  -- Dynamically registered clients (RFC 7591) nothing has used for 30
  -- days: no connection of any state (a revoked one still names its client)
  -- and no pending authorization (whose params carry the id as clientId).
  delete from public.agent_clients c
  where c.created_at <= now() - interval '30 days'
    and not exists (select 1 from public.agent_connections k where k.client_id = c.client_id)
    and not exists (select 1 from public.agent_pending_auth p where p.params ->> 'clientId' = c.client_id);
  get diagnostics v_n = row_count;
  v_total := v_total + v_n;

  delete from public.agent_uploads where expires_at <= now();
  get diagnostics v_n = row_count;
  v_total := v_total + v_n;

  return v_total;
end;
$$;

revoke execute on function public.agent_sweep_expired() from public, anon, authenticated;
grant execute on function public.agent_sweep_expired() to service_role;
