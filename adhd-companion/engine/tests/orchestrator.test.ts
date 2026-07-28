import { describe, expect, it } from "vitest";
import {
  NudgeOrchestrator,
  createInitialState,
  reduce,
} from "../src/orchestrator/index.js";
import { TIMERS, mutableClock } from "../src/types/index.js";

describe("orchestrator state machine", () => {
  it("idle → L1 on drift + event anchor when guards pass", () => {
    const clock = mutableClock(1_700_000_000);
    const orch = new NudgeOrchestrator(clock);
    orch.dispatch({ type: "drift_detected", confidence: "high" });
    expect(orch.getState().level).toBe("idle");
    expect(orch.getState().pendingDrift).toBe(true);
    orch.dispatch({ type: "event_anchor", anchor: "app_switch" });
    expect(orch.getState().level).toBe("L1");
    expect(orch.getState().escalateAfterUnix).toBe(
      1_700_000_000 + TIMERS.L1_IGNORE_SECONDS,
    );
  });

  it("repeated drift_detected preserves pendingDriftSinceUnix", () => {
    const clock = mutableClock(1_700_000_000);
    let state = createInitialState();
    state = reduce(state, { type: "drift_detected", confidence: "medium" }, clock);
    expect(state.pendingDriftSinceUnix).toBe(1_700_000_000);
    clock.advance(30);
    state = reduce(state, { type: "drift_detected", confidence: "high" }, clock);
    expect(state.pendingDrift).toBe(true);
    expect(state.pendingDriftSinceUnix).toBe(1_700_000_000);
    expect(state.pendingConfidence).toBe("high");
  });

  it("never fires from low-confidence drift", () => {
    const clock = mutableClock(1_700_000_000);
    let state = createInitialState();
    state = reduce(state, { type: "drift_detected", confidence: "low" }, clock);
    state = reduce(
      state,
      { type: "event_anchor", anchor: "window_focus" },
      clock,
    );
    expect(state.level).toBe("idle");
    expect(state.pendingDrift).toBe(false);
  });

  it("low-confidence drift preserves a stronger pending wait", () => {
    const clock = mutableClock(1_700_000_000);
    let state = createInitialState();
    state = reduce(state, { type: "drift_detected", confidence: "high" }, clock);
    expect(state.pendingDrift).toBe(true);
    state = reduce(state, { type: "drift_detected", confidence: "low" }, clock);
    expect(state.pendingDrift).toBe(true);
    expect(state.pendingConfidence).toBe("high");
    expect(state.pendingDriftSinceUnix).toBe(1_700_000_000);
    state = reduce(state, { type: "event_anchor", anchor: "app_switch" }, clock);
    expect(state.level).toBe("L1");
  });

  it("aligned clears pending drift while idle (mirrors Rust)", () => {
    const clock = mutableClock(1_700_000_000);
    let state = createInitialState();
    state = reduce(state, { type: "drift_detected", confidence: "high" }, clock);
    expect(state.pendingDrift).toBe(true);
    state = reduce(state, { type: "aligned" }, clock);
    expect(state.level).toBe("idle");
    expect(state.pendingDrift).toBe(false);
    expect(state.pendingDriftSinceUnix).toBeNull();
    expect(state.pendingConfidence).toBeNull();
  });

  it("aligned is a no-op once already elevated", () => {
    const clock = mutableClock(1_700_000_000);
    let state = createInitialState();
    state = reduce(state, { type: "drift_detected", confidence: "high" }, clock);
    state = reduce(state, { type: "event_anchor", anchor: "app_switch" }, clock);
    expect(state.level).toBe("L1");
    state = reduce(state, { type: "aligned" }, clock);
    expect(state.level).toBe("L1");
  });

  it("L1 ignore ≥8m → L2; L2 ignore ≥10m → L3", () => {
    const clock = mutableClock(1_000);
    let state = createInitialState();
    state = reduce(state, { type: "drift_detected", confidence: "medium" }, clock);
    state = reduce(state, { type: "event_anchor", anchor: "idle_return" }, clock);
    expect(state.level).toBe("L1");

    clock.advance(TIMERS.L1_IGNORE_SECONDS);
    state = reduce(state, { type: "tick" }, clock);
    expect(state.level).toBe("L2");
    expect(state.escalateAfterUnix).toBe(clock.nowUnix() + TIMERS.L2_IGNORE_SECONDS);

    clock.advance(TIMERS.L2_IGNORE_SECONDS);
    state = reduce(state, { type: "tick" }, clock);
    expect(state.level).toBe("L3");
  });

  it("ignore escalation is not cancelled by spacing", () => {
    const clock = mutableClock(1_000);
    let state = createInitialState();
    state = reduce(state, { type: "drift_detected", confidence: "high" }, clock);
    state = reduce(state, { type: "event_anchor", anchor: "app_switch" }, clock);
    expect(state.level).toBe("L1");
    state = {
      ...state,
      guards: {
        ...state.guards,
        minutesSinceLastNudge: 8,
        minMinutesBetweenNudges: 15,
      },
    };
    clock.advance(TIMERS.L1_IGNORE_SECONDS);
    state = reduce(state, { type: "tick" }, clock);
    expect(state.level).toBe("L2");
  });

  it("doing_it applies 45m cooldown; snooze applies 20m", () => {
    const clock = mutableClock(5_000);
    let state = createInitialState();
    state = reduce(state, { type: "drift_detected", confidence: "high" }, clock);
    state = reduce(state, { type: "event_anchor", anchor: "app_switch" }, clock);

    state = reduce(state, { type: "acknowledge", reason: "doing_it" }, clock);
    expect(state.level).toBe("idle");
    expect(state.cooldownUntilUnix).toBe(5_000 + TIMERS.COOLDOWN_DOING_IT_SECONDS);

    clock.advance(TIMERS.COOLDOWN_DOING_IT_SECONDS);
    state = reduce(state, { type: "tick" }, clock);
    expect(state.cooldownUntilUnix).toBeNull();

    state = reduce(state, { type: "drift_detected", confidence: "high" }, clock);
    state = reduce(state, { type: "event_anchor", anchor: "app_switch" }, clock);
    state = reduce(state, { type: "acknowledge", reason: "snooze" }, clock);
    expect(state.cooldownUntilUnix).toBe(
      clock.nowUnix() + TIMERS.COOLDOWN_SNOOZE_SECONDS,
    );
  });

  it("pause acknowledge preserves pre-set cooldown deadline", () => {
    const clock = mutableClock(5_000);
    let state = createInitialState();
    state = reduce(state, { type: "drift_detected", confidence: "high" }, clock);
    state = reduce(state, { type: "event_anchor", anchor: "app_switch" }, clock);
    const until = 5_000 + 30 * 60;
    state = reduce(
      state,
      { type: "set_guards", guards: { paused: true, cooldownUntilUnix: until } },
      clock,
    );
    state = reduce(state, { type: "acknowledge", reason: "pause" }, clock);
    expect(state.level).toBe("idle");
    expect(state.cooldownUntilUnix).toBe(until);
    expect(state.guards.cooldownUntilUnix).toBe(until);
    expect(state.cooldownKind).toBe("pause");
  });

  it("wake does not leap L1→L3; cancels if guards fail", () => {
    const clock = mutableClock(10_000);
    let state = createInitialState();
    state = reduce(state, { type: "drift_detected", confidence: "high" }, clock);
    state = reduce(state, { type: "event_anchor", anchor: "app_switch" }, clock);
    expect(state.level).toBe("L1");

    // Lid closed longer than L1+L2 windows — only one escalate step per tick/wake
    clock.advance(TIMERS.L1_IGNORE_SECONDS + TIMERS.L2_IGNORE_SECONDS + 60);
    state = reduce(state, { type: "wake" }, clock);
    expect(state.level).toBe("L2"); // one step, not L3

    state = reduce(
      state,
      { type: "set_guards", guards: { inMeeting: true } },
      clock,
    );
    state = reduce(state, { type: "wake" }, clock);
    expect(state.level).toBe("idle");
    expect(state.lastTransition?.reason).toContain("wake_cancel");
  });

  it("L3 circuit breaker enters gentle mode after 2 presentations", () => {
    const clock = mutableClock(20_000);
    let state = createInitialState();

    // First L1→L2→L3
    state = reduce(state, { type: "drift_detected", confidence: "high" }, clock);
    state = reduce(state, { type: "event_anchor", anchor: "app_switch" }, clock);
    clock.advance(TIMERS.L1_IGNORE_SECONDS);
    state = reduce(state, { type: "tick" }, clock);
    clock.advance(TIMERS.L2_IGNORE_SECONDS);
    state = reduce(state, { type: "tick" }, clock);
    expect(state.level).toBe("L3");
    expect(state.l3PresentationsToday).toBe(1);

    state = reduce(state, { type: "acknowledge", reason: "resolve" }, clock);
    clock.advance(TIMERS.COOLDOWN_SNOOZE_SECONDS); // ensure spacing ok
    state = reduce(
      state,
      {
        type: "set_guards",
        guards: { minutesSinceLastNudge: 60, cooldownUntilUnix: null },
      },
      clock,
    );
    state = {
      ...state,
      cooldownUntilUnix: null,
      cooldownKind: null,
    };

    // Second escalation to L3 → gentle
    state = reduce(state, { type: "drift_detected", confidence: "high" }, clock);
    state = reduce(state, { type: "event_anchor", anchor: "app_switch" }, clock);
    clock.advance(TIMERS.L1_IGNORE_SECONDS);
    state = reduce(state, { type: "tick" }, clock);
    clock.advance(TIMERS.L2_IGNORE_SECONDS);
    state = reduce(state, { type: "tick" }, clock);
    expect(state.level).toBe("L3");
    expect(state.gentleMode).toBe(true);
    expect(state.l3PresentationsToday).toBe(2);
  });
});
