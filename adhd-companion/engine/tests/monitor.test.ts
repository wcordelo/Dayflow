import { describe, expect, it } from "vitest";
import { evaluateAlignment } from "../src/monitor/index.js";
import type { Priority } from "../src/types/index.js";

const priorities: Priority[] = [
  { id: 1, text: "Write grant proposal", status: "active" },
];

describe("monitor evaluateAlignment", () => {
  it("never recommends nudge when confidence is low", () => {
    const result = evaluateAlignment({
      priorities,
      context: {
        frontmostBundleId: "com.spotify.client",
        windowTitle: "Discover Weekly",
        browserUrl: null,
        captureTrigger: null, // no anchor → low confidence drift path
        idleSeconds: 0,
      },
    });
    expect(result.confidence).toBe("low");
    expect(result.recommendNudge).toBe(false);
  });

  it("recommends nudge on strong drift with medium+ confidence", () => {
    const result = evaluateAlignment({
      priorities,
      context: {
        frontmostBundleId: "com.netflix.Netflix",
        windowTitle: "Netflix — Stranger Things",
        browserUrl: null,
        captureTrigger: "app_switch",
        idleSeconds: 5,
      },
    });
    expect(result.verdict).toBe("drift");
    expect(result.confidence).not.toBe("low");
    expect(result.recommendNudge).toBe(true);
  });

  it("returns aligned when priority tokens appear in title", () => {
    const result = evaluateAlignment({
      priorities,
      context: {
        frontmostBundleId: "com.google.Chrome",
        windowTitle: "Grant proposal outline — Docs",
        browserUrl: "https://docs.google.com/document/d/xyz",
        captureTrigger: "window_focus",
        idleSeconds: 2,
      },
    });
    expect(result.verdict).toBe("aligned");
    expect(result.recommendNudge).toBe(false);
  });

  it("unknown + no nudge when no active priorities", () => {
    const result = evaluateAlignment({
      priorities: [{ id: 1, text: "Done thing", status: "done" }],
      context: {
        frontmostBundleId: "com.netflix.Netflix",
        windowTitle: "Netflix",
        browserUrl: null,
        captureTrigger: "app_switch",
        idleSeconds: 0,
      },
    });
    expect(result.verdict).toBe("unknown");
    expect(result.confidence).toBe("low");
    expect(result.recommendNudge).toBe(false);
  });
});
