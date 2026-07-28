import { describe, expect, it } from "vitest";
import {
  logicalDayKey,
  logicalDayStartUnix,
  nextDayBoundaryUnix,
} from "../src/dayBoundary/index.js";

describe("dayBoundary 4AM", () => {
  // Fixed offset: UTC-5 (e.g. US Eastern standard) → offset minutes east = -300
  const eastern = { timezoneOffsetMinutes: -300 };

  it("assigns pre-4AM timestamps to previous calendar day", () => {
    // 2024-06-15 03:30 EDT = 2024-06-15 07:30 UTC
    const unix = Date.UTC(2024, 5, 15, 7, 30, 0) / 1000;
    expect(logicalDayKey(unix, eastern)).toBe("2024-06-14");

    // 2024-06-15 04:00 EDT = 2024-06-15 09:00 UTC
    const atBoundary = Date.UTC(2024, 5, 15, 9, 0, 0) / 1000;
    expect(logicalDayKey(atBoundary, eastern)).toBe("2024-06-15");
  });

  it("logicalDayStartUnix and nextDayBoundaryUnix align to 4AM", () => {
    const mid = Date.UTC(2024, 5, 15, 18, 0, 0) / 1000; // 13:00 EDT
    const start = logicalDayStartUnix(mid, eastern);
    expect(logicalDayKey(start, eastern)).toBe("2024-06-15");
    expect(logicalDayKey(start - 1, eastern)).toBe("2024-06-14");

    const next = nextDayBoundaryUnix(mid, eastern);
    expect(logicalDayKey(next, eastern)).toBe("2024-06-16");
    expect(next).toBeGreaterThan(mid);
  });

  it("host-local rollback does not mix UTC Date.UTC with local Y/M/D", () => {
    // Construct a local pre-boundary instant via Date components.
    const localPre = new Date(2024, 5, 15, 3, 30, 0, 0);
    const unix = Math.floor(localPre.getTime() / 1000);
    expect(logicalDayKey(unix)).toBe("2024-06-14");
  });
});
