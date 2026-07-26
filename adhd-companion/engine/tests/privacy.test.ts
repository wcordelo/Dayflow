import { describe, expect, it } from "vitest";
import {
  defaultPrivacyRules,
  evaluatePrivacy,
  isIncognitoWindow,
  shouldSuppressL3ForFocus,
} from "../src/privacy/index.js";

describe("privacy suite", () => {
  const rules = defaultPrivacyRules({
    appBlocklist: ["com.apple.MobileSMS", "com.1password.1password"],
    titleBlocklist: ["password reset", "bank statement"],
  });

  it("redacts app blocklist and title blocklist", () => {
    expect(
      evaluatePrivacy(
        { frontmostBundleId: "com.1password.1password", windowTitle: "Vault" },
        rules,
      ),
    ).toEqual({ action: "redact", reason: "app_blocklist" });

    expect(
      evaluatePrivacy(
        {
          frontmostBundleId: "com.apple.mail",
          windowTitle: "Fwd: Bank statement March",
        },
        rules,
      ),
    ).toEqual({ action: "redact", reason: "title_blocklist" });
  });

  it("skips incognito browser windows", () => {
    expect(
      isIncognitoWindow(
        "com.google.Chrome",
        "Notion – Incognito",
        rules,
      ),
    ).toBe(true);

    expect(
      evaluatePrivacy(
        {
          frontmostBundleId: "com.google.Chrome",
          windowTitle: "Search - Incognito",
        },
        rules,
      ),
    ).toEqual({ action: "skip", reason: "incognito" });
  });

  it("pauses capture on DRM focus and suppresses L3", () => {
    expect(
      evaluatePrivacy(
        { frontmostBundleId: "com.netflix.Netflix", windowTitle: "Netflix" },
        rules,
      ),
    ).toEqual({ action: "pause_capture", reason: "drm" });

    expect(shouldSuppressL3ForFocus("com.netflix.Netflix", rules)).toBe(true);
    expect(shouldSuppressL3ForFocus("com.apple.Safari", rules)).toBe(false);
  });
});
