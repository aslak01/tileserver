#!/usr/bin/env bash
# Build the tileserver RPM package.
#
# Usage:  ./packaging/build-rpm.sh
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
mkdir -p "${DEST}/generate/assets/styles/topo"
mkdir -p "${DEST}/server"
mkdir -p "${DEST}/packaging"

# Repo-root shared files
cp "${SCRIPT_DIR}/../common.sh"            "${DEST}/"
cp "${SCRIPT_DIR}/../setup-deps.sh"        "${DEST}/"

# Tile generation / scraping
cp "${SCRIPT_DIR}/../generate/generate-tiles.sh"        "${DEST}/generate/"
cp "${SCRIPT_DIR}/../generate/download-terrain.sh"     "${DEST}/generate/"
cp "${SCRIPT_DIR}/../generate/generate-contours.sh"    "${DEST}/generate/"
cp "${SCRIPT_DIR}/../generate/process-tile.sh"         "${DEST}/generate/"
cp "${SCRIPT_DIR}/../generate/contour-worker.sh"       "${DEST}/generate/"
cp "${SCRIPT_DIR}/../generate/Containerfile.tippecanoe" "${DEST}/generate/"
cp "${SCRIPT_DIR}/../generate/assets/styles/topo/style.json" \
   "${DEST}/generate/assets/styles/topo/"

# Tileserver / API serving
cp "${SCRIPT_DIR}/../server/Containerfile"          "${DEST}/server/"
cp "${SCRIPT_DIR}/../server/entrypoint.sh"          "${DEST}/server/"
cp "${SCRIPT_DIR}/../server/haproxy.cfg"            "${DEST}/server/"
cp "${SCRIPT_DIR}/../server/tileserver-config.json" "${DEST}/server/"

# Packaging
cp "${SCRIPT_DIR}/../packaging/tileserver.service"    "${DEST}/packaging/"
cp "${SCRIPT_DIR}/../packaging/tileserver-download"   "${DEST}/packaging/"

tar -czf ~/rpmbuild/SOURCES/"${TARBALL}" -C "${STAGING_DIR}" "${NAME}-${VERSION}"

# Copy spec file
cp "${SCRIPT_DIR}/tileserver.spec" ~/rpmbuild/SPECS/

# Build RPM
echo "==> Building RPM..."
rpmbuild -bb ~/rpmbuild/SPECS/tileserver.spec

echo ""
echo "==> Done! RPM packages:"
echo "    tileserver           (runtime: empty server, starts on install)"
echo "    tileserver-download  (generator: tileserver-download command)"
find ~/rpmbuild/RPMS -name '*.rpm' -print
