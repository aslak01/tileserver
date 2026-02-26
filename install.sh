#!/usr/bin/env bash
# Install the tileserver as a systemd service that persists across logouts
# and starts automatically on boot.
#
# This builds the container image, installs a systemd unit, and starts it.
# Requires sudo for writing to /etc/systemd/system.
#
# Usage:
#     ./install.sh            # install and start
#     ./install.sh uninstall  # stop, disable, and remove the service

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IMAGE_NAME="tileserver"
CONTAINER_NAME="tileserver"
SERVICE_NAME="tileserver"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# ── Uninstall ────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "uninstall" ]]; then
  echo "==> Uninstalling ${SERVICE_NAME} service..."
  sudo systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  sudo systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  sudo rm -f "${SERVICE_FILE}"
  sudo systemctl daemon-reload
  echo "    Service removed."
  echo "    Container image and data in ${DATA_DIR}/ are untouched."
  exit 0
fi

# ── Preflight checks ────────────────────────────────────────────────────────

if ! command -v systemctl &>/dev/null; then
  echo "Error: systemd is required. Use ./run.sh for non-systemd environments." >&2
  exit 1
fi

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
  echo "Warning: ${DATA_DIR}/terrain.mbtiles not found — hillshade will not be available."
fi

if [[ ! -f "${DATA_DIR}/contours.mbtiles" ]]; then
  echo "Warning: ${DATA_DIR}/contours.mbtiles not found — contour lines will not be available."
fi

# ── Stop existing service if running ─────────────────────────────────────────

if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
  echo "==> Stopping existing ${SERVICE_NAME} service..."
  sudo systemctl stop "${SERVICE_NAME}"
fi

# ── Clean up existing container ──────────────────────────────────────────────

if "${CTR}" inspect "${CONTAINER_NAME}" &>/dev/null; then
  echo "==> Removing existing container ${CONTAINER_NAME}..."
  "${CTR}" rm -f "${CONTAINER_NAME}"
fi

# ── Build image ──────────────────────────────────────────────────────────────

echo "==> Building image..."
"${CTR}" build -t "${IMAGE_NAME}" -f "${SCRIPT_DIR}/Containerfile" "${SCRIPT_DIR}"

# ── Install systemd service ──────────────────────────────────────────────────

echo "==> Installing systemd service..."

CTR_PATH="$(command -v "${CTR}")"

VOLUME_FLAG="${DATA_DIR}:/data"
if [[ "${CTR}" == "podman" ]]; then
  VOLUME_FLAG="${VOLUME_FLAG}:z"
fi

# For rootless podman the service must run as the current user so it can
# access the image in the user's local container storage.
USER_LINES=""
if [[ "${CTR}" == "podman" ]]; then
  USER_LINES="User=$(whoami)
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u)"
fi

sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=Tileserver
After=network.target

[Service]
Type=simple
${USER_LINES}
ExecStartPre=-${CTR_PATH} rm -f ${CONTAINER_NAME}
ExecStart=${CTR_PATH} run --rm --name ${CONTAINER_NAME} -p 8080:8080 -v ${VOLUME_FLAG} ${IMAGE_NAME}
ExecStop=${CTR_PATH} stop -t 10 ${CONTAINER_NAME}
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}"

# ── Status ───────────────────────────────────────────────────────────────────

echo ""
echo "==> Tileserver installed and running!"
echo "    Vector tiles: http://localhost:8080/{z}/{x}/{y}.pbf"
echo "    Topo style:   http://localhost:8080/styles/topo/style.json"
echo "    Bright style: http://localhost:8080/styles/osm-bright/style.json"
echo "    Preview:      http://localhost:8080/"
echo ""
echo "    Status:    sudo systemctl status ${SERVICE_NAME}"
echo "    Logs:      sudo journalctl -u ${SERVICE_NAME} -f"
echo "    Restart:   sudo systemctl restart ${SERVICE_NAME}"
echo "    Stop:      sudo systemctl stop ${SERVICE_NAME}"
echo "    Uninstall: ./install.sh uninstall"
