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
#   - GDAL (gdal_contour, ogr2ogr, gdalbuildvrt, gdalwarp)
#   - tippecanoe (built from source)
#   - curl, jq, unzip, awk
#
# It also configures:
#   - /etc/subuid and /etc/subgid for rootless podman
#   - loginctl linger for container persistence across logouts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="$(whoami)"

# ── Helpers ──────────────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
warn()  { echo "  Warning: $*"; }
ok()    { echo "  OK: $*"; }

check_cmd() {
  command -v "$1" &>/dev/null
}

# ── 1. System packages ──────────────────────────────────────────────────────

info "Installing system packages..."

sudo dnf install -y \
  podman \
  slirp4netns \
  sqlite \
  gdal \
  gdal-libs \
  curl \
  jq \
  unzip \
  gawk \
  gcc-c++ \
  make \
  sqlite-devel \
  zlib-devel \
  git

# gdal-tools is a separate package on some Fedora/RHEL versions
if ! check_cmd gdal_contour; then
  info "Installing gdal-tools..."
  sudo dnf install -y gdal-tools 2>/dev/null || true
fi

# ── 2. Verify GDAL tools ────────────────────────────────────────────────────

info "Checking GDAL tools..."

for cmd in gdal_contour ogr2ogr gdalbuildvrt gdalwarp; do
  if check_cmd "$cmd"; then
    ok "$cmd found"
  else
    echo "Error: $cmd not found after installing gdal packages." >&2
    echo "  Try: sudo dnf install gdal-tools" >&2
    exit 1
  fi
done

# ── 3. Tippecanoe (build from source) ───────────────────────────────────────

if check_cmd tippecanoe; then
  ok "tippecanoe already installed ($(tippecanoe --version 2>&1 | head -1))"
else
  info "Building tippecanoe from source..."

  TIPPECANOE_DIR="${SCRIPT_DIR}/.tippecanoe-build"
  rm -rf "${TIPPECANOE_DIR}"
  git clone https://github.com/felt/tippecanoe.git "${TIPPECANOE_DIR}"
  make -C "${TIPPECANOE_DIR}" -j"$(nproc)"
  sudo make -C "${TIPPECANOE_DIR}" install
  rm -rf "${TIPPECANOE_DIR}"

  if check_cmd tippecanoe; then
    ok "tippecanoe installed"
  else
    echo "Error: tippecanoe build failed." >&2
    exit 1
  fi
fi

# ── 4. Rootless podman: subuid/subgid ───────────────────────────────────────

info "Configuring rootless podman for ${USER_NAME}..."

setup_subid() {
  local file=$1
  if grep -q "^${USER_NAME}:" "$file" 2>/dev/null; then
    ok "$file already configured for ${USER_NAME}"
  else
    info "Adding ${USER_NAME} to $file"
    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${USER_NAME}"
    ok "Added ${USER_NAME} to $file"
  fi
}

setup_subid /etc/subuid
setup_subid /etc/subgid

# ── 5. Rootless podman: apply changes ───────────────────────────────────────

info "Applying podman user namespace changes..."
podman system migrate
ok "podman system migrate done"

# ── 6. Enable linger (containers survive logout) ────────────────────────────

info "Enabling loginctl linger for ${USER_NAME}..."

if loginctl show-user "${USER_NAME}" 2>/dev/null | grep -q "Linger=yes"; then
  ok "linger already enabled"
else
  sudo loginctl enable-linger "${USER_NAME}"
  ok "linger enabled"
fi

# ── 7. Verify everything works ──────────────────────────────────────────────

info "Verifying setup..."

echo ""
echo "  Tool versions:"
echo "    podman:       $(podman --version)"
echo "    sqlite3:      $(sqlite3 --version | awk '{print $1}')"
echo "    gdal_contour: $(gdal_contour --version 2>&1 | head -1)"
echo "    tippecanoe:   $(tippecanoe --version 2>&1 | head -1)"
echo "    curl:         $(curl --version | head -1 | awk '{print $2}')"
echo "    jq:           $(jq --version)"
echo ""

# Quick podman smoke test
if podman run --rm docker.io/library/alpine echo "podman works" &>/dev/null; then
  ok "podman rootless container test passed"
else
  warn "podman rootless test failed — you may need to log out and back in"
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
echo "    1. ./generate-tiles.sh    # download OSM data, generate tiles + contours"
echo "    2. ./run.sh               # start the tileserver"
