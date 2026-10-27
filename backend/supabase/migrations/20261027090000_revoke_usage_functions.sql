-- Hardening BE-B (docs/HARDENING_PLAN_2026-10-25.md, finding #14): the
-- usage and quota functions were revoked from PUBLIC only, which on a
-- Supabase project with its standard defaults leaves them callable by
-- anyone. (Not yet confirmed against the live project: the plan's read-only
-- check, `select proname, proacl from pg_proc where pronamespace =
-- 'public'::regnamespace`, settles it. This migration is safe either way.)
--
-- Why `revoke ... from public` was not enough. On a Supabase project,
-- everything the migration role (`postgres`) creates in `public` is granted
-- to `anon`, `authenticated` and `service_role` by default privileges that
-- Supabase sets up when it provisions the project (`alter default
-- privileges in schema public grant all on functions to ...`). Those are
-- explicit per-role grants. `revoke execute on function f from public`
-- removes the grant to the PUBLIC pseudo-role and nothing else, so after
-- 20260907000000_init.sql and both `ask_outcomes` migrations, the three
-- functions below would still be executable through `/rest/v1/rpc/<name>`
-- by any anonymous JWT, and anyone can mint one. All three are SECURITY
-- DEFINER and take the user id as a parameter, so a caller could:
--   - call `record_ask_usage` in a loop to inflate the GLOBAL monthly
--     counter that `ASK_MONTHLY_GLOBAL_LIMIT` is checked against, which
--     switches `ask` off for every student until the 1st;
--   - call `record_ask_usage` with another student's id to burn their daily
--     allowance;
--   - call `ask_usage_counts` to read how many requests every user made
--     this month;
--   - call `record_ask_outcome` to write rows into `ask_outcomes`, the
--     table the empty-answer alarm is read from.
-- The suite did not catch it because `test/local_auth_stub.sql` ran on bare
-- Postgres, which has no such default privileges; it now declares them, and
-- `test/rls.test.sql` fails against the earlier migrations alone.
--
-- Only the Edge Functions call these, always as `service_role`, so that is
-- the one role granted back. The wrong fix would have been `revoke ... from
-- anon` alone, which looks right and leaves `authenticated` (every signed-in
-- anonymous account) able to call them.

revoke execute on function public.record_ask_usage(uuid, bigint, bigint)
  from public, anon, authenticated;
grant execute on function public.record_ask_usage(uuid, bigint, bigint)
  to service_role;

revoke execute on function public.ask_usage_counts(uuid)
  from public, anon, authenticated;
grant execute on function public.ask_usage_counts(uuid)
  to service_role;

revoke execute on function public.record_ask_outcome(
  uuid, text, text, integer, integer, integer, integer, integer, integer, integer, integer, integer, text, text, integer, integer
) from public, anon, authenticated;
grant execute on function public.record_ask_outcome(
  uuid, text, text, integer, integer, integer, integer, integer, integer, integer, integer, integer, text, text, integer, integer
) to service_role;

-- Matching default privileges, so the next function this migration role
-- creates in `public` is not handed to the API roles automatically. This
-- removes the schema-level entries Supabase installed for `anon` and
-- `authenticated` (it applies to the role running this migration, which is
-- `postgres` on a real project; Supabase's own `supabase_admin` entries are
-- untouched). `service_role` keeps its default grant. Two limits worth
-- knowing: the built-in PostgreSQL default that lets PUBLIC execute every
-- new function is global, not per-schema, and a per-schema `revoke` cannot
-- remove it, so a new function still needs its own `revoke ... from public`
-- (the check at the end of `rls.test.sql` fails the suite if one forgets);
-- and a global `alter default privileges ... revoke execute ... from
-- public` was rejected, because it would also strip PUBLIC's access to
-- functions this role creates in other schemas, such as an extension
-- installed later. `is_enrolled` is deliberately left alone: RLS policies
-- call it as `authenticated`, and it reads `auth.uid()` rather than taking
-- a user id.
alter default privileges in schema public
  revoke execute on functions from public, anon, authenticated;

-- `directory_cache` is service-role only, and its migration says "no grant
-- to anon/authenticated at all", but on a Supabase project the default
-- privileges above give every new table full privileges for both roles, so
-- RLS with no policy was the only thing keeping it closed. Found when the
-- stub started reproducing those defaults. It matters little (no policy
-- means zero rows), but the belt-and-braces the comment promised was never
-- there. `20261022090000_chrome_extension.sql` does the same explicit
-- revoke for its three tables, for the same reason.
revoke all on public.directory_cache from anon, authenticated;

-- Fail the migration (it runs in a transaction, so it rolls back) rather
-- than leave a hole if any overload of these functions was missed, for
-- example a signature this file did not list.
do $$
declare
  fn record;
begin
  for fn in
    select p.oid, p.oid::regprocedure as signature
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('record_ask_usage', 'ask_usage_counts', 'record_ask_outcome')
  loop
    if has_function_privilege('anon', fn.oid, 'execute')
       or has_function_privilege('authenticated', fn.oid, 'execute') then
      raise exception '% is still executable by anon or authenticated', fn.signature;
    end if;
    if not has_function_privilege('service_role', fn.oid, 'execute') then
      raise exception '% is not executable by service_role', fn.signature;
    end if;
  end loop;
end $$;
