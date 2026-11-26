-- Proves the v11 agent-connection tables (20261108090000_agent_connection.sql)
-- are service-role only, that two live pending authorizations cannot share a
-- typed code, and that deletes cascade the way the migration says. Run after
-- local_auth_stub.sql and every migration, like rls.test.sql.

\set ON_ERROR_STOP on

set role service_role;

insert into auth.users (id) values
  ('a1111111-1111-1111-1111-111111111111'),
  ('b2222222-2222-2222-2222-222222222222');

insert into public.agent_connections (id, user_id, client_id, client_name, scopes) values
  ('conn-a', 'a1111111-1111-1111-1111-111111111111', 'https://claude.ai/c', 'Claude', '{read}'),
  ('conn-b', 'b2222222-2222-2222-2222-222222222222', 'https://claude.ai/c', 'Claude', '{read}');

insert into public.agent_tokens (hash, kind, connection_id, resource, scopes, expires_at) values
  ('tok-a', 'access', 'conn-a', 'https://mcp.test', '{read}', now() + interval '1 hour'),
  ('tok-b', 'refresh', 'conn-b', 'https://mcp.test', '{read}', now() + interval '1 day');

insert into public.agent_pending_auth
  (id, user_code, match_number, match_choices, nonce_hash, params, user_id, client_name, status, expires_at)
values
  ('pend-a', 'BCDFGHJK', 42, '{42,17,63}', 'nonce', '{}'::jsonb, 'a1111111-1111-1111-1111-111111111111', 'Claude', 'pending', now() + interval '10 minutes');

insert into public.agent_snapshots (user_id, courses, work_list, manual, written_at) values
  ('a1111111-1111-1111-1111-111111111111', '[]', '[]', '[]', now()),
  ('b2222222-2222-2222-2222-222222222222', '[]', '[]', '[]', now());

insert into public.agent_drafts (id, user_id, connection_id, assignment_id, kind, body, status) values
  ('draft-a', 'a1111111-1111-1111-1111-111111111111', 'conn-a', 'asg-1', 'text', 'hello', 'proposed');

reset role;

-- (a) and (b): authenticated and anon see nothing and write nothing.
do $$
declare
  r text;
  t text;
  n int;
  tables text[] := array['agent_pending_auth', 'agent_clients', 'agent_connections', 'agent_tokens', 'agent_snapshots', 'agent_drafts'];
  inserts text[] := array[
    $i$insert into public.agent_pending_auth (id, user_code, match_number, match_choices, nonce_hash, params, client_name, status, expires_at) values ('x', 'ZZZZZZZZ', 1, '{1}', 'n', '{}', 'c', 'pending', now())$i$,
    $i$insert into public.agent_clients (client_id, client_name, redirect_uris) values ('smc_x', 'c', '{https://a.example/cb}')$i$,
    $i$insert into public.agent_connections (id, user_id, client_id, client_name, scopes) values ('x', 'a1111111-1111-1111-1111-111111111111', 'c', 'c', '{}')$i$,
    $i$insert into public.agent_tokens (hash, kind, connection_id, resource, scopes, expires_at) values ('x', 'access', 'conn-a', 'r', '{}', now())$i$,
    $i$insert into public.agent_snapshots (user_id, courses, work_list, manual, written_at) values ('a1111111-1111-1111-1111-111111111111', '[]', '[]', '[]', now())$i$,
    $i$insert into public.agent_drafts (id, user_id, assignment_id, kind, status) values ('x', 'a1111111-1111-1111-1111-111111111111', 'a', 'text', 'proposed')$i$
  ];
  i int;
