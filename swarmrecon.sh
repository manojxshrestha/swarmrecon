#!/usr/bin/env bash
# swarmrecon.sh — single-command recon for a target domain
# Usage: ./swarmrecon.sh -d target.com
# Plan: swarmreconplan.md (openswarm repo)
set -euo pipefail

# ================================================================
#  UI — ANSI colours (auto-off when output is piped or NO_COLOR set)
# ================================================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_MAGENTA=$'\033[35m'
    C_CYAN=$'\033[36m'
else
    C_RESET='' C_BOLD='' C_DIM=''
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN=''
fi

DOMAIN=""
OUTDIR=""
LOG=""

usage() {
    printf '%sUsage:%s ./swarmrecon.sh -d <domain> [--resume | --from <n>]\n' "$C_BOLD" "$C_RESET"
    printf '  %s-d, --domain <domain>%s  target domain (required)\n' "$C_DIM" "$C_RESET"
    printf '  %s-r, --resume%s          resume at the first unfinished step\n' "$C_DIM" "$C_RESET"
    printf '  %s-f, --from <n>%s        start at step n (1-15)\n' "$C_DIM" "$C_RESET"
    printf '  %s-h, --help%s            show this help\n' "$C_DIM" "$C_RESET"
    printf '  %sOutput:%s recon/<domain>/<NN-step>/\n' "$C_DIM" "$C_RESET"
    exit "${1:-1}"
}

RESUME=false
START_STEP=1
FROM_SET=false

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--domain)  [ $# -ge 2 ] || usage 1; DOMAIN="$2"; shift 2 ;;
        -r|--resume)  RESUME=true; shift ;;
        -f|--from)    [ $# -ge 2 ] || usage 1; START_STEP="$2"; FROM_SET=true; shift 2 ;;
        -h|--help)    usage 0 ;;
        *)            usage 1 ;;
    esac
done
[ -z "$DOMAIN" ] && usage 1

if ! [[ "$START_STEP" =~ ^[0-9]+$ ]] || [ "$START_STEP" -lt 1 ] || [ "$START_STEP" -gt 15 ]; then
    printf '%s[!]%s --from must be a step number between 1 and 15 (got: %s)\n' \
        "$C_RED" "$C_RESET" "$START_STEP" >&2
    exit 1
fi
if $RESUME && $FROM_SET; then
    printf '%s[!]%s use either --resume or --from <n>, not both\n' "$C_RED" "$C_RESET" >&2
    exit 1
fi

# DOMAIN is used as a path component (recon/<DOMAIN>/) and in theHarvester -d
# — accept plain hostnames only: no slashes, no shell metas.
# (plain printf: the log helpers below are not defined yet)
if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9_]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] || [ "${#DOMAIN}" -gt 253 ]; then
    printf '%s[!]%s invalid domain: %s (hostname chars only: A-Z a-z 0-9 . _ -, max 253)\n' \
        "$C_RED" "$C_RESET" "$DOMAIN" >&2
    exit 1
fi

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"   # dir of swarmrecon.sh (wordlists live here)
WL_DIR="$SWARM_DIR/wordlists"
# pipx (wappalyzer) + go tools (puredns) install into these — make sure a
# fresh shell (before `pipx ensurepath` takes effect) still finds them
export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"

# ---------- one writer per target ----------
# Two runs for the same domain share recon/<domain>/: one run's step cleanup
# (for example the Step 7 subdomains/ staging dir) can race the other run's
# cp, and both truncate/interleave recon.log. Lock before OUTDIR is created
# or the log is truncated, so a second run exits without touching the tree.
LOCK_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/swarmrecon"
mkdir -p "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/${DOMAIN}.lock"
if command -v flock >/dev/null 2>&1; then
    # Keep the lock file: flock state belongs to the open fd, not the path.
    # Do not unlink it on exit (an unlink/recreate race could admit a third run).
    exec 9>>"$LOCK_FILE"
    if ! flock -n 9; then
        holder="$(cat "$LOCK_FILE" 2>/dev/null || true)"
        printf '%s[!]%s another swarmrecon run is already active for %s%s%s%s\n' \
            "$C_RED" "$C_RESET" "$C_BOLD" "$DOMAIN" "$C_RESET" \
            "${holder:+ (pid $holder)}" >&2
        printf '    wait for it to finish before starting another run.\n' >&2
        exit 1
    fi
    : > "$LOCK_FILE"
    printf '%s\n' "$$" > "$LOCK_FILE"
else
    # Fallback for systems without util-linux flock (macOS, busybox).
    LOCK_FILE="$LOCK_DIR/${DOMAIN}.lock.d"
    if ! mkdir "$LOCK_FILE" 2>/dev/null; then
        holder="$(cat "$LOCK_FILE/pid" 2>/dev/null || true)"
        printf '%s[!]%s another swarmrecon run is already active for %s%s%s%s\n' \
            "$C_RED" "$C_RESET" "$C_BOLD" "$DOMAIN" "$C_RESET" \
            "${holder:+ (pid $holder)}" >&2
        printf '    wait for it to finish before starting another run.\n' >&2
        exit 1
    fi
    printf '%s\n' "$$" > "$LOCK_FILE/pid"
    trap 'rm -rf "$LOCK_FILE"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
fi

OUTDIR="recon/${DOMAIN}"
mkdir -p "$OUTDIR"
LOG="$OUTDIR/recon.log"
: > "$LOG"

# ---------- log helpers (plain text -> file, coloured -> console) ----------
_log() { printf '%s\n' "$*" >> "$LOG"; }

info() { _log "[*] $*"; printf '%s[*]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { _log "[+] $*"; printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { _log "[-] $*"; printf '%s[-]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { _log "[!] $*"; printf '%s[!]%s %s\n' "$C_RED" "$C_RESET" "$*"; }

# ---------- command echo + per-command timing ----------
# Printed before every external tool (SWARM_CMDS=full disables truncation);
# the full text always goes to recon.log and .swarmrecon-cmd, which the
# dashboard reads to show what is running right now.
_CMD_T0=""
_CMD_FILE="$OUTDIR/.swarmrecon-cmd"
CURRENT_STEP=""

fmt_dur() {  # $1 = seconds -> 2h05m / 12m03s / 8s
    local s="${1:-0}"
    if [ "$s" -ge 3600 ]; then
        printf '%dh%02dm' "$((s / 3600))" "$(((s % 3600) / 60))"
    elif [ "$s" -ge 60 ]; then
        printf '%dm%02ds' "$((s / 60))" "$((s % 60))"
    else
        printf '%ds' "$s"
    fi
}

cmd() {  # $* = human-readable command about to run
    local text="$*" shown="$*"
    if [ -n "$_CMD_T0" ]; then
        printf '  %s⏱ %s%s\n' "$C_DIM" "$(fmt_dur $((SECONDS - _CMD_T0)))" "$C_RESET"
    fi
    _CMD_T0=$SECONDS
    if [ "${SWARM_CMDS:-}" != "full" ] && [ "${#shown}" -gt 160 ]; then
        shown="${shown:0:159}…"
    fi
    printf '  %s▶%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$shown" "$C_RESET"
    _log "[*] cmd: $text"
    printf '%s|%s|%s\n' "${CURRENT_STEP:-?}" "$(date +%s)" "$text" \
        > "$_CMD_FILE" 2>/dev/null || true
}

cmd_end() {  # close the timer for the step's last command
    if [ -n "$_CMD_T0" ]; then
        printf '  %s⏱ %s%s\n' "$C_DIM" "$(fmt_dur $((SECONDS - _CMD_T0)))" "$C_RESET"
        _CMD_T0=""
    fi
    : > "$_CMD_FILE" 2>/dev/null || true
}

banner() {
    printf '%s╭%s\n' "$C_CYAN" "$C_RESET"
    printf '%s│%s  %sswarmrecon%s  %s→%s  %s%s%s\n' \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET" "$C_BOLD" "$DOMAIN" "$C_RESET"
    printf '%s│%s  %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_RESET"
    printf '%s╰%s\n' "$C_CYAN" "$C_RESET"
}

step_banner() {  # $1=step_no  $2=title
    CURRENT_STEP="$1"
    printf '\n%s━━━ Step %s ▸ %s %s\n' "$C_MAGENTA$C_BOLD" "$1" "$2" "$C_RESET"
}

# step results for the final summary:  status|step|details
SUMMARY=()
note_result() { SUMMARY+=("$1|$2|$3"); }

now_s() { date +%s; }

# ---- venv helpers (ported from openswarm scripts/tools/_env.sh) ----
# resolve a venv activate script: venv/ first, then .venv/ (uv default).
# ALWAYS exits 0 — prints empty string when no venv exists.
venv_activate() {  # $1 = tool dir
    local d="$1"
    if [ -f "$d/venv/bin/activate" ]; then
        printf '%s' "$d/venv/bin/activate"
    elif [ -f "$d/.venv/bin/activate" ]; then
        printf '%s' "$d/.venv/bin/activate"
    fi
    return 0
}

# self-heal a venv whose python symlink points at a vanished interpreter
# (e.g. system default flipped 3.13 -> 3.14): re-point bin/python at the
# site-matching interpreter. idempotent no-op when versions already match.
repair_venv_python() {  # $1 = activate path
    local activate="${1:-}"
    [ -f "$activate" ] || return 0
    local venv_dir site_ver resolved_ver candidate c
    venv_dir="$(cd "$(dirname "$activate")/.." && pwd)"
    # site-packages version: lib/pythonX.Y/
    site_ver="$(basename "$(ls -d "$venv_dir"/lib/python*/ 2>/dev/null | head -n1)" 2>/dev/null)"
    [ -n "$site_ver" ] || return 0
    # what bin/python actually resolves to
    resolved_ver="$(basename "$(readlink -f "$venv_dir/bin/python" 2>/dev/null)" 2>/dev/null)"
    [ -n "$resolved_ver" ] || return 0
    if [ "$site_ver" = "$resolved_ver" ]; then
        return 0
    fi
    # find matching interpreter — prefer /usr/bin, then PATH
    candidate=""
    for c in "/usr/bin/$site_ver" "$site_ver"; do
        if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then
            candidate="$(command -v "$c" 2>/dev/null || echo "$c")"
            break
        fi
    done
    [ -n "$candidate" ] || return 0
    ln -sfn "$candidate" "$venv_dir/bin/python" || return 0
    # python3 is usually a symlink to python; re-point if it exists as a link
    if [ -L "$venv_dir/bin/python3" ]; then
        ln -sfn python "$venv_dir/bin/python3"
    fi
    return 0
}

# ---- ProjectDiscovery httpx resolution ----
# python3-httpx (pip) installs a CLI with the same name. It rejects
# -threads/-silent, so when it wins the PATH race Steps 6/7/13 quietly produce
# 0 live hosts. These helpers detect a real PD binary anywhere on PATH and
# put its directory first, so the pipeline works even when the Python CLI is
# shadowing it in /usr/bin.
_is_pd_httpx() {  # $1 = candidate binary
    local h
    h="$("$1" -h 2>&1 || true)"
    case "$h" in *"-threads"*) return 0 ;; esac
    return 1
}

resolve_pd_httpx() {
    local cur d
    local IFS=:
    cur="$(command -v httpx 2>/dev/null || true)"
    if [ -n "$cur" ] && _is_pd_httpx "$cur"; then
        printf '%s' "$cur"
        return 0
    fi
    # first httpx is missing or the Python CLI — hunt for a PD binary
    for d in $PATH; do
        [ -n "$d" ] || continue
        [ -x "$d/httpx" ] || continue
        if [ "$d/httpx" = "$cur" ]; then continue; fi
        if _is_pd_httpx "$d/httpx"; then
            printf '%s' "$d/httpx"
            return 0
        fi
    done
    return 1
}

# ---------- source merge (Steps 4/8/9/12 → Steps 13/14) ----------
# The numbered step dirs hold candidates that the crawler and the high-value
# hunt never consumed. merge_forward builds the two compatibility lists in
# recon/<domain>/merge/, appends them to the root lists with dedupe, and then
# removes the temporary merged files (the user's append-and-delete flow).
# Calling it twice is safe: the candidates are regenerated from the numbered
# dirs each time, and sort -u keeps the append idempotent.
_append_unique() {  # $1=source file  $2=destination file
    local src="$1" dst="$2" tmp
    [ -e "$src" ] || return 0
    if [ ! -s "$src" ]; then
        rm -f "$src"
        return 0
    fi
    tmp="${dst}.merge.$$"
    if ! touch "$dst" 2>/dev/null; then
        warn "cannot create ${dst} — merge append skipped"
        rm -f "$src"
        return 0
    fi
    if cat "$dst" "$src" 2>/dev/null \
        | sed -e 's/\r$//' \
              -e '/^[[:space:]]*$/d' \
              -e 's|^\(https\?://[^/]\+\)/$|\1|' \
        | sort -u > "$tmp" \
        && mv -f "$tmp" "$dst"; then
        rm -f "$src"
        return 0
    fi
    rm -f "$tmp"
    warn "could not append $(basename "$src") to $(basename "$dst")"
    return 0
}

