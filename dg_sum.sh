#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# SCRIPT 2: Analyze inventory TSV and generate duplicate statistics
# Input format: HASH<TAB>PATH (from master_inventory.sh)
# ============================================================================

INV_TSV=""
TOP_N=20
REPORT=""

usage() {
  cat <<EOF
Usage: $(basename "$0") INVENTORY.tsv [options]

Options:
  --top N           Show top N largest duplicate groups (default: 20)
  --report FILE     Write detailed duplicate groups report to FILE
  -h, --help        Show this help

Input format:
  Expected TSV format: HASH<TAB>PATH
  .DS_Store and ._* files are automatically ignored

Output:
  Summary statistics and duplicate group analysis
EOF
  exit 0
}

# --- Arg Parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --top)
      [[ $# -ge 2 ]] || { echo "ERROR: --top requires a value" >&2; exit 2; }
      TOP_N="$2"
      shift 2
      ;;
    --report)
      [[ $# -ge 2 ]] || { echo "ERROR: --report requires a path" >&2; exit 2; }
      REPORT="$2"
      shift 2
      ;;
    *)
      if [[ -z "$INV_TSV" ]]; then
        INV_TSV="$1"
        shift
      else
        echo "ERROR: Unexpected argument: $1" >&2
        usage
      fi
      ;;
  esac
done

# --- Validation ---
if [[ -z "$INV_TSV" || ! -f "$INV_TSV" ]]; then
  echo "ERROR: Inventory TSV file is required and must exist" >&2
  usage
fi

# --- Temp Files ---
FILTERED_TSV="./filtered_inv_$$.tsv"
EXT_TMP="./ext_inv_$$.tmp"
WORST_TMP="./worst_inv_$$.tmp"

trap 'rm -f "$FILTERED_TSV" "$EXT_TMP" "$WORST_TMP"' EXIT

# --- Filter Apple Garbage ---
# Count ignored entries
ignored_count=$(
  awk -F'\t' '
    {
      path=$2
      n=split(path, p, "/")
      base=p[n]
      if (tolower(base) == ".ds_store" || base ~ /^._/) c++
    }
    END { print c+0 }
  ' "$INV_TSV"
)

# Create filtered TSV (HASH<TAB>PATH format preserved)
awk -F'\t' '
  {
    hash=$1
    path=$2
    n=split(path, p, "/")
    base=p[n]
    if (tolower(base) == ".ds_store") next
    if (base ~ /^._/) next
    print hash "\t" path
  }
' "$INV_TSV" > "$FILTERED_TSV"

# --- Core Statistics ---
total_files=$(wc -l < "$FILTERED_TSV" | tr -d ' ')
unique_hashes=$(cut -f1 "$FILTERED_TSV" | sort -u | wc -l | tr -d ' ')
dup_groups=$(cut -f1 "$FILTERED_TSV" | sort | uniq -c | awk '$1>1 {c++} END {print c+0}')
dup_files=$(cut -f1 "$FILTERED_TSV" | sort | uniq -c | awk '$1>1 {s+=($1-1)} END {print s+0}')

# --- Extension Distribution ---
cut -f2 "$FILTERED_TSV" \
| awk -F'/' '
  {
    filename=$NF
    n=split(filename, parts, ".")
    if (n == 1) ext="(none)"
    else ext=tolower(parts[n])
    print ext
  }
' > "$EXT_TMP"

# --- Identify Worst Duplicate Offenders ---
awk -F'\t' '
  {
    hash=$1
    path=$2
    n=split(path, p, "/")
    base=p[n]
    
    cnt[hash]++
    
    # Track simplest filename (shortest basename)
    if (!(hash in best) || length(base) < length(best[hash])) {
      best[hash] = base
    }
  }
  END {
    for (h in cnt) {
      if (cnt[h] > 1) {
        print cnt[h] "\t" h "\t" best[h]
      }
    }
  }
' "$FILTERED_TSV" \
| sort -t$'\t' -k1,1nr > "$WORST_TMP"

# --- Display Summary ---
echo "=== Inventory Summary ==="
echo "Inventory file: $INV_TSV"
echo
echo "Ignored entries (.DS_Store / ._*): $ignored_count"
echo
echo "Total individual files (usable):    $total_files"
echo "Total unique files (unique hash):   $unique_hashes"
echo "Total duplicate files:              $dup_files"
echo "Total duplicate groups:             $dup_groups"
echo
echo "If deduped (keep 1 per hash):"
echo "  Remaining files:                  $unique_hashes"
echo "  Files removed (savings):          $dup_files"
echo
echo "Top $TOP_N largest duplicate groups:"
if [[ -s "$WORST_TMP" ]]; then
  head -n "$TOP_N" "$WORST_TMP" | awk -F'\t' '{printf "%6d  %s\n", $1, $3}'
else
  echo "  (none)"
fi
echo
echo "File extension counts (top 25):"
sort "$EXT_TMP" | uniq -c | sort -nr | head -n 25 | awk '{printf "%8s  %s\n", $1, $2}'

# --- Optional Detailed Report ---
if [[ -n "$REPORT" ]]; then
  echo
  echo "Writing duplicate groups report to: $REPORT"
  
  {
    echo "=== Duplicate Groups Report ==="
    echo "Inventory: $INV_TSV"
    echo "Ignored Apple garbage: $ignored_count"
    echo "Total duplicate groups: $dup_groups"
    echo
    
    while IFS=$'\t' read -r cnt hash bestname; do
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "HASH: $hash"
      echo "COUNT: $cnt duplicates"
      echo "SIMPLEST: $bestname"
      echo
      awk -F'\t' -v target="$hash" '$1 == target {print "  " $2}' "$FILTERED_TSV"
      echo
    done < "$WORST_TMP"
  } > "$REPORT"
  
  echo "✓ Report written: $REPORT"
fi
