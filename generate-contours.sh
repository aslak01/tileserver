#!/usr/bin/env bash
set -euo pipefail

# Generate contour line vector tiles from SRTM DEM data and pack into MBTiles.
#
# Covers Norway bounding box at 10m contour intervals.
# Requires: curl, gdal_contour (GDAL), ogr2ogr (GDAL), tippecanoe, unzip
#
# Usage:
#     ./generate-contours.sh [output.mbtiles]
#
# The output defaults to data/contours.mbtiles if not specified.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ── Config ───────────────────────────────────────────────────────────────────

# Norway bounding box (same as download-terrain.sh)
BBOX_WEST=4
BBOX_SOUTH=57
BBOX_EAST=32
BBOX_NORTH=72

# SRTM tiles cover 1x1 degree each, named by SW corner: N60E010.hgt.zip
SRTM_BASE="https://elevation-tiles-prod.s3.amazonaws.com/skadi"

CONTOUR_INTERVAL=10   # meters between contour lines
INDEX_INTERVAL=50     # meters between index (bold) contour lines

MAX_ZOOM=14
MIN_ZOOM=9

# ── Output path ──────────────────────────────────────────────────────────────

DB_PATH="${1:-${DATA_DIR}/contours.mbtiles}"
WORK_DIR="${DATA_DIR}/contours_work"
SRTM_DIR="${WORK_DIR}/srtm"
CONTOUR_DIR="${WORK_DIR}/geojson"

mkdir -p "${SRTM_DIR}" "${CONTOUR_DIR}"

# ── Dependency check ─────────────────────────────────────────────────────────

for cmd in curl gdal_contour ogr2ogr tippecanoe unzip; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '${cmd}' not found." >&2
    case "$cmd" in
      gdal_contour|ogr2ogr) echo "  Install GDAL: brew install gdal / apt install gdal-bin" >&2 ;;
      tippecanoe) echo "  Install tippecanoe: brew install tippecanoe / see https://github.com/felt/tippecanoe" >&2 ;;
    esac
    exit 1
  fi
done

# ── 1. Download SRTM tiles ──────────────────────────────────────────────────

echo "==> Downloading SRTM elevation tiles..."

download_count=0
skip_count=0

for lat in $(seq "${BBOX_SOUTH}" "$(( BBOX_NORTH - 1 ))"); do
  for lon in $(seq "${BBOX_WEST}" "$(( BBOX_EAST - 1 ))"); do
    # Format tile name: N60E010 or S01W005
    if (( lat >= 0 )); then
      ns=$(printf "N%02d" "${lat}")
    else
      ns=$(printf "S%02d" "$(( -lat ))")
    fi
    if (( lon >= 0 )); then
      ew=$(printf "E%03d" "${lon}")
    else
      ew=$(printf "W%03d" "$(( -lon ))")
    fi

    tile_name="${ns}${ew}"
    hgt_file="${SRTM_DIR}/${tile_name}.hgt"
    zip_file="${SRTM_DIR}/${tile_name}.hgt.zip"

    if [[ -f "${hgt_file}" ]]; then
      skip_count=$(( skip_count + 1 ))
      continue
    fi

    url="${SRTM_BASE}/${ns}/${tile_name}.hgt.gz"

    if curl -sSf --max-time 30 -o "${hgt_file}.gz" "${url}" 2>/dev/null; then
      gunzip -f "${hgt_file}.gz"
      download_count=$(( download_count + 1 ))
      printf "\r  Downloaded: %d  Skipped: %d  Current: %s" \
        "${download_count}" "${skip_count}" "${tile_name}" >&2
    else
      # Not all tiles have data (ocean areas)
      rm -f "${hgt_file}.gz"
      skip_count=$(( skip_count + 1 ))
    fi
  done
done

echo ""
echo "  SRTM tiles: ${download_count} downloaded, ${skip_count} skipped/missing"

# ── 2. Merge SRTM tiles into a single VRT ───────────────────────────────────

echo "==> Merging SRTM tiles..."

MERGED_VRT="${WORK_DIR}/merged.vrt"
MERGED_TIF="${WORK_DIR}/merged.tif"

hgt_files=( "${SRTM_DIR}"/*.hgt )
if [[ ${#hgt_files[@]} -eq 0 ]]; then
  echo "Error: no SRTM .hgt files found in ${SRTM_DIR}" >&2
  exit 1
fi

gdalbuildvrt -overwrite "${MERGED_VRT}" "${SRTM_DIR}"/*.hgt

# Reproject to EPSG:4326 and clip to bbox (ensures clean edges)
gdalwarp -overwrite \
  -t_srs EPSG:4326 \
  -te "${BBOX_WEST}" "${BBOX_SOUTH}" "${BBOX_EAST}" "${BBOX_NORTH}" \
  -r bilinear \
  "${MERGED_VRT}" "${MERGED_TIF}"

echo "  Merged DEM: ${MERGED_TIF}"

# ── 3. Generate contour lines ────────────────────────────────────────────────

echo "==> Generating contour lines at ${CONTOUR_INTERVAL}m intervals..."

CONTOUR_SHP="${CONTOUR_DIR}/contours.shp"

if [[ -f "${CONTOUR_SHP}" ]]; then
  echo "  Contours already generated, skipping. Delete ${CONTOUR_DIR} to regenerate."
else
  gdal_contour \
    -a height \
    -i "${CONTOUR_INTERVAL}" \
    -f "ESRI Shapefile" \
    "${MERGED_TIF}" "${CONTOUR_DIR}"

  echo "  Generated: ${CONTOUR_SHP}"
fi

# ── 4. Convert to GeoJSON with nth_line attribute ────────────────────────────

echo "==> Converting to GeoJSON with index line markers..."

CONTOUR_GEOJSON="${WORK_DIR}/contours.geojson"

if [[ -f "${CONTOUR_GEOJSON}" ]]; then
  echo "  GeoJSON already exists, skipping."
else
  # Add nth_line field: 10 for 100m lines, 5 for 50m lines, 1 for others
  ogr2ogr -f GeoJSON \
    -t_srs EPSG:4326 \
    -sql "SELECT height,
      CASE
        WHEN CAST(height AS INTEGER) % 100 = 0 THEN 10
        WHEN CAST(height AS INTEGER) % ${INDEX_INTERVAL} = 0 THEN 5
        ELSE 1
      END AS nth_line,
      geometry
      FROM contours
      WHERE height > 0" \
    "${CONTOUR_GEOJSON}" "${CONTOUR_SHP}"

  echo "  Generated: ${CONTOUR_GEOJSON}"
fi

# ── 5. Generate MBTiles with tippecanoe ──────────────────────────────────────

echo "==> Generating contour MBTiles with tippecanoe..."

if [[ -f "${DB_PATH}" ]]; then
  echo "  ${DB_PATH} already exists, skipping. Delete it to regenerate."
else
  tippecanoe \
    -o "${DB_PATH}" \
    --named-layer=contour:"${CONTOUR_GEOJSON}" \
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

# ── 6. Cleanup (optional) ───────────────────────────────────────────────────

echo ""
echo "==> Done!"
echo "  Contour MBTiles: ${DB_PATH}"
echo ""
echo "  To save disk space, you can remove the work directory:"
echo "    rm -rf ${WORK_DIR}"
