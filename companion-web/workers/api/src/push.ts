import {
  buildPushPayload,
  type PushSubscription,
  type VapidKeys,
} from "@block65/webcrypto-web-push";

export type NudgeKind = "morning" | "evening" | "eat" | "chime";

const NUDGE_COPY: Record<NudgeKind, { title: string; body: string }> = {
  morning: { title: "Companion", body: "Gentle morning check-in when you're ready." },
  evening: { title: "Companion", body: "Evening reflection — what went okay today?" },
  eat: { title: "Companion", body: "Have you eaten something today?" },
  chime: { title: "Companion", body: "Quick time check — how's it going?" },
};

export async function sendWebPush(opts: {
  subscriptionJson: string;
  vapid: VapidKeys;
  kind: NudgeKind;
}): Promise<boolean> {
  let subscription: PushSubscription;
  try {
    subscription = JSON.parse(opts.subscriptionJson) as PushSubscription;
  } catch {
    return false;
  }
  if (!subscription?.endpoint || !subscription.keys?.p256dh || !subscription.keys?.auth) {
    return false;
  }
  const copy = NUDGE_COPY[opts.kind];
  const message = {
    data: JSON.stringify({
      title: copy.title,
      body: copy.body,
      kind: opts.kind,
    }),
    options: { ttl: 60 * 60, urgency: "normal" as const },
  };
  try {
    const payload = await buildPushPayload(message, subscription, opts.vapid);
    const res = await fetch(subscription.endpoint, payload);
    return res.status >= 200 && res.status < 300;
  } catch {
    return false;
  }
}
