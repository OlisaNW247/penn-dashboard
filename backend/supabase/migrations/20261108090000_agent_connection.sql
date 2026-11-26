-- ---------------------------------------------------------------------
-- The v11 agent connection (docs/AGENT_CONNECTION_PLAN_V11_2026-11-07.md):
-- a student connects Claude to Smooth as a remote MCP connector. This adds
-- the five tables behind the OAuth flow, the connector's tokens, the
-- snapshot the MCP server reads, and the drafts an agent proposes.
--
-- Additive and re-runnable: only `create table if not exists` and
-- `create ... index if not exists`. Nothing existing is touched.
--
-- Every table here is read and written only by the service role, and only
-- through the `agent-auth`, `mcp` and `agent-snapshot` Edge Functions
-- (`_shared/agentStorePostgrest.ts`). No client (the phone, the extension,
-- the agent) ever queries them directly, so there is no legitimate
-- anon or authenticated reader to write a policy for.
--
-- docs/PRIVACY.md and backend/PROTOCOL.md describe `agent_snapshots`, the
-- one table that holds a student's own work list. It is deleted on opt-out,
-- on Canvas disconnect and on account deletion (`deleteUserData`).
-- ---------------------------------------------------------------------

-- agent_pending_auth: one row per authorization a browser has started and a
-- phone has not yet finished. `id` is 128 random bits (base64url, 22
-- chars), the secret in the QR / `smooth://link` and the poll key; it is
-- never typed. `user_code` is the 8-character code a student can type when
-- the phone cannot scan, so two live pending rows must never share one
-- (partial unique index). `match_number` / `match_choices` are the
-- two-digit number the page shows and the phone asks the student to pick
-- (QRLJacking defence). `nonce_hash` ties status polling to the browser that
-- started the flow. The one-time authorization code is stored only as a
-- hash. Service role only: it holds live codes and the nonce hash, which
-- would let a client approve or steal someone's authorization.
create table if not exists public.agent_pending_auth (
  id                    text primary key,
  user_code             text not null,
  match_number          integer not null,
  match_choices         integer[] not null,
  nonce_hash            text not null,
  params                jsonb not null,
  user_id               uuid null references auth.users (id) on delete cascade,
  auth_code_hash        text null,
  auth_code_expires_at  timestamptz null,
  client_name           text not null,
  status                text not null check (status in ('pending', 'approved', 'denied', 'consumed')),
  created_at            timestamptz not null default now(),
  expires_at            timestamptz not null
);
create unique index if not exists agent_pending_auth_user_code_pending_idx
  on public.agent_pending_auth (user_code) where status = 'pending';
create unique index if not exists agent_pending_auth_auth_code_hash_idx
  on public.agent_pending_auth (auth_code_hash) where auth_code_hash is not null;
create index if not exists agent_pending_auth_expires_at_idx on public.agent_pending_auth (expires_at);

-- agent_clients: clients registered through RFC 7591 dynamic client
-- registration, for SDK-based MCP clients that cannot use a client metadata
-- document. Public clients only (no secret); the id is `smc_` + 128 random
-- bits. Service role only, like the rest.
create table if not exists public.agent_clients (
  client_id      text primary key,
  client_name    text not null,
  redirect_uris  text[] not null,
  created_at     timestamptz not null default now()
);

-- agent_connections: one row per agent a student has connected (Claude on
-- one account, say). Revoking sets `revoked_at` and deletes the tokens; the
-- row stays so the student's list can show what was connected and when.
-- Service role only: the student sees and revokes their own connections
-- through the phone, via an Edge Function that checks who they are.
create table if not exists public.agent_connections (
  id            text primary key,
  user_id       uuid not null references auth.users (id) on delete cascade,
  client_id     text not null,
  client_name   text not null,
  scopes        text[] not null,
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz null,
  revoked_at    timestamptz null
);
create index if not exists agent_connections_user_id_idx on public.agent_connections (user_id);

-- agent_tokens: the access and refresh tokens of a connection, stored only
-- as sha256 hashes (`hash` is the key), so a database read cannot be turned
-- into a working token. `rotated_from` / `used_at` implement refresh-token
-- rotation: presenting a redeemed refresh token again is reuse and revokes
-- the connection. They die with their connection. Service role only: a
-- reader of this table must not be able to enumerate or delete tokens.
create table if not exists public.agent_tokens (
  hash           text primary key,
  kind           text not null check (kind in ('access', 'refresh')),
  connection_id  text not null references public.agent_connections (id) on delete cascade,
  resource       text not null,
  scopes         text[] not null,
  expires_at     timestamptz not null,
  rotated_from   text null,
  used_at        timestamptz null,
  created_at     timestamptz not null default now()
);
create index if not exists agent_tokens_connection_id_idx on public.agent_tokens (connection_id);
create index if not exists agent_tokens_expires_at_idx on public.agent_tokens (expires_at);

-- agent_snapshots: the one table that holds a student's own work. One row
-- per opted-in student: the phone uploads their courses, work list and
-- manual tasks, and the MCP server reads it for the agent. It is the only
-- thing the agent sees of the student's schedule, so it is deleted on
-- opt-out, Canvas disconnect and account deletion. Service role only,
-- because a direct reader would see a student's assignments.
create table if not exists public.agent_snapshots (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  courses     jsonb not null,
  work_list   jsonb not null,
  manual      jsonb not null,
  written_at  timestamptz not null
);

-- agent_drafts (designed now, used from Phase 3): a submission an agent has
-- proposed for an assignment (text, a link, or a file in storage). The
-- student reviews it on the phone and submits it from the app; the agent
-- never submits. If the connection is revoked the draft stays (the student
-- may still want it), so `connection_id` is set null rather than cascaded.
-- Service role only: drafts are the student's own writing.
create table if not exists public.agent_drafts (
  id                    text primary key,
  user_id               uuid not null references auth.users (id) on delete cascade,
  connection_id         text null references public.agent_connections (id) on delete set null,
  assignment_id         text not null,
  kind                  text not null check (kind in ('text', 'url', 'file')),
  body                  text null,
  url                   text null,
  file_path             text null,
  file_name             text null,
  mime_type             text null,
  file_bytes            integer null,
  note                  text null,
  status                text not null check (status in ('proposed', 'seen', 'submitted', 'declined', 'failed')),
  canvas_submission_id  text null,
  attempt               integer null,
  error_class           text null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create index if not exists agent_drafts_user_id_status_idx on public.agent_drafts (user_id, status);

-- Service role only. RLS is on with no policy for anon or authenticated, so
-- even a stray grant would return zero rows; the explicit revoke is there
-- because Supabase's default privileges hand anon/authenticated grants on
-- every new public table (same reasoning as 20261022090000_chrome_extension.sql).
alter table public.agent_pending_auth enable row level security;
alter table public.agent_clients enable row level security;
alter table public.agent_connections enable row level security;
alter table public.agent_tokens enable row level security;
alter table public.agent_snapshots enable row level security;
alter table public.agent_drafts enable row level security;

revoke all on public.agent_pending_auth, public.agent_clients, public.agent_connections, public.agent_tokens,
  public.agent_snapshots, public.agent_drafts from anon, authenticated;
grant all on public.agent_pending_auth, public.agent_clients, public.agent_connections, public.agent_tokens,
  public.agent_snapshots, public.agent_drafts to service_role;
