#!/usr/bin/env bash
set -euo pipefail

platform="${1:-all}"
case "$platform" in
  all|android|ios) ;;
  *) echo "Usage: $0 [all|android|ios]" >&2; exit 2 ;;
esac

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
problems=()

require_value() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "${value//[[:space:]]/}" ]]; then
    problems+=("$name is missing")
  fi
}

require_value SAP_BASE_URL
if [[ -n "${SAP_BASE_URL:-}" && "${SAP_BASE_URL}" != https://* ]]; then
  problems+=("SAP_BASE_URL must use HTTPS")
fi
if [[ "${SAP_TRANSPORT_AUTH_MODE:-}" != "gateway" ]]; then
  problems+=("SAP_TRANSPORT_AUTH_MODE must be gateway")
fi
if [[ -n "${SAP_BASIC_AUTH_USER:-}" || -n "${SAP_BASIC_AUTH_PASSWORD:-}" ]]; then
  problems+=("SAP_BASIC_AUTH_USER/SAP_BASIC_AUTH_PASSWORD must not be present")
fi
if [[ "${ENABLE_DEMO_DATA:-false}" == "true" ]]; then
  problems+=("ENABLE_DEMO_DATA must not be true")
fi

if [[ "$platform" == "all" || "$platform" == "android" ]]; then
  require_value CASLA_ANDROID_APPLICATION_ID
  require_value CASLA_ANDROID_STORE_FILE
  require_value CASLA_ANDROID_STORE_PASSWORD
  require_value CASLA_ANDROID_KEY_ALIAS
  require_value CASLA_ANDROID_KEY_PASSWORD
  if [[ "${CASLA_ANDROID_APPLICATION_ID:-}" == com.example.* ]]; then
    problems+=("CASLA_ANDROID_APPLICATION_ID still uses a com.example placeholder")
  fi
  if [[ -n "${CASLA_ANDROID_STORE_FILE:-}" && ! -f "${CASLA_ANDROID_STORE_FILE}" ]]; then
    problems+=("CASLA_ANDROID_STORE_FILE does not exist")
  fi
fi

if [[ "$platform" == "all" || "$platform" == "ios" ]]; then
  require_value CASLA_IOS_BUNDLE_ID
  require_value CASLA_IOS_TEAM_ID
  if [[ "${CASLA_IOS_BUNDLE_ID:-}" == com.example.* ]]; then
    problems+=("CASLA_IOS_BUNDLE_ID still uses a com.example placeholder")
  fi
fi

if (( ${#problems[@]} > 0 )); then
  echo "Release preflight failed:" >&2
  for problem in "${problems[@]}"; do
    echo " - $problem" >&2
  done
  exit 1
fi

export ENABLE_DEMO_DATA=false
export SAP_TRANSPORT_AUTH_MODE=gateway
bash "$root_dir/tool/verify_transport_security.sh"

if [[ "$platform" == "all" || "$platform" == "android" ]]; then
  gateway_define="$(printf 'SAP_TRANSPORT_AUTH_MODE=gateway' | base64 | tr -d '\n')"
  demo_define="$(printf 'ENABLE_DEMO_DATA=false' | base64 | tr -d '\n')"
  (
    cd "$root_dir/android"
    ./gradlew -Pdart-defines="$gateway_define,$demo_define" :app:verifyCaslaSigning
  )
fi

if [[ "$platform" == "all" || "$platform" == "ios" ]]; then
  bash "$root_dir/ios/verify_production_identity.sh"
fi

echo "Release preflight passed for $platform without printing secret values."
