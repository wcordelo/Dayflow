/**
 * Pure TypeScript mirror of the Rust-resident nudge orchestrator (contract v2.2).
 * Injectable wall clock only — never escalate from Date.now() alone.
 */

import {
  TIMERS,
  type Clock,
  type Confidence,
  type EventAnchor,
  type NudgeLevel,
  type OrchestratorGuards,
  type ResolveReason,
} from "../types/index.js";
import { confidenceAtLeast } from "../monitor/index.js";

export { TIMERS };

export type OrchestratorEvent =
  | { type: "drift_detected"; confidence: Confidence }
  | { type: "event_anchor"; anchor: EventAnchor }
  | { type: "tick" } // re-check wall-clock deadlines / guards
  | { type: "wake" } // lid open / unlock — reload deadlines, re-run guards
  | { type: "l1_clicked" }
  | { type: "acknowledge"; reason: ResolveReason }
  | { type: "set_guards"; guards: Partial<OrchestratorGuards> }
  | { type: "l3_presented" }; // count circuit breaker

export interface NudgeTransition {
  from: NudgeLevel;
  to: NudgeLevel;
  atUnix: number;
  reason: string;
}

export interface OrchestratorState {
  level: NudgeLevel;
  /** When current level was entered (wall clock). */
  levelEnteredAtUnix: number | null;
  /** Wall-clock unix when ignore escalates to next level. */
  escalateAfterUnix: number | null;
  /** Drift seen but waiting for event anchor. */
  pendingDrift: boolean;
  pendingDriftSinceUnix: number | null;
  pendingConfidence: Confidence | null;
  cooldownUntilUnix: number | null;
  cooldownKind: "doing_it" | "snooze" | "pause" | "gentle" | null;
  consecutiveIgnores: number;
  l3PresentationsToday: number;
  gentleMode: boolean;
  lastTransition: NudgeTransition | null;
  guards: OrchestratorGuards;
}

export const DEFAULT_GUARDS: OrchestratorGuards = {
  companionEnabled: true,
  activePriorityCount: 1,
  quietHours: false,
  paused: false,
  overwhelm: false,
  inMeeting: false,
  dailyBudgetRemaining: 10,
  confidence: "medium",
  confidenceThreshold: "medium",
  cooldownUntilUnix: null,
  minutesSinceLastNudge: 60,
  minMinutesBetweenNudges: 15,
};

export function createInitialState(
  guards: Partial<OrchestratorGuards> = {},
): OrchestratorState {
  return {
    level: "idle",
    levelEnteredAtUnix: null,
    escalateAfterUnix: null,
    pendingDrift: false,
    pendingDriftSinceUnix: null,
    pendingConfidence: null,
    cooldownUntilUnix: null,
    cooldownKind: null,
    consecutiveIgnores: 0,
    l3PresentationsToday: 0,
    gentleMode: false,
    lastTransition: null,
    guards: { ...DEFAULT_GUARDS, ...guards },
  };
}

function mergeGuards(
  state: OrchestratorState,
  patch: Partial<OrchestratorGuards>,
): OrchestratorState {
  return {
    ...state,
    guards: { ...state.guards, ...patch },
  };
}

/**
 * Suppression precedence (highest wins): Pause/Overwhelm → Meeting → Quiet →
 * Budget → Cooldown/spacing → Low confidence.
 */
export function guardsBlockNudge(
  state: OrchestratorState,
  nowUnix: number,
): string | null {
  const g = state.guards;
  if (!g.companionEnabled) return "companion_disabled";
  if (g.overwhelm) return "overwhelm";
  if (g.paused) return "paused";
  if (g.inMeeting) return "meeting";
  if (g.quietHours) return "quiet_hours";
  if (g.dailyBudgetRemaining <= 0) return "budget_exhausted";
  if (g.activePriorityCount < 1) return "no_priorities";
  const cd = g.cooldownUntilUnix ?? state.cooldownUntilUnix;
  if (cd !== null && nowUnix < cd) return "cooldown";
  if (
    g.minutesSinceLastNudge !== null &&
    g.minutesSinceLastNudge < g.minMinutesBetweenNudges
  ) {
    return "spacing";
  }
  if (!confidenceAtLeast(g.confidence, g.confidenceThreshold)) {
    return "low_confidence";
  }
  if (state.gentleMode && state.level === "idle") {
    // Gentle mode: still allow L1 if explicitly not circuit-locked; block auto L3 path later
  }
  return null;
}