merge_forward() {
    local merger="$SWARM_DIR/merge/merge-sources.sh"
    local mdir="$OUTDIR/merge"
    local nh=0 nu=0

    if [ ! -f "$merger" ]; then
        warn "merge/merge-sources.sh missing — Step 4/8/9/12 candidates not forwarded"
        return 0
    fi
    if ! bash "$merger" -d "$DOMAIN" -o "$OUTDIR" >>"$LOG" 2>&1; then
        warn "source merge failed — see ${LOG}"
        return 0
    fi

    _append_unique "$mdir/merged-alive-domains.txt" "$OUTDIR/alive-domains.txt"
    _append_unique "$mdir/merged-https-subs.txt"    "$OUTDIR/https-subs.txt"
    rmdir "$mdir" 2>/dev/null || true

    nh=$(grep -c '.' "$OUTDIR/alive-domains.txt" 2>/dev/null || true)
    nu=$(grep -c 'http' "$OUTDIR/https-subs.txt" 2>/dev/null || true)
    info "merged Steps 4/8/9/12 → alive-domains.txt (${nh:-0} hosts) + https-subs.txt (${nu:-0} seeds)"
    return 0
}

# ================================================================
#  Step 1 — Technology discovery (Wappalyzer)
#  output → recon/<domain>/01-wappalyzer/
# ================================================================
step_wappalyzer() {
    # fresh run: drop the previous JSON before the guard — wappalyzer writes
    # -oJ only on success, so a failed/skipped step must not leave stale tech data
    rm -f "$OUTDIR/01-wappalyzer/technologies.json"

    if ! command -v wappalyzer >/dev/null 2>&1; then
        warn "Step 1 SKIPPED: wappalyzer not found (run ./install.sh)"
        note_result "skip" "1 · Wappalyzer" "wappalyzer not installed"
        return 0
    fi

    local sdir="$OUTDIR/01-wappalyzer"
    mkdir -p "$sdir"
    cmd "wappalyzer -i https://${DOMAIN} -oJ 01-wappalyzer/technologies.json"
    local json_out="$sdir/technologies.json"
    # NOTE: wappalyzer's -oC is silently skipped when -oJ is also given
    # (verified 2026-10-17) -> JSON only; CSV can be derived later if needed.
    local t0; t0=$(now_s)
    if wappalyzer -i "https://${DOMAIN}" -oJ "$json_out" >>"$LOG" 2>&1; then
        local n=0
        n=$(python3 - "$json_out" <<'PY' 2>/dev/null || echo 0
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(sum(len(v) for v in d.values()))
except Exception:
    print(0)
PY
)
        ok "done in $(( $(now_s) - t0 ))s → 01-wappalyzer/technologies.json (${n} technologies)"
        note_result "ok" "1 · Wappalyzer" "01-wappalyzer/ · ${n} techs"
    else
        err "FAILED (exit=$?) — see ${LOG}"
        err "hint: stale Playwright chromium build; run ./install.sh"
        note_result "fail" "1 · Wappalyzer" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 2 — DNS + WHOIS (dig/whois/nslookup)  [exact commands per user]
#  output → recon/<domain>/02-dns-whois/
# ================================================================
step_dns_whois() {
    # fresh run: drop the previous output dir before the guard — a skipped
    # step must not leave stale DNS/WHOIS evidence from an earlier run
    rm -rf "$OUTDIR/02-dns-whois"

    local miss=0
    for t in dig whois nslookup; do
        if ! command -v "$t" >/dev/null 2>&1; then
            warn "Step 2 SKIPPED: $t not found (install manually / ./install.sh)"
            miss=1
        fi
    done
    if [ "$miss" -ne 0 ]; then
        note_result "skip" "2 · DNS + WHOIS" "dig/whois/nslookup not installed"
        return 0
    fi

    local sdir="$OUTDIR/02-dns-whois"
    mkdir -p "$sdir"
    cmd "dig A/AAAA/NS/MX/TXT/CAA/SOA/DMARC ${DOMAIN} (+Google/Cloudflare) · nslookup · whois"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    if {
        # DNS IPv4 addresses
        dig +short A "$domain" > "$sdir/dns-a.txt"
        # DNS IPv6 addresses
        dig +short AAAA "$domain" > "$sdir/dns-aaaa.txt"
        # DNS name servers
        dig NS "$domain" > "$sdir/dns-ns.txt"
        # DNS mail servers
        dig MX "$domain" > "$sdir/dns-mx.txt"
        # DNS TXT records (SPF, verification, etc.)
        dig TXT "$domain" > "$sdir/dns-txt.txt"
        # DNS CAA records (certificate authority restrictions)
        dig CAA "$domain" > "$sdir/dns-caa.txt"
        # DNS SOA record (zone authority information)
        dig SOA "$domain" > "$sdir/dns-soa.txt"
        # DMARC email security policy
        dig TXT "_dmarc.$domain" > "$sdir/dns-dmarc.txt"
        # Query through Google DNS
        dig "$domain" @8.8.8.8 > "$sdir/dns-google.txt"
        # Query through Cloudflare DNS
        dig "$domain" @1.1.1.1 > "$sdir/dns-cloudflare.txt"
        # Alternative DNS lookup
        nslookup "$domain" > "$sdir/dns-nslookup.txt"
        # WHOIS for the domain
        whois "$domain" > "$sdir/whois-domain.txt"
        # WHOIS for each unique IPv4 address
        # (regex checks address FORMAT only — does NOT validate octets are 0-255)
        for ip in $(dig +short A "$domain" |
            grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' |
            sort -u); do
            echo "===== $domain -> $ip ====="
            whois "$ip" |
                grep -Ei '^(CIDR|NetRange|inetnum|route|OrgName|org-name|netname|origin|descr):'
        done > "$sdir/whois-ips.txt"
    :  # verdict = produced files (fail-soft: transient whois/network blips must not fail the step)
    } >>"$LOG" 2>&1; then
        local nfiles
        nfiles=$(find "$sdir" -type f -size +0c | wc -l)
        [ -s "$sdir/whois-domain.txt" ] || warn "whois unreachable (transient network?) — whois-domain.txt empty"
        if [ "$nfiles" -eq 0 ]; then
            err "FAILED — no DNS/WHOIS output produced — see ${LOG}"
            note_result "fail" "2 · DNS + WHOIS" "failed — see recon.log"
        else
            ok "done in $(( $(now_s) - t0 ))s → 02-dns-whois/ (${nfiles} files)"
            info "A: $(paste -sd' ' "$sdir/dns-a.txt" 2>/dev/null | head -c 200)"
            note_result "ok" "2 · DNS + WHOIS" "02-dns-whois/ · ${nfiles} files"
        fi
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "2 · DNS + WHOIS" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 5 — Port scan (nmap · single pass per user)
#  nmap -Pn --open -sV -T4 --top-ports 1000 --min-rate 500 -vvv  (one run → nmap-full.txt)
#  output → recon/<domain>/05-nmap/
# ================================================================
step_nmap() {
    if ! command -v nmap >/dev/null 2>&1; then
        warn "Step 5 SKIPPED: nmap not found (run ./install.sh / install manually)"
        note_result "skip" "5 · Nmap port scan" "nmap not installed"
        return 0
    fi

    local sdir="$OUTDIR/05-nmap"
    mkdir -p "$sdir"
    cmd "nmap -Pn --open -sV -T4 --top-ports 1000 --min-rate 500 ${DOMAIN} -oN 05-nmap/nmap-full.txt"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    # fresh run: don't leave legacy 4-stage files behind
    rm -f "$sdir/nmap-quick.txt" "$sdir/nmap-version.txt" "$sdir/nmap-allports.txt" "$sdir/nmap-full.txt"

    if {
        # single pass (user's command): top-1000 + service versions, fast timing
        nmap -Pn --open -sV -T4 --top-ports 1000 --min-rate 500 -vvv "$domain" -oN "$sdir/nmap-full.txt"
    } >>"$LOG" 2>&1; then
        local nports
        # nmap pads columns: "80/tcp  open" (2 spaces) vs "443/tcp open" (1 space)
        nports=$(grep -cE '/tcp[[:space:]]+open' "$sdir/nmap-full.txt" 2>/dev/null || true)
        ok "done in $(( $(now_s) - t0 ))s → 05-nmap/ (1 report, ${nports:-0} open ports)"
        note_result "ok" "5 · Nmap port scan" "05-nmap/ · ${nports:-0} open ports"
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "5 · Nmap port scan" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 6 — Certificate Transparency logs (ctfr)
#  ctfr lives in $HOME/ctfr with its own venv (PEP-668 blocks system pip);
#  the venv is ACTIVATED automatically before running (user requirement).
#  output → recon/<domain>/06-ctfr/
# ================================================================
step_ctfr() {
    # fresh run: ctfr.py opens its -o file in APPEND mode (no truncate) and the
    # live probe file is only rewritten when httpx actually runs. Create the dir
    # and drop both BEFORE the readiness guard so a skipped step can never feed
    # step 7 stale results.
    mkdir -p "$OUTDIR/06-ctfr"
    rm -f "$OUTDIR/06-ctfr/ctfr-subdomains.txt" \
          "$OUTDIR/06-ctfr/live-ctfr-subdomains.txt"

    local ctfr_dir="$HOME/ctfr"
    local ctfr_act; ctfr_act="$(venv_activate "$ctfr_dir")"
    if [ ! -f "$ctfr_dir/ctfr.py" ] || [ -z "$ctfr_act" ]; then
        warn "Step 6 SKIPPED: ctfr not ready at ${ctfr_dir} (run ./install.sh)"
        note_result "skip" "6 · CT logs (ctfr)" "ctfr/venv missing — run ./install.sh"
        return 0
    fi

    # absolute path: this step cds into the ctfr dir before running
    local sdir_rel="$OUTDIR/06-ctfr"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"

    cmd "python3 ctfr.py -d ${DOMAIN} -o 06-ctfr/ctfr-subdomains.txt   (venv: ~/ctfr)"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    if (
        # auto-activate the virtual environment (user requirement)
        repair_venv_python "$ctfr_act"
        source "$ctfr_act"
        cd "$ctfr_dir"
        # exact command per user, output into our step dir
        python3 ctfr.py -d "$domain" -o "$sdir/ctfr-subdomains.txt"
    ) >>"$LOG" 2>&1; then
        local nsubs=0
        nsubs=$(grep -c '\.' "$sdir/ctfr-subdomains.txt" 2>/dev/null || true)

        # Live probe of CT results (user's exact pipeline):
        #   grep -v "No IP" ctfr-subdomains.txt | awk '{print $1}' | httpx -silent -o live-ctfr-subdomains.txt
        local n_live=0
        if command -v httpx >/dev/null 2>&1; then
            cmd "grep -v 'No IP' ctfr-subdomains.txt | awk '{print \$1}' | httpx -silent -o live-ctfr-subdomains.txt"
            grep -v "No IP" "$sdir/ctfr-subdomains.txt" 2>/dev/null \
                | awk '{print $1}' \
                | httpx -silent -o "$sdir/live-ctfr-subdomains.txt" >>"$LOG" 2>&1 || true
            n_live=$(grep -c 'http' "$sdir/live-ctfr-subdomains.txt" 2>/dev/null || true)
            ok "done in $(( $(now_s) - t0 ))s → 06-ctfr/ (${nsubs:-0} CT entries, ${n_live:-0} live via httpx)"
        else
            warn "httpx not found — live CT probe skipped (install ProjectDiscovery httpx)"
            ok "done in $(( $(now_s) - t0 ))s → 06-ctfr/ctfr-subdomains.txt (${nsubs:-0} entries, live probe skipped)"
        fi
        note_result "ok" "6 · CT logs (ctfr)" "06-ctfr/ · ${nsubs:-0} CT / ${n_live:-0} live"
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "6 · CT logs (ctfr)" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 8 — DNS subdomain bruteforce (puredns + massdns)
#  puredns = fast, handles wildcards; massdns compiled for speed (user).
#  wordlists: <swarmrecon>/wordlists/{subdomains-top1million-20000,resolvers}.txt
#  output → recon/<domain>/08-puredns/
# ================================================================
step_puredns() {
    # puredns may not be on PATH — accept $HOME/go/bin/puredns (go install default)
    local pd=""
    if command -v puredns >/dev/null 2>&1; then
        pd="$(command -v puredns)"
    elif [ -x "$HOME/go/bin/puredns" ]; then
        pd="$HOME/go/bin/puredns"
    else
        warn "Step 8 SKIPPED: puredns not found (run ./install.sh)"
        note_result "skip" "8 · DNS bruteforce" "puredns missing — run ./install.sh"
        return 0
    fi

    if ! command -v massdns >/dev/null 2>&1; then
        warn "Step 8 SKIPPED: massdns not found (puredns backend — run ./install.sh)"
        note_result "skip" "8 · DNS bruteforce" "massdns missing — run ./install.sh"
        return 0
    fi

    local wl_wordlist="$WL_DIR/subdomains-top1million-20000.txt"
    local wl_resolvers="$WL_DIR/resolvers.txt"
    if [ ! -s "$wl_wordlist" ] || [ ! -s "$wl_resolvers" ]; then
        warn "Step 8 SKIPPED: wordlists missing in ${WL_DIR} (ship with the repo — check wordlists/)"
        note_result "skip" "8 · DNS bruteforce" "wordlists missing — check wordlists/"
        return 0
    fi

    # absolute path (same convention as other steps)
    local sdir_rel="$OUTDIR/08-puredns"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"

    cmd "puredns bruteforce wordlists/subdomains-top1million-20000.txt ${DOMAIN} -r wordlists/resolvers.txt"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    # exact command per user, with absolute wordlist/resolver paths
    if "$pd" bruteforce "$wl_wordlist" "$domain" -r "$wl_resolvers" \
        > "$sdir/puredns-subdomains.txt" 2>>"$LOG"; then
        local nsubs=0
        nsubs=$(grep -c '\.' "$sdir/puredns-subdomains.txt" 2>/dev/null || true)
        ok "done in $(( $(now_s) - t0 ))s → 08-puredns/puredns-subdomains.txt (${nsubs:-0} subdomains)"
        note_result "ok" "8 · DNS bruteforce" "08-puredns/ · ${nsubs:-0} subdomains"
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "8 · DNS bruteforce" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 9 — Vhost fuzzing (ffuf)
#  1) baseline: Content-Length of a non-existent vhost (curl -I)
#  2) ffuf pass A: -fs <baseline> -mc all
#  3) ffuf pass B: -fs <baseline> -fc 403
#  (user's 2nd example had "-H -H" typo -> single -H used)
#  output → recon/<domain>/09-vhost/
# ================================================================
step_vhost_ffuf() {
    local miss=0
    for t in ffuf curl; do
        if ! command -v "$t" >/dev/null 2>&1; then
            warn "Step 9 SKIPPED: $t not found (run ./install.sh / install manually)"
            miss=1
        fi
    done
    local wl_raw="$WL_DIR/common.txt"
    if [ ! -s "$wl_raw" ]; then
        warn "Step 9 SKIPPED: ${wl_raw} missing (ships with repo — check wordlists/)"
        miss=1
    fi
    if [ "$miss" -ne 0 ]; then
        note_result "skip" "9 · Vhost fuzzing" "ffuf/curl/common.txt missing"
        return 0
    fi

    local sdir_rel="$OUTDIR/09-vhost"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    # fresh run: a failed/skipped pass must not be papered over by last run's json
    rm -f "$sdir/vhost-mc-all.json" "$sdir/vhost-no403.json"

    # common.txt is a path wordlist. Used directly as a Host label, entries
    # containing '/' make an invalid header (HTTP 400) and dotted filenames
    # such as '.env' are not legal DNS labels. Keep only single labels.
    local wl="$sdir/vhost-wordlist.txt"
    awk 'length($0) <= 63 && $0 ~ /^[A-Za-z0-9][A-Za-z0-9-]*$/ {print}' "$wl_raw" \
        | sort -u > "$wl"
    if [ ! -s "$wl" ]; then
        err "no legal vhost labels in ${wl_raw}"
        note_result "fail" "9 · Vhost fuzzing" "no legal host labels in common.txt"
        return 0
    fi
    info "vhost wordlist: $(wc -l < "$wl" | tr -d ' ') labels (filtered from common.txt)"

    # ffuf's default User-Agent is blocked by Cloudflare (HTTP 403 with a
    # different body length for every request). Use a browser UA so the
    # baseline (-fs) actually identifies the wildcard/default vhost response.
    local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

    # --- baseline: what does a NON-existent vhost return? ---
    cmd "curl -sI http://${domain} -H 'Host: defnotvalid.${domain}'   (baseline Content-Length)"
    curl -s -I -A "$ua" "http://${domain}" -H "Host: defnotvalid.${domain}" \
        > "$sdir/vhost-baseline.txt" 2>>"$LOG" || true
    local base_cl
    base_cl=$(grep -i '^Content-Length:' "$sdir/vhost-baseline.txt" 2>/dev/null \
        | head -1 | grep -oE '[0-9]+' || true)

    if [ -z "$base_cl" ]; then
        err "baseline FAILED: no Content-Length from non-existent vhost — cannot set -fs"
        err "see ${sdir}/vhost-baseline.txt"
        note_result "fail" "9 · Vhost fuzzing" "baseline: no Content-Length"
        return 0
    fi
    info "baseline CL=${base_cl} (defnotvalid.${domain})"

    # --- ffuf passes (absolute wordlist + -o json; browser UA avoids WAF 403) ---
    # '&&' so pass A failure aborts instead of reporting pass B alone as ok
    cmd "ffuf -w common.txt:FUZZ -u http://${domain}/ -H 'Host: FUZZ.${domain}' -fs ${base_cl}   (2 passes: -mc all, then -fc 400,403)"
    echo
    echo "━━━ Vhost Fuzzing Pass A: -mc all (all status codes except baseline)"
    echo "━━━ Command: ffuf -w ${wl}:FUZZ -u http://${domain}/ -H 'Host: FUZZ.${domain}' -H 'User-Agent: ${ua}' -fs ${base_cl} -fc 400 -mc all -rate 20 -t 50"
    echo
    if {
        # pass A: all status codes except baseline size/invalid Host
        ffuf -w "${wl}:FUZZ" -u "http://${domain}/" -H "Host: FUZZ.${domain}" \
            -H "User-Agent: ${ua}" -fs "$base_cl" -fc 400 -mc all \
            -rate 20 -t 50 \
            -of json -o "$sdir/vhost-mc-all.json" \
        && echo
        echo "━━━ Vhost Fuzzing Pass B: -fc 400,403 (exclude 400/403)"
        echo "━━━ Command: ffuf -w ${wl}:FUZZ -u http://${domain}/ -H 'Host: FUZZ.${domain}' -H 'User-Agent: ${ua}' -fs ${base_cl} -fc 400,403 -rate 20 -t 50"
        echo
        # pass B: exclude 400/403
        ffuf -w "${wl}:FUZZ" -u "http://${domain}/" -H "Host: FUZZ.${domain}" \
            -H "User-Agent: ${ua}" -fs "$base_cl" -fc 400,403 \
            -rate 20 -t 50 \
            -of json -o "$sdir/vhost-no403.json"
    } >>"$LOG" 2>&1; then
        local n1=0 n2=0
        n1=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("results",[])))' "$sdir/vhost-mc-all.json" 2>/dev/null || echo "?")
        n2=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("results",[])))' "$sdir/vhost-no403.json" 2>/dev/null || echo "?")
        ok "done in $(( $(now_s) - t0 ))s → 09-vhost/ (mc-all: ${n1}, no403: ${n2} matches)"
        note_result "ok" "9 · Vhost fuzzing" "09-vhost/ · ${n1}+${n2} matches (CL=${base_cl})"
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "9 · Vhost fuzzing" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 10 — Zone Transfer attack (AXFR)
#  1) nslookup -type=NS <domain>          (list nameservers)
#  2) dig axfr <ns> <domain>              (per nameserver attempt)
#  Success marker: "XFR size:" or ANSWER: >0 in dig output.
#  output → recon/<domain>/10-zone-transfer/
# ================================================================
step_zone_transfer() {
    local miss=0
    for t in nslookup dig; do
        if ! command -v "$t" >/dev/null 2>&1; then
            warn "Step 10 SKIPPED: $t not found (install manually / ./install.sh)"
            miss=1
        fi
    done
    if [ "$miss" -ne 0 ]; then
        note_result "skip" "10 · Zone transfer" "nslookup/dig missing"
        return 0
    fi

    local sdir_rel="$OUTDIR/10-zone-transfer"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    # --- list nameservers (user's exact command) ---
    cmd "nslookup -type=NS ${domain}"
    nslookup -type=NS "$domain" > "$sdir/nslookup-NS.txt" 2>>"$LOG" || true
    local nss
    nss=$(grep -i 'nameserver =' "$sdir/nslookup-NS.txt" 2>/dev/null \
        | awk '{print $NF}' | sed 's/\.$//' | sort -u || true)
    # fallback: nslookup output formats vary -> clean list from dig
    if [ -z "$nss" ]; then
        nss=$(dig +short NS "$domain" 2>>"$LOG" | sed 's/\.$//' | sort -u || true)
    fi
    if [ -z "$nss" ]; then
        err "no nameservers found for ${domain} — nothing to attempt"
        note_result "fail" "10 · Zone transfer" "no nameservers discovered"
        return 0
    fi

    local total=0 xfr_ok=0
    # --- attempt zone transfer (AXFR) against each nameserver ---
    for ns in $nss; do
        total=$((total + 1))
        local out="$sdir/axfr-${ns}.txt"
        cmd "dig axfr ${ns} ${domain}"
        if dig axfr "$ns" "$domain" > "$out" 2>>"$LOG"; then
            if grep -qiE 'XFR size|ANSWER: [1-9]' "$out"; then
                xfr_ok=$((xfr_ok + 1))
                err "*** AXFR ACCEPTED by ${ns} — full zone exposed! ***"
            else
                info "AXFR refused by ${ns} (no records)"
            fi
        else
            info "AXFR failed/refused by ${ns} (expected — most servers say no)"
        fi
    done

    if [ "$xfr_ok" -gt 0 ]; then
        ok "done in $(( $(now_s) - t0 ))s → 10-zone-transfer/ — ⚠ ${xfr_ok}/${total} nameservers ALLOWED transfer"
        note_result "ok" "10 · Zone transfer" "⚠ AXFR open on ${xfr_ok}/${total} NS!"
    else
        ok "done in $(( $(now_s) - t0 ))s → 10-zone-transfer/ — 0/${total} nameservers allowed transfer (all refused)"
        note_result "ok" "10 · Zone transfer" "0/${total} NS allowed (all refused)"
    fi
}

# ================================================================
#  Step 12 — Public files: robots.txt / security.txt / sitemaps
#  (user's script; sections -> separate files, headers -> recon.log.
#   robots.txt fetched ONCE then grepped locally for section 3 —
#   same bytes as re-fetching, one fewer request.)
#  TODO(user "improvements to make later"): proper XML parse (namespaces,
#  .gz, indexes), recursive sitemap-index follow w/ limits, diff against
#  crawl/archive URLs. NOTE: a path in a sitemap is NOT a vuln by itself.
#  output → recon/<domain>/12-robots-sitemap/
# ================================================================
step_robots_sitemap() {
    if ! command -v curl >/dev/null 2>&1; then
        warn "Step 12 SKIPPED: curl not found"
        note_result "skip" "12 · robots/sitemap" "curl missing"
        return 0
    fi

    local sdir_rel="$OUTDIR/12-robots-sitemap"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"
    local domain="$DOMAIN"
    local base="https://${domain}"
    local t0; t0=$(now_s)

    cmd "curl robots.txt + security.txt + sitemap endpoints + sitemap.xml + http->https   (${base})"
    if {
        # 1. robots.txt (HIGH — may reveal unlinked paths)
        curl -sS -L --max-time 15 "$base/robots.txt" > "$sdir/robots.txt"

        # 2. security.txt (MEDIUM — disclosure policy / reporting contact)
        curl -sS -L --max-time 15 "$base/.well-known/security.txt" > "$sdir/security.txt"

        # 3. Sitemaps advertised in robots.txt (HIGH — nonstandard locations)
        grep -iE '^[[:space:]]*Sitemap:[[:space:]]*' "$sdir/robots.txt" \
            > "$sdir/advertised-sitemaps.txt" || true

        # 4. Common sitemap paths — status/type/final URL (MEDIUM)
        {
            local -a paths=(
                "sitemap.xml"
                "sitemap-index.xml"
                "sitemap_index.xml"
                "sitemapindex.xml"
                "sitemap1.xml"
                "sitemap-main.xml"
                "sitemap.xml.gz"
            )
            for path in "${paths[@]}"; do
                echo "----- /$path -----"
                curl -sS -L --max-time 15 \
                    -o /dev/null \
                    -w 'HTTP: %{http_code} | Type: %{content_type} | Final URL: %{url_effective}\n' \
                    "$base/$path"
            done
        } > "$sdir/sitemap-endpoint-checks.txt"

        # 5. URLs advertised inside sitemap.xml (HIGH — page list to review)
        curl -sS -L --max-time 20 "$base/sitemap.xml" \
            | grep -oE '<loc>[^<]+' \
            | sed 's/<loc>//' > "$sdir/sitemap-urls.txt" || true

        # 6. HTTP->HTTPS + redirect behaviour (MEDIUM)
        curl -sS -L --max-time 15 \
            -o /dev/null \
            -w 'HTTP: %{http_code} | Final URL: %{url_effective}\n' \
            "http://$domain" > "$sdir/http-redirect-check.txt"
    :  # verdict = produced files (fail-soft: transient curl/network blips must not fail the step)
    } >>"$LOG" 2>&1; then
        local n_adv=0 n_loc=0 nfiles=0
        n_adv=$(grep -ci 'sitemap:' "$sdir/advertised-sitemaps.txt" 2>/dev/null || true)
        n_loc=$(grep -c 'http' "$sdir/sitemap-urls.txt" 2>/dev/null || true)
        nfiles=$(find "$sdir" -type f -size +0c | wc -l)
        [ -s "$sdir/robots.txt" ] || warn "robots.txt fetch failed (curl error / network?) — 0 bytes"
        if [ "$nfiles" -eq 0 ]; then
            err "FAILED — all curls produced no output — see ${LOG}"
            note_result "fail" "12 · robots/sitemap" "failed — see recon.log"
        else
            ok "done in $(( $(now_s) - t0 ))s → 12-robots-sitemap/ (advertised: ${n_adv:-0}, sitemap URLs: ${n_loc:-0})"
            note_result "ok" "12 · robots/sitemap" "12-robots-sitemap/ · ${n_loc:-0} sitemap URLs"
        fi
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "12 · robots/sitemap" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 7 — Subdomain enumeration (subenum, user's own tool)
#  runs from ~/subenum:  ./subenum.sh -d <domain> -hp
#  (-hp writes the alive probes; prefix is "" for -d mode, only -l mode
#   prefixes filenames with "<dom>-")
#  source: ~/subenum/outputs/<domain>/alive/{https-subs,alive-domains}.txt
#  copied to: recon/<domain>/subdomains/
#  AFTER the CT merges, BOTH final files are MOVED UP to recon/<domain>/:
#  https-subs.txt and alive-domains.txt (user: both belong in
#  recon/target.com/ directory — subdomains/ is only the staging area,
#  rmdir'd at the end of the step so an empty dir never lingers)
# ================================================================
step_subenum() {
    # fresh run: drop this target's previous final lists BEFORE the skip-guard —
    # steps 13/14 consume these roots unconditionally, so a skipped rerun must
    # never leave last run's data behind (staging files keep their rm below)
    rm -f "$OUTDIR/https-subs.txt" "$OUTDIR/alive-domains.txt"

    local subenum_dir="$HOME/subenum"
    if [ ! -f "$subenum_dir/subenum.sh" ]; then
        warn "Step 7 SKIPPED: subenum not found at ${subenum_dir} (run ./install.sh)"
        note_result "skip" "7 · Subenum" "subenum missing — run ./install.sh"
        return 0
    fi

    # user-specified destination (no NN- prefix)
    local sdir_rel="$OUTDIR/subdomains"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    # fresh run: drop this target's staging lists so a rerun never merges with
    # stale data (root finals were already dropped above the skip-guard)
    rm -f "$sdir/https-subs.txt" "$sdir/alive-domains.txt" "$sdir/temp"

    cmd "./subenum.sh -d ${domain} -hp   (cwd: ${subenum_dir})"
    # run in ITS dir (OUTPUT_DIR is CWD-relative: outputs/<domain>/...)
    if (
        cd "$subenum_dir"
        if [ -x "./subenum.sh" ]; then
            ./subenum.sh -d "$domain" -hp
        else
            bash ./subenum.sh -d "$domain" -hp    # exec bit missing fallback
        fi
    ) >>"$LOG" 2>&1; then
        # move this target's probe results into swarmrecon's tree
        local src="$subenum_dir/outputs/${domain}/alive"
        cp "$src/https-subs.txt"    "$sdir/https-subs.txt"    >>"$LOG" 2>&1 || true
        cp "$src/alive-domains.txt" "$sdir/alive-domains.txt" >>"$LOG" 2>&1 || true

        # Merge live CT subs into https-subs (user's CORRECTED command —
        # merges live-ctfr, NOT raw ctfr):
        #   cat live-ctfr-subdomains.txt https-subs.txt | sort -u > temp && mv temp https-subs.txt
        # (temp+mv required: shell would truncate https-subs.txt before cat reads it)
        local ctfr_live="$OUTDIR/06-ctfr/live-ctfr-subdomains.txt"
        if [ -s "$ctfr_live" ]; then
            if [ -s "$sdir/https-subs.txt" ]; then
                if cat "$ctfr_live" "$sdir/https-subs.txt" | sort -u > "$sdir/temp" \
                    && mv "$sdir/temp" "$sdir/https-subs.txt"; then
                    local n_merged=0
                    n_merged=$(grep -c 'http' "$sdir/https-subs.txt" 2>/dev/null || true)
                    info "merged live-ctfr + https-subs → https-subs.txt (${n_merged:-0} URLs)"
                else
                    err "merge failed — https-subs.txt kept subenum-only"
                    rm -f "$sdir/temp"
                fi
            else
                # subenum produced no https list -> seed it from live CT results
                cp "$ctfr_live" "$sdir/https-subs.txt" && \
                    info "https-subs.txt seeded from live-ctfr (subenum produced none)"
            fi
        else
            info "no live-ctfr-subdomains.txt (step 6 skipped or httpx missing) — https-subs unchanged"
        fi

        # alive-domains: same treatment (user's manual command — scheme stripped
        # from live-ctfr URLs first, since alive-domains holds bare hosts):
        #   sed 's|https\?://||' live.txt | cat - alive-domains.txt | sort -u > temp && mv temp alive-domains.txt
        if [ -s "$sdir/alive-domains.txt" ]; then
            if [ -s "$ctfr_live" ]; then
                if sed 's|https\?://||' "$ctfr_live" | cat - "$sdir/alive-domains.txt" | sort -u > "$sdir/temp" \
                    && mv "$sdir/temp" "$sdir/alive-domains.txt"; then
                    info "merged live-ctfr (scheme-stripped) + alive-domains → alive-domains.txt"
                else
                    err "alive merge failed — alive-domains.txt kept subenum-only"
                    rm -f "$sdir/temp"
                fi
            fi
        elif [ -s "$ctfr_live" ]; then
            # subenum produced no alive list -> seed it from live CT hosts
            sed 's|https\?://||' "$ctfr_live" > "$sdir/alive-domains.txt" \
                && info "alive-domains.txt seeded from live-ctfr (subenum produced none)"
        fi

        # FINAL LOCATION (user): https-subs.txt belongs directly in
        # recon/<domain>/ after the merge — not inside subdomains/.
        if [ -s "$sdir/https-subs.txt" ]; then
            if mv -f "$sdir/https-subs.txt" "$OUTDIR/https-subs.txt"; then
                info "placed merged list → ${OUTDIR}/https-subs.txt"
            else
                err "could not move https-subs.txt to ${OUTDIR}/"
            fi
        fi
        # same for alive-domains.txt (user: "also need to be in recon/target.com/")
        if [ -s "$sdir/alive-domains.txt" ]; then
            if mv -f "$sdir/alive-domains.txt" "$OUTDIR/alive-domains.txt"; then
                info "placed merged list → ${OUTDIR}/alive-domains.txt"
            else
                err "could not move alive-domains.txt to ${OUTDIR}/"
            fi
        fi

        if [ -s "$OUTDIR/https-subs.txt" ] || [ -s "$OUTDIR/alive-domains.txt" ]; then
            local n_https=0 n_alive=0
            n_https=$(grep -c 'http' "$OUTDIR/https-subs.txt" 2>/dev/null || true)
            n_alive=$(grep -c '.' "$OUTDIR/alive-domains.txt" 2>/dev/null || true)
            ok "done in $(( $(now_s) - t0 ))s → https-subs.txt (${n_https:-0} URLs) + alive-domains.txt (${n_alive:-0} hosts)"
            note_result "ok" "7 · Subenum" "https-subs: ${n_https:-0} · alive: ${n_alive:-0}"
        else
            err "subenum ran but nothing copied — check ${subenum_dir}/outputs/${domain}/alive/"
            note_result "fail" "7 · Subenum" "no alive output produced — see recon.log"
        fi
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "7 · Subenum" "failed — see recon.log"
    fi

    # staging served its purpose — drop it when empty so it never lingers
    # (rmdir only succeeds on an empty dir; files stuck on a failed mv stay visible)
    rmdir "$sdir" 2>/dev/null || true
}

# ================================================================
#  Step 13 — Web crawling (user's exact pipeline)
#    waymore (venv @ ~/waymore) -> wayurls.txt      (moved into recon/<domain>/)
#    gau    echo $D | gau --threads 10 --subs | anew gauurls.txt
#    merge  cat wayurls gauurls | uro | sort -u > waygauurls.txt
#    hakrawler / katana / gospider  on https-subs.txt
#    extracturls.sh -f gooutput     -> alivesubsurls.txt (moved up to root)
#    final merge: cat waygauurls cleansubskatanaurls hakcrawlurls alivesubsurls
#                 | uro > merged-crawl.txt
#    filter.sh (domain via stdin) -> check/ ; downstream uses only
#    check/param-urls.txt
#    gf-scripts/gf-extract.sh check/param-urls.txt -> check/gf/gf-*.txt (pattern classes)
#  All crawl artifacts live directly in recon/<domain>/ (same convention
#  as https-subs.txt / alive-domains.txt).
# ================================================================
step_crawl() {
    local t0; t0=$(now_s)
    local ran=0 skipped=0

    # fresh run: drop previous crawl artifacts (recon.log truncates each run)
    rm -f "$OUTDIR/wayurls.txt" "$OUTDIR/gauurls.txt" "$OUTDIR/waygauurls.txt" \
          "$OUTDIR/hakcrawlurls.txt" "$OUTDIR/cleansubskatanaurls.txt" \
          "$OUTDIR/alivesubsurls.txt" "$OUTDIR/merged-crawl.txt"
    rm -rf "$OUTDIR/gooutput" "$OUTDIR/check"

    # Forward the orphaned Step 4/8/9/12 candidates before the crawlers read
    # https-subs.txt. This is the Step 13 half of the append-and-delete flow.
    merge_forward

    # --- 1. waymore (user: venv in ~/waymore, run there, then move file) ---
    local wayvenv; wayvenv="$(venv_activate "$HOME/waymore")"
    if [ -f "$wayvenv" ]; then
        cmd "waymore -i ${DOMAIN} -mode U -oU wayurls.txt   (cwd: ~/waymore)"
        if (
            repair_venv_python "$wayvenv"
            source "$wayvenv"
            cd "$HOME/waymore" || exit 1
            rm -f wayurls.txt                       # never move a stale file
            waymore -i "$DOMAIN" -mode U -oU wayurls.txt
        ) >>"$LOG" 2>&1; then
            if [ -f "$HOME/waymore/wayurls.txt" ]; then
                if mv -f "$HOME/waymore/wayurls.txt" "$OUTDIR/wayurls.txt"; then
                    local nw=0; nw=$(grep -c 'http' "$OUTDIR/wayurls.txt" 2>/dev/null || true)
                    ok "waymore → wayurls.txt (${nw:-0} URLs)"
                    ran=$((ran + 1))
                else
                    err "could not move wayurls.txt into ${OUTDIR}/"
                fi
            else
                err "waymore exited 0 but produced no wayurls.txt"
            fi
        else
            err "waymore FAILED (exit=$?) — see ${LOG}"
        fi
    else
        warn "waymore venv missing at ${HOME}/waymore/venv — skipped (python3 -m venv venv && pip install waymore)"
        skipped=$((skipped + 1))
    fi

    # --- 2. gau: echo $D | gau --threads 10 --subs | anew gauurls.txt ---
    if command -v gau >/dev/null 2>&1; then
        cmd "echo ${DOMAIN} | gau --threads 10 --subs | anew gauurls.txt"
        if command -v anew >/dev/null 2>&1; then
            if echo "$DOMAIN" | gau --threads 10 --subs 2>>"$LOG" | anew "$OUTDIR/gauurls.txt" >>"$LOG" 2>&1; then
                local ng=0; ng=$(grep -c 'http' "$OUTDIR/gauurls.txt" 2>/dev/null || true)
                if [ "${ng:-0}" -eq 0 ]; then
                    warn "gau returned 0 URLs — providers unreachable/rate-limited? config: ~/.gau.toml; debug: echo ${DOMAIN} | gau --subs --verbose"
                else
                    ok "gau → gauurls.txt (${ng:-0} URLs)"
                fi
                ran=$((ran + 1))
            else
                err "gau FAILED (exit=$?) — see ${LOG}"
                rm -f "$OUTDIR/gauurls.txt"   # never merge a partial crawl
            fi
        else
            warn "anew not found — gau output written directly"
            if echo "$DOMAIN" | gau --threads 10 --subs > "$OUTDIR/gauurls.txt" 2>>"$LOG"; then
                local ng=0; ng=$(grep -c 'http' "$OUTDIR/gauurls.txt" 2>/dev/null || true)
                if [ "${ng:-0}" -eq 0 ]; then
                    warn "gau returned 0 URLs — providers unreachable/rate-limited? config: ~/.gau.toml; debug: echo ${DOMAIN} | gau --subs --verbose"
                fi
                ran=$((ran + 1))
            else
                err "gau FAILED (exit=$?) — see ${LOG}"
                rm -f "$OUTDIR/gauurls.txt"   # never merge a partial crawl
            fi
        fi
    else
        warn "gau not found — skipped"; skipped=$((skipped + 1))
    fi

    # --- 3. merge: cat wayurls gauurls | uro | sort -u > waygauurls.txt ---
    local w_in="$OUTDIR/wayurls.txt" g_in="$OUTDIR/gauurls.txt" m_out="$OUTDIR/waygauurls.txt"
    local merge_inputs=()
    [ -s "$w_in" ] && merge_inputs+=("$w_in")
    [ -s "$g_in" ] && merge_inputs+=("$g_in")
    if [ "${#merge_inputs[@]}" -gt 0 ]; then
        cmd "cat wayurls.txt gauurls.txt | uro | sort -u > waygauurls.txt"
        if command -v uro >/dev/null 2>&1; then
            if cat "${merge_inputs[@]}" | uro | sort -u > "$m_out"; then
                local nm=0; nm=$(grep -c 'http' "$m_out" 2>/dev/null || true)
                ok "merge (way+gau via uro) → waygauurls.txt (${nm:-0} URLs)"; ran=$((ran + 1))
            else
                err "waygauurls merge FAILED"; rm -f "$m_out"
            fi
        else
            warn "uro not found — merging with plain sort -u"
            if cat "${merge_inputs[@]}" | sort -u > "$m_out"; then
                ran=$((ran + 1))
            else
                err "waygauurls merge FAILED"; rm -f "$m_out"
            fi
        fi
    else
        info "no wayurls/gauurls produced — waygauurls.txt skipped"
    fi

    # --- inputs for the crawlers ---
    local subs="$OUTDIR/https-subs.txt"

    # --- 4. cat https-subs.txt | hakrawler -subs -u -d 3 > hakcrawlurls.txt ---
    if [ ! -s "$subs" ]; then
        warn "https-subs.txt missing/empty (step 7) — hakrawler skipped"; skipped=$((skipped + 1))
    elif command -v hakrawler >/dev/null 2>&1; then
        cmd "cat https-subs.txt | hakrawler -subs -u -d 3 > hakcrawlurls.txt"
        if cat "$subs" | hakrawler -subs -u -d 3 > "$OUTDIR/hakcrawlurls.txt" 2>>"$LOG"; then
            local nh=0; nh=$(grep -c 'http' "$OUTDIR/hakcrawlurls.txt" 2>/dev/null || true)
            ok "hakrawler → hakcrawlurls.txt (${nh:-0} URLs)"; ran=$((ran + 1))
        else
            err "hakrawler FAILED (exit=$?) — see ${LOG}"
            rm -f "$OUTDIR/hakcrawlurls.txt"   # never merge a partial crawl
        fi
    else
        warn "hakrawler not found — skipped"; skipped=$((skipped + 1))
    fi

    # --- 5. cat https-subs.txt | katana -d 3 -jc -timeout 15 -c 20 | anew cleansubskatanaurls.txt ---
    if [ ! -s "$subs" ]; then
        warn "https-subs.txt missing/empty (step 7) — katana skipped"; skipped=$((skipped + 1))
    elif command -v katana >/dev/null 2>&1; then
        local kt_out="$OUTDIR/cleansubskatanaurls.txt"
        # Stop katana once the result file reaches this many URLs — the crawl
        # queue otherwise grows faster than it drains. 0 disables the cap.
        local kt_cap="${KATANA_URL_CAP:-1000000}"
        [[ "$kt_cap" =~ ^[0-9]+$ ]] || kt_cap=1000000
        local kt_rc=0 nk=0
        local kt_label="cat https-subs.txt | katana -d 3 -jc -timeout 15 -c 20 | anew cleansubskatanaurls.txt"
        [ "$kt_cap" -gt 0 ] && kt_label="${kt_label}  [cap ${kt_cap}]"
        cmd "$kt_label"
        if command -v anew >/dev/null 2>&1; then
            if cat "$subs" | katana -d 3 -jc -timeout 15 -c 20 2>>"$LOG" \
                 | anew "$kt_out" 2>>"$LOG" \
                 | awk -v max="$kt_cap" 'max > 0 && NR > max { exit } { print }' >/dev/null; then
                kt_rc=0
            else
                kt_rc=$?
            fi
        else
            warn "anew not found — katana output written directly"
            if cat "$subs" | katana -d 3 -jc -timeout 15 -c 20 2>>"$LOG" \
                 | awk -v max="$kt_cap" 'max > 0 && NR > max { exit } { print }' > "$kt_out"; then
                kt_rc=0
            else
                kt_rc=$?
            fi
        fi

        nk=$(grep -c 'http' "$kt_out" 2>/dev/null || true)
        if [ "$kt_rc" -eq 0 ]; then
            ok "katana → cleansubskatanaurls.txt (${nk:-0} URLs)"; ran=$((ran + 1))
        elif [ "$kt_cap" -gt 0 ] && [ "$(wc -l < "$kt_out" 2>/dev/null || echo 0)" -ge "$kt_cap" ]; then
            warn "katana URL cap reached (${kt_cap}) — stopped; continuing with the next sub-step"
            ok "katana → cleansubskatanaurls.txt (${nk:-0} URLs, capped)"; ran=$((ran + 1))
        else
            err "katana FAILED (exit=${kt_rc}) — see ${LOG}"
            rm -f "$kt_out"   # never merge a partial crawl
        fi
    else
        warn "katana not found — skipped"; skipped=$((skipped + 1))
    fi

    # --- 6. gospider -S https-subs.txt -o gooutput -c 10 -d 3 -t 20 ---
    if [ ! -s "$subs" ]; then
        warn "https-subs.txt missing/empty (step 7) — gospider skipped"; skipped=$((skipped + 1))
    elif command -v gospider >/dev/null 2>&1; then
        cmd "gospider -S https-subs.txt -o gooutput -c 10 -d 3 -t 20"
        if gospider -S "$subs" -o "$OUTDIR/gooutput" -c 10 -d 3 -t 20 >>"$LOG" 2>&1; then
            local ngs=0; ngs=$(find "$OUTDIR/gooutput" -type f 2>/dev/null | wc -l | tr -d ' ' || true)
            ok "gospider → gooutput/ (${ngs:-0} files)"; ran=$((ran + 1))
        else
            err "gospider FAILED (exit=$?) — see ${LOG}"
        fi
    else
        warn "gospider not found — skipped"; skipped=$((skipped + 1))
    fi

    # --- 7. extract alive URLs from gooutput (user's extracturls.sh) ---
    #   ./extracturls.sh -f gooutput -d example.com
    #   hard-requires dnsx + httpx (script checks both on line 40);
    #   writes allsubsurls.txt / alivesubdomains.txt / alivesubsurls.txt
    #   INTO gooutput/, then alivesubsurls.txt moves to recon/<domain>/ root.
    local extractor="$SWARM_DIR/extracturls.sh"
    if [ ! -d "$OUTDIR/gooutput" ] || [ -z "$(ls -A "$OUTDIR/gooutput" 2>/dev/null)" ]; then
        warn "gooutput/ empty (gospider skipped or failed) — extracturls skipped"
        skipped=$((skipped + 1))
    elif [ ! -f "$extractor" ]; then
        warn "extracturls.sh not found in ${SWARM_DIR} — skipped"
        skipped=$((skipped + 1))
    elif ! command -v dnsx >/dev/null 2>&1 || ! command -v httpx >/dev/null 2>&1; then
        warn "dnsx and/or httpx missing (required by extracturls.sh) — skipped"
        skipped=$((skipped + 1))
    else
        cmd "extracturls.sh -f gooutput -d ${DOMAIN}   (dnsx + 2x httpx)"
        if bash "$extractor" -f "$OUTDIR/gooutput" -d "$DOMAIN" >>"$LOG" 2>&1; then
            if [ -s "$OUTDIR/gooutput/alivesubsurls.txt" ]; then
                if mv -f "$OUTDIR/gooutput/alivesubsurls.txt" "$OUTDIR/alivesubsurls.txt"; then
                    local na=0; na=$(grep -c 'http' "$OUTDIR/alivesubsurls.txt" 2>/dev/null || true)
                    ok "extracturls → alivesubsurls.txt (${na:-0} alive URLs)"
                    ran=$((ran + 1))
                else
                    err "could not move alivesubsurls.txt to ${OUTDIR}/"
                fi
            else
                err "extracturls ran but produced no alivesubsurls.txt — see ${LOG}"
            fi
        else
            err "extracturls.sh FAILED (exit=$?) — see ${LOG}"
        fi
    fi

    # --- 8. Merge crawled results (user's exact command) ---
    #   cat waygauurls.txt cleansubskatanaurls.txt hakcrawlurls.txt alivesubsurls.txt | uro > merged-crawl.txt
    local crawl_inputs=() crawl_missing=()
    local f
    for f in waygauurls.txt cleansubskatanaurls.txt hakcrawlurls.txt alivesubsurls.txt; do
        if [ -s "$OUTDIR/$f" ]; then
            crawl_inputs+=("$OUTDIR/$f")
        else
            crawl_missing+=("$f")
        fi
    done
    if [ "${#crawl_missing[@]}" -gt 0 ]; then
        warn "crawl merge inputs missing: ${crawl_missing[*]}"
    fi
    if [ "${#crawl_inputs[@]}" -gt 0 ]; then
        cmd "cat waygauurls.txt cleansubskatanaurls.txt hakcrawlurls.txt alivesubsurls.txt | uro > merged-crawl.txt"
        if command -v uro >/dev/null 2>&1; then
            if cat "${crawl_inputs[@]}" | uro > "$OUTDIR/merged-crawl.txt"; then
                local nmc=0; nmc=$(grep -c 'http' "$OUTDIR/merged-crawl.txt" 2>/dev/null || true)
                ok "merge crawled results → merged-crawl.txt (${nmc:-0} URLs)"
                ran=$((ran + 1))
            else
                err "merged-crawl merge FAILED"; rm -f "$OUTDIR/merged-crawl.txt"
            fi
        else
            warn "uro not found — merging with plain sort -u"
            if cat "${crawl_inputs[@]}" | sort -u > "$OUTDIR/merged-crawl.txt"; then
                ran=$((ran + 1))
            else
                err "merged-crawl merge FAILED"; rm -f "$OUTDIR/merged-crawl.txt"
            fi
        fi
    else
        info "no crawl outputs produced — merged-crawl.txt skipped"
    fi

    # --- 9. filter.sh: liveness + param extraction (user's tool) ---
    #   ./filter.sh   (interactive: "Enter domain..." fed via stdin)
    #   runs with cwd=recon/<domain>/ so its default input merged-crawl.txt
    #   resolves there and outputs land in recon/<domain>/check/.
    #   6 categories written; downstream consumes ONLY check/param-urls.txt.
    local filterer="$SWARM_DIR/filter.sh"
    if [ ! -s "$OUTDIR/merged-crawl.txt" ]; then
        warn "merged-crawl.txt missing/empty — filter.sh skipped"
        skipped=$((skipped + 1))
    elif [ ! -f "$filterer" ]; then
        warn "filter.sh not found in ${SWARM_DIR} — skipped"
        skipped=$((skipped + 1))
    elif ! command -v httpx >/dev/null 2>&1; then
        warn "httpx missing (required by filter.sh) — skipped"
        skipped=$((skipped + 1))
    else
        cmd "echo ${DOMAIN} | filter.sh   (cwd: recon/${DOMAIN}/)"
        if ( cd "$OUTDIR" && echo "$DOMAIN" | bash "$filterer" ) >>"$LOG" 2>&1; then
            if [ -s "$OUTDIR/check/param-urls.txt" ]; then
                local npu=0; npu=$(grep -c 'http' "$OUTDIR/check/param-urls.txt" 2>/dev/null || true)
                ok "filter.sh → check/param-urls.txt (${npu:-0} param URLs)"
                ran=$((ran + 1))
            else
                warn "filter.sh ran but produced 0 live URLs — no param-urls.txt"
                ran=$((ran + 1))
            fi
        else
            err "filter.sh FAILED (exit=$?) — domain mismatch or input problem, see ${LOG}"
        fi
    fi

    # --- 10. gf-scripts/gf-extract.sh: gf-pattern classification of param URLs ---
    #   ./gf-scripts/gf-extract.sh check/param-urls.txt check/gf
    #   ($1 must be the input FILE — passing the bare "check" dir errors
    #    at gf-scripts/gf-extract.sh line 21; args are explicit here to avoid that)
    local gfex="$SWARM_DIR/gf-scripts/gf-extract.sh"
    if [ ! -s "$OUTDIR/check/param-urls.txt" ]; then
        warn "check/param-urls.txt missing/empty (filter.sh) — gf-extract skipped"
        skipped=$((skipped + 1))
    elif [ ! -f "$gfex" ]; then
        warn "gf-scripts/gf-extract.sh not found in ${SWARM_DIR} — skipped"
        skipped=$((skipped + 1))
    elif ! command -v gf >/dev/null 2>&1; then
        warn "gf not found (go install github.com/tomnomnom/gf@latest) — skipped"
        skipped=$((skipped + 1))
    elif [ ! -d "$HOME/.gf" ]; then
        warn "gf patterns missing at ${HOME}/.gf — run ./gf-scripts/sync-gf-patterns.sh (bundled in gf-patterns/) — skipped"
        skipped=$((skipped + 1))
    else
        cmd "gf-extract.sh check/param-urls.txt check/gf   (cwd: recon/${DOMAIN}/)"
        if ( cd "$OUTDIR" && bash "$gfex" check/param-urls.txt check/gf ) >>"$LOG" 2>&1; then
            local ngf=0 ngf_urls=0
            ngf=$(find "$OUTDIR/check/gf" -name 'gf-*.txt' 2>/dev/null | wc -l | tr -d ' ')
            if [ "${ngf:-0}" -gt 0 ]; then
                # expand the glob only when files are known to exist (0 files ->
                # unmatched glob + pipefail + set -e would kill the script here)
                ngf_urls=$(cat "$OUTDIR/check/gf"/gf-*.txt 2>/dev/null | wc -l | tr -d ' ')
                ok "gf-extract → check/gf/ (${ngf} pattern files, ${ngf_urls} matches)"
                ran=$((ran + 1))
            else
                warn "gf-extract ran but no pattern matched — 0 gf-*.txt files"
                ran=$((ran + 1))
            fi
        else
            err "gf-scripts/gf-extract.sh FAILED (exit=$?) — see ${LOG}"
        fi
    fi

    # step verdict
    if [ "$ran" -gt 0 ]; then
        ok "done in $(( $(now_s) - t0 ))s — ${ran} sub-steps ran, ${skipped} skipped"
        note_result "ok" "13 · Web crawl" "${ran} ran / ${skipped} skipped"
    elif [ "$skipped" -gt 0 ]; then
        note_result "skip" "13 · Web crawl" "all skipped — missing tools/inputs"
    else
        note_result "fail" "13 · Web crawl" "all sub-steps failed — see recon.log"
    fi
}

# ================================================================
#  Step 14 — High-value path hunt (user's exact ffuf invocation)
#    purpose: secrets, information disclosure, endpoints, errors,
#             juicy file extensions  (wordlists/high-value-paths.txt)
#    sources: https://<domain> (apex) + every host in step-7's
#    alive-domains.txt (bare hosts); per-host ffuf, merged results
# ================================================================
step_highvalue() {
    local t0; t0=$(now_s)
    local sdir_rel="$OUTDIR/14-high-value"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"
local wl="$WL_DIR/high-value-paths.txt"
    local targets=("https://${DOMAIN}")

    # fresh run: drop previous results so a skipped/failed rerun can't show stale hits
    rm -f "$sdir"/high-value-*.json "$sdir/high-value-results.txt"

    # Step 14 half of the append-and-delete flow. Step 13 normally already
    # appended these; regenerating and appending again is idempotent because
    # _append_unique dedupes. It also covers a skipped/failed Step 13.
    merge_forward

    local miss=0
    if ! command -v ffuf >/dev/null 2>&1; then
        warn "Step 14 SKIPPED: ffuf not found (run ./install.sh)"
        miss=1
    fi
    if [ ! -s "$wl" ]; then
        warn "Step 14 SKIPPED: wordlist missing (check wordlists/)"
        miss=1
    fi
    if [ "$miss" -ne 0 ]; then
        note_result "skip" "14 · High-value" "ffuf/wordlist missing"
        return 0
    fi

    info "high-value wordlist: $(wc -l < "$wl" | tr -d ' ') paths"

    # sources: apex (above) + every host in step-7's alive-domains.txt
    local adoms="$OUTDIR/alive-domains.txt"
    if [ -s "$adoms" ]; then
        local h seen="|${DOMAIN}|"
        while IFS= read -r h; do
            h="${h#http://}"; h="${h#https://}"; h="${h%/}"
            [ -z "$h" ] && continue
            case "$seen" in *"|$h|"*) continue ;; esac
            seen+="|$h|"
            targets+=("https://$h")
        done < "$adoms"
    else
        warn "alive-domains.txt missing/empty — step 14 covers apex only"
    fi

    info "ffuf -w high-value-paths.txt — ${#targets[@]} target(s)"
    local t t_json
    local -a t_files=()
    local i=1
    for t in "${targets[@]}"; do
        echo
        echo "━━━ Target $i/${#targets[@]}: ${t}"
        echo "━━━ Command: ffuf -w high-value-paths.txt -u ${t%/}/FUZZ -mc 200,301,302,401,403 -ac -rate 20 -t 50"
        echo
        t_json="$sdir/high-value-$(printf '%s' "$t" | sed 's|^[a-zA-Z]*://||; s|[^A-Za-z0-9._-]|_|g').json"
        cmd "ffuf -w high-value-paths.txt -u ${t%/}/FUZZ -mc 200,301,302,401,403 -ac -rate 20 -t 50"
        ffuf \
            -w "$wl" \
            -u "${t%/}/FUZZ" \
            -mc 200,301,302,401,403 \
            -ac \
            -rate 20 \
            -t 50 \
            -o "$t_json" \
            -of json >>"$LOG" 2>&1 || warn "ffuf exited nonzero for $t (network?) — see ${LOG}"
        if [ -s "$t_json" ]; then
            t_files+=("$t_json")
        else
            warn "no results file for $t"
        fi
        ((i++))
    done

    # merge per-host results into the contract pair (results.json/.txt)
    if [ ${#t_files[@]} -eq 1 ]; then
        cp "${t_files[0]}" "$sdir/high-value-results.json" \
            || warn "cp failed — high-value-results.json missing"
    elif [ ${#t_files[@]} -gt 1 ] && command -v jq >/dev/null 2>&1; then
        # merge ALL hosts' .results — plain `add` is right-biased (every earlier
        # host was overwritten by the next file); verified 2026-10-19
        jq -s '{results: [.[] | (.results // []) | .[]]}' "${t_files[@]}" \
            > "$sdir/high-value-results.json" \
            || warn "jq merge failed — high-value-results.json may be partial"
    elif [ ${#t_files[@]} -gt 1 ]; then
        python3 - "$sdir/high-value-results.json" "${t_files[@]}" <<'PYEOF' \
            || warn "python merge failed — high-value-results.json may be partial"
import json, sys
out = {"results": []}
for f in sys.argv[2:]:
    try:
        out["results"].extend(json.load(open(f)).get("results", []))
    except Exception:
        pass
json.dump(out, open(sys.argv[1], "w"))
PYEOF
    fi
    # t_files=0 → no merge written; the verdict below reports "no results file"
    if [ -s "$sdir/high-value-results.json" ]; then
        local nres=0
        if command -v jq >/dev/null 2>&1; then
            nres=$(jq -r '.results | length' "$sdir/high-value-results.json" 2>/dev/null || echo 0)
            # flatten URLs (user): jq -r '.results[].url' ... > high-value-results.txt
            if jq -r '.results[].url' "$sdir/high-value-results.json" > "$sdir/high-value-results.txt" 2>>"$LOG"; then
                info "high-value-results.txt extracted (${nres:-0} URLs)"
            else
                warn "jq URL extraction failed — high-value-results.txt not written"
            fi
        else
            warn "jq not found — hit count and .txt extraction skipped (json kept)"
        fi
        ok "done in $(( $(now_s) - t0 ))s → 14-high-value/high-value-results.json (${nres:-0} hits)"
        note_result "ok" "14 · High-value" "14-high-value/ · ${nres:-0} hits"
    else
        err "ffuf produced no results file (failed to run) — see ${LOG}"
        note_result "fail" "14 · High-value" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 15 — JavaScript collection + endpoint extraction
#  check/livejslinks.txt → js_files/ → analysis.md → LinkFinder endpoints
#  Fail-soft: missing tools/empty lists skip this step only.
# ================================================================
step_js() {
    local t0; t0=$(now_s)
    local sdir="$OUTDIR/js_files"
    local check_dir="$OUTDIR/check"
    local js_links="$SWARM_DIR/js-scripts/js-links.sh"
    local downloader="$SWARM_DIR/js-scripts/downloadjs.py"
    local analyzer="$SWARM_DIR/js-scripts/analyzejs.py"
    local lf_wrapper="$SWARM_DIR/js-scripts/linkfinder.sh"
    local resolver="$SWARM_DIR/js-scripts/js-endpoints.py"

    if [ "${SWARMRECON_JS:-1}" = "0" ]; then
        warn "Step 15 SKIPPED: SWARMRECON_JS=0"
        note_result "skip" "15 · JavaScript" "disabled by SWARMRECON_JS=0"
        return 0
    fi
    if [ ! -s "$check_dir/crawledurls.txt" ]; then
        warn "Step 15 SKIPPED: check/crawledurls.txt missing/empty (run Step 13)"
        note_result "skip" "15 · JavaScript" "check/crawledurls.txt missing — run Step 13"
        return 0
    fi
    if [ ! -f "$js_links" ] || [ ! -f "$downloader" ]; then
        warn "Step 15 SKIPPED: js-links.sh or downloadjs.py missing"
        note_result "skip" "15 · JavaScript" "js-links.sh/downloadjs.py missing"
        return 0
    fi

    # fresh outputs: a failed rerun must not leave stale JS endpoints behind
    rm -f "$check_dir/livejslinks.txt" "$check_dir/livejslinks-dropped.txt" \
          "$check_dir/js-endpoints.txt" "$check_dir/js-endpoints-absolute.txt"
    rm -rf -- "$sdir"
    mkdir -p "$sdir/files" "$OUTDIR/urls" "$check_dir"

    cmd "js-links.sh --domain ${DOMAIN} --input check/crawledurls.txt"
    if ! ( cd "$OUTDIR" && bash "$js_links" \
            --domain "$DOMAIN" \
            --input check/crawledurls.txt \
            --output check/livejslinks.txt \
            --dropped check/livejslinks-dropped.txt ) >>"$LOG" 2>&1; then
        err "js-links.sh failed — see ${LOG}"
        note_result "fail" "15 · JavaScript" "js-links.sh failed — see recon.log"
        return 0
    fi

    local njs=0
    njs=$(grep -c . "$check_dir/livejslinks.txt" 2>/dev/null || true)
    if [ "${njs:-0}" -eq 0 ]; then
        warn "Step 15: no .js/.mjs/.cjs URLs after filtering"
        note_result "skip" "15 · JavaScript" "0 JS URLs in crawl output"
        return 0
    fi
    ok "check/livejslinks.txt → ${njs} JS URL(s)"

    # Scope boundary: prefer an explicit/user scope file; otherwise build
    # exact:<host> entries from the JS URL list so the downloader cannot roam.
    local scope_file="$sdir/scope.txt"
    local user_scope="${SWARMRECON_SCOPE_FILE:-}"
    if [ -z "$user_scope" ]; then
        for candidate in \
            "$OUTDIR/scope/scope-engagement.txt" \
            "$OUTDIR/scope/scope.txt" \
            "$OUTDIR/scope.txt"; do
            [ -s "$candidate" ] || continue
            user_scope="$candidate"
            break
        done
    fi
    if [ -n "$user_scope" ] && [ -s "$user_scope" ]; then
        if [ "$user_scope" != "$scope_file" ]; then
            cp -f "$user_scope" "$scope_file" || {
                err "could not copy scope file to ${scope_file}"
                note_result "fail" "15 · JavaScript" "scope file copy failed"
                return 0
            }
        fi
        info "scope: ${user_scope}"
    else
        if [ -n "$user_scope" ]; then
            warn "scope file missing/empty: ${user_scope} — deriving exact hosts from JS list"
        fi
        if ! python3 - "$check_dir/livejslinks.txt" "$scope_file" <<'PY' >>"$LOG" 2>&1
import sys
from urllib.parse import urlsplit

hosts = set()
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        host = (urlsplit(line.strip()).hostname or "").lower()
    except ValueError:
        continue
    if host:
        hosts.add(host)
with open(sys.argv[2], "w", encoding="utf-8") as out:
    for host in sorted(hosts):
        out.write(f"exact:{host}\n")
PY
        then
            err "could not build ${scope_file}"
            note_result "fail" "15 · JavaScript" "scope generation failed"
            return 0
        fi
        info "scope: derived exact hosts from JS list → ${scope_file}"
    fi

    if [ ! -s "$scope_file" ]; then
        warn "Step 15: scope file is empty — downloader would refuse every URL"
        note_result "skip" "15 · JavaScript" "empty scope file"
        return 0
    fi

    cmd "downloadjs.py --input check/livejslinks.txt --scope-file js_files/scope.txt --out js_files"
    if ! ( cd "$OUTDIR" && python3 "$downloader" \
            --input check/livejslinks.txt \
            --scope-file js_files/scope.txt \
            --out js_files ) >>"$LOG" 2>&1; then
        err "downloadjs.py failed — see ${LOG}"
        note_result "fail" "15 · JavaScript" "downloadjs.py failed — see recon.log"
        return 0
    fi

    local manifest="$sdir/manifest.tsv"
    if [ ! -s "$manifest" ]; then
        warn "Step 15: downloader produced no manifest"
        note_result "fail" "15 · JavaScript" "manifest missing"
        return 0
    fi

    local n_ok=0
    n_ok=$(awk -F'\t' 'NR > 1 && ($2 == "OK" || $2 == "SKIP" || ($2 ~ /^[0-9]+$/ && $2 >= 200 && $2 < 300)) { n++ } END { print n + 0 }' "$manifest")
    local n_files=$n_ok
    if [ "$n_files" -eq 0 ]; then
        warn "Step 15: 0 JS files downloaded (see js_files/dropped.txt and recon.log)"
        note_result "fail" "15 · JavaScript" "0 files downloaded"
        return 0
    fi

    # OpenSwarm-compatible URL/local lists.
    if python3 - "$manifest" "$OUTDIR/urls/js_files.txt" "$OUTDIR/urls/js_files_local.txt" <<'PY' >>"$LOG" 2>&1
import csv
import sys
from pathlib import Path

manifest = Path(sys.argv[1])
urls_out = Path(sys.argv[2])
local_out = Path(sys.argv[3])
base = manifest.parent
urls = []
local = []
seen_urls = set()
seen_local = set()

with manifest.open(encoding="utf-8", errors="replace", newline="") as stream:
    for row in csv.DictReader(stream, delimiter="\t"):
        status = (row.get("status") or "").upper()
        success = status in {"OK", "SKIP"} or (status.isdigit() and 200 <= int(status) < 300)
        if not success:
            continue
        url = (row.get("url") or "").strip()
        rel = (row.get("path") or "").strip()
        if url and url not in seen_urls:
            seen_urls.add(url)
            urls.append(url)
        if rel:
            path = (base / rel).resolve()
            if path.is_file() and str(path) not in seen_local:
                seen_local.add(str(path))
                local.append(str(path))

urls_out.write_text("\n".join(urls) + ("\n" if urls else ""), encoding="utf-8")
local_out.write_text("\n".join(local) + ("\n" if local else ""), encoding="utf-8")
PY
    then
        info "urls/js_files.txt + urls/js_files_local.txt written"
    else
        warn "could not write urls/js_files*.txt — see ${LOG}"
    fi

    if [ -f "$analyzer" ]; then
        cmd "analyzejs.py --input js_files --manifest js_files/manifest.tsv"
        if ( cd "$OUTDIR" && python3 "$analyzer" \
                --input js_files \
                --manifest js_files/manifest.tsv \
                --scope-file js_files/scope.txt \
                --out js_files/analysis.md ) >>"$LOG" 2>&1; then
            ok "js_files/analysis.md written"
        else
            warn "analyzejs.py failed — see ${LOG}"
        fi
    else
        warn "analyzejs.py missing — offline JS analysis skipped"
    fi

    local lf_home="${LINKFINDER_HOME:-$HOME/LinkFinder}"
    local lf_available=0
    if [ -f "$lf_home/linkfinder.py" ] && \
       { [ -x "$lf_home/venv/bin/python" ] || [ -x "$lf_home/.venv/bin/python" ]; }; then
        lf_available=1
    fi

    if [ "$lf_available" -eq 1 ] && [ -f "$lf_wrapper" ]; then
        cmd "linkfinder.sh -i js_files/files --raw-out js_files/linkfinder.raw.txt"
        if ( cd "$OUTDIR" && bash "$lf_wrapper" \
                -i js_files/files \
                --raw-out js_files/linkfinder.raw.txt ) > "$sdir/linkfinder.txt" 2>>"$LOG"; then
            local nlf=0
            nlf=$(grep -c . "$sdir/linkfinder.txt" 2>/dev/null || true)
            ok "js_files/linkfinder.txt → ${nlf:-0} endpoint(s)"
        else
            warn "linkfinder.sh failed — see ${LOG}"
        fi
    else
        warn "LinkFinder not installed at ${lf_home} — LinkFinder endpoints skipped"
    fi

    if [ "$lf_available" -eq 1 ] && [ -f "$resolver" ]; then
        cmd "js-endpoints.py --input js_files --manifest js_files/manifest.tsv"
        if ( cd "$OUTDIR" && python3 "$resolver" \
                --input js_files \
                --manifest js_files/manifest.tsv \
                --scope-file js_files/scope.txt ) >>"$LOG" 2>&1; then
            ok "check/js-endpoints.txt + check/js-endpoints-absolute.txt written"
        else
            warn "js-endpoints.py failed — see ${LOG}"
        fi
    elif [ ! -f "$resolver" ]; then
        warn "js-endpoints.py missing — endpoint resolution skipped"
    fi

    local n_abs=0
    n_abs=$(grep -c . "$check_dir/js-endpoints-absolute.txt" 2>/dev/null || true)
    ok "done in $(( $(now_s) - t0 ))s → js_files/ (${n_files} files) · ${n_abs:-0} absolute endpoints"
    note_result "ok" "15 · JavaScript" "js_files/ · ${n_files} files · ${n_abs:-0} endpoints"
}

# ================================================================
#  Step 3 — Passive intel (whois · msftrecon · Scopify · Spoofy · cloud_enum)
#  openswarm Phase-3 parity: same module commands and output filenames as
#  scripts/tools/phase-intel.sh (so phase3-3b-4-skip-prompt.md copies line up).
#  output → recon/<domain>/03-intel/
# ================================================================
step_intel() {
    local t0; t0=$(now_s)
    local sdir_rel="$OUTDIR/03-intel"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"
    local domain="$DOMAIN"
    local tools_dir="$HOME/.local/bin"
    local ran=0 skipped=0

    local act_msft act_scop act_spoof act_cloud
    act_msft="$(venv_activate "$tools_dir/msftrecon")"
    act_scop="$(venv_activate "$tools_dir/Scopify")"
    act_spoof="$(venv_activate "$tools_dir/Spoofy")"
    act_cloud="$(venv_activate "$tools_dir/cloud_enum")"

    # fresh-run hygiene: truncate every module output
    : > "$sdir/domain_info_general.txt"
    : > "$sdir/azure_tenant_domains.txt"
    : > "$sdir/scopify.txt"
    : > "$sdir/spoof.txt"
    : > "$sdir/cloud_enum.txt"

    info "03-intel/ → ${sdir}"

    # --- whois (plain, no venv) ---
    # Query the FULL domain: unfurl %r is only the root label ("trybrowzer",
    # not "trybrowzer.com") — a TLD-less whois returns nothing useful. (openswarm
    # phase-intel.sh uses %r here too, but tees silently so the failure is hidden.)
    # Verdict by output, not exit code: some whois servers exit non-zero while
    # still printing a record.
    if command -v whois >/dev/null 2>&1; then
        local whois_out="$sdir/.whois.tmp"
        cmd "whois ${domain}"
        whois "$domain" >"$whois_out" 2>>"$LOG" || true
        if [ -s "$whois_out" ]; then
            cat "$whois_out" >> "$sdir/domain_info_general.txt"
            ran=$((ran + 1))
        else
            warn "whois returned nothing for ${domain}"
            skipped=$((skipped + 1))
        fi
        rm -f "$whois_out"
    else
        warn "whois not installed — skipped"
        skipped=$((skipped + 1))
    fi

    # --- msftrecon (appends to domain_info_general + azure tenant grep) ---
    local msft_script="$tools_dir/msftrecon/msftrecon/msftrecon.py"
    if [ -f "$msft_script" ] && [ -n "$act_msft" ]; then
        local msft_out="$sdir/.msftrecon.tmp"
        cmd "python3 msftrecon.py -d ${domain}   (venv: ~/.local/bin/msftrecon)"
        (
            repair_venv_python "$act_msft"
            source "$act_msft"
            python3 "$msft_script" -d "$domain"
        ) >"$msft_out" 2>&1 || true
        if [ -s "$msft_out" ]; then
            cat "$msft_out" >> "$sdir/domain_info_general.txt"
            grep -iE 'microsoft|azure|tenant' "$msft_out" > "$sdir/azure_tenant_domains.txt" 2>/dev/null || true
            ran=$((ran + 1))
        else
            warn "msftrecon produced no output"
            skipped=$((skipped + 1))
        fi
        rm -f "$msft_out"
    else
        warn "msftrecon missing — skipped (./install.sh)"
        skipped=$((skipped + 1))
    fi

    # --- Scopify (needs unfurl for the company name) ---
    local scop_script="$tools_dir/Scopify/scopify.py"
    if [ -f "$scop_script" ] && [ -n "$act_scop" ]; then
        if command -v unfurl >/dev/null 2>&1; then
            local company
            company="$(unfurl format %r <<< "$domain" 2>/dev/null || printf '%s' "$domain")"
            cmd "python3 scopify.py -c ${company}   (cwd: 03-intel)"
            (
                repair_venv_python "$act_scop"
                source "$act_scop"
                # Scopify writes debug_<company>.html relative to CWD; keep it
                # inside the step dir instead of polluting the repo root.
                cd "$sdir" || exit 1
                python3 "$scop_script" -c "$company"
            ) >"$sdir/scopify.txt" 2>&1 || true
            # Scopify exits 0 even when Netify has no page for the company;
            # don't count its error text as a successful module.
            if [ -s "$sdir/scopify.txt" ] \
                && ! grep -qiE '^[[:space:]]*Error:|Could not find page' "$sdir/scopify.txt"; then
                ran=$((ran + 1))
            else
                if grep -qiE '^[[:space:]]*Error:|Could not find page' "$sdir/scopify.txt"; then
                    warn "Scopify failed: $(grep -m1 -iE 'Error:|Could not find page' "$sdir/scopify.txt")"
                else
                    warn "Scopify produced no output"
                fi
                skipped=$((skipped + 1))
            fi
        else
            warn "unfurl not installed — Scopify skipped"
            skipped=$((skipped + 1))
        fi
    else
        warn "Scopify missing — skipped (./install.sh)"
        skipped=$((skipped + 1))
    fi

    # --- Spoofy (SPF / DMARC / DKIM analysis) ---
    local spoof_script="$tools_dir/Spoofy/spoofy.py"
    if [ -f "$spoof_script" ] && [ -n "$act_spoof" ]; then
        cmd "python3 spoofy.py -d ${domain}"
        (
            repair_venv_python "$act_spoof"
            source "$act_spoof"
            cd "$tools_dir/Spoofy" || exit 1
            python3 "$spoof_script" -d "$domain"
        ) >"$sdir/spoof.txt" 2>&1 || true
        if [ -s "$sdir/spoof.txt" ]; then
            ran=$((ran + 1))
        else
            warn "Spoofy produced no output"
            skipped=$((skipped + 1))
        fi
    else
        warn "Spoofy missing — skipped (./install.sh)"
        skipped=$((skipped + 1))
    fi

    # --- cloud_enum (AWS / Azure / GCP resource hunt) ---
    local cloud_script="$tools_dir/cloud_enum/cloud_enum.py"
    if [ -f "$cloud_script" ] && [ -n "$act_cloud" ]; then
        local company mutations brute
        company="$(unfurl format %r <<< "$domain" 2>/dev/null || printf '%s' "$domain" | awk -F. '{print $(NF-1)}')"
        mutations="$tools_dir/cloud_enum/enum_tools/fuzz.txt"
        brute="$mutations"
        if [ ! -f "$mutations" ]; then
            mutations="$cloud_script"
            brute="$cloud_script"
        fi
        local ce_tmp="$sdir/.cloud_enum.tmp"
        cmd "python3 cloud_enum.py -k ${company} -k ${domain} -t 50 -qs"
        (
            repair_venv_python "$act_cloud"
            source "$act_cloud"
            PYTHONWARNINGS=ignore python3 "$cloud_script" \
                -k "$company" \
                -k "$domain" \
                -k "${domain%%.*}" \
                -t 50 \
                -m "$mutations" \
                -b "$brute" \
                -qs 2>/dev/null
        ) >"$ce_tmp" 2>&1 || true
        if command -v anew >/dev/null 2>&1; then
            anew -q "$sdir/cloud_enum.txt" < "$ce_tmp" >/dev/null 2>&1 || true
        else
            cat "$ce_tmp" >> "$sdir/cloud_enum.txt" 2>/dev/null || true
        fi
        rm -f "$ce_tmp"
        if [ -s "$sdir/cloud_enum.txt" ]; then
            ran=$((ran + 1))
        else
            info "cloud_enum: no cloud resources found"
            ran=$((ran + 1))
        fi
    else
        warn "cloud_enum missing — skipped (./install.sh)"
        skipped=$((skipped + 1))
    fi

    local elapsed=$(( $(now_s) - t0 ))
    if [ "$ran" -gt 0 ]; then
        ok "03-intel/ · ${ran} module(s) produced output · ${skipped} skipped (${elapsed}s)"
        note_result "ok" "3 · Intel" "03-intel/ · ${ran} ok / ${skipped} skipped"
    elif [ "$skipped" -gt 0 ]; then
        warn "03-intel/ · all modules skipped or empty — see recon.log"
        note_result "skip" "3 · Intel" "tools missing/empty — run ./install.sh"
    else
        err "03-intel/ failed — see recon.log"
        note_result "fail" "3 · Intel" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 4 — OSINT (theHarvester: subdomains + emails)
#  openswarm phase-osint.sh parity: same source sets, same -n -r -f runs,
#  same JSON extraction → output filenames.
#  output → recon/<domain>/04-osint/
# ================================================================

# theHarvester runner — $1=sdir $2=basename $3=sources $4=label $5...=command argv
# (binary ladder resolved by step_osint; uv sync may not create an entry point)
_run_harvester() {
    local osint_dir="$1" base="$2" sources="$3" label="$4"
    shift 4
    info "theHarvester (${label}) — sources: ${sources}"
    cmd "$* -d ${DOMAIN} -b ${sources} -n -r -f ${base}   (cwd: 04-osint)"
    (
        cd "$osint_dir" || exit 1
        "$@" -d "$DOMAIN" -b "$sources" -n -r -f "$base"
    ) 2>&1 | tee -a "$osint_dir/theharvester.log"
    return "${PIPESTATUS[0]}"
}

# JSON field extraction — $1=json_file $2=output_file $3=key
_extract_json_field() {
    local json_file="$1" output_file="$2" key="$3"
    if [ ! -f "$json_file" ]; then
        return 1
    fi
    python3 - "$json_file" "$key" "$output_file" <<'PY' 2>&1 | tee -a "$(dirname "$output_file")/parse.log"
import json, sys
json_file, key, output_file = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(json_file) as f:
        data = json.load(f)
    items = data.get(key, [])
    with open(output_file, 'a') as out:
        for item in items:
            out.write(str(item) + '\n')
    print('  Extracted ' + str(len(items)) + ' ' + key)
except Exception as e:
    print('Parse error (' + json_file + '): ' + str(e), file=sys.stderr)
PY
}

step_osint() {
    local t0; t0=$(now_s)
    local sdir_rel="$OUTDIR/04-osint"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"
    local harvester_dir="${HARVESTER_DIR:-$HOME/theHarvester}"

    if [ ! -d "$harvester_dir/.git" ]; then
        warn "Step 4 SKIPPED: theHarvester not found at ${harvester_dir} (run ./install.sh)"
        note_result "skip" "4 · OSINT" "theHarvester missing — run ./install.sh"
        return 0
    fi

    # binary ladder (uv sync doesn't always create an entry point)
    local harv_args=()
    if [ -f "$harvester_dir/.venv/bin/theHarvester" ]; then
        harv_args=("$harvester_dir/.venv/bin/theHarvester")
    elif command -v theHarvester >/dev/null 2>&1; then
        harv_args=(theHarvester)
    elif [ -f "$harvester_dir/.venv/bin/python3" ]; then
        if command -v uv >/dev/null 2>&1; then
            harv_args=(uv run --directory "$harvester_dir" theHarvester)
        else
            harv_args=("$harvester_dir/.venv/bin/python3" -m theHarvester)
        fi
    fi
    if [ ${#harv_args[@]} -eq 0 ]; then
        warn "Step 4 SKIPPED: theHarvester binary not found (run ./install.sh)"
        note_result "skip" "4 · OSINT" "theHarvester binary missing — run ./install.sh"
        return 0
    fi

    info "04-osint/ → ${sdir}"
    # fresh-run hygiene
    rm -f "$sdir/theharvester_subdomains.json" "$sdir/theharvester_emails.json"
    : > "$sdir/subdomains.txt"
    : > "$sdir/emails.txt"
    : > "$sdir/theharvester.log"

    # valid per theHarvester 5.0.0 source_catalog.py (verified against the install):
    #   threatcrowd removed in 5.x; chaos only selectable via projectdiscovery.
    #   One unknown name → "Invalid source." and the whole run aborts.
    # (openswarm phase-osint.sh still carries the 4.11.1 list incl. both — same bug.)
    local SUB_SOURCES="crtsh,rapiddns,subdomaincenter,hackertarget,otx,urlscan,dnsdumpster,bevigil,certspotter,bufferoverun,virustotal,waybackarchive,commoncrawl,securityTrails,fullhunt,projectdiscovery,robtex"
    local EMAIL_SOURCES="yahoo,duckduckgo,hunter,intelx,haveibeenpwned,hudsonrock,leakix,leaklookup,mojeek,tomba"

    _run_harvester "$sdir" "theharvester_subdomains" "$SUB_SOURCES" "subdomains" "${harv_args[@]}" || true
    _run_harvester "$sdir" "theharvester_emails" "$EMAIL_SOURCES" "emails" "${harv_args[@]}" || true

    _extract_json_field "$sdir/theharvester_subdomains.json" "$sdir/subdomains.txt" "hosts" || true
    _extract_json_field "$sdir/theharvester_emails.json" "$sdir/emails.txt" "emails" || true
    # superset vs openswarm: the email run's JSON also carries hosts (e.g. a lone
    # trust.trybrowzer.com would be lost when the subdomain run aborts) — merge them
    _extract_json_field "$sdir/theharvester_emails.json" "$sdir/subdomains.txt" "hosts" || true

    sort -u -o "$sdir/subdomains.txt" "$sdir/subdomains.txt" 2>/dev/null || true
    sort -u -o "$sdir/emails.txt" "$sdir/emails.txt" 2>/dev/null || true

    local nsub=0 nmail=0
    nsub=$(wc -l < "$sdir/subdomains.txt" 2>/dev/null | tr -d ' ' || printf '0')
    nmail=$(wc -l < "$sdir/emails.txt" 2>/dev/null | tr -d ' ' || printf '0')

    if grep -q "Invalid source" "$sdir/theharvester.log" 2>/dev/null; then
        warn "theHarvester rejected source(s) — source list outdated for this version (see 04-osint/theharvester.log)"
    fi

    local elapsed=$(( $(now_s) - t0 ))
    if [ -f "$sdir/theharvester_subdomains.json" ] || [ -f "$sdir/theharvester_emails.json" ]; then
        ok "04-osint/ · ${nsub} subdomains · ${nmail} emails (${elapsed}s)"
        note_result "ok" "4 · OSINT" "04-osint/ · ${nsub} subdomains · ${nmail} emails"
    else
        err "theHarvester produced no JSON output — see 04-osint/theharvester.log"
        note_result "fail" "4 · OSINT" "no output — see 04-osint/theharvester.log"
    fi
}

# ================================================================
#  Resume / --from (step level)
# ================================================================
# Every completed step appends one line to recon/<domain>/.swarmrecon-state:
#     <step>|<status>|<epoch>
# The last line for a step wins. At the start of a run every step that is about
# to execute is marked "pending", so an interruption always resolves to the
# right step even when old artifacts from a previous run are still on disk.
# --resume starts at the first step whose status is not "ok" (11 is manual and
# always skipped). If the state file is missing (an interrupted run from an
# older version), the same decision is made from the step artifacts instead.
STATE_FILE="$OUTDIR/.swarmrecon-state"

_state_status() {  # $1=step → last recorded status (empty when unknown)
    [ -s "$STATE_FILE" ] || return 0
    awk -F'|' -v n="$1" '$1==n { s=$2 } END { print s }' "$STATE_FILE" 2>/dev/null
}

_prune_state_before() {  # $1=step → forget everything recorded for >= step
    [ -s "$STATE_FILE" ] || return 0
    local tmp="$STATE_FILE.tmp.$$"
    if awk -F'|' -v s="$1" '$1+0 < s' "$STATE_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"
    fi
}

_set_pending_steps() {  # $1=first step → mark it and every later step pending
    local n
    local steps=(1 2 3 4 5 6 7 8 9 10 12 13 14)   # 11 is manual
    for n in "${steps[@]}"; do
        [ "$n" -ge "$1" ] || continue
        printf '%s|pending|%s\n' "$n" "$(date +%s)" >> "$STATE_FILE"
    done
}

_step_artifact_done() {  # $1=step → true when that step's outputs exist
    case "$1" in
        1)  [ -s "$OUTDIR/01-wappalyzer/technologies.json" ] ;;
        2)  compgen -G "$OUTDIR/02-dns-whois/*" >/dev/null ;;
        3)  [ -s "$OUTDIR/03-intel/domain_info_general.txt" ] \
            || [ -s "$OUTDIR/03-intel/azure_tenant_domains.txt" ] \
            || [ -s "$OUTDIR/03-intel/scopify.txt" ] \
            || [ -s "$OUTDIR/03-intel/spoof.txt" ] \
            || [ -s "$OUTDIR/03-intel/cloud_enum.txt" ] ;;
        4)  [ -s "$OUTDIR/04-osint/theharvester_subdomains.json" ] \
            || [ -s "$OUTDIR/04-osint/subdomains.txt" ] ;;
        5)  [ -s "$OUTDIR/05-nmap/nmap-full.txt" ] ;;
        6)  [ -s "$OUTDIR/06-ctfr/ctfr-subdomains.txt" ] ;;
        7)  [ -s "$OUTDIR/https-subs.txt" ] && [ -s "$OUTDIR/alive-domains.txt" ] ;;
        8)  [ -s "$OUTDIR/08-puredns/puredns-subdomains.txt" ] ;;
        9)  [ -s "$OUTDIR/09-vhost/vhost-mc-all.json" ] ;;
        10) compgen -G "$OUTDIR/10-zone-transfer/*" >/dev/null ;;
        12) compgen -G "$OUTDIR/12-robots-sitemap/*" >/dev/null ;;
        13) [ -s "$OUTDIR/merged-crawl.txt" ] && [ -d "$OUTDIR/check" ] ;;
        14) [ -s "$OUTDIR/14-high-value/high-value-results.json" ] ;;
        *)  return 1 ;;
    esac
}

