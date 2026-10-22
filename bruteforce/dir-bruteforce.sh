#!/usr/bin/env bash
# =============================================================================
#
# Usage:
#   ./bruteforce/dir-bruteforce.sh                    Interactive: prompts for
#                                                     target URL + wordlist path
#   ./bruteforce/dir-bruteforce.sh --url <url> --wordlist <f>
#                                                     Single host scan
#   ./bruteforce/dir-bruteforce.sh --plan <file> --wordlist <f>
#                                                     Execute scan plan (JSON)
#
# Options (with --url / --plan):
#   --wordlist <path>     Wordlist file (repeatable, REQUIRED — no built-in lists)
#   --profile <name>      light|standard|deep (default: light; interactive mode
#                         runs the full chosen wordlist with no budget cap)
#   --ext-profile <name>  php|java|dotnet|generic (deep only)
#   --threads <n>         FFUF concurrent threads (default 500)
#   --rate <ms>           Request delay in ms (default 2 -> ~500 req/s)
#   --target <domain>     Aggregate reports into directories/<domain>/
#   --dry-run             Print plan without executing
#   --force               Re-scan existing results (wipe evidence first)
#   --report-only         Regenerate reports from existing evidence, no scan
# =============================================================================
set -euo pipefail

# Ctrl+C must always tear the whole run down. GNU timeout launches ffuf in its
# own process group, so terminal SIGINT reaches only this shell + timeout;
# if the child chain lingers, bash keeps waiting and the script never quits.
# INT -> TERM -> KILL escalation guarantees termination either way.
on_interrupt() {
  trap - INT TERM
  printf '\n' >&2
  echo "WARN  Interrupted (Ctrl+C) — terminating child processes..." >&2
  if [ "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" = "$$" ]; then
    kill -INT -$$ 2>/dev/null || true
  fi
  pkill -INT -P $$ 2>/dev/null || true
  sleep 1
  kill -TERM -$$ 2>/dev/null || true
  pkill -TERM -P $$ 2>/dev/null || true
  sleep 1
  kill -KILL -$$ 2>/dev/null || true
  pkill -KILL -P $$ 2>/dev/null || true
  exit 130
}
trap on_interrupt INT
trap on_interrupt TERM

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── swarmrecon port ──────────────────────────────────────────────────────
# Previously sourced openswarm scripts/tools/_env.sh (log_*, _scope_guard).
# All dependencies are now defined here; outputs land in
# <swarmrecon-root>/directories/<host>/ (no recon/ nesting).
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # parent of bruteforce/ = swarmrecon root
WL_DIR="$BASE_DIR/wordlists"               # convenience dir for bare-name picks
DIRBUST_BASE="${BASE_DIR}/directories"     # swarmrecon root -> directories/<host>/

# Console logging (replicates openswarm _env.sh definitions)
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}[+]${NC} $1"; }
log_err()  { echo -e "${RED}[-]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_info() { echo -e "${CYAN}[*]${NC} $1"; }

# openswarm engagement-scope checking has no equivalent in swarmrecon
# (scope.txt / scope-checker.py live only in openswarm) -> always allow.
_scope_guard() { return 0; }

# ── Extension profiles ────────────────────────────────────────────────────
declare -A EXT_PROFILES
EXT_PROFILES["php"]=".php,.php3,.php4,.phtml,.bak,.old,.zip,.tar.gz"
EXT_PROFILES["java"]=".jsp,.jspx,.do,.action,.class,.bak,.old"
EXT_PROFILES["dotnet"]=".aspx,.ashx,.asmx,.config,.bak,.old"
EXT_PROFILES["generic"]=".bak,.old,.zip,.tar.gz,.txt,.sql,.json"

# ── Profile request budgets ───────────────────────────────────────────────
declare -A PROFILE_BUDGET
PROFILE_BUDGET["light"]=5000
PROFILE_BUDGET["standard"]=50000
PROFILE_BUDGET["deep"]=150000

# ── High-value path patterns (substring match) ──────────────────────────
CRITICAL_PATTERNS="\.git/|\.env|heapdump|backup\.zip|backup\.tar|dump\.sql|database\.sql|web\.config|app\.config|settings\.py|\.svn/|\.hg/config|phpinfo\.php|id_rsa|\.aws/credentials|\.npmrc|\.dockercfg|\.env\.production"
INTERESTING_PATTERNS="/admin|/graphql|/graphiql|/swagger|/api-docs|/actuator|/manager/html|/jmx-console|/server-status|/server-info|/oauth/|/login|/wp-admin|/wp-login|/api/|/console|\.well-known|/signup|/sign-up|/sign-up_|/signin|/sign-in|/register|/registration|/auth/|/authenticate|/create-account|/forgot-password|/reset-password|/password-reset"

# ── Help ──────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage:
  $0                                Interactive: prompts for target URL and
                                    wordlist path, then bruteforces
  $0 --url <url> --wordlist <f>    Single host scan
  $0 --plan <file> --wordlist <f>  Execute scan plan (JSON)

Options (with --url / --plan):
  --wordlist <path>     Wordlist file (repeatable, REQUIRED — no built-in lists)
  --profile <name>      light|standard|deep (default: light; interactive mode
                        runs the full chosen wordlist with no budget cap)
  --ext-profile <name>  php|java|dotnet|generic (deep only)
  --threads <n>         FFUF concurrent threads (default 500)
  --rate <ms>           Request delay in ms (default 2 -> ~500 req/s)
  --target <domain>     Aggregate reports into directories/<domain>/
  --dry-run             Print plan without executing
  --force               Re-scan existing results (wipe evidence first)
  --report-only         Regenerate reports from existing evidence, no scan
EOF
  exit "${1:-0}"
}

