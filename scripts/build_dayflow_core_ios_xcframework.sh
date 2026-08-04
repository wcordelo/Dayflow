#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${repo_root}/shared-core/Cargo.toml"
output_dir="${repo_root}/shared-core/dist"
framework="${output_dir}/DayflowCoreiOS.xcframework"
headers_dir="${output_dir}/uniffi-ios-headers"
simulator_library="${output_dir}/libdayflow_core_ios_simulator.a"
mac_library="${output_dir}/libdayflow_core_macos_universal.a"

echo "Running Dayflow safety preflight before creating the iOS XCFramework."
bash "${repo_root}/scripts/verify_dayflow_setup.sh"

targets=("aarch64-apple-darwin" "x86_64-apple-darwin" "aarch64-apple-ios" "aarch64-apple-ios-sim" "x86_64-apple-ios")
for target in "${targets[@]}"; do
  if ! rustup target list --installed | grep -Fxq "${target}"; then
    echo "Missing Rust target ${target}. Install it with: rustup target add ${target}" >&2
    exit 2
  fi
  cargo build --manifest-path "${manifest}" --release --features uniffi --target "${target}"
done

mkdir -p "${output_dir}" "${headers_dir}"
cp "${repo_root}/clients/generated/swift/DayflowCoreFFI.h" "${headers_dir}/DayflowCoreFFI.h"
cp "${repo_root}/clients/generated/swift/DayflowCoreFFI.modulemap" "${headers_dir}/module.modulemap"

lipo -create \
  "${repo_root}/shared-core/target/aarch64-apple-ios-sim/release/libdayflow_core.a" \
  "${repo_root}/shared-core/target/x86_64-apple-ios/release/libdayflow_core.a" \
  -output "${simulator_library}"

lipo -create \
  "${repo_root}/shared-core/target/aarch64-apple-darwin/release/libdayflow_core.a" \
  "${repo_root}/shared-core/target/x86_64-apple-darwin/release/libdayflow_core.a" \
  -output "${mac_library}"

if [[ -e "${framework}" ]]; then
  echo "Refusing to overwrite existing ${framework}; move it aside intentionally before rebuilding." >&2
  exit 3
fi

xcodebuild -create-xcframework \
  -library "${mac_library}" \
  -headers "${headers_dir}" \
  -library "${repo_root}/shared-core/target/aarch64-apple-ios/release/libdayflow_core.a" \
  -headers "${headers_dir}" \
  -library "${simulator_library}" \
  -headers "${headers_dir}" \
  -output "${framework}"

echo "Created ${framework}"
