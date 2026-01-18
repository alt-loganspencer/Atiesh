#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# SCRIPT 1: Generate music file inventory with SHA256 hashes
# Output format: HASH<TAB>PATH (one line per file)
# ============================================================================

# --- Configuration ---
ROOT="/data_n001/data/udata/real/_logan/master"
ALLOWED_EXT=("mp3" "aif" "aiff" "wav" "ogg" "m4a" "flac")
BATCH_SIZE=100
FILE_LIMIT=0
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
INV_FILE="./inventory_${TIMESTAMP}.tsv"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--limit N]

Options:
  --limit N    Process only first N files (default: all files)
  -h, --help   Show this help

Output:
  Creates inventory TSV with format: HASH<TAB>PATH
  Automatically excludes .DS_Store and ._* files
EOF
  exit 1
}

# --- Arg Parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --limit)
      [[ $# -ge 2 ]] || { echo "ERROR: --limit requires a value" >&2; exit 2; }
      FILE_LIMIT="$2"
      shift 2
      ;;
    *) 
      echo "ERROR: Unknown argument: $1" >&2
      usage
      ;;
  esac
done

# --- Validation ---
if [[ ! -d "$ROOT" ]]; then
  echo "ERROR: Root directory does not exist: $ROOT" >&2
  exit 2
fi

# --- Build find extension arguments ---
find_args=()
for ext in "${ALLOWED_EXT[@]}"; do
  [[ ${#find_args[@]} -gt 0 ]] && find_args+=(-o)
  find_args+=(-iname "*.${ext}")
done

# --- Execute Pipeline ---
echo "Creating inventory: $INV_FILE" >&2
echo "Scanning directory: $ROOT" >&2
[[ "$FILE_LIMIT" -gt 0 ]] && echo "Limit: $FILE_LIMIT files" >&2

# Pipeline:
# 1. find: locate music files (NULL-terminated)
# 2. head: limit count if requested
# 3. xargs/sha256sum: compute hashes
# 4. sed: normalize to HASH<TAB>PATH format
find "$ROOT" -type f \
  ! -name '._*' \
  ! -iname '.ds_store' \
  \( "${find_args[@]}" \) \
  -print0 \
  | { if [[ "$FILE_LIMIT" -gt 0 ]]; then head -z -n "$FILE_LIMIT"; else cat; fi; } \
  | xargs -0 -n "$BATCH_SIZE" sha256sum \
  | sed 's/^\([a-f0-9]\{64\}\)  \(.*\)/\1\t\2/' > "$INV_FILE"

file_count=$(wc -l < "$INV_FILE" | tr -d ' ')
echo "✓ Inventory complete: $file_count files indexed" >&2
echo "✓ Output: $INV_FILE" >&2
echo "✓ Format: HASH<TAB>PATH" >&2
