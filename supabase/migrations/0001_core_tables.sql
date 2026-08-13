-- 0001_core_tables.sql
-- Phase 1 MVP schema: enums, core tables, updated_at trigger.
-- Scope: KRA only. No Objective/KeyResult/Calibration tables (Phase 2/3).
-- RLS policies live in 0003; rating rollup lives in 0004.
-- Idempotent: safe to re-run.

-- ---------------------------------------------------------------------------
-- Enums (exact strings per RULING.md)
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_type where typname = 'review_cycle_status') then
    create type review_cycle_status as enum ('draft', 'active', 'self_eval', 'manager_eval', 'closed');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'goal_plan_status') then
    create type goal_plan_status as enum ('draft', 'submitted', 'manager_reviewed', 'finalized');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'participant_role') then
    create type participant_role as enum ('employee', 'line_manager', 'hr_admin');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'rating_type') then
    create type rating_type as enum ('self', 'manager');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- updated_at trigger function
-- ---------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- profiles — extends auth.users
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  full_name    text not null,
  email        text not null unique,
  -- direct line manager only; matrix reporting is Phase 2
  manager_id   uuid references public.profiles (id) on delete set null,
  is_hr_admin  boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint profiles_manager_not_self check (manager_id is null or manager_id <> id)
);

create index if not exists profiles_manager_id_idx on public.profiles (manager_id);

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- review_cycle
-- ---------------------------------------------------------------------------

create table if not exists public.review_cycle (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  start_date  date not null,
  end_date    date not null,
  status      review_cycle_status not null default 'draft',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint review_cycle_dates_ordered check (end_date >= start_date)
);

drop trigger if exists review_cycle_set_updated_at on public.review_cycle;
create trigger review_cycle_set_updated_at
  before update on public.review_cycle
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- employee_goal_plan — one per employee per cycle
-- ---------------------------------------------------------------------------

create table if not exists public.employee_goal_plan (
  id                       uuid primary key default gen_random_uuid(),
  review_cycle_id          uuid not null references public.review_cycle (id) on delete cascade,
  employee_id              uuid not null references public.profiles (id) on delete cascade,
  status                   goal_plan_status not null default 'draft',
  -- scale the Average Method result is rescaled back onto (e.g. 5 => 1-5 scale)
  overall_rating_scale_max integer not null default 5,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  constraint employee_goal_plan_unique_per_cycle unique (review_cycle_id, employee_id),
  constraint employee_goal_plan_scale_positive check (overall_rating_scale_max > 0)
);

create index if not exists employee_goal_plan_employee_id_idx on public.employee_goal_plan (employee_id);
create index if not exists employee_goal_plan_review_cycle_id_idx on public.employee_goal_plan (review_cycle_id);

drop trigger if exists employee_goal_plan_set_updated_at on public.employee_goal_plan;
create trigger employee_goal_plan_set_updated_at
  before update on public.employee_goal_plan
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- kra_category — weight is a percent of the whole plan
-- ---------------------------------------------------------------------------

create table if not exists public.kra_category (
  id                    uuid primary key default gen_random_uuid(),
  employee_goal_plan_id uuid not null references public.employee_goal_plan (id) on delete cascade,
  name                  text not null,
  description           text,
  -- percent of the plan; should sum to 100 across a plan, but plans are built
  -- incrementally so the 100-total check is deferred to validate_goal_plan_weights (0004)
  weight                numeric(6,2) not null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint kra_category_weight_range check (weight >= 0 and weight <= 100)
);

create index if not exists kra_category_plan_id_idx on public.kra_category (employee_goal_plan_id);

drop trigger if exists kra_category_set_updated_at on public.kra_category;
create trigger kra_category_set_updated_at
  before update on public.kra_category
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- goal — weight is a percent within its category
-- ---------------------------------------------------------------------------

create table if not exists public.goal (
  id               uuid primary key default gen_random_uuid(),
  kra_category_id  uuid not null references public.kra_category (id) on delete cascade,
  title            text not null,
  description      text,
  -- percent within its category; should sum to 100 per category, deferred as above
  weight           numeric(6,2) not null,
  target_metric    text,
  rating_scale_max integer not null default 5,
  self_rating      numeric(5,2),
  self_comment     text,
  manager_rating   numeric(5,2),
  manager_comment  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint goal_weight_range check (weight >= 0 and weight <= 100),
  constraint goal_rating_scale_positive check (rating_scale_max > 0),
  constraint goal_self_rating_range
    check (self_rating is null or (self_rating >= 0 and self_rating <= rating_scale_max)),
  constraint goal_manager_rating_range
    check (manager_rating is null or (manager_rating >= 0 and manager_rating <= rating_scale_max))
);

create index if not exists goal_kra_category_id_idx on public.goal (kra_category_id);

drop trigger if exists goal_set_updated_at on public.goal;
create trigger goal_set_updated_at
  before update on public.goal
  for each row execute function public.set_updated_at();