begin
  foreach r in array array['authenticated', 'anon'] loop
    perform set_config('request.jwt.claims', '{"sub":"a1111111-1111-1111-1111-111111111111"}', true);
    for i in 1 .. array_length(tables, 1) loop
      t := tables[i];
      perform set_config('role', r, true);
      begin
        execute format('select count(*) from public.%I', t) into n;
        perform set_config('role', 'service_role', true);
        if n <> 0 then
          raise exception '% saw % rows in %', r, n, t;
        end if;
      exception when insufficient_privilege then
        perform set_config('role', 'service_role', true); -- permission denied is also a pass
      end;
      perform set_config('role', r, true);
      begin
        execute inserts[i];
        perform set_config('role', 'service_role', true);
        raise exception '% could insert into %', r, t;
      exception when insufficient_privilege then
        perform set_config('role', 'service_role', true);
      end;
    end loop;
  end loop;
  perform set_config('role', 'service_role', true);
end $$;

reset role;
set role service_role;

-- (c) typed codes: unique among pending rows only.
do $$
begin
  begin
    insert into public.agent_pending_auth
      (id, user_code, match_number, match_choices, nonce_hash, params, client_name, status, expires_at)
    values ('pend-dup', 'BCDFGHJK', 1, '{1}', 'n', '{}', 'c', 'pending', now() + interval '10 minutes');
    raise exception 'second pending row with the same user_code was accepted';
  exception when unique_violation then
    null;
  end;
  insert into public.agent_pending_auth
    (id, user_code, match_number, match_choices, nonce_hash, params, client_name, status, expires_at)
  values ('pend-consumed', 'BCDFGHJK', 1, '{1}', 'n', '{}', 'c', 'consumed', now() + interval '10 minutes');
end $$;

-- (e) deleting a connection cascades its tokens, nulls the draft's link.
do $$
declare
  n int;
  c text;
begin
  insert into public.agent_tokens (hash, kind, connection_id, resource, scopes, expires_at)
  values ('tok-a2', 'refresh', 'conn-a', 'https://mcp.test', '{read}', now() + interval '1 day');
  delete from public.agent_connections where id = 'conn-a';
  select count(*) into n from public.agent_tokens where connection_id = 'conn-a';
  if n <> 0 then raise exception 'tokens survived their connection: %', n; end if;
  select connection_id into c from public.agent_drafts where id = 'draft-a';
  if c is not null then raise exception 'draft kept connection_id %', c; end if;
  select count(*) into n from public.agent_drafts where id = 'draft-a';
  if n <> 1 then raise exception 'draft was deleted with the connection'; end if;
  select count(*) into n from public.agent_tokens where hash = 'tok-b';
  if n <> 1 then raise exception 'other user token was deleted'; end if;
end $$;

-- (d) deleting a user cascades everything of theirs (user A; B untouched).
do $$
declare
  n int;
begin
  insert into public.agent_connections (id, user_id, client_id, client_name, scopes)
  values ('conn-a3', 'a1111111-1111-1111-1111-111111111111', 'c', 'c', '{}');
  insert into public.agent_tokens (hash, kind, connection_id, resource, scopes, expires_at)
  values ('tok-a3', 'access', 'conn-a3', 'r', '{}', now() + interval '1 hour');
  delete from auth.users where id = 'a1111111-1111-1111-1111-111111111111';
  select count(*) into n from public.agent_connections where user_id = 'a1111111-1111-1111-1111-111111111111';
  if n <> 0 then raise exception 'connections survived user deletion'; end if;
  select count(*) into n from public.agent_tokens where hash in ('tok-a', 'tok-a3');
  if n <> 0 then raise exception 'tokens survived user deletion'; end if;
  select count(*) into n from public.agent_snapshots where user_id = 'a1111111-1111-1111-1111-111111111111';
  if n <> 0 then raise exception 'snapshot survived user deletion'; end if;
  select count(*) into n from public.agent_drafts where user_id = 'a1111111-1111-1111-1111-111111111111';
  if n <> 0 then raise exception 'draft survived user deletion'; end if;
  select count(*) into n from public.agent_pending_auth where user_id = 'a1111111-1111-1111-1111-111111111111';
  if n <> 0 then raise exception 'pending row survived user deletion'; end if;
  select count(*) into n from public.agent_snapshots where user_id = 'b2222222-2222-2222-2222-222222222222';
  if n <> 1 then raise exception 'user B snapshot was deleted'; end if;
  raise notice 'agent_connection: all checks passed';
end $$;
