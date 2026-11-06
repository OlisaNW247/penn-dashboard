-- finish_fact_extraction(): the end of a fact extraction as ONE transaction.
--
-- Until now the Edge Function finished a run in three separate statements:
-- delete the extraction's old facts, insert the new ones, update the
-- extraction row. A run that died after the insert left the row `running`,
-- was retried once the 5 minute staleness rule let it be (see
-- claim_fact_extraction in 20261104090000_course_facts.sql), deleted and
-- re-inserted the same facts, and phones received them again under new
-- `seq` values (a fact's id on the phone is documentID + seq). A plpgsql
-- function body is a single transaction, so the three steps now commit
-- together or not at all, and a retry starts from a row that still says what
-- it said before.
--
-- Facts are only written when `p_status = 'done'`; a `failed` finish updates
-- the row alone and leaves any earlier facts of that revision untouched, the
-- way the three statements did. The facts go in as ONE insert (see the
-- `course_facts.seq` comment about commit order). `p_facts` is a jsonb array
-- of { fact_type, target_source_id, title, due_at, kind, quote, confidence };
-- course, document, content hash and post date come from the extraction row
-- and `p_posted_at`, so a caller cannot file a fact under another course.
--
-- ORDER OF DEPLOYMENT: apply this migration BEFORE the next `extract-facts`
-- deploy. The new extract-facts calls `finish_fact_extraction` through rpc and
-- there is no fallback to the old three statements: against a database
-- without this function every finish throws, the run ends early, and no fact
-- is stored. (scripts/deploy-facts.mjs applies only the course_facts
-- migration; apply this one by hand or through the Management API first.)
--
-- Idempotent like its predecessor: `create or replace` plus grants.
-- SECURITY DEFINER with the service-role-only grant, like every function that
-- takes ids as parameters.
create or replace function public.finish_fact_extraction(
  p_document_id text,
  p_content_hash text,
  p_status text,
  p_facts jsonb default '[]'::jsonb,
  p_posted_at timestamptz default null,
  p_fact_count integer default 0,
  p_rejected_count integer default 0,
  p_reject_reasons jsonb default '{}'::jsonb,
  p_model text default null,
  p_prompt_tokens integer default null,
  p_completion_tokens integer default null,
  p_reasoning_tokens integer default null,
  p_cost_usd numeric default null,
  p_latency_ms integer default null,
  p_detail text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_course text;
begin
  if p_status not in ('done', 'failed') then
    raise exception 'finish_fact_extraction: bad status %', p_status;
  end if;

  select e.id, e.course_id
    into v_id, v_course
    from public.course_fact_extractions e
   where e.document_id = p_document_id
     and e.content_hash = p_content_hash
     for update;
  if v_id is null then
    raise exception 'finish_fact_extraction: extraction row missing';
  end if;

  if p_status = 'done' then
    delete from public.course_facts where extraction_id = v_id;
    if jsonb_typeof(p_facts) = 'array' and jsonb_array_length(p_facts) > 0 then
      insert into public.course_facts (
        extraction_id, course_id, document_id, content_hash, fact_type,
        target_source_id, title, due_at, kind, quote, confidence, posted_at
      )
      select v_id, v_course, p_document_id, p_content_hash, f.fact_type,
             f.target_source_id, f.title, f.due_at, f.kind, f.quote, f.confidence, p_posted_at
        from jsonb_to_recordset(p_facts) as f(
          fact_type text, target_source_id text, title text, due_at timestamptz,
          kind text, quote text, confidence text
        );
    end if;
  end if;

  update public.course_fact_extractions
     set status = p_status,
         fact_count = p_fact_count,
         rejected_count = p_rejected_count,
         reject_reasons = coalesce(p_reject_reasons, '{}'::jsonb),
         model = p_model,
         prompt_tokens = p_prompt_tokens,
         completion_tokens = p_completion_tokens,
         reasoning_tokens = p_reasoning_tokens,
         cost_usd = p_cost_usd,
         latency_ms = p_latency_ms,
         detail = left(p_detail, 200),
         updated_at = now()
   where id = v_id;
end;
$$;

revoke execute on function public.finish_fact_extraction(
  text, text, text, jsonb, timestamptz, integer, integer, jsonb, text, integer, integer, integer, numeric, integer, text
) from public, anon, authenticated;
grant execute on function public.finish_fact_extraction(
  text, text, text, jsonb, timestamptz, integer, integer, jsonb, text, integer, integer, integer, numeric, integer, text
) to service_role;
