#!/usr/bin/env bash
# Process a single SRTM tile: download if needed, generate contour GeoJSONL.
# Called by generate-contours.sh via xargs — not meant to be run directly.
#
# Usage: process-tile.sh <srtm_dir> <contour_dir> <srtm_base> <interval> <index_interval> <lat> <lon>

set -euo pipefail

SRTM_DIR=$1
CONTOUR_DIR=$2
SRTM_BASE=$3
CONTOUR_INTERVAL=$4
INDEX_INTERVAL=$5
lat=$6
lon=$7

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

# Convert raw .hgt to GeoTIFF (GDAL may lack the SRTM HGT driver)
tif_file="${SRTM_DIR}/${name}.tif"
if [[ ! -f "${tif_file}" ]]; then
  # .hgt is raw signed 16-bit big-endian, 3601x3601 for 1-arcsecond
  # Build a VRT descriptor so GDAL can read it as raw binary
  vrt_file="${SRTM_DIR}/${name}.vrt"
  cat > "${vrt_file}" <<VRTEOF
<VRTDataset rasterXSize="3601" rasterYSize="3601">
  <SRS>EPSG:4326</SRS>
  <GeoTransform>${lon}.0, 0.000277777777778, 0.0, $(( lat + 1 )).0, 0.0, -0.000277777777778</GeoTransform>
  <VRTRasterBand dataType="Int16" band="1" subClass="VRTRawRasterBand">
    <SourceFilename relativeToVRT="1">${name}.hgt</SourceFilename>
    <ByteOrder>MSB</ByteOrder>
    <ImageOffset>0</ImageOffset>
    <PixelOffset>2</PixelOffset>
    <LineOffset>7202</LineOffset>
    <NoDataValue>-32768</NoDataValue>
  </VRTRasterBand>
</VRTDataset>
VRTEOF
  gdal_translate -q -of GTiff "${vrt_file}" "${tif_file}" 2>/dev/null || { rm -f "${vrt_file}" "${tif_file}"; exit 0; }
  rm -f "${vrt_file}"
fi

# Generate contours for this tile
tmp_shp_dir="${CONTOUR_DIR}/${name}_shp"
mkdir -p "${tmp_shp_dir}"

if ! gdal_contour -a height -i "${CONTOUR_INTERVAL}" -f "ESRI Shapefile" \
    "${tif_file}" "${tmp_shp_dir}" 2>/dev/null; then
  rm -rf "${tmp_shp_dir}"
  exit 0
fi

# Find the shapefile
shp_file=""
for f in "${tmp_shp_dir}"/*.shp; do
  if [[ -f "$f" ]]; then
    shp_file="$f"
    break
  fi
done

if [[ -z "${shp_file}" ]]; then
  rm -rf "${tmp_shp_dir}"
  exit 0
fi

layer_name=$(basename "${shp_file}" .shp)

# Convert to GeoJSONSeq with nth_line attribute for index line styling
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
  echo "${name}"
fi