function transition(
  state: OrchestratorState,
  to: NudgeLevel,
  nowUnix: number,
  reason: string,
): OrchestratorState {
  const from = state.level;
  let escalateAfterUnix: number | null = null;
  if (to === "L1") {
    escalateAfterUnix = nowUnix + TIMERS.L1_IGNORE_SECONDS;
  } else if (to === "L2") {
    escalateAfterUnix = nowUnix + TIMERS.L2_IGNORE_SECONDS;
  } else if (to === "L3") {
    escalateAfterUnix = null;
  }

  let l3PresentationsToday = state.l3PresentationsToday;
  let gentleMode = state.gentleMode;
  if (to === "L3" && from !== "L3") {
    l3PresentationsToday += 1;
    if (l3PresentationsToday >= TIMERS.L3_CIRCUIT_BREAKER_MAX) {
      gentleMode = true;
    }
  }

  return {
    ...state,
    level: to,
    levelEnteredAtUnix: to === "idle" ? null : nowUnix,
    escalateAfterUnix,
    pendingDrift: false,
    pendingDriftSinceUnix: null,
    pendingConfidence: null,
    l3PresentationsToday,
    gentleMode,
    lastTransition: { from, to, atUnix: nowUnix, reason },
  };
}

function enterCooldown(
  state: OrchestratorState,
  nowUnix: number,
  reason: ResolveReason,
): OrchestratorState {
  let cooldownUntilUnix: number | null = null;
  let cooldownKind: OrchestratorState["cooldownKind"] = null;

  if (reason === "doing_it") {
    cooldownUntilUnix = nowUnix + TIMERS.COOLDOWN_DOING_IT_SECONDS;
    cooldownKind = "doing_it";
  } else if (reason === "snooze") {
    cooldownUntilUnix = nowUnix + TIMERS.COOLDOWN_SNOOZE_SECONDS;
    cooldownKind = "snooze";
  } else if (reason === "pause" || reason === "overwhelm") {
    cooldownUntilUnix = state.guards.cooldownUntilUnix;
    cooldownKind = "pause";
  } else if (reason === "circuit_breaker") {
    cooldownKind = "gentle";
  }

  const next = transition(state, "idle", nowUnix, reason);
  return {
    ...next,
    cooldownUntilUnix,
    cooldownKind,
    consecutiveIgnores:
      reason === "resolve" || reason === "doing_it" || reason === "snooze"
        ? 0
        : state.consecutiveIgnores,
    guards: {
      ...next.guards,
      cooldownUntilUnix,
    },
  };
}

function tryFireL1(
  state: OrchestratorState,
  nowUnix: number,
  reason: string,
): OrchestratorState {
  const block = guardsBlockNudge(state, nowUnix);
  if (block) {
    return {
      ...state,
      pendingDrift: false,
      pendingDriftSinceUnix: null,
      pendingConfidence: null,
      lastTransition: {
        from: state.level,
        to: state.level,
        atUnix: nowUnix,
        reason: `blocked:${block}`,
      },
    };
  }
  // Start at L2 if many consecutive ignores (ignore-as-signal); K=3 provisional
  const startLevel: NudgeLevel =
    state.consecutiveIgnores >= 3 && !state.gentleMode ? "L2" : "L1";
  // Circuit breaker: never auto-present L3 as start; gentle mode stays L1-only path
  if (state.gentleMode && startLevel !== "L1") {
    return transition(state, "L1", nowUnix, `${reason}+gentle`);
  }
  return transition(state, startLevel, nowUnix, reason);
}

function maybeEscalate(
  state: OrchestratorState,
  nowUnix: number,
): OrchestratorState {
  if (state.level === "idle" || state.level === "L3") return state;
  if (state.escalateAfterUnix === null) return state;
  if (nowUnix < state.escalateAfterUnix) return state;

  const block = guardsBlockNudge(state, nowUnix);
  if (block) {
    // Do not leap levels after sleep — cancel escalation path back toward idle
    return {
      ...enterCooldown(state, nowUnix, "guards_failed"),
      lastTransition: {
        from: state.level,
        to: "idle",
        atUnix: nowUnix,
        reason: `escalate_cancelled:${block}`,
      },
    };
  }

  if (state.level === "L1") {
    return {
      ...transition(state, "L2", nowUnix, "ignore>=8m"),
      consecutiveIgnores: state.consecutiveIgnores + 1,
    };
  }
  if (state.level === "L2") {
    if (state.gentleMode) {
      // Circuit breaker: do not escalate to L3
      return enterCooldown(state, nowUnix, "circuit_breaker");
    }
    return {
      ...transition(state, "L3", nowUnix, "ignore>=10m"),
      consecutiveIgnores: state.consecutiveIgnores + 1,
    };
  }
  return state;
}

