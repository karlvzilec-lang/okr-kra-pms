"use client";

import { useCallback, useEffect, useRef, useState } from "react";

/**
 * Pointer-event drag controller for the calibration board.
 *
 * Replaces HTML5 drag-and-drop, which never fires on touch devices. One code
 * path now serves mouse, touch and pen: drag starts from a dedicated handle
 * marked `touch-action: none`, so the browser hands us the touch stream
 * declaratively and never steals it for native scrolling. Everything else on
 * the card and board stays natively scrollable.
 *
 * Drop targets are found with `document.elementFromPoint()` on every animation
 * frame rather than cached rects: the board scrolls horizontally *during* a
 * drag (including our own edge auto-scroll), which would invalidate any cache.
 * The floating preview is `pointer-events: none`, so it is invisible to the
 * hit test.
 */

/** Displacement, in px, that separates a deliberate pickup from finger jitter. */
const ENGAGE_THRESHOLD_PX = 6;
/** Distance from a scroller edge at which auto-scroll kicks in. */
const EDGE_ZONE_PX = 56;
/** Peak auto-scroll speed, px per frame, at the very edge. */
const EDGE_MAX_SPEED_PX = 18;

/** Marks a droppable column. Value is the column id. */
export const DROP_TARGET_ATTR = "data-drop-column-id";
/** Marks the horizontally scrolling board viewport. */
export const SCROLLER_ATTR = "data-board-scroller";

/** What ended the last drag. Consumed by the board's aria-live status line. */
export type DragOutcome =
  | { kind: "dropped"; participantId: string; label: string; columnId: string }
  | { kind: "missed"; participantId: string; label: string }
  | { kind: "cancelled"; participantId: string; label: string };

export type PointerDragState = {
  /** Participant currently being dragged, or null when idle. */
  draggingId: string | null;
  /** Column id under the pointer, or null. */
  dragOverColumn: string | null;
  /** Viewport coords for the floating preview, or null when not engaged. */
  preview: { x: number; y: number; label: string } | null;
  /**
   * How the most recent engaged drag ended. Set as `preview` is cleared, so the
   * status line still has something to announce after the preview is gone.
   * Reset to null when the next drag engages.
   */
  lastOutcome: DragOutcome | null;
};

type Options = {
  /** Called once, on release, with the participant and the column under the pointer. */
  onDrop: (participantId: string, columnId: string | null) => void;
  /** When true, drags never engage. */
  disabled: boolean;
};

