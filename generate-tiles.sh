#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"

GEOFABRIK_BASE="https://download.geofabrik.de/europe"
COUNTRY="norway"

PLANETILER_VERSION="0.10.0"
PLANETILER_JAR="planetiler.jar"
PLANETILER_URL="https://github.com/onthegomap/planetiler/releases/download/v${PLANETILER_VERSION}/${PLANETILER_JAR}"

STYLE_REPO="https://github.com/openmaptiles/osm-bright-gl-style"
STYLE_BRANCH="master"

# ── Detect container runtime (podman or docker) ─────────────────────────────

if command -v podman &>/dev/null && podman info &>/dev/null; then
  CTR=podman
elif command -v docker &>/dev/null && docker info &>/dev/null; then
  CTR=docker
else
  echo "Error: no working container runtime found." >&2
  echo "Install and start Docker or Podman." >&2
  exit 1
fi
echo "==> Using container runtime: ${CTR}"

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
  echo "    Generating ${COUNTRY}.mbtiles..."
  ${CTR} run --rm \
    -v "${DATA_DIR}:/data:z" \
    eclipse-temurin:21-jre \
    java -Xmx4g -jar "/data/${PLANETILER_JAR}" \
    --osm-path="/data/${COUNTRY}-latest.osm.pbf" \
    --output="/data/${COUNTRY}.mbtiles" \
    --download \
    --fetch-wikidata
fi

# ── 3. Download OSM Bright style, sprites, and fonts ────────────────────────

STYLE_DIR="${DATA_DIR}/styles/osm-bright"

echo "==> Setting up OSM Bright style..."
mkdir -p "${STYLE_DIR}"

if [[ ! -f "${STYLE_DIR}/style.json" ]]; then
  echo "    Downloading style..."
  TMPDIR="$(mktemp -d)"
  curl -fSL "${STYLE_REPO}/archive/refs/heads/${STYLE_BRANCH}.tar.gz" |
    tar -xz -C "${TMPDIR}" --strip-components=1

  cp "${TMPDIR}/style.json" "${STYLE_DIR}/style.json"
  cp -r "${TMPDIR}/icons" "${STYLE_DIR}/icons" 2>/dev/null || true

  # Patch style.json: point source to local mbtiles, add terrain + hillshade
  if command -v jq &>/dev/null; then
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
  else
    echo "    Warning: jq not found, style.json not patched." >&2
    echo "    Install jq to enable automatic style patching." >&2
  fi

  rm -rf "${TMPDIR}"
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