function maybeFirePending(
  state: OrchestratorState,
  nowUnix: number,
  via: string,
): OrchestratorState {
  if (!state.pendingDrift || state.level !== "idle") return state;
  if (state.pendingDriftSinceUnix === null) return state;

  const waited = nowUnix - state.pendingDriftSinceUnix;
  const capped = waited >= TIMERS.PENDING_ANCHOR_CAP_SECONDS;
  if (!capped && (via === "cap_only" || via === "pending_anchor_cap")) return state;

  const conf = state.pendingConfidence ?? state.guards.confidence;
  const withConf = mergeGuards(state, { confidence: conf });
  return tryFireL1(withConf, nowUnix, via);
}

/**
 * Apply one event to the orchestrator. Pure: returns new state.
 */
export function reduce(
  state: OrchestratorState,
  event: OrchestratorEvent,
  clock: Clock,
): OrchestratorState {
  const now = clock.nowUnix();

  switch (event.type) {
    case "set_guards":
      return mergeGuards(state, event.guards);

    case "drift_detected": {
      if (state.level !== "idle") return state;
      const withConf = mergeGuards(state, { confidence: event.confidence });
      if (event.confidence === "low") {
        return {
          ...withConf,
          lastTransition: {
            from: state.level,
            to: state.level,
            atUnix: now,
            reason: "drift_low_confidence_ignored",
          },
        };
      }
      // Wait for event anchor (caller may immediately send one)
      return {
        ...withConf,
        pendingDrift: true,
        pendingDriftSinceUnix: now,
        pendingConfidence: event.confidence,
      };
    }

    case "event_anchor": {
      if (state.level !== "idle") return state;
      if (!state.pendingDrift) return state;
      return maybeFirePending(state, now, `anchor:${event.anchor}`);
    }

    case "tick":
    case "wake": {
      // Clear expired cooldown
      let s = state;
      const cd = s.cooldownUntilUnix;
      if (cd !== null && now >= cd) {
        s = {
          ...s,
          cooldownUntilUnix: null,
          cooldownKind: null,
          guards: { ...s.guards, cooldownUntilUnix: null },
        };
      }
      // Pending drift past anchor cap → fire if still eligible
      if (s.pendingDrift && s.level === "idle") {
        s = maybeFirePending(s, now, "pending_anchor_cap");
      }
      // Escalate by wall clock (wake must not leap L1→L3 without intermediate)
      s = maybeEscalate(s, now);
      // On wake, if guards now fail while elevated, cancel
      if (event.type === "wake" && s.level !== "idle") {
        const block = guardsBlockNudge(s, now);
        if (block) {
          s = {
            ...enterCooldown(s, now, "guards_failed"),
            lastTransition: {
              from: state.level,
              to: "idle",
              atUnix: now,
              reason: `wake_cancel:${block}`,
            },
          };
        }
      }
      return s;
    }

    case "l1_clicked": {
      if (state.level !== "L1") return state;
      return transition(state, "L2", now, "l1_clicked");
    }

    case "acknowledge": {
      if (event.reason === "priorities_changed") {
        const next = transition(state, "idle", now, "priorities_changed");
        return {
          ...next,
          pendingDrift: false,
          cooldownUntilUnix: null,
          cooldownKind: null,
          consecutiveIgnores: 0,
        };
      }
      return enterCooldown(state, now, event.reason);
    }

    case "l3_presented": {
      // Explicit count hook if UI presents L3 without going through transition
      const l3PresentationsToday = state.l3PresentationsToday + 1;
      return {
        ...state,
        l3PresentationsToday,
        gentleMode:
          l3PresentationsToday >= TIMERS.L3_CIRCUIT_BREAKER_MAX
            ? true
            : state.gentleMode,
      };
    }

    default: {
      const _exhaustive: never = event;
      return _exhaustive;
    }
  }
}

export class NudgeOrchestrator {
  private state: OrchestratorState;
  private readonly clock: Clock;

  constructor(clock: Clock, guards?: Partial<OrchestratorGuards>) {
    this.clock = clock;
    this.state = createInitialState(guards);
  }

  getState(): OrchestratorState {
    return this.state;
  }

  dispatch(event: OrchestratorEvent): OrchestratorState {
    this.state = reduce(this.state, event, this.clock);
    return this.state;
  }
}
