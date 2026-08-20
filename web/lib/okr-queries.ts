// Server-side loaders for the review-cycle board and the OKR authoring pages.
//
// These go through PostgREST rather than a new RPC, matching
// lib/goal-plan-queries.ts: everything they read is already reachable under
// the existing select policies, and the nested selects keep each page's shape
// to one round trip.
//
// Nothing here computes a score or a current_value. Those are stored columns
// maintained by database triggers (recompute_key_result_score,
// apply_check_in_to_key_result); the UI only ever reads them back.

import type { SupabaseClient } from "@supabase/supabase-js";
import { rangeFor, refetchIfClamped, type Paginated } from "@/lib/pagination";
import type {
  CheckIn,
  KeyResult,
  ObjectiveWithCycle,
  ReviewCycle,
  ReviewCycleStatus,
} from "@/lib/types";

const CYCLE_COLUMNS = "id, name, start_date, end_date, status, created_at, updated_at";

const KEY_RESULT_COLUMNS =
  "id, title, metric_unit, start_value, target_value, current_value, score, " +
  "score_override, created_at, updated_at";

function firstOf<T>(value: T | T[] | null): T | null {
  if (!value) return null;
  return Array.isArray(value) ? (value[0] ?? null) : value;
}

/** effective_score is coalesce(score_override, score) — the DB's own rule. */
function withEffectiveScore(raw: Omit<KeyResult, "effective_score">): KeyResult {
  return { ...raw, effective_score: raw.score_override ?? raw.score };
}

/**
 * Every cycle visible to the caller, newest first. HR sees all of them via
 * review_cycle_hr_all; anyone else sees only the cycles they participate in.
 */
export async function loadReviewCycles(supabase: SupabaseClient): Promise<ReviewCycle[]> {
  const { data } = await supabase
    .from("review_cycle")
    .select(CYCLE_COLUMNS)
    .order("start_date", { ascending: false });

  return (data ?? []) as ReviewCycle[];
}

type RawObjectiveRow = {
  id: string;
  review_cycle_id: string;
  owner_id: string;
  title: string;
  description: string | null;
  status: "active" | "closed";
  created_at: string;
  updated_at: string;
  review_cycle:
    | { name: string; status: ReviewCycleStatus }
    | { name: string; status: ReviewCycleStatus }[]
    | null;
  key_result: { count: number }[] | null;
};

function shapeObjective(row: RawObjectiveRow): ObjectiveWithCycle {
  const cycle = firstOf(row.review_cycle);
  return {
    id: row.id,
    review_cycle_id: row.review_cycle_id,
    owner_id: row.owner_id,
    title: row.title,
    description: row.description,
    status: row.status,
    created_at: row.created_at,
    updated_at: row.updated_at,
    review_cycle_name: cycle?.name ?? null,
    review_cycle_status: cycle?.status ?? null,
    key_result_count: row.key_result?.[0]?.count ?? 0,
  };
}

const OWN_OBJECTIVE_SELECT =
  "id, review_cycle_id, owner_id, title, description, status, created_at, updated_at, " +
  "review_cycle(name, status), key_result(count)";

/**
 * One page of the signed-in user's own objectives, newest first.
 *
 * Scoped by owner_id for the same reason loadOwnObjectives is: can_read_objective
 * also exposes a manager's objectives upward, and this list means "mine", not
 * "everything I can see". The count is exact and rides the same request, so it
 * counts the owner-filtered set rather than every objective RLS would allow.
 *
 * `id` breaks ties on created_at. Objectives are usually authored one at a
 * time, but seeded or scripted rows land in a single transaction and share a
 * timestamp exactly, which is enough to make an untiebroken sort unstable
 * across two page requests.
 */
export async function loadOwnObjectivePage(
  supabase: SupabaseClient,
  userId: string,
  page: number,
): Promise<Paginated<ObjectiveWithCycle>> {
  const { from, to } = rangeFor(page);

  const { data, count } = await supabase
    .from("objective")
    .select(OWN_OBJECTIVE_SELECT, { count: "exact" })
    .eq("owner_id", userId)
    .order("created_at", { ascending: false })
    .order("id", { ascending: true })
    .range(from, to);

  const total = count ?? 0;
  const rows = ((data ?? []) as unknown as RawObjectiveRow[]).map(shapeObjective);

  return refetchIfClamped(rows, total, page, (target) =>
    loadOwnObjectivePage(supabase, userId, target),
  );
}

export type ObjectiveDetail = ObjectiveWithCycle & { key_results: KeyResult[] };

type RawObjectiveDetail = Omit<RawObjectiveRow, "key_result"> & {
  key_result: Omit<KeyResult, "effective_score">[] | null;
};

/** One objective with its key results, or null when RLS hides it. */
export async function loadObjectiveDetail(
  supabase: SupabaseClient,
  objectiveId: string,
): Promise<ObjectiveDetail | null> {
  const { data, error } = await supabase
    .from("objective")
    .select(
      "id, review_cycle_id, owner_id, title, description, status, created_at, updated_at, " +
        `review_cycle(name, status), key_result(${KEY_RESULT_COLUMNS})`,
    )
    .eq("id", objectiveId)
    .maybeSingle();

  if (error || !data) return null;

  const row = data as unknown as RawObjectiveDetail;
  const cycle = firstOf(row.review_cycle);

  return {
    id: row.id,
    review_cycle_id: row.review_cycle_id,
    owner_id: row.owner_id,
    title: row.title,
    description: row.description,
    status: row.status,
    created_at: row.created_at,
    updated_at: row.updated_at,
    review_cycle_name: cycle?.name ?? null,
    review_cycle_status: cycle?.status ?? null,
    key_result_count: (row.key_result ?? []).length,
    key_results: [...(row.key_result ?? [])]
      .map(withEffectiveScore)
      .sort((a, b) => a.created_at.localeCompare(b.created_at)),
  };
}

export type CheckInWithAuthor = CheckIn & { author_name: string | null };

type RawCheckInRow = CheckIn & {
  profiles: { full_name: string } | { full_name: string }[] | null;
};

/**
 * Check-in history for one objective's key results, most recent first. This is
 * the evidence trail behind every current_value on the page — the database
 * allows no UPDATE and no DELETE on check_in for anyone, HR included, so what
 * renders here is what actually happened.
 */
export async function loadCheckInsForKeyResults(
  supabase: SupabaseClient,
  keyResultIds: string[],
): Promise<CheckInWithAuthor[]> {
  if (keyResultIds.length === 0) return [];

  const { data } = await supabase
    .from("check_in")
    .select("id, key_result_id, checked_in_by, new_value, note, created_at, profiles(full_name)")
    .in("key_result_id", keyResultIds)
    .order("created_at", { ascending: false });

  return ((data ?? []) as unknown as RawCheckInRow[]).map((row) => ({
    id: row.id,
    key_result_id: row.key_result_id,
    checked_in_by: row.checked_in_by,
    new_value: row.new_value,
    note: row.note,
    created_at: row.created_at,
    author_name: firstOf(row.profiles)?.full_name ?? null,
  }));
}
