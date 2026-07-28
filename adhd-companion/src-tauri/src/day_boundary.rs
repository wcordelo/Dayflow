//! Day boundary — 4 AM local logical day (Dayflow convention).

use chrono::{DateTime, Duration, Local, NaiveTime, TimeZone};

pub const DAY_BOUNDARY_HOUR: u32 = 4;

/// YYYY-MM-DD for the logical day containing `unix_seconds` (local 4 AM boundary).
pub fn logical_day_key(unix_seconds: i64) -> String {
    let dt = Local
        .timestamp_opt(unix_seconds, 0)
        .single()
        .unwrap_or_else(Local::now);
    let boundary = NaiveTime::from_hms_opt(DAY_BOUNDARY_HOUR, 0, 0).unwrap();
    let local_date = if dt.time() < boundary {
        dt.date_naive() - Duration::days(1)
    } else {
        dt.date_naive()
    };
    local_date.format("%Y-%m-%d").to_string()
}

pub fn now_unix() -> i64 {
    Local::now().timestamp()
}

pub fn logical_day_start_unix(unix_seconds: i64) -> i64 {
    let dt = Local
        .timestamp_opt(unix_seconds, 0)
        .single()
        .unwrap_or_else(Local::now);
    let boundary = NaiveTime::from_hms_opt(DAY_BOUNDARY_HOUR, 0, 0).unwrap();
    let start_date = if dt.time() < boundary {
        dt.date_naive() - Duration::days(1)
    } else {
        dt.date_naive()
    };
    let start_naive = start_date.and_time(boundary);
    let start: DateTime<Local> = Local
        .from_local_datetime(&start_naive)
        .single()
        .unwrap_or(dt);
    start.timestamp()
}

/// Previous logical day key (4 AM boundary), not wall-clock −24h.
pub fn previous_logical_day_key(unix_seconds: i64) -> String {
    logical_day_key(logical_day_start_unix(unix_seconds) - 1)
}

pub fn next_day_boundary_unix(unix_seconds: i64) -> i64 {
    let dt = Local
        .timestamp_opt(unix_seconds, 0)
        .single()
        .unwrap_or_else(Local::now);
    let boundary = NaiveTime::from_hms_opt(DAY_BOUNDARY_HOUR, 0, 0).unwrap();
    let start_date = if dt.time() < boundary {
        dt.date_naive()
    } else {
        dt.date_naive() + Duration::days(1)
    };
    let start_naive = start_date.and_time(boundary);
    let start: DateTime<Local> = Local
        .from_local_datetime(&start_naive)
        .single()
        .unwrap_or(dt);
    start.timestamp()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn day_key_stable_format() {
        let key = logical_day_key(now_unix());
        assert_eq!(key.len(), 10);
        assert!(key.chars().nth(4) == Some('-'));
    }
}
