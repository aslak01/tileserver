#!/usr/bin/env bash
set -euo pipefail

# Download AWS Terrain Tiles (Mapzen Terrarium) and pack into MBTiles.
#
# Covers Norway + Svalbard bounding box at zoom levels 0-12.
# Downloads tiles in parallel for speed, then batch-inserts into SQLite.
# Requires: curl, sqlite3, awk
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

PARALLEL=30           # concurrent downloads
MAX_RETRIES=2
BATCH_SIZE=500        # insert into SQLite every N downloads

# ── Output path ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_PATH="${1:-${SCRIPT_DIR}/data/terrain.mbtiles}"
DL_DIR="${DB_PATH%.mbtiles}_downloads"
mkdir -p "$(dirname "$(realpath "$DB_PATH" 2>/dev/null || echo "$DB_PATH")")"
mkdir -p "${DL_DIR}"

# ── Dependency check ─────────────────────────────────────────────────────────

for cmd in curl sqlite3 awk; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '${cmd}' not found." >&2
    exit 1
  fi
done

# Verify sqlite3 has readfile() support (fileio extension)
if ! sqlite3 ":memory:" "SELECT typeof(readfile('/dev/null'));" &>/dev/null; then
  echo "Error: sqlite3 does not support readfile(). Install a full sqlite3 build." >&2
  exit 1
fi

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

