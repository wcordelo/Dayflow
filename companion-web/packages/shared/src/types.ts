export type PriorityStatus = "active" | "done" | "progressed" | "open" | "dropped";

export type Priority = {
  id: string;
  text: string;
  status: PriorityStatus;
  source?: string;
};

export type EngagementState = {
  /** ISO week key YYYY-Www for rolling weekly check-in count */
  weekKey: string;
  checkinsThisWeek: number;
  /** Distinct logical day last counted toward checkinsThisWeek */
  lastCountedDayKey: string | null;
  /** Consecutive unanswered nudges — drives soft backoff */
  missedNudges: number;
  /** Unix seconds; skip push/nudge until this time when decaying */
  backoffUntil: number | null;
  /** Unix seconds when the last nudge was sent; next alarm counts a miss if still set */
  lastNudgeAt: number | null;
};

import { logicalDayKey } from "./dayBoundary.js";

export type UserSettings = {
  checkinHour: number;
  reflectionHour: number;
  chimeFrequencyMin: number | null;
  eatReminderEnabled: boolean;
  eatReminderHour: number;
  quietHoursStart: number | null;
  quietHoursEnd: number | null;
  ttsEnabled: boolean;
  openRouterKeySet: boolean;
  overwhelmUntil: number | null;
  healthDataConsent: boolean;
  /** IANA timezone for local nudge hours and logical day (e.g. America/Los_Angeles) */
  ianaTimeZone: string | null;
  engagement: EngagementState;
};

export function isoWeekKey(d = new Date(), timeZone?: string | null): string {
  let year: number;
  let month: number;
  let day: number;
  if (timeZone) {
    const key = logicalDayKey(d, timeZone);
    [year, month, day] = key.split("-").map(Number) as [number, number, number];
  } else {
    year = d.getFullYear();
    month = d.getMonth() + 1;
    day = d.getDate();
  }
  const date = new Date(Date.UTC(year, month - 1, day));
  const dayNum = date.getUTCDay() || 7;
  date.setUTCDate(date.getUTCDate() + 4 - dayNum);
  const yearStart = new Date(Date.UTC(date.getUTCFullYear(), 0, 1));
  const weekNo = Math.ceil((((date.getTime() - yearStart.getTime()) / 86400000) + 1) / 7);
  return `${date.getUTCFullYear()}-W${String(weekNo).padStart(2, "0")}`;
}

export const DEFAULT_ENGAGEMENT: EngagementState = {
  weekKey: isoWeekKey(),
  checkinsThisWeek: 0,
  lastCountedDayKey: null,
  missedNudges: 0,
  backoffUntil: null,
  lastNudgeAt: null,
};

export const DEFAULT_SETTINGS: UserSettings = {
  checkinHour: 9,
  reflectionHour: 18,
  chimeFrequencyMin: null,
  eatReminderEnabled: false,
  eatReminderHour: 12,
  quietHoursStart: 22,
  quietHoursEnd: 7,
  ttsEnabled: true,
  openRouterKeySet: false,
  overwhelmUntil: null,
  healthDataConsent: false,
  ianaTimeZone: null,
  engagement: { ...DEFAULT_ENGAGEMENT },
};

/** Private-beta success bar: ≥4 check-ins/week by week 4 */
export const WEEKLY_CHECKIN_TARGET = 4;

export type CompanionEventKind =
  | "priority_set"
  | "priority_update"
  | "checkin_completed"
  | "chime_answered"
  | "overwhelm_on"
  | "overwhelm_off"
  | "brief_generated"
  | "settings_updated"
  | "day_log_note"
  | "gratitude"
  | "friend_reframe";

export type CompanionEvent = {
  id: number;
  kind: CompanionEventKind;
  dayKey: string;
  payload: unknown;
  createdAt: number;
};

export type NudgeType = "morning" | "noon_chime" | "15min_chime" | "eat_reminder" | "evening";

export type ChatMessage = {
  role: "user" | "assistant" | "system";
  content: string;
};
