#!/usr/bin/env bash
# Build the tileserver RPM package.
#
# Usage:  ./build-rpm.sh
#
# Requires: rpm-build (dnf install rpm-build)
# Output:   ~/rpmbuild/RPMS/noarch/tileserver-*.noarch.rpm

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="tileserver"
VERSION="1.0.0"
TARBALL="${NAME}-${VERSION}.tar.gz"

# Ensure rpmbuild is available
if ! command -v rpmbuild &>/dev/null; then
  echo "Error: rpmbuild not found. Install it with: sudo dnf install rpm-build" >&2
  exit 1
fi

# Set up rpmbuild directory structure
echo "==> Setting up rpmbuild tree..."
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# Create source tarball
# The tarball must extract to tileserver-1.0.0/ to match %setup -q
echo "==> Creating source tarball..."
STAGING_DIR=$(mktemp -d)
trap 'rm -rf "${STAGING_DIR}"' EXIT
DEST="${STAGING_DIR}/${NAME}-${VERSION}"
mkdir -p "${DEST}/data/styles/topo"

# Copy source files
cp "${SCRIPT_DIR}/generate-tiles.sh"      "${DEST}/"
cp "${SCRIPT_DIR}/generate-contours.sh"   "${DEST}/"
cp "${SCRIPT_DIR}/download-terrain.sh"    "${DEST}/"
cp "${SCRIPT_DIR}/process-tile.sh"        "${DEST}/"
cp "${SCRIPT_DIR}/contour-worker.sh"      "${DEST}/"
cp "${SCRIPT_DIR}/setup-deps.sh"          "${DEST}/"
cp "${SCRIPT_DIR}/common.sh"              "${DEST}/"
cp "${SCRIPT_DIR}/Containerfile"           "${DEST}/"
cp "${SCRIPT_DIR}/entrypoint.sh"           "${DEST}/"
cp "${SCRIPT_DIR}/haproxy.cfg"             "${DEST}/"
cp "${SCRIPT_DIR}/tileserver-config.json"  "${DEST}/"
cp "${SCRIPT_DIR}/tileserver.service"      "${DEST}/"
cp "${SCRIPT_DIR}/data/styles/topo/style.json" "${DEST}/data/styles/topo/"

tar -czf ~/rpmbuild/SOURCES/"${TARBALL}" -C "${STAGING_DIR}" "${NAME}-${VERSION}"

# Copy spec file
cp "${SCRIPT_DIR}/tileserver.spec" ~/rpmbuild/SPECS/

# Build RPM
echo "==> Building RPM..."
rpmbuild -bb ~/rpmbuild/SPECS/tileserver.spec

echo ""
echo "==> Done! RPM packages:"
find ~/rpmbuild/RPMS -name '*.rpm' -print
