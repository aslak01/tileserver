#!/usr/bin/env bash
# Shared helpers for tileserver scripts.
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

set -euo pipefail

# Idempotence: skip re-detection when sourced multiple times in one shell.
if [[ -n "${_TILESERVER_COMMON_LOADED:-}" ]]; then
  return 0
fi
_TILESERVER_COMMON_LOADED=1

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

# ── Container images used by the build scripts ──────────────────────────────

export GDAL_IMAGE="ghcr.io/osgeo/gdal:alpine-small-3.12.2"
export TIPPECANOE_VERSION="2.79.0"
export TIPPECANOE_IMAGE="localhost/tileserver-tippecanoe:${TIPPECANOE_VERSION}"

# Files created by containers should be owned by the invoking user.
# Rootless podman maps container root to the host user, so no flag is needed;
# docker needs an explicit --user.
if [[ "${CTR}" == "podman" ]]; then
  CTR_USER_FLAGS=()
else
  CTR_USER_FLAGS=(--user "$(id -u):$(id -g)")
fi

# ── Data file preflight checks (shared by run.sh and install.sh) ────────────

check_data_files() {
  if [[ ! -f "${DATA_DIR}/norway.mbtiles" ]]; then
    echo "Error: ${DATA_DIR}/norway.mbtiles not found."
    echo "Run ./generate-tiles.sh first to create the MBTiles file."
    exit 1
  fi

  if [[ ! -f "${DATA_DIR}/styles/osm-bright/style.json" ]]; then
    echo "Error: Style not found at ${DATA_DIR}/styles/osm-bright/style.json"
    echo "Run ./generate-tiles.sh first to download styles."
    exit 1
  fi

  if [[ ! -f "${DATA_DIR}/styles/topo/style.json" ]]; then
    echo "Warning: Topo style not found at ${DATA_DIR}/styles/topo/style.json"
  fi

  if [[ ! -f "${DATA_DIR}/terrain.mbtiles" ]]; then
    echo "Warning: ${DATA_DIR}/terrain.mbtiles not found — hillshade terrain will not be available."
    echo "Run: ./download-terrain.sh ${DATA_DIR}/terrain.mbtiles"
  fi

  if [[ ! -f "${DATA_DIR}/contours.mbtiles" ]]; then
    echo "Warning: ${DATA_DIR}/contours.mbtiles not found — contour lines will not be available."
    echo "Run: ./generate-contours.sh ${DATA_DIR}/contours.mbtiles"
  fi
}
