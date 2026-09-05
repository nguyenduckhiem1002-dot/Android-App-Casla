#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
preflight="$root_dir/tool/release_preflight.sh"

base_env=(
  SAP_BASE_URL=https://gateway.example.invalid
  SAP_TRANSPORT_AUTH_MODE=gateway
  ENABLE_DEMO_DATA=false
  CASLA_IOS_BUNDLE_ID=com.casla.ci
  CASLA_IOS_TEAM_ID=CITEAM1234
)

run_preflight() {
  env -u SAP_BASIC_AUTH_USER -u SAP_BASIC_AUTH_PASSWORD \
    "${base_env[@]}" "$@" bash "$preflight" ios
}

expect_failure() {
  local case_name="$1"
  local expected="$2"
  shift 2

  set +e
  local output
  output=$(run_preflight "$@" 2>&1)
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "Expected release preflight case '$case_name' to fail." >&2
    exit 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    echo "Release preflight case '$case_name' failed for the wrong reason." >&2
    echo "$output" >&2
    exit 1
  fi
}

# The happy path uses only shell-level iOS identity/transport validation and can
# run on the Ubuntu CI host without certificates, Xcode or production secrets.
run_preflight >/dev/null

expect_failure \
  "non-HTTPS gateway" \
  "SAP_BASE_URL must use HTTPS" \
  SAP_BASE_URL=http://gateway.example.invalid

expect_failure \
  "direct Basic transport" \
  "SAP_TRANSPORT_AUTH_MODE must be gateway" \
  SAP_TRANSPORT_AUTH_MODE=basic

secret_sentinel="CASLA_PREFLIGHT_SECRET_SENTINEL"
set +e
secret_output=$(
  run_preflight SAP_BASIC_AUTH_USER="$secret_sentinel" 2>&1
)
secret_status=$?
set -e
if [[ "$secret_status" -eq 0 ]]; then
  echo "Release preflight accepted a production Basic credential." >&2
  exit 1
fi
if ! grep -Fq "SAP_BASIC_AUTH_USER/SAP_BASIC_AUTH_PASSWORD must not be present" <<<"$secret_output"; then
  echo "Release preflight rejected Basic credentials for the wrong reason." >&2
  echo "$secret_output" >&2
  exit 1
fi
if grep -Fq "$secret_sentinel" <<<"$secret_output"; then
  echo "Release preflight leaked a secret value into its output." >&2
  exit 1
fi

expect_failure \
  "demo data" \
  "ENABLE_DEMO_DATA must not be true" \
  ENABLE_DEMO_DATA=true

expect_failure \
  "placeholder iOS identity" \
  "CASLA_IOS_BUNDLE_ID still uses a com.example placeholder" \
  CASLA_IOS_BUNDLE_ID=com.example.casla

expect_failure \
  "missing team identity" \
  "CASLA_IOS_TEAM_ID is missing" \
  CASLA_IOS_TEAM_ID=

set +e
invalid_platform_output=$(bash "$preflight" windows 2>&1)
invalid_platform_status=$?
set -e
if [[ "$invalid_platform_status" -ne 2 ]]; then
  echo "Invalid platform must exit with status 2." >&2
  exit 1
fi
if ! grep -Fq "Usage:" <<<"$invalid_platform_output"; then
  echo "Invalid platform did not emit usage guidance." >&2
  exit 1
fi

echo "Release preflight regression tests passed."
