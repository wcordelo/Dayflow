#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${repo_root}/shared-core/Cargo.toml"
output_dir="${repo_root}/shared-core/dist"
framework="${output_dir}/DayflowCore.xcframework"
universal_library="${output_dir}/libdayflow_core_universal.a"

echo "Running Dayflow safety preflight before creating the Mac XCFramework."
bash "${repo_root}/scripts/verify_dayflow_setup.sh"

targets=("aarch64-apple-darwin" "x86_64-apple-darwin")

for target in "${targets[@]}"; do
  if ! rustup target list --installed | grep -Fxq "${target}"; then
    echo "Missing Rust target ${target}. Install it with: rustup target add ${target}" >&2
    exit 2
  fi
  cargo build --manifest-path "${manifest}" --release --features uniffi --target "${target}"
done

# Xcode 26 treats two standalone static libraries with the same module as
# equivalent slices. Build one fat macOS library instead; it still contains
# both native architectures and produces a valid single macOS XCFramework
# slice for Xcode's linker.
mkdir -p "${output_dir}"
lipo -create \
  "${repo_root}/shared-core/target/aarch64-apple-darwin/release/libdayflow_core.a" \
  "${repo_root}/shared-core/target/x86_64-apple-darwin/release/libdayflow_core.a" \
  -output "${universal_library}"

if [[ -e "${framework}" ]]; then
  echo "Refusing to overwrite existing ${framework}; remove it intentionally before rebuilding." >&2
  exit 3
fi

xcodebuild -create-xcframework \
  -library "${universal_library}" \
  -headers "${repo_root}/shared-core/include" \
  -output "${framework}"

echo "Created ${framework}"