# ── Logging ───────────────────────────────────────────────────────────────


# ── Resolve user-supplied wordlist files (no hardcoded defaults) ─────────
resolve_wordlists() {
  local files=()
  local wl
  for wl in "$@"; do
    if [ -f "$wl" ]; then
      files+=("$wl")
    elif [ -f "$WL_DIR/$wl" ]; then
      files+=("$WL_DIR/$wl")
    else
      log_err "Wordlist not found: $wl (tried as given and under $WL_DIR/)"
    fi
  done

  if [ ${#files[@]} -eq 0 ]; then
    log_err "No wordlist provided — pass --wordlist <path> or run without args (interactive)"
    return 1
  fi

  printf '%s\n' "${files[@]}"
}

# ── Estimate total lines in wordlist files ────────────────────────────
estimate_requests() {
  local files=("$@")
  local total=0
  for f in "${files[@]}"; do
    if [ -f "$f" ]; then
      local count
      count=$(grep -cve '^\s*\(#\|$\)' "$f" 2>/dev/null || true)
      count="${count:-0}"
      total=$((total + count))
    fi
  done
  echo "$total"
}

# ── Pre-flight: DNS + reachability ─────────────────────────────────────
# Returns 0 if the host resolves and responds, 1 if it should be skipped.
host_preflight() {
  local host="$1"
  local host_domain
  host_domain=$(echo "$host" | sed -E 's|https?://||' | sed 's|/.*$||')

  if ! getent hosts "$host_domain" >/dev/null 2>&1; then
    log_err "  NXDOMAIN — $host_domain does not resolve, skipping (dead scope entry?)"
    return 1
  fi

  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$host" 2>/dev/null || echo "000")
  if [ "$code" = "000" ]; then
    log_err "  $host_domain unreachable (no HTTP response), skipping"
    return 1
  fi

  log_ok "  Pre-flight OK: $host_domain → HTTP $code"
  return 0
}

# ── Check WAF via probe request ──────────────────────────────────────
# Detects common challenge/block engines from the root response body.
check_waf() {
  local url="$1"
  local body
  body=$(curl -s -m 10 -A "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0" "$url" 2>/dev/null || true)

  # DataDome JS challenge (captcha-delivery.com script + dd= var)
  if echo "$body" | grep -qiE 'captcha-delivery\.com|geo\.captcha|var dd=\{|"rt":"c"'; then
    echo "datadome"
    return 0
  fi
  # Cloudflare challenge / Just a moment
  if echo "$body" | grep -qiE 'cf-chl|challenge-platform|__cf_chl|"just a moment"|cf-ray'; then
    echo "cloudflare"
    return 0
  fi
  # Akamai bot manager
  if echo "$body" | grep -qiE 'akamai|_abck|sensor_data|akamaized'; then
    echo "akamai"
    return 0
  fi
  # AWS WAF block page
  if echo "$body" | grep -qiE 'aws.?waf|request blocked|400 Bad Request' && echo "$body" | grep -qi 'amazonaws'; then
    echo "aws_waf"
    return 0
  fi

  # Fallback: status-code heuristic on root
  local code
  code=$(curl -sI -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  if [ "$code" = "403" ] || [ "$code" = "503" ]; then
    echo "block_${code}"
    return 0
  fi
  echo ""
}

# ── Fingerprint an ffuf result entry ─────────────────────────────────
fingerprint_entry() {
  local json="$1"
  # Use (status, words, lines, length) as composite fingerprint
  python3 - "$json" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    results = data.get('results', [])
    for r in results:
        fp = {
            'url': r.get('url', ''),
            'status': r.get('status', 0),
            'words': r.get('words', 0),
            'lines': r.get('lines', 0),
            'length': r.get('length', 0),
            'path': ('/' + r.get('input', {}).get('FUZZ', '').lstrip('/')) if r.get('input', {}).get('FUZZ') else '',
        }
        print(json.dumps(fp))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
PY
}

# ── Check if path matches critical or interesting patterns ────────────
classify_path() {
  local path="$1"
  local status="$2"
  local critical=0
  local interesting=0

  if echo "$path" | grep -qE "$CRITICAL_PATTERNS"; then
    critical=1
  fi
  if echo "$path" | grep -qE "$INTERESTING_PATTERNS"; then
    interesting=1
  fi

  echo "$critical|$interesting"
}

# ── Scan a single host ─────────────────────────────────────────────────
scan_host() {
  local host="$1"
  host="${host%/}"
  # C1: skip out-of-scope hosts (subshell so batch mode skips, not dies)
  if ! ( _scope_guard "$host" ) 2>/dev/null; then
    log_warn "skipping out-of-scope host: $host"
    return 1
  fi
  local intent="$2"
  local profile="$3"
  local ext_profile="$4"
  local rate_ms="$5"
  local dry_run="$6"
  local run_id="$7"
  local threads="$8"
  local host_domain
  host_domain=$(echo "$host" | sed -E 's|https?://||' | sed 's|/.*$||')

  # Pre-flight: skip dead hosts before spending any budget
  if ! host_preflight "$host"; then
    return 1
  fi

  # Determine output directory
  local out_dir="${DIRBUST_BASE}/${host_domain}"
  local evi_dir="$out_dir/evidence"
  if [ "$FORCE" = "true" ]; then
    rm -rf "$evi_dir"
  fi
  mkdir -p "$evi_dir"/{200,201,204,301,302,303,307,308,401,403,405,500,502,503}

  local meta_file="$evi_dir/scan-meta.json"
  local results_file="$evi_dir/results.json"
  local robots_file="$evi_dir/robots.txt"

  # Wordlists always come from the user (--wordlist / interactive prompt)
  if [ ${#CUSTOM_WORDLISTS[@]} -eq 0 ]; then
    log_err "No wordlist selected for $host — pass --wordlist <path>"
    return 1
  fi
  mapfile -t wl_files < <(resolve_wordlists "${CUSTOM_WORDLISTS[@]}")
  if [ ${#wl_files[@]} -eq 0 ]; then
    log_err "Wordlist resolution failed for $host"
    return 1
  fi
  local wl_names=()
  for f in "${wl_files[@]}"; do
    wl_names+=("$(basename "$f")")
  done

  local est_requests
  est_requests=$(estimate_requests "${wl_files[@]}")
  local max_req="${MAX_REQ_OVERRIDE:-${PROFILE_BUDGET[$profile]:-5000}}"

  if [ "$est_requests" -gt "$max_req" ]; then
    log_warn "Estimated requests ($est_requests) exceeds $profile budget ($max_req) — capped"
    est_requests=$max_req
  fi

  log_info "Host: $host | Profile: $profile | Wordlists: ${#wl_files[@]} | Est: ~${est_requests} reqs"

  if [ "$dry_run" = "true" ]; then
    echo "  Wordlists: ${wl_names[*]}"
    echo "  Ext profile: ${ext_profile:-none}"
    echo "  Output: $out_dir"
    return 0
  fi

  local start_ts
  start_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local waf_result
  waf_result=$(check_waf "$host")

  # ── Check robots.txt ─────────────────────────────────────────────
  log_info "  Checking robots.txt + sitemap.xml..."
  for doc_path in robots.txt sitemap.xml sitemap-index.xml sitemap_index.xml sitemapindex.xml; do
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$host/$doc_path" 2>/dev/null || echo "000")
    if [ "$code" != "404" ] && [ "$code" != "000" ]; then
      local content
      content=$(curl -s "$host/$doc_path" 2>/dev/null || true)
      echo "--- $doc_path ($code) ---" >> "$robots_file"
      echo "$content" >> "$robots_file"
      echo "" >> "$robots_file"
      log_ok "    $host/$doc_path → $code"
    fi
  done

  # ── Run ffuf with each wordlist ──────────────────────────────────
  local all_results=()
  local rate_flag=()
  local thread_flag=()
  local total_429=0
  local total_requests=0
  local stopped_reason="completed"
  local waf_zero_streak=0

  if [ -n "$rate_ms" ] && [ "$rate_ms" -gt 0 ]; then
    local req_per_sec=$((1000 / rate_ms))
    [ "$req_per_sec" -lt 1 ] && req_per_sec=1
    rate_flag=(-rate "$req_per_sec")
  fi

  if [ -n "$threads" ] && [ "$threads" -gt 0 ]; then
    thread_flag=(-t "$threads")
  fi

  for wl_file in "${wl_files[@]}"; do
    local wl_name
    wl_name=$(basename "$wl_file")
    local wl_count
    wl_count=$(grep -cve '^\s*\(#\|$\)' "$wl_file" 2>/dev/null || true)
    wl_count="${wl_count:-0}"
    local ffuf_out="$evi_dir/ffuf-${wl_name%.txt}.json"

    # Check budget
    if [ "$total_requests" -ge "$max_req" ]; then
      log_warn "  Max requests ($max_req) reached — stopping wordlist loop"
      stopped_reason="budget_exhausted"
      break
    fi

    local remaining=$((max_req - total_requests))
    local use_count=$wl_count
    [ "$use_count" -gt "$remaining" ] && use_count=$remaining

    log_info "  ffuf: $wl_name (${use_count} entries)..."

    # Clean wordlist — strip comments/blanks/leading slashes (avoid //FUZZ), truncate to budget
    local clean_wl
    clean_wl=$(mktemp "${TMPDIR:-/tmp}/dirbust_${wl_name%.txt}_XXXXXX.txt")
    grep -vE '^\s*(#|$)' "$wl_file" | sed 's|^/||' | head -"$use_count" > "$clean_wl"

    local rps_est=${req_per_sec:-0}
    [ "$rps_est" -le 0 ] && rps_est=500
    local ffuf_timeout=$(( use_count * 3 / rps_est + 300 ))
    rm -f "$ffuf_out"
    timeout --foreground "$ffuf_timeout" ffuf -u "${host%/}/FUZZ" -w "$clean_wl" \
      -ac -mc 200-299,301,302,401,403,405,429,500,502,503 -o "$ffuf_out" -of json -noninteractive -timeout 20 "${rate_flag[@]}" "${thread_flag[@]}" || true

    rm -f "$clean_wl"

    # Parse results
    local result_count=0
    local run_ok=0
    if [ -s "$ffuf_out" ]; then
      run_ok=1
      local run_429_before=$total_429
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        local entry_status
        entry_status=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',0))" 2>/dev/null || echo "0")
        if [ "$entry_status" = "429" ]; then
          total_429=$((total_429 + 1))
        else
          all_results+=("$line")
        fi
      done < <(fingerprint_entry "$ffuf_out")

      result_count=$(python3 - "$ffuf_out" 2>/dev/null <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(len(d.get('results', [])))
PY
) || result_count="0"
      result_count=$(( result_count - (total_429 - run_429_before) ))
      [ "$result_count" -lt 0 ] && result_count=0
      log_ok "    → $result_count hits (${total_429} rate-limited)"
    else
      log_warn "    → ffuf produced no output (killed/failed) — budget still consumed, ignored for WAF-wall"
    fi
    total_requests=$((total_requests + use_count))

    # Check stop conditions
    if [ "$total_requests" -gt 0 ] && [ "$total_429" -gt 0 ]; then
      local pct_429=$((total_429 * 100 / total_requests))
      if [ "$pct_429" -gt 30 ]; then
        log_warn "  >30% of responses are 429 — rate limited, stopping"
        stopped_reason="rate_limited"
        break
      fi
    fi

    # WAF-wall detection: WAF suspected AND 2+ consecutive wordlists yield 0 hits
    # with 0 rate-limited → all traffic is hitting the same challenge/block page.
    if [ -n "$waf_result" ]; then
      if [ "$run_ok" -eq 1 ]; then
        if [ "$result_count" -eq 0 ] && [ "$total_429" -eq 0 ]; then
          waf_zero_streak=$((waf_zero_streak + 1))
        else
          waf_zero_streak=0
        fi
      fi
      if [ "$waf_zero_streak" -ge 2 ]; then
        log_warn "  ${waf_zero_streak} consecutive zero-hit wordlists under suspected $waf_result — WAF wall, stopping"
        stopped_reason="waf_blocked"
        break
      fi
    fi

    if [ "$total_requests" -ge "$max_req" ]; then
      stopped_reason="budget_exhausted"
      break
    fi
  done

  # ── Extension scan (only if ext_profile set and deep profile) ─────
  local ext_results=()
  if [ -n "$ext_profile" ] && [ "$profile" = "deep" ]; then
    local exts="${EXT_PROFILES[$ext_profile]:-}"
    if [ -n "$exts" ]; then
      local ext_wl="$WL_DIR/raft-medium-files.txt"
      if [ -f "$ext_wl" ]; then
        local ext_remaining=$(( max_req - total_requests ))
        if [ "$ext_remaining" -le 0 ]; then
          log_warn "  Extension scan skipped — budget exhausted ($total_requests/$max_req)"
        else
          local ext_out="$evi_dir/ffuf-extensions.json"
          log_info "  Extension scan: $ext_profile ($exts)..."
          local clean_ext ext_use
          clean_ext=$(mktemp "${TMPDIR:-/tmp}/dirbust_ext_${ext_profile}_XXXXXX.txt")
          ext_use=$(grep -vE '^\s*(#|$)' "$ext_wl" | wc -l)
          ext_use=$((ext_use + 0))
          [ "$ext_use" -gt "$ext_remaining" ] && ext_use=$ext_remaining
          grep -vE '^\s*(#|$)' "$ext_wl" | sed 's|^/||' | head -"$ext_use" > "$clean_ext"
          local rps_ext=${req_per_sec:-0}
          [ "$rps_ext" -le 0 ] && rps_ext=500
          local ext_timeout=$(( ext_use * 3 / rps_ext + 300 ))
          rm -f "$ext_out"
          timeout --foreground "$ext_timeout" ffuf -u "${host%/}/FUZZ" -w "$clean_ext" -e "$exts" \
            -ac -mc 200-299,301,302,401,403,405,429,500,502,503 -o "$ext_out" -of json -noninteractive -timeout 20 "${rate_flag[@]}" "${thread_flag[@]}" || true
          rm -f "$clean_ext"
          total_requests=$((total_requests + ext_use))
          if [ -s "$ext_out" ]; then
            while IFS= read -r line; do
              [ -z "$line" ] && continue
              if echo "$line" | grep -qE '"status": *429'; then
                total_429=$((total_429 + 1))
              else
                ext_results+=("$line")
              fi
            done < <(fingerprint_entry "$ext_out")
            local ext_count
            ext_count=$(python3 - "$ext_out" 2>/dev/null <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(len(d.get('results', [])))
PY
) || ext_count="0"
            log_ok "    → $ext_count extension hits (${total_429} total rate-limited)"
          else
            log_warn "    → extension scan produced no output — budget still consumed"
          fi
        fi
      fi
    fi
  fi

  local end_ts
  end_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # ── Write scan-meta.json ─────────────────────────────────────────
  local wl_json="["
  local first=true
  for n in "${wl_names[@]}"; do
    $first || wl_json+=","
    wl_json+="\"$n\""
    first=false
  done
  wl_json+="]"

  cat > "$meta_file" <<METAEOF
{
  "schema_version": "1.0",
  "run_id": "$run_id",
  "host": "$host",
  "started": "$start_ts",
  "finished": "$end_ts",
  "intent": "$intent",
  "profile": "$profile",
  "ext_profile": $( [ -n "$ext_profile" ] && printf '"%s"' "${ext_profile//[^a-zA-Z0-9_-]/}" || printf 'null' ),
  "wordlists": $wl_json,
  "request_count": $total_requests,
  "max_requests": $max_req,
  "stopped_reason": "$stopped_reason",
  "rate_limited": $( [ "$stopped_reason" = "rate_limited" ] && echo true || echo false ),
  "waf_suspected": $( [ -n "$waf_result" ] && echo true || echo false )
}
METAEOF
  log_ok "  scan-meta.json written ($total_requests requests, reason: $stopped_reason)"

  # ── Write results.json + per-status files ─────────────────────────
  {
    echo '['
    local first_entry=true
    for entry in "${all_results[@]}" "${ext_results[@]}"; do
      $first_entry || echo ','
      echo "$entry"
      first_entry=false
    done
    echo ']'
  } > "$results_file"

  # Reset per-status JSONL from any prior run (appends would duplicate)
  find "$evi_dir" -name 'entries.json' -type f -delete 2>/dev/null || true

  # Also write per-status files
  for entry in "${all_results[@]}" "${ext_results[@]}"; do
    local status url path
    status=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',0))" 2>/dev/null || echo "0")
    path=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('path',''))" 2>/dev/null || echo "")
    local status_dir="$evi_dir/$status"
    [ -d "$status_dir" ] && echo "$entry" >> "$status_dir/entries.json"
  done

  log_ok "  Results: $results_file"
}

# ── Generate aggregate reports ──────────────────────────────────────────
generate_reports() {
  local domain="$1"
  local out_dir="${DIRBUST_BASE}/${domain}"
  local evi_base="$out_dir/evidence"

  local critical_file="$out_dir/critical-exposure.txt"
  local interesting_file="$out_dir/interesting-surface.txt"
  local summary_file="$out_dir/results-summary.md"

  : > "$critical_file"
  : > "$interesting_file"

  log_info "Generating reports..."

  # Classify and write critical/interesting
  # entries.json files are JSONL (one object per line) — parse line-by-line.
  python3 <<PYEOF 2>/dev/null || log_warn "Report classifier python failed — reports may be incomplete"
import json
import glob
import os

entries = []
evi_base = "$evi_base"

# Primary: per-status entries.json (JSONL, written on completed scans)
for entry_file in sorted(glob.glob(os.path.join(evi_base, "**", "entries.json"), recursive=True)):
    try:
        with open(entry_file) as f:
            for line in f:
                line = line.strip()
                if line:
                    entries.append(json.loads(line))
    except (json.JSONDecodeError, FileNotFoundError, OSError):
        continue

# Fallback: raw ffuf result arrays (survives interrupted scans that never
# wrote per-status files). Only used when entries.json yielded nothing.
if not entries:
    for ffuf_file in sorted(glob.glob(os.path.join(evi_base, "**", "ffuf-*.json"), recursive=True)) \
                   + sorted(glob.glob(os.path.join(evi_base, "**", "ffuf_*.json"), recursive=True)):
        try:
            with open(ffuf_file) as f:
                data = json.load(f)
            for r in data.get("results", []):
                entries.append({
                    "url": r.get("url", ""),
                    "status": r.get("status", 0),
                    "words": r.get("words", 0),
                    "lines": r.get("lines", 0),
                    "length": r.get("length", 0),
                    "path": (r.get("input", {}) or {}).get("FUZZ", r.get("url", "")),
                })
        except (json.JSONDecodeError, FileNotFoundError, OSError):
            continue

# ---- FP KILL LAYER -----------------------------------------------------
# FP mechanism A: SPA soft-shell (identical app HTML for ANY path, incl .git/*)
# FP mechanism B: WAF block page repeated across flagged paths
# Defense: random-path control probe per host + identical-signature clustering.
import re, urllib.request, uuid

bases = sorted({m.group(0).rstrip('/')
                for m in (re.match(r"https?://[^/\s]+", e.get("url","")) for e in entries)
                if m})
controls = {}
for b in bases:
    try:
        req = urllib.request.Request(
            b + "/fp-control-" + uuid.uuid4().hex + "/",
            headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            controls[b] = [resp.status, len(resp.read())]
    except Exception:
        controls[b] = None

shell_counts = {}
for e in entries:
    mu = re.match(r"https?://[^/\s]+", e.get("url",""))
    hk = mu.group(0) if mu else ""
    ln_ = e.get("length", 0)
    # coarse length bucket for large pages: shells vary by nonces/dynamic
    # content between requests, so exact-byte equality misses them
    qlen = ("big" + str(ln_ // 100000)) if ln_ >= 50000 else str(ln_)
    sg = (e.get("status",0), e.get("words",0), e.get("lines",0), qlen)
    shell_counts.setdefault(hk, {}).setdefault(sg, 0)
    shell_counts[hk][sg] += 1

fp_dropped_control = 0
fp_dropped_shell = 0
fp_dropped_waf_block = 0
critical = []
interesting = []
all_lines = []
seen = set()

for e in entries:
    path = e.get("path", "")
    if path and not path.startswith("/"):
        path = "/" + path.lstrip("/")
    status = e.get("status", 0)
    url = e.get("url", "")
    words = e.get("words", 0)
    lines = e.get("lines", 0)
    length = e.get("length", 0)

    if url in seen:
        continue
    seen.add(url)
    mu = re.match(r"https?://[^/\s]+", url)
    hkey = mu.group(0) if mu else ""
    ctl = controls.get(hkey)
    if ctl and status == ctl[0] and abs(length - ctl[1]) <= (64 if ctl[1] < 2048 else max(256, int(ctl[1] * 0.02))):
        fp_dropped_control += 1
        continue
    qlen = ("big" + str(length // 100000)) if length >= 50000 else str(length)
    sig = (status, words, lines, qlen)
    if shell_counts.get(hkey, {}).get(sig, 0) >= 5:
        # Distinguish WAF/block-page clusters (sensitive paths served an
        # identical big response) from generic SPA soft-shells.
        if re.search(r'\.(git|env|svn|hg|aws)|bash_history|web\.config|id_rsa', path, re.I) \
           or (status == 403 and length >= 50000):
            fp_dropped_waf_block += 1
        else:
            fp_dropped_shell += 1
        continue

    line = f"{url} [{status}] words:{words} lines:{lines} bytes:{length}"
    all_lines.append(line)

    import re
    critical_pat = r'\.git/|\.env|heapdump|backup\.zip|backup\.tar|dump\.sql|database\.sql|web\.config|app\.config|settings\.py|\.svn/|\.hg/config|phpinfo\.php|id_rsa|\.aws/credentials|\.npmrc|\.dockercfg|\.env\.production'
    interesting_pat = r'/admin|/graphql|/graphiql|/swagger|/api-docs|/actuator|/manager/html|/jmx-console|/server-status|/server-info|/oauth/|/login|/wp-admin|/wp-login|/api/|/console|\.well-known|/signup|/sign-up|/sign-up_|/signin|/sign-in|/register|/registration|/auth/|/authenticate|/create-account|/forgot-password|/reset-password|/password-reset'

    if re.search(critical_pat, path, re.IGNORECASE):
        critical.append(line)
    elif re.search(interesting_pat, path, re.IGNORECASE):
        interesting.append(line)

with open("$critical_file", "w") as f:
    f.write("# Critical Exposure\n# Format: url [status] words lines bytes\n")
    for line in critical:
        f.write(line + "\n")

with open("$interesting_file", "w") as f:
    f.write("# Interesting Surface\n# Format: url [status] words lines bytes\n")
    for line in interesting:
        f.write(line + "\n")

# Write summary
with open("$summary_file", "w") as f:
    f.write(f"# Directory Bruteforce Results: $domain\n\n")
    f.write(f"## Summary\n")
    f.write(f"- Total entries: {len(entries)}\n")
    f.write(f"- Critical exposures: {len(critical)}\n")
    f.write(f"- Interesting surface: {len(interesting)}\n")
    f.write(f"- FP dropped (control-match): {fp_dropped_control}\n")
    f.write(f"- FP dropped (waf-block-page): {fp_dropped_waf_block}\n")
    f.write(f"- FP dropped (shell-signature): {fp_dropped_shell}\n")
    f.write("\n# Evidence format: entries.json files are JSONL — ONE JSON object per\n")
    f.write("# line (not a single array). Parse line-by-line.\n")

    if critical:
        f.write(f"\n## Critical Exposures\n")
        for line in critical:
            f.write(f"- {line}\n")

    if interesting:
        f.write(f"\n## Interesting Surface\n")
        for line in interesting[:20]:
            f.write(f"- {line}\n")
        if len(interesting) > 20:
            f.write(f"- ... and {len(interesting) - 20} more\n")

    if not critical and not interesting:
        f.write(f"\n## All Findings\n")
        for line in all_lines[:30]:
            f.write(f"- {line}\n")
        if len(all_lines) > 30:
            f.write(f"- ... and {len(all_lines) - 30} more\n")

    f.write(f"\n## Evidence\n")
    f.write(f"- Raw: evidence/results.json\n")
    f.write(f"- Per-status: evidence/<status_code>/entries.json\n")
PYEOF

  log_ok "Reports written: $out_dir/"
  log_ok "  critical-exposure.txt ($(grep -cve '^\s*\(#\|$\)' "$critical_file" 2>/dev/null || true) entries)"
  log_ok "  interesting-surface.txt ($(grep -cve '^\s*\(#\|$\)' "$interesting_file" 2>/dev/null || true) entries)"
  log_ok "  results-summary.md"
}

# ── Aggregate reports into a target root ─────────────────────────────────
# Copies interesting-surface.txt, critical-exposure.txt and results-summary.md
# from a scanned host's directories/<host>/ folder into directories/<target>/.
# Multiple hosts merge with "# source: <host>" separators (dup headers skipped).
aggregate_to_target() {
  local host_domain="$1"
  local target="${TARGET_DOMAIN:-}"
  [ -z "$target" ] && return 0
  [ "$target" = "$host_domain" ] && return 0

  local src_dir="${DIRBUST_BASE}/${host_domain}"
  local dst_dir="${DIRBUST_BASE}/${target}"
  [ ! -d "$src_dir" ] && return 0
  mkdir -p "$dst_dir"

  # Fresh-aggregate truncation happens once in MAIN before mode dispatch — append only here

  local f
  for f in interesting-surface.txt critical-exposure.txt results-summary.md; do
    local src="$src_dir/$f"
    local dst="$dst_dir/$f"
    if [ -s "$src" ]; then
      local nlines
      nlines=$(grep -cve '^\s*\(#\|$\)' "$src" 2>/dev/null || true)
      [ -z "$nlines" ] && nlines=0
      if [ ! -f "$dst" ]; then
        cp "$src" "$dst" || { log_warn "cp failed — $f not aggregated"; continue; }
      elif [ "$nlines" -gt 0 ]; then
        { echo "# source: ${host_domain}"
          grep -vE '^\s*#' "$src" | sed '/^[[:space:]]*$/d'
        } >> "$dst"
      fi
      log_ok "Aggregated $f → $dst ($nlines entries)"
    fi
  done
}

# =========================================================================
# MAIN
# =========================================================================


MODE=""
URL=""
PLAN_FILE=""
PROFILE="light"
EXT_PROFILE=""
RATE_MS=""
THREADS=""
TARGET_DOMAIN=""
DRY_RUN="false"
FORCE="false"
REPORT_ONLY="false"
FRESH_AGGREGATE="${FRESH_AGGREGATE:-false}"
CUSTOM_WORDLISTS=()
RUN_ID=""
MAX_REQ_OVERRIDE=""   # interactive mode: exact size of the chosen wordlist

# ── Interactive mode (no args): prompt for URL + wordlist, then scan ─────
if [ $# -eq 0 ]; then
  if ! command -v ffuf &>/dev/null; then
    log_err "ffuf not found — install: go install github.com/ffuf/ffuf/v2@latest"
    exit 1
  fi
  echo "dir-bruteforce — interactive mode"
  URL=""
  while [ -z "$URL" ]; do
    read -rp "Target URL: " URL || { echo; log_err "stdin closed"; exit 1; }
    [ -z "$URL" ] && echo "(URL required)"
  done
  local_wordlist=""
  while [ -z "$local_wordlist" ]; do
    read -rp "Wordlist path: " local_wordlist || { echo; log_err "stdin closed"; exit 1; }
    if [ -z "$local_wordlist" ]; then
      echo "(wordlist path required)"
    elif [ -f "$local_wordlist" ]; then
      :
    elif [ -f "$WL_DIR/$local_wordlist" ]; then
      local_wordlist="$WL_DIR/$local_wordlist"
    else
      echo "Not found: $local_wordlist (tried as given and under $WL_DIR/)"
      local_wordlist=""
    fi
  done
  MODE="url"
  CUSTOM_WORDLISTS=("$local_wordlist")
  wl_lines=$(grep -cve '^\s*(#|$)' "$local_wordlist" 2>/dev/null || true)
  MAX_REQ_OVERRIDE="${wl_lines:-0}"
  log_info "Scanning $URL with $local_wordlist ($MAX_REQ_OVERRIDE paths — full run, no budget cap)"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --plan)       shift; PLAN_FILE="$1"; MODE="plan" ;;
    --url)        shift; URL="$1"; MODE="url" ;;
    --profile)    shift; PROFILE="$1" ;;
    --ext-profile) shift; EXT_PROFILE="$1" ;;
    --wordlist)   shift; CUSTOM_WORDLISTS+=("$1") ;;
    --threads)    shift; THREADS="$1" ;;
    --rate)       shift; RATE_MS="$1" ;;
    --target)     shift; TARGET_DOMAIN="$1" ;;
    --dry-run)    DRY_RUN="true" ;;
    --force)      FORCE="true" ;;
    --report-only) REPORT_ONLY="true" ;;
    --fresh-aggregate) FRESH_AGGREGATE="true" ;;
    --help|-h)    usage ;;
    *) log_err "Unknown option: $1"; usage 1 ;;
  esac
  shift
