import { describe, expect, it } from "vitest";
import { buildPushWakeBatch, parsePushRegistration } from "./relay";

describe("push wake contract", () => {
  it("keeps provider payloads content-free and field-bounded", () => {
    const row = {
      device_id: "ios-1",
      platform: "ios",
      token: "apns-token",
      sequence: 7,
      kind: "sync_available",
      // This simulates an accidental future row field. The builder must not
      // copy it into a provider payload.
      ciphertext: "must-not-leak",
    } as const;
    const batch = buildPushWakeBatch([row]);

    expect(batch).toEqual({
      schema_version: 1,
      wakes: [{
        device_id: "ios-1",
        platform: "ios",
        token: "apns-token",
        sequence: 7,
        kind: "sync_available",
      }],
    });
    expect(JSON.stringify(batch)).not.toContain("ciphertext");
    expect(JSON.stringify(batch)).not.toContain("journal");
    expect(JSON.stringify(batch)).not.toContain("capture");
  });

  it("rejects empty and control-bearing provider tokens", () => {
    expect(() => parsePushRegistration({ token: "" })).toThrow();
    expect(() => parsePushRegistration({ token: "token\u0001" })).toThrow();
    expect(parsePushRegistration({ token: "valid-token" })).toEqual({ token: "valid-token" });
  });
});