export function usePointerDrag({ onDrop, disabled }: Options) {
  const [state, setState] = useState<PointerDragState>({
    draggingId: null,
    dragOverColumn: null,
    preview: null,
    lastOutcome: null,
  });

  // All live drag bookkeeping lives in a ref so the window listeners, which are
  // registered once, never read stale state.
  const drag = useRef<{
    pointerId: number;
    participantId: string;
    label: string;
    startX: number;
    startY: number;
    x: number;
    y: number;
    engaged: boolean;
    column: string | null;
    /** Element holding the pointer capture, so we can release it on cleanup. */
    captureTarget: Element | null;
  } | null>(null);

  const frame = useRef<number | null>(null);
  const onDropRef = useRef(onDrop);
  const disabledRef = useRef(disabled);

  useEffect(() => {
    onDropRef.current = onDrop;
  }, [onDrop]);
  useEffect(() => {
    disabledRef.current = disabled;
  }, [disabled]);

  const stopFrameLoop = useCallback(() => {
    if (frame.current !== null) {
      cancelAnimationFrame(frame.current);
      frame.current = null;
    }
  }, []);

  const reset = useCallback(() => {
    const current = drag.current;
    if (current?.captureTarget) {
      // Releasing is best-effort: the browser may already have dropped the
      // capture (that is exactly the lostpointercapture path).
      try {
        (current.captureTarget as HTMLElement).releasePointerCapture?.(current.pointerId);
      } catch {
        /* capture already gone */
      }
    }
    drag.current = null;
    stopFrameLoop();
    setState((prev) => ({
      draggingId: null,
      dragOverColumn: null,
      preview: null,
      lastOutcome: prev.lastOutcome,
    }));
  }, [stopFrameLoop]);

  /** Column id under (x, y), or null. The preview is pointer-events:none. */
  const columnAt = useCallback((x: number, y: number): string | null => {
    const el = document.elementFromPoint(x, y);
    const target = el?.closest<HTMLElement>(`[${DROP_TARGET_ATTR}]`);
    return target?.getAttribute(DROP_TARGET_ATTR) ?? null;
  }, []);

  /** Scroll the board when the pointer sits near a horizontal edge. */
  const autoScroll = useCallback((x: number, y: number) => {
    const el = document.elementFromPoint(x, y);
    const scroller =
      el?.closest<HTMLElement>(`[${SCROLLER_ATTR}]`) ??
      document.querySelector<HTMLElement>(`[${SCROLLER_ATTR}]`);
    if (!scroller) return;

    const rect = scroller.getBoundingClientRect();
    // Only steer when the pointer is vertically within the board.
    if (y < rect.top || y > rect.bottom) return;

    if (x < rect.left + EDGE_ZONE_PX) {
      const intensity = Math.min(1, (rect.left + EDGE_ZONE_PX - x) / EDGE_ZONE_PX);
      scroller.scrollLeft -= EDGE_MAX_SPEED_PX * intensity;
    } else if (x > rect.right - EDGE_ZONE_PX) {
      const intensity = Math.min(1, (x - (rect.right - EDGE_ZONE_PX)) / EDGE_ZONE_PX);
      scroller.scrollLeft += EDGE_MAX_SPEED_PX * intensity;
    }
  }, []);

  useEffect(() => {
    // One continuous loop while engaged: it both re-hit-tests (the board moves
    // under a still finger during auto-scroll) and drives the auto-scroll.
    function tick() {
      const current = drag.current;
      if (!current || !current.engaged) {
        frame.current = null;
        return;
      }

      autoScroll(current.x, current.y);
      const column = columnAt(current.x, current.y);
      if (column !== current.column) {
        current.column = column;
        setState((prev) => ({ ...prev, dragOverColumn: column }));
      }
      setState((prev) =>
        prev.preview && prev.preview.x === current.x && prev.preview.y === current.y
          ? prev
          : { ...prev, preview: { x: current.x, y: current.y, label: current.label } },
      );

      frame.current = requestAnimationFrame(tick);
    }

    function handleMove(event: PointerEvent) {
      const current = drag.current;
      if (!current || event.pointerId !== current.pointerId) return;

      current.x = event.clientX;
      current.y = event.clientY;

      if (!current.engaged) {
        const moved = Math.hypot(event.clientX - current.startX, event.clientY - current.startY);
        if (moved < ENGAGE_THRESHOLD_PX) return;

        current.engaged = true;
        navigator.vibrate?.(10);
        setState({
          draggingId: current.participantId,
          dragOverColumn: null,
          preview: { x: current.x, y: current.y, label: current.label },
          lastOutcome: null,
        });
        if (frame.current === null) frame.current = requestAnimationFrame(tick);
      }

      // Engaged: this gesture is a drag, not a scroll or a text selection.
      if (event.cancelable) event.preventDefault();
    }

    function handleUp(event: PointerEvent) {
      const current = drag.current;
      if (!current || event.pointerId !== current.pointerId) return;

      const engaged = current.engaged;
      const participantId = current.participantId;
      const label = current.label;
      const column = engaged ? columnAt(event.clientX, event.clientY) : null;

      reset();
      if (!engaged) return;
      setState((prev) => ({
        ...prev,
        lastOutcome: column
          ? { kind: "dropped", participantId, label, columnId: column }
          : { kind: "missed", participantId, label },
      }));
      onDropRef.current(participantId, column);
    }

    function handleCancel(event: PointerEvent) {
      const current = drag.current;
      if (!current || event.pointerId !== current.pointerId) return;
      const { engaged, label, participantId } = current;
      reset();
      if (engaged) {
        setState((prev) => ({
          ...prev,
          lastOutcome: { kind: "cancelled", participantId, label },
        }));
      }
    }

    // Defensive path: a pointer that is released outside the viewport, or whose
    // capture the browser revokes for any other reason, may never deliver
    // pointerup/pointercancel. Without this the drag would stay engaged with the
    // rAF loop spinning, and the next unrelated pointerup could drop the card.
    function handleLostCapture(event: PointerEvent) {
      const current = drag.current;
      if (!current || event.pointerId !== current.pointerId) return;
      const { engaged, label, participantId } = current;
      reset();
      if (engaged) {
        setState((prev) => ({
          ...prev,
          lastOutcome: { kind: "cancelled", participantId, label },
        }));
      }
    }

    window.addEventListener("pointermove", handleMove, { passive: false });
    window.addEventListener("pointerup", handleUp);
    window.addEventListener("pointercancel", handleCancel);
    window.addEventListener("lostpointercapture", handleLostCapture);

    return () => {
      window.removeEventListener("pointermove", handleMove);
      window.removeEventListener("pointerup", handleUp);
      window.removeEventListener("pointercancel", handleCancel);
      window.removeEventListener("lostpointercapture", handleLostCapture);
      // StrictMode remounts and real unmounts both land here: drop the frame
      // loop so no orphaned rAF keeps scrolling the board.
      stopFrameLoop();
      drag.current = null;
    };
  }, [autoScroll, columnAt, reset, stopFrameLoop]);

  /**
   * Clear a stale `lastOutcome` once its consequence has been handled elsewhere
   * (e.g. the Adjust modal it opened was saved). Without this, a save that
   * lands the participant back in the column it was dropped on re-triggers the
   * "already in <band>, nothing changed" no-op text on the next render, even
   * though the save just changed the score.
   */
  const clearOutcome = useCallback(() => {
    setState((prev) => (prev.lastOutcome ? { ...prev, lastOutcome: null } : prev));
  }, []);

  /** Attach to a drag handle's `onPointerDown`. */
  const startDrag = useCallback(
    (event: React.PointerEvent, participantId: string, label: string) => {
      if (disabledRef.current) return;
      // Mouse: primary button only. Touch/pen report button 0 as well.
      if (event.pointerType === "mouse" && event.button !== 0) return;
      if (drag.current) return;

      // Capture on the handle itself. Pointer events keep bubbling to window, so
      // the listeners above are unaffected, but the browser now guarantees the
      // stream stays ours and fires lostpointercapture if it ever does not.
      const captureTarget = event.currentTarget as Element | null;
      try {
        (captureTarget as HTMLElement | null)?.setPointerCapture?.(event.pointerId);
      } catch {
        /* non-fatal: fall back to plain window listeners */
      }

      drag.current = {
        pointerId: event.pointerId,
        participantId,
        label,
        startX: event.clientX,
        startY: event.clientY,
        x: event.clientX,
        y: event.clientY,
        engaged: false,
        column: null,
        captureTarget,
      };
    },
    [],
  );

  return { ...state, startDrag, clearOutcome };
}
