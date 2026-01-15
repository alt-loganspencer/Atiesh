#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# /master dedupe by SHA-256
# NOTE: To be run on a Linux system (Synology, UT2, etc) ONLY! Do NOT run from a Mac-based client.
# If you need to run on/from a Mac, see <NEWNAMEPLACEHOLDER> in the Atiesh repo.
#
# MODES (mutually exclusive; exactly one required):
#   --inventory  : Print "FULL_PATH/BASENAME <TAB> SHA256" for each file to STDOUT. (Echo to .tsv file of your choosing for future operations)
#   --dry-run    : Runs full logic but does not move files. Print KEEP/MOVE/CONFLICT decisions to STDOUT.
#   --execute    : Runs full logic AND performs moves as stipulated.
#
# RULES:
# - Scan ROOT=/master recursively, excluding /master/DUPES
# - Duplicates are identical SHA-256 hashes
# - Keep the "cleanest" filename in place; move all other copies
# - Move destination: /master/DUPES/<relative path from /master/>
# - IMMUTABLE: NEVER rename files. If dest exists -> CONFLICT + skip.
# - NEVER overwrite anything.
# ============================================================================

ROOT="/master"
DUPE_DIR="${ROOT}/DUPES"

MODE=""

usage() {
  cat <<'EOF'
Usage:
  master_dedupe.sh --inventory
  master_dedupe.sh --dry-run
  master_dedupe.sh --execute

Modes:
  --inventory : STDOUT only; prints "FULL_PATH<TAB>SHA256" per file under /master (excludes /master/DUPES).
  --dry-run   : STDOUT only; prints what would be kept/moved/conflicted; does not move anything.
  --execute   : performs moves of duplicates into /master/DUPES/<relative path> (no renames, no overwrites).

Examples:
  bash /master/master_dedupe.sh --inventory > /tmp/inventory.tsv
  bash /master/master_dedupe.sh --dry-run
  bash /master/master_dedupe.sh --execute
EOF
}

# --- Arg parsing (exactly one mode) ----------------------------------------

for arg in "$@"; do
  case "$arg" in
    --inventory|--dry-run|--execute)
      if [[ -n "$MODE" ]]; then
        echo "ERROR: multiple modes specified. Choose exactly one." >&2
        usage >&2
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
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "ERROR: you must specify exactly one mode: --inventory | --dry-run | --execute" >&2
  usage >&2
  exit 2
fi

# --- Helpers ---------------------------------------------------------------

# "Cleanliness score" for choosing which file stays in place.
# Lower is better. Penalize obvious duplicate suffix patterns.
clean_score() {
  local path="$1"
  local base stem score len

  base="$(basename "$path")"
  stem="${base%.*}"

  score=0

  # Common duplicate suffix patterns:
  #  - "-1", "-2", ...
  #  - " (1)", " (2)", ...
  #  - " copy", " copy 2", " - Copy", etc.
  if [[ "$stem" =~ -[0-9]+$ ]]; then score=$((score + 100)); fi
  if [[ "$stem" =~ \ \([0-9]+\)$ ]]; then score=$((score + 100)); fi
  if [[ "$stem" =~ [[:space:]][Cc][Oo][Pp][Yy]([[:space:]][0-9]+)?$ ]]; then score=$((score + 80)); fi
  if [[ "$stem" =~ [[:space:]]-[[:space:]][Cc][Oo][Pp][Yy]([[:space:]][0-9]+)?$ ]]; then score=$((score + 80)); fi
  if [[ "$stem" =~ _[Cc][Oo][Pp][Yy]([[:space:]]?[0-9]+)?$ ]]; then score=$((score + 80)); fi

  # Tie-breaker: shorter basename tends to be "original"
  len="${#base}"
  score=$((score + (len / 10)))

  echo "$score"
}

# Build "HASH<TAB>FULLPATH" inventory (excluding DUPES).
# Output: to stdout.
build_hash_inventory() {
  # NUL-safe pipeline for spaces/newlines/etc.
  find "$ROOT" -type f ! -path "${DUPE_DIR}/*" -print0 \
    | xargs -0 sha256sum \
    | awk '{h=$1; $1=""; sub(/^ /,""); print h "\t" $0}'
}

# Convert "HASH<TAB>FULLPATH" to "FULLPATH<TAB>HASH" for inventory mode.
hash_to_path_first() {
  awk -F'\t' '{print $2 "\t" $1}'
}

# Move duplicate to /master/DUPES/<relative path> WITHOUT renaming.
# If destination exists -> conflict and skip.
move_to_dupes_no_rename() {
  local src="$1"
  local rel dest dest_dir

  rel="${src#${ROOT}/}"       # strip "/master/"
  dest="${DUPE_DIR}/${rel}"
  dest_dir="$(dirname "$dest")"

  # Never touch DUPES itself (should already be excluded, but belt+suspenders)
  if [[ "$src" == "$DUPE_DIR"* ]]; then
    echo "CONFLICT (already under DUPES; skipped): $src"  # stdout (execute mode)
    return 0
  fi

  # Ensure destination directory exists
  mkdir -p "$dest_dir"

  if [[ -e "$dest" ]]; then
    echo "CONFLICT (dest exists; skipped): $src -> $dest"
    return 0
  fi

  mv -- "$src" "$dest"
  echo "MOVED: $src -> $dest"
}

# --- MODE: inventory (STDOUT only) ----------------------------------------

if [[ "$MODE" == "--inventory" ]]; then
  # EXACT OUTPUT REQUESTED: full path + hash, one per line, only.
  # Format: FULL_PATH<TAB>SHA256
  build_hash_inventory | hash_to_path_first
  exit 0
fi

# --- For dry-run/execute: we need a sorted hash list to group duplicates ----

TMP_SORT="/tmp/ut2_sha256_sorted.tsv"

# Build + sort by hash
build_hash_inventory | sort -k1,1 > "$TMP_SORT"

# --- MODE: dry-run or execute ---------------------------------------------

mkdir -p "$DUPE_DIR"

current_hash=""
declare -a group_paths=()

flush_group() {
  local keep="" keep_score=999999 p s
  local rel dest

  if (( ${#group_paths[@]} <= 1 )); then
    group_paths=()
    return
  fi

  # Choose keeper: cleanest score; if tie, first encountered wins.
  for p in "${group_paths[@]}"; do
    s="$(clean_score "$p")"
    if (( s < keep_score )); then
      keep_score="$s"
      keep="$p"
    fi
  done

  echo "KEEP: $keep"

  for p in "${group_paths[@]}"; do
    if [[ "$p" == "$keep" ]]; then
      continue
    fi

    # Compute destination for reporting
    rel="${p#${ROOT}/}"
    dest="${DUPE_DIR}/${rel}"

    if [[ "$MODE" == "--dry-run" ]]; then
      if [[ -e "$dest" ]]; then
        echo "CONFLICT (dest exists; would skip): $p -> $dest"
      else
        echo "WOULD MOVE: $p -> $dest"
      fi
    else
      # --execute
      move_to_dupes_no_rename "$p"
    fi
  done

  group_paths=()
}

# Read sorted TSV: hash<TAB>path
# Assumption: file paths do not contain literal TABs (vanishingly rare).
while IFS=$'\t' read -r h p; do
  if [[ "$h" != "$current_hash" ]]; then
    flush_group
    current_hash="$h"
  fi
  group_paths+=("$p")
done < "$TMP_SORT"

flush_group
exit 0
