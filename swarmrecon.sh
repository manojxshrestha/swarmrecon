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
    printf '%sUsage:%s ./swarmrecon.sh -d <domain>\n' "$C_BOLD" "$C_RESET"
    printf '  %sOutput:%s recon/<domain>/<NN-step>/\n' "$C_DIM" "$C_RESET"
    exit 1
}

while getopts ":d:h" opt; do
    case "$opt" in
        d) DOMAIN="$OPTARG" ;;
        h|*) usage ;;
    esac
done
[ -z "$DOMAIN" ] && usage

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"   # dir of swarmrecon.sh (wordlists live here)
WL_DIR="$SWARM_DIR/wordlists"
# pipx (wappalyzer) + go tools (puredns) install into these — make sure a
# fresh shell (before `pipx ensurepath` takes effect) still finds them
export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"

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

banner() {
    printf '%s╭%s\n' "$C_CYAN" "$C_RESET"
    printf '%s│%s  %sswarmrecon%s  %s→%s  %s%s%s\n' \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET" "$C_BOLD" "$DOMAIN" "$C_RESET"
    printf '%s│%s  %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_RESET"
    printf '%s╰%s\n' "$C_CYAN" "$C_RESET"
}

step_banner() {  # $1=step_no  $2=title
    printf '\n%s━━━ Step %s ▸ %s %s\n' "$C_MAGENTA$C_BOLD" "$1" "$2" "$C_RESET"
}

# step results for the final summary:  status|step|details
SUMMARY=()
note_result() { SUMMARY+=("$1|$2|$3"); }

now_s() { date +%s; }

