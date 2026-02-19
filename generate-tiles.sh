#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

GEOFABRIK_BASE="https://download.geofabrik.de/europe"
COUNTRY="norway"

PLANETILER_VERSION="0.10.0"
PLANETILER_JAR="planetiler.jar"
PLANETILER_URL="https://github.com/onthegomap/planetiler/releases/download/v${PLANETILER_VERSION}/${PLANETILER_JAR}"

STYLE_REPO="https://github.com/openmaptiles/osm-bright-gl-style"
STYLE_BRANCH="master"

mkdir -p "${DATA_DIR}"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Download a file if it doesn't already exist.
download_file() {
  local url="$1" dest="$2"
  if [[ -f "${dest}" ]]; then
    echo "    $(basename "${dest}") already exists, skipping."
  else
    echo "    Downloading $(basename "${dest}")..."
    curl -fSL -o "${dest}" "${url}"
  fi
}

# Run a function in the background, tracking its PID.
BG_PIDS=()
bg_run() { "$@" & BG_PIDS+=($!); }

# Wait for all tracked background PIDs; exit on first failure.
bg_wait() {
  local pid
  for pid in "${BG_PIDS[@]}"; do
    if ! wait "${pid}"; then
      echo "Error: background job (PID ${pid}) failed." >&2
      exit 1
    fi
  done
  BG_PIDS=()
}

# ── 1. Download all inputs in parallel ───────────────────────────────────────

PBF="${DATA_DIR}/${COUNTRY}-latest.osm.pbf"
MBTILES="${DATA_DIR}/${COUNTRY}.mbtiles"
SOURCES_DIR="${DATA_DIR}/sources"
mkdir -p "${SOURCES_DIR}"

echo "==> Downloading inputs..."

# OSM extract
bg_run download_file \
  "${GEOFABRIK_BASE}/${COUNTRY}-latest.osm.pbf" "${PBF}"

# Planetiler
bg_run download_file \
  "${PLANETILER_URL}" "${DATA_DIR}/${PLANETILER_JAR}"

# Lake centerlines — used to label lakes
bg_run download_file \
  "https://github.com/acalcutt/osm-lakelines/releases/download/v12/lake_centerline.shp.zip" \
  "${SOURCES_DIR}/lake_centerline.shp.zip"

# Water polygons — coastlines and ocean fill
bg_run download_file \
  "https://osmdata.openstreetmap.de/download/water-polygons-split-3857.zip" \
  "${SOURCES_DIR}/water-polygons-split-3857.zip"

# Natural Earth — low-zoom country/boundary/landcover data
bg_run download_file \
  "https://naciscdn.org/naturalearth/packages/natural_earth_vector.gpkg.zip" \
  "${SOURCES_DIR}/natural_earth_vector.gpkg.zip"

bg_wait

# ── 2. Generate MBTiles with Planetiler ──────────────────────────────────────

echo "==> Generating MBTiles with Planetiler..."

if [[ -f "${MBTILES}" ]]; then
  echo "    ${COUNTRY}.mbtiles already exists, skipping."
else
  echo "    Generating ${COUNTRY}.mbtiles..."
  ${CTR} run --rm \
    -v "${DATA_DIR}:/data:z" \
    eclipse-temurin:21-jre \
    java -Xmx4g -jar "/data/${PLANETILER_JAR}" \
    --osm-path="/data/${COUNTRY}-latest.osm.pbf" \
    --output="/data/${COUNTRY}.mbtiles" \
    --tmpdir=/data/tmp \
    --languages=no,en \
    --lake-centerlines-path=/data/sources/lake_centerline.shp.zip \
    --water-polygons-path=/data/sources/water-polygons-split-3857.zip \
    --natural-earth-path=/data/sources/natural_earth_vector.gpkg.zip
fi

# ── 3. Download style, fonts, and terrain (parallel with each other) ─────────

STYLE_DIR="${DATA_DIR}/styles/osm-bright"
FONTS_DIR="${DATA_DIR}/fonts"

setup_style() {
  echo "==> Setting up OSM Bright style..."
  mkdir -p "${STYLE_DIR}"

  if [[ -f "${STYLE_DIR}/style.json" ]]; then
    echo "    Style already exists, skipping."
    return
  fi

  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required to patch style.json but was not found." >&2
    echo "Install jq (e.g. brew install jq / apt install jq) and re-run." >&2
    return 1
  fi

  echo "    Downloading style..."
  local tmp
  tmp="$(mktemp -d)"
  curl -fSL "${STYLE_REPO}/archive/refs/heads/${STYLE_BRANCH}.tar.gz" |
    tar -xz -C "${tmp}" --strip-components=1

  cp "${tmp}/style.json" "${STYLE_DIR}/style.json"
  cp -r "${tmp}/icons" "${STYLE_DIR}/icons" 2>/dev/null || true

  # Patch style.json: point source to local mbtiles, add terrain + hillshade.
  # Assumes the upstream style has a "background" layer; if not, hillshade
  # becomes the first layer (still renders correctly).
  jq '
    .sources = {
      "openmaptiles": {
        "type": "vector",
        "url": "mbtiles://{v3}"
      },
      "terrain": {
        "type": "raster-dem",
        "url": "mbtiles://{terrain}",
        "encoding": "terrarium",
        "tileSize": 256,
        "maxzoom": 12
      }
    } |
    del(.sprite) |
    .glyphs = "{fontstack}/{range}.pbf" |
    # Insert hillshade layer after background
    ({
      "id": "hillshade",
      "type": "hillshade",
      "source": "terrain",
      "minzoom": 0,
      "maxzoom": 16,
      "paint": {
        "hillshade-exaggeration": 0.5,
        "hillshade-shadow-color": "#473B24",
        "hillshade-highlight-color": "#ffffff",
        "hillshade-accent-color": "#000000",
        "hillshade-illumination-direction": 335
      }
    }) as $hs |
    (.layers | to_entries | map(select(.value.id == "background"))[0].key // -1) as $idx |
    if $idx >= 0 then
      .layers = .layers[:$idx+1] + [$hs] + .layers[$idx+1:]
    else
      .layers = [$hs] + .layers
    end
  ' "${STYLE_DIR}/style.json" > "${STYLE_DIR}/style.json.tmp" \
    && mv "${STYLE_DIR}/style.json.tmp" "${STYLE_DIR}/style.json"

  rm -rf "${tmp}"
}

setup_fonts() {
  if [[ -d "${FONTS_DIR}/Noto Sans Regular" ]]; then
    echo "    Fonts already exist, skipping."
    return
  fi
  echo "    Downloading fonts..."
  mkdir -p "${FONTS_DIR}"
  local tmp
  tmp="$(mktemp -d)"
  curl -fSL -o "${tmp}/fonts.zip" \
    "https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip"
  unzip -qo "${tmp}/fonts.zip" -d "${FONTS_DIR}"
  rm -rf "${tmp}"
}

bg_run setup_style
bg_run setup_fonts
bg_run bash "${SCRIPT_DIR}/download-terrain.sh" "${DATA_DIR}/terrain.mbtiles"

bg_wait

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "==> Done! Data is in ${DATA_DIR}/"
echo "    MBTiles: ${MBTILES}"
echo "    Style:   ${STYLE_DIR}/style.json"
echo ""
echo "Next: run ./run.sh to start the tile server."
