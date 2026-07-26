//! Gemini + local LLM runners for pipe engines.

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::db::Database;
use crate::day_boundary::logical_day_key;
use crate::day_boundary::now_unix;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmResponse {
    pub text: String,
    pub model: String,
    pub prompt_tokens: Option<i64>,
    pub completion_tokens: Option<i64>,
    pub cost_usd: Option<f64>,
    pub used_network: bool,
}

pub trait LlmClient: Send + Sync {
    fn complete(&self, system: &str, user: &str) -> Result<LlmResponse, String>;
}

/// Offline / CI client — deterministic, never hits network.
pub struct LocalLlm;

impl LlmClient for LocalLlm {
    fn complete(&self, _system: &str, user: &str) -> Result<LlmResponse, String> {
        Ok(LlmResponse {
            text: format!("[local] {}", user.chars().take(400).collect::<String>()),
            model: "local-heuristic".into(),
            prompt_tokens: Some(0),
            completion_tokens: Some(0),
            cost_usd: Some(0.0),
            used_network: false,
        })
    }
}

pub struct GeminiClient {
    pub api_key: String,
    pub model: String,
}

impl GeminiClient {
    pub fn new(api_key: String) -> Self {
        Self {
            api_key,
            model: "gemini-2.0-flash".into(),
        }
    }
}

impl LlmClient for GeminiClient {
    fn complete(&self, system: &str, user: &str) -> Result<LlmResponse, String> {
        let url = format!(
            "https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent?key={}",
            self.model, self.api_key
        );
        let body = json!({
            "system_instruction": { "parts": [{ "text": system }] },
            "contents": [{ "role": "user", "parts": [{ "text": user }] }],
            "generationConfig": { "temperature": 0.4 }
        });
        let resp = ureq::post(&url)
            .set("Content-Type", "application/json")
            .send_json(body)
            .map_err(|e| format!("gemini http: {e}"))?;
        let v: serde_json::Value = resp.into_json().map_err(|e| format!("gemini json: {e}"))?;
        let text = v["candidates"][0]["content"]["parts"][0]["text"]
            .as_str()
            .unwrap_or("")
            .to_string();
        if text.is_empty() {
            return Err(format!("gemini empty: {v}"));
        }
        let prompt_tokens = v["usageMetadata"]["promptTokenCount"].as_i64();
        let completion_tokens = v["usageMetadata"]["candidatesTokenCount"].as_i64();
        // rough flash pricing placeholder for soft-cap display
        let cost = match (prompt_tokens, completion_tokens) {
            (Some(p), Some(c)) => Some((p as f64 * 0.0000001) + (c as f64 * 0.0000004)),
            _ => None,
        };
        Ok(LlmResponse {
            text,
            model: self.model.clone(),
            prompt_tokens,
            completion_tokens,
            cost_usd: cost,
            used_network: true,
        })
    }
}

pub fn select_client(data_dir: &std::path::Path, opt_in: bool) -> Box<dyn LlmClient> {
    if !opt_in {
        return Box::new(LocalLlm);
    }
    match crate::secrets::load_gemini_key(data_dir) {
        Some(k) => Box::new(GeminiClient::new(k)),
        None => Box::new(LocalLlm),
    }
}

pub fn log_llm(
    db: &Database,
    budget_tag: &str,
    purpose: &str,
    resp: &LlmResponse,
    status: &str,
) {
    let day = logical_day_key(now_unix());
    let _ = db.log_llm_call(
        &day,
        budget_tag,
        purpose,
        status,
        resp.cost_usd,
        &format!("model={} net={}", resp.model, resp.used_network),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_never_networks() {
        let c = LocalLlm;
        let r = c.complete("sys", "hello world").unwrap();
        assert!(!r.used_network);
        assert!(r.text.contains("hello"));
    }
}
