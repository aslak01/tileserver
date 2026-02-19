#!/usr/bin/env bash
set -euo pipefail

cleanup() {
  echo "Shutting down..."
  kill "${TILESERVER_PID:-}" "${HAPROXY_PID:-}" 2>/dev/null || true
  wait 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT

# Start tileserver-gl in the background
echo "Starting tileserver-gl on port 8081..."
node /usr/src/app/ --config /data/tileserver-config.json --port 8081 --verbose &
TILESERVER_PID=$!

# Wait for tileserver-gl to be ready
echo "Waiting for tileserver-gl..."
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:8081/health &>/dev/null; then
    echo "tileserver-gl is ready."
    break
  fi
  if ! kill -0 "${TILESERVER_PID}" 2>/dev/null; then
    echo "tileserver-gl exited unexpectedly."
    exit 1
  fi
  sleep 1
done

# Start HAProxy in the background
echo "Starting HAProxy on port 8080..."
haproxy -f /usr/local/etc/haproxy/haproxy.cfg -db &
HAPROXY_PID=$!

echo "Both processes running (tileserver=${TILESERVER_PID}, haproxy=${HAPROXY_PID})."

# Monitor both processes — exit if either dies
while true; do
  if ! kill -0 "${TILESERVER_PID}" 2>/dev/null; then
    echo "tileserver-gl (PID ${TILESERVER_PID}) exited."
    kill "${HAPROXY_PID}" 2>/dev/null || true
    exit 1
  fi
  if ! kill -0 "${HAPROXY_PID}" 2>/dev/null; then
    echo "HAProxy (PID ${HAPROXY_PID}) exited."
    kill "${TILESERVER_PID}" 2>/dev/null || true
    exit 1
  fi
  sleep 2
done
