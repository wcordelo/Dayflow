#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Dayflow legacy autostart cleanup is macOS-only; nothing to do."
  exit 0
fi

user_id="$(id -u)"
legacy_agent="${HOME}/Library/LaunchAgents/ADHD Companion.plist"

if [[ ! -f "${legacy_agent}" ]]; then
  echo "No retired ADHD Companion launch agent found."
  exit 0
fi

# Disable the exact retired job in launchd first. These operations are
# idempotent and scoped to this one known label/path.
launchctl disable "gui/${user_id}/ADHD Companion" 2>/dev/null || true
launchctl bootout "gui/${user_id}" "${legacy_agent}" 2>/dev/null || true

# Keep the plist for auditability, but make its disabled state survive a
# future login or launchd reload.
if ! /usr/libexec/PlistBuddy -c 'Set :Disabled true' "${legacy_agent}" 2>/dev/null; then
  /usr/libexec/PlistBuddy -c 'Add :Disabled bool true' "${legacy_agent}"
fi
if ! /usr/libexec/PlistBuddy -c 'Set :RunAtLoad false' "${legacy_agent}" 2>/dev/null; then
  /usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool false' "${legacy_agent}"
fi

/usr/libexec/PlistBuddy -c 'Print :Disabled' "${legacy_agent}" | rg -q '^true$'
/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "${legacy_agent}" | rg -q '^false$'

echo "Disabled and unloaded retired ADHD Companion autostart: ${legacy_agent}"
