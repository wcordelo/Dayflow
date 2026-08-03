#!/usr/bin/env bash
set -euo pipefail

action="${1:-runtime}"

printf '%s\n' \
  "Archived ADHD Companion prototype runtime is disabled (${action})." \
  "Use a native Dayflow client; do not launch the historical browser/Tauri surface." >&2
exit 1
