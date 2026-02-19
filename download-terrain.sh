#!/usr/bin/env bash
set -euo pipefail

# Download AWS Terrain Tiles (Mapzen Terrarium) and pack into MBTiles.
#
# Covers Norway + Svalbard bounding box at zoom levels 0-12.
# Requires: curl, sqlite3, xxd, awk
#
# Usage:
#     ./download-terrain.sh [output.mbtiles]
#
# The output defaults to data/terrain.mbtiles if not specified.
# Supports resuming: tiles already in the database are skipped.

# ── Config ───────────────────────────────────────────────────────────────────

BBOX_WEST=4.0
BBOX_SOUTH=57.0
BBOX_EAST=32.0
BBOX_NORTH=81.5

MIN_ZOOM=0
MAX_ZOOM=12

TILE_URL="https://s3.amazonaws.com/elevation-tiles-prod/terrarium"

BATCH_SIZE=100
MAX_RETRIES=3

# ── Output path ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_PATH="${1:-${SCRIPT_DIR}/data/terrain.mbtiles}"
mkdir -p "$(dirname "$(realpath "$DB_PATH" 2>/dev/null || echo "$DB_PATH")")"

# ── Dependency check ─────────────────────────────────────────────────────────

for cmd in curl sqlite3 xxd awk; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '${cmd}' not found." >&2
    exit 1
  fi
done

# ── Functions ────────────────────────────────────────────────────────────────

# Calculate tile range for a bbox at a given zoom level.
# Outputs: x_min x_max y_min y_max
tile_range() {
  local zoom=$1
  awk -v z="$zoom" \
      -v w="$BBOX_WEST" -v s="$BBOX_SOUTH" \
      -v e="$BBOX_EAST" -v n="$BBOX_NORTH" '
  BEGIN {
    pi = atan2(0, -1)
    ntiles = 2 ^ z
    maxt = ntiles - 1

    x_min = int((w + 180) / 360 * ntiles)
    x_max = int((e + 180) / 360 * ntiles)
    if (x_min < 0) x_min = 0
    if (x_max > maxt) x_max = maxt

    # North latitude -> smaller y
    lat = n * pi / 180
    y_min = int((1 - log(sin(lat)/cos(lat) + 1/cos(lat)) / pi) / 2 * ntiles)

    # South latitude -> larger y
    lat = s * pi / 180
    y_max = int((1 - log(sin(lat)/cos(lat) + 1/cos(lat)) / pi) / 2 * ntiles)

    if (y_min < 0) y_min = 0
    if (y_max > maxt) y_max = maxt

    printf "%d %d %d %d\n", x_min, x_max, y_min, y_max
  }'
}

# Initialize MBTiles database with required schema and metadata.
init_db() {
  sqlite3 "$DB_PATH" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS metadata (
  name  TEXT PRIMARY KEY,
  value TEXT
);
CREATE TABLE IF NOT EXISTS tiles (
  zoom_level  INTEGER,
  tile_column INTEGER,
  tile_row    INTEGER,
  tile_data   BLOB,
  PRIMARY KEY (zoom_level, tile_column, tile_row)
);
INSERT OR REPLACE INTO metadata VALUES ('name', 'terrain');
INSERT OR REPLACE INTO metadata VALUES ('format', 'png');
INSERT OR REPLACE INTO metadata VALUES ('type', 'baselayer');
INSERT OR REPLACE INTO metadata VALUES ('description', 'AWS Terrain Tiles (Mapzen Terrarium) for Norway');
INSERT OR REPLACE INTO metadata VALUES ('attribution', 'Terrain data: AWS Terrain Tiles / Mapzen');
INSERT OR REPLACE INTO metadata VALUES ('minzoom', '0');
INSERT OR REPLACE INTO metadata VALUES ('maxzoom', '12');
INSERT OR REPLACE INTO metadata VALUES ('bounds', '4.0,57.0,32.0,81.5');
SQL
}

# Count total tiles across all zoom levels.
count_total() {
  local total=0
  for z in $(seq "$MIN_ZOOM" "$MAX_ZOOM"); do
    local x_min x_max y_min y_max
    read -r x_min x_max y_min y_max <<< "$(tile_range "$z")"
    total=$(( total + (x_max - x_min + 1) * (y_max - y_min + 1) ))
  done
  echo "$total"
}

