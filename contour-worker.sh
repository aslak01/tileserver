#!/bin/sh
# Runs inside the GDAL container. Called by process-tile.sh.
# Usage: contour-worker.sh <name> <interval>
set -e

name=$1
interval=$2

# Generate contours from .hgt
gdal_contour -a height -i "${interval}" -f "ESRI Shapefile" \
  "/srtm/${name}.hgt" "/out/${name}_shp" 2>/dev/null || exit 0

# Find the shapefile
shp_file=$(find "/out/${name}_shp" -name '*.shp' | head -1)
if [ -z "${shp_file}" ]; then
  rm -rf "/out/${name}_shp"
  exit 0
fi

# Plain convert to GeoJSONSeq (no SQL — nth_line added in post-processing)
ogr2ogr -f GeoJSONSeq \
  -where "height > 0" \
  "/out/${name}.geojsonl" "${shp_file}" 2>/dev/null || true

# Clean up intermediate shapefile
rm -rf "/out/${name}_shp"