_detect_start_step() {  # prints the first unfinished step, or 0 if all done
    local n st
    local steps=(1 2 3 4 5 6 7 8 9 10 12 13 14)   # 11 is manual
    for n in "${steps[@]}"; do
        st="$(_state_status "$n")"
        if [ -n "$st" ]; then
            # a recorded skip is retried: the missing tool may be installed now
            [ "$st" = "ok" ] || { printf '%s' "$n"; return 0; }
        elif ! _step_artifact_done "$n"; then
            printf '%s' "$n"; return 0
        fi
    done
    printf '0'
}

if $RESUME; then
    _resume_src="artifacts"
    [ -s "$STATE_FILE" ] && _resume_src="run state"
    START_STEP="$(_detect_start_step)"
    if [ "$START_STEP" = "0" ]; then
        info "resume: every step in ${OUTDIR}/ is already complete — nothing to do"
        exit 0
    fi
    _prune_state_before "$START_STEP"
    _set_pending_steps "$START_STEP"
    info "resume: starting at step ${START_STEP} (detected from ${_resume_src})"
elif $FROM_SET; then
    _prune_state_before "$START_STEP"
    _set_pending_steps "$START_STEP"
    info "start: --from ${START_STEP} (earlier steps left untouched)"
else
    : > "$STATE_FILE"   # fresh run: drop the previous run's step state
    _set_pending_steps 1
