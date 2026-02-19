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

# ── 1. Download PBF file from Geofabrik ─────────────────────────────────────

PBF="${DATA_DIR}/${COUNTRY}-latest.osm.pbf"
echo "==> Downloading PBF file..."
if [[ -f "${PBF}" ]]; then
  echo "    ${COUNTRY} PBF already exists, skipping."
else
  echo "    Downloading ${COUNTRY}..."
  curl -fSL -o "${PBF}" "${GEOFABRIK_BASE}/${COUNTRY}-latest.osm.pbf"
fi

# ── 2. Generate MBTiles with Planetiler ─────────────────────────────────────

MBTILES="${DATA_DIR}/${COUNTRY}.mbtiles"

echo "==> Generating MBTiles with Planetiler..."

# Download Planetiler if not present
if [[ ! -f "${DATA_DIR}/${PLANETILER_JAR}" ]]; then
  echo "    Downloading Planetiler ${PLANETILER_VERSION}..."
  curl -fSL -o "${DATA_DIR}/${PLANETILER_JAR}" "${PLANETILER_URL}"
fi

if [[ -f "${MBTILES}" ]]; then
  echo "    ${COUNTRY}.mbtiles already exists, skipping."
else
  # Pre-download auxiliary files that Planetiler needs.
  # Java's HTTP client fails on GitHub release redirects inside containers,
  # so we fetch them with curl on the host instead.
  SOURCES_DIR="${DATA_DIR}/sources"
  mkdir -p "${SOURCES_DIR}"

  download_source() {
    local url="$1" dest="${SOURCES_DIR}/$(basename "$1")"
    if [[ -f "${dest}" ]]; then
      echo "    $(basename "${dest}") already exists, skipping."
    else
      echo "    Downloading $(basename "${dest}")..."
      curl -fSL -o "${dest}" "${url}"
    fi
  }

  # Lake centerlines — used to label lakes
  download_source "https://github.com/acalcutt/osm-lakelines/releases/download/v12/lake_centerline.shp.zip"
  # Water polygons — coastlines and ocean fill
  download_source "https://osmdata.openstreetmap.de/download/water-polygons-split-3857.zip"
  # Natural Earth — low-zoom country/boundary/landcover data
  download_source "https://naciscdn.org/naturalearth/packages/natural_earth_vector.gpkg.zip"

  echo "    Generating ${COUNTRY}.mbtiles..."
  ${CTR} run --rm \
    -v "${DATA_DIR}:/data:z" \
    eclipse-temurin:21-jre \
    java -Xmx4g -jar "/data/${PLANETILER_JAR}" \
    --osm-path="/data/${COUNTRY}-latest.osm.pbf" \
    --output="/data/${COUNTRY}.mbtiles" \
    --languages=no,en \
    --lake-centerlines-path=/data/sources/lake_centerline.shp.zip \
    --water-polygons-path=/data/sources/water-polygons-split-3857.zip \
    --natural-earth-path=/data/sources/natural_earth_vector.gpkg.zip \
    --fetch-wikidata
fi

# ── 3. Download OSM Bright style, sprites, and fonts ────────────────────────

STYLE_DIR="${DATA_DIR}/styles/osm-bright"

echo "==> Setting up OSM Bright style..."
mkdir -p "${STYLE_DIR}"

if [[ ! -f "${STYLE_DIR}/style.json" ]]; then
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required to patch style.json but was not found." >&2
    echo "Install jq (e.g. brew install jq / apt install jq) and re-run." >&2
    exit 1
  fi

  echo "    Downloading style..."
  STYLE_TMP="$(mktemp -d)"
  trap 'rm -rf "${STYLE_TMP}"' EXIT
  curl -fSL "${STYLE_REPO}/archive/refs/heads/${STYLE_BRANCH}.tar.gz" |
    tar -xz -C "${STYLE_TMP}" --strip-components=1

  cp "${STYLE_TMP}/style.json" "${STYLE_DIR}/style.json"
  cp -r "${STYLE_TMP}/icons" "${STYLE_DIR}/icons" 2>/dev/null || true

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

  rm -rf "${STYLE_TMP}"
  trap - EXIT
else
  echo "    Style already exists, skipping."
fi

# Download fonts (Noto Sans for good i18n coverage)
FONTS_DIR="${DATA_DIR}/fonts"
if [[ ! -d "${FONTS_DIR}/Noto Sans Regular" ]]; then
  echo "    Downloading fonts..."
  mkdir -p "${FONTS_DIR}"
  FONTS_URL="https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip"
  FONTS_TMP="$(mktemp -d)"
  curl -fSL -o "${FONTS_TMP}/fonts.zip" "${FONTS_URL}"
  unzip -qo "${FONTS_TMP}/fonts.zip" -d "${FONTS_DIR}"
  rm -rf "${FONTS_TMP}"
else
  echo "    Fonts already exist, skipping."
fi

# ── 4. Download terrain tiles ────────────────────────────────────────────────

echo "==> Downloading terrain tiles (will resume if partially complete)..."
bash "${SCRIPT_DIR}/download-terrain.sh" "${DATA_DIR}/terrain.mbtiles"

echo ""
echo "==> Done! Data is in ${DATA_DIR}/"
echo "    MBTiles: ${MBTILES}"
echo "    Style:   ${STYLE_DIR}/style.json"
echo ""
echo "Next: run ./run.sh to start the tile server."
