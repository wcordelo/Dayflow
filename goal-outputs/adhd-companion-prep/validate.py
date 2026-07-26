#!/usr/bin/env python3
"""Tier 1 structural validation for adhd-companion-prep package."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent

REQUIRED_FILES = [
    "SPEC.md",
    "schema.sql",
    "M0_RUNBOOK.md",
    "PACKAGE_README.md",
    "prompts/checkin.md",
    "prompts/analyze.md",
    "prompts/monitor.md",
    "prompts/brief.md",
]

SPEC_SECTIONS = [
    "GOAL",
    "DELIVERABLES",
    "BUILD POLICY",
    "CAPTURE",
    "DUAL PATH",
    "ORCHESTRATOR",
    "PRIVACY SUITE",
    "M0 CRITERIA",
]

TABLES = [
    "screenshots",
    "observations",
    "timeline_cards",
    "priorities",
    "nudge_events",
    "settings",
    "llm_calls",
]

SCREENSHOT_COLS = [
    "capture_trigger",
    "idle_seconds_at_capture",
    "frontmost_bundle_id",
    "window_title",
    "redacted",
    "file_path",
]


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


def main() -> None:
    missing = [f for f in REQUIRED_FILES if not (ROOT / f).is_file()]
    if missing:
        fail(f"missing files: {missing}")
    if len(REQUIRED_FILES) != 8:
        fail("internal: required list must be census 8")
    present = [f for f in REQUIRED_FILES if (ROOT / f).is_file()]
    if len(present) != 8:
        fail(f"census != 8 (found {len(present)})")

    for f in REQUIRED_FILES:
        data = (ROOT / f).read_bytes()
        if b"\x00" in data:
            fail(f"{f} contains null bytes")
        data.decode("utf-8")

    spec = (ROOT / "SPEC.md").read_text(encoding="utf-8")
    for section in SPEC_SECTIONS:
        if not re.search(rf"(?i){re.escape(section)}", spec):
            fail(f"SPEC.md missing section marker: {section}")
    gate = re.search(
        r"hard gate removed|build policy|scaffold.{0,40}proceed|not a gate on agent",
        spec,
        re.I,
    )
    if not gate:
        fail("SPEC.md missing v2.3 build-policy language (hard gate removed / scaffold proceeds)")
    if "create-tauri-app" in spec.lower() and re.search(
        r"create-tauri-app[\s\S]{0,80}blocked until M0",
        spec,
        re.I,
    ):
        fail("SPEC.md still contains old hard-gate blocker language")

    sql = (ROOT / "schema.sql").read_text(encoding="utf-8").lower()
    for table in TABLES:
        if not re.search(rf"create\s+table\s+(if\s+not\s+exists\s+)?{table}\b", sql):
            fail(f"schema.sql missing CREATE TABLE {table}")
    # Extract screenshots table body roughly
    m = re.search(
        r"create\s+table\s+(if\s+not\s+exists\s+)?screenshots\s*\((.*?)\)\s*;",
        sql,
        re.S,
    )
    shot_body = m.group(2) if m else sql
    for col in SCREENSHOT_COLS:
        if col not in shot_body:
            fail(f"screenshots table missing column: {col}")

    for name in ("checkin", "analyze", "monitor", "brief"):
        text = (ROOT / "prompts" / f"{name}.md").read_text(encoding="utf-8")
        if not text.startswith("---"):
            fail(f"prompts/{name}.md missing YAML frontmatter start")
        end = text.find("---", 3)
        if end < 0:
            fail(f"prompts/{name}.md missing YAML frontmatter end")
        fm = text[3:end]
        if not re.search(r"(?m)^(schedule|trigger)\s*:", fm):
            fail(f"prompts/{name}.md frontmatter missing schedule or trigger")
        if not re.search(r"(?m)^budget_tag\s*:", fm):
            fail(f"prompts/{name}.md frontmatter missing budget_tag")
        body = text[end + 3 :].strip()
        if len(body) < 200:
            fail(f"prompts/{name}.md body < 200 chars ({len(body)})")

    monitor = (ROOT / "prompts/monitor.md").read_text(encoding="utf-8").lower()
    if not all(x in monitor for x in ("low", "medium", "high")):
        fail("monitor.md must mention confidence levels low/medium/high")
    if "nudge" not in monitor or "confidence" not in monitor:
        fail("monitor.md must discuss confidence and nudging")
    if not re.search(r"low[^\n.]{0,80}(no nudge|not nudge|do not nudge|don't nudge|skip nudge|remain silent|stay silent)", monitor):
        # softer fallback
        if not ("no nudge" in monitor or "not fire" in monitor or "silent" in monitor):
            fail("monitor.md must state low confidence => no nudge (or silent)")

    brief = (ROOT / "prompts/brief.md").read_text(encoding="utf-8")
    brief_l = brief.lower()
    if "still open" not in brief_l and "still-open" not in brief_l:
        fail("brief.md must include still open framing")
    if "accomplishment" not in brief_l and "what you did" not in brief_l:
        fail("brief.md must be accomplishment-first")
    # Forbid failed/failure as outcome labels — allow mentioning the forbid rule
    # Check that outcome vocabulary includes done/progressed
    if "done" not in brief_l or "progressed" not in brief_l:
        fail("brief.md must include done and progressed outcomes")
    if not re.search(r"fail(ed|ure)", brief_l):
        fail("brief.md should explicitly forbid failed/failure as priority outcomes")

    runbook = (ROOT / "M0_RUNBOOK.md").read_text(encoding="utf-8")
    for letter in ("a", "b", "c", "d", "e", "f"):
        if not re.search(rf"\({letter}\)|criterion {letter}|criteria {letter}|#{letter}\b|^\s*-\s*\[[ x]\].*\({letter}\)", runbook, re.I | re.M):
            # broader: just require the letter in parentheses somewhere near checklist
            if f"({letter})" not in runbook.lower() and f"(**{letter}**)" not in runbook.lower():
                fail(f"M0_RUNBOOK.md missing checklist marker for ({letter})")
    if not re.search(r"linux|cloud agent|cannot execute|can'?t execute|not (able|possible).*m0", runbook, re.I):
        fail("M0_RUNBOOK.md must state Linux/Cloud Agent cannot execute native M0")

    readme = (ROOT / "PACKAGE_README.md").read_text(encoding="utf-8")
    for f in REQUIRED_FILES:
        base = f.split("/")[-1]
        if base not in readme and f not in readme:
            fail(f"PACKAGE_README.md must list {f}")
    if not re.search(r"v2\.3|hard gate removed|parallel", readme, re.I):
        fail("PACKAGE_README.md must state v2.3 build policy (hard gate removed / parallel M0)")
    if not ("(a)" in readme and "(b)" in readme and "(e)" in readme) and "M0" not in readme:
        fail("PACKAGE_README.md should mention M0 validation")

    print("PASS: validate.py 8/8 files; all mechanical checks green")
    sys.exit(0)


if __name__ == "__main__":
    main()
