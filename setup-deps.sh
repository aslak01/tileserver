#!/usr/bin/env bash
set -euo pipefail

# Install all dependencies needed to build and run the tileserver.
#
# Targets RHEL/Fedora (dnf). Run as your normal user — the script
# will call sudo where needed.
#
# What it installs:
#   - podman + rootless networking (slirp4netns)
#   - sqlite3 (with readfile support)
#   - curl, jq, unzip, awk
#
# What it builds (as OCI images — no host toolchain needed):
#   - GDAL container image (ghcr.io/osgeo/gdal) for contour generation
#   - tippecanoe container image (Containerfile.tippecanoe)
#
# It also configures:
#   - /etc/subuid and /etc/subgid for rootless podman
#   - loginctl linger for container persistence across logouts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="$(whoami)"

# ── 1. System packages ──────────────────────────────────────────────────────

info()  { echo "==> $*"; }
warn()  { echo "  Warning: $*"; }
ok()    { echo "  OK: $*"; }

check_cmd() {
  command -v "$1" &>/dev/null
}

info "Installing system packages..."

sudo dnf install -y \
  podman \
  slirp4netns \
  sqlite \
  curl \
  jq \
  unzip \
  gawk

# ── 2. Container runtime + shared constants ─────────────────────────────────

# Sources the container runtime detection and image constants from common.sh.
# Done after the package install so podman is guaranteed to be present.
source "${SCRIPT_DIR}/common.sh"

# ── 3. GDAL container image ─────────────────────────────────────────────────

info "Pulling GDAL container image (${GDAL_IMAGE})..."
"${CTR}" pull "${GDAL_IMAGE}"
ok "GDAL image pulled"

# ── 4. Tippecanoe (OCI image) ───────────────────────────────────────────────

if "${CTR}" image inspect "${TIPPECANOE_IMAGE}" &>/dev/null; then
  ok "tippecanoe image already built (${TIPPECANOE_IMAGE})"
else
  info "Building tippecanoe container image (${TIPPECANOE_VERSION})..."
  "${CTR}" build -t "${TIPPECANOE_IMAGE}" \
    -f "${SCRIPT_DIR}/generate/Containerfile.tippecanoe" "${SCRIPT_DIR}/generate"
  ok "tippecanoe image built"
fi

# ── 5. Rootless podman: subuid/subgid ───────────────────────────────────────

info "Configuring rootless podman for ${USER_NAME}..."

if grep -q "^${USER_NAME}:" /etc/subuid 2>/dev/null && \
   grep -q "^${USER_NAME}:" /etc/subgid 2>/dev/null; then
  ok "subuid/subgid already configured for ${USER_NAME}"
else
  info "Adding ${USER_NAME} to /etc/subuid and /etc/subgid"
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${USER_NAME}"
  ok "Added ${USER_NAME} to subuid/subgid"
fi

# ── 6. Rootless podman: apply changes ───────────────────────────────────────

info "Applying podman user namespace changes..."
podman system migrate
ok "podman system migrate done"

# ── 7. Enable linger (containers survive logout) ────────────────────────────

info "Enabling loginctl linger for ${USER_NAME}..."

if loginctl show-user "${USER_NAME}" 2>/dev/null | grep -q "Linger=yes"; then
  ok "linger already enabled"
else
  sudo loginctl enable-linger "${USER_NAME}"
  ok "linger enabled"
fi

# ── 8. Verify everything works ──────────────────────────────────────────────

info "Verifying setup..."

echo ""
echo "  Tool versions:"
echo "    podman:       $(podman --version)"
echo "    sqlite3:      $(sqlite3 --version | awk '{print $1}')"
echo "    curl:         $(curl --version | head -1 | awk '{print $2}')"
echo "    jq:           $(jq --version)"
echo ""

# Quick podman + GDAL smoke test
if podman run --rm "${GDAL_IMAGE}" gdalinfo --version 2>/dev/null; then
  ok "podman + GDAL container test passed"
else
  warn "podman GDAL test failed — you may need to log out and back in"
fi

# tippecanoe smoke test
if podman run --rm "${TIPPECANOE_IMAGE}" --version 2>/dev/null; then
  ok "tippecanoe container test passed"
else
  warn "tippecanoe container test failed"
fi

# sqlite3 readfile check
if sqlite3 ":memory:" "SELECT typeof(readfile('/dev/null'));" &>/dev/null; then
  ok "sqlite3 readfile() support confirmed"
else
  warn "sqlite3 readfile() not available — terrain download may not work"
fi

echo ""
info "All dependencies installed!"
echo ""
echo "  Next steps:"
echo "    1. ./generate/generate-tiles.sh    # download OSM data, generate tiles + contours"
echo "    2. ./server/run.sh                 # start the tileserver"
