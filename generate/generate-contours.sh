#!/usr/bin/env bash
set -euo pipefail

# Generate contour line vector tiles from SRTM DEM data and pack into MBTiles.
#
# Covers Norway bounding box at 10m contour intervals.
# Downloads and processes tiles in parallel for speed. GDAL and tippecanoe
# run inside OCI containers, so the host only needs curl and a container
# runtime (no host toolchain).
#
# Per-tile failures (network, corrupt data) are logged to
# contours_work/failures.log and skipped — re-run this script to retry them;
# completed tiles are skipped on resume.
#
# Requires: curl, podman or docker
#
# Usage:
#     ./generate/generate-contours.sh [output.mbtiles]
#
# The output defaults to data/contours.mbtiles if not specified.

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

# ── Config ───────────────────────────────────────────────────────────────────

# Norway bounding box (mainland only, not Svalbard).
# SRTM data above ~71°N is poor quality / unavailable, so contours are limited
# to mainland Norway. Terrain/hillshade (download-terrain.sh) extends to 81.5°N
# since the Terrarium raster tiles are usable at those latitudes.
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

TILES_PER_XARGS_JOB=8 # tiles per host download process

# ── Output paths ─────────────────────────────────────────────────────────────

DB_PATH="${1:-${DATA_DIR}/contours.mbtiles}"
WORK_DIR="${DATA_DIR}/contours_work"
SRTM_DIR="${WORK_DIR}/srtm"
CONTOUR_DIR="${WORK_DIR}/contours_per_tile"
FAIL_DIR="${WORK_DIR}/failures"
CHUNK_DIR="${WORK_DIR}/chunks"
FAIL_LOG="${WORK_DIR}/failures.log"

mkdir -p "${SRTM_DIR}" "${CONTOUR_DIR}" "${FAIL_DIR}" "${CHUNK_DIR}"

# ── Dependency check ─────────────────────────────────────────────────────────
# GDAL and tippecanoe run inside containers; the host only needs curl.

if ! command -v curl &>/dev/null; then
  echo "Error: required command 'curl' not found." >&2
  exit 1
fi

# ── Container images ─────────────────────────────────────────────────────────

echo "==> Pulling GDAL container image..."
"${CTR}" pull "${GDAL_IMAGE}" 2>/dev/null || true

if ! "${CTR}" image inspect "${TIPPECANOE_IMAGE}" &>/dev/null; then
  echo "==> Building tippecanoe container image (${TIPPECANOE_IMAGE})..."
  "${CTR}" build -t "${TIPPECANOE_IMAGE}" \
    -f "${SCRIPT_DIR}/Containerfile.tippecanoe" "${SCRIPT_DIR}"
fi

PROCESS_TILE="${SCRIPT_DIR}/process-tile.sh"
WORKER="${SCRIPT_DIR}/contour-worker.sh"

# ── 1. Build tile list ───────────────────────────────────────────────────────

tile_list="${WORK_DIR}/tile_list.txt"
: > "${tile_list}"
for lat in $(seq "${BBOX_SOUTH}" "$(( BBOX_NORTH - 1 ))"); do
  for lon in $(seq "${BBOX_WEST}" "$(( BBOX_EAST - 1 ))"); do
    echo "${lat} ${lon}" >> "${tile_list}"
  done
done

total=$(wc -l < "${tile_list}" | tr -d ' ')

# ── 2. Download SRTM tiles (host, parallel curl) ─────────────────────────────

echo "==> Downloading SRTM tiles (${JOBS} parallel jobs, ${total} tiles)..."

xargs -P "${JOBS}" -L "${TILES_PER_XARGS_JOB}" \
  "${PROCESS_TILE}" "${SRTM_DIR}" "${FAIL_DIR}" "${SRTM_BASE}" \
  < "${tile_list}"

downloaded=$(find "${SRTM_DIR}" -name '*.hgt' 2>/dev/null | wc -l | tr -d ' ')
echo "  Downloaded ${downloaded} SRTM tiles (rest were ocean or failed — see failures.log)"

# ── 3. Generate contours in JOBS parallel containers ─────────────────────────

echo "==> Generating contours in ${JOBS} parallel containers..."

rm -f "${CHUNK_DIR}"/chunk_*
split -n l/"${JOBS}" -d "${tile_list}" "${CHUNK_DIR}/chunk_"

