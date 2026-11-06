-- Behavioural check of finish_fact_extraction()
-- (20261105090000_finish_fact_extraction.sql) against a real Postgres: facts
-- are inserted with the extraction's course/document/hash, a second finish of
-- the same extraction REPLACES them (no duplicates), a failed finish leaves
-- facts alone, a failure midway rolls the whole finish back, a missing row
-- and a bad status raise, and `authenticated` cannot call it. Run after
-- local_auth_stub.sql and every migration, as claim_fact_extraction.test.sql:
--
--   scripts/sql-check.sh
\set ON_ERROR_STOP on
set role service_role;
insert into public.courses (course_id, code, name) values ('91001','TST 101','f1') on conflict do nothing;
insert into public.course_documents (id, course_id, course_code, kind, source_id, title, text, content_hash, fetched_at)
values ('announcement:91001:f1','91001','TST 101','announcement','f1','F','body','fh1',now()) on conflict do nothing;

-- The claim test leaves the global monthly budget spent; start clean.
delete from public.fact_extraction_budget;

do $$ declare r text; n int; s text; c int; seq1 bigint; seq2 bigint; begin
  r := public.claim_fact_extraction('announcement:91001:f1','91001','fh1');
  if r <> 'claimed' then raise exception 'setup claim returned %', r; end if;

  -- 1. done with two facts
  perform public.finish_fact_extraction(
    'announcement:91001:f1','fh1','done',
    '[{"fact_type":"new_task","target_source_id":null,"title":"Read ch 5","due_at":"2026-11-10T23:59:00Z","kind":"preparation","quote":"q1","confidence":"high"},
      {"fact_type":"cancel","target_source_id":"123","title":null,"due_at":null,"kind":null,"quote":"q2","confidence":"medium"}]'::jsonb,
    '2026-11-04T12:00:00Z', 2, 1, '{"quote_not_in_text":1}'::jsonb, 'm', 10, 20, 0, 0.0012, 345, null);
  select count(*) into n from public.course_facts where document_id='announcement:91001:f1';
  if n <> 2 then raise exception 'expected 2 facts, got %', n; end if;
  select status, fact_count into s, c from public.course_fact_extractions where document_id='announcement:91001:f1';
  if s <> 'done' or c <> 2 then raise exception 'row status=% fact_count=%', s, c; end if;
  select count(*) into n from public.course_facts f
    join public.course_fact_extractions e on e.id = f.extraction_id
   where f.course_id = '91001' and f.content_hash = 'fh1' and f.posted_at = '2026-11-04T12:00:00Z' and e.document_id = f.document_id;
  if n <> 2 then raise exception 'facts not filed under the extraction row'; end if;
  select min(seq) into seq1 from public.course_facts where document_id='announcement:91001:f1';

  -- 2. finishing again replaces, never duplicates
  perform public.finish_fact_extraction(
    'announcement:91001:f1','fh1','done',
    '[{"fact_type":"note","target_source_id":"123","title":"covers ch 5","due_at":null,"kind":null,"quote":"q3","confidence":"high"}]'::jsonb,
    null, 1, 0, '{}'::jsonb, 'm', null, null, null, null, 10, null);
  select count(*) into n from public.course_facts where document_id='announcement:91001:f1';
  if n <> 1 then raise exception 'second finish left % facts', n; end if;
  select min(seq) into seq2 from public.course_facts where document_id='announcement:91001:f1';
  if seq2 <= seq1 then raise exception 'seq did not advance on replace'; end if;

  -- 3. a failed finish keeps the facts and records the status
  perform public.finish_fact_extraction('announcement:91001:f1','fh1','failed', '[]'::jsonb, null, 0, 0, '{}'::jsonb, 'm', null, null, null, null, 5, 'timeout');
  select count(*) into n from public.course_facts where document_id='announcement:91001:f1';
  if n <> 1 then raise exception 'failed finish touched facts: %', n; end if;
  select status into s from public.course_fact_extractions where document_id='announcement:91001:f1';
  if s <> 'failed' then raise exception 'status=%', s; end if;

  -- 4. a bad fact (null quote violates NOT NULL) rolls the whole finish back:
  -- the old fact survives and the row keeps its status
  begin
    perform public.finish_fact_extraction(
      'announcement:91001:f1','fh1','done',
      '[{"fact_type":"cancel","target_source_id":"1","title":null,"due_at":null,"kind":null,"quote":null,"confidence":"high"}]'::jsonb,
      null, 1, 0, '{}'::jsonb, 'm', null, null, null, null, 5, null);
    raise exception 'bad fact was accepted';
  exception when not_null_violation then
    null;
  end;
  select count(*) into n from public.course_facts where document_id='announcement:91001:f1';
  if n <> 1 then raise exception 'rollback lost the old fact: %', n; end if;
  select status into s from public.course_fact_extractions where document_id='announcement:91001:f1';
  if s <> 'failed' then raise exception 'rollback changed the row to %', s; end if;

  -- 5. missing row, bad status
  begin
    perform public.finish_fact_extraction('announcement:91001:nope','x','done');
    raise exception 'missing row accepted';
  exception when raise_exception then
    if sqlerrm not like '%extraction row missing%' then raise; end if;
  end;
  begin
    perform public.finish_fact_extraction('announcement:91001:f1','fh1','pending');
    raise exception 'bad status accepted';
  exception when raise_exception then
    if sqlerrm not like '%bad status%' then raise; end if;
  end;

  -- 6. authenticated cannot call it
  begin
    perform set_config('role','authenticated', true);
    perform public.finish_fact_extraction('announcement:91001:f1','fh1','done');
    raise exception 'authenticated could call finish_fact_extraction';
  exception when insufficient_privilege then
    perform set_config('role','service_role', true);
  end;
  raise notice 'finish_fact_extraction: all 6 checks passed';
end $$;
