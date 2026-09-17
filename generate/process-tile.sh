#!/usr/bin/env bash
# Download a batch of SRTM tiles for contour generation.
# Called by generate-contours.sh via xargs — not meant to be run directly.
#
# Contour generation itself (gdal_contour/ogr2ogr) runs in a GDAL container;
# this script only downloads and decompresses the raw .hgt tiles on the host.
#
# Usage: process-tile.sh <srtm_dir> <fail_dir> <srtm_base> <lat> <lon> [lat lon ...]

set -euo pipefail

SRTM_DIR=$1
FAIL_DIR=$2
SRTM_BASE=$3
shift 3

if (( $# % 2 != 0 )); then
  echo "Error: expected lat/lon pairs, got an odd argument count." >&2
  exit 1
fi

download_one() {
  local lat=$1 lon=$2
  local ns ew name
  if (( lat >= 0 )); then ns=$(printf "N%02d" "$lat"); else ns=$(printf "S%02d" "$(( -lat ))"); fi
  if (( lon >= 0 )); then ew=$(printf "E%03d" "$lon"); else ew=$(printf "W%03d" "$(( -lon ))"); fi
  name="${ns}${ew}"

  local hgt_file="${SRTM_DIR}/${name}.hgt"

  # Skip if already downloaded (resume)
  if [[ -f "${hgt_file}" ]]; then
    return 0
  fi

  local url="${SRTM_BASE}/${ns}/${name}.hgt.gz"
  local tmp_gz="${hgt_file}.gz"
  local status
  status=$(curl -sS --max-time 15 -o "${tmp_gz}" -w '%{http_code}' "${url}" 2>/dev/null) || true

  if [[ "${status}" == "404" ]]; then
    rm -f "${tmp_gz}"
    return 0   # HTTP 404 — ocean tile, no data available (expected)
  fi
  if [[ "${status}" != "200" || ! -s "${tmp_gz}" ]]; then
    rm -f "${tmp_gz}"
    echo "${name} download(http=${status:-none})" >> "${FAIL_DIR}/dl_$$.txt"
    return 0
  fi
  if ! gunzip -f "${tmp_gz}"; then
    rm -f "${tmp_gz}" "${hgt_file}"
    echo "${name} gunzip" >> "${FAIL_DIR}/dl_$$.txt"
    return 0
  fi
  echo "${name}"
}

while (( $# >= 2 )); do
  download_one "$1" "$2"
  shift 2
done
