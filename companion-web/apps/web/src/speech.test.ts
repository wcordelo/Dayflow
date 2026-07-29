import { describe, expect, it } from "vitest";
import { speechSupported } from "./speech";

describe("speech helpers", () => {
  it("reports support without throwing", () => {
    expect(typeof speechSupported()).toBe("boolean");
  });
});
