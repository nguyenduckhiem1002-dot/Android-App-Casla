#!/usr/bin/env bash
set -euo pipefail

bundle_id="${CASLA_IOS_BUNDLE_ID:-}"
team_id="${CASLA_IOS_TEAM_ID:-}"
problems=()

if [[ -z "$bundle_id" || "$bundle_id" == com.example.* ]]; then
  problems+=("CASLA_IOS_BUNDLE_ID is missing or still uses a com.example placeholder")
fi

if [[ -z "$team_id" ]]; then
  problems+=("CASLA_IOS_TEAM_ID is missing")
fi

if (( ${#problems[@]} > 0 )); then
  echo "iOS production identity is not configured:" >&2
  for problem in "${problems[@]}"; do
    echo " - $problem" >&2
  done
  exit 1
fi

echo "iOS production identity inputs are configured."