# Download a single tile with retries. Returns 0 on success.
download_tile() {
  local url=$1 output=$2
  local attempt
  for attempt in $(seq 1 "$MAX_RETRIES"); do
    if curl -sSf --max-time 30 -o "$output" "$url" 2>/dev/null; then
      return 0
    fi
    sleep $(( attempt * 2 ))
  done
  return 1
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo "Terrain tile download: zoom ${MIN_ZOOM}-${MAX_ZOOM}"
echo "Output: ${DB_PATH}"
echo ""

init_db

total=$(count_total)
existing_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tiles;")
echo "Total tiles: ${total}, already downloaded: ${existing_count}"
echo ""

downloaded=0
failed=0
skipped=0

tmpfile=$(mktemp)
sql_batch=$(mktemp)
trap 'rm -f "$tmpfile" "$sql_batch"' EXIT

start_time=$(date +%s)

for z in $(seq "$MIN_ZOOM" "$MAX_ZOOM"); do
  read -r x_min x_max y_min y_max <<< "$(tile_range "$z")"
  level_total=$(( (x_max - x_min + 1) * (y_max - y_min + 1) ))
  printf "Zoom %2d: %8d tiles  (x: %d-%d, y: %d-%d)\n" \
    "$z" "$level_total" "$x_min" "$x_max" "$y_min" "$y_max"

  # Load existing tiles for this zoom level into an associative array
  declare -A existing_tiles=()
  while IFS='|' read -r col row; do
    existing_tiles["${col},${row}"]=1
  done < <(sqlite3 "$DB_PATH" "SELECT tile_column, tile_row FROM tiles WHERE zoom_level = $z;")

  echo "BEGIN;" > "$sql_batch"
  batch_count=0

  for x in $(seq "$x_min" "$x_max"); do
    for y in $(seq "$y_min" "$y_max"); do
      # TMS y-flip for MBTiles
      tms_y=$(( (1 << z) - 1 - y ))

      # Skip tiles already in the database
      if [[ -n "${existing_tiles["${x},${tms_y}"]+_}" ]]; then
        skipped=$(( skipped + 1 ))
        continue
      fi

      # Download tile
      url="${TILE_URL}/${z}/${x}/${y}.png"
      if download_tile "$url" "$tmpfile"; then
        hex=$(xxd -p "$tmpfile" | tr -d '\n')
        echo "INSERT OR IGNORE INTO tiles VALUES ($z, $x, $tms_y, X'$hex');" >> "$sql_batch"
        downloaded=$(( downloaded + 1 ))
        batch_count=$(( batch_count + 1 ))
      else
        printf "\n  Warning: failed z=%d x=%d y=%d\n" "$z" "$x" "$y" >&2
        failed=$(( failed + 1 ))
      fi

      # Commit batch to database
      if (( batch_count >= BATCH_SIZE )); then
        echo "COMMIT;" >> "$sql_batch"
        sqlite3 "$DB_PATH" < "$sql_batch"
        echo "BEGIN;" > "$sql_batch"
        batch_count=0
      fi

      # Progress update every 500 tiles
      done_count=$(( downloaded + failed + skipped ))
      if (( done_count > 0 && done_count % 500 == 0 )); then
        now=$(date +%s)
        elapsed=$(( now - start_time ))
        if (( elapsed > 0 )); then
          rate=$(( (downloaded + failed) / elapsed ))
          pct=$(( done_count * 100 / total ))
          if (( rate > 0 )); then
            eta=$(( (total - done_count) / rate ))
            printf "\r  Progress: %d/%d (%d%%)  Downloaded: %d  Failed: %d  Rate: %d/s  ETA: %dm%02ds  " \
              "$done_count" "$total" "$pct" "$downloaded" "$failed" "$rate" \
              "$(( eta / 60 ))" "$(( eta % 60 ))" >&2
          fi
        fi
      fi
    done
  done

  # Commit remaining batch for this zoom level
  if (( batch_count > 0 )); then
    echo "COMMIT;" >> "$sql_batch"
    sqlite3 "$DB_PATH" < "$sql_batch"
  fi

  unset existing_tiles
done

elapsed=$(( $(date +%s) - start_time ))
echo "" >&2
echo ""
echo "Done in $(( elapsed / 60 ))m$(( elapsed % 60 ))s."
echo "  Downloaded: ${downloaded}"
echo "  Skipped (already had): ${skipped}"
echo "  Failed: ${failed}"
echo "  Output: ${DB_PATH}"
