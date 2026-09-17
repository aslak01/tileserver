# Tileserver

Containerized vector tile server (tileserver-gl behind an HAProxy caching proxy)
for Norway map tiles, terrain, and contour lines.

Tile generation and tile serving are deliberately separated:

```
tileserver/
├── common.sh                 # shared helpers (runtime detection, DATA_DIR, preflight)
├── setup-deps.sh             # installs/builds dependencies for both halves
├── generate/                 # tile scraping/generation — writes data/
│   ├── generate-tiles.sh     #   orchestrator: OSM extract → MBTiles, styles, fonts
│   ├── download-terrain.sh   #   AWS Terrain Tiles → terrain.mbtiles
│   ├── generate-contours.sh  #   SRTM → contours → contours.mbtiles
│   ├── process-tile.sh       #   SRTM download helper (called via xargs)
│   ├── contour-worker.sh     #   runs inside the GDAL container
│   ├── Containerfile.tippecanoe
│   └── assets/styles/topo/   #   repo-owned style input
├── server/                   # running the tileserver / exposing the API
│   ├── run.sh                #   build image + run container (dev)
│   ├── install.sh            #   install as a systemd service
│   ├── entrypoint.sh         #   container entrypoint (tileserver-gl + HAProxy)
│   ├── Containerfile         #   serving image
│   ├── haproxy.cfg
│   └── tileserver-config.json
├── packaging/                # RPM packaging
│   ├── build-rpm.sh
│   ├── tileserver.spec
│   └── tileserver.service
└── data/                     # generated output (gitignored): *.mbtiles, styles, fonts
```

`data/` is the handoff point: everything in `generate/` writes it, everything in
`server/` reads it.

## Quick start

```sh
./setup-deps.sh                 # podman, sqlite3, GDAL + tippecanoe images
./generate/generate-tiles.sh    # download OSM data, generate tiles/terrain/contours
./server/run.sh                 # start the tileserver (dev)
# or
./server/install.sh             # install as a systemd service (persistent)
```

## Generating tiles

All generation happens from `generate/`:

```sh
./generate/generate-tiles.sh                                # everything (OSM + styles + fonts + terrain + contours)
./generate/download-terrain.sh data/terrain.mbtiles         # terrain only (resumable)
./generate/generate-contours.sh data/contours.mbtiles       # contours only (resumable)
```

Downloads and generation are idempotent — existing outputs are skipped, and
failed tiles are retried on re-run.

## Serving tiles

The server (`server/`) builds a single container image from
`maptiler/tileserver-gl` + HAProxy and mounts `data/` read-write (`:z` for
SELinux). Without tile data it returns 503; HAProxy stays up either way.

```sh
./server/run.sh              # http://localhost:8080/{z}/{x}/{y}.pbf
./server/install.sh          # systemd service (starts on boot)
./server/install.sh uninstall
```

## RPM packaging

```sh
./packaging/build-rpm.sh     # → ~/rpmbuild/RPMS/noarch/tileserver-*.noarch.rpm
```

The RPM installs the same layout under `/opt/tileserver/` and expects tile
data in `/opt/tileserver/data/`.
