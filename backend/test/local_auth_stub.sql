-- Stand-in for the parts of Supabase's managed `auth` schema and API roles
-- that the migration and RLS policies depend on, so the schema can be
-- exercised against a bare local Postgres instance instead of a full
-- Supabase stack (which needs Docker, unavailable in this container).
--
-- This is deliberately the *minimum* slice of Supabase's real auth schema:
-- a `users` table with just the primary key our foreign keys reference, and
-- an `auth.uid()` that reads the same `request.jwt.claims` GUC PostgREST
-- sets on every request in the real product. Tests below set that GUC with
-- `set_config` to impersonate a given user for the duration of a
-- transaction, the same way PostgREST would per-request.
--
-- Run this once against a scratch database, before applying the real
-- migration, never against anything that might be a real project database.

create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key
);

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select (nullif(current_setting('request.jwt.claims', true), '')::json ->> 'sub')::uuid;
$$;

-- The three Data API roles Supabase provisions on every project. `anon` and
-- `authenticated` are the roles PostgREST assumes for unauthenticated and
-- authenticated requests respectively; `service_role` is what the Edge
-- Functions runtime uses when a function is built with the service key, and
-- on a real Supabase project it bypasses RLS entirely -- BYPASSRLS below
-- reproduces that so the service-role write paths in db.ts don't need their
-- own policies.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  else
    alter role service_role bypassrls;
  end if;
end
$$;

-- On a real Supabase project `service_role` can read and write auth.users
-- (it is how `serviceClient.auth.admin.deleteUser` and friends work under
-- the hood); grant the same here so delete-account's admin call and this
-- test file's own fixture setup (which impersonates service_role rather
-- than the local superuser, to match how the edge functions actually
-- write) both work against the stub. Must come after the role exists.
grant usage on schema auth to service_role;
grant select, insert, update, delete on auth.users to service_role;
