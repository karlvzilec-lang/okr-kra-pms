-- 0005_participant_role_matrix.sql
-- Adds 'matrix_manager' to the existing participant_role enum.
--
-- This file deliberately contains NOTHING ELSE. PostgreSQL forbids using a
-- newly added enum value in the same transaction that added it, so any table,
-- trigger, policy or seed row referencing 'matrix_manager' must land in a
-- later migration (0006+). Keeping this file bare is what guarantees that.
--
-- Idempotent: IF NOT EXISTS makes re-running a no-op.

alter type public.participant_role add value if not exists 'matrix_manager';
