#!/usr/bin/env bash
# =============================================================================
# Port Discovery & Service Brute-Forcing — MANUAL (after Step 5)
#
# NOT called by swarmrecon.sh. Run it yourself against an authorized target.
#
# Flow:
#   final alive-domains.txt
#     -> dnmasscan (dns.log + masscan.log)
#     -> nmap -sV  (nmap-scan.gnmap)
#     -> brutespray (scan-results/, confirmation required)
#
# Usage:
#   ./portscan/portscan.sh -d example.com
#   ./portscan/portscan.sh -f recon/example.com/alive-domains.txt
#
# See ./portscan/README.md for the full guide.
# =============================================================================
set -Eeuo pipefail

on_interrupt() {
  trap - INT TERM
  printf '\n' >&2
  echo "WARN  Interrupted — terminating child processes..." >&2
  pkill -INT -P $$ 2>/dev/null || true
  sleep 1
  pkill -TERM -P $$ 2>/dev/null || true
  exit 130
}
trap on_interrupt INT TERM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"     # swarmrecon repo root
RECON_BASE="$BASE_DIR/recon"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}[+]${NC} $1"; }
log_err()  { echo -e "${RED}[-]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_info() { echo -e "${CYAN}[*]${NC} $1"; }
die()      { log_err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage:
  $0                             Auto-detect the newest recon/<domain>/alive-domains.txt
  $0 -d <domain>                 Use recon/<domain>/alive-domains.txt
  $0 -f <alive-domains.txt>      Use an explicit merged domains file

Options:
  -d, --domain <domain>          Domain whose final alive-domains.txt is used
  -f, --domains-file <file>      Explicit merged alive-domains.txt
  -o, --out <dir>                Output directory
                                 (default: recon/<domain>/05b-ports)
  --top-ports <n>                dnMasscan --top-ports value (default: 1000)
  --max-rate <n>                 Optional dnMasscan --max-rate
  --dnmasscan <path>             dnMasscan script (default: ./dnmasscan or PATH)
  --nmap <path>                  nmap binary (default: PATH)
  --brutespray <path>            brutespray binary (default: PATH)
  --no-brute                     Stop after nmap -sV; never run brutespray
  --yes                          Skip confirmation prompts (authorized runs only);
                                 sudo still prompts for your password
  --dry-run                      Print commands; execute nothing
  --no-sudo                      Do not prefix dnMasscan with sudo
  -h, --help                     Show this help

Output:
  <out>/dns.log
  <out>/masscan.log
  <out>/ips.txt
  <out>/ports.txt
  <out>/nmap-scan.gnmap
  <out>/scan-results/            only when brutespray runs
  portscan/alive-domains.txt     snapshot of the merged input

dnMasscan runs through sudo; the script prompts for your password first.

Install hints:
  ./portscan/install.sh          installs/verifies nmap · masscan · dnmasscan · brutespray
  dnmasscan                     (or) download to the repo root as ./dnmasscan, then chmod +x
  brutespray                    (or) go install github.com/x90skysn3k/brutespray/v2@latest
EOF
  exit "${1:-0}"
}

DOMAIN=""
DOMAINS_FILE=""
OUT_DIR=""
TOP_PORTS=1000
MAX_RATE=""
DNMASSSCAN_ARG=""
NMAP_ARG="nmap"
BRUTESPRAY_ARG="brutespray"
RUN_BRUTE=true
ASSUME_YES=false
DRY_RUN=false
NO_SUDO=false

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--domain)        [ $# -ge 2 ] || die "$1 needs a value"; DOMAIN="$2"; shift 2 ;;
    -f|--domains-file)  [ $# -ge 2 ] || die "$1 needs a value"; DOMAINS_FILE="$2"; shift 2 ;;
    -o|--out)           [ $# -ge 2 ] || die "$1 needs a value"; OUT_DIR="$2"; shift 2 ;;
    --top-ports)        [ $# -ge 2 ] || die "$1 needs a value"; TOP_PORTS="$2"; shift 2 ;;
    --max-rate)         [ $# -ge 2 ] || die "$1 needs a value"; MAX_RATE="$2"; shift 2 ;;
    --dnmasscan)        [ $# -ge 2 ] || die "$1 needs a value"; DNMASSSCAN_ARG="$2"; shift 2 ;;
    --nmap)             [ $# -ge 2 ] || die "$1 needs a value"; NMAP_ARG="$2"; shift 2 ;;
    --brutespray)       [ $# -ge 2 ] || die "$1 needs a value"; BRUTESPRAY_ARG="$2"; shift 2 ;;
    --no-brute)         RUN_BRUTE=false; shift ;;
    --yes|-y)           ASSUME_YES=true; shift ;;
    --dry-run)          DRY_RUN=true; shift ;;
    --no-sudo)          NO_SUDO=true; shift ;;
    -h|--help)          usage 0 ;;
    *)                  usage 1 ;;
  esac
