-- Hardening BE-C (docs/HARDENING_PLAN_2026-10-25.md, BE-02): reserve a unit
-- of quota BEFORE the model call, atomically, and settle tokens afterwards.
--
-- Until now every model-calling function read `ask_usage_counts`, decided,
-- called the model, and only then (ask: after a clean stream; extract-
-- announcement: after a clean answer) wrote `record_ask_usage`. Two things
-- were therefore never counted: requests that overlapped (ten parallel
-- calls all read "5 of 40 used" and all went through), and requests the
-- client abandoned before the stream ended (the model had been called and
-- the provider billed it; the generator never reached the line that
-- charges). Both are free spend for anyone holding an anonymous JWT.
--
-- `reserve_ask_usage` does the check and the charge in ONE statement, so
-- there is no gap for a second request to slip through. The per-user daily
-- limit is the atomic part: `insert ... on conflict do update ... where
-- requests < limit` takes the row lock, re-evaluates the condition against
-- the newest row version, and returns a row only if it incremented, so N
-- parallel callers at 39 of 40 get exactly one reservation. The global
-- monthly limit is deliberately NOT serialized (that would put every
-- request from every user behind one lock): it is a sum read in the same
-- call, so it can overshoot by at most the number of requests in flight at
-- once, which is the right trade for a budget guard that is documented as
-- "never a feature gate" (PROTOCOL.md, quota).
--
-- `settle_ask_usage` then adds the tokens to the reserved day's row (and,
-- with p_refund, gives the request back). It takes the day the reservation
-- was made on, because a request reserved at 23:59:59 UTC and settled after
-- midnight must not decrement, or add tokens to, the wrong day.
--
-- The old `record_ask_usage` and `ask_usage_counts` are left as they are:
-- functions deployed before this migration still call them, and dropping
-- them would turn every one of those calls into an error (which fails open,
-- i.e. unmetered). Apply this migration BEFORE deploying the functions that
-- call the new pair; a function deployed first would find them missing,
-- fail open and meter nothing until the migration lands.
--
-- Both are SECURITY DEFINER, take the user id as a parameter, and are
-- granted to service_role only, exactly like the functions
-- 20261027090000_revoke_usage_functions.sql locks down. The `revoke` must
-- name anon and authenticated explicitly: Supabase's default privileges
-- grant them to those roles, which `from public` does not remove.

create function public.reserve_ask_usage(
  p_user_id uuid,
  p_daily_limit integer,
  p_monthly_global_limit bigint
)
returns table (allowed boolean, reserved_day date, today_requests integer, month_requests bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day date := (now() at time zone 'utc')::date;
  v_month_start date := date_trunc('month', (now() at time zone 'utc')::date)::date;
  v_month bigint;
  v_today integer;
begin
  -- Sargable: a range on the bare `day` column, not a function of it.
  select coalesce(sum(au.requests), 0)
    into v_month
    from public.ask_usage au
   where au.day >= v_month_start
     and au.day < (v_month_start + interval '1 month')::date;

  if v_month >= p_monthly_global_limit then
    select coalesce(
      (select au.requests from public.ask_usage au where au.user_id = p_user_id and au.day = v_day),
      0
    ) into v_today;
    return query select false, v_day, v_today, v_month;
    return;
  end if;

  insert into public.ask_usage (user_id, day, requests, prompt_tokens, completion_tokens, updated_at)
  values (p_user_id, v_day, 1, 0, 0, now())
  on conflict (user_id, day) do update
    set requests = public.ask_usage.requests + 1,
        updated_at = now()
    where public.ask_usage.requests < p_daily_limit
  returning public.ask_usage.requests into v_today;

  if found then
    return query select true, v_day, v_today, v_month + 1;
  else
    select au.requests into v_today
      from public.ask_usage au
     where au.user_id = p_user_id and au.day = v_day;
    return query select false, v_day, coalesce(v_today, 0), v_month;
  end if;
end;
$$;

create function public.settle_ask_usage(
  p_user_id uuid,
  p_day date,
  p_prompt_tokens bigint,
  p_completion_tokens bigint,
  p_refund boolean default false
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.ask_usage
     set requests          = case when p_refund then greatest(requests - 1, 0) else requests end,
         prompt_tokens     = prompt_tokens + greatest(coalesce(p_prompt_tokens, 0), 0),
         completion_tokens = completion_tokens + greatest(coalesce(p_completion_tokens, 0), 0),
         updated_at        = now()
   where user_id = p_user_id
     and day = p_day;
$$;

revoke execute on function public.reserve_ask_usage(uuid, integer, bigint)
  from public, anon, authenticated;
grant execute on function public.reserve_ask_usage(uuid, integer, bigint)
  to service_role;

revoke execute on function public.settle_ask_usage(uuid, date, bigint, bigint, boolean)
  from public, anon, authenticated;
grant execute on function public.settle_ask_usage(uuid, date, bigint, bigint, boolean)
  to service_role;
