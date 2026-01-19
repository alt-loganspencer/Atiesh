#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# SCRIPT 3: Deduplicate music files based on inventory TSV
# Input format: HASH<TAB>PATH (from master_inventory.sh)
# ============================================================================

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
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --tsv)
      [[ $# -ge 2 ]] || { echo "ERROR: --tsv requires a file path" >&2; exit 2; }
      INPUT_TSV="$2"; shift 2 ;;
    --dry-run)
      [[ -z "$MODE" ]] || { echo "ERROR: Cannot specify both --dry-run and --execute" >&2; exit 2; }
      MODE="dry-run"; shift ;;
    --execute)
      [[ -z "$MODE" ]] || { echo "ERROR: Cannot specify both --dry-run and --execute" >&2; exit 2; }
      MODE="execute"; shift ;;
    --limit)
      [[ $# -ge 2 ]] || { echo "ERROR: --limit requires a value" >&2; exit 2; }
      GROUP_LIMIT="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -z "$INPUT_TSV" || ! -f "$INPUT_TSV" ]] && { echo "ERROR: Valid TSV file required" >&2; exit 2; }
[[ -z "$MODE" ]] && { echo "ERROR: Must specify --dry-run or --execute" >&2; exit 2; }
[[ ! -d "$ROOT" ]] && { echo "ERROR: Root directory does not exist: $ROOT" >&2; exit 2; }
[[ "$MODE" == "execute" && ! -d "$DUPE_DIR" ]] && mkdir -p "$DUPE_DIR"

clean_score() {
  local bn="${1##*/}"
  local s=0
  [[ "$bn" =~ -[0-9]+\.[^.]+$ ]] && s=$((s + 100))
  [[ "$bn" =~ \ [0-9]+\.[^.]+$ ]] && s=$((s + 100))
  [[ "$bn" =~ \ \([0-9]+\)\.[^.]+$ ]] && s=$((s + 100))
  [[ "$bn" =~ [[:space:]][Cc]opy ]] && s=$((s + 80))
  echo $((s + ${#bn} / 10))
}

process_group() {
  local -a grp=("$@")
  (( ${#grp[@]} <= 1 )) && return 0
  ((GROUPS_PROCESSED++)) || true
  
  local keep="" ks=999999
  for p in "${grp[@]}"; do
    local sc=$(clean_score "$p")
    (( sc < ks )) && { ks=$sc; keep="$p"; }
  done
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "GROUP #$GROUPS_PROCESSED: ${#grp[@]} duplicates found"
  echo "  KEEP (score: $ks): $keep"
  
  for p in "${grp[@]}"; do
    [[ "$p" == "$keep" ]] && continue
    local rel="${p#${ROOT}/}"
    local dest="${DUPE_DIR}/${rel}"
    if [[ "$MODE" == "dry-run" ]]; then
      echo "  WOULD MOVE: $p"
      echo "           -> $dest"
    else
      mkdir -p "$(dirname "$dest")"
      mv -- "$p" "$dest" 2>/dev/null && echo "  ✓ MOVED: $p" || echo "  ✗ FAILED: $p" >&2
    fi
  done
}

echo "=== Deduplication Process ===" >&2
echo "Input TSV: $INPUT_TSV" >&2
echo "Mode: $MODE" >&2
[[ $GROUP_LIMIT -gt 0 ]] && echo "Limit: $GROUP_LIMIT groups" >&2
echo >&2

TMP_SORT="./dedupe_work_$$.tmp"
trap 'rm -f "$TMP_SORT"' EXIT
sort -k1,1 "$INPUT_TSV" > "$TMP_SORT"
echo "Sorted $(wc -l < "$TMP_SORT") lines" >&2

cur_hash=""
grp_paths=()
total_dupes=0
total_kept=0
lines_read=0
lines_skip=0
limit_hit=false

while IFS="|" read -r hash path; do
  ((lines_read++)) || true
  
  if [[ ! "$hash" =~ ^[a-f0-9]{64}$ ]]; then
    ((lines_skip++)) || true
    continue
  fi
  
  if [[ -z "$path" ]]; then
    ((lines_skip++)) || true
    continue
  fi
  
  local_bn="${path##*/}"
  if [[ "$local_bn" == ".DS_Store" || "$local_bn" == ._* ]]; then
    ((lines_skip++)) || true
    continue
  fi
  
  if [[ "$hash" != "$cur_hash" ]]; then
    if [[ -n "$cur_hash" && ${#grp_paths[@]} -gt 0 ]]; then
      if (( ${#grp_paths[@]} > 1 )); then
        total_dupes=$((total_dupes + ${#grp_paths[@]} - 1))
        ((total_kept++)) || true
      fi
      process_group "${grp_paths[@]}"
      if [[ $GROUP_LIMIT -gt 0 && $GROUPS_PROCESSED -ge $GROUP_LIMIT ]]; then
        echo "Limit reached: $GROUP_LIMIT groups" >&2
        limit_hit=true
        break
      fi
    fi
    cur_hash="$hash"
    grp_paths=()
  fi
  
  grp_paths+=("$path")
done < <(awk -F'\t' '{print $1 "|" $2}' "$TMP_SORT")

if [[ "$limit_hit" == "false" && -n "$cur_hash" && ${#grp_paths[@]} -gt 1 ]]; then
  total_dupes=$((total_dupes + ${#grp_paths[@]} - 1))
  ((total_kept++)) || true
  process_group "${grp_paths[@]}"
fi

echo "" >&2
echo "=== Summary ===" >&2
echo "Lines read: $lines_read" >&2
echo "Lines skipped: $lines_skip" >&2
echo "Duplicate groups: $GROUPS_PROCESSED" >&2
echo "Files kept: $total_kept" >&2
echo "Files moved: $total_dupes" >&2
[[ "$MODE" == "dry-run" ]] && echo "DRY RUN - no files moved. Use --execute to apply." >&2
