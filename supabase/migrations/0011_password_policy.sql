-- 0011_password_policy.sql
-- Forced password rotation: password_changed_at is NULL until the user sets
-- their own password (forces a change on first login for HR-provisioned
-- accounts), and a policy elsewhere in the app treats it as expired again
-- after 60 days. This migration only adds the column, the self-update path,
-- and the guard restricting what a non-HR user may touch on their own row —
-- it does not enforce the 60-day window itself (that's an app-layer check,
-- since RLS can't express "reject reads based on a computed staleness rule"
-- without hiding the row entirely, which would break the user's ability to
-- read their own profile to see they need to change their password).

alter table public.profiles
  add column if not exists password_changed_at timestamptz;

-- ---------------------------------------------------------------------------
-- Self-update: a user may update their OWN profile row (previously only HR
-- could write to profiles at all), but only the password_changed_at field —
-- name, email, manager_id, is_hr_admin stay HR-only. Same column-level guard
-- pattern as restrict_manager_goal_updates (0003): RLS is row-aware, not
-- column-aware, so the trigger is the enforcement point.
-- ---------------------------------------------------------------------------

create or replace function public.restrict_profile_self_updates()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.is_hr_admin() then
    return new;
  end if;

  if new.id is distinct from old.id
    or new.full_name is distinct from old.full_name
    or new.email is distinct from old.email
    or new.manager_id is distinct from old.manager_id
    or new.is_hr_admin is distinct from old.is_hr_admin
    or new.created_at is distinct from old.created_at
  then
    raise exception 'You may only update your own password_changed_at timestamp'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

revoke all on function public.restrict_profile_self_updates() from public;

drop trigger if exists profiles_restrict_self_updates on public.profiles;
create trigger profiles_restrict_self_updates
before update on public.profiles
for each row
execute function public.restrict_profile_self_updates();

drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update
on public.profiles
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());
