#!/usr/bin/env bash
# Process a single SRTM tile: download if needed, generate contour GeoJSONL.
# Called by generate-contours.sh via xargs — not meant to be run directly.
#
# Runs GDAL inside a container (ghcr.io/osgeo/gdal) since the system GDAL
# may lack drivers (SRTM HGT, GeoTIFF, Shapefile, etc.).
#
# Usage: process-tile.sh <srtm_dir> <contour_dir> <srtm_base> <interval> <index_interval> <ctr> <lat> <lon>

set -euo pipefail

SRTM_DIR=$1
CONTOUR_DIR=$2
SRTM_BASE=$3
CONTOUR_INTERVAL=$4
INDEX_INTERVAL=$5
CTR=$6
lat=$7
lon=$8

GDAL_IMAGE="ghcr.io/osgeo/gdal:alpine-small-latest"

# Format tile name
if (( lat >= 0 )); then ns=$(printf "N%02d" "$lat"); else ns=$(printf "S%02d" "$(( -lat ))"); fi
if (( lon >= 0 )); then ew=$(printf "E%03d" "$lon"); else ew=$(printf "W%03d" "$(( -lon ))"); fi
name="${ns}${ew}"

hgt_file="${SRTM_DIR}/${name}.hgt"
geojsonl="${CONTOUR_DIR}/${name}.geojsonl"

# Skip if already processed
if [[ -f "${geojsonl}" ]]; then
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
# Mount the srtm and contour dirs, work entirely inside /work
${CTR} run --rm \
  -v "${SRTM_DIR}:/srtm:ro,z" \
  -v "${CONTOUR_DIR}:/out:z" \
  "${GDAL_IMAGE}" \
  sh -c "
    set -e
    name='${name}'
    interval='${CONTOUR_INTERVAL}'
    index_interval='${INDEX_INTERVAL}'

    # Generate contours from .hgt (GDAL in this image has the SRTM driver)
    gdal_contour -a height -i \"\${interval}\" -f 'ESRI Shapefile' \
      /srtm/\${name}.hgt /out/\${name}_shp 2>/dev/null || exit 0

    # Find the shapefile
    shp_file=\$(ls /out/\${name}_shp/*.shp 2>/dev/null | head -1)
    if [ -z \"\${shp_file}\" ]; then
      rm -rf /out/\${name}_shp
      exit 0
    fi

    layer_name=\$(basename \"\${shp_file}\" .shp)

    # Convert to GeoJSONSeq with nth_line attribute
    ogr2ogr -f GeoJSONSeq \
      -t_srs EPSG:4326 \
      -sql \"SELECT height,
        CASE
          WHEN CAST(height AS INTEGER) % 100 = 0 THEN 10
          WHEN CAST(height AS INTEGER) % \${index_interval} = 0 THEN 5
          ELSE 1
        END AS nth_line,
        geometry
        FROM \\\"\${layer_name}\\\"
        WHERE height > 0\" \
      /out/\${name}.geojsonl \"\${shp_file}\" 2>/dev/null || true

    # Clean up intermediate shapefile
    rm -rf /out/\${name}_shp
  "

if [[ -f "${geojsonl}" ]]; then
  echo "${name}"
fi