done

if [ -z "$MODE" ]; then
  log_err "Missing --plan or --url (run with no args for interactive mode)"; usage 1
fi

# Fresh-aggregate: truncate target aggregate files ONCE per invocation
# (batch = this run) — aggregate_to_target merges hosts append-only afterwards.
if [ "$FRESH_AGGREGATE" = "true" ] && [ -n "${TARGET_DOMAIN:-}" ]; then
  mkdir -p "${DIRBUST_BASE}/${TARGET_DOMAIN}"
  : > "${DIRBUST_BASE}/${TARGET_DOMAIN}/interesting-surface.txt"
  : > "${DIRBUST_BASE}/${TARGET_DOMAIN}/critical-exposure.txt"
  : > "${DIRBUST_BASE}/${TARGET_DOMAIN}/results-summary.md"
  log_info "Fresh aggregate: truncated directories/${TARGET_DOMAIN} targets"
fi

# Check ffuf
if ! command -v ffuf &>/dev/null; then
  log_err "ffuf not found — install: go install github.com/ffuf/ffuf/v2@latest"
  exit 1
fi

[ ! -d "$WL_DIR" ] && log_warn "Wordlist dir not found: $WL_DIR (only needed for bare-name --wordlist args)"

# Generate run ID
RUN_ID=$(date -u +"%Y%m%d-%H%M%S")-$(openssl rand -hex 3 2>/dev/null || echo "000000")

