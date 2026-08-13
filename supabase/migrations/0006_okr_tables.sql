-- 0006_okr_tables.sql
-- Phase 2 Part A: the OKR overlay — objective / key_result / check_in /
-- objective_alignment. Tables, enums, indexes and set_updated_at triggers only.
--
-- RLS lands in 0008; the score-recompute and check-in triggers land in 0009.
-- The OKR tree is structurally separate from the Phase 1 KRA scorecard: no
-- column here feeds compute_goal_plan_rating, by design.
--
-- Alignment only, no cascade table: OKR tools link objectives, they do not
-- copy them the way KRAs cascade (see 0002's goal_cascade vs goal_alignment).
--
-- Idempotent: safe to re-run.

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_type where typname = 'objective_status') then
    create type objective_status as enum ('active', 'closed');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'scope_type') then
    create type scope_type as enum ('kra_category', 'objective');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- objective — single-owner for this phase (team-owned is a later extension)
-- ---------------------------------------------------------------------------

create table if not exists public.objective (
  id              uuid primary key default gen_random_uuid(),
  review_cycle_id uuid not null references public.review_cycle (id) on delete cascade,
  owner_id        uuid not null references public.profiles (id) on delete cascade,
  title           text not null,
  description     text,
  status          objective_status not null default 'active',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists objective_review_cycle_id_idx on public.objective (review_cycle_id);
create index if not exists objective_owner_id_idx on public.objective (owner_id);

drop trigger if exists objective_set_updated_at on public.objective;
create trigger objective_set_updated_at
  before update on public.objective
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- key_result — industry-standard 0.0-1.0 scoring
--
-- score is a STORED column, not a view expression, because the Part C summary
-- reads it directly. It is recomputed by a BEFORE INSERT OR UPDATE trigger in
-- 0009, never by application code. score_override wins over score for display:
-- the effective value is coalesce(score_override, score).
-- ---------------------------------------------------------------------------

create table if not exists public.key_result (
  id             uuid primary key default gen_random_uuid(),
  objective_id   uuid not null references public.objective (id) on delete cascade,
  title          text not null,
  -- free text: '%', 'requests/sec', 'tickets', ...
  metric_unit    text,
  start_value    numeric not null default 0,
  target_value   numeric not null,
  -- defaults to start_value at insert time; maintained by the check_in trigger
  current_value  numeric,
  -- 0.0-1.0, computed; null when target_value = start_value (degenerate case)
  score          numeric(4,3),
  -- manual override; wins over score wherever the effective score is read
  score_override numeric(4,3),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint key_result_score_range
    check (score is null or (score >= 0 and score <= 1)),
  constraint key_result_score_override_range
    check (score_override is null or (score_override >= 0 and score_override <= 1))
);

create index if not exists key_result_objective_id_idx on public.key_result (objective_id);

drop trigger if exists key_result_set_updated_at on public.key_result;
create trigger key_result_set_updated_at
  before update on public.key_result
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- check_in — an append-only progress event on a key result.
--
-- Inserting a check-in updates the parent key_result.current_value to
-- new_value via an AFTER INSERT trigger (0009), which in turn fires the
-- key_result BEFORE UPDATE score trigger. Documented here so the mechanism is
-- discoverable from the table it acts on: TRIGGER, not application logic.
-- ---------------------------------------------------------------------------

create table if not exists public.check_in (
  id            uuid primary key default gen_random_uuid(),
  key_result_id uuid not null references public.key_result (id) on delete cascade,
  checked_in_by uuid not null references public.profiles (id),
  new_value     numeric not null,
  note          text,
  created_at    timestamptz not null default now()
);

create index if not exists check_in_key_result_id_idx on public.check_in (key_result_id);
create index if not exists check_in_created_at_idx on public.check_in (key_result_id, created_at);

-- ---------------------------------------------------------------------------
-- objective_alignment — bottom-up link, one alignment UP per objective, many
-- children per parent. Mirrors goal_alignment in 0002 exactly, including the
-- unique constraint on the CHILD column.
--
-- Insert authorization (0008) mirrors Phase 1 Ruling 3: write authority on the
-- CHILD objective plus read authority on the PARENT — not participation in
-- both. That asymmetry is the whole point.
-- ---------------------------------------------------------------------------

create table if not exists public.objective_alignment (
  id                  uuid primary key default gen_random_uuid(),
  parent_objective_id uuid not null references public.objective (id) on delete cascade,
  -- unique: an objective may align upward to only one parent
  child_objective_id  uuid not null unique references public.objective (id) on delete cascade,
  created_by          uuid not null references public.profiles (id),
  created_at          timestamptz not null default now(),
  constraint objective_alignment_no_self_link
    check (parent_objective_id <> child_objective_id)
);

create index if not exists objective_alignment_parent_idx
  on public.objective_alignment (parent_objective_id);
