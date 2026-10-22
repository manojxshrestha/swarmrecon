#!/usr/bin/env bash
# merge/merge-sources.sh — collect the orphaned recon outputs into the two
# candidate lists consumed by Steps 13 and 14.
#
# Sources (all inside recon/<domain>/):
#   04-osint/subdomains.txt                 bare hosts / host:IPs (theHarvester)
#   08-puredns/puredns-subdomains.txt       bare hosts   (DNS bruteforce)
#   09-vhost/vhost-mc-all.json              Host: FUZZ.x  (ffuf pass A)
#   09-vhost/vhost-no403.json               Host: FUZZ.x  (ffuf pass B)
#   12-robots-sitemap/sitemap-urls.txt      full URLs    (<loc> entries)
#   12-robots-sitemap/advertised-sitemaps.txt  Sitemap: URLs
#
# Outputs (always written, possibly empty):
#   <outdir>/merge/merged-alive-domains.txt   bare in-scope hosts
#   <outdir>/merge/merged-https-subs.txt      https root seeds + sitemap URLs
#
# The merge is deliberately offline: it normalizes, scope-filters, and dedupes
# candidates. It does not probe them, so "alive" means "candidate host from an
# earlier step", not "verified live right now".
#
# Usage:
#   ./merge/merge-sources.sh -d example.com
#   ./merge/merge-sources.sh -d example.com -o recon/example.com
#
# Exit: 0 on success (even with zero sources), 2 on bad usage/missing python3.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DOMAIN=""
OUTDIR=""

usage() {
    printf 'Usage: %s -d <domain> [-o <outdir>]\n' "${0##*/}"
    printf '  -d  target domain (required)\n'
    printf '  -o  output dir (default: %s/recon/<domain>)\n' "$ROOT_DIR"
    exit 2
}

while getopts ":d:o:h" opt; do
    case "$opt" in
        d) DOMAIN="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        h|*) usage ;;
    esac
done
[ -n "$DOMAIN" ] || usage

# Keep this validation in step with swarmrecon.sh: domain is also a path part.
if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9_]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] \
    || [ "${#DOMAIN}" -gt 253 ]; then
    printf '[!] invalid domain: %s\n' "$DOMAIN" >&2
    exit 2
fi

command -v python3 >/dev/null 2>&1 || {
    printf '[!] python3 not found — required to merge vhost/sitemap outputs\n' >&2
    exit 2
}

[ -n "$OUTDIR" ] || OUTDIR="$ROOT_DIR/recon/$DOMAIN"
mkdir -p "$OUTDIR/merge" || exit 1

exec python3 - "$DOMAIN" "$OUTDIR" <<'PY'
import html
import json
import os
import re
import sys
from urllib.parse import urlsplit

domain = sys.argv[1].lower().strip(".")
outdir = sys.argv[2]
merge_dir = os.path.join(outdir, "merge")

