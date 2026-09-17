#!/bin/sh
# Runs inside the GDAL container. Processes a chunk of SRTM tiles:
# gdal_contour -> shapefile -> ogr2ogr GeoJSONSeq -> nth_line annotation.
# Called by generate-contours.sh — not meant to be run directly.
#
# Usage (inside container): /worker.sh <chunk_file> <contour_interval> <index_interval>
#
# Container paths (from the WORK_DIR mount):
#   /work/srtm              — downloaded .hgt files
#   /work/contours_per_tile — GeoJSONL output
#   /work/failures          — per-chunk failure logs
set -e

CHUNK_FILE=$1
INTERVAL=$2
INDEX_INTERVAL=$3

SRTM_DIR=/work/srtm
OUT_DIR=/work/contours_per_tile
FAIL_DIR=/work/failures
CHUNK_LOG="${FAIL_DIR}/${CHUNK_FILE##*/}.log"

while read -r lat lon; do
  if [ "$lat" -ge 0 ]; then ns=$(printf "N%02d" "$lat"); else ns=$(printf "S%02d" "$(( -lat ))"); fi
  if [ "$lon" -ge 0 ]; then ew=$(printf "E%03d" "$lon"); else ew=$(printf "W%03d" "$(( -lon ))"); fi
  name="${ns}${ew}"

  hgt_file="${SRTM_DIR}/${name}.hgt"
  geojsonl="${OUT_DIR}/${name}.geojsonl"

  # Skip if already processed (resume) or no DEM data (ocean / failed download)
  if [ -s "${geojsonl}" ] || [ ! -f "${hgt_file}" ]; then
    continue
  fi

  shp_dir="${OUT_DIR}/${name}_shp"
  rm -rf "${shp_dir}"

  # Generate contours from the .hgt
  if ! gdal_contour -a height -i "${INTERVAL}" -f "ESRI Shapefile" \
      "${hgt_file}" "${shp_dir}" 2>/dev/null; then
    rm -rf "${shp_dir}"
    echo "${name} gdal_contour" >> "${CHUNK_LOG}"
    continue
  fi

  shp_file=$(find "${shp_dir}" -name '*.shp' | head -1)
  if [ -z "${shp_file}" ]; then
    rm -rf "${shp_dir}"
    echo "${name} no_shapefile" >> "${CHUNK_LOG}"
    continue
  fi

  # Convert to GeoJSONSeq (height > 0 filters sea-level artifacts)
  if ! ogr2ogr -f GeoJSONSeq -where "height > 0" "${geojsonl}" "${shp_file}" 2>/dev/null; then
    rm -f "${geojsonl}"
    rm -rf "${shp_dir}"
    echo "${name} ogr2ogr" >> "${CHUNK_LOG}"
    continue
  fi

  # Insert nth_line (styled differently for index contours) after height
  awk -F'"height":' -v idx="${INDEX_INTERVAL}" '{
    if (NF >= 2) {
      split($2, a, /[,}]/)
      h = int(a[1] + 0.5)
      if (h % 100 == 0) nth = 10
      else if (h % idx == 0) nth = 5
      else nth = 1
      sub(/"height":[^,}]+/, "&,\"nth_line\":" nth)
    }
    print
  }' "${geojsonl}" > "${geojsonl}.tmp" && mv "${geojsonl}.tmp" "${geojsonl}"

  rm -rf "${shp_dir}"
  echo "${name}"
done < "${CHUNK_FILE}"
