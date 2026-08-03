#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
normal_scheme="${repo_root}/Dayflow/Dayflow.xcodeproj/xcshareddata/xcschemes/Dayflow.xcscheme"
project_file="${repo_root}/Dayflow/Dayflow.xcodeproj/project.pbxproj"

for required_file in "${normal_scheme}" "${project_file}"; do
  if [[ ! -f "${required_file}" ]]; then
    echo "Missing Xcode automation guard input: ${required_file}" >&2
    exit 2
  fi
done

ui_test_tree="${repo_root}/Dayflow/DayflowUITests"
if [[ -e "${repo_root}/Dayflow/Dayflow.xcodeproj/xcshareddata/xcschemes/DayflowUI.xcscheme" ]]; then
  echo "Dayflow must not ship an accidental UI-automation entry point." >&2
  exit 3
fi

if [[ -d "${ui_test_tree}" ]]; then
  leftover_ui_file="$(find "${ui_test_tree}" -type f -print -quit)"
  if [[ -n "${leftover_ui_file}" ]]; then
    echo "Dayflow must not retain UI-automation source: ${leftover_ui_file}" >&2
    exit 3
  fi
fi

if rg -q "DayflowUITests|DayflowUITests\.xctest|com\.apple\.product-type\.bundle\.ui-testing|runsForEachTargetApplicationUIConfiguration|XCTApplicationLaunchMetric|XCUIApplication|XCUIElement|XCUIScreen|testLaunchPerformance" \
  "${project_file}" "${normal_scheme}" "${repo_root}/Dayflow" "${repo_root}/DayflowTests" 2>/dev/null; then
  echo "The Dayflow project must not contain a UI-automation target or repeated launch test." >&2
  exit 4
fi

if ! rg -q "DayflowTests\.xctest" "${normal_scheme}"; then
  echo "The normal Dayflow scheme must retain the non-interactive unit-test target." >&2
  exit 5
fi

echo "Dayflow test-scheme automation is disabled: normal=unit tests, no UI target or scheme."
