#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

contains_fixed_text() {
  local needle="$1"
  local path="$2"
  if command -v rg >/dev/null 2>&1; then
    rg --fixed-strings --quiet -- "$needle" "$path"
  elif [[ -d "$path" ]]; then
    grep -RFq -- "$needle" "$path"
  else
    grep -Fq -- "$needle" "$path"
  fi
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Missing product-surface boundary file: $path" >&2
    exit 1
  fi
}

require_text() {
  local needle="$1"
  local path="$2"
  if ! contains_fixed_text "$needle" "$path"; then
    echo "Product-surface boundary is missing '$needle' in $path" >&2
    exit 1
  fi
}

require_file "$repo_root/companion-web/README.md"
require_file "$repo_root/companion-web/apps/web/DEPRECATED.md"
require_file "$repo_root/companion-web/workers/api/src/index.ts"
require_file "$repo_root/companion-web/workers/api/README.md"
require_file "$repo_root/companion-web/workers/api/package.json"
require_file "$repo_root/companion-web/workers/api/wrangler.jsonc"
require_file "$repo_root/adhd-companion/DEPRECATED.md"
require_file "$repo_root/adhd-companion/package.json"
require_file "$repo_root/adhd-companion/scripts/deny-runtime.sh"
require_file "$repo_root/adhd-companion/src-tauri/tauri.conf.json"
require_file "$repo_root/docs/multi-device/MIGRATION_AND_DEPRECATION.md"
require_file "$repo_root/scripts/verify_dayflow_setup.sh"

# A previous local build could leave the retired companion executable outside
# Git's tracked files. The disabled launch agent used this exact path, so keep
# the stale app bundle out of the machine even when the repository is clean.
retired_app_bundle="$repo_root/adhd-companion/dist-app/ADHD Companion.app"
if [[ -e "$retired_app_bundle" ]]; then
  echo "Retired ADHD Companion app bundle must be moved out of the checkout: $retired_app_bundle" >&2
  echo "Move it to the macOS Trash, then rerun this guard before launching Dayflow." >&2
  exit 1
fi

# This repository previously carried a ten-minute Cursor/GitHub Bugbot agent
# for the retired companion PR. It is an external automation definition, not
# part of the unified Dayflow product or its read-only CI. Keep the exact
# paths blocked so a copied automation cannot silently return.
retired_automation_files=(
  "$repo_root/.cursor/automations/bugbot-autofix-adhd-companion.md"
  "$repo_root/.github/workflows/bugbot-autofix.yml"
)
for retired_automation_file in "${retired_automation_files[@]}"; do
  if [[ -e "$retired_automation_file" ]]; then
    echo "Retired external automation definition must be removed: $retired_automation_file" >&2
    exit 1
  fi
done

require_text "no longer a user-facing companion product" \
  "$repo_root/companion-web/README.md"
require_text "preserved compiled migration artifact" \
  "$repo_root/companion-web/README.md"
require_text "Do not deploy or extend this bundle" \
  "$repo_root/companion-web/apps/web/DEPRECATED.md"
require_text "historical Tauri prototype" \
  "$repo_root/adhd-companion/DEPRECATED.md"
require_text "Archived ADHD nudge companion prototype" \
  "$repo_root/adhd-companion/package.json"
require_text '"dev": "bash scripts/deny-runtime.sh dev"' \
  "$repo_root/adhd-companion/package.json"
require_text '"preview": "bash scripts/deny-runtime.sh preview"' \
  "$repo_root/adhd-companion/package.json"
require_text '"tauri": "bash scripts/deny-runtime.sh tauri"' \
  "$repo_root/adhd-companion/package.json"
require_text '"beforeDevCommand": "bash scripts/deny-runtime.sh tauri"' \
  "$repo_root/adhd-companion/src-tauri/tauri.conf.json"
require_text '"active": false' \
  "$repo_root/adhd-companion/src-tauri/tauri.conf.json"
require_text "opaque ciphertext only" \
  "$repo_root/companion-web/workers/api/README.md"
require_text '"name": "@dayflow/sync-relay"' \
  "$repo_root/companion-web/workers/api/package.json"
require_text '"main": "src/index.ts"' \
  "$repo_root/companion-web/workers/api/wrangler.jsonc"
require_text "DAYFLOW_PUSH_DISPATCHER" \
  "$repo_root/companion-web/workers/api/src/relay-do.ts"
require_text "buildPushWakeBatch" \
  "$repo_root/companion-web/workers/api/src/relay.ts"
require_text "registerPushToken" \
  "$repo_root/companion-web/workers/api/src/index.ts"
require_text "Remove local browser pairing and the Mac loopback bridge" \
  "$repo_root/docs/multi-device/MIGRATION_AND_DEPRECATION.md"
require_text 'LSMultipleInstancesProhibited' \
  "$repo_root/Dayflow/Dayflow/Info.plist"
require_text 'No app or automation was launched' \
  "$repo_root/scripts/verify_dayflow_setup.sh"
require_text '--evaluate-project' \
  "$repo_root/scripts/verify_dayflow_setup.sh"
require_text 'Xcode project evaluation is opt-in; no project-opening command was run' \
  "$repo_root/scripts/verify_dayflow_setup.sh"
require_text 'fail "macOS AutomationMode is already active outside Dayflow' \
  "$repo_root/scripts/verify_dayflow_setup.sh"
require_text 'Resolve the external AutomationMode session before continuing.' \
  "$repo_root/scripts/verify_dayflow_setup.sh"
require_text 'gradle --no-daemon :app:verifyDayflowCoreNative' \
  "$repo_root/scripts/verify_dayflow_setup.sh"