# ================================================================
#  Step 1 — Technology discovery (Wappalyzer)
#  output → recon/<domain>/01-wappalyzer/
# ================================================================
step_wappalyzer() {
    if ! command -v wappalyzer >/dev/null 2>&1; then
        warn "Step 1 SKIPPED: wappalyzer not found (run ./install.sh)"
        note_result "skip" "1 · Wappalyzer" "wappalyzer not installed"
        return 0
    fi

    local sdir="$OUTDIR/01-wappalyzer"
    mkdir -p "$sdir"
    info "wappalyzer -i https://${DOMAIN}"
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
    info "dig A/AAAA/NS/MX/TXT/CAA/SOA/DMARC + Google/Cloudflare resolvers + nslookup + whois"
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
    } >>"$LOG" 2>&1; then
        ok "done in $(( $(now_s) - t0 ))s → 02-dns-whois/ (13 files)"
        info "A: $(paste -sd' ' "$sdir/dns-a.txt" 2>/dev/null | head -c 200)"
        note_result "ok" "2 · DNS + WHOIS" "02-dns-whois/ · 13 files"
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "2 · DNS + WHOIS" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 3 — Port scan (nmap)  [4-stage sequence per user]
#  1 quick TCP -> 2 service/versions -> 3 all TCP ports -> 4 full + versions
#  output → recon/<domain>/03-nmap/
# ================================================================
step_nmap() {
    if ! command -v nmap >/dev/null 2>&1; then
        warn "Step 3 SKIPPED: nmap not found (run ./install.sh / install manually)"
        note_result "skip" "3 · Nmap port scan" "nmap not installed"
        return 0
    fi

    local sdir="$OUTDIR/03-nmap"
    mkdir -p "$sdir"
    info "4 stages: quick TCP -> -sV -> -p- -> -p- -sV (progress in recon.log)"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    if {
        # Stage 1: Quick TCP scan
        nmap -Pn --open "$domain" -oN "$sdir/nmap-quick.txt"
        # Stage 2: Identify services and versions
        nmap -Pn --open -sV "$domain" -oN "$sdir/nmap-version.txt"
        # Stage 3: Check all TCP ports
        nmap -Pn --open -p- "$domain" -oN "$sdir/nmap-allports.txt"
        # Stage 4: Full TCP scan with service detection
        nmap -Pn --open -p- -sV "$domain" -oN "$sdir/nmap-full.txt"
    } >>"$LOG" 2>&1; then
        local nports
        nports=$(grep -c '/tcp open' "$sdir/nmap-full.txt" 2>/dev/null || true)
        ok "done in $(( $(now_s) - t0 ))s → 03-nmap/ (4 reports, ${nports:-0} open ports)"
        note_result "ok" "3 · Nmap port scan" "03-nmap/ · ${nports:-0} open ports"
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "3 · Nmap port scan" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 4 — Certificate Transparency logs (ctfr)
#  ctfr lives in $HOME/ctfr with its own venv (PEP-668 blocks system pip);
#  the venv is ACTIVATED automatically before running (user requirement).
#  output → recon/<domain>/04-ctfr/
# ================================================================
step_ctfr() {
    local ctfr_dir="$HOME/ctfr"
    if [ ! -f "$ctfr_dir/ctfr.py" ] || [ ! -f "$ctfr_dir/venv/bin/activate" ]; then
        warn "Step 4 SKIPPED: ctfr not ready at ${ctfr_dir} (run ./install.sh)"
        note_result "skip" "4 · CT logs (ctfr)" "ctfr/venv missing — run ./install.sh"
        return 0
    fi

    # absolute path: this step cds into the ctfr dir before running
    local sdir_rel="$OUTDIR/04-ctfr"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"

    info "activate ${ctfr_dir}/venv + python3 ctfr.py -d ${DOMAIN}"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    if (
        # auto-activate the virtual environment (user requirement)
        source "$ctfr_dir/venv/bin/activate"
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
            grep -v "No IP" "$sdir/ctfr-subdomains.txt" 2>/dev/null \
                | awk '{print $1}' \
                | httpx -silent -o "$sdir/live-ctfr-subdomains.txt" >>"$LOG" 2>&1 || true
            n_live=$(grep -c 'http' "$sdir/live-ctfr-subdomains.txt" 2>/dev/null || true)
            ok "done in $(( $(now_s) - t0 ))s → 04-ctfr/ (${nsubs:-0} CT entries, ${n_live:-0} live via httpx)"
        else
            warn "httpx not found — live CT probe skipped (install ProjectDiscovery httpx)"
            ok "done in $(( $(now_s) - t0 ))s → 04-ctfr/ctfr-subdomains.txt (${nsubs:-0} entries, live probe skipped)"
        fi
        note_result "ok" "4 · CT logs (ctfr)" "04-ctfr/ · ${nsubs:-0} CT / ${n_live:-0} live"
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "4 · CT logs (ctfr)" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 6 — DNS subdomain bruteforce (puredns + massdns)
#  puredns = fast, handles wildcards; massdns compiled for speed (user).
#  wordlists: <swarmrecon>/wordlists/{subdomains-top1million-20000,resolvers}.txt
#  output → recon/<domain>/06-puredns/
# ================================================================
step_puredns() {
    # puredns may not be on PATH — accept $HOME/go/bin/puredns (go install default)
    local pd=""
    if command -v puredns >/dev/null 2>&1; then
        pd="$(command -v puredns)"
    elif [ -x "$HOME/go/bin/puredns" ]; then
        pd="$HOME/go/bin/puredns"
    else
        warn "Step 6 SKIPPED: puredns not found (run ./install.sh)"
        note_result "skip" "6 · DNS bruteforce" "puredns missing — run ./install.sh"
        return 0
    fi

    if ! command -v massdns >/dev/null 2>&1; then
        warn "Step 6 SKIPPED: massdns not found (puredns backend — run ./install.sh)"
        note_result "skip" "6 · DNS bruteforce" "massdns missing — run ./install.sh"
        return 0
    fi

    local wl_wordlist="$WL_DIR/subdomains-top1million-20000.txt"
    local wl_resolvers="$WL_DIR/resolvers.txt"
    if [ ! -s "$wl_wordlist" ] || [ ! -s "$wl_resolvers" ]; then
        warn "Step 6 SKIPPED: wordlists missing in ${WL_DIR} (ship with the repo — check wordlists/)"
        note_result "skip" "6 · DNS bruteforce" "wordlists missing — check wordlists/"
        return 0
    fi

    # absolute path (same convention as other steps)
    local sdir_rel="$OUTDIR/06-puredns"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"

    info "puredns bruteforce (20k wordlist + resolvers, wildcard filtering)"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    # exact command per user, with absolute wordlist/resolver paths
    if "$pd" bruteforce "$wl_wordlist" "$domain" -r "$wl_resolvers" \
        > "$sdir/puredns-subdomains.txt" 2>>"$LOG"; then
        local nsubs=0
        nsubs=$(grep -c '\.' "$sdir/puredns-subdomains.txt" 2>/dev/null || true)
        ok "done in $(( $(now_s) - t0 ))s → 06-puredns/puredns-subdomains.txt (${nsubs:-0} subdomains)"
        note_result "ok" "6 · DNS bruteforce" "06-puredns/ · ${nsubs:-0} subdomains"
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "6 · DNS bruteforce" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 7 — Vhost fuzzing (ffuf)
#  1) baseline: Content-Length of a non-existent vhost (curl -I)
#  2) ffuf pass A: -fs <baseline> -mc all
#  3) ffuf pass B: -fs <baseline> -fc 403
#  (user's 2nd example had "-H -H" typo -> single -H used)
#  output → recon/<domain>/07-vhost/
# ================================================================
step_vhost_ffuf() {
    local miss=0
    for t in ffuf curl; do
        if ! command -v "$t" >/dev/null 2>&1; then
            warn "Step 7 SKIPPED: $t not found (run ./install.sh / install manually)"
            miss=1
        fi
    done
    local wl="$WL_DIR/common.txt"
    if [ ! -s "$wl" ]; then
        warn "Step 7 SKIPPED: ${wl} missing (ships with repo — check wordlists/)"
        miss=1
    fi
    if [ "$miss" -ne 0 ]; then
        note_result "skip" "7 · Vhost fuzzing" "ffuf/curl/common.txt missing"
        return 0
    fi

    local sdir_rel="$OUTDIR/07-vhost"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    # --- baseline: what does a NON-existent vhost return? ---
    curl -s -I "http://${domain}" -H "Host: defnotvalid.${domain}" \
        > "$sdir/vhost-baseline.txt" 2>>"$LOG" || true
    local base_cl
    base_cl=$(grep -i '^Content-Length:' "$sdir/vhost-baseline.txt" 2>/dev/null \
        | head -1 | grep -oE '[0-9]+' || true)

    if [ -z "$base_cl" ]; then
        err "baseline FAILED: no Content-Length from non-existent vhost — cannot set -fs"
        err "see ${sdir}/vhost-baseline.txt"
        note_result "fail" "7 · Vhost fuzzing" "baseline: no Content-Length"
        return 0
    fi
    info "baseline CL=${base_cl} (defnotvalid.${domain})"

    # fresh run: a failed pass must not be papered over by last run's json
    rm -f "$sdir/vhost-mc-all.json" "$sdir/vhost-no403.json"

    # --- ffuf passes (user's exact commands + absolute wordlist + -o json) ---
    # '&&' so pass A failure aborts instead of reporting pass B alone as ok
    if {
        # pass A: all status codes except baseline size
        ffuf -w "${wl}:FUZZ" -u "http://${domain}/" -H "Host: FUZZ.${domain}" \
            -fs "$base_cl" -mc all -of json -o "$sdir/vhost-mc-all.json" \
        && ffuf -w "${wl}:FUZZ" -u "http://${domain}/" -H "Host: FUZZ.${domain}" \
            -fs "$base_cl" -fc 403 -of json -o "$sdir/vhost-no403.json"
    } >>"$LOG" 2>&1; then
        local n1=0 n2=0
        n1=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("results",[])))' "$sdir/vhost-mc-all.json" 2>/dev/null || echo "?")
        n2=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("results",[])))' "$sdir/vhost-no403.json" 2>/dev/null || echo "?")
        ok "done in $(( $(now_s) - t0 ))s → 07-vhost/ (mc-all: ${n1}, no403: ${n2} matches)"
        note_result "ok" "7 · Vhost fuzzing" "07-vhost/ · ${n1}+${n2} matches (CL=${base_cl})"
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "7 · Vhost fuzzing" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 8 — Zone Transfer attack (AXFR)
#  1) nslookup -type=NS <domain>          (list nameservers)
#  2) dig axfr <ns> <domain>              (per nameserver attempt)
#  Success marker: "XFR size:" or ANSWER: >0 in dig output.
#  output → recon/<domain>/08-zone-transfer/
# ================================================================
step_zone_transfer() {
    local miss=0
    for t in nslookup dig; do
        if ! command -v "$t" >/dev/null 2>&1; then
            warn "Step 8 SKIPPED: $t not found (install manually / ./install.sh)"
            miss=1
        fi
    done
    if [ "$miss" -ne 0 ]; then
        note_result "skip" "8 · Zone transfer" "nslookup/dig missing"
        return 0
    fi

    local sdir_rel="$OUTDIR/08-zone-transfer"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    # --- list nameservers (user's exact command) ---
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
        note_result "fail" "8 · Zone transfer" "no nameservers discovered"
        return 0
    fi

    local total=0 xfr_ok=0
    # --- attempt zone transfer (AXFR) against each nameserver ---
    for ns in $nss; do
        total=$((total + 1))
        local out="$sdir/axfr-${ns}.txt"
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
        ok "done in $(( $(now_s) - t0 ))s → 08-zone-transfer/ — ⚠ ${xfr_ok}/${total} nameservers ALLOWED transfer"
        note_result "ok" "8 · Zone transfer" "⚠ AXFR open on ${xfr_ok}/${total} NS!"
    else
        ok "done in $(( $(now_s) - t0 ))s → 08-zone-transfer/ — 0/${total} nameservers allowed transfer (all refused)"
        note_result "ok" "8 · Zone transfer" "0/${total} NS allowed (all refused)"
    fi
}

# ================================================================
#  Step 9 — Directory bruteforcing (ffuf)
#  1) baseline: Content-Length of a random non-existent path (curl -I)
#  2) ffuf -fc 403,404 -fs 0,<baseline_CL> -mc 200,301,302 -t 100
#  3) jq -r '.results[].url' -> flat list
#  (user example used -fs 0; baseline CL added per user: "we need to see
#   on its too filter size" -> dynamic, like the vhost step)
#  output → recon/<domain>/09-directories/
# ================================================================
step_dirbust() {
    local miss=0
    for t in ffuf curl jq; do
        if ! command -v "$t" >/dev/null 2>&1; then
            warn "Step 9 SKIPPED: $t not found (run ./install.sh / install manually)"
            miss=1
        fi
    done
    local wl="$WL_DIR/raft-medium-directories.txt"
    if [ ! -s "$wl" ]; then
        warn "Step 9 SKIPPED: ${wl} missing (ships with repo — check wordlists/)"
        miss=1
    fi
    if [ "$miss" -ne 0 ]; then
        note_result "skip" "9 · Directory bruteforce" "ffuf/curl/jq/wordlist missing"
        return 0
    fi

    local sdir_rel="$OUTDIR/09-directories"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    # --- baseline: what does a random non-existent path return? ---
    curl -s -I "https://${domain}/asdkl3" \
        > "$sdir/dir-baseline.txt" 2>>"$LOG" || true
    local base_cl
    base_cl=$(grep -i '^Content-Length:' "$sdir/dir-baseline.txt" 2>/dev/null \
        | head -1 | grep -oE '[0-9]+' || true)

    # -fs list: always filter empty bodies (user's -fs 0); add baseline
    # error-page size when the server sent a Content-Length.
    # (unlike vhost step, missing CL is NOT fatal here -> -fs 0 still valid)
    local fs="0"
    if [ -n "$base_cl" ]; then
        fs="0,${base_cl}"
        info "baseline CL=${base_cl} (/asdkl3) → -fs ${fs}"
    else
        warn "baseline: no Content-Length → using -fs 0 only"
    fi

    # fresh run: a failed ffuf must not feed jq a previous run's json
    rm -f "$sdir/ffuf-directory.json" "$sdir/ffuf-directory.txt"

    # --- ffuf (user's exact flags, dynamic -fs, outputs into step dir) ---
    # '&&' so failed ffuf aborts the block instead of jq masking it
    if {
        ffuf -u "https://${domain}/FUZZ" -w "$wl" \
            -fc 403,404 -fs "$fs" -mc 200,301,302 -t 100 \
            -o "$sdir/ffuf-directory.json" -of json \
        && jq -r '.results[].url' "$sdir/ffuf-directory.json" > "$sdir/ffuf-directory.txt"
    } >>"$LOG" 2>&1; then
        local nurls=0
        nurls=$(grep -c 'http' "$sdir/ffuf-directory.txt" 2>/dev/null || true)
        ok "done in $(( $(now_s) - t0 ))s → 09-directories/ (${nurls:-0} paths matched)"
        note_result "ok" "9 · Directory bruteforce" "09-directories/ · ${nurls:-0} paths"
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "9 · Directory bruteforce" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 10 — Public files: robots.txt / security.txt / sitemaps
#  (user's script; sections -> separate files, headers -> recon.log.
#   robots.txt fetched ONCE then grepped locally for section 3 —
#   same bytes as re-fetching, one fewer request.)
#  TODO(user "improvements to make later"): proper XML parse (namespaces,
#  .gz, indexes), recursive sitemap-index follow w/ limits, diff against
#  crawl/archive URLs. NOTE: a path in a sitemap is NOT a vuln by itself.
#  output → recon/<domain>/10-robots-sitemap/
# ================================================================
step_robots_sitemap() {
    if ! command -v curl >/dev/null 2>&1; then
        warn "Step 10 SKIPPED: curl not found"
        note_result "skip" "10 · robots/sitemap" "curl missing"
        return 0
    fi

    local sdir_rel="$OUTDIR/10-robots-sitemap"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"
    local domain="$DOMAIN"
    local base="https://${domain}"
    local t0; t0=$(now_s)

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
            paths=(
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
    } >>"$LOG" 2>&1; then
        local n_adv=0 n_loc=0
        n_adv=$(grep -ci 'sitemap:' "$sdir/advertised-sitemaps.txt" 2>/dev/null || true)
        n_loc=$(grep -c 'http' "$sdir/sitemap-urls.txt" 2>/dev/null || true)
        ok "done in $(( $(now_s) - t0 ))s → 10-robots-sitemap/ (advertised: ${n_adv:-0}, sitemap URLs: ${n_loc:-0})"
        note_result "ok" "10 · robots/sitemap" "10-robots-sitemap/ · ${n_loc:-0} sitemap URLs"
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "10 · robots/sitemap" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 5 — Subdomain enumeration (subenum, user's own tool)
#  runs from ~/subenum:  ./subenum.sh -d <domain> -hp
#  (-hp writes the alive probes; prefix is "" for -d mode, only -l mode
#   prefixes filenames with "<dom>-")
#  source: ~/subenum/outputs/<domain>/alive/{https-subs,alive-domains}.txt
#  copied to: recon/<domain>/subdomains/
#  AFTER the CT merges, BOTH final files are MOVED UP to recon/<domain>/:
#  https-subs.txt and alive-domains.txt (user: both belong in
#  recon/target.com/ directory — subdomains/ is only the staging area)
# ================================================================
step_subenum() {
    local subenum_dir="$HOME/subenum"
    if [ ! -f "$subenum_dir/subenum.sh" ]; then
        warn "Step 5 SKIPPED: subenum not found at ${subenum_dir} (run ./install.sh)"
        note_result "skip" "5 · Subenum" "subenum missing — run ./install.sh"
        return 0
    fi

    # user-specified destination (no NN- prefix)
    local sdir_rel="$OUTDIR/subdomains"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"
    local domain="$DOMAIN"
    local t0; t0=$(now_s)

    # fresh run: drop this target's previous final + staging lists so a rerun
    # never merges with or reports stale data (recon.log is truncated each run)
    rm -f "$OUTDIR/https-subs.txt" "$OUTDIR/alive-domains.txt" \
          "$sdir/https-subs.txt" "$sdir/alive-domains.txt" "$sdir/temp"

    info "subenum.sh -d ${domain} -hp (cwd: ${subenum_dir})"
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
        local ctfr_live="$OUTDIR/04-ctfr/live-ctfr-subdomains.txt"
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
            info "no live-ctfr-subdomains.txt (step 4 skipped or httpx missing) — https-subs unchanged"
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
            note_result "ok" "5 · Subenum" "https-subs: ${n_https:-0} · alive: ${n_alive:-0}"
        else
            err "subenum ran but nothing copied — check ${subenum_dir}/outputs/${domain}/alive/"
            note_result "fail" "5 · Subenum" "no alive output produced — see recon.log"
        fi
    else
        err "FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "5 · Subenum" "failed — see recon.log"
    fi
}

# ================================================================
#  Step 11 — Web crawling (user's exact pipeline)
#    waymore (venv @ ~/waymore) -> wayurls.txt      (moved into recon/<domain>/)
#    gau    echo $D | gau --threads 10 --subs | anew gauurls.txt
#    merge  cat wayurls gauurls | uro | sort -u > waygauurls.txt
#    hakrawler / katana / gospider  on https-subs.txt
#    extracturls.sh -f gooutput     -> alivesubsurls.txt (moved up to root)
#    final merge: cat waygauurls cleansubskatanaurls hakcrawlurls alivesubsurls
#                 | uro > merged-crawl.txt
#    filter.sh (domain via stdin) -> check/ ; downstream uses only
#    check/param-urls.txt
#    gf-extract.sh check/param-urls.txt -> check/gf/gf-*.txt (pattern classes)
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

    # --- 1. waymore (user: venv in ~/waymore, run there, then move file) ---
    local wayvenv="$HOME/waymore/venv/bin/activate"
    if [ -f "$wayvenv" ]; then
        if (
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
        if command -v anew >/dev/null 2>&1; then
            if echo "$DOMAIN" | gau --threads 10 --subs | anew "$OUTDIR/gauurls.txt" >>"$LOG" 2>&1; then
                local ng=0; ng=$(grep -c 'http' "$OUTDIR/gauurls.txt" 2>/dev/null || true)
                ok "gau → gauurls.txt (${ng:-0} URLs)"; ran=$((ran + 1))
            else
                err "gau FAILED (exit=$?) — see ${LOG}"
            fi
        else
            warn "anew not found — gau output written directly"
            if echo "$DOMAIN" | gau --threads 10 --subs > "$OUTDIR/gauurls.txt" 2>>"$LOG"; then
                ran=$((ran + 1))
            else
                err "gau FAILED (exit=$?) — see ${LOG}"
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
        warn "https-subs.txt missing/empty (step 5) — hakrawler skipped"; skipped=$((skipped + 1))
    elif command -v hakrawler >/dev/null 2>&1; then
        if cat "$subs" | hakrawler -subs -u -d 3 > "$OUTDIR/hakcrawlurls.txt" 2>>"$LOG"; then
            local nh=0; nh=$(grep -c 'http' "$OUTDIR/hakcrawlurls.txt" 2>/dev/null || true)
            ok "hakrawler → hakcrawlurls.txt (${nh:-0} URLs)"; ran=$((ran + 1))
        else
            err "hakrawler FAILED (exit=$?) — see ${LOG}"
        fi
    else
        warn "hakrawler not found — skipped"; skipped=$((skipped + 1))
    fi

    # --- 5. cat https-subs.txt | katana -d 3 -jc -timeout 15 -c 20 | anew cleansubskatanaurls.txt ---
    if [ ! -s "$subs" ]; then
        warn "https-subs.txt missing/empty (step 5) — katana skipped"; skipped=$((skipped + 1))
    elif command -v katana >/dev/null 2>&1; then
        local kt_out="$OUTDIR/cleansubskatanaurls.txt"
        if command -v anew >/dev/null 2>&1; then
            if cat "$subs" | katana -d 3 -jc -timeout 15 -c 20 | anew "$kt_out" >>"$LOG" 2>&1; then
                local nk=0; nk=$(grep -c 'http' "$kt_out" 2>/dev/null || true)
                ok "katana → cleansubskatanaurls.txt (${nk:-0} URLs)"; ran=$((ran + 1))
            else
                err "katana FAILED (exit=$?) — see ${LOG}"
            fi
        else
            warn "anew not found — katana output written directly"
            if cat "$subs" | katana -d 3 -jc -timeout 15 -c 20 > "$kt_out" 2>>"$LOG"; then
                ran=$((ran + 1))
            else
                err "katana FAILED (exit=$?) — see ${LOG}"
            fi
        fi
    else
        warn "katana not found — skipped"; skipped=$((skipped + 1))
    fi

    # --- 6. gospider -S https-subs.txt -o gooutput -c 10 -d 3 -t 20 ---
    if [ ! -s "$subs" ]; then
        warn "https-subs.txt missing/empty (step 5) — gospider skipped"; skipped=$((skipped + 1))
    elif command -v gospider >/dev/null 2>&1; then
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
    elif bash "$extractor" -f "$OUTDIR/gooutput" -d "$DOMAIN" >>"$LOG" 2>&1; then
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
    elif ( cd "$OUTDIR" && echo "$DOMAIN" | bash "$filterer" ) >>"$LOG" 2>&1; then
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

    # --- 10. gf-extract.sh: gf-pattern classification of param URLs ---
    #   ./gf-extract.sh check/param-urls.txt check/gf
    #   ($1 must be the input FILE — passing the bare "check" dir errors
    #    at gf-extract.sh line 21; args are explicit here to avoid that)
    local gfex="$SWARM_DIR/gf-extract.sh"
    if [ ! -s "$OUTDIR/check/param-urls.txt" ]; then
        warn "check/param-urls.txt missing/empty (filter.sh) — gf-extract skipped"
        skipped=$((skipped + 1))
    elif [ ! -f "$gfex" ]; then
        warn "gf-extract.sh not found in ${SWARM_DIR} — skipped"
        skipped=$((skipped + 1))
    elif ! command -v gf >/dev/null 2>&1; then
        warn "gf not found (go install github.com/tomnomnom/gf@latest) — skipped"
        skipped=$((skipped + 1))
    elif [ ! -d "$HOME/.gf" ]; then
        warn "gf patterns missing at ${HOME}/.gf — run ./sync-gf-patterns.sh (bundled in gf-patterns/) — skipped"
        skipped=$((skipped + 1))
    elif ( cd "$OUTDIR" && bash "$gfex" check/param-urls.txt check/gf ) >>"$LOG" 2>&1; then
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
        err "gf-extract.sh FAILED (exit=$?) — see ${LOG}"
    fi

    # step verdict
    if [ "$ran" -gt 0 ]; then
        ok "done in $(( $(now_s) - t0 ))s — ${ran} sub-steps ran, ${skipped} skipped"
        note_result "ok" "11 · Web crawl" "${ran} ran / ${skipped} skipped"
    elif [ "$skipped" -gt 0 ]; then
        note_result "skip" "11 · Web crawl" "all skipped — missing tools/inputs"
    else
        note_result "fail" "11 · Web crawl" "all sub-steps failed — see recon.log"
    fi
}

# ================================================================
#  Step 12 — High-value path hunt (user's exact ffuf invocation)
#    purpose: secrets, information disclosure, endpoints, errors,
#             juicy file extensions  (wordlists/high-value-paths.txt)
#    base URL comes from the user's interactive prompt manually;
#    in the script it is https://<domain>
# ================================================================
step_highvalue() {
    local t0; t0=$(now_s)
    local sdir_rel="$OUTDIR/12-high-value"
    mkdir -p "$sdir_rel"
    local sdir; sdir="$(cd "$sdir_rel" && pwd)"
    local wl="$WL_DIR/high-value-paths.txt"
    local target="https://${DOMAIN}"

    # fresh run: drop previous results so a skipped/failed rerun can't show stale hits
    rm -f "$sdir/high-value-results.json" "$sdir/high-value-results.txt"

    local miss=0
    if ! command -v ffuf >/dev/null 2>&1; then
        warn "Step 12 SKIPPED: ffuf not found (run ./install.sh)"
        miss=1
    fi
    if [ ! -s "$wl" ]; then
        warn "Step 12 SKIPPED: ${wl} missing (ships with repo — check wordlists/)"
        miss=1
    fi
    if [ "$miss" -ne 0 ]; then
        note_result "skip" "12 · High-value" "ffuf/wordlist missing"
        return 0
    fi

    info "ffuf -w high-value-paths.txt -u ${target}/FUZZ -mc ... -ac -rate 5"
    if ffuf \
        -w "$wl" \
        -u "${target%/}/FUZZ" \
        -mc 200,301,302,401,403,500 \
        -ac \
        -rate 5 \
        -o "$sdir/high-value-results.json" \
        -of json >>"$LOG" 2>&1; then
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
        ok "done in $(( $(now_s) - t0 ))s → 12-high-value/high-value-results.json (${nres:-0} hits)"
        note_result "ok" "12 · High-value" "12-high-value/ · ${nres:-0} hits"
    else
        err "ffuf FAILED (exit=$?) — see ${LOG}"
        note_result "fail" "12 · High-value" "failed — see recon.log"
    fi
}

# ================================================================
#  Run
# ================================================================
banner
info "output → ${OUTDIR}/"

step_banner 1 "Technology discovery (Wappalyzer)"
step_wappalyzer

step_banner 2 "DNS + WHOIS (dig / whois / nslookup)"
step_dns_whois

step_banner 3 "Port scan (nmap · 4 stages)"
step_nmap

step_banner 4 "Certificate Transparency (ctfr)"
step_ctfr

step_banner 5 "Subdomain enumeration (subenum)"
step_subenum

step_banner 6 "DNS bruteforce (puredns + massdns)"
step_puredns

step_banner 7 "Vhost fuzzing (ffuf)"
step_vhost_ffuf

step_banner 8 "Zone transfer (AXFR)"
step_zone_transfer

step_banner 9 "Directory bruteforce (ffuf)"
step_dirbust

step_banner 10 "Public files (robots / security.txt / sitemaps)"
step_robots_sitemap

step_banner 11 "Web crawling (waymore · gau · hakrawler · katana · gospider)"
step_crawl

step_banner 12 "High-value paths (ffuf · secrets / disclosure / juicy files)"
step_highvalue

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
nfiles=$(find "$OUTDIR" -type f ! -name 'recon.log' | wc -l | tr -d ' ')
printf '\n  %s%s files%s in %s%s/%s\n' "$C_BOLD" "$nfiles" "$C_RESET" "$C_CYAN" "$OUTDIR" "$C_RESET"
printf '  %slog:%s %s\n\n' "$C_DIM" "$C_RESET" "$LOG"
