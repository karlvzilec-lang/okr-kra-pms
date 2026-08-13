-- 0009_okr_scoring.sql
-- Stored OKR scoring and check-in propagation.

-- Recompute the stored 0.0-1.0 score whenever an input to the formula changes.
-- A degenerate start/target range has no meaningful progress ratio, so its
-- score is NULL. score_override remains independent and is applied at read time.
create or replace function public.recompute_key_result_score()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.current_value is null
    or new.start_value is null
    or new.target_value is null
    or new.start_value = new.target_value
  then
    new.score := null;
  else
    new.score := greatest(
      0::numeric,
      least(
        1::numeric,
        (new.current_value - new.start_value)
          / (new.target_value - new.start_value)
      )
    );
  end if;

  return new;
end;
$$;

revoke all on function public.recompute_key_result_score() from public;

drop trigger if exists key_result_recompute_score on public.key_result;
create trigger key_result_recompute_score
before insert or update
on public.key_result
for each row
execute function public.recompute_key_result_score();

-- A successful check-in atomically advances its key result. The UPDATE fires
-- key_result_recompute_score, so current_value and score cannot drift apart.
create or replace function public.apply_check_in_to_key_result()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.key_result
  set current_value = new.new_value
  where id = new.key_result_id;

  if not found then
    raise exception 'Key result % does not exist or is not writable', new.key_result_id
      using errcode = '42501';
  end if;

  return new;
end;
$$;

revoke all on function public.apply_check_in_to_key_result() from public;

drop trigger if exists check_in_apply_current_value on public.check_in;
create trigger check_in_apply_current_value
after insert on public.check_in
for each row
execute function public.apply_check_in_to_key_result();
