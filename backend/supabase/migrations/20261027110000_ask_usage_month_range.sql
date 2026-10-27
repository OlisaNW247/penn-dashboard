-- Hardening BE-15: the monthly quota count could not use an index.
--
-- `ask_usage_counts` summed this month's requests with
--   where date_trunc('month', au.day) = date_trunc('month', <today>)
-- which applies a function to the column, so Postgres cannot use an index on
-- `day` and reads every row in the table for every quota check. The table is
-- one row per user per day, so today that is cheap, and it grows by the number
-- of active users every day for the life of the project; this runs on the
-- critical path of every `ask`, with a 1.5 s deadline after which the counter
-- fails open and stops metering. A range on the bare column is the same set of
-- rows:
--   where au.day >= <first of this month> and au.day < <first of next month>
-- and can use an index on `day`, which the primary key (user_id, day) cannot
-- serve for a query that does not name user_id.
--
-- The wrong fix would have been the index alone: with the function still
-- wrapped around the column the planner has nothing to match it against.
--
-- `reserve_ask_usage` (20261027100000) already uses the range form; this makes
-- the older read path agree and adds the index both rely on. Same signature and
-- return shape, so callers are untouched, and the grants are re-asserted
-- because they are the point of 20261027090000: service_role only.

create index if not exists ask_usage_day_idx on public.ask_usage (day);

create or replace function public.ask_usage_counts(p_user_id uuid)
returns table (today_requests integer, month_requests bigint)
language sql
security definer
set search_path = public
stable
as $$
  select
    coalesce((
      select au.requests
      from public.ask_usage au
      where au.user_id = p_user_id
        and au.day = (now() at time zone 'utc')::date
    ), 0) as today_requests,
    coalesce((
      select sum(au.requests)
      from public.ask_usage au
      where au.day >= date_trunc('month', (now() at time zone 'utc')::date)::date
        and au.day <  (date_trunc('month', (now() at time zone 'utc')::date) + interval '1 month')::date
    ), 0) as month_requests;
$$;

revoke execute on function public.ask_usage_counts(uuid) from public, anon, authenticated;
grant execute on function public.ask_usage_counts(uuid) to service_role;
