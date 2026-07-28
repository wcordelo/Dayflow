/** Shared domain types for the ADHD companion engine (contract v2.2). */

export type NudgeLevel = "idle" | "L1" | "L2" | "L3";

export type Confidence = "low" | "medium" | "high";

export type AlignmentVerdict = "aligned" | "drift" | "unknown";

export type EventAnchor = "app_switch" | "window_focus" | "idle_return";

export type CaptureTrigger =
  | EventAnchor
  | "idle_fallback"
  | "click"
  | "typing_pause"
  | "scroll_stop"
  | "visual_change";

export type ResolveReason =
  | "doing_it"
  | "snooze"
  | "priorities_changed"
  | "pause"
  | "overwhelm"
  | "resolve"
  | "budget_exhausted"
  | "guards_failed"
  | "circuit_breaker";

export type CooldownKind = "doing_it" | "snooze" | "pause" | "gentle";

export interface Clock {
  /** Wall-clock unix seconds (injectable; never call Date.now() inside SM without clock). */
  nowUnix(): number;
}

export interface SystemClock extends Clock {
  nowUnix(): number;
}

export function systemClock(): Clock {
  return {
    nowUnix(): number {
      return Math.floor(Date.now() / 1000);
    },
  };
}

export function fixedClock(unixSeconds: number): Clock {
  let t = unixSeconds;
  return {
    nowUnix(): number {
      return t;
    },
  };
}

export function mutableClock(startUnix: number): Clock & { advance(seconds: number): void; set(unix: number): void } {
  let t = startUnix;
  return {
    nowUnix(): number {
      return t;
    },
    advance(seconds: number): void {
      t += seconds;
    },
    set(unix: number): void {
      t = unix;
    },
  };
}

/** Orchestrator timing constants from SPEC / contract v2.2. */
export const TIMERS = {
  /** L1 ignore → escalate to L2 */
  L1_IGNORE_SECONDS: 8 * 60,
  /** L2 ignore → escalate to L3 */
  L2_IGNORE_SECONDS: 10 * 60,
  /** Cap waiting for event anchor while drift pending */
  PENDING_ANCHOR_CAP_SECONDS: 10 * 60,
  /** doing_it cooldown */
  COOLDOWN_DOING_IT_SECONDS: 45 * 60,
  /** snooze cooldown */
  COOLDOWN_SNOOZE_SECONDS: 20 * 60,
  /** L3 presentations per logical day before gentle mode */
  L3_CIRCUIT_BREAKER_MAX: 2,
} as const;

export interface Priority {
  id: number;
  text: string;
  status: "active" | "done" | "dropped" | "carried" | "deferred";
}

export interface OrchestratorGuards {
  companionEnabled: boolean;
  activePriorityCount: number;
  quietHours: boolean;
  paused: boolean;
  overwhelm: boolean;
  inMeeting: boolean;
  dailyBudgetRemaining: number;
  confidence: Confidence;
  /** Minimum confidence required to nudge (aggressiveness maps here). */
  confidenceThreshold: Confidence;
  cooldownUntilUnix: number | null;
  /** Minutes of new activity since last nudge; null = unknown / skip check. */
  minutesSinceLastNudge: number | null;
  minMinutesBetweenNudges: number;
}

export interface CaptureContext {
  frontmostBundleId: string | null;
  windowTitle: string | null;
  browserUrl: string | null;
  captureTrigger: CaptureTrigger | null;
  idleSeconds: number | null;
}
