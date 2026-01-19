#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# SCRIPT 3: Deduplicate music files based on inventory TSV
# Input format: HASH<TAB>PATH (from master_inventory.sh)
# ============================================================================

# --- Configuration ---
ROOT="/data_n001/data/udata/real/_logan/master"
DUPE_DIR="/data_n001/data/udata/real/_logan/DUPES"
INPUT_TSV=""
MODE=""
GROUP_LIMIT=0
GROUPS_PROCESSED=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --tsv FILE [--dry-run | --execute] [--limit N]

Required:
  --tsv FILE       Path to inventory TSV (from master_inventory.sh)
  
Mode (choose one):
  --dry-run        Show what would be moved (no changes)
  --execute        Actually move duplicate files

Options:
  --limit N        Process only first N duplicate groups (default: all)
  -h, --help       Show this help

Input format:
  Expected TSV format: HASH<TAB>PATH

Behavior:
  - Groups files by hash
  - Keeps the "cleanest" filename (least likely to be a duplicate)
  - Moves duplicates to: $DUPE_DIR
  - Preserves directory structure in DUPES folder
  - .DS_Store and ._* files are automatically ignored

Scoring (lower = better to keep):
  +100 points: filename ends with -N (e.g., file-1.mp3)
  +100 points: filename contains (N) (e.g., file (1).mp3)
  +80 points:  filename contains "copy"
  +length/10:  longer filenames score worse
EOF
  exit 0
}

