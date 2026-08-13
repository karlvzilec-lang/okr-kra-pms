-- 0007_matrix_tables.sql
-- Phase 2 Part B: matrix-manager scoping tables.
--
-- review_participant_scope is what makes matrix access SCOPED rather than
-- blanket: a matrix manager may act only on the specific sections explicitly
-- granted to them. RLS in 0008 must always join through this table — checking
-- role = 'matrix_manager' alone is the SAP EX-role bug the research flagged.
--
-- goal_matrix_rating is deliberately separate from goal.manager_rating /
-- goal.manager_comment: those belong to the line-manager relationship and are
-- guarded by restrict_manager_goal_updates (0003), and multiple matrix
-- managers may independently rate the same goal. Matrix ratings are advisory
-- and do NOT feed compute_goal_plan_rating.
--
-- Depends on 0005 having committed 'matrix_manager' into participant_role.
-- Idempotent: safe to re-run.

-- ---------------------------------------------------------------------------
-- review_participant_scope
--
-- scope_id is polymorphic (kra_category.id or objective.id) so it carries no
-- FK; existence is validated by trigger below instead.
-- ---------------------------------------------------------------------------

create table if not exists public.review_participant_scope (
  id                    uuid primary key default gen_random_uuid(),
  review_participant_id uuid not null references public.review_participant (id) on delete cascade,
  scope_type            scope_type not null,
  scope_id              uuid not null,
  created_at            timestamptz not null default now(),
  constraint review_participant_scope_unique
    unique (review_participant_id, scope_type, scope_id)
);

create index if not exists review_participant_scope_participant_idx
  on public.review_participant_scope (review_participant_id);
create index if not exists review_participant_scope_lookup_idx
  on public.review_participant_scope (scope_type, scope_id);

-- ---------------------------------------------------------------------------
-- Trigger 1: the referenced review_participant row must have role
-- 'matrix_manager'. Enforced, not left to convention — a scope grant hung off
-- an 'employee' or 'line_manager' row would be meaningless at best and an
-- access-widening accident at worst.
-- ---------------------------------------------------------------------------

create or replace function public.enforce_scope_participant_is_matrix()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.participant_role;
begin
  select rp.role
  into v_role
  from public.review_participant as rp
  where rp.id = new.review_participant_id;

  if v_role is null then
    raise exception 'review_participant % does not exist', new.review_participant_id
      using errcode = '23503';
  end if;

  if v_role <> 'matrix_manager' then
    raise exception
      'review_participant_scope may only reference a matrix_manager participant (row % has role %)',
      new.review_participant_id,
      v_role
      using errcode = '23514';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Trigger 2: polymorphic scope_id existence validation. Replaces the FK that
-- a polymorphic column cannot have.
-- ---------------------------------------------------------------------------

create or replace function public.validate_scope_target_exists()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.scope_type = 'kra_category' then
    if not exists (
      select 1 from public.kra_category as kc where kc.id = new.scope_id
    ) then
      raise exception 'kra_category % does not exist', new.scope_id
        using errcode = '23503';
    end if;

  elsif new.scope_type = 'objective' then
    if not exists (
      select 1 from public.objective as o where o.id = new.scope_id
    ) then
      raise exception 'objective % does not exist', new.scope_id
        using errcode = '23503';
    end if;

  else
    raise exception 'Unhandled scope_type %', new.scope_type
      using errcode = '22023';
  end if;

  return new;
end;
$$;

drop trigger if exists review_participant_scope_enforce_role on public.review_participant_scope;
create trigger review_participant_scope_enforce_role
  before insert or update on public.review_participant_scope
  for each row execute function public.enforce_scope_participant_is_matrix();

drop trigger if exists review_participant_scope_validate_target on public.review_participant_scope;
create trigger review_participant_scope_validate_target
  before insert or update on public.review_participant_scope
  for each row execute function public.validate_scope_target_exists();

-- ---------------------------------------------------------------------------
-- goal_matrix_rating — advisory input, surfaced to the line manager / HR.
-- Unique per (goal, participant) so each matrix manager holds exactly one
-- rating per goal, while several may rate the same goal independently.
-- ---------------------------------------------------------------------------

create table if not exists public.goal_matrix_rating (
  id             uuid primary key default gen_random_uuid(),
  goal_id        uuid not null references public.goal (id) on delete cascade,
  participant_id uuid not null references public.profiles (id) on delete cascade,
  rating         numeric(5,2),
  comment        text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint goal_matrix_rating_unique_per_rater unique (goal_id, participant_id),
  constraint goal_matrix_rating_non_negative
    check (rating is null or rating >= 0)
);

create index if not exists goal_matrix_rating_goal_id_idx on public.goal_matrix_rating (goal_id);
create index if not exists goal_matrix_rating_participant_id_idx
  on public.goal_matrix_rating (participant_id);

drop trigger if exists goal_matrix_rating_set_updated_at on public.goal_matrix_rating;
create trigger goal_matrix_rating_set_updated_at
  before update on public.goal_matrix_rating
  for each row execute function public.set_updated_at();
