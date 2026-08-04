#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_tests=false
evaluate_project=false

for argument in "$@"; do
  case "${argument}" in
    --run-tests)
      run_tests=true
      ;;
    --evaluate-project)
      evaluate_project=true
      ;;
    *)
      echo "Usage: bash scripts/verify_dayflow_setup.sh [--run-tests] [--evaluate-project]" >&2
      exit 2
      ;;
  esac
done

failures=0
warnings=0

pass() {
  printf 'PASS  %s\n' "$1"
}

warn() {
  printf 'WARN  %s\n' "$1"
  warnings=$((warnings + 1))
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_file() {
  local file_path="$1"
  if [[ -f "${file_path}" ]]; then
    pass "found ${file_path#"${repo_root}/"}"
  else
    fail "missing ${file_path#"${repo_root}/"}"
  fi
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "the Dayflow Mac setup requires macOS; this host is $(uname -s)"
else
  pass "macOS host"
fi

require_file "${repo_root}/Dayflow/Dayflow.xcodeproj/project.pbxproj"
require_file "${repo_root}/Dayflow/Dayflow.xcodeproj/xcshareddata/xcschemes/Dayflow.xcscheme"
require_file "${repo_root}/Dayflow/Dayflow/Info.plist"
require_file "${repo_root}/shared-core/Cargo.toml"

automation_writer="$(ps -axo pid=,comm=,command= 2>/dev/null | awk '
  $2 !~ /(^|\/)(rg|awk)$/ &&
  $0 ~ /\/System\/Library\/PrivateFrameworks\/AutomationMode\.framework\/automationmode-writer/ { print }
' || true)"
if [[ -n "${automation_writer}" ]]; then
  fail "macOS AutomationMode is already active outside Dayflow; clear it with Control-Option-Command-Period or restart macOS before launching Dayflow"
  printf '%s\n' "${automation_writer}" >&2
  echo "No app or automation was launched. Resolve the external AutomationMode session before continuing." >&2
  exit 1
else
  pass "no external AutomationMode writer detected"
fi

if command -v xcode-select >/dev/null 2>&1 && xcode_path="$(xcode-select -p 2>/dev/null)" && [[ -d "${xcode_path}" ]]; then
  pass "Xcode developer directory: ${xcode_path}"
else
  fail "Xcode developer directory is not configured"
fi

if command -v xcodebuild >/dev/null 2>&1; then
  xcode_version="$(xcodebuild -version 2>/dev/null | head -1 || true)"
  if [[ -n "${xcode_version}" ]]; then
    pass "${xcode_version}"
  else
    fail "xcodebuild is present but did not report a version"
  fi

  if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    pass "Xcode first-launch tasks and license state"
  else
    fail "Xcode first-launch tasks or license state need attention; run xcodebuild -runFirstLaunch manually"
  fi

  if [[ "${evaluate_project}" == true ]]; then
    project_evaluates=false
    if [[ -x /usr/bin/perl ]]; then
      # Perl converts a child signal into an ordinary exit status, keeping a
      # CoreDevice plug-in abort from making this diagnostic itself look like a
      # second shell crash.
      if /usr/bin/perl -e 'system @ARGV; exit(($? & 127) ? 1 : (($? >> 8) & 255))' -- \
        xcodebuild -list -project "${repo_root}/Dayflow/Dayflow.xcodeproj" >/dev/null 2>&1; then
        project_evaluates=true
      fi
    elif xcodebuild -list -project "${repo_root}/Dayflow/Dayflow.xcodeproj" >/dev/null 2>&1; then
      project_evaluates=true
    fi
    if [[ "${project_evaluates}" == true ]]; then
      pass "Xcode can evaluate the Dayflow project"
    else
      xcode_crash_report="$(ls -t /Library/Logs/DiagnosticReports/xcodebuild-*.ips 2>/dev/null | head -1 || true)"
      if [[ -n "${xcode_crash_report}" ]] && rg -q 'DVTCoreDeviceLocator|xpc_add_bundle' "${xcode_crash_report}" 2>/dev/null; then
        fail "Xcode CoreDevice plug-in aborts before Dayflow project evaluation; inspect ${xcode_crash_report} (license state is healthy)"
      else
        fail "Xcode cannot evaluate the Dayflow project on this host; inspect /Library/Logs/DiagnosticReports/xcodebuild-*.ips (this is separate from license state)"
      fi
    fi
  else
    pass "Xcode project evaluation is opt-in; no project-opening command was run"
  fi
else
  fail "xcodebuild is not installed"
fi

if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "${repo_root}/Dayflow/Dayflow/Info.plist" >/dev/null 2>&1; then
    pass "Dayflow Info.plist is valid"
  else
    fail "Dayflow Info.plist is invalid"
  fi
  multi_instance_value="$(plutil -extract LSMultipleInstancesProhibited raw -o - "${repo_root}/Dayflow/Dayflow/Info.plist" 2>/dev/null || true)"
  if [[ "${multi_instance_value}" == "true" ]]; then
    pass "Launch Services single-instance guard"
  else
    fail "LSMultipleInstancesProhibited is not true"
  fi
else
  fail "plutil is not available"
fi

bash "${repo_root}/scripts/verify_dayflow_test_scheme.sh" >/dev/null \
  && pass "non-interactive Xcode test scheme" \
  || fail "non-interactive Xcode test scheme"
bash "${repo_root}/scripts/verify_dayflow_product_surfaces.sh" >/dev/null \
  && pass "native product-surface boundaries" \
  || fail "native product-surface boundaries"
bash "${repo_root}/scripts/verify_dayflow_native_contracts.sh" >/dev/null \
  && pass "native client contracts" \
  || fail "native client contracts"

legacy_agent="${HOME}/Library/LaunchAgents/ADHD Companion.plist"
if [[ -f "${legacy_agent}" ]]; then
  disabled_value="$(/usr/libexec/PlistBuddy -c 'Print :Disabled' "${legacy_agent}" 2>/dev/null || true)"
  run_at_load_value="$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "${legacy_agent}" 2>/dev/null || true)"
  if [[ "${disabled_value}" == "true" && "${run_at_load_value}" != "true" ]]; then
    pass "retired ADHD Companion launch agent is disabled"
  else
    fail "retired ADHD Companion launch agent is still enabled; run scripts/disable_legacy_dayflow_autostart.sh"
  fi
else
  pass "no retired ADHD Companion launch agent"
fi

runtime_matches="$(ps -axo pid=,comm=,command= 2>/dev/null | awk '
  $2 !~ /(^|\/)(rg|awk)$/ &&
  ($0 ~ /\/Applications\/Dayflow\.app\/Contents\/MacOS\/Dayflow/ ||
   $0 ~ /\/companion-web\/(apps\/web|workers\/api)/ ||
   $0 ~ /ADHD Companion/) { print }
' || true)"
if [[ -n "${runtime_matches}" ]]; then
  fail "a Dayflow/retired companion runtime is already running"
  printf '%s\n' "${runtime_matches}" >&2
else
  pass "no Dayflow or retired companion runtime is running"
fi

android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "${android_sdk}" ]]; then
  for android_sdk_candidate in \
    /opt/homebrew/share/android-commandlinetools \
    /usr/local/share/android-commandlinetools \
    "${HOME}/Library/Android/sdk"; do
    if [[ -d "${android_sdk_candidate}/platforms" && -d "${android_sdk_candidate}/build-tools" ]]; then
      android_sdk="${android_sdk_candidate}"
      break
    fi
  done
