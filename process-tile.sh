#!/usr/bin/env bash
# Process a single SRTM tile: download if needed, generate contour GeoJSONL.
# Called by generate-contours.sh via xargs — not meant to be run directly.
#
# Runs GDAL inside a container (ghcr.io/osgeo/gdal) since the system GDAL
# may lack drivers (SRTM HGT, GeoTIFF, Shapefile, etc.).
#
# Usage: process-tile.sh <srtm_dir> <contour_dir> <srtm_base> <interval> <index_interval> <ctr> <script_dir> <lat> <lon>

set -euo pipefail

SRTM_DIR=$1
CONTOUR_DIR=$2
SRTM_BASE=$3
CONTOUR_INTERVAL=$4
INDEX_INTERVAL=$5
CTR=$6
SCRIPT_DIR=$7
lat=$8
lon=$9

GDAL_IMAGE="ghcr.io/osgeo/gdal:alpine-small-latest"

# Format tile name
if (( lat >= 0 )); then ns=$(printf "N%02d" "$lat"); else ns=$(printf "S%02d" "$(( -lat ))"); fi
if (( lon >= 0 )); then ew=$(printf "E%03d" "$lon"); else ew=$(printf "W%03d" "$(( -lon ))"); fi
name="${ns}${ew}"

hgt_file="${SRTM_DIR}/${name}.hgt"
geojsonl="${CONTOUR_DIR}/${name}.geojsonl"

# Skip if already processed
if [[ -f "${geojsonl}" ]] && [[ -s "${geojsonl}" ]]; then
  exit 0
fi

# Download if needed
if [[ ! -f "${hgt_file}" ]]; then
  url="${SRTM_BASE}/${ns}/${name}.hgt.gz"
  tmp_gz="${hgt_file}.gz"
  if ! curl -sSf --max-time 15 -o "${tmp_gz}" "${url}" 2>/dev/null; then
    rm -f "${tmp_gz}"
    exit 0  # Ocean tile, no data
  fi
  gunzip -f "${tmp_gz}"
fi

# Run gdal_contour + ogr2ogr inside a container
# contour-worker.sh runs inside the container, avoiding shell quoting issues
rm -f "${geojsonl}"
${CTR} run --rm \
  -v "${SRTM_DIR}:/srtm:ro,z" \
  -v "${CONTOUR_DIR}:/out:z" \
  -v "${SCRIPT_DIR}/contour-worker.sh:/worker.sh:ro,z" \
  "${GDAL_IMAGE}" \
  /worker.sh "${name}" "${CONTOUR_INTERVAL}"

# Add nth_line field to each GeoJSON feature (runs on host, avoids SQL quoting)
if [[ -f "${geojsonl}" ]] && [[ -s "${geojsonl}" ]]; then
  tmp="${geojsonl}.tmp"
  awk -F'"height":' '{
    if (NF >= 2) {
      # Extract height value
      split($2, a, /[,}]/)
      h = int(a[1])
      if (h % 100 == 0) nth = 10
      else if (h % '"${INDEX_INTERVAL}"' == 0) nth = 5
      else nth = 1
      # Insert nth_line after height
      sub(/"height":[^,}]+/, "&,\"nth_line\":" nth)
    }
    print
  }' "${geojsonl}" > "${tmp}" && mv "${tmp}" "${geojsonl}"
  echo "${name}"
fi
