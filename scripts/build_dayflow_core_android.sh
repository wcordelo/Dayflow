#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core_dir="${repo_root}/shared-core"
output_dir="${repo_root}/clients/generated/android/jniLibs"
ndk_root="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
api_level="${ANDROID_API_LEVEL:-29}"

if [[ -z "${ndk_root}" || ! -d "${ndk_root}" ]]; then
  echo "ANDROID_NDK_HOME or ANDROID_NDK_ROOT must point to an installed Android NDK." >&2
  exit 2
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) host_tag="darwin-arm64" ;;
  Darwin-x86_64) host_tag="darwin-x86_64" ;;
  Linux-x86_64) host_tag="linux-x86_64" ;;
  Linux-aarch64) host_tag="linux-aarch64" ;;
  MINGW*|MSYS*|CYGWIN*) host_tag="windows-x86_64" ;;
  *)
    echo "Unsupported Android NDK host: $(uname -s)-$(uname -m)" >&2
    exit 2
    ;;
esac

toolchain_dir="${ndk_root}/toolchains/llvm/prebuilt/${host_tag}/bin"
if [[ ! -d "${toolchain_dir}" ]]; then
  # Some macOS NDK distributions still ship only the x86_64 host tools. They
  # remain runnable through Rosetta on Apple Silicon, so use them when the
  # native host directory is absent instead of failing before Cargo starts.
  case "${host_tag}" in
    darwin-arm64) fallback_host_tag="darwin-x86_64" ;;
    darwin-x86_64) fallback_host_tag="darwin-arm64" ;;
    *) fallback_host_tag="" ;;
  esac
  if [[ -n "${fallback_host_tag}" && -d "${ndk_root}/toolchains/llvm/prebuilt/${fallback_host_tag}/bin" ]]; then
    host_tag="${fallback_host_tag}"
    toolchain_dir="${ndk_root}/toolchains/llvm/prebuilt/${host_tag}/bin"
  fi
fi
if [[ ! -d "${toolchain_dir}" ]]; then
  echo "Android NDK LLVM toolchain not found at ${toolchain_dir}." >&2
  exit 2
fi

export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${toolchain_dir}/aarch64-linux-android${api_level}-clang"
export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER="${toolchain_dir}/armv7a-linux-androideabi${api_level}-clang"
export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="${toolchain_dir}/x86_64-linux-android${api_level}-clang"

targets=("aarch64-linux-android" "armv7-linux-androideabi" "x86_64-linux-android")
for target in "${targets[@]}"; do
  if ! rustup target list --installed | grep -Fxq "${target}"; then
    echo "Missing Rust target ${target}. Install it with: rustup target add ${target}" >&2
    exit 2
  fi
done

for linker in \
  "${CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER}" \
  "${CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER}" \
  "${CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER}"; do
  if [[ ! -x "${linker}" ]]; then
    echo "Android NDK linker not found or not executable: ${linker}" >&2
    exit 2
  fi
done

for target in "${targets[@]}"; do
  cargo build \
    --manifest-path "${core_dir}/Cargo.toml" \
    --release \
    --features uniffi \
    --target "${target}"
done

abi_for_target() {
  case "$1" in
    aarch64-linux-android) echo "arm64-v8a" ;;
    armv7-linux-androideabi) echo "armeabi-v7a" ;;
    x86_64-linux-android) echo "x86_64" ;;
    *)
      echo "Unknown Android Rust target: $1" >&2
      return 2
      ;;
  esac
}

for target in "${targets[@]}"; do
  abi="$(abi_for_target "${target}")"
  library="${core_dir}/target/${target}/release/libdayflow_core.so"
  if [[ ! -f "${library}" ]]; then
    echo "Rust Android library was not produced: ${library}" >&2
    exit 3
  fi
  mkdir -p "${output_dir}/${abi}"
  cp "${library}" "${output_dir}/${abi}/libdayflow_core.so"
done

echo "Built Android Rust libraries under ${output_dir}."
