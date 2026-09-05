#!/usr/bin/env bash
set -euo pipefail

mode="${SAP_TRANSPORT_AUTH_MODE:-}"
basic_user="${SAP_BASIC_AUTH_USER:-}"
basic_password="${SAP_BASIC_AUTH_PASSWORD:-}"
problems=()

if [[ "${mode,,}" != "gateway" ]]; then
  problems+=("SAP_TRANSPORT_AUTH_MODE must be gateway for a production release")
fi

if [[ -n "$basic_user" || -n "$basic_password" ]]; then
  problems+=("SAP_BASIC_AUTH_USER/SAP_BASIC_AUTH_PASSWORD must not be embedded in a production release")
fi

if (( ${#problems[@]} > 0 )); then
  echo "Production transport security is not configured:" >&2
  for problem in "${problems[@]}"; do
    echo " - $problem" >&2
  done
  exit 1
fi

echo "Production transport security inputs are configured."
