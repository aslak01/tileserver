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

check_data_files

# Rootless podman needs linger enabled so user-level containers keep running
# after logout (with multi-user.target boot start, the user manager must be up).
if [[ "${CTR}" == "podman" ]] && \
   ! loginctl show-user "$(whoami)" 2>/dev/null | grep -q "Linger=yes"; then
  echo "==> Enabling loginctl linger (containers survive logout)..."
  sudo loginctl enable-linger "$(whoami)"
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

# SELinux relabel (":z") is always applied so the image works on both
# SELinux and non-SELinux hosts.
VOLUME_FLAG="${DATA_DIR}:/data:z"

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
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
${USER_LINES}
ExecStartPre=-${CTR_PATH} rm -f "${CONTAINER_NAME}"
ExecStart=${CTR_PATH} run --rm --name "${CONTAINER_NAME}" -p 8080:8080 -v "${VOLUME_FLAG}" "${IMAGE_NAME}"
ExecStop=${CTR_PATH} stop -t 10 "${CONTAINER_NAME}"
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
