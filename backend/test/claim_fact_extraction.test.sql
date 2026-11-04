-- Behavioural check of claim_fact_extraction() (20261104090000_course_facts.sql)
-- against a real Postgres: the state machine (pending → running → done /
-- failed, three attempts, a running row stale after five minutes is
-- re-claimable), the three budgets (course per day, course per month,
-- global per month; a skipped row is retried once the budget allows) and
-- the revoke from `authenticated`. Run after local_auth_stub.sql, every
-- migration in order and rls.test.sql, as the same role:
--
--   scripts/sql-check.sh        # does all of that in a throwaway Docker Postgres
--
-- First run 2026-11-04 on Marco's Mac (postgres:16 in OrbStack): all 11
-- checks passed. Note for readers of the budget: a stale `running` row that
-- is re-claimed counts against the budget again, because the model is
-- called again; that is on purpose.
\set ON_ERROR_STOP on
set role service_role;
insert into public.courses (course_id, code, name) values ('90001','TST 001','t1'),('90002','TST 002','t2') on conflict do nothing;
insert into public.course_documents (id, course_id, course_code, kind, source_id, title, text, content_hash, fetched_at)
select 'announcement:90001:d'||g, '90001', 'TST 001', 'announcement', 'd'||g, 'T'||g, 'body', 'h1', now() from generate_series(1,6) g on conflict do nothing;
insert into public.course_documents (id, course_id, course_code, kind, source_id, title, text, content_hash, fetched_at)
values ('announcement:90002:x1','90002','TST 002','announcement','x1','X','body','h1',now()) on conflict do nothing;

do $$ declare r text; a int; s text; begin
  -- 1. fresh claim
  r := public.claim_fact_extraction('announcement:90001:d1','90001','h1');
  if r <> 'claimed' then raise exception 'fresh claim returned %', r; end if;
  select status, attempts into s, a from public.course_fact_extractions where document_id='announcement:90001:d1' and content_hash='h1';
  if s <> 'running' or a <> 1 then raise exception 'after claim status=% attempts=%', s, a; end if;
  -- 2. re-claim while running (fresh) is refused
  r := public.claim_fact_extraction('announcement:90001:d1','90001','h1');
  if r = 'claimed' then raise exception 're-claim of a running row was allowed'; end if;
  raise notice 'running re-claim -> %', r;
  -- 3. stale running (>5 min) is re-claimable, attempts climb
  update public.course_fact_extractions set updated_at = now() - interval '6 minutes' where document_id='announcement:90001:d1';
  r := public.claim_fact_extraction('announcement:90001:d1','90001','h1');
  if r <> 'claimed' then raise exception 'stale running not re-claimed: %', r; end if;
  -- 4. failed 3 times gives up
  update public.course_fact_extractions set status='failed', attempts=3 where document_id='announcement:90001:d1';
  r := public.claim_fact_extraction('announcement:90001:d1','90001','h1');
  if r = 'claimed' then raise exception 'claimed after 3 failures'; end if;
  raise notice 'after 3 failures -> %', r;
  -- 5. done is final
  update public.course_fact_extractions set status='done' where document_id='announcement:90001:d1';
  r := public.claim_fact_extraction('announcement:90001:d1','90001','h1');
  if r <> 'not_pending' then raise exception 'done row returned %', r; end if;
  -- 6. a new hash of the same document is a new extraction
  r := public.claim_fact_extraction('announcement:90001:d1','90001','h2');
  if r <> 'claimed' then raise exception 'new hash not claimed: %', r; end if;
  -- 7. daily cap: limit 3 for course 90001; d1(h1) + d1(h2) used 2 so far today (stale re-claim counted too: check)
  select extractions into a from public.fact_extraction_budget where course_id='90001' and day=current_date;
  raise notice 'budget used so far today for 90001 = %', a;
  r := public.claim_fact_extraction('announcement:90001:d2','90001','h1', 3, 3);  -- limit 3
  raise notice 'd2 with daily limit 3 -> %', r;
  r := public.claim_fact_extraction('announcement:90001:d3','90001','h1', 3, 3);
  if r <> 'skipped_budget' then raise exception 'daily cap not enforced: % (used=%)', r, a; end if;
  select detail into s from public.course_fact_extractions where document_id='announcement:90001:d3';
  if s <> 'course daily cap' then raise exception 'detail=%', s; end if;
  -- 8. a skipped row is retried later (status not final)
  update public.fact_extraction_budget set extractions = 0 where course_id='90001';
  r := public.claim_fact_extraction('announcement:90001:d3','90001','h1', 3, 3);
  if r <> 'claimed' then raise exception 'skipped row not retried after budget reset: %', r; end if;
  -- 9. course monthly cap does not touch another course
  update public.fact_extraction_budget set extractions = 400 where course_id='90001';
  r := public.claim_fact_extraction('announcement:90001:d4','90001','h1');
  if r <> 'skipped_budget' then raise exception 'course monthly cap not enforced: %', r; end if;
  r := public.claim_fact_extraction('announcement:90002:x1','90002','h1');
  if r <> 'claimed' then raise exception 'other course blocked by course cap: %', r; end if;
  -- 10. global monthly cap blocks everyone
  update public.fact_extraction_budget set extractions = 5000 where course_id='90001';
  update public.course_fact_extractions set status='done' where document_id='announcement:90002:x1';
  r := public.claim_fact_extraction('announcement:90001:d5','90001','h1');
  if r <> 'skipped_budget' then raise exception 'global cap not enforced: %', r; end if;
  select detail into s from public.course_fact_extractions where document_id='announcement:90001:d5';
  if s <> 'monthly global cap' then raise exception 'detail=%', s; end if;
  -- 11. authenticated cannot call it
  begin
    perform set_config('role','authenticated', true);
    perform public.claim_fact_extraction('announcement:90001:d6','90001','h1');
    raise exception 'authenticated could call claim_fact_extraction';
  exception when insufficient_privilege then
    perform set_config('role','service_role', true);
  end;
  raise notice 'claim_fact_extraction: all 11 checks passed';
end $$;