fi
if [[ -n "${android_sdk}" && -d "${android_sdk}" ]]; then
  pass "Android SDK is configured: ${android_sdk}"
else
  warn "Android SDK is not configured on this Mac; Android/ChromeOS builds require a target host or CI"
fi

if [[ "${run_tests}" == true ]]; then
  if cargo test --manifest-path "${repo_root}/shared-core/Cargo.toml" --all-features >/dev/null; then
    pass "shared Rust core tests"
  else
    fail "shared Rust core tests"
  fi
  if swift test --package-path "${repo_root}/clients/ios" >/dev/null; then
    pass "iOS host package tests"
  else
    fail "iOS host package tests"
  fi
  if (cd "${repo_root}/companion-web/workers/api" && npm run check >/dev/null); then
    pass "opaque relay tests"
  else
    fail "opaque relay tests"
  fi
  if [[ -n "${android_sdk}" && -d "${android_sdk}" && "$(command -v gradle || true)" != "" ]]; then
    if (
      cd "${repo_root}/clients/android" &&
      ANDROID_HOME="${android_sdk}" \
      ANDROID_SDK_ROOT="${android_sdk}" \
      gradle --no-daemon :app:verifyDayflowCoreNative >/dev/null
    ); then
      if (
        cd "${repo_root}/clients/android" &&
        ANDROID_HOME="${android_sdk}" \
        ANDROID_SDK_ROOT="${android_sdk}" \
        gradle --no-daemon :app:testDebugUnitTest >/dev/null
      ); then
        pass "Android JVM unit tests"
      else
        fail "Android JVM unit tests"
      fi
    else
      fail "Android Rust ABI libraries are missing or stale; run scripts/build_dayflow_core_android.sh before Android tests"
    fi
  elif [[ -z "${android_sdk}" ]]; then
    warn "Android JVM tests skipped because no Android SDK was found"
  else
    warn "Android JVM tests skipped because gradle is not installed"
  fi
fi

printf '\nSetup preflight complete: %d failure(s), %d warning(s).\n' "${failures}" "${warnings}"
if (( failures > 0 )); then
  echo "No app or automation was launched. Resolve the failures above before running Dayflow." >&2
  exit 1
fi
echo "No app or automation was launched by this preflight."
