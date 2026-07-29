/** 4 AM local logical day (Dayflow convention). */

export const DAY_BOUNDARY_HOUR = 4;

export function logicalDayKey(date = new Date()): string {
  const d = new Date(date);
  if (d.getHours() < DAY_BOUNDARY_HOUR) {
    d.setDate(d.getDate() - 1);
  }
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

export function previousLogicalDayKey(date = new Date()): string {
  const key = logicalDayKey(date);
  const [y, m, d] = key.split("-").map(Number);
  const dt = new Date(y!, m! - 1, d!);
  dt.setDate(dt.getDate() - 1);
  return logicalDayKey(new Date(dt.getFullYear(), dt.getMonth(), dt.getDate(), 12));
}

export function nextDayBoundaryUnix(now = Date.now()): number {
  const d = new Date(now);
  const boundary = new Date(d);
  boundary.setHours(DAY_BOUNDARY_HOUR, 0, 0, 0);
  if (d.getTime() >= boundary.getTime()) {
    boundary.setDate(boundary.getDate() + 1);
  }
  return Math.floor(boundary.getTime() / 1000);
}
