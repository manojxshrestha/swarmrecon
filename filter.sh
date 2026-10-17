#!/bin/bash
set -uo pipefail
# NOTE: no 'set -e' — grep/httpx non-zero statuses are routine here, not fatal.

input_file="${1:-merged-crawl.txt}"
out_dir="check"
output_file="$out_dir/crawledurls.txt"
param_file="$out_dir/param-urls.txt"
raw_file="$out_dir/httpx-raw.txt"
api_file="$out_dir/api-candidates.txt"
idor_file="$out_dir/idor-candidates.txt"
api_param_file="$out_dir/api-param-candidates.txt"
idor_param_file="$out_dir/idor-param-candidates.txt"
temp_file=$(mktemp)
challenge_noise='__cf_chl'
tracking_noise='^(utm_[a-z0-9_]+|fbclid|gclid|msclkid|mc_eid|igshid|_zendesk)$'

trap 'rm -f "$temp_file"' EXIT

command -v httpx >/dev/null 2>&1 || { echo "Error: httpx not found in PATH"; exit 1; }
httpx -h 2>&1 | grep -- '-threads' > /dev/null || { echo "Error: 'httpx' is not ProjectDiscovery httpx (no -threads flag). Fix PATH."; exit 1; }
# NOTE: no 'grep -q' here — under 'pipefail' its early exit SIGPIPEs httpx and fakes a failure.

[ -f "$input_file" ] || { echo "Error: Input file '$input_file' not found in the current directory."; exit 1; }

mkdir -p "$out_dir" || { echo "FATAL: cannot create output dir '$out_dir' (permissions/disk?). Aborting."; exit 1; }
[ -d "$out_dir" ] && [ -w "$out_dir" ] || { echo "FATAL: '$out_dir' is not a writable directory. Aborting."; exit 1; }

print_summary() {
fcount() { if [ -f "$1" ]; then wc -l < "$1"; else echo 0; fi; }
echo
echo "========== FILTER SUMMARY =========="
printf '%-22s %s\n' "Domain-filtered:" "$(fcount "$temp_file")"
echo
printf '%-22s %s  -> %s\n' "Live URLs:" "$(fcount "$output_file")" "crawledurls.txt"
printf '%-22s %s  -> %s\n' "Parameter URLs:" "$(fcount "$param_file")" "param-urls.txt"
printf '%-22s %s  -> %s\n' "API candidates:" "$(fcount "$api_file")" "api-candidates.txt"
printf '%-22s %s  -> %s\n' "API + params:" "$(fcount "$api_param_file")" "api-param-candidates.txt"
printf '%-22s %s  -> %s\n' "IDOR candidates:" "$(fcount "$idor_file")" "idor-candidates.txt"
printf '%-22s %s  -> %s\n' "IDOR + params:" "$(fcount "$idor_param_file")" "idor-param-candidates.txt"
echo
echo "File contents:"
echo "  crawledurls.txt           = all live/in-scope URLs"
echo "  param-urls.txt            = live URLs with key=value parameters"
echo "  api-candidates.txt        = suspected API/technical routes"
echo "  api-param-candidates.txt  = API candidates with query parameters"
echo "  idor-candidates.txt       = URLs containing likely object references"
echo "  idor-param-candidates.txt = IDOR candidates with query parameters"
echo "===================================="
}

read -r -p "Enter domain to filter (e.g., example.com): " domain

# Normalize + validate bare hostname only
domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
if ! printf '%s\n' "$domain" | grep -qE '^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$'; then
    echo "Invalid domain. Enter a bare hostname such as example.com"
    exit 1
fi

escaped_domain=$(printf '%s\n' "$domain" | sed 's/\./\\./g')

