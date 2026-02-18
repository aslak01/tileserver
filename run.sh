#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"

HAPROXY_IMAGE="tileserver-haproxy"
TILESERVER_IMAGE="docker.io/maptiler/tileserver-gl:latest"

# Container / network names
TILESERVER_NAME="tileserver-gl"
HAPROXY_NAME="tileserver-haproxy"
POD_NAME="tileserver-pod"
NET_NAME="tileserver-net"

# ── Detect container runtime ─────────────────────────────────────────────────

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

# ── Preflight checks ────────────────────────────────────────────────────────

if [[ ! -f "${DATA_DIR}/norway.mbtiles" ]]; then
  echo "Error: ${DATA_DIR}/norway.mbtiles not found."
  echo "Run ./generate-tiles.sh first to create the MBTiles file."
  exit 1
fi

if [[ ! -f "${DATA_DIR}/styles/osm-bright/style.json" ]]; then
  echo "Error: Style not found at ${DATA_DIR}/styles/osm-bright/style.json"
  echo "Run ./generate-tiles.sh first to download styles."
  exit 1
fi

# ── Clean up existing containers ─────────────────────────────────────────────

for name in "${TILESERVER_NAME}" "${HAPROXY_NAME}"; do
  if ${CTR} inspect "${name}" &>/dev/null; then
    echo "==> Removing existing container ${name}..."
    ${CTR} rm -f "${name}"
  fi
done

# ── Build HAProxy image ─────────────────────────────────────────────────────

echo "==> Building HAProxy image..."
${CTR} build -t "${HAPROXY_IMAGE}" -f "${SCRIPT_DIR}/Containerfile.haproxy" "${SCRIPT_DIR}"

# ── Start containers ─────────────────────────────────────────────────────────

if [[ "${CTR}" == "podman" ]]; then
  # Podman: use a pod (shared network namespace)
  if podman pod exists "${POD_NAME}" 2>/dev/null; then
    echo "==> Removing existing pod ${POD_NAME}..."
    podman pod rm -f "${POD_NAME}"
  fi

  echo "==> Creating pod ${POD_NAME} (exposing port 8080)..."
  podman pod create --name "${POD_NAME}" -p 8080:8080

  echo "==> Starting tileserver-gl on port 8081..."
  podman run -d \
    --name "${TILESERVER_NAME}" \
    --pod "${POD_NAME}" \
    -v "${DATA_DIR}:/data:z" \
    "${TILESERVER_IMAGE}" \
    --config /data/tileserver-config.json \
    --port 8081 \
    --verbose

  echo "==> Starting HAProxy on port 8080..."
  podman run -d \
    --name "${HAPROXY_NAME}" \
    --pod "${POD_NAME}" \
    -e TILESERVER_HOST=127.0.0.1 \
    "${HAPROXY_IMAGE}"

else
  # Docker: use a shared bridge network, HAProxy connects to tileserver by name
  if ! docker network inspect "${NET_NAME}" &>/dev/null; then
    echo "==> Creating network ${NET_NAME}..."
    docker network create "${NET_NAME}"
  fi

  echo "==> Starting tileserver-gl on port 8081..."
  docker run -d \
    --name "${TILESERVER_NAME}" \
    --network "${NET_NAME}" \
    -v "${DATA_DIR}:/data" \
    "${TILESERVER_IMAGE}" \
    --config /data/tileserver-config.json \
    --port 8081 \
    --verbose

  echo "==> Starting HAProxy on port 8080..."
  docker run -d \
    --name "${HAPROXY_NAME}" \
    --network "${NET_NAME}" \
    -p 8080:8080 \
    -e TILESERVER_HOST="${TILESERVER_NAME}" \
    "${HAPROXY_IMAGE}"
fi

# ── Status ───────────────────────────────────────────────────────────────────

echo ""
echo "==> Containers are running!"
echo "    Tile URL:  http://localhost:8080/{z}/{x}/{y}.png"
echo "    Preview:   http://localhost:8080/"
echo "    Test tile: curl -o test.png http://localhost:8080/10/546/287.png"
echo ""
echo "    Logs:   ${CTR} logs ${TILESERVER_NAME}"
echo "            ${CTR} logs ${HAPROXY_NAME}"
echo "    Stop:   ${CTR} rm -f ${TILESERVER_NAME} ${HAPROXY_NAME}"
