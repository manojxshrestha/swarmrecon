#!/usr/bin/env bash
# js-links.sh — build a clean, scope-filtered JavaScript URL list.
#
# Default input:  check/crawledurls.txt (already live + scope-filtered)
# Fallback:       merged-crawl.txt, only with --probe
# Default output: check/livejslinks.txt
#
# The filter parses each URL path instead of grepping for ".js", so .json,
# .jsp, .jsx, and .map are not mistaken for JavaScript. Fragments are removed.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./js-links.sh [-i <file>] [-o <file>] [--domain <host>] [--scope-file <file>]
                     [--dropped <file>] [--probe] [--threads <n>]

Build check/livejslinks.txt from crawl output.

Options:
  -i, --input <file>       URL list (default: check/crawledurls.txt;
                           merged-crawl.txt only when --probe is used)
  -o, --output <file>      output list (default: check/livejslinks.txt)
      --dropped <file>     dropped URLs with reasons
                           (default: check/livejslinks-dropped.txt)
      --domain <host>      keep only this host and its subdomains
      --scope-file <file>  keep hosts matching this scope file (exact: supported)
      --probe              run PD httpx (200/301/302) on the filtered candidates
      --threads <n>        httpx threads for --probe (default: 50)
  -h, --help               show this help

Default mode sends no requests. --probe sends requests only to the filtered
candidate list; run it only when the engagement permits live traffic.
EOF
}

INPUT=""
OUTPUT="check/livejslinks.txt"
DROPPED=""
DOMAIN=""
SCOPE_FILE=""
PROBE=0
THREADS=50

need_arg() {
    [ "$#" -ge 2 ] || { printf '[!] %s requires a value\n' "$1" >&2; exit 2; }
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -i|--input)     need_arg "$@"; INPUT="$2"; shift 2 ;;
        -o|--output)    need_arg "$@"; OUTPUT="$2"; shift 2 ;;
        --dropped)      need_arg "$@"; DROPPED="$2"; shift 2 ;;
        --domain)       need_arg "$@"; DOMAIN="$2"; shift 2 ;;
        --scope-file)   need_arg "$@"; SCOPE_FILE="$2"; shift 2 ;;
        --probe)        PROBE=1; shift ;;
        --threads)      need_arg "$@"; THREADS="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              printf '[!] unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -n "$DOMAIN" ]; then
    DOMAIN="${DOMAIN,,}"
    if ! [[ "$DOMAIN" =~ ^[a-z0-9_]([a-z0-9._-]*[a-z0-9])?$ ]]; then
        printf '[!] invalid --domain: %s\n' "$DOMAIN" >&2
        exit 2
    fi
fi

if [ -n "$SCOPE_FILE" ] && [ ! -s "$SCOPE_FILE" ]; then
    printf '[!] scope file missing or empty: %s\n' "$SCOPE_FILE" >&2
    exit 2
fi

if [ -z "$INPUT" ]; then
    if [ -s "check/crawledurls.txt" ]; then
        INPUT="check/crawledurls.txt"
    elif [ "$PROBE" -eq 1 ] && [ -s "merged-crawl.txt" ]; then
        INPUT="merged-crawl.txt"
    else
        printf '[!] no input: check/crawledurls.txt is missing/empty'
        [ "$PROBE" -eq 1 ] && printf ' and merged-crawl.txt is missing/empty'
        printf '\n'
        exit 2
    fi
fi
[ -s "$INPUT" ] || { printf '[!] input missing or empty: %s\n' "$INPUT" >&2; exit 2; }

if ! [[ "$THREADS" =~ ^[1-9][0-9]*$ ]]; then
    printf '[!] --threads must be a positive integer\n' >&2
    exit 2
fi

if [ -z "$DROPPED" ]; then
    DROPPED="$(dirname "$OUTPUT")/livejslinks-dropped.txt"
fi

mkdir -p "$(dirname "$OUTPUT")" "$(dirname "$DROPPED")"

candidates="$(mktemp)"
live=""
cleanup() {
    rm -f "$candidates"
    if [ -n "$live" ]; then
        rm -f "$live"
    fi
}
trap cleanup EXIT