done

[[ "$TOP_PORTS" =~ ^[0-9]+$ ]] && [ "$TOP_PORTS" -gt 0 ] \
  || die "--top-ports must be a positive integer"
if [ -n "$MAX_RATE" ]; then
  [[ "$MAX_RATE" =~ ^[0-9]+$ ]] && [ "$MAX_RATE" -gt 0 ] \
    || die "--max-rate must be a positive integer"
fi

# Interactive fallback: no target supplied. Auto-detect the merged root list.
if [ -z "$DOMAIN" ] && [ -z "$DOMAINS_FILE" ]; then
  mapfile -t CANDIDATES < <(
    find "$RECON_BASE" -mindepth 2 -maxdepth 2 -type f -name alive-domains.txt -size +0c \
      -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-
  )

  if [ ${#CANDIDATES[@]} -eq 0 ]; then
    read -rp "Path to merged alive-domains.txt: " input || die "stdin closed"
    [ -n "$input" ] || die "no merged alive-domains.txt found under $RECON_BASE"
    DOMAINS_FILE="$input"
  elif [ ${#CANDIDATES[@]} -eq 1 ]; then
    DOMAINS_FILE="${CANDIDATES[0]}"
    log_info "Auto-detected merged list: $DOMAINS_FILE"
  else
    echo "Merged alive-domains.txt files found:"
    for i in "${!CANDIDATES[@]}"; do
      domain_name="$(basename "$(dirname "${CANDIDATES[$i]}")")"
      printf '  %2d) %-30s %s\n' "$((i + 1))" "$domain_name" "${CANDIDATES[$i]}"
    done
    read -rp "Choose [1 = newest]: " choice || choice=""
    choice="${choice:-1}"
    [[ "$choice" =~ ^[0-9]+$ ]] || die "invalid choice: $choice"
    idx=$((choice - 1))
    [ "$idx" -ge 0 ] && [ "$idx" -lt ${#CANDIDATES[@]} ] || die "invalid choice: $choice"
    DOMAINS_FILE="${CANDIDATES[$idx]}"
  fi
fi

if [ -n "$DOMAIN" ] && [ -n "$DOMAINS_FILE" ]; then
  die "use either -d/--domain or -f/--domains-file, not both"
fi

if [ -n "$DOMAIN" ]; then
  DOMAIN="${DOMAIN#http://}"
  DOMAIN="${DOMAIN#https://}"
  DOMAIN="${DOMAIN%%/*}"
  case "$DOMAIN" in
    ""|.|..|*/*|*..*) die "invalid domain: $DOMAIN" ;;
  esac
  DOMAINS_FILE="$RECON_BASE/$DOMAIN/alive-domains.txt"
  [ -n "$OUT_DIR" ] || OUT_DIR="$RECON_BASE/$DOMAIN/05b-ports"
fi

[ -f "$DOMAINS_FILE" ] || die "domains file not found: $DOMAINS_FILE
Run swarmrecon first; use the final merged recon/<domain>/alive-domains.txt."
[ -s "$DOMAINS_FILE" ] || die "domains file is empty: $DOMAINS_FILE"

if [ -z "$OUT_DIR" ]; then
  if [ "$(basename "$DOMAINS_FILE")" = "alive-domains.txt" ]; then
    OUT_DIR="$(cd "$(dirname "$DOMAINS_FILE")" && pwd)/05b-ports"
  else
    base="$(basename "$DOMAINS_FILE")"
    base="${base%.txt}"
    OUT_DIR="$(cd "$(dirname "$DOMAINS_FILE")" && pwd)/${base}-05b-ports"
  fi
fi
OUT_DIR="${OUT_DIR%/}"

# Keep a copy of the merged input beside this script, as requested. The scan
# still uses the original recon file; the copy is the manual-run snapshot.
if [ "$(basename "$DOMAINS_FILE")" = "alive-domains.txt" ]; then
  INPUT_SNAPSHOT="$SCRIPT_DIR/alive-domains.txt"
  SOURCE_ABS="$(cd "$(dirname "$DOMAINS_FILE")" && pwd)/$(basename "$DOMAINS_FILE")"
  if [ "$SOURCE_ABS" != "$INPUT_SNAPSHOT" ]; then
    if $DRY_RUN; then
      log_info "Would save input snapshot: $INPUT_SNAPSHOT"
    else
      cp -f "$DOMAINS_FILE" "$INPUT_SNAPSHOT" || die "could not save input snapshot: $INPUT_SNAPSHOT"
      log_info "Saved input snapshot: $INPUT_SNAPSHOT"
    fi
  fi
fi

DOMAIN_COUNT="$(grep -cve '^[[:space:]]*\(#\|$\)' "$DOMAINS_FILE" 2>/dev/null || true)"
[ "${DOMAIN_COUNT:-0}" -gt 0 ] || die "no usable domains in $DOMAINS_FILE"

resolve_exec() {
  local bin="$1"
  if [[ "$bin" == */* ]]; then
    [ -x "$bin" ] && printf '%s\n' "$bin"
  else
    command -v "$bin" 2>/dev/null
  fi
}

# Decide whether credential testing is worth starting. Matches brutespray's
# own gnmap service list (v1.8.x) plus the usual ports for services newer
# builds support (e.g. RDP/MongoDB), so we don't prompt when the only open
# ports are HTTP(S)/tcpwrapped.
has_brutable_service() {  # $1 = nmap grepable output
  local svc_re='ssh|ftp|postgres|telnet|mysql|ms-sql-s|shell|vnc|imap|imaps|nntp|pcanywheredata|pop3|pop3s|exec|login|microsoft-ds|smtp|smtps|submission|svn|iss-realsecure|snmptrap|snmp'
  local port_re='21|22|23|25|110|119|139|143|445|512|513|514|587|993|995|1433|3306|3389|5432|5631|5900|3690'
  grep -Eq "/open/tcp//(${svc_re})/" "$1" \
    || grep -Eq "(^|[[:space:],])(${port_re})/open/(tcp|udp)/" "$1"
}

DNMASSSCAN_BIN=""
if [ -n "$DNMASSSCAN_ARG" ]; then
  DNMASSSCAN_BIN="$(resolve_exec "$DNMASSSCAN_ARG" || true)"
  [ -n "$DNMASSSCAN_BIN" ] || die "dnmasscan is not executable: $DNMASSSCAN_ARG"
else
  for candidate in "$BASE_DIR/dnmasscan" "$BASE_DIR/tools/dnmasscan"; do
    if [ -x "$candidate" ]; then DNMASSSCAN_BIN="$candidate"; break; fi
  done
  [ -n "$DNMASSSCAN_BIN" ] || DNMASSSCAN_BIN="$(command -v dnmasscan 2>/dev/null || true)"
fi
if [ -z "$DNMASSSCAN_BIN" ]; then
  if $DRY_RUN; then
    DNMASSSCAN_BIN="$BASE_DIR/dnmasscan"
    log_warn "dnmasscan not found; dry-run assumes $DNMASSSCAN_BIN"
  else
    die "dnmasscan not found (run ./portscan/install.sh, or download it as ./dnmasscan, put it in tools/, or pass --dnmasscan)"
  fi
fi

NMAP_BIN="$(resolve_exec "$NMAP_ARG" || true)"
if [ -z "$NMAP_BIN" ]; then
  if $DRY_RUN; then NMAP_BIN="$NMAP_ARG"; log_warn "nmap not found; dry-run assumes '$NMAP_ARG'"; else die "nmap not found"; fi
fi

BRUTESPRAY_BIN=""
if $RUN_BRUTE; then
  BRUTESPRAY_BIN="$(resolve_exec "$BRUTESPRAY_ARG" || true)"
  if [ -z "$BRUTESPRAY_BIN" ]; then
    if $DRY_RUN; then
      BRUTESPRAY_BIN="$BRUTESPRAY_ARG"
      log_warn "brutespray not found; dry-run assumes '$BRUTESPRAY_ARG'"
    else
      log_warn "brutespray not found — stopping after nmap -sV (install or use --no-brute)"
      RUN_BRUTE=false
    fi
  fi
fi

SUDO=()
if [ "$(id -u)" -ne 0 ] && ! $NO_SUDO; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  elif $DRY_RUN; then
    SUDO=(sudo)
    log_warn "sudo not found; dry-run still shows the sudo command"
  else
    die "sudo not found; run as root or pass --no-sudo"
  fi
fi

MASS_FILE="$OUT_DIR/masscan.log"
DNS_FILE="$OUT_DIR/dns.log"
IPS_FILE="$OUT_DIR/ips.txt"
PORTS_FILE="$OUT_DIR/ports.txt"
NMAP_FILE="$OUT_DIR/nmap-scan.gnmap"
BRUTE_DIR="$OUT_DIR/scan-results"

log_info "Port Discovery & Service Brute-Forcing — manual"
log_info "Targets: $DOMAINS_FILE ($DOMAIN_COUNT domains)"
log_info "Output:  $OUT_DIR"
log_info "Ports:   --top-ports $TOP_PORTS"
log_info "Brute:   $($RUN_BRUTE && echo yes || echo no)"

if ! $DRY_RUN && ! $ASSUME_YES; then
  read -rp "Run port discovery against these targets? [Y/n] " answer || answer=""
  case "$answer" in
    ""|y|Y|yes|YES) ;;
    *) die "aborted" ;;
  esac
fi

if ! $DRY_RUN; then
  mkdir -p "$OUT_DIR"
fi

if [ ${#SUDO[@]} -gt 0 ] && ! $DRY_RUN; then
  log_info "dnMasscan needs sudo — enter your password when prompted."
  sudo -v || die "sudo authentication failed"
fi

log_cmd() {
  printf '  $ '
  printf '%q ' "$@"
  printf '\n'
}

run_cmd() {
  log_cmd "$@"
  if ! $DRY_RUN; then
    "$@"
  fi
}

log_info "Step 1/3 — dnMasscan"
DN_CMD=()
if [ ${#SUDO[@]} -gt 0 ]; then DN_CMD+=("${SUDO[@]}"); fi
DN_CMD+=("$DNMASSSCAN_BIN" "$DOMAINS_FILE" "$DNS_FILE" --top-ports "$TOP_PORTS")
[ -n "$MAX_RATE" ] && DN_CMD+=(--max-rate "$MAX_RATE")
DN_CMD+=(-oG "$MASS_FILE")
run_cmd "${DN_CMD[@]}"

if ! $DRY_RUN; then
  [ -s "$MASS_FILE" ] || die "dnMasscan produced no masscan.log: $MASS_FILE"
fi

log_info "Extracting unique IPs and open ports"
if $DRY_RUN; then
  printf '  $ grep -oP %q %q | sort -u > %q\n' 'Host: \K[0-9.]+' "$MASS_FILE" "$IPS_FILE"
  printf '  $ grep -oP %q %q | sort -u | paste -sd, > %q\n' '\d+(?=/open)' "$MASS_FILE" "$PORTS_FILE"
else
  grep -oP 'Host: \K[0-9.]+' "$MASS_FILE" | sort -u > "$IPS_FILE" || true
  grep -oP '\d+(?=/open)' "$MASS_FILE" | sort -u | paste -sd, > "$PORTS_FILE" || true
  if [ ! -s "$IPS_FILE" ] || [ ! -s "$PORTS_FILE" ]; then
    log_warn "No open ports found in $MASS_FILE — stopping."
    exit 0
  fi
  log_info "IPs: $(wc -l < "$IPS_FILE" | tr -d ' ') · ports: $(cat "$PORTS_FILE")"
fi

log_info "Step 2/3 — nmap -Pn -sV"
if $DRY_RUN; then
  PORTS_ARG="<ports-from-masscan>"
else
  PORTS_ARG="$(tr -d '\n' < "$PORTS_FILE")"
fi
run_cmd "$NMAP_BIN" -Pn -sV -iL "$IPS_FILE" -p "$PORTS_ARG" -oG "$NMAP_FILE"

if ! $DRY_RUN; then
  [ -s "$NMAP_FILE" ] || die "nmap produced no grepable output: $NMAP_FILE"
fi

if $RUN_BRUTE; then
  if ! $DRY_RUN && ! grep -q '/open/' "$NMAP_FILE"; then
    log_warn "No open services in $NMAP_FILE — skipping brutespray."
    RUN_BRUTE=false
  elif ! $DRY_RUN && ! has_brutable_service "$NMAP_FILE"; then
    OPEN_SVCS="$(grep -oP '(?<=/open/tcp//)[^/]*' "$NMAP_FILE" | sed '/^$/d' | sort -u | paste -sd, -)"
    log_warn "No brutespray-supported services (open: ${OPEN_SVCS:-unknown}) — skipping credential testing."
    RUN_BRUTE=false
  fi
fi

if $RUN_BRUTE; then
  log_info "Step 3/3 — brutespray"
  if ! $DRY_RUN && ! $ASSUME_YES; then
    log_warn "The next step runs brutespray: default/custom credential testing."
    log_warn "Only continue if you have explicit authorization for these targets."
    read -rp "Type 'yes' to run brutespray: " answer || answer=""
    if [ "$answer" != "yes" ]; then
      log_warn "Skipped brutespray; service inventory is complete."
      RUN_BRUTE=false
    fi
  fi
  if $RUN_BRUTE; then
    if ! $DRY_RUN; then mkdir -p "$BRUTE_DIR"; fi
    run_cmd "$BRUTESPRAY_BIN" -f "$NMAP_FILE" -o "$BRUTE_DIR"
  fi
else
  log_info "Step 3/3 — brutespray skipped"
fi

if $DRY_RUN; then
  log_ok "Dry run complete — nothing was executed."
else
  log_ok "Done. Evidence: $OUT_DIR"
  printf '  %-24s %s\n' "masscan.log" "$MASS_FILE"
  printf '  %-24s %s\n' "nmap-scan.gnmap" "$NMAP_FILE"
  if [ -d "$BRUTE_DIR" ]; then
    printf '  %-24s %s\n' "scan-results/" "$BRUTE_DIR"
  fi
fi
