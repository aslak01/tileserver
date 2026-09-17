#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IMAGE_NAME="tileserver"
CONTAINER_NAME="tileserver"

# ── Preflight checks ────────────────────────────────────────────────────────

check_data_files

# ── Clean up existing container ──────────────────────────────────────────────

if "${CTR}" inspect "${CONTAINER_NAME}" &>/dev/null; then
  echo "==> Removing existing container ${CONTAINER_NAME}..."
  "${CTR}" rm -f "${CONTAINER_NAME}"
fi

# ── Build image ──────────────────────────────────────────────────────────────

echo "==> Building image..."
"${CTR}" build -t "${IMAGE_NAME}" -f "${SCRIPT_DIR}/Containerfile" "${SCRIPT_DIR}"

# ── Start container ──────────────────────────────────────────────────────────

# SELinux relabel (":z") is always applied so the image works on both
# SELinux and non-SELinux hosts.
VOLUME_FLAG="${DATA_DIR}:/data:z"

echo "==> Starting tileserver on port 8080..."
"${CTR}" run -d \
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
echo ""
echo "    For persistent deployment: ./install.sh"