# Batch-insert all PNG files from DL_DIR into SQLite in a single transaction.
# Files are named: {z}_{x}_{tms_y}.png
batch_insert() {
  local files=( "${DL_DIR}"/*.png )
  if [[ ${#files[@]} -eq 0 || ! -f "${files[0]}" ]]; then
    return 0
  fi

  local sql="BEGIN TRANSACTION;\n"
  local count=0
  for f in "${files[@]}"; do
    local base
    base=$(basename "$f" .png)
    local z x tms_y
    IFS='_' read -r z x tms_y <<< "$base"
    sql+="INSERT OR IGNORE INTO tiles VALUES (${z}, ${x}, ${tms_y}, readfile('${f}'));\n"
    count=$(( count + 1 ))
  done
  sql+="COMMIT;\n"

  printf "${sql}" | sqlite3 "$DB_PATH"

  # Clean up inserted files
  rm -f "${files[@]}"
  echo "$count"
}

# Download a single tile. Called by xargs in parallel.
# Args: z x y tms_y
download_one() {
  local z=$1 x=$2 y=$3 tms_y=$4
  local url="${TILE_URL}/${z}/${x}/${y}.png"
  local output="${DL_DIR}/${z}_${x}_${tms_y}.png"

  local attempt
  for attempt in $(seq 1 "${MAX_RETRIES}"); do
    if curl -sSf --max-time 15 -o "${output}" "${url}" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  rm -f "${output}"
  return 1
}

export -f download_one
export TILE_URL DL_DIR MAX_RETRIES

# ── Main ─────────────────────────────────────────────────────────────────────

echo "Terrain tile download: zoom ${MIN_ZOOM}-${MAX_ZOOM}"
echo "Output: ${DB_PATH}"
echo "Parallel downloads: ${PARALLEL}"
echo ""

init_db

total=$(count_total)
existing_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tiles;")
echo "Total tiles: ${total}, already downloaded: ${existing_count}"
echo ""

grand_downloaded=0
grand_skipped=0
grand_failed=0
start_time=$(date +%s)

for z in $(seq "$MIN_ZOOM" "$MAX_ZOOM"); do
  read -r x_min x_max y_min y_max <<< "$(tile_range "$z")"
  level_total=$(( (x_max - x_min + 1) * (y_max - y_min + 1) ))
  printf "Zoom %2d: %8d tiles  (x: %d-%d, y: %d-%d)\n" \
    "$z" "$level_total" "$x_min" "$x_max" "$y_min" "$y_max"

  # Load existing tiles for this zoom level into a set
  declare -A existing_tiles=()
  while IFS='|' read -r col row; do
    existing_tiles["${col},${row}"]=1
  done < <(sqlite3 "$DB_PATH" "SELECT tile_column, tile_row FROM tiles WHERE zoom_level = $z;")

  # Build list of tiles to download for this zoom level
  todo_file="${DL_DIR}/todo_z${z}.txt"
  : > "${todo_file}"
  level_skipped=0

  for x in $(seq "$x_min" "$x_max"); do
    for y in $(seq "$y_min" "$y_max"); do
      tms_y=$(( (1 << z) - 1 - y ))
      if [[ -n "${existing_tiles["${x},${tms_y}"]+_}" ]]; then
        level_skipped=$(( level_skipped + 1 ))
        continue
      fi
      echo "${z} ${x} ${y} ${tms_y}" >> "${todo_file}"
    done
  done

  unset existing_tiles

  todo_count=$(wc -l < "${todo_file}" | tr -d ' ')
  grand_skipped=$(( grand_skipped + level_skipped ))

  if [[ "${todo_count}" -eq 0 ]]; then
    echo "  All tiles present, skipping."
    rm -f "${todo_file}"
    continue
  fi

  echo "  Need to download: ${todo_count} (skipping ${level_skipped} existing)"

  # Download in parallel
  level_downloaded=0
  level_failed=0
  batch_num=0

  while IFS= read -r line; do
    read -r tz tx ty ttms_y <<< "$line"
    # Queue download
    echo "${tz} ${tx} ${ty} ${ttms_y}"
    batch_num=$(( batch_num + 1 ))

    # When we hit batch size, flush the batch
    if (( batch_num >= BATCH_SIZE )); then
      :  # handled below
    fi
  done < "${todo_file}" | xargs -P "${PARALLEL}" -L 1 bash -c '
    download_one "$@" || echo "FAIL $1 $2 $3 $4" >> "'"${DL_DIR}/failures_z${z}.txt"'"
  ' _

  # Insert all downloaded tiles for this zoom level
  inserted=$(batch_insert)
  level_downloaded=${inserted:-0}

  # Count failures
  if [[ -f "${DL_DIR}/failures_z${z}.txt" ]]; then
    level_failed=$(wc -l < "${DL_DIR}/failures_z${z}.txt" | tr -d ' ')
    rm -f "${DL_DIR}/failures_z${z}.txt"
  fi

  grand_downloaded=$(( grand_downloaded + level_downloaded ))
  grand_failed=$(( grand_failed + level_failed ))

  now=$(date +%s)
  elapsed=$(( now - start_time ))
  done_so_far=$(( grand_downloaded + grand_failed + grand_skipped ))
  pct=$(( done_so_far * 100 / total ))

  if (( elapsed > 0 && grand_downloaded > 0 )); then
    rate=$(( grand_downloaded / elapsed ))
    remaining_dl=$(( total - done_so_far ))
    if (( rate > 0 )); then
      eta=$(( remaining_dl / rate ))
      printf "  Done: +%d tiles (%.0f/s, ETA %dm%02ds, %d%% overall)\n" \
        "$level_downloaded" "$(echo "scale=1; $grand_downloaded / $elapsed" | bc)" \
        "$(( eta / 60 ))" "$(( eta % 60 ))" "$pct"
    fi
  else
    printf "  Done: +%d tiles (%d%% overall)\n" "$level_downloaded" "$pct"
  fi

  rm -f "${todo_file}"
done

elapsed=$(( $(date +%s) - start_time ))
echo ""
echo "Done in $(( elapsed / 60 ))m$(( elapsed % 60 ))s."
echo "  Downloaded: ${grand_downloaded}"
echo "  Skipped (already had): ${grand_skipped}"
echo "  Failed: ${grand_failed}"
echo "  Output: ${DB_PATH}"

# Clean up download dir
rmdir "${DL_DIR}" 2>/dev/null || true
