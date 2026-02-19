#!/usr/bin/env bash
# Shared helpers for tileserver scripts.
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

set -euo pipefail

if [[ -z "${BASH_SOURCE[1]:-}" ]]; then
  echo "Error: common.sh must be sourced from a script, not directly." >&2
  return 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
export DATA_DIR="${SCRIPT_DIR}/data"

# ── Detect container runtime (podman or docker) ─────────────────────────────

if command -v podman &>/dev/null && podman info &>/dev/null; then
  CTR=podman
elif command -v docker &>/dev/null && docker info &>/dev/null; then
  CTR=docker
else
  echo "Error: no working container runtime found." >&2
  echo "Install and start Docker or Podman." >&2
  exit 1
fi
echo "==> Using container runtime: ${CTR}"
