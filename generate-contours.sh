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

for cmd in curl gdal_contour ogr2ogr tippecanoe; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '${cmd}' not found." >&2
    case "$cmd" in
      gdal_contour|ogr2ogr) echo "  Install GDAL: brew install gdal / apt install gdal-bin" >&2 ;;
      tippecanoe) echo "  Install tippecanoe: brew install tippecanoe / see https://github.com/felt/tippecanoe" >&2 ;;
    esac
    exit 1
  fi
done

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
  "${PROCESS_TILE}" "${SRTM_DIR}" "${CONTOUR_DIR}" "${SRTM_BASE}" "${CONTOUR_INTERVAL}" "${INDEX_INTERVAL}" \
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
  # Concatenate all per-tile GeoJSONL into one stream for tippecanoe
  MERGED="${WORK_DIR}/all_contours.geojsonl"
  cat "${CONTOUR_DIR}"/*.geojsonl > "${MERGED}"

  tippecanoe \
    -o "${DB_PATH}" \
    --named-layer=contour:"${MERGED}" \
    --minimum-zoom="${MIN_ZOOM}" \
    --maximum-zoom="${MAX_ZOOM}" \
    --simplification=2 \
    --detect-shared-borders \
    --no-tile-size-limit \
    --attribution="Contours derived from SRTM data" \
    --name="contours" \
    --force

  rm -f "${MERGED}"
  echo "  Generated: ${DB_PATH}"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "==> Done!"
echo "  Contour MBTiles: ${DB_PATH}"
echo ""
echo "  To save disk space, you can remove the work directory:"
echo "    rm -rf ${WORK_DIR}"
