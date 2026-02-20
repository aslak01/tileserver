#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IMAGE_NAME="tileserver"
CONTAINER_NAME="tileserver"

# ── Preflight checks ────────────────────────────────────────────────────────

if [[ ! -f "${DATA_DIR}/norway.mbtiles" ]]; then
  echo "Error: ${DATA_DIR}/norway.mbtiles not found."
  echo "Run ./generate-tiles.sh first to create the MBTiles file."
  exit 1
fi

if [[ ! -f "${DATA_DIR}/styles/osm-bright/style.json" ]]; then
  echo "Error: Style not found at ${DATA_DIR}/styles/osm-bright/style.json"
  echo "Run ./generate-tiles.sh first to download styles."
  exit 1
fi

if [[ ! -f "${DATA_DIR}/styles/topo/style.json" ]]; then
  echo "Warning: Topo style not found at ${DATA_DIR}/styles/topo/style.json"
fi

if [[ ! -f "${DATA_DIR}/terrain.mbtiles" ]]; then
  echo "Warning: ${DATA_DIR}/terrain.mbtiles not found — hillshade terrain will not be available."
  echo "Run: ./download-terrain.sh ${DATA_DIR}/terrain.mbtiles"
fi

if [[ ! -f "${DATA_DIR}/contours.mbtiles" ]]; then
  echo "Warning: ${DATA_DIR}/contours.mbtiles not found — contour lines will not be available."
  echo "Run: ./generate-contours.sh ${DATA_DIR}/contours.mbtiles"
fi

# ── Clean up existing container ──────────────────────────────────────────────

if ${CTR} inspect "${CONTAINER_NAME}" &>/dev/null; then
  echo "==> Removing existing container ${CONTAINER_NAME}..."
  ${CTR} rm -f "${CONTAINER_NAME}"
fi

# ── Build image ──────────────────────────────────────────────────────────────

echo "==> Building image..."
${CTR} build -t "${IMAGE_NAME}" -f "${SCRIPT_DIR}/Containerfile" "${SCRIPT_DIR}"

# ── Start container ──────────────────────────────────────────────────────────

VOLUME_FLAG="${DATA_DIR}:/data"
if [[ "${CTR}" == "podman" ]]; then
  VOLUME_FLAG="${VOLUME_FLAG}:z"
fi

echo "==> Starting tileserver on port 8080..."
${CTR} run -d \
  --name "${CONTAINER_NAME}" \
  -p 8080:8080 \
  -v "${VOLUME_FLAG}" \
  "${IMAGE_NAME}"

# ── Status ───────────────────────────────────────────────────────────────────

echo ""
echo "==> Container is running!"
echo "    Vector tiles: http://localhost:8080/{z}/{x}/{y}.pbf"
echo "    Topo style:   http://localhost:8080/styles/topo/style.json"
echo "    Bright style: http://localhost:8080/styles/osm-bright/style.json"
echo "    Preview:      http://localhost:8080/"
echo "    Test tile:    curl -sS -o test.pbf http://localhost:8080/10/546/287.pbf"
echo ""
echo "    Logs:   ${CTR} logs ${CONTAINER_NAME}"
echo "    Stop:   ${CTR} rm -f ${CONTAINER_NAME}"
