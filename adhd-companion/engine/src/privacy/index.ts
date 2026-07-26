/**
 * Privacy suite helpers (contract v2.2 / M1 required).
 * Pure functions — no native capture. Native layer calls these before write/upload.
 */

export type RedactReason =
  | "app_blocklist"
  | "title_blocklist"
  | "incognito"
  | "drm"
  | "user_skip";

export type PrivacyDecision =
  | { action: "allow" }
  | { action: "redact"; reason: RedactReason }
  | { action: "skip"; reason: RedactReason }
  | { action: "pause_capture"; reason: "drm" };

export interface PrivacyRules {
  /** Bundle IDs that must never leave the machine (placeholder JPEG + redacted=1). */
  appBlocklist: string[];
  /** Case-insensitive substrings matched against window titles. */
  titleBlocklist: string[];
  /** Bundle IDs treated as browsers for incognito heuristics. */
  browserBundleIds: string[];
  /** Bundle IDs that imply DRM / streaming focus → pause capture. */
  drmBundleIds: string[];
  /** Title substrings that imply private/incognito window. */
  incognitoTitleMarkers: string[];
  /** Prefer skip vs redact for incognito (default skip). */
  incognitoMode?: "skip" | "redact";
}

export const DEFAULT_BROWSER_BUNDLES = [
  "com.apple.Safari",
  "com.google.Chrome",
  "com.brave.Browser",
  "company.thebrowser.Browser", // Arc
  "org.mozilla.firefox",
  "com.microsoft.edgemac",
] as const;

export const DEFAULT_DRM_BUNDLES = [
  "com.netflix.Netflix",
  "com.apple.TV",
  "com.disney.disneyplus",
  "com.hulu.plus",
  "com.amazon.aiv.AIVApp",
  "tv.twitch.desktop",
  "com.spotify.client", // audio/video DRM-ish; pause escalation over playback focus
] as const;

export const DEFAULT_INCOGNITO_MARKERS = [
  "Incognito",
  "InPrivate",
  "Private Browsing",
  "Private Window",
] as const;

export function defaultPrivacyRules(
  overrides: Partial<PrivacyRules> = {},
): PrivacyRules {
  return {
    appBlocklist: overrides.appBlocklist ?? [],
    titleBlocklist: overrides.titleBlocklist ?? [],
    browserBundleIds: overrides.browserBundleIds ?? [...DEFAULT_BROWSER_BUNDLES],
    drmBundleIds: overrides.drmBundleIds ?? [...DEFAULT_DRM_BUNDLES],
    incognitoTitleMarkers:
      overrides.incognitoTitleMarkers ?? [...DEFAULT_INCOGNITO_MARKERS],
    incognitoMode: overrides.incognitoMode ?? "skip",
  };
}

function norm(s: string | null | undefined): string {
  return (s ?? "").trim().toLowerCase();
}

export function isAppBlocked(
  bundleId: string | null | undefined,
  rules: PrivacyRules,
): boolean {
  if (!bundleId) return false;
  const b = bundleId.trim().toLowerCase();
  return rules.appBlocklist.some((x) => x.trim().toLowerCase() === b);
}

export function isTitleBlocked(
  title: string | null | undefined,
  rules: PrivacyRules,
): boolean {
  const t = norm(title);
  if (!t) return false;
  return rules.titleBlocklist.some((rule) => {
    const r = norm(rule);
    return r.length > 0 && t.includes(r);
  });
}

export function isIncognitoWindow(
  bundleId: string | null | undefined,
  title: string | null | undefined,
  rules: PrivacyRules,
): boolean {
  if (!bundleId) return false;
  const b = bundleId.trim().toLowerCase();
  const isBrowser = rules.browserBundleIds.some(
    (x) => x.trim().toLowerCase() === b,
  );
  if (!isBrowser) return false;
  const t = title ?? "";
  return rules.incognitoTitleMarkers.some((marker) =>
    t.toLowerCase().includes(marker.toLowerCase()),
  );
}

export function isDrmFocus(
  bundleId: string | null | undefined,
  rules: PrivacyRules,
): boolean {
  if (!bundleId) return false;
  const b = bundleId.trim().toLowerCase();
  return rules.drmBundleIds.some((x) => x.trim().toLowerCase() === b);
}

/**
 * Evaluate privacy for a capture attempt.
 * Precedence: DRM pause → app blocklist → incognito → title blocklist → allow.
 */
export function evaluatePrivacy(
  input: {
    frontmostBundleId: string | null;
    windowTitle: string | null;
  },
  rules: PrivacyRules,
): PrivacyDecision {
  if (isDrmFocus(input.frontmostBundleId, rules)) {
    return { action: "pause_capture", reason: "drm" };
  }
  if (isAppBlocked(input.frontmostBundleId, rules)) {
    return { action: "redact", reason: "app_blocklist" };
  }
  if (isIncognitoWindow(input.frontmostBundleId, input.windowTitle, rules)) {
    return rules.incognitoMode === "redact"
      ? { action: "redact", reason: "incognito" }
      : { action: "skip", reason: "incognito" };
  }
  if (isTitleBlocked(input.windowTitle, rules)) {
    return { action: "redact", reason: "title_blocklist" };
  }
  return { action: "allow" };
}

/** True when L3 must not present over current focus (DRM / streaming). */
export function shouldSuppressL3ForFocus(
  bundleId: string | null | undefined,
  rules: PrivacyRules,
): boolean {
  return isDrmFocus(bundleId, rules);
}
