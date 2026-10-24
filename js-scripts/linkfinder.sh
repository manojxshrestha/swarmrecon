#!/usr/bin/env bash
# linkfinder.sh — run LinkFinder against local JavaScript files only.
#
# LinkFinder emits endpoints, not verified findings. This wrapper:
#   - uses $LINKFINDER_HOME or $HOME/LinkFinder
#   - activates the LinkFinder venv by using its Python interpreter
#   - forces CLI output (-o cli)
#   - rejects live URL input and -d/--domain
#   - filters namespace noise and globally sorts/deduplicates
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./linkfinder.sh -i <file|dir|glob> [-r <regex>] [-t <seconds>]
                       [--raw-out <file>]

Run LinkFinder on local JavaScript files. Directory input scans top-level
*.js only (LinkFinder's glob is not recursive). Live URL input and -d are
rejected.

Options:
  -i, --input <path>     local file, directory, or quoted glob (required)
  -r, --regex <regex>    LinkFinder endpoint filter
  -t, --timeout <sec>    LinkFinder timeout (default: LinkFinder's default)
      --raw-out <file>   save unfiltered CLI output before namespace filtering
  -h, --help             show this help

Environment:
  LINKFINDER_HOME        LinkFinder checkout (default: $HOME/LinkFinder)
  LINKFINDER_RAW=1       print raw output without namespace filtering
EOF
}

INPUT=""
REGEX=""
TIMEOUT=""
RAW_OUT=""

need_arg() {
    [ "$#" -ge 2 ] || { printf '[!] %s requires a value\n' "$1" >&2; exit 2; }
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -i|--input)     need_arg "$@"; INPUT="$2"; shift 2 ;;
        -r|--regex)     need_arg "$@"; REGEX="$2"; shift 2 ;;
        -t|--timeout)   need_arg "$@"; TIMEOUT="$2"; shift 2 ;;
        --raw-out)      need_arg "$@"; RAW_OUT="$2"; shift 2 ;;
        -d|--domain)
            printf '[!] -d/--domain is disabled in automation; pass local files\n' >&2
            exit 2
            ;;
        -o|--output)
            printf '[!] -o/--output is not supported; this wrapper always uses -o cli\n' >&2
            exit 2
            ;;
        -h|--help)      usage; exit 0 ;;
        *)              printf '[!] unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$INPUT" ] || { usage >&2; exit 2; }

case "$INPUT" in
    http://*|https://*)
        printf '[!] live URL input is disabled; download JS first\n' >&2
        exit 2
        ;;
esac

LINKFINDER_DIR="${LINKFINDER_HOME:-$HOME/LinkFinder}"
if [ ! -f "$LINKFINDER_DIR/linkfinder.py" ]; then
    printf '[!] LinkFinder not found at %s (run ./install.sh or set LINKFINDER_HOME)\n' \
        "$LINKFINDER_DIR" >&2
    exit 1
fi

PY=""
for candidate in "$LINKFINDER_DIR/venv/bin/python" "$LINKFINDER_DIR/.venv/bin/python"; do
    if [ -x "$candidate" ]; then
        PY="$candidate"
        break
    fi
done
if [ -z "$PY" ]; then
    printf '[!] LinkFinder venv not found in %s (run ./install.sh)\n' "$LINKFINDER_DIR" >&2
    exit 1
fi
if ! "$PY" -c 'import jsbeautifier' >/dev/null 2>&1; then
    printf '[!] LinkFinder venv is missing jsbeautifier (run ./install.sh)\n' >&2
    exit 1
fi

input_arg="$INPUT"
if [ -d "$INPUT" ]; then
    input_arg="$INPUT/*.js"
fi

matches=()
while IFS= read -r match; do
    matches+=("$match")
done < <(compgen -G "$input_arg" || true)
if [ "${#matches[@]}" -eq 0 ]; then
    printf '[!] no top-level .js files matched: %s\n' "$input_arg" >&2
    exit 2
fi

lf_args=(-i "$input_arg" -o cli)
[ -n "$REGEX" ] && lf_args+=(-r "$REGEX")
[ -n "$TIMEOUT" ] && lf_args+=(-t "$TIMEOUT")

tmp="$(mktemp)"
err="$(mktemp)"
cleanup() { rm -f "$tmp" "$err"; }
trap cleanup EXIT

set +e
"$PY" "$LINKFINDER_DIR/linkfinder.py" "${lf_args[@]}" > "$tmp" 2> "$err"
rc=$?
set -e

if [ -n "$RAW_OUT" ]; then
    mkdir -p "$(dirname "$RAW_OUT")"
    cp "$tmp" "$RAW_OUT"
fi

if [ "$rc" -ne 0 ]; then
    cat "$tmp" >&2
    cat "$err" >&2
    exit "$rc"
fi

if [ "${LINKFINDER_RAW:-0}" = "1" ]; then
    cat "$tmp"
else
    { grep -viE '^(https?:)?//(www\.)?(w3\.org|schema\.org|reactjs\.org|xmlns\.com|purl\.org|json-schema\.org)(/|$)' "$tmp" || true; } \
        | sort -u
fi
