#!/bin/bash
# =============================================================================
# sync-gf-patterns.sh — Install gf patterns shipped with the repo (~/.gf)
#
# gf(1) ONLY reads ~/.gf/. The source of truth is git-tracked:
#   gf-patterns/   (all *.json patterns + category-index.json)
#
# install.sh calls this to make the patterns globally accessible.
# Files are COPIED (not moved) so the repo stays the source of truth and
# `git status` stays clean.
#
# category-index.json is an INDEX (no flags/patterns) — never installed.
# ~/.gf is SHARED (openswarm + swarmrecon both sync there, plus user files):
# prune is ownership-aware — only files THIS repo recorded in its
# ~/.gf/.<tool>-manifest and no longer ships are removed; anything the other
# repo's manifest claims (or user files) are never touched.
#
# Usage:
#   ./sync-gf-patterns.sh
#   gf -list
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
SRC="$REPO_DIR/gf-patterns"
GF_DIR="$HOME/.gf"
TOOL_ID="swarmrecon"
MANIFEST="$GF_DIR/.${TOOL_ID}-manifest"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
info() { echo -e "${CYAN}[*]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; }

if [ ! -d "$SRC" ]; then
  err "Pattern source not found: $SRC"
  exit 1
fi

mkdir -p "$GF_DIR"

# ── Copy every real pattern (skip MANIFEST) into ~/.gf ───────────────
# Skip files that already exist and are IDENTICAL (cmp) — only missing
# or changed patterns are copied; unchanged files are never rewritten.
INSTALLED=0
UPTODATE=0
for f in "$SRC"/*.json; do
  name=$(basename "$f")
  case "$name" in
    category-index.json)
      info "Skipping manifest: $name (index only, not a pattern)"
      continue
      ;;
  esac
  if [ -f "$GF_DIR/$name" ] && cmp -s "$f" "$GF_DIR/$name"; then
    UPTODATE=$((UPTODATE + 1))
    continue
  fi
  cp -f "$f" "$GF_DIR/$name"
  INSTALLED=$((INSTALLED + 1))
done

# ── Ownership-aware prune: only files THIS repo synced before ────────
# ~/.gf is shared (openswarm + swarmrecon both write here, plus user
# patterns) — delete only names recorded in OUR manifest that we no longer
# ship AND that the other repo's manifest does not claim.
PRUNED=0
if [ -f "$MANIFEST" ]; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -f "$SRC/$name" ] && continue            # still shipped → keep
    claimed=0
    for other in "$GF_DIR"/.*-manifest; do
      { [ -f "$other" ] && [ "$other" != "$MANIFEST" ]; } || continue
      grep -qxF "$name" "$other" 2>/dev/null && claimed=1
    done
    [ "$claimed" -eq 1 ] && continue           # the other repo owns it
    [ -f "$GF_DIR/$name" ] || continue
    rm -f "$GF_DIR/$name"
    PRUNED=$((PRUNED + 1))
    warn "Removed stale ~/.gf/$name (no longer shipped by $TOOL_ID)"
  done < "$MANIFEST"
fi

# ── Record current ownership for the next run's prune ────────────────
for f in "$SRC"/*.json; do
  name=$(basename "$f")
  [ "$name" = "category-index.json" ] && continue
  printf '%s\n' "$name"
done > "$MANIFEST.tmp"
mv -f "$MANIFEST.tmp" "$MANIFEST"

TOTAL=$(ls "$GF_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
if [ "$INSTALLED" -eq 0 ] && [ "$PRUNED" -eq 0 ]; then
  log "GF patterns already up-to-date → $GF_DIR/ ($UPTODATE unchanged, $TOTAL total)"
else
  log "GF patterns synced → $GF_DIR/ ($INSTALLED copied, $UPTODATE already up-to-date, $TOTAL total)"
  [ "$PRUNED" -gt 0 ] && log "  pruned $PRUNED stale pattern file(s)"
fi
log "Verify with: gf -list"
