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
503; run generate-tiles.sh to populate data and restart the service.

%prep
%setup -q

%install
# Application directory
install -d %{buildroot}/opt/%{name}
install -d %{buildroot}/opt/%{name}/data
install -d %{buildroot}/opt/%{name}/data/styles/topo

# Install scripts
install -m 0755 generate-tiles.sh      %{buildroot}/opt/%{name}/
install -m 0755 generate-contours.sh   %{buildroot}/opt/%{name}/
install -m 0755 download-terrain.sh    %{buildroot}/opt/%{name}/
install -m 0755 process-tile.sh        %{buildroot}/opt/%{name}/
install -m 0755 contour-worker.sh      %{buildroot}/opt/%{name}/
install -m 0755 setup-deps.sh          %{buildroot}/opt/%{name}/
install -m 0644 common.sh              %{buildroot}/opt/%{name}/

# Container build files
install -m 0644 Containerfile           %{buildroot}/opt/%{name}/
install -m 0755 entrypoint.sh           %{buildroot}/opt/%{name}/
install -m 0644 haproxy.cfg             %{buildroot}/opt/%{name}/
install -m 0644 tileserver-config.json  %{buildroot}/opt/%{name}/

# Topo style (shipped with the repo; osm-bright is downloaded by generate-tiles.sh)
install -m 0644 data/styles/topo/style.json %{buildroot}/opt/%{name}/data/styles/topo/

# Systemd unit
install -d %{buildroot}%{_unitdir}
install -m 0644 tileserver.service %{buildroot}%{_unitdir}/tileserver.service

%post
echo "==> Building tileserver container image (this may take a minute)..."
podman build -t tileserver -f /opt/%{name}/Containerfile /opt/%{name} || {
    echo "WARNING: Container image build failed. You can retry with:"
    echo "  podman build -t tileserver -f /opt/%{name}/Containerfile /opt/%{name}"
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
echo "    cd /opt/%{name} && sudo ./generate-tiles.sh"
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
%dir /opt/%{name}/data/styles
%dir /opt/%{name}/data/styles/topo
/opt/%{name}/generate-tiles.sh
/opt/%{name}/generate-contours.sh
/opt/%{name}/download-terrain.sh
/opt/%{name}/process-tile.sh
/opt/%{name}/contour-worker.sh
/opt/%{name}/setup-deps.sh
/opt/%{name}/common.sh
/opt/%{name}/Containerfile
/opt/%{name}/entrypoint.sh
/opt/%{name}/haproxy.cfg
/opt/%{name}/tileserver-config.json
/opt/%{name}/data/styles/topo/style.json
%config(noreplace) %{_unitdir}/tileserver.service

%changelog
* Wed Feb 26 2026 Tileserver Maintainer <maintainer@example.com> - 1.0.0-1
- Initial RPM package
