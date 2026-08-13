-- 0002_relationship_tables.sql
-- Cascade / align link tables, review participants, and the rating rollup
-- output table. Tables only — policies land in 0003, functions in 0004.
--
-- Cascade and align are deliberately SEPARATE tables, not a single
-- parent_goal_id column: cascade records a top-down copy event, alignment
-- records a bottom-up link between two independently pre-existing goals.
-- Merging them would lose the origin-direction distinction.
-- Idempotent: safe to re-run.

-- ---------------------------------------------------------------------------
-- goal_cascade — a manager's goal was copied into a report's goal
-- ---------------------------------------------------------------------------

create table if not exists public.goal_cascade (
  id               uuid primary key default gen_random_uuid(),
  source_goal_id   uuid not null references public.goal (id) on delete cascade,
  -- a goal can only be the RESULT of one cascade
  cascaded_goal_id uuid not null unique references public.goal (id) on delete cascade,
  cascaded_by      uuid not null references public.profiles (id),
  cascaded_at      timestamptz not null default now(),
  constraint goal_cascade_no_self_copy check (source_goal_id <> cascaded_goal_id)
);

create index if not exists goal_cascade_source_goal_id_idx on public.goal_cascade (source_goal_id);

-- ---------------------------------------------------------------------------
-- goal_alignment — two pre-existing goals linked; one alignment UP per goal,
-- many children per parent
-- ---------------------------------------------------------------------------

create table if not exists public.goal_alignment (
  id             uuid primary key default gen_random_uuid(),
  parent_goal_id uuid not null references public.goal (id) on delete cascade,
  -- unique: enforces "a goal may align upward to only one parent"
  child_goal_id  uuid not null unique references public.goal (id) on delete cascade,
  created_by     uuid not null references public.profiles (id),
  created_at     timestamptz not null default now(),
  constraint goal_alignment_no_self_link check (parent_goal_id <> child_goal_id)
);

create index if not exists goal_alignment_parent_goal_id_idx on public.goal_alignment (parent_goal_id);

-- ---------------------------------------------------------------------------
-- review_participant — the table RLS keys off (not role names alone)
-- ---------------------------------------------------------------------------

create table if not exists public.review_participant (
  id                    uuid primary key default gen_random_uuid(),
  employee_goal_plan_id uuid not null references public.employee_goal_plan (id) on delete cascade,
  participant_id        uuid not null references public.profiles (id) on delete cascade,
  role                  participant_role not null,
  created_at            timestamptz not null default now(),
  constraint review_participant_unique_role
    unique (employee_goal_plan_id, participant_id, role)
);

create index if not exists review_participant_plan_id_idx on public.review_participant (employee_goal_plan_id);
create index if not exists review_participant_participant_id_idx on public.review_participant (participant_id);

-- ---------------------------------------------------------------------------
-- goal_plan_rating — one row per (plan, rating_type) so self and manager
-- scores stay independently visible during manager eval, never overwritten
-- in place by each other
-- ---------------------------------------------------------------------------

create table if not exists public.goal_plan_rating (
  id                    uuid primary key default gen_random_uuid(),
  employee_goal_plan_id uuid not null references public.employee_goal_plan (id) on delete cascade,
  rating_type           rating_type not null,
  -- rescaled Average Method result, on the plan's overall_rating_scale_max
  overall_score         numeric(6,3) not null,
  computed_at           timestamptz not null default now(),
  constraint goal_plan_rating_unique_per_type unique (employee_goal_plan_id, rating_type),
  constraint goal_plan_rating_score_non_negative check (overall_score >= 0)
);

create index if not exists goal_plan_rating_plan_id_idx on public.goal_plan_rating (employee_goal_plan_id);