python3 - "$INPUT" "$candidates" "$DROPPED" "$DOMAIN" "$SCOPE_FILE" <<'PY'
import fnmatch
import sys
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

input_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
dropped_path = Path(sys.argv[3])
domain = sys.argv[4].strip().lower().rstrip(".")
scope_path = Path(sys.argv[5]) if sys.argv[5] else None

patterns = []
if scope_path is not None:
    for line in scope_path.read_text(encoding="utf-8", errors="replace").splitlines():
        raw = line.strip()
        if raw and not raw.startswith("#"):
            patterns.append(raw.lower().rstrip("."))


def in_scope(host: str) -> bool:
    if not host:
        return False
    if domain:
        return host == domain or host.endswith("." + domain)
    if not patterns:
        return True
    for raw in patterns:
        pattern = raw.lstrip("#").strip().rstrip(".")
        if not pattern:
            continue
        for prefix in ("exact:", "="):
            if pattern.startswith(prefix):
                if host == pattern[len(prefix):].strip():
                    return True
                break
        else:
            if pattern.startswith("*."):
                base = pattern[2:]
                if host == base or host.endswith("." + base):
                    return True
            elif "*" in pattern or "?" in pattern:
                if fnmatch.fnmatch(host, pattern):
                    return True
            elif host == pattern or host.endswith("." + pattern):
                return True
    return False


def drop(url: str, reason: str) -> None:
    dropped.append(f"{url}\t{reason}")


kept = []
dropped = []
seen = set()
for raw_line in input_path.read_text(encoding="utf-8", errors="replace").splitlines():
    original = raw_line.strip()
    if not original or original.startswith("#"):
        continue
    try:
        parts = urlsplit(original)
    except ValueError:
        drop(original, "invalid-url")
        continue
    scheme = parts.scheme.lower()
    if scheme not in {"http", "https"}:
        drop(original, "not-http")
        continue
    host = (parts.hostname or "").lower().rstrip(".,;:)")
    if not host:
        drop(original, "missing-host")
        continue
    if not in_scope(host):
        drop(original, "out-of-scope")
        continue
    path = parts.path.lower()
    if "/cdn-cgi/challenge-platform/" in (parts.path + "?" + parts.query).lower():
        drop(original, "cloudflare-challenge")
        continue
    if path.endswith((".json", ".jsp", ".jsx", ".map")):
        drop(original, "excluded-extension")
        continue
    if not path.endswith((".js", ".mjs", ".cjs")):
        drop(original, "not-js")
        continue
    cleaned = urlunsplit(parts._replace(fragment=""))
    if cleaned in seen:
        continue
    seen.add(cleaned)
    kept.append(cleaned)

out_path.write_text("\n".join(sorted(kept)) + ("\n" if kept else ""), encoding="utf-8")
dropped_path.write_text("\n".join(dropped) + ("\n" if dropped else ""), encoding="utf-8")
print(f"[js-links] {len(kept)} kept, {len(dropped)} dropped")
PY

if [ ! -s "$candidates" ]; then
    : > "$OUTPUT"
    printf '[js-links] no JS candidates after filtering -> %s\n' "$OUTPUT"
    exit 0
fi

if [ "$PROBE" -eq 1 ]; then
    if ! command -v httpx >/dev/null 2>&1; then
        printf '[!] --probe requires ProjectDiscovery httpx on PATH\n' >&2
        exit 2
    fi
    httpx_help="$(httpx -h 2>&1 || true)"
    if ! grep -q -- '-threads' <<<"$httpx_help"; then
        printf '[!] httpx on PATH is not ProjectDiscovery httpx (no -threads flag)\n' >&2
        exit 2
    fi
    live="$(mktemp)"
    if ! httpx -silent -mc 200,301,302 -threads "$THREADS" < "$candidates" > "$live"; then
        printf '[!] httpx probe failed\n' >&2
        exit 1
    fi
    sort -u "$live" > "$OUTPUT"
    printf '[js-links] probe kept %s URL(s) -> %s\n' "$(wc -l < "$OUTPUT" | tr -d ' ')" "$OUTPUT"
else
    cp "$candidates" "$OUTPUT"
    printf '[js-links] wrote %s\n' "$OUTPUT"
fi

exit 0