chunk_pids=()
for chunk in "${CHUNK_DIR}"/chunk_*; do
  [[ -s "${chunk}" ]] || continue
  cname="$(basename "${chunk}")"
  "${CTR}" run --rm ${CTR_USER_FLAGS[@]+"${CTR_USER_FLAGS[@]}"} \
    -v "${WORK_DIR}:/work:z" \
    -v "${WORKER}:/worker.sh:ro,z" \
    "${GDAL_IMAGE}" \
    /worker.sh "/work/chunks/${cname}" "${CONTOUR_INTERVAL}" "${INDEX_INTERVAL}" &
  chunk_pids+=($!)
done

run_failed=0
for pid in "${chunk_pids[@]}"; do
  if ! wait "${pid}"; then
    echo "  WARNING: a contour worker container failed; its remaining tiles are skipped." >&2
    run_failed=1
  fi
done

# ── 4. Failure summary (log + warn — re-run to retry) ────────────────────────

cat "${FAIL_DIR}"/* >> "${FAIL_LOG}" 2>/dev/null || true
rm -rf "${FAIL_DIR}" "${CHUNK_DIR}"

failed_count=$(wc -l < "${FAIL_LOG}" | tr -d ' ')
done_count=$(find "${CONTOUR_DIR}" -name '*.geojsonl' -size +0c | wc -l | tr -d ' ')
other=$(( total - done_count - failed_count ))
if (( other < 0 )); then other=0; fi

echo ""
echo "  Generated contours for ${done_count} tiles; ${other} ocean/no-data; ${failed_count} failed"
if [[ "${failed_count}" -gt 0 || "${run_failed}" -ne 0 ]]; then
  echo "  WARNING: failed tiles are listed in ${FAIL_LOG}"
  echo "  Re-run this script to retry them (completed tiles are skipped)."
fi

if [[ "${done_count}" -eq 0 ]]; then
  echo "Error: no contour data was generated." >&2
  exit 1
fi

# Free disk space — SRTM files are no longer needed once geojsonl exists
if [[ -d "${SRTM_DIR}" ]]; then
  echo "  Removing SRTM source files to free disk space..."
  rm -rf "${SRTM_DIR}"
fi

# ── 5. Generate MBTiles with tippecanoe (in container) ───────────────────────

echo "==> Generating contour MBTiles with tippecanoe..."

if [[ -f "${DB_PATH}" ]]; then
  echo "  ${DB_PATH} already exists, skipping. Delete it to regenerate."
else
  # Collect all non-empty geojsonl files
  mapfile -t geojsonl_files < <(find "${CONTOUR_DIR}" -name '*.geojsonl' -size +0c -print | sort)

  echo "  Tiling ${#geojsonl_files[@]} files..."

  # Map host paths to container paths (WORK_DIR is mounted at /work)
  container_files=()
  for f in "${geojsonl_files[@]}"; do
    container_files+=("${f/#"${WORK_DIR}"//work}")
  done

  out_name="$(basename "${DB_PATH}")"
  out_dir="$(dirname "${DB_PATH}")"

  mkdir -p "${WORK_DIR}/tmp"

  # tippecanoe reads GeoJSONSeq natively; -t redirects its temp files into the
  # mounted work dir (keeps /tmp out of the picture on small-tmpfs hosts).
  "${CTR}" run --rm ${CTR_USER_FLAGS[@]+"${CTR_USER_FLAGS[@]}"} \
    -v "${WORK_DIR}:/work:z" \
    -v "${out_dir}:/out:z" \
    "${TIPPECANOE_IMAGE}" \
    -o "/out/${out_name}" \
    -t /work/tmp \
    -l contour \
    --minimum-zoom="${MIN_ZOOM}" \
    --maximum-zoom="${MAX_ZOOM}" \
    --simplification=2 \
    --detect-shared-borders \
    --no-tile-size-limit \
    --attribution="Contours derived from SRTM data" \
    --name="contours" \
    --force \
    "${container_files[@]}"

  rm -rf "${WORK_DIR}/tmp"

  echo "  Generated: ${DB_PATH}"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "==> Done!"
echo "  Contour MBTiles: ${DB_PATH}"
echo ""
echo "  To save disk space, you can remove the work directory:"
echo "    rm -rf ${WORK_DIR}"
