/** 4 AM local logical day (Dayflow convention). */

export const DAY_BOUNDARY_HOUR = 4;

type ZonedParts = { year: number; month: number; day: number; hour: number; minute: number };

export function zonedParts(date: Date, timeZone: string): ZonedParts {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "numeric",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(date);
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value ?? "0");
  return {
    year: get("year"),
    month: get("month"),
    day: get("day"),
    hour: get("hour") % 24,
    minute: get("minute"),
  };
}

export function logicalDayKey(date = new Date(), timeZone?: string | null): string {
  if (timeZone) {
    const { year, month, day, hour } = zonedParts(date, timeZone);
    if (hour < DAY_BOUNDARY_HOUR) {
      return logicalDayKey(new Date(date.getTime() - 86400000), timeZone);
    }
    return `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  }
  const d = new Date(date);
  if (d.getHours() < DAY_BOUNDARY_HOUR) {
    d.setDate(d.getDate() - 1);
  }
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

export function previousLogicalDayKey(date = new Date(), timeZone?: string | null): string {
  const key = logicalDayKey(date, timeZone);
  const [y, m, d] = key.split("-").map(Number);
  const dt = new Date(y!, m! - 1, d!);
  dt.setDate(dt.getDate() - 1);
  return logicalDayKey(new Date(dt.getFullYear(), dt.getMonth(), dt.getDate(), 12), timeZone);
}

/** Next wall-clock occurrence of `hour`:00 in `timeZone`, strictly after `now`. */
export function nextUnixForLocalHour(hour: number, timeZone: string, now = Date.now()): number {
  let probe = Math.floor(now / 60_000) * 60_000 + 60_000;
  for (let i = 0; i < 7 * 24 * 60; i++) {
    const { hour: h, minute } = zonedParts(new Date(probe), timeZone);
    if (h === hour && minute === 0 && probe > now) return probe;
    probe += 60_000;
  }
  return now + 86400000;
}

export function nextDayBoundaryUnix(now = Date.now(), timeZone?: string | null): number {
  if (timeZone) {
    const { hour } = zonedParts(new Date(now), timeZone);
    let at = nextUnixForLocalHour(DAY_BOUNDARY_HOUR, timeZone, now - 60_000);
    if (hour >= DAY_BOUNDARY_HOUR && at <= now) {
      at = nextUnixForLocalHour(DAY_BOUNDARY_HOUR, timeZone, at);
    }
    return Math.floor(at / 1000);
  }
  const d = new Date(now);
  const boundary = new Date(d);
  boundary.setHours(DAY_BOUNDARY_HOUR, 0, 0, 0);
  if (d.getTime() >= boundary.getTime()) {
    boundary.setDate(boundary.getDate() + 1);
  }
  return Math.floor(boundary.getTime() / 1000);
}