# Post-parse defaults — subenum parity (500 threads / ~500 req/s)
THREADS="${THREADS:-500}"
RATE_MS="${RATE_MS:-2}"

# ── --plan mode ─────────────────────────────────────────────────────
if [ "$MODE" = "plan" ]; then
  if [ ! -f "$PLAN_FILE" ]; then
    log_err "Plan file not found: $PLAN_FILE"; exit 1
  fi

  log_info "Reading scan plan: $PLAN_FILE"
  if [ ${#CUSTOM_WORDLISTS[@]} -eq 0 ]; then
    log_err "plan mode requires --wordlist <path> (no built-in wordlists)"
    exit 1
  fi

  # Parse plan and scan each entry
  python3 -c "
import json
with open('$PLAN_FILE') as f:
    data = json.load(f)
plans = data.get('plans', [])
if not plans:
    print('NO_PLANS')
else:
    for p in plans:
        host = p.get('host', '')
        intent = p.get('intent', 'default')
        profile = p.get('profile', 'light')
        ext_prof = p.get('ext_profile') or ''
        conf = p.get('confidence', 1.0)
        if conf < 0.5:
            print(f'SKIP_LOW_CONF|{host}|{intent}|{conf}')
        else:
            ext = ext_prof or ''
            print(f'SCAN|{host}|{intent}|{profile}|{ext}')
" | while IFS='|' read -r cmd rest; do
    case "$cmd" in
      NO_PLANS)
        log_warn "No plans in scan_plan.json — nothing to scan"
        ;;
      SKIP_LOW_CONF)
        log_info "  Skip: $rest"
        ;;
      SCAN)
        IFS='|' read -r host intent profile ext_prof <<< "$rest"
        if scan_host "$host" "$intent" "$profile" "$ext_prof" "$RATE_MS" "$DRY_RUN" "$RUN_ID" "$THREADS"; then
          host_domain=$(echo "$host" | sed -E 's|https?://||' | sed 's|/.*$||')
          aggregate_to_target "$host_domain"
        fi
        ;;
    esac
  done

  # Generate aggregate reports — extract domain from plan
  domains_from_plan=$(python3 -c "
import json, re
with open('$PLAN_FILE') as f:
    data = json.load(f)
seen = set()
for p in data.get('plans', []):
    h = p.get('host', '')
    if not h:
        continue
    m = re.search(r'https?://([^/]+)', h)
    if m and m.group(1) not in seen:
        seen.add(m.group(1))
        print(m.group(1))
" 2>/dev/null || echo "")

  if [ -n "$domains_from_plan" ]; then
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      generate_reports "$d"
    done <<< "$domains_from_plan"
  fi
fi

# ── --url mode ──────────────────────────────────────────────────────
if [ "$MODE" = "url" ]; then
  if [ -z "$URL" ]; then
    log_err "--url requires a URL"; usage 1
  fi

  # URL-format cleanup
  case "$URL" in
    http://*|https://*) ;;
    *) URL="https://$URL" ;;
  esac
  URL="${URL%/}"

  if [ "$DRY_RUN" = "true" ]; then
    host_domain=$(echo "$URL" | sed -E 's|https?://||' | sed 's|/.*$||')
    out_dir="${DIRBUST_BASE}/${host_domain}"
    if [ ${#CUSTOM_WORDLISTS[@]} -eq 0 ]; then
      log_err "dry-run requires --wordlist <path>"
      exit 1
    fi
    mapfile -t wl_files < <(resolve_wordlists "${CUSTOM_WORDLISTS[@]}")
    if [ ${#wl_files[@]} -eq 0 ]; then log_err "wordlist resolution failed"; exit 1; fi
    est=$(estimate_requests "${wl_files[@]}")
    budget="${MAX_REQ_OVERRIDE:-${PROFILE_BUDGET[$PROFILE]:-5000}}"
    [ "$est" -gt "$budget" ] && est=$budget

    echo ""
    echo "=== Dry Run ==="
    echo "Host:     $URL"
    echo "Profile:  $PROFILE"
    echo "Ext:      ${EXT_PROFILE:-none}"
    echo "Threads:  $THREADS"
    echo "Rate:     ~$((1000 / RATE_MS)) req/s (delay ${RATE_MS}ms)"
    echo "Target:   ${TARGET_DOMAIN:-none (per-host output only)}"
    echo "Budget:   $budget requests"
    echo "Estimated: ~$est requests"
    echo "Wordlists:"
    for f in "${wl_files[@]}"; do
      echo "  - $(basename "$f") ($(wc -l < "$f" | tr -d ' ') lines)"
    done
    echo "Output:   $out_dir"
    echo ""
    exit 0
  fi

  host_domain=$(echo "$URL" | sed -E 's|https?://||' | sed 's|/.*$||')

  # --report-only: regenerate reports from existing evidence, no scan
  if [ "$REPORT_ONLY" = "true" ]; then
    out_dir="${DIRBUST_BASE}/${host_domain}"
    if [ -d "$out_dir/evidence" ] && { find "$out_dir/evidence" -name 'entries.json' -type f 2>/dev/null | grep -q . || find "$out_dir/evidence" -name 'ffuf-*.json' -o -name 'ffuf_*.json' 2>/dev/null | grep -q .; }; then
      log_info "Report-only mode: regenerating reports from existing evidence"
      generate_reports "$host_domain"
      aggregate_to_target "$host_domain"
    else
      log_err "No evidence found for $host_domain — run a scan first (or --force)"
      exit 1
    fi
    log_ok "dir-bruteforce complete"
    exit 0
  fi

  if scan_host "$URL" "manual" "$PROFILE" "$EXT_PROFILE" "$RATE_MS" "$DRY_RUN" "$RUN_ID" "$THREADS"; then
    generate_reports "$host_domain"
    aggregate_to_target "$host_domain"
  else
    log_warn "Scan skipped (preflight/scope failure) — reports not generated"
  fi
fi

log_ok "dir-bruteforce complete"
