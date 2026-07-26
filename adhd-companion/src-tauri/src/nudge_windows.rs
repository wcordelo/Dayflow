//! L1 notification + L2/L3 dedicated nudge windows.

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_notification::NotificationExt;

pub fn present_nudge_level(app: &AppHandle, level: &str) -> Result<(), String> {
    match level {
        "L1" => show_l1_notification(app),
        "L2" | "L3" => show_nudge_window(app, level),
        _ => Ok(()),
    }
}

pub fn show_l1_notification(app: &AppHandle) -> Result<(), String> {
    app.notification()
        .builder()
        .title("Gentle nudge")
        .body("Still on your priorities? Tap to check in.")
        .show()
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn show_nudge_window(app: &AppHandle, level: &str) -> Result<(), String> {
    let label = match level {
        "L2" => "nudge-l2",
        "L3" => "nudge-l3",
        _ => return Ok(()),
    };
    if let Some(w) = app.get_webview_window(label) {
        w.show().map_err(|e| e.to_string())?;
        let _ = w.set_focus();
        return Ok(());
    }
    let title = if level == "L3" {
        "Take a breath — priorities"
    } else {
        "Quick check-in"
    };
    let url = format!("nudge.html?level={level}");
    let builder = WebviewWindowBuilder::new(app, label, WebviewUrl::App(url.into()))
        .title(title)
        .inner_size(
            if level == "L3" { 520.0 } else { 420.0 },
            if level == "L3" { 560.0 } else { 320.0 },
        )
        .resizable(false)
        .always_on_top(true)
        .visible(true)
        .focused(true);
    // macOS: promote to NSPanel collection behaviors in objc2 follow-up (M0-b).
    builder.build().map_err(|e| e.to_string())?;
    Ok(())
}

pub fn hide_nudge_windows(app: &AppHandle) -> Result<(), String> {
    for label in ["nudge-l2", "nudge-l3"] {
        if let Some(w) = app.get_webview_window(label) {
            let _ = w.hide();
        }
    }
    Ok(())
}
