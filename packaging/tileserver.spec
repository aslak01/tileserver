Name:           tileserver
Version:        1.0.0
Release:        1%{?dist}
Summary:        Containerized vector tile server with HAProxy caching

License:        MIT
URL:            https://github.com/example/tileserver
BuildArch:      noarch

Source0:        %{name}-%{version}.tar.gz

BuildRequires:  systemd-rpm-macros

# Runtime-only: the server serves from /opt/tileserver/data and needs
# nothing else on the host besides a container runtime.
Requires:       podman
Recommends:     %{name}-download

%description
A containerized tile server for serving vector map tiles, terrain data,
and contour lines. Uses tileserver-gl behind an HAProxy caching proxy.

The service starts immediately on port 8080. Without tile data it returns
503; install the %{name}-download package and run 'tileserver-download'
to populate the data directory, then restart the service.

%package download
Summary:        Map tile download/generation tools for tileserver
# Generation runs Planetiler/GDAL/tippecanoe in containers and fetches
# inputs from the network.
Requires:       podman
Requires:       slirp4netns
Requires:       sqlite
Requires:       curl
Requires:       jq
Requires:       unzip
Requires:       gawk

%description download
Download and generation tools for the tileserver: fetches OSM extracts,
terrain tiles, and contour source data, and builds MBTiles files and map
styles into /opt/tileserver/data. Tile generation runs in containers
(Planetiler, GDAL, tippecanoe), so no compiler toolchain is required.

Provides a 'tileserver-download' command:

    tileserver-download           full pipeline (OSM, styles, fonts, terrain, contours)
    tileserver-download terrain   terrain tiles only (resumable)
    tileserver-download contours  contour lines only (resumable)
    tileserver-download setup     install dependencies + build container images

%prep
%setup -q

%install
# Application directory (mirrors the repo layout)
install -d %{buildroot}/opt/%{name}
install -d %{buildroot}/opt/%{name}/data
install -d %{buildroot}/opt/%{name}/generate
install -d %{buildroot}/opt/%{name}/generate/assets/styles/topo
install -d %{buildroot}/opt/%{name}/server
install -d %{buildroot}%{_bindir}

# ── Runtime (tileserver) ─────────────────────────────────────────────────────

install -m 0644 server/Containerfile           %{buildroot}/opt/%{name}/server/
install -m 0755 server/entrypoint.sh           %{buildroot}/opt/%{name}/server/
install -m 0644 server/haproxy.cfg             %{buildroot}/opt/%{name}/server/
install -m 0644 server/tileserver-config.json  %{buildroot}/opt/%{name}/server/

# ── Generator (tileserver-download) ─────────────────────────────────────────

install -m 0755 generate/generate-tiles.sh      %{buildroot}/opt/%{name}/generate/
install -m 0755 generate/generate-contours.sh   %{buildroot}/opt/%{name}/generate/
install -m 0755 generate/download-terrain.sh    %{buildroot}/opt/%{name}/generate/
install -m 0755 generate/process-tile.sh        %{buildroot}/opt/%{name}/generate/
install -m 0755 generate/contour-worker.sh      %{buildroot}/opt/%{name}/generate/
install -m 0644 generate/Containerfile.tippecanoe %{buildroot}/opt/%{name}/generate/

# Topo style (shipped with the repo; osm-bright is downloaded by generate-tiles.sh)
install -m 0644 generate/assets/styles/topo/style.json \
    %{buildroot}/opt/%{name}/generate/assets/styles/topo/

install -m 0755 setup-deps.sh           %{buildroot}/opt/%{name}/
install -m 0644 common.sh               %{buildroot}/opt/%{name}/
install -m 0755 packaging/tileserver-download %{buildroot}%{_bindir}/tileserver-download

# Systemd unit
install -d %{buildroot}%{_unitdir}
install -m 0644 packaging/tileserver.service %{buildroot}%{_unitdir}/tileserver.service

%post
echo "==> Building tileserver container image (this may take a minute)..."
podman build -t tileserver -f /opt/%{name}/server/Containerfile /opt/%{name}/server || {
    echo "WARNING: Container image build failed. You can retry with:"
    echo "  podman build -t tileserver -f /opt/%{name}/server/Containerfile /opt/%{name}/server"
}

systemctl daemon-reload

if [ $1 -eq 1 ]; then
    # First install
    systemctl enable --now tileserver || true
elif [ $1 -ge 2 ]; then
    # Upgrade — only restart if already running
    systemctl try-restart tileserver || true
fi

echo ""
echo "========================================================================"
echo "  Tileserver is running on port 8080 (no tile data loaded yet)."
echo ""
echo "  To generate tile data:"
echo "    sudo tileserver-download"
echo ""
echo "  Then restart:"
echo "    sudo systemctl restart tileserver"
echo "========================================================================"

%post download
echo ""
echo "========================================================================"
echo "  tileserver-download installed."
echo ""
echo "  Recommended first step — install dependencies and build the"
echo "  GDAL/tippecanoe container images:"
echo "    sudo tileserver-download setup"
echo ""
echo "  Then generate tile data:"
echo "    sudo tileserver-download"
echo "========================================================================"

%preun
if [ $1 -eq 0 ]; then
    # Full uninstall (not upgrade)
    systemctl disable --now tileserver 2>/dev/null || true
    podman rm -f tileserver 2>/dev/null || true
    podman rmi -f tileserver 2>/dev/null || true
fi

%postun
if [ $1 -eq 0 ]; then
    systemctl daemon-reload || true
    echo ""
    echo "Tileserver removed. Data directory /opt/%{name}/data/ was left intact."
    echo "To remove it:  rm -rf /opt/%{name}/data/"
fi

%files
%dir /opt/%{name}
%dir /opt/%{name}/data
%dir /opt/%{name}/server
/opt/%{name}/server/Containerfile
/opt/%{name}/server/entrypoint.sh
/opt/%{name}/server/haproxy.cfg
/opt/%{name}/server/tileserver-config.json
%config(noreplace) %{_unitdir}/tileserver.service

%files download
%dir /opt/%{name}
%dir /opt/%{name}/data
%dir /opt/%{name}/generate
%dir /opt/%{name}/generate/assets
%dir /opt/%{name}/generate/assets/styles
%dir /opt/%{name}/generate/assets/styles/topo
/opt/%{name}/setup-deps.sh
/opt/%{name}/common.sh
/opt/%{name}/generate/generate-tiles.sh
/opt/%{name}/generate/generate-contours.sh
/opt/%{name}/generate/download-terrain.sh
/opt/%{name}/generate/process-tile.sh
/opt/%{name}/generate/contour-worker.sh
/opt/%{name}/generate/Containerfile.tippecanoe
/opt/%{name}/generate/assets/styles/topo/style.json
%{_bindir}/tileserver-download

%changelog
* Thu Sep 17 2026 Tileserver Maintainer <maintainer@example.com> - 1.0.0-1
- Split packaging into runtime (tileserver) and generator (tileserver-download)
- Runtime now requires only podman; generator deps moved to the download package
- Added /usr/bin/tileserver-download command with all/terrain/contours/setup subcommands

* Thu Feb 26 2026 Tileserver Maintainer <maintainer@example.com> - 1.0.0-1
- Initial RPM package
