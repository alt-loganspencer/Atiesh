#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# UT2 /master dedupe by SHA-256
#
# MODES (mutually exclusive; exactly one required):
#   --inventory  : STDOUT only. Print "FULL_PATH<TAB>SHA256" per file.
#   --dry-run    : STDOUT only. Print KEEP/MOVE/CONFLICT decisions. No moves.
#   --execute    : Perform moves. Print actions to STDOUT.
#
# RULES:
# - Scan ROOT=/master recursively, excluding /master/DUPES
# - Duplicates are identical SHA-256 hashes
# - Keep the "cleanest" filename in place; move all other copies
# - Move destination: /master/DUPES/<relative path from /master/>
# - IMMUTABLE: NEVER rename files. If dest exists -> CONFLICT + skip.
# - NEVER overwrite anything.
# ============================================================================

# Enable case-insensitive pattern matching
shopt -s nocasematch

ROOT="/master"
DUPE_DIR="${ROOT}/DUPES"

# Only these extensions are scanned/processed
ALLOWED_EXT=(
  "mp3" "aif" "aiff" "wav" "ogg" "m4a" "flac"
)

MODE=""

usage() {
  cat <<'EOF'
Usage:
  master_dedupe.sh --inventory
  master_dedupe.sh --dry-run
  master_dedupe.sh --execute

Modes:
  --inventory : STDOUT only; prints "FULL_PATH<TAB>SHA256" per file under /master.
  --dry-run   : STDOUT only; prints what would be kept/moved; does not move anything.
  --execute   : performs moves of duplicates into /master/DUPES/.
EOF
}

# --- Arg parsing -----------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --inventory|--dry-run|--execute)
      if [[ -n "$MODE" ]]; then
        echo "ERROR: multiple modes specified." >&2
        exit 2
      fi
      MODE="$arg"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "ERROR: you must specify exactly one mode." >&2
  usage >&2
  exit 2
fi

# --- Helpers ---------------------------------------------------------------

clean_score() {
  local path="$1"
  local base stem score len

  base="$(basename "$path")"
  stem="${base%.*}"
  score=0

  if [[ "$stem" =~ -[0-9]+$ ]]; then score=$((score + 100)); fi
  if [[ "$stem" =~ \ \([0-9]+\)$ ]]; then score=$((score + 100)); fi
  if [[ "$stem" =~ [[:space:]]copy([[:space:]][0-9]+)?$ ]]; then score=$((score + 80)); fi
  if [[ "$stem" =~ [[:space:]]-[[:space:]]copy([[:space:]][0-9]+)?$ ]]; then score=$((score + 80)); fi
  if [[ "$stem" =~ _copy([[:space:]]?[0-9]+)?$ ]]; then score=$((score + 80)); fi

  len="${#base}"
  score=$((score + (len / 10)))
  echo "$score"
}

# Modified to use NUL delimiters (\0) for filename robustness
build_hash_inventory() {
  local find_ext_expr=()
  local ext

  for ext in "${ALLOWED_EXT[@]}"; do
    find_ext_expr+=( -iname "*.${ext}" -o )
  done
  unset 'find_ext_expr[${#find_ext_expr[@]}-1]'

  # Uses -print0 and sed to maintain NUL separators through the pipe
  # sed logic: captures hash and path, outputs as "HASH<TAB>PATH\0"
  find "$ROOT" -type f \
    ! -path "${DUPE_DIR}/*" \
    ! -name '._*' \
    ! -iname '.ds_store' \
    \( "${find_ext_expr[@]}" \) \
    -print0 \
    | xargs -0 sha256sum \
    | sed -z 's/^\([^ ]*\)  \(.*\)/\1\t\2/'
}

move_to_dupes_no_rename() {
  local src="$1"
  local rel dest dest_dir

  rel="${src#${ROOT}/}"
  dest="${DUPE_DIR}/${rel}"
  dest_dir="$(dirname "$dest")"

  if [[ "$src" == "$DUPE_DIR"* ]]; then
    echo "CONFLICT (already under DUPES): $src"
    return 0
  fi

  mkdir -p "$dest_dir"

  if [[ -e "$dest" ]]; then
    echo "CONFLICT (dest exists): $src -> $dest"
    return 0
  fi

  mv -- "$src" "$dest"
  echo "MOVED: $src -> $dest"
}

# --- MODE: inventory ------------------------------------------------------

if [[ "$MODE" == "--inventory" ]]; then
  # Robustly handle NUL-terminated input for the inventory output
  build_hash_inventory | while IFS=$'\t' read -r -d '' h p; do
    printf "%s\t%s\n" "$p" "$h"
  done
  exit 0
fi

# --- Write temp files to current working directory ----------

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TMP_SORT="./dedupe_sort_${TIMESTAMP}.tsv"

# Ensure cleanup on exit
trap 'rm -f "$TMP_SORT"' EXIT

# Sort using NUL as the record terminator
build_hash_inventory | sort -z -k1,1 > "$TMP_SORT"

# --- MODE: dry-run or execute ---------------------------------------------

mkdir -p "$DUPE_DIR"

current_hash=""
declare -a group_paths=()

flush_group() {
  local keep="" keep_score=999999 p s rel dest
  if (( ${#group_paths[@]} <= 1 )); then
    group_paths=()
    return
  fi

  for p in "${group_paths[@]}"; do
    s="$(clean_score "$p")"
    if (( s < keep_score )); then
      keep_score="$s"
      keep="$p"
    fi
  done

  echo "KEEP: $keep"
  for p in "${group_paths[@]}"; do
    [[ "$p" == "$keep" ]] && continue
    rel="${p#${ROOT}/}"
    dest="${DUPE_DIR}/${rel}"

    if [[ "$MODE" == "--dry-run" ]]; then
      if [[ -e "$dest" ]]; then
        echo "CONFLICT (dest exists; would skip): $p -> $dest"
      else
        echo "WOULD MOVE: $p -> $dest"
      fi
    else
      move_to_dupes_no_rename "$p"
    fi
  done
  group_paths=()
}

# Read using NUL terminator to safely handle filenames with newlines
while IFS=$'\t' read -r -d '' h p; do
  if [[ "$h" != "$current_hash" ]]; then
    flush_group
    current_hash="$h"
  fi
  group_paths+=("$p")
done < "$TMP_SORT"

flush_group
exit 0