# --- Arg Parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --tsv)
      [[ $# -ge 2 ]] || { echo "ERROR: --tsv requires a file path" >&2; exit 2; }
      INPUT_TSV="$2"
      shift 2
      ;;
    --dry-run)
      [[ -z "$MODE" ]] || { echo "ERROR: Cannot specify both --dry-run and --execute" >&2; exit 2; }
      MODE="dry-run"
      shift
      ;;
    --execute)
      [[ -z "$MODE" ]] || { echo "ERROR: Cannot specify both --dry-run and --execute" >&2; exit 2; }
      MODE="execute"
      shift
      ;;
    --limit)
      [[ $# -ge 2 ]] || { echo "ERROR: --limit requires a value" >&2; exit 2; }
      GROUP_LIMIT="$2"
      shift 2
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage
      ;;
  esac
done

# --- Validation ---
if [[ -z "$INPUT_TSV" || ! -f "$INPUT_TSV" ]]; then
  echo "ERROR: Valid inventory TSV file required (--tsv)" >&2
  exit 2
fi

if [[ -z "$MODE" ]]; then
  echo "ERROR: Must specify --dry-run or --execute" >&2
  exit 2
fi

if [[ ! -d "$ROOT" ]]; then
  echo "ERROR: Root directory does not exist: $ROOT" >&2
  exit 2
fi

if [[ "$MODE" == "execute" && ! -d "$DUPE_DIR" ]]; then
  echo "Creating DUPES directory: $DUPE_DIR" >&2
  mkdir -p "$DUPE_DIR"
fi

# --- Scoring Function ---
# Lower score = cleaner filename = better to KEEP
# Higher score = likely a duplicate = should be MOVED
clean_score() {
  local path="$1"
  local basename="${path##*/}"
  local score=0
  
  # Penalty for duplicate-like patterns
  # Pattern: "filename-1.ext" or "filename-23.ext" (hyphen + number before extension)
  [[ "$basename" =~ -[0-9]+\.[^.]+$ ]] && score=$((score + 100))
  
  # Pattern: "filename 1.ext" or "filename 23.ext" (space + number before extension)
  [[ "$basename" =~ \ [0-9]+\.[^.]+$ ]] && score=$((score + 100))
  
  # Pattern: "filename (1).ext" or "filename (23).ext" (parenthesized number)
  [[ "$basename" =~ \ \([0-9]+\)\.[^.]+$ ]] && score=$((score + 100))
  
  # Pattern: "filename copy.ext" or "filename copy 2.ext"
  [[ "$basename" =~ [[:space:]]copy([[:space:]]|\.)[^/]*$ ]] && score=$((score + 80))
  
  # Pattern: "filename - Copy.ext" or similar variations
  [[ "$basename" =~ [[:space:]]-[[:space:]]?[Cc]opy ]] && score=$((score + 80))
  
  # Small penalty for longer filenames (tiebreaker)
  score=$((score + ${#basename} / 10))
  
  echo "$score"
}

# --- Group Processing ---
process_group() {
  local -a group=("$@")
  
  # Skip if not actually duplicates
  if (( ${#group[@]} <= 1 )); then
    return 0
  fi
  
  ((GROUPS_PROCESSED++)) || true
  
  # Find best file to keep (lowest score)
  local keep=""
  local keep_score=999999
  
  for path in "${group[@]}"; do
    local score=$(clean_score "$path")
    if (( score < keep_score )); then
      keep_score=$score
      keep="$path"
    fi
  done
  
  # Display group info
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "GROUP #$GROUPS_PROCESSED: ${#group[@]} duplicates found"
  echo "  KEEP (score: $keep_score): $keep"
  
  # Process duplicates
  for path in "${group[@]}"; do
    [[ "$path" == "$keep" ]] && continue
    
    # Calculate destination path
    local rel_path="${path#${ROOT}/}"
    local dest="${DUPE_DIR}/${rel_path}"
    
    if [[ "$MODE" == "dry-run" ]]; then
      echo "  WOULD MOVE: $path"
      echo "           -> $dest"
    else
      # Create destination directory if needed
      local dest_dir=$(dirname "$dest")
      mkdir -p "$dest_dir"
      
      # Move the file
      if mv -- "$path" "$dest" 2>/dev/null; then
        echo "  ✓ MOVED: $path"
      else
        echo "  ✗ FAILED: $path (may not exist or permission denied)" >&2
      fi
    fi
  done
}

# --- Main Execution ---
echo "=== Deduplication Process ===" >&2
echo "Input TSV: $INPUT_TSV" >&2
echo "Mode: $MODE" >&2
[[ $GROUP_LIMIT -gt 0 ]] && echo "Limit: $GROUP_LIMIT groups" >&2
echo >&2

# Prepare sorted temp file
TMP_SORT="./dedupe_work_$$.tmp"
trap 'rm -f "$TMP_SORT"' EXIT

# Sort by hash (column 1)
sort -k1,1 "$INPUT_TSV" > "$TMP_SORT" || { echo "ERROR: Sort failed" >&2; exit 1; }

# Verify sorted file
sorted_lines=$(wc -l < "$TMP_SORT")
echo "Sorted $sorted_lines lines" >&2

# Process groups
current_hash=""
group_paths=()
total_dupes=0
total_kept=0
lines_read=0
lines_skipped=0
limit_reached=false

# Use awk for efficient TSV parsing with process substitution
# Using ASCII unit separator (0x1F) as delimiter - won't appear in filenames
while IFS="|" read -r hash path; do
  ((lines_read++)) || true

  # Validate hash is exactly 64 hex characters
  if [[ ! "$hash" =~ ^[a-f0-9]{64}$ ]]; then
    ((lines_skipped++)) || true
    continue
  fi

  # Validate path exists
  if [[ -z "$path" ]]; then
    ((lines_skipped++)) || true
    continue
  fi

  # Skip Apple garbage
  file_basename="${path##*/}"
  if [[ "$file_basename" == ".DS_Store" || "$file_basename" == ._* ]]; then
    ((lines_skipped++)) || true
    continue
  fi
  
  # Check if we're starting a new group
  if [[ "$hash" != "$current_hash" ]]; then
    # Process previous group if it exists
    if [[ -n "$current_hash" && ${#group_paths[@]} -gt 0 ]]; then
      if (( ${#group_paths[@]} > 1 )); then
        total_dupes=$((total_dupes + ${#group_paths[@]} - 1))
        ((total_kept++)) || true
      fi
      process_group "${group_paths[@]}"
      
      # Check limit AFTER processing
      if [[ $GROUP_LIMIT -gt 0 && $GROUPS_PROCESSED -ge $GROUP_LIMIT ]]; then
        echo >&2
        echo "Limit reached: $GROUP_LIMIT groups processed" >&2
        limit_reached=true
        break
      fi
    fi
    
    # Start new group
    current_hash="$hash"
    group_paths=()
  fi
  
  group_paths+=("$path")
done < <(awk -F'\t' '{print $1 "\x1F" $2}' "$TMP_SORT")

# Process final group (only if limit not reached)
if [[ "$limit_reached" == "false" && -n "$current_hash" && ${#group_paths[@]} -gt 0 ]]; then
  if (( ${#group_paths[@]} > 1 )); then
    total_dupes=$((total_dupes + ${#group_paths[@]} - 1))
    ((total_kept++)) || true
  fi
  process_group "${group_paths[@]}"
fi

# Final summary
echo >&2
echo "=== Summary ===" >&2
echo "Lines read from TSV: $lines_read" >&2
echo "Lines skipped: $lines_skipped" >&2
echo "Duplicate groups processed: $GROUPS_PROCESSED" >&2
echo "Files kept (originals): $total_kept" >&2
echo "Files moved (duplicates): $total_dupes" >&2

if [[ "$MODE" == "dry-run" ]]; then
  echo >&2
  echo "This was a DRY RUN - no files were moved." >&2
  echo "Run with --execute to perform actual deduplication." >&2
fi
\x1F' read -r hash path; do
  ((lines_read++)) || true
  
  # Validate hash is exactly 64 hex characters
  if [[ ! "$hash" =~ ^[a-f0-9]{64}$ ]]; then
    ((lines_skipped++)) || true
    continue
  fi
  
  # Validate path exists
  if [[ -z "$path" ]]; then
    ((lines_skipped++)) || true
    continue
  fi
  
  # Skip Apple garbage
  file_basename="${path##*/}"
  if [[ "$file_basename" == ".DS_Store" || "$file_basename" == ._* ]]; then
    ((lines_skipped++)) || true
    continue
  fi
  
  # Check if we're starting a new group
  if [[ "$hash" != "$current_hash" ]]; then
    # Process previous group if it exists
    if [[ -n "$current_hash" && ${#group_paths[@]} -gt 0 ]]; then
      if (( ${#group_paths[@]} > 1 )); then
        total_dupes=$((total_dupes + ${#group_paths[@]} - 1))
        ((total_kept++)) || true
      fi
      process_group "${group_paths[@]}"
      
      # Check limit AFTER processing
      if [[ $GROUP_LIMIT -gt 0 && $GROUPS_PROCESSED -ge $GROUP_LIMIT ]]; then
        echo >&2
        echo "Limit reached: $GROUP_LIMIT groups processed" >&2
        limit_reached=true
        break
      fi
    fi
    
    # Start new group
    current_hash="$hash"
    group_paths=()
  fi
  
  group_paths+=("$path")
done < <(awk -F'\t' '{print $1 "|" $2}' "$TMP_SORT")

# Process final group (only if limit not reached)
if [[ "$limit_reached" == "false" && -n "$current_hash" && ${#group_paths[@]} -gt 0 ]]; then
  if (( ${#group_paths[@]} > 1 )); then
    total_dupes=$((total_dupes + ${#group_paths[@]} - 1))
    ((total_kept++)) || true
  fi
  process_group "${group_paths[@]}"
fi

# Final summary
echo >&2
echo "=== Summary ===" >&2
echo "Lines read from TSV: $lines_read" >&2
echo "Lines skipped: $lines_skipped" >&2
echo "Duplicate groups processed: $GROUPS_PROCESSED" >&2
echo "Files kept (originals): $total_kept" >&2
echo "Files moved (duplicates): $total_dupes" >&2

if [[ "$MODE" == "dry-run" ]]; then
  echo >&2
  echo "This was a DRY RUN - no files were moved." >&2
  echo "Run with --execute to perform actual deduplication." >&2
fi
