/**
 * Logical day helpers — Dayflow 4 AM local boundary.
 * Day key = YYYY-MM-DD for the calendar day that started at the most recent 4:00 local.
 */

const DAY_BOUNDARY_HOUR = 4;

export interface DayBoundaryOptions {
  /** Local hour when the day rolls (default 4). */
  boundaryHour?: number;
  /**
   * Optional timezone offset minutes east of UTC at `unixSeconds`
   * (e.g. Date.getTimezoneOffset() returns west-of-UTC; pass -getTimezoneOffset()).
   * If omitted, uses the host local timezone.
   */
  timezoneOffsetMinutes?: number;
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

function formatYmd(year: number, monthIndex: number, day: number): string {
  return `${year}-${pad2(monthIndex + 1)}-${pad2(day)}`;
}

/**
 * Convert unix seconds + offset into local Y/M/D/H/M/S components.
 * `timezoneOffsetMinutes` is minutes east of UTC (IST = +330).
 */
function localParts(
  unixSeconds: number,
  timezoneOffsetMinutes?: number,
): { y: number; m: number; d: number; h: number; min: number; s: number } {
  if (timezoneOffsetMinutes === undefined) {
    const d = new Date(unixSeconds * 1000);
    return {
      y: d.getFullYear(),
      m: d.getMonth(),
      d: d.getDate(),
      h: d.getHours(),
      min: d.getMinutes(),
      s: d.getSeconds(),
    };
  }
  const shifted = new Date((unixSeconds + timezoneOffsetMinutes * 60) * 1000);
  return {
    y: shifted.getUTCFullYear(),
    m: shifted.getUTCMonth(),
    d: shifted.getUTCDate(),
    h: shifted.getUTCHours(),
    min: shifted.getUTCMinutes(),
    s: shifted.getUTCSeconds(),
  };
}

/**
 * Returns the logical day key (YYYY-MM-DD) for a wall-clock unix timestamp.
 * Times before 04:00 local belong to the previous calendar date's day key.
 */
export function logicalDayKey(
  unixSeconds: number,
  options: DayBoundaryOptions = {},
): string {
  const boundaryHour = options.boundaryHour ?? DAY_BOUNDARY_HOUR;
  const p = localParts(unixSeconds, options.timezoneOffsetMinutes);

  let y = p.y;
  let m = p.m;
  let d = p.d;
  if (p.h < boundaryHour) {
    // Roll back one calendar day
    const prev = new Date(Date.UTC(y, m, d));
    prev.setUTCDate(prev.getUTCDate() - 1);
    y = prev.getUTCFullYear();
    m = prev.getUTCMonth();
    d = prev.getUTCDate();
  }
  return formatYmd(y, m, d);
}

/**
 * Unix seconds of the start of the logical day containing `unixSeconds`
 * (local midnight+boundaryHour of that day key).
 */
export function logicalDayStartUnix(
  unixSeconds: number,
  options: DayBoundaryOptions = {},
): number {
  const boundaryHour = options.boundaryHour ?? DAY_BOUNDARY_HOUR;
  const key = logicalDayKey(unixSeconds, options);
  const [ys, ms, ds] = key.split("-").map((x) => Number(x));
  if (ys === undefined || ms === undefined || ds === undefined) {
    throw new Error(`Invalid day key: ${key}`);
  }

  if (options.timezoneOffsetMinutes === undefined) {
    const start = new Date(ys, ms - 1, ds, boundaryHour, 0, 0, 0);
    return Math.floor(start.getTime() / 1000);
  }

  // Interpret Y-M-D boundaryHour in the given offset as UTC epoch
  const asUtc = Date.UTC(ys, ms - 1, ds, boundaryHour, 0, 0) -
    options.timezoneOffsetMinutes * 60 * 1000;
  return Math.floor(asUtc / 1000);
}

/** Next 4 AM boundary after `unixSeconds` (Overwhelm pause end). */
export function nextDayBoundaryUnix(
  unixSeconds: number,
  options: DayBoundaryOptions = {},
): number {
  const start = logicalDayStartUnix(unixSeconds, options);
  if (unixSeconds < start) {
    return start;
  }
  // Start of *next* logical day = this day's start + ~24h via day key + 1
  const key = logicalDayKey(unixSeconds, options);
  const [ys, ms, ds] = key.split("-").map((x) => Number(x));
  if (ys === undefined || ms === undefined || ds === undefined) {
    throw new Error(`Invalid day key: ${key}`);
  }
  const next = new Date(Date.UTC(ys, ms - 1, ds));
  next.setUTCDate(next.getUTCDate() + 1);
  const nextKey = formatYmd(
    next.getUTCFullYear(),
    next.getUTCMonth(),
    next.getUTCDate(),
  );
  const boundaryHour = options.boundaryHour ?? DAY_BOUNDARY_HOUR;
  if (options.timezoneOffsetMinutes === undefined) {
    const [ny, nm, nd] = nextKey.split("-").map((x) => Number(x));
    if (ny === undefined || nm === undefined || nd === undefined) {
      throw new Error(`Invalid next day key: ${nextKey}`);
    }
    return Math.floor(new Date(ny, nm - 1, nd, boundaryHour, 0, 0, 0).getTime() / 1000);
  }
  const [ny, nm, nd] = nextKey.split("-").map((x) => Number(x));
  if (ny === undefined || nm === undefined || nd === undefined) {
    throw new Error(`Invalid next day key: ${nextKey}`);
  }
  const asUtc =
    Date.UTC(ny, nm - 1, nd, boundaryHour, 0, 0) -
    options.timezoneOffsetMinutes * 60 * 1000;
  return Math.floor(asUtc / 1000);
}

export { DAY_BOUNDARY_HOUR };