fi

if [ "$START_STEP" -gt 1 ] && [ ! -d "$OUTDIR/01-wappalyzer" ]; then
    warn "no earlier output found in ${OUTDIR}/ — step ${START_STEP} may be missing prerequisites"
fi

run_step() {  # $1=step  $2=banner title  $3=summary label  $4...=step function
    local n="$1" title="$2" label="$3"
    shift 3
    if [ "$n" -lt "$START_STEP" ]; then
        note_result "skip" "$label" "not run — resumed at step ${START_STEP}"
        return 0
    fi
    step_banner "$n" "$title"
    local before=${#SUMMARY[@]} st="fail"
    "$@"
    cmd_end
    if [ ${#SUMMARY[@]} -gt "$before" ]; then
        IFS='|' read -r st _ _ <<< "${SUMMARY[$(( ${#SUMMARY[@]} - 1 ))]}"
    fi
    printf '%s|%s|%s\n' "$n" "$st" "$(date +%s)" >> "$STATE_FILE"
    _log "[state] step ${n} → ${st}"
}

# ================================================================
#  Run
# ================================================================
banner
info "output → ${OUTDIR}/"

# ProjectDiscovery httpx and python3-httpx share the same binary name. The
# Python CLI rejects -threads/-silent, so steps 6/7/13 would silently produce
# 0 live hosts. Prefer a real PD binary (wherever it is on PATH) and warn
# accurately when none exists.
hx_first="$(command -v httpx 2>/dev/null || true)"
hx_pd="$(resolve_pd_httpx || true)"
if [ -z "$hx_pd" ]; then
    if [ -n "$hx_first" ]; then
        warn "httpx on PATH is not ProjectDiscovery httpx (python3-httpx collision) — no PD binary found; Steps 6/7/13 live probes will be empty. Fix: ./install.sh (or: go install github.com/projectdiscovery/httpx/cmd/httpx@latest)"
    else
        warn "httpx not found — Steps 6/7 live probes skipped (./install.sh installs ProjectDiscovery httpx)"
    fi
elif [ "$hx_first" != "$hx_pd" ]; then
    # the PD dir is often on PATH but after /usr/bin — move it to the front
    # (dropping any duplicate entry so the list stays clean)
    hx_dir="$(dirname "$hx_pd")"
    hx_rest=""
    hx_oldifs="$IFS"; IFS=:
    for hx_p in $PATH; do
        [ -n "$hx_p" ] || continue
        [ "$hx_p" = "$hx_dir" ] && continue
        hx_rest="${hx_rest:+$hx_rest:}$hx_p"
    done
    IFS="$hx_oldifs"
    PATH="$hx_dir${hx_rest:+:$hx_rest}"; export PATH
    info "httpx → ${hx_pd} (ProjectDiscovery; python3-httpx collision avoided)"
fi

run_step 1 "Technology discovery (Wappalyzer)" \
    "1 · Wappalyzer" step_wappalyzer

run_step 2 "DNS + WHOIS (dig / whois / nslookup)" \
    "2 · DNS + WHOIS" step_dns_whois

run_step 3 "Passive intel (whois · msftrecon · Scopify · Spoofy · cloud_enum)" \
    "3 · Intel" step_intel

run_step 4 "OSINT (theHarvester — subdomains + emails)" \
    "4 · OSINT" step_osint

run_step 5 "Port scan (nmap · single pass)" \
    "5 · Nmap port scan" step_nmap

run_step 6 "Certificate Transparency (ctfr)" \
    "6 · CT logs (ctfr)" step_ctfr

run_step 7 "Subdomain enumeration (subenum)" \
    "7 · Subenum" step_subenum

run_step 8 "DNS bruteforce (puredns + massdns)" \
    "8 · DNS bruteforce" step_puredns

run_step 9 "Vhost fuzzing (ffuf)" \
    "9 · Vhost fuzzing" step_vhost_ffuf

run_step 10 "Zone transfer (AXFR)" \
    "10 · Zone transfer" step_zone_transfer

# Step 11 is manual (never resumed, but recorded so the summary stays complete).
if [ "$START_STEP" -le 11 ]; then
    step_banner 11 "Directory bruteforce — MANUAL"
    warn "NOT automated — run ./bruteforce/dir-bruteforce.sh yourself (README → Manual → Step 11)"
    info "Full guide: README.md → Manual → Step 11"
    note_result "skip" "11 · Directory bruteforce" "manual — ./bruteforce/dir-bruteforce.sh; README → Manual"
else
    note_result "skip" "11 · Directory bruteforce" "not run — resumed at step ${START_STEP}"
fi
printf '%s|skip|%s\n' 11 "$(date +%s)" >> "$STATE_FILE"

run_step 12 "Public files (robots / security.txt / sitemaps)" \
    "12 · robots/sitemap" step_robots_sitemap

run_step 13 "Web crawling (waymore · gau · hakrawler · katana · gospider)" \
    "13 · Web crawl" step_crawl

run_step 14 "High-value paths (ffuf · secrets / disclosure / juicy files)" \
    "14 · High-value" step_highvalue

run_step 15 "JavaScript collection + LinkFinder" \
    "15 · JavaScript" step_js

# ---------------------------------------------------------------
# Step N (TODO): add next recon steps here following the same shape:
#   step_x() { guard tool -> local sdir=$OUTDIR/NN-name; mkdir -p ->
#              info -> run into $sdir -> ok/err -> note_result }
# ---------------------------------------------------------------

# ================================================================
#  Summary
# ================================================================
printf '\n%s━━━━ Summary %s\n' "$C_BLUE$C_BOLD" "$C_RESET"
for entry in "${SUMMARY[@]}"; do
    IFS='|' read -r st title detail <<< "$entry"
    case "$st" in
        ok)   printf '  %s✓%s %-18s %s%s%s\n' "$C_GREEN$C_BOLD" "$C_RESET" "$title" "$C_DIM" "$detail" "$C_RESET" ;;
        skip) printf '  %s−%s %-18s %s%s%s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$title" "$C_DIM" "$detail" "$C_RESET" ;;
        fail) printf '  %s✗%s %-18s %s%s%s\n' "$C_RED$C_BOLD" "$C_RESET" "$title" "$C_DIM" "$detail" "$C_RESET" ;;
    esac
done
nfiles=$(find "$OUTDIR" -type f ! -name 'recon.log' ! -name '.swarmrecon-state' | wc -l | tr -d ' ')
printf '\n  %s%s files%s in %s%s/%s\n' "$C_BOLD" "$nfiles" "$C_RESET" "$C_CYAN" "$OUTDIR" "$C_RESET"
printf '  %slog:%s %s\n\n' "$C_DIM" "$C_RESET" "$LOG"
