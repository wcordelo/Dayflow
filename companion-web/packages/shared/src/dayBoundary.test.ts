import { describe, expect, it } from "vitest";
import { logicalDayKey, previousLogicalDayKey } from "./dayBoundary.js";
import { FORBIDDEN_PHRASES } from "./doctrine.js";

describe("dayBoundary", () => {
  it("formats YYYY-MM-DD", () => {
    const key = logicalDayKey(new Date("2026-07-29T15:00:00"));
    expect(key).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it("previous day is before today", () => {
    const now = new Date("2026-07-29T15:00:00");
    expect(previousLogicalDayKey(now) < logicalDayKey(now)).toBe(true);
  });
});

describe("doctrine", () => {
  it("forbids self-like lists", () => {
    expect(FORBIDDEN_PHRASES.some((p) => p.includes("like about yourself"))).toBe(true);
  });
});
