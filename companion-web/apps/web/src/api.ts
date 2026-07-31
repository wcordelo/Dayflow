const API = import.meta.env.VITE_API_BASE ?? "";

export function wsUrl(path: string): string {
  const origin = API ? new URL(API, window.location.origin).origin : window.location.origin;
  const wsProto = origin.startsWith("https") ? "wss:" : "ws:";
  return `${wsProto}//${new URL(origin).host}${path}`;
}

export async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${API}${path}`, {
    ...init,
    credentials: "include",
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(text || res.statusText);
  }
  return res.json() as Promise<T>;
}

export type ServerState = {
  priorities: Array<{ id: string; text: string; status: string }>;
  yesterdayPriorities?: Array<{ id: string; text: string; status: string }>;
  settings: {
    checkinHour: number;
    reflectionHour: number;
    chimeFrequencyMin: number | null;
    eatReminderEnabled: boolean;
    eatReminderHour: number;
    ttsEnabled: boolean;
    openRouterKeySet: boolean;
    overwhelmUntil: number | null;
    healthDataConsent: boolean;
    ianaTimeZone?: string | null;
    engagement?: {
      weekKey: string;
      checkinsThisWeek: number;
      missedNudges: number;
      backoffUntil: number | null;
    };
  };
  dayKey: string;
  dayLog: string[];
  lastBrief: unknown | null;
};
