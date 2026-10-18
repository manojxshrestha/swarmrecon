#!/bin/bash
# gf-extract.sh — standalone gf-pattern URL classifier.
# Manual Phase-4 companion to filter.sh: run AFTER filter.sh, BEFORE copying
# to the openswarm engagement (see prompts/phase3-3b-4-skip-prompt.md).
#
# Usage:
#   ./gf-extract.sh [input_file] [output_dir]
#     input default:  check/param-urls.txt   (pipeline-identical evidence;
#                     pass check/crawledurls.txt for full path-pattern coverage)
#     output default: check/gf/              (copy gf-*.txt to engagement params/)
#
# Only patterns with hits produce files. Hardened: gf also searches $PWD
# recursively (verified via `gf -dump`), so each pattern runs from an empty
# dir with the corpus on stdin; output over 2x input is discarded as a leak.
set -uo pipefail

input_file="${1:-check/param-urls.txt}"
out_dir="${2:-check/gf}"

command -v gf >/dev/null 2>&1 || { echo "Error: gf not found in PATH"; exit 1; }
[ -f "$input_file" ] || { echo "Error: input file '$input_file' not found."; exit 1; }
[ -d "$HOME/.gf" ] && ls "$HOME/.gf"/*.json >/dev/null 2>&1 || {
  echo "Error: gf patterns missing at $HOME/.gf — run ./sync-gf-patterns.sh (patterns bundled in gf-patterns/)"
  exit 1
}

NPARAM=$(wc -l < "$input_file" | tr -d ' ')
if [ "$NPARAM" -eq 0 ]; then
    echo "Nothing to classify (0 input URLs)."
    exit 0
fi
mkdir -p "$out_dir" || { echo "FATAL: cannot create '$out_dir'"; exit 1; }
[ -d "$out_dir" ] && [ -w "$out_dir" ] || { echo "FATAL: '$out_dir' not writable"; exit 1; }

input_abs="$(cd "$(dirname "$input_file")" && pwd -P)/$(basename "$input_file")"
out_abs="$(cd "$out_dir" && pwd -P)"
emptydir=$(mktemp -d)
trap 'rm -rf "$emptydir"' EXIT
shopt -s nullglob

total=0
classes=0
cap=$((NPARAM * 2 + 10))
for pattern in "$HOME"/.gf/*.json; do
    [ -f "$pattern" ] || continue
    cls=$(basename "$pattern" .json)
    safe=$(printf '%s' "$cls" | tr '_' '-')
    tmp=$(mktemp)
    (cd "$emptydir" && gf "$cls" < "$input_abs" 2>/dev/null | sort -u > "$tmp") || true
    n=$(wc -l < "$tmp" | tr -d ' ')
    if [ "$n" -gt "$cap" ]; then
        echo "[!] gf-$safe: $n lines from a $NPARAM-line corpus — leak suspected, discarded"
        rm -f "$tmp"
        continue
    fi
    if [ "$n" -gt 0 ]; then
        mv "$tmp" "$out_abs/gf-$safe.txt"
        echo "[+] gf-$safe.txt: $n"
        total=$((total + n))
        classes=$((classes + 1))
    else
        rm -f "$tmp"
    fi
done

echo
echo "========== GF SUMMARY =========="
printf '%-22s %s\n' "Corpus:" "$NPARAM URLs ($input_file)"
printf '%-22s %s\n' "Candidates:" "$total across $classes patterns -> $out_dir/"
echo "================================"
