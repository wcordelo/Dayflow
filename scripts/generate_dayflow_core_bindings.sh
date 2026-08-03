#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core_dir="$repo_root/shared-core"
output_dir="$repo_root/clients/generated"
ios_binding_dir="$repo_root/clients/ios/Sources/DayflowCoreBindings"

mkdir -p "$output_dir/swift" "$output_dir/kotlin"
mkdir -p "$ios_binding_dir"

cargo build --manifest-path "$core_dir/Cargo.toml" --release --features uniffi

case "$(uname -s)" in
  Darwin)
    library_path="$core_dir/target/release/libdayflow_core.dylib"
    ;;
  Linux)
    library_path="$core_dir/target/release/libdayflow_core.so"
    ;;
  *)
    echo "Unsupported binding-generation host: $(uname -s)" >&2
    exit 1
    ;;
esac

if [[ ! -f "$library_path" ]]; then
  echo "Missing shared-core library at $library_path" >&2
  exit 1
fi

pushd "$core_dir" >/dev/null
cargo run --release \
  --features uniffi-bindings --bin uniffi-bindgen -- \
  generate --library "$library_path" \
  --language swift --out-dir "$output_dir/swift"
cargo run --release \
  --features uniffi-bindings --bin uniffi-bindgen -- \
  generate --library "$library_path" \
  --language kotlin --out-dir "$output_dir/kotlin"
popd >/dev/null

cp "$output_dir/swift/DayflowCore.swift" "$ios_binding_dir/DayflowCore.swift"

echo "Generated DayflowCore Swift and Kotlin bindings under $output_dir."
