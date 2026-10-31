#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    "Usage: $0 android|windows" \
    "" \
    "android requires:" \
    "  DAYFLOW_ANDROID_KEYSTORE" \
    "  DAYFLOW_ANDROID_KEYSTORE_PASSWORD" \
    "  DAYFLOW_ANDROID_KEY_ALIAS" \
    "  DAYFLOW_ANDROID_KEY_PASSWORD" \
    "" \
    "windows requires:" \
    "  DAYFLOW_WINDOWS_PFX" \
    "  DAYFLOW_WINDOWS_PFX_PASSWORD" \
    "  DAYFLOW_WINDOWS_PACKAGE_PUBLISHER" \
    "  DAYFLOW_WINDOWS_PACKAGE_VERSION"
}

require_value() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf 'Missing required release input: %s\n' "$name" >&2
    exit 1
  fi
}

require_file() {
  local name="$1"
  require_value "$name"
  if [[ ! -f "${!name}" ]]; then
    printf 'Release input is not a file: %s\n' "$name" >&2
    exit 1
  fi
}

case "${1:-}" in
  android)
    require_file DAYFLOW_ANDROID_KEYSTORE
    require_value DAYFLOW_ANDROID_KEYSTORE_PASSWORD
    require_value DAYFLOW_ANDROID_KEY_ALIAS
    require_value DAYFLOW_ANDROID_KEY_PASSWORD
    ;;
  windows)
    require_file DAYFLOW_WINDOWS_PFX
    require_value DAYFLOW_WINDOWS_PFX_PASSWORD
    require_value DAYFLOW_WINDOWS_PACKAGE_PUBLISHER
    require_value DAYFLOW_WINDOWS_PACKAGE_VERSION
    if [[ "${DAYFLOW_WINDOWS_PACKAGE_PUBLISHER}" == "CN=Dayflow" ]]; then
      printf '%s\n' "The development publisher CN=Dayflow cannot sign a release package." >&2
      exit 1
    fi
    if [[ ! "${DAYFLOW_WINDOWS_PACKAGE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s\n' "Windows package version must have four numeric components." >&2
      exit 1
    fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

printf 'Native %s release inputs are present without printing secret values.\n' "$1"