# Step 1: Filter to in-scope hosts.
#   - Match on normalized host (lowercase, port stripped) but output the original URL.
#   - Extra count check: crawler-concatenation junk (e.g. sub.example.comexample.com)
#     ends in ".example.com" so pure boundary matching would accept it — reject any host
#     where the apex domain appears more than once.
awk -v d="$domain" -v ed="$escaped_domain" '
{
    url = $0
    if (match(url, /^https?:\/\/[^\/?#]+/)) {
        host = substr(url, RSTART, RLENGTH)
        sub(/^https?:\/\//, "", host)
        sub(/:[0-9]+$/, "", host)
        host = tolower(host)
        if (host == d || host ~ ("\\." ed "$")) {
            n = gsub(ed, "&", host)
            if (n <= 1) print url
        }
    }
}' "$input_file" \
  | grep -aviE "$challenge_noise" \
  | sort -u > "$temp_file"
scoped_n=$(wc -l < "$temp_file")
echo "[*] Domain-filtered URLs: $scoped_n"
if [ "$scoped_n" -eq 0 ]; then
    echo "[!] ABORT: nothing matched '$domain' — check domain spelling (e.g. libelle.nl, not libelle.com). No files touched."
    exit 1
fi

# Step 2: Liveness — output is the original URL (plain httpx mode, no -sc/-cl parsing).
#         Do NOT pass -fr: redirects are intentionally not followed (default), so the
#         original URL is preserved. Keep WAF/403/401/429/5xx alive, drop 404s + errors.
: > "$raw_file"
httpx -silent -no-color -threads 150 -timeout 8 -retries 1 -fc 404,000 \
  < "$temp_file" | tee "$raw_file" | sort -u > "$output_file"
echo "[+] Clean URLs saved to $output_file: $(wc -l < "$output_file")"
alive_n=$(wc -l < "$output_file")
if [ "$alive_n" -eq 0 ] && [ -s "$raw_file" ]; then
    echo "[!] httpx output empty but partial run captured — recovering probed URLs..."
    sort -u "$raw_file" > "$output_file"
    alive_n=$(wc -l < "$output_file")
    echo "[+] Recovered URLs in $output_file: $alive_n"
fi
if [ "$alive_n" -eq 0 ]; then
    echo "[!] WARNING: 0 live URLs — keeping previous candidate files untouched."
    print_summary
    exit 0
fi

# Step 3: Extract real key=value param URLs; strip fragments + tracking params but keep the URL.
awk -v track="$tracking_noise" '
{
    url = $0
    sub(/#.*/, "", url)            # fragments are not sent to the server
    if (url !~ /\?/) { next }
    q = url; sub(/^[^?]*\?/, "", q)
    n = split(q, parts, /&/)
    out = ""
    for (i = 1; i <= n; i++) {
        if (parts[i] !~ /=/) { continue }   # require key=value
        key = parts[i]; sub(/=.*/, "", key)
        if (tolower(key) ~ track) { continue }  # drop tracking params, keep the URL
        out = (out == "" ? "" : out "&") parts[i]
    }
    if (out == "") { next }
    base = url; sub(/\?.*/, "", base)
    print base "?" out
}' "$output_file" | sort -u > "$param_file"
echo "[+] Param URLs saved to $param_file: $(wc -l < "$param_file")"

# Step 4: Extract PATH-parameterized API routes (query-param extraction above
# structurally misses REST/RPC routes where identifiers live in the path,
# e.g. /resource/XResource/create, /api/v3/pidgets/boards/{u}/{b}/pins,
# /url_shortener/{hex}/redirect, /users/12345/profile).
# API candidates: endpoint discovery. IDOR candidates: object-reference targets.
# A URL can land in both (e.g. /api/v1/users/123).
# *-param files keep the exact query-bearing URLs for authz correlation
# (e.g. /api/v1/users/123?organization_id=456).
# Truncate first: awk 'print > file' never opens (hence never clears) a file
# it writes nothing to, so stale results would otherwise survive empty runs.
: > "$api_file"; : > "$idor_file"; : > "$api_param_file"; : > "$idor_param_file"
awk -v api_out="$api_file" -v idor_out="$idor_file" -v api_pout="$api_param_file" -v idor_pout="$idor_param_file" '
{
    url = $0
    sub(/#.*/, "", url)          # fragments are never sent
    exact = url                  # query preserved for *-param files
    sub(/\?.*/, "", url)         # normalized route for classification
    host = ""
    if (match(url, /^https?:\/\/[^\/?#]+/)) {
        host = substr(url, RSTART, RLENGTH)
        sub(/^https?:\/\//, "", host)
        sub(/:[0-9]+$/, "", host)
        host = tolower(host)
    }
    path = url
    sub(/^https?:\/\/[^\/]+/, "", path)
    if (path !~ /\//) { next }
    n = split(path, seg, "/")
    # a YYYY only starts a date run followed by a REAL month (1-12),
    # so /products/2026/99/widget is not misread as a date
    date_idx = 0
    for (j = 1; j <= n; j++) {
        if (seg[j] ~ /^(19|20)[0-9]{2}$/ && (j+1) <= n && seg[j+1] ~ /^(0?[1-9]|1[0-2])$/) { date_idx = j; break }
    }
    api_hit = 0; idor_hit = 0; ver = 0
    for (i = 1; i <= n; i++) {
        s = seg[i]; ls = tolower(s)
        if (ls == "api" || ls == "resource" || ls == "resources" || ls == "graphql" || ls == "rpc" || ls == "actions" || ls == "batch" || ls == "bulk" || ls == "mutation" || ls == "webhook" || ls == "webhooks" || ls == "callback" || ls == "oauth" || ls == "token" || ls == "session" || ls == "internal" || ls == "rest" || ls == "services" || ls == "json") { api_hit = 1 }
        # NOTE: bare "service" deliberately NOT a signal — it collides with out-of-scope libelle.nl/service.
        # "query" and "admin" likewise omitted: enormous noise on content sites.
        if (s ~ /^[0-9]+$/) {
            if (s ~ /^(19|20)[0-9]{2}$/) { continue }    # years are not IDs
            if (date_idx && i == date_idx+1 && s ~ /^(0?[1-9]|1[0-2])$/) { continue }  # MM only; DD kept (recall over noise)
            idor_hit = 1
        }
        else if (s ~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) { idor_hit = 1 }
        else if (s ~ /^[0-9a-fA-F]{8,}$/)     { idor_hit = 1 }
        else if (s ~ /^[vV][0-9]+$/)          { ver = 1 }  # supporting signal only, never fires alone
    }
    if (path ~ /\/(api\/v[0-9]+|resource)\//) { api_hit = 1 }
    if (host ~ /^api\./ && tolower(path) !~ /\.(css|js|mjs|png|jpg|jpeg|gif|svg|ico|webp|avif|woff|woff2|ttf|map|pdf|mp4|webm|mp3|zip|gz|tar)$/) { api_hit = 1 }
    if (ver && (idor_hit || api_hit || path ~ /\/api\//)) { api_hit = 1 }
    if (api_hit) { print url > api_out; if (exact != url) print exact > api_pout }
    if (idor_hit) { print url > idor_out; if (exact != url) print exact > idor_pout }
}' "$output_file"
sort -u -o "$api_file" "$api_file"
sort -u -o "$idor_file" "$idor_file"
sort -u -o "$api_param_file" "$api_param_file"
sort -u -o "$idor_param_file" "$idor_param_file"
echo "[+] API candidates saved to $api_file: $(wc -l < "$api_file")"
echo "[+] IDOR candidates saved to $idor_file: $(wc -l < "$idor_file")"
echo "[+] API param candidates saved to $api_param_file: $(wc -l < "$api_param_file")"
echo "[+] IDOR param candidates saved to $idor_param_file: $(wc -l < "$idor_param_file")"

print_summary