require_text 'Xcode CoreDevice plug-in aborts before Dayflow project evaluation' \
  "$repo_root/scripts/verify_dayflow_setup.sh"

# A previous local install registered the archived companion as a login
# LaunchAgent. It is not part of the repository, so only enforce the guard
# when this script is running on the Mac that can actually have that agent.
if [[ "$(uname -s)" == "Darwin" ]]; then
  legacy_agent="${HOME}/Library/LaunchAgents/ADHD Companion.plist"
  if [[ -f "${legacy_agent}" ]]; then
    disabled_value="$(/usr/libexec/PlistBuddy -c 'Print :Disabled' "${legacy_agent}" 2>/dev/null || true)"
    run_at_load_value="$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "${legacy_agent}" 2>/dev/null || true)"
    if [[ "${disabled_value}" != "true" || "${run_at_load_value}" == "true" ]]; then
      echo "The retired ADHD Companion launch agent is still enabled: ${legacy_agent}" >&2
      echo "Run scripts/disable_legacy_dayflow_autostart.sh before using Dayflow." >&2
      exit 1
    fi
  fi
fi

# The compiled browser bundle is intentionally preserved for migration review.
# Any new source file outside that artifact would silently recreate a web
# product surface and needs an explicit architecture review first.
unexpected_web_file="$(find "$repo_root/companion-web/apps/web" \
  -type f \
  -not -path "$repo_root/companion-web/apps/web/dist/*" \
  -not -name DEPRECATED.md \
  -print -quit)"
if [[ -n "$unexpected_web_file" ]]; then
  echo "Unexpected user-facing web source under companion-web/apps/web: $unexpected_web_file" >&2
  exit 1
fi

# The archived surfaces above remain in the repository as migration material,
# but native product code must not depend on them. Keep this denylist narrow:
# loopback AI providers are valid, while the old browser/Tauri ports and
# companion identifiers are not.
native_product_paths=(
  "$repo_root/Dayflow"
  "$repo_root/clients"
  "$repo_root/shared-core"
)
native_product_globs=(
  '*.swift'
  '*.m'
  '*.mm'
  '*.h'
  '*.kt'
  '*.kts'
  '*.java'
  '*.cs'
  '*.xaml'
  '*.rs'
  '*.toml'
  '*.json'
  '*.xml'
  '*.plist'
)

reject_native_product_reference() {
  local needle="$1"
  local match
  local rg_args=(
    --hidden
    --fixed-strings
    --line-number
    --glob '!**/.git/**'
    --glob '!**/.gradle/**'
    --glob '!**/build/**'
    --glob '!**/DerivedData/**'
  )
  for glob in "${native_product_globs[@]}"; do
    rg_args+=(--glob "$glob")
  done

  if command -v rg >/dev/null 2>&1; then
    match="$(rg "${rg_args[@]}" -- "$needle" "${native_product_paths[@]}" 2>/dev/null || true)"
  else
    match=""
    while IFS= read -r -d '' candidate; do
      candidate_match="$(grep -nHF -- "$needle" "$candidate" 2>/dev/null || true)"
      if [[ -n "$candidate_match" ]]; then
        match+="${candidate_match}"$'\n'
      fi
    done < <(
      find "${native_product_paths[@]}" \
        \( -path '*/.git' -o -path '*/.gradle' -o -path '*/build' -o -path '*/DerivedData' \) -prune -o \
        -type f \
        \( -name '*.swift' -o -name '*.m' -o -name '*.mm' -o -name '*.h' -o -name '*.kt' \
          -o -name '*.kts' -o -name '*.java' -o -name '*.cs' -o -name '*.xaml' -o -name '*.rs' \
          -o -name '*.toml' -o -name '*.json' -o -name '*.xml' -o -name '*.plist' \) \
        -print0
    )
  fi
  if [[ -n "$match" ]]; then
    echo "Legacy companion reference '$needle' found in native product code:" >&2
    echo "$match" >&2
    exit 1
  fi
}

reject_native_product_reference 'adhd-companion'
reject_native_product_reference 'ADHD Companion'
reject_native_product_reference 'DayflowCompanion'
reject_native_product_reference 'com.adhdcompanion.app'
reject_native_product_reference 'companion-web'
reject_native_product_reference 'localhost:5173'
reject_native_product_reference 'localhost:1420'
reject_native_product_reference 'tauri'
reject_native_product_reference '/usr/bin/osascript'
reject_native_product_reference 'NSAppleEventsUsageDescription'
reject_native_product_reference 'tell application "Ghostty"'
reject_native_product_reference 'NSAppleScript'

# The deployable Worker must be the opaque relay source. Older compiled output
# may still contain the retired companion API for migration review, but it is
# not an allowed deployment input.
forbidden_relay_source_terms=(
  'CompanionStateDO'
  'StoredState'
  '/api/mutate'
  '/api/state'
  'openrouter'
  'DEV_AUTH_BYPASS'
)
for needle in "${forbidden_relay_source_terms[@]}"; do
  if command -v rg >/dev/null 2>&1; then
    match="$(rg --fixed-strings --line-number -- "$needle" \
      "$repo_root/companion-web/workers/api/src" 2>/dev/null || true)"
  else
    match="$(grep -R -F -n -- "$needle" \
      "$repo_root/companion-web/workers/api/src" 2>/dev/null || true)"
  fi
  if [[ -n "$match" ]]; then
    echo "Retired companion relay term '$needle' found in deployable relay source:" >&2
    echo "$match" >&2
    exit 1
  fi
done

echo "Dayflow product-surface boundaries are consistent."
