#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_file="${repo_root}/Dayflow/Dayflow.xcodeproj"

echo "Running Dayflow safety preflight before the real-database Xcode check."
bash "${repo_root}/scripts/verify_dayflow_setup.sh"

temporary_root="${TMPDIR:-/tmp}"
temporary_root="${temporary_root%/}"
cleanup_derived_data=0
if [[ -n "${DAYFLOW_REAL_DB_DERIVED_DATA:-}" ]]; then
  derived_data="${DAYFLOW_REAL_DB_DERIVED_DATA}"
else
  # A failed xcodebuild can leave several gigabytes of module caches and
  # package artifacts behind. Use a unique directory and clean it even when
  # the host Xcode process aborts before producing the test bundle.
  derived_data="$(mktemp -d "${temporary_root}/dayflow-real-db-migration-build.XXXXXX")"
  cleanup_derived_data=1
fi

cleanup() {
  if [[ "${cleanup_derived_data}" == "1" \
    && "${DAYFLOW_KEEP_REAL_DB_DERIVED_DATA:-0}" != "1" \
    && "${derived_data}" == "${temporary_root}/dayflow-real-db-migration-build."* ]]; then
    find "${derived_data}" -depth -delete
  fi
}
trap cleanup EXIT

if [[ "${cleanup_derived_data}" == "1" ]]; then
  echo "Using disposable real-database build directory: ${derived_data}"
else
  echo "Using caller-provided real-database build directory: ${derived_data}"
fi

xcodebuild -quiet \
  -project "${project_file}" \
  -scheme Dayflow \
  -destination 'platform=macOS' \
  -derivedDataPath "${derived_data}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY='' \
  build-for-testing

products_dir="${derived_data}/Build/Products/Debug"
app_dir="${products_dir}/Dayflow.app"
test_bundle="${app_dir}/Contents/PlugIns/DayflowTests.xctest"

if [[ ! -d "${test_bundle}" ]]; then
  echo "Dayflow test bundle was not produced at ${test_bundle}" >&2
  exit 2
fi

# xcodebuild does not forward arbitrary shell environment variables to the
# hosted test process. Run the already-built bundle directly so the opt-in
# guard is actually enabled and no normal test run can touch the live DB.
DAYFLOW_REAL_DB_CHECK=1 \
  DYLD_FRAMEWORK_PATH="${app_dir}/Contents/Frameworks:${products_dir}:${products_dir}/PackageFrameworks" \
  DYLD_LIBRARY_PATH="${app_dir}/Contents/MacOS" \
  xcrun xctest \
  -XCTest 'DayflowMultiDeviceTests/testOptInRepresentativeRealDatabaseMigrationIsSafeAndIdempotent' \
  "${test_bundle}"
