//! SQLite WAL store — schema from schema/schema.sql

use std::fs;
use std::path::{Path, PathBuf};

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::day_boundary::{logical_day_key, now_unix};
use crate::monitor::Priority;

#[derive(Debug, thiserror::Error)]
pub enum DbError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

pub struct Database {
    conn: Connection,
    pub root: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScreenshotRow {
    pub id: i64,
    pub captured_at: i64,
    pub day: String,
    pub file_path: Option<String>,
    pub capture_trigger: String,
    pub frontmost_bundle_id: Option<String>,
    pub window_title: Option<String>,
    pub redacted: i64,
    pub redact_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimelineCard {
    pub id: i64,
    pub day: String,
    pub start_time: i64,
    pub end_time: i64,
    pub title: String,
    pub summary: Option<String>,
    pub category: Option<String>,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BriefPayload {
    pub day: String,
    pub accomplishments: Vec<String>,
    pub still_open: Vec<String>,
    pub narrative: String,
}

impl Database {
    pub fn open(app_data_dir: &Path) -> Result<Self, DbError> {
        fs::create_dir_all(app_data_dir)?;
        fs::create_dir_all(app_data_dir.join("screenshots"))?;
        let db_path = app_data_dir.join("db.sqlite");
        let conn = Connection::open(&db_path)?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")?;
        let mut db = Self {
            conn,
            root: app_data_dir.to_path_buf(),
        };
        db.migrate()?;
        Ok(db)
    }

    fn migrate(&mut self) -> Result<(), DbError> {
        let schema = include_str!("../../schema/schema.sql");
        self.conn.execute_batch(schema)?;
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at INTEGER NOT NULL
            );",
        )?;
        let applied: Option<i64> = self
            .conn
            .query_row(
                "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1",
                [],
                |r| r.get(0),
            )
            .optional()?;
        if applied.is_none() {
            self.conn.execute(
                "INSERT INTO schema_migrations (version, applied_at) VALUES (1, ?1)",
                params![now_unix()],
            )?;
        }
        Ok(())
    }

    pub fn get_setting(&self, key: &str) -> Result<Option<String>, DbError> {
        let v = self
            .conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                params![key],
                |r| r.get(0),
            )
            .optional()?;
        Ok(v)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<(), DbError> {
        self.conn.execute(
            "INSERT INTO settings (key, value, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
            params![key, value, now_unix()],
        )?;
        Ok(())
    }

    pub fn insert_screenshot(
        &self,
        trigger: &str,
        bundle: Option<&str>,
        title: Option<&str>,
        file_path: Option<&str>,
        redacted: bool,
        redact_reason: Option<&str>,
        accessibility_text: Option<&str>,
        frame_hash: Option<&str>,
    ) -> Result<i64, DbError> {
        let captured_at = now_unix();
        let day = logical_day_key(captured_at);
        self.conn.execute(
            "INSERT INTO screenshots (
                captured_at, day, file_path, capture_trigger, frontmost_bundle_id,
                window_title, accessibility_text, text_source, frame_hash, redacted, redact_reason
             ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
            params![
                captured_at,
                day,
                file_path,
                trigger,
                bundle,
                title,
                accessibility_text,
                if accessibility_text.is_some() {
                    "thin_ax"
                } else {
                    "none"
                },
                frame_hash,
                if redacted { 1 } else { 0 },
                redact_reason,
            ],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    pub fn list_screenshots(&self, day: &str, limit: i64) -> Result<Vec<ScreenshotRow>, DbError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, captured_at, day, file_path, capture_trigger, frontmost_bundle_id,
                    window_title, redacted, redact_reason
             FROM screenshots WHERE day = ?1 ORDER BY captured_at DESC LIMIT ?2",
        )?;
        let rows = stmt
            .query_map(params![day, limit], |r| {
                Ok(ScreenshotRow {
                    id: r.get(0)?,
                    captured_at: r.get(1)?,
                    day: r.get(2)?,
                    file_path: r.get(3)?,
                    capture_trigger: r.get(4)?,
                    frontmost_bundle_id: r.get(5)?,
                    window_title: r.get(6)?,
                    redacted: r.get(7)?,
                    redact_reason: r.get(8)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn list_priorities(&self, day: &str) -> Result<Vec<Priority>, DbError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, text, status FROM priorities WHERE day = ?1 ORDER BY rank ASC, id ASC",
        )?;
        let rows = stmt
            .query_map(params![day], |r| {
                Ok(Priority {
                    id: r.get(0)?,
                    text: r.get(1)?,
                    status: r.get(2)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn replace_priorities(&self, day: &str, texts: &[String], source: &str) -> Result<(), DbError> {
        self.conn
            .execute("DELETE FROM priorities WHERE day = ?1", params![day])?;
        for (i, text) in texts.iter().enumerate() {
            let t = text.trim();
            if t.is_empty() {
                continue;
            }
            self.conn.execute(
                "INSERT INTO priorities (day, rank, text, status, source, created_at, updated_at)
                 VALUES (?1, ?2, ?3, 'active', ?4, ?5, ?5)",
                params![day, i as i64, t, source, now_unix()],
            )?;
        }
        Ok(())
    }

    pub fn soft_confirm_carryover(&self, from_day: &str, to_day: &str) -> Result<usize, DbError> {
        let existing = self.list_priorities(to_day)?;
        if !existing.is_empty() {
            return Ok(0);
        }
        let prev = self.list_priorities(from_day)?;
        let active: Vec<_> = prev
            .into_iter()
            .filter(|p| p.status == "active" || p.status == "carried")
            .collect();
        for (i, p) in active.iter().enumerate() {
            self.conn.execute(
                "INSERT INTO priorities (day, rank, text, status, source, carried_from_id, created_at, updated_at)
                 VALUES (?1, ?2, ?3, 'active', 'soft_confirm', ?4, ?5, ?5)",
                params![to_day, i as i64, p.text, p.id, now_unix()],
            )?;
        }
        Ok(active.len())
    }

    /// Mark existing analyze-batch cards replaced before a new slow-path run (sliding-window).
    pub fn replace_analyze_timeline_cards(&self, day: &str) -> Result<(), DbError> {
        self.conn.execute(
            "UPDATE timeline_cards SET status = 'replaced', updated_at = ?2
             WHERE day = ?1 AND status = 'active' AND (category IS NULL OR category = 'local')",
            params![day, now_unix()],
        )?;
        Ok(())
    }

    pub fn insert_timeline_card(
        &self,
        day: &str,
        start: i64,
        end: i64,
        title: &str,
        summary: &str,
        category: Option<&str>,
    ) -> Result<i64, DbError> {
        self.conn.execute(
            "INSERT INTO timeline_cards (day, start_time, end_time, title, summary, category, status, created_at, updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,'active',?7,?7)",
            params![day, start, end, title, summary, category, now_unix()],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    pub fn list_timeline_cards(&self, day: &str) -> Result<Vec<TimelineCard>, DbError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, day, start_time, end_time, title, summary, category, status
             FROM timeline_cards WHERE day = ?1 AND status = 'active' ORDER BY start_time ASC",
        )?;
        let rows = stmt
            .query_map(params![day], |r| {
                Ok(TimelineCard {
                    id: r.get(0)?,
                    day: r.get(1)?,
                    start_time: r.get(2)?,
                    end_time: r.get(3)?,
                    title: r.get(4)?,
                    summary: r.get(5)?,
                    category: r.get(6)?,
                    status: r.get(7)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn log_nudge_event(
        &self,
        day: &str,
        level: &str,
        previous: Option<&str>,
        action: &str,
        reason: Option<&str>,
        confidence: Option<&str>,
        escalate_after: Option<i64>,
    ) -> Result<(), DbError> {
        self.conn.execute(
            "INSERT INTO nudge_events (
                day, level, previous_level, action, reason, confidence, escalate_after_unix, created_at
             ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
            params![
                day,
                level,
                previous,
                action,
                reason,
                confidence,
                escalate_after,
                now_unix()
            ],
        )?;
        Ok(())
    }

    pub fn log_llm_call(
        &self,
        day: &str,
        budget_tag: &str,
        purpose: &str,
        status: &str,
        cost_usd: Option<f64>,
        summary: &str,
    ) -> Result<(), DbError> {
        self.conn.execute(
            "INSERT INTO llm_calls (day, budget_tag, provider, purpose, status, cost_usd, request_summary, created_at)
             VALUES (?1,?2,'local_or_gemini',?3,?4,?5,?6,?7)",
            params![day, budget_tag, purpose, status, cost_usd, summary, now_unix()],
        )?;
        Ok(())
    }

    pub fn build_evening_brief(&self, day: &str) -> Result<BriefPayload, DbError> {
        let priorities = self.list_priorities(day)?;
        let cards = self.list_timeline_cards(day)?;
        let mut accomplishments = Vec::new();
        let mut still_open = Vec::new();
        for p in &priorities {
            if p.status == "done" {
                accomplishments.push(p.text.clone());
            } else if p.status == "active" || p.status == "deferred" {
                still_open.push(p.text.clone());
            }
        }
        for c in cards.iter().take(5) {
            if !accomplishments.iter().any(|a| a == &c.title) {
                accomplishments.push(format!("Spent time on: {}", c.title));
            }
        }
        if accomplishments.is_empty() {
            accomplishments.push("You showed up today — that counts.".into());
        }
        let narrative = format!(
            "Accomplishments first: {}. Still open (no shame): {}.",
            accomplishments.join("; "),
            if still_open.is_empty() {
                "nothing urgent".into()
            } else {
                still_open.join("; ")
            }
        );
        Ok(BriefPayload {
            day: day.into(),
            accomplishments,
            still_open,
            narrative,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn migrate_and_priorities() {
        let dir = tempdir().unwrap();
        let db = Database::open(dir.path()).unwrap();
        db.replace_priorities("2024-06-15", &["A".into(), "B".into()], "checkin")
            .unwrap();
        let ps = db.list_priorities("2024-06-15").unwrap();
        assert_eq!(ps.len(), 2);
    }
}
