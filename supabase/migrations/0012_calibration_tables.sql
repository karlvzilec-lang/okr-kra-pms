-- 0012_calibration_tables.sql
-- Phase 3 Part A/B schema: the calibration overlay (calibration_session /
-- calibration_band / calibration_participant) plus the publish gate column
-- employee_goal_plan.published_at.
--
-- Tables, enum, indexes, set_updated_at triggers, and the original_score
-- immutability trigger only. RLS lands in 0013; the calibration functions
-- (add_plan_to_calibration_session, adjust_calibration_participant,
-- finalize_calibration_session, publish_employee_goal_plan) land in 0014.
--
-- Calibration is a FACILITATED pass, not a curve fit: nothing in this file
-- computes or enforces a distribution. original_score is the pre-calibration
-- snapshot, calibrated_score is what the facilitator lands on, and the pair of
-- them IS the audit trail — there is deliberately no changelog table.
--
-- Nothing here touches compute_goal_plan_rating or its inputs.
--
-- Idempotent: safe to re-run.

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_type where typname = 'calibration_session_status') then
    create type calibration_session_status as enum ('open', 'finalized');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- employee_goal_plan.published_at — the publish/close gate.
--
-- NULL means "not published": the employee must not see the calibrated/final
-- score yet. Only publish_employee_goal_plan (0014) sets it, and only after
-- checking the plan's calibration session is finalized (or that the plan was
-- never calibrated at all and its status is manager_reviewed/finalized).
-- Deliberately nullable with no default — the absence of a value is the state.
-- ---------------------------------------------------------------------------

alter table public.employee_goal_plan
  add column if not exists published_at timestamptz;

-- Partial index: every read of this column that matters (comp_export_rows in
-- 0015) filters on `published_at is not null`, so index only those rows.
create index if not exists employee_goal_plan_published_at_idx
  on public.employee_goal_plan (published_at)
  where published_at is not null;

-- ---------------------------------------------------------------------------
-- calibration_session — one facilitated pass over a review cycle.
--
-- A cycle may have several sessions (per department, per function), so there
-- is no unique constraint on review_cycle_id. status is the hard gate the
-- functions in 0014 check: 'finalized' freezes adjustments and unblocks
-- publishing.
-- ---------------------------------------------------------------------------

create table if not exists public.calibration_session (
  id              uuid primary key default gen_random_uuid(),
  review_cycle_id uuid not null references public.review_cycle (id) on delete cascade,
  name            text not null,
  status          calibration_session_status not null default 'open',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists calibration_session_review_cycle_id_idx
  on public.calibration_session (review_cycle_id);

drop trigger if exists calibration_session_set_updated_at on public.calibration_session;
create trigger calibration_session_set_updated_at
  before update on public.calibration_session
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- calibration_band — a configurable-size matrix, NOT a fixed 3x3.
--
-- A session owns an arbitrary number of bands; no band count is hardcoded
-- anywhere in this phase. Matching is half-open [min_score, max_score) and
-- lives in the shared helper in 0014 — the same rule for both
-- add_plan_to_calibration_session and adjust_calibration_participant.
--
-- Because the range is half-open, the TOP band must be configured to extend
-- ABOVE the plan's overall_rating_scale_max (e.g. [4.5, 5.001) on a 5-point
-- scale), otherwise a perfect 5.000 matches nothing and 0014 raises 23514.
-- That raise is intentional: a band gap is a facilitator config error worth
-- surfacing loudly, not silently leaving band_id null.
-- ---------------------------------------------------------------------------

create table if not exists public.calibration_band (
  id                     uuid primary key default gen_random_uuid(),
  calibration_session_id uuid not null references public.calibration_session (id) on delete cascade,
  label                  text not null,
  min_score              numeric(6,3) not null,
  max_score              numeric(6,3) not null,
  sort_order             integer not null default 0,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  -- strict: a zero-width band would be unmatchable under half-open matching
  constraint calibration_band_range_ordered check (max_score > min_score),
  constraint calibration_band_min_non_negative check (min_score >= 0),
  constraint calibration_band_unique_sort_order
    unique (calibration_session_id, sort_order)
);

create index if not exists calibration_band_session_id_idx
  on public.calibration_band (calibration_session_id);
-- supports the [min_score, max_score) lookup in 0014's matching helper
create index if not exists calibration_band_session_range_idx
  on public.calibration_band (calibration_session_id, min_score, max_score);

drop trigger if exists calibration_band_set_updated_at on public.calibration_band;
create trigger calibration_band_set_updated_at
  before update on public.calibration_band
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- calibration_participant — one plan's place in one session.
--
-- original_score: the pre-calibration snapshot, taken from the plan's MANAGER
--   goal_plan_rating.overall_score (self-assessments are never calibration
--   inputs). Immutable once set — see the trigger below.
-- calibrated_score: the only adjustable field, and only via
--   adjust_calibration_participant while the session is still 'open'.
-- band_id: recomputed whenever calibrated_score changes. Nullable at the
--   column level only because the FK target may be deleted; the functions in
--   0014 never leave it null on a successful call.
--
-- unique (calibration_session_id, employee_goal_plan_id): a plan can only be
-- calibrated once per session.
-- ---------------------------------------------------------------------------

create table if not exists public.calibration_participant (
  id                     uuid primary key default gen_random_uuid(),
  calibration_session_id uuid not null references public.calibration_session (id) on delete cascade,
  employee_goal_plan_id  uuid not null references public.employee_goal_plan (id) on delete cascade,
  original_score         numeric(6,3) not null,
  calibrated_score       numeric(6,3),
  band_id                uuid references public.calibration_band (id) on delete set null,
  facilitator_note       text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint calibration_participant_unique_per_session
    unique (calibration_session_id, employee_goal_plan_id),
  constraint calibration_participant_original_score_non_negative
    check (original_score >= 0),
  constraint calibration_participant_calibrated_score_non_negative
    check (calibrated_score is null or calibrated_score >= 0)
);

create index if not exists calibration_participant_session_id_idx
  on public.calibration_participant (calibration_session_id);
create index if not exists calibration_participant_plan_id_idx
  on public.calibration_participant (employee_goal_plan_id);
create index if not exists calibration_participant_band_id_idx
  on public.calibration_participant (band_id);

drop trigger if exists calibration_participant_set_updated_at on public.calibration_participant;
create trigger calibration_participant_set_updated_at
  before update on public.calibration_participant
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- original_score immutability.
--
-- Schema-level guard, so it holds no matter who the caller is or which path
-- reaches the row — including HR admins and the SECURITY DEFINER functions in
-- 0014, which run as the definer and would otherwise bypass every RLS policy.
-- HR is precisely who would be tempted to overwrite the pre-calibration
-- snapshot, and that snapshot is half of the audit trail, so the guard is
-- deliberately absolute rather than role-conditional.
--
-- Comparison is `is distinct from`, so a no-op UPDATE that re-writes the same
-- value passes (an UPDATE touching only facilitator_note or calibrated_score
-- carries the unchanged original_score in NEW and must not trip the guard).
-- ---------------------------------------------------------------------------

create or replace function public.enforce_original_score_immutable()
returns trigger
language plpgsql
as $$
begin
  if new.original_score is distinct from old.original_score then
    raise exception
      'original_score is immutable once set (participant %): it is the pre-calibration snapshot; adjust calibrated_score instead',
      old.id
      using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists calibration_participant_original_score_immutable
  on public.calibration_participant;
create trigger calibration_participant_original_score_immutable
  before update on public.calibration_participant
  for each row execute function public.enforce_original_score_immutable();
