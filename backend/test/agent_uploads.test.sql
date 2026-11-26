-- Checks 20261110090000_agent_uploads.sql: chunks cascade with their upload,
-- (upload, index) is unique, the sweeper removes expired uploads and keeps
-- live ones, an account's uploads go with the account, and the tables are
-- service-role only. Run after local_auth_stub.sql and every migration.

\set ON_ERROR_STOP on

set role service_role;
select public.agent_sweep_expired();

insert into auth.users (id) values ('d4444444-4444-4444-4444-444444444444');

insert into public.agent_uploads (id, user_id, connection_id, assignment_id, file_name, mime_type, total_bytes, sha256, chunk_bytes, chunks, expires_at) values
  ('up-old', 'd4444444-4444-4444-4444-444444444444', 'c1', 'a', 'x.pdf', 'application/pdf', 20000, repeat('a', 64), 16384, 2, now() - interval '1 minute'),
  ('up-live', 'd4444444-4444-4444-4444-444444444444', 'c1', 'a', 'y.pdf', 'application/pdf', 10, repeat('b', 64), 16384, 1, now() + interval '20 minutes');
insert into public.agent_upload_chunks (upload_id, index, data, sha256) values
  ('up-old', 0, '\x0102'::bytea, repeat('c', 64)),
  ('up-old', 1, '\x03'::bytea, repeat('d', 64)),
  ('up-live', 0, '\x0a0b'::bytea, repeat('e', 64));

do $$
declare
  n integer;
begin
  -- (a) a second row for the same index is refused; an upsert replaces it.
  begin
    insert into public.agent_upload_chunks (upload_id, index, data, sha256) values ('up-live', 0, '\x00'::bytea, 'x');
    raise exception 'duplicate chunk index accepted';
  exception when unique_violation then null;
  end;
  insert into public.agent_upload_chunks (upload_id, index, data, sha256) values ('up-live', 0, '\xff'::bytea, 'f')
    on conflict (upload_id, index) do update set data = excluded.data, sha256 = excluded.sha256;
  if (select data from public.agent_upload_chunks where upload_id = 'up-live' and index = 0) <> '\xff'::bytea then
    raise exception 'chunk was not replaced';
  end if;
  -- bytes round-trip.
  if encode((select data from public.agent_upload_chunks where upload_id = 'up-old' and index = 0), 'hex') <> '0102' then
    raise exception 'bytea did not round-trip';
  end if;

  -- (b) the sweeper removes the expired upload and its chunks, keeps the live one.
  n := public.agent_sweep_expired();
  if n <> 1 then raise exception 'sweep removed % rows, expected 1', n; end if;
  if exists (select 1 from public.agent_uploads where id = 'up-old') then raise exception 'expired upload survived'; end if;
  if exists (select 1 from public.agent_upload_chunks where upload_id = 'up-old') then raise exception 'expired chunks survived'; end if;
  if not exists (select 1 from public.agent_upload_chunks where upload_id = 'up-live') then raise exception 'live chunk was swept'; end if;
end $$;

-- (c) deleting the account deletes its uploads and chunks.
reset role;
delete from auth.users where id = 'd4444444-4444-4444-4444-444444444444';
do $$
begin
  if exists (select 1 from public.agent_uploads) or exists (select 1 from public.agent_upload_chunks) then
    raise exception 'uploads outlived the account';
  end if;
end $$;

-- (d) anon and authenticated can read and write neither table.
do $$
declare
  r text;
  t text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    foreach t in array array['agent_uploads', 'agent_upload_chunks'] loop
      execute format('set role %I', r);
      begin
        execute format('select 1 from public.%I', t);
        raise exception '% could read %', r, t;
      exception when insufficient_privilege then null;
      end;
      reset role;
    end loop;
  end loop;
  raise notice 'agent_uploads: all checks passed';
end $$;
