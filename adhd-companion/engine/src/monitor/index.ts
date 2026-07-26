/**
 * Fast-path alignment monitor — Phase 1 local heuristics only (no Gemini).
 * Conservative: low confidence → never recommend nudge.
 */

import type {
  AlignmentVerdict,
  CaptureContext,
  CaptureTrigger,
  Confidence,
  Priority,
} from "../types/index.js";

export interface MonitorInput {
  context: CaptureContext;
  priorities: Priority[];
  /** Bundles / title tokens considered on-task for active priorities (user or heuristic). */
  alignedSignals?: {
    bundleIds?: string[];
    titleSubstrings?: string[];
  };
  /** Bundles / titles that often mean drift (social, entertainment). */
  driftSignals?: {
    bundleIds?: string[];
    titleSubstrings?: string[];
  };
  /** Aggressiveness 0–2 maps to confidence threshold externally; kept for evidence only. */
  aggressiveness?: 0 | 1 | 2;
}

export interface MonitorResult {
  verdict: AlignmentVerdict;
  confidence: Confidence;
  /** True only when verdict is drift AND confidence is medium or high. */
  recommendNudge: boolean;
  evidence: string[];
}

const DEFAULT_DRIFT_BUNDLES = [
  "com.apple.Safari", // alone not enough — need title signals
];

const STRONG_DRIFT_BUNDLES = [
  "com.hnc.Discord",
  "com.tinyspeck.slackmacgap",
  "com.spotify.client",
  "com.netflix.Netflix",
  "com.apple.TV",
  "com.reddit.Reddit",
  "com.twitter.twitter-mac",
  "ru.keepcoder.Telegram",
  "org.whispersystems.signal-desktop",
];

const STRONG_DRIFT_TITLE = [
  "youtube",
  "twitter",
  "x.com",
  "instagram",
  "tiktok",
  "reddit",
  "facebook",
  "netflix",
  "hulu",
  "twitch",
];

const ANCHOR_TRIGGERS: CaptureTrigger[] = [
  "app_switch",
  "window_focus",
  "idle_return",
];

function activePriorities(priorities: Priority[]): Priority[] {
  return priorities.filter((p) => p.status === "active");
}

function includesAny(hay: string, needles: string[]): boolean {
  const h = hay.toLowerCase();
  return needles.some((n) => n.length > 0 && h.includes(n.toLowerCase()));
}

function confidenceAtLeast(have: Confidence, need: Confidence): boolean {
  const rank: Record<Confidence, number> = { low: 0, medium: 1, high: 2 };
  return rank[have] >= rank[need];
}

/**
 * Evaluate alignment from local signals only.
 * Rule: recommendNudge is false whenever confidence === "low".
 */
export function evaluateAlignment(input: MonitorInput): MonitorResult {
  const evidence: string[] = [];
  const active = activePriorities(input.priorities);

  if (active.length === 0) {
    evidence.push("no_active_priorities");
    return {
      verdict: "unknown",
      confidence: "low",
      recommendNudge: false,
      evidence,
    };
  }

  const bundle = input.context.frontmostBundleId ?? "";
  const title = input.context.windowTitle ?? "";
  const url = input.context.browserUrl ?? "";
  const blob = `${title} ${url}`;

  const alignedBundles = input.alignedSignals?.bundleIds ?? [];
  const alignedTitles = input.alignedSignals?.titleSubstrings ?? [];
  const driftBundles = [
    ...(input.driftSignals?.bundleIds ?? []),
    ...STRONG_DRIFT_BUNDLES,
  ];
  const driftTitles = [
    ...(input.driftSignals?.titleSubstrings ?? []),
    ...STRONG_DRIFT_TITLE,
  ];

  const onAlignedBundle =
    bundle.length > 0 &&
    alignedBundles.some((b) => b.toLowerCase() === bundle.toLowerCase());
  const onAlignedTitle =
    alignedTitles.length > 0 && includesAny(blob, alignedTitles);
  const onDriftBundle =
    bundle.length > 0 &&
    driftBundles.some((b) => b.toLowerCase() === bundle.toLowerCase());
  const onDriftTitle = includesAny(blob, driftTitles);

  const idle = input.context.idleSeconds;
  if (idle !== null && idle !== undefined && idle >= 300) {
    evidence.push("long_idle");
    return {
      verdict: "unknown",
      confidence: "low",
      recommendNudge: false,
      evidence,
    };
  }

  if (onAlignedBundle || onAlignedTitle) {
    evidence.push(
      onAlignedBundle ? "aligned_bundle" : "aligned_title",
    );
    return {
      verdict: "aligned",
      confidence: onAlignedBundle && onAlignedTitle ? "high" : "medium",
      recommendNudge: false,
      evidence,
    };
  }

  // Priority text overlap with title — weak positive signal
  const priorityHit = active.some((p) => {
    const tokens = p.text
      .toLowerCase()
      .split(/\s+/)
      .filter((t) => t.length >= 4);
    return tokens.some((t) => blob.toLowerCase().includes(t));
  });
  if (priorityHit) {
    evidence.push("priority_token_in_title");
    return {
      verdict: "aligned",
      confidence: "medium",
      recommendNudge: false,
      evidence,
    };
  }

  if (onDriftBundle && onDriftTitle) {
    evidence.push("drift_bundle_and_title");
    return finalizeDrift("high", evidence, input);
  }
  if (onDriftBundle || onDriftTitle) {
    evidence.push(onDriftBundle ? "drift_bundle" : "drift_title");
    // Single weak signal → medium only if we also have an event anchor
    const trigger = input.context.captureTrigger;
    const anchored =
      trigger !== null &&
      trigger !== undefined &&
      ANCHOR_TRIGGERS.includes(trigger as (typeof ANCHOR_TRIGGERS)[number]);
    if (anchored) {
      evidence.push(`anchor:${trigger}`);
      return finalizeDrift("medium", evidence, input);
    }
    evidence.push("no_event_anchor");
    return {
      verdict: "drift",
      confidence: "low",
      recommendNudge: false,
      evidence,
    };
  }

  // Unknown context — prefer silence
  if (!bundle && !title) {
    evidence.push("empty_context");
  } else {
    evidence.push("no_strong_signal");
    // Safari alone without title cues is unknown, not drift
    if (DEFAULT_DRIFT_BUNDLES.some((b) => b === bundle)) {
      evidence.push("browser_without_drift_title");
    }
  }

  return {
    verdict: "unknown",
    confidence: "low",
    recommendNudge: false,
    evidence,
  };
}

function finalizeDrift(
  confidence: Confidence,
  evidence: string[],
  _input: MonitorInput,
): MonitorResult {
  const recommendNudge = confidence !== "low";
  return {
    verdict: "drift",
    confidence,
    recommendNudge,
    evidence,
  };
}

export { confidenceAtLeast };
