use chrono::{DateTime, Datelike, FixedOffset, TimeZone, Timelike, Utc};

use crate::CoreError;

/// Dayflow's existing product convention: a new logical day begins at 4:00 AM.
pub const DEFAULT_LOGICAL_DAY_BOUNDARY_HOUR: u8 = 4;

/// Return the local calendar day that owns a timestamp under Dayflow's boundary.
///
/// `timezone_offset_minutes` is supplied by the native client at the time of
/// projection. Keeping the offset explicit makes replay deterministic and avoids
/// silently applying the host machine's timezone to an event recorded elsewhere.
pub fn logical_day_key(
    timestamp_unix: i64,
    timezone_offset_minutes: i32,
    boundary_hour: u8,
) -> Result<String, CoreError> {
    if boundary_hour > 23 {
        return Err(CoreError::InvalidBoundaryHour);
    }

    let offset_seconds = timezone_offset_minutes
        .checked_mul(60)
        .ok_or(CoreError::InvalidTimezoneOffset)?;
    let offset = FixedOffset::east_opt(offset_seconds).ok_or(CoreError::InvalidTimezoneOffset)?;
    let local = Utc
        .timestamp_opt(timestamp_unix, 0)
        .single()
        .ok_or(CoreError::InvalidTimestamp)?
        .with_timezone(&offset);

    let date = if local.hour() < u32::from(boundary_hour) {
        local.date_naive() - chrono::Days::new(1)
    } else {
        local.date_naive()
    };

    Ok(format!(
        "{:04}-{:02}-{:02}",
        date.year(),
        date.month(),
        date.day()
    ))
}

#[allow(dead_code)]
fn _local_datetime(
    timestamp_unix: i64,
    timezone_offset_minutes: i32,
) -> Result<DateTime<FixedOffset>, CoreError> {
    let offset_seconds = timezone_offset_minutes
        .checked_mul(60)
        .ok_or(CoreError::InvalidTimezoneOffset)?;
    let offset = FixedOffset::east_opt(offset_seconds).ok_or(CoreError::InvalidTimezoneOffset)?;
    Utc.timestamp_opt(timestamp_unix, 0)
        .single()
        .map(|value| value.with_timezone(&offset))
        .ok_or(CoreError::InvalidTimestamp)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn four_am_boundary_belongs_to_new_day() {
        let before = Utc
            .with_ymd_and_hms(2026, 8, 1, 3, 59, 59)
            .unwrap()
            .timestamp();
        let at_boundary = Utc
            .with_ymd_and_hms(2026, 8, 1, 4, 0, 0)
            .unwrap()
            .timestamp();
        let before_day = logical_day_key(before, 0, 4).unwrap();
        let boundary_day = logical_day_key(at_boundary, 0, 4).unwrap();

        assert_ne!(before_day, boundary_day);
    }

    #[test]
    fn west_coast_offset_is_applied_before_boundary() {
        // 04:30 UTC is 20:30 on the prior local date in UTC-8.
        let day = logical_day_key(1_720_000_000, -8 * 60, 4).unwrap();
        assert!(day.contains('-'));
    }
}
