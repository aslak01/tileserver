Name:           tileserver
Version:        1.0.0
Release:        1%{?dist}
Summary:        Containerized vector tile server with HAProxy caching

License:        MIT
URL:            https://github.com/example/tileserver
BuildArch:      noarch

Source0:        %{name}-%{version}.tar.gz

BuildRequires:  systemd-rpm-macros

Requires:       podman
Requires:       slirp4netns
Requires:       sqlite
Requires:       curl
Requires:       jq
Requires:       unzip
Requires:       gawk

%description
A containerized tile server for serving vector map tiles, terrain data,
and contour lines. Uses tileserver-gl behind an HAProxy caching proxy.

The service starts immediately on port 8080. Without tile data it returns
503; run generate/generate-tiles.sh to populate data and restart the service.

%prep
%setup -q

%install
# Application directory (mirrors the repo layout)
install -d %{buildroot}/opt/%{name}
install -d %{buildroot}/opt/%{name}/data
install -d %{buildroot}/opt/%{name}/generate
install -d %{buildroot}/opt/%{name}/generate/assets/styles/topo
install -d %{buildroot}/opt/%{name}/server

# Repo-root shared files
install -m 0755 setup-deps.sh           %{buildroot}/opt/%{name}/
install -m 0644 common.sh               %{buildroot}/opt/%{name}/

# Tile generation / scraping scripts
install -m 0755 generate/generate-tiles.sh      %{buildroot}/opt/%{name}/generate/
install -m 0755 generate/generate-contours.sh   %{buildroot}/opt/%{name}/generate/
install -m 0755 generate/download-terrain.sh    %{buildroot}/opt/%{name}/generate/
install -m 0755 generate/process-tile.sh        %{buildroot}/opt/%{name}/generate/
install -m 0755 generate/contour-worker.sh      %{buildroot}/opt/%{name}/generate/
install -m 0644 generate/Containerfile.tippecanoe %{buildroot}/opt/%{name}/generate/

# Topo style (shipped with the repo; osm-bright is downloaded by generate-tiles.sh)
install -m 0644 generate/assets/styles/topo/style.json \
    %{buildroot}/opt/%{name}/generate/assets/styles/topo/

# Tileserver / API serving files
install -m 0644 server/Containerfile           %{buildroot}/opt/%{name}/server/
install -m 0755 server/entrypoint.sh           %{buildroot}/opt/%{name}/server/
install -m 0644 server/haproxy.cfg             %{buildroot}/opt/%{name}/server/
install -m 0644 server/tileserver-config.json  %{buildroot}/opt/%{name}/server/

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
echo "    cd /opt/%{name} && sudo ./generate/generate-tiles.sh"
echo ""
echo "  Then restart:"
echo "    sudo systemctl restart tileserver"
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
%dir /opt/%{name}/generate
%dir /opt/%{name}/generate/assets
%dir /opt/%{name}/generate/assets/styles
%dir /opt/%{name}/generate/assets/styles/topo
%dir /opt/%{name}/server
/opt/%{name}/setup-deps.sh
/opt/%{name}/common.sh
/opt/%{name}/generate/generate-tiles.sh
/opt/%{name}/generate/generate-contours.sh
/opt/%{name}/generate/download-terrain.sh
/opt/%{name}/generate/process-tile.sh
/opt/%{name}/generate/contour-worker.sh
/opt/%{name}/generate/Containerfile.tippecanoe
/opt/%{name}/generate/assets/styles/topo/style.json
/opt/%{name}/server/Containerfile
/opt/%{name}/server/entrypoint.sh
/opt/%{name}/server/haproxy.cfg
/opt/%{name}/server/tileserver-config.json
%config(noreplace) %{_unitdir}/tileserver.service

%changelog
* Wed Feb 26 2026 Tileserver Maintainer <maintainer@example.com> - 1.0.0-1
- Initial RPM package
