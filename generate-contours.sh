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

# ── Helper: format tile name from lat/lon ────────────────────────────────────

tile_name() {
  local lat=$1 lon=$2
  local ns ew
  if (( lat >= 0 )); then ns=$(printf "N%02d" "$lat"); else ns=$(printf "S%02d" "$(( -lat ))"); fi
  if (( lon >= 0 )); then ew=$(printf "E%03d" "$lon"); else ew=$(printf "W%03d" "$(( -lon ))"); fi
  echo "${ns}${ew}"
}

# ── Helper: download + contour a single tile ────────────────────────────────

process_tile() {
  local lat=$1 lon=$2
  local name
  name=$(tile_name "$lat" "$lon")
  local ns="${name:0:3}"
  local hgt_file="${SRTM_DIR}/${name}.hgt"
  local geojsonl="${CONTOUR_DIR}/${name}.geojsonl"

  # Skip if already processed
  if [[ -f "${geojsonl}" ]]; then
    return 0
  fi

  # Download if needed
  if [[ ! -f "${hgt_file}" ]]; then
    local url="${SRTM_BASE}/${ns}/${name}.hgt.gz"
    local tmp_gz="${hgt_file}.gz"
    if ! curl -sSf --max-time 15 -o "${tmp_gz}" "${url}" 2>/dev/null; then
      rm -f "${tmp_gz}"
      return 0  # Ocean tile, no data
    fi
    gunzip -f "${tmp_gz}"
  fi

  # Generate contours for this tile
  local tmp_shp_dir="${CONTOUR_DIR}/${name}_shp"
  mkdir -p "${tmp_shp_dir}"

  gdal_contour \
    -a height \
    -i "${CONTOUR_INTERVAL}" \
    -f "ESRI Shapefile" \
    "${hgt_file}" "${tmp_shp_dir}" 2>/dev/null || { rm -rf "${tmp_shp_dir}"; return 0; }

  local shp_file="${tmp_shp_dir}/contour.shp"
  if [[ ! -f "${shp_file}" ]]; then
    # gdal_contour may name it differently
    shp_file=$(ls "${tmp_shp_dir}"/*.shp 2>/dev/null | head -1)
    if [[ -z "${shp_file}" ]]; then
      rm -rf "${tmp_shp_dir}"
      return 0
    fi
  fi

  local layer_name
  layer_name=$(basename "${shp_file}" .shp)

  # Convert to GeoJSON lines with nth_line attribute
  ogr2ogr -f GeoJSONSeq \
    -t_srs EPSG:4326 \
    -sql "SELECT height,
      CASE
        WHEN CAST(height AS INTEGER) % 100 = 0 THEN 10
        WHEN CAST(height AS INTEGER) % ${INDEX_INTERVAL} = 0 THEN 5
        ELSE 1
      END AS nth_line,
      geometry
      FROM \"${layer_name}\"
      WHERE height > 0" \
    "${geojsonl}" "${shp_file}" 2>/dev/null || true

  # Clean up intermediate shapefile
  rm -rf "${tmp_shp_dir}"

  if [[ -f "${geojsonl}" ]]; then
    printf "." >&2
  fi
}

export -f process_tile tile_name
export SRTM_DIR SRTM_BASE CONTOUR_DIR CONTOUR_INTERVAL INDEX_INTERVAL

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

# Process tiles in parallel
xargs -P "${JOBS}" -L 1 bash -c 'process_tile $0 $1' < "${tile_list}"

echo ""

# Count results
geojsonl_count=$(ls "${CONTOUR_DIR}"/*.geojsonl 2>/dev/null | wc -l | tr -d ' ')
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