# Hostname grammar: letters/digits/hyphen labels, no leading/trailing hyphen.
LABEL_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
HOST_RE = re.compile(
    r"^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    r"(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$"
)

hosts = set()
urls = set()


def in_scope(host):
    """Exact apex or a real subdomain boundary; no substring matches."""
    if host == domain:
        return True
    if not host.endswith("." + domain):
        return False
    # Crawler concatenation junk such as a.example.comexample.com contains
    # the apex twice. A legitimate in-scope host can only contain it once.
    return host.count(domain) <= 1


def norm_host(raw):
    """Accept a bare host or a URL and return a normalized in-scope host."""
    if raw is None:
        return None
    s = html.unescape(str(raw)).strip().strip("\"'").strip()
    if not s:
        return None

    # theHarvester occasionally emits wildcards and URLs.
    if s.startswith("*."):
        s = s[2:]

    if "://" in s or s.startswith("//"):
        if s.startswith("//"):
            s = "https:" + s
        try:
            s = urlsplit(s).hostname or ""
        except ValueError:
            return None
    else:
        # bare "host:port", "host:ip,ip,...", "host/path", or "host?query"
        s = re.split(r"[/?#]", s, maxsplit=1)[0]
        if "@" in s:
            s = s.rsplit("@", 1)[1]
        # theHarvester writes "host:1.2.3.4,2606:..." and other tools write
        # "host:port". Strip the metadata only when the suffix looks like a
        # port / IP list, so a malformed "host:junk" is still rejected later.
        if ":" in s:
            head, tail = s.split(":", 1)
            if not tail.strip() or re.match(r"^[0-9a-fA-F:.,\[\]\s]+$", tail):
                s = head

    s = s.strip().lower().rstrip(".")
    if not s or not HOST_RE.match(s):
        return None
    return s if in_scope(s) else None


def norm_url(raw):
    """Accept an absolute http(s) URL and return a normalized in-scope URL."""
    if raw is None:
        return None
    s = html.unescape(str(raw)).strip().strip("\"'").strip()
    if not s:
        return None
    if s.startswith("//"):
        s = "https:" + s
    if not re.match(r"^https?://", s, re.I):
        return None
    try:
        p = urlsplit(s)
        host = norm_host(p.hostname or "")
        port = p.port
    except ValueError:
        return None
    if not host:
        return None

    netloc = host
    if port and port not in (80, 443):
        netloc += ":%d" % port

    # Fragments are never sent to the server; drop them so seeds dedupe.
    # The root path is written without its trailing slash to match the
    # subenum-style root list and avoid host/ vs host duplicates.
    url = "%s://%s" % (p.scheme.lower(), netloc)
    if p.path and p.path != "/":
        url += p.path
    elif p.query:
        url += "/"
    if p.query:
        url += "?" + p.query
    return url


def add_host(raw):
    h = norm_host(raw)
    if h:
        hosts.add(h)


def add_url(raw):
    u = norm_url(raw)
    if not u:
        return
    urls.add(u)
    h = norm_host(urlsplit(u).hostname or "")
    if h:
        hosts.add(h)


def read_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                yield line
    except OSError:
        return


def load_vhost_json(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return
    results = data.get("results", []) if isinstance(data, dict) else data
    if not isinstance(results, list):
        return
    for item in results:
        if not isinstance(item, dict):
            continue
        raw_input = item.get("input")
        if isinstance(raw_input, dict):
            label = raw_input.get("FUZZ")
            if label is None:
                label = next(iter(raw_input.values()), None)
        elif isinstance(raw_input, str):
            label = raw_input
        else:
            label = None
        if not isinstance(label, str):
            continue
        label = label.strip().strip(".").lower()
        if not LABEL_RE.match(label):
            continue

        # ffuf records the actual Host header in "host" (FUZZ.domain). Prefer
        # it so a custom -o directory can never re-suffix labels for the wrong
        # target; fall back to label + domain for older/other JSON writers.
        candidate = item.get("host") or (label + "." + domain)
        h = norm_host(candidate)
        if h:
            hosts.add(h)


# 1. OSINT hosts
for line in read_lines(os.path.join(outdir, "04-osint", "subdomains.txt")):
    add_host(line)

# 2. puredns hosts
for line in read_lines(os.path.join(outdir, "08-puredns", "puredns-subdomains.txt")):
    add_host(line)

# 3. ffuf vhost results (both passes)
for name in ("vhost-mc-all.json", "vhost-no403.json"):
    load_vhost_json(os.path.join(outdir, "09-vhost", name))

# 4. sitemap <loc> URLs
for line in read_lines(os.path.join(outdir, "12-robots-sitemap", "sitemap-urls.txt")):
    add_url(line)

# 5. "Sitemap: https://..." lines from robots.txt
for line in read_lines(os.path.join(outdir, "12-robots-sitemap", "advertised-sitemaps.txt")):
    m = re.search(r"https?://\S+", html.unescape(line), re.I)
    if m:
        add_url(m.group(0).rstrip(".,;)"))

alive_path = os.path.join(merge_dir, "merged-alive-domains.txt")
seed_path = os.path.join(merge_dir, "merged-https-subs.txt")

# Step 13 crawls https-subs.txt, so every host found by OSINT, puredns, vhost
# fuzzing, or sitemap parsing gets an https root seed. Sitemap URLs collected
# above are kept with their original scheme and path.
for h in hosts:
    urls.add("https://" + h)

try:
    with open(alive_path, "w", encoding="utf-8") as fh:
        for h in sorted(hosts):
            fh.write(h + "\n")
    with open(seed_path, "w", encoding="utf-8") as fh:
        for u in sorted(urls):
            fh.write(u + "\n")
except OSError as e:
    print("[!] merge write failed: %s" % e, file=sys.stderr)
    sys.exit(1)

print("[*] merge sources: alive=%d hosts, https=%d seeds (%s)"
      % (len(hosts), len(urls), merge_dir))
PY
