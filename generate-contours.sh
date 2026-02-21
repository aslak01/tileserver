#!/usr/bin/env bash
set -euo pipefail

# Generate contour line vector tiles from SRTM DEM data and pack into MBTiles.
#
# Covers Norway bounding box at 10m contour intervals.
# Downloads and processes tiles in parallel for speed.
#
# Requires: curl, gdal_contour (GDAL), ogr2ogr (GDAL), tippecanoe
#
# Usage:
#     ./generate-contours.sh [output.mbtiles]
#
# The output defaults to data/contours.mbtiles if not specified.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ── Config ───────────────────────────────────────────────────────────────────

# Norway bounding box
BBOX_WEST=4
BBOX_SOUTH=57
BBOX_EAST=32
BBOX_NORTH=72

SRTM_BASE="https://elevation-tiles-prod.s3.amazonaws.com/skadi"

CONTOUR_INTERVAL=10   # meters between contour lines
INDEX_INTERVAL=50     # meters between index (bold) contour lines

MAX_ZOOM=14
MIN_ZOOM=9

JOBS=$(( $(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) ))

# ── Output path ──────────────────────────────────────────────────────────────

DB_PATH="${1:-${DATA_DIR}/contours.mbtiles}"
WORK_DIR="${DATA_DIR}/contours_work"
SRTM_DIR="${WORK_DIR}/srtm"
CONTOUR_DIR="${WORK_DIR}/contours_per_tile"

mkdir -p "${SRTM_DIR}" "${CONTOUR_DIR}"

# ── Dependency check ─────────────────────────────────────────────────────────

for cmd in curl tippecanoe; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '${cmd}' not found." >&2
    if [[ "$cmd" == "tippecanoe" ]]; then
      echo "  Install tippecanoe: see https://github.com/felt/tippecanoe" >&2
    fi
    exit 1
  fi
done

GDAL_IMAGE="ghcr.io/osgeo/gdal:alpine-small-latest"
echo "==> Pulling GDAL container image..."
${CTR} pull "${GDAL_IMAGE}" 2>/dev/null || true

PROCESS_TILE="${SCRIPT_DIR}/process-tile.sh"

# ── 1. Download and generate contours per tile (parallel) ────────────────────

echo "==> Downloading SRTM tiles and generating contours (${JOBS} parallel jobs)..."

# Build list of lat/lon pairs
tile_list="${WORK_DIR}/tile_list.txt"
: > "${tile_list}"
for lat in $(seq "${BBOX_SOUTH}" "$(( BBOX_NORTH - 1 ))"); do
  for lon in $(seq "${BBOX_WEST}" "$(( BBOX_EAST - 1 ))"); do
    echo "${lat} ${lon}" >> "${tile_list}"
  done
done

total=$(wc -l < "${tile_list}" | tr -d ' ')
echo "  Processing ${total} tiles with ${JOBS} parallel workers..."

# Process tiles in parallel — xargs appends "lat lon" from each line
xargs -P "${JOBS}" -L 1 \
  "${PROCESS_TILE}" "${SRTM_DIR}" "${CONTOUR_DIR}" "${SRTM_BASE}" "${CONTOUR_INTERVAL}" "${INDEX_INTERVAL}" "${CTR}" "${SCRIPT_DIR}" \
  < "${tile_list}"

echo ""

# Count results
geojsonl_count=$(find "${CONTOUR_DIR}" -name '*.geojsonl' | wc -l | tr -d ' ')
echo "  Generated contours for ${geojsonl_count} tiles (rest were ocean/empty)"

if [[ "${geojsonl_count}" -eq 0 ]]; then
  echo "Error: no contour data was generated." >&2
  exit 1
fi

# ── 2. Generate MBTiles with tippecanoe ──────────────────────────────────────

echo "==> Generating contour MBTiles with tippecanoe..."

if [[ -f "${DB_PATH}" ]]; then
  echo "  ${DB_PATH} already exists, skipping. Delete it to regenerate."
else
  # Pipe all per-tile GeoJSONL directly into tippecanoe (no intermediate file)
  find "${CONTOUR_DIR}" -name '*.geojsonl' -print0 \
    | xargs -0 cat \
    | tippecanoe \
      -o "${DB_PATH}" \
      --named-layer=contour:/dev/stdin \
      --minimum-zoom="${MIN_ZOOM}" \
      --maximum-zoom="${MAX_ZOOM}" \
      --simplification=2 \
      --detect-shared-borders \
      --no-tile-size-limit \
      --attribution="Contours derived from SRTM data" \
      --name="contours" \
      --force

  echo "  Generated: ${DB_PATH}"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "==> Done!"
echo "  Contour MBTiles: ${DB_PATH}"
echo ""
echo "  To save disk space, you can remove the work directory:"
echo "    rm -rf ${WORK_DIR}"
