<h1 align="center">
  <br>
  <img src="assets/swarmrecon.png" alt="swarmrecon" width="600">
  <br>
  swarmrecon
  <br>
</h1>

<h4 align="center">Single-command web recon — CT · DNS · nmap · bruteforce · vhosts · crawling · filtering — in one 12-step script</h4>

<p align="center">
  <img src="https://img.shields.io/badge/bash-5.x-4EAA25" alt="Bash 5.x">
  <img src="https://img.shields.io/badge/steps-12-blue" alt="12 Steps">
  <img src="https://img.shields.io/badge/tools-20%2B-orange" alt="20+ Tools">
  <img src="https://img.shields.io/badge/fail--soft-never%20aborts-success" alt="Fail-Soft">
  <img src="https://img.shields.io/badge/wordlists-bundled-lightgrey" alt="Bundled Wordlists">
  <img src="https://img.shields.io/badge/output-recon%2F%3Cdomain%3E-9cf" alt="recon/<domain>/">
</p>

<p align="center">
  <b>swarmrecon</b> runs your entire recon playbook as one command —
  <code>./swarmrecon.sh -d target.com</code> — across <b>12 steps</b> and <b>20+ tools</b>,
  writing everything into a fixed <code>recon/&lt;domain&gt;/</code> tree:
  per-step raw output plus <b>final consumable files at the root</b>
  (<code>https-subs.txt</code> · <code>alive-domains.txt</code> · <code>merged-crawl.txt</code> ·
  <code>check/param-urls.txt</code> · <code>check/gf/gf-*.txt</code>)
  ready to feed into further testing or an engagement pipeline.
  <b>Fail-soft</b> — a missing tool skips its step with a warning, never aborts the run.
</p>

---

**Quick links:** [What is this?](#what-is-this) · [Quick Install](#quick-install) · [Usage](#usage) · [Pipeline](#pipeline-12-steps) · [Output layout](#output-layout) · [Wordlists & patterns](#wordlists--patterns) · [Design notes](#design-notes)

---

## What is this?

Recon normally means hand-running ~30 commands across CT logs, DNS, port scans,
bruteforce, crawling, and filtering — then manually sorting outputs into a folder
structure. `swarmrecon.sh` encodes that whole playbook:

- **One command** runs the full chain end to end.
- **Fail-soft by design** — a missing tool or failed step produces a warning and a
  `skip`/`fail` row in the final summary; the script exits `0` with a summary table
  (`✓` ok / `−` skipped / `✗` failed) instead of dying halfway. Every step's raw
  stdout/stderr appends to `recon/<domain>/recon.log`.
- **Deterministic layout** — same folders, same filenames, every run. Steps delete
  their previous run's results first, so a failed rerun can never show stale data
  as fresh.
- **Wordlists ship with the repo** — no separate download step.

---

## Quick Install

```bash
# 1. Clone & enter
git clone https://github.com/manojxshrestha/swarmrecon.git && cd swarmrecon

# 2. Install deps (wappalyzer + chromium, ctfr, puredns + massdns, subenum, GF patterns)
./install.sh
```

> **Idempotent — safe to re-run**: `install.sh` checks every component first and
> **skips what's already installed** (only missing things are installed); the GF
> sync likewise skips patterns already present and identical in `~/.gf`.
> It covers `wappalyzer`, Playwright Chromium, `ctfr` (→ `~/ctfr`, own venv),
> `puredns` + `massdns` (→ Go bin + `/usr/local/bin`), `subenum` (→ `~/subenum`,
> runs its own `install.sh`), and **GF patterns** (`./sync-gf-patterns.sh` copies
> `gf-patterns/*.json` → `~/.gf`, skips the manifest, prunes stale files).
> Everything else must already be on your `PATH`
> (see [Prerequisites](#prerequisites)). Wordlists are bundled in `wordlists/`.

---

## Prerequisites

External tools the script drives (install anything missing — `./install.sh`
handles its own set; any tool absent → that step skips itself with a hint and
the run continues):

| Category | Tools |
|----------|-------|
| Core | `bash` (5.x), `curl`, `jq`, `python3`, `git` |
| DNS | `dig`, `nslookup`, `whois` |
| Scanning / fuzzing | `nmap`, `ffuf` |
| ProjectDiscovery | `httpx`, `dnsx` |
| URL discovery | `gau`, `anew`, `uro`, `hakrawler`, `katana`, `gospider` |
| Classification | `gf` — patterns **bundled** in `gf-patterns/` (126 patterns, synced to `~/.gf` by `./install.sh`) |
| Crawling | `waymore` (venv at `~/waymore/venv`) |

---

## Usage

```bash
./swarmrecon.sh -d target.com
```

| Flag | Meaning |
|------|---------|
| `-d <domain>` | target domain (required) |
| `-h` | usage |

Notes:

- Run it **from the repo directory** — outputs land in `recon/<domain>/` relative
  to your current working directory.
- Every run truncates and rewrites `recon/<domain>/recon.log`.
- Colours auto-disable when output is piped or when `NO_COLOR` is set.

---

## Pipeline (12 steps)

| # | Step | Tool(s) | Output |
|---|------|---------|--------|
| 1 | Technology discovery | `wappalyzer` (Playwright/Chromium) | `01-wappalyzer/technologies.json` |
| 2 | DNS + WHOIS | `dig`, `whois`, `nslookup` | `02-dns-whois/` — 13 files: A/AAAA/NS/MX/TXT/CAA/SOA/DMARC, Google/Cloudflare resolvers, nslookup, whois per domain + per resolved IP |
| 3 | Port scan (4 stages) | `nmap` | `03-nmap/` — `nmap-quick.txt` (`-Pn --open`), `nmap-version.txt` (`-sV`), `nmap-allports.txt` (`-p-`), `nmap-full.txt` (`-p- -sV`) |
| 4 | Certificate Transparency | `ctfr` (auto-venv) + `httpx` | `04-ctfr/` — `ctfr-subdomains.txt`, `live-ctfr-subdomains.txt` (live-probed) |
| 5 | Subdomain enumeration | `subenum` + CT merge | root **`https-subs.txt`**, **`alive-domains.txt`** |
| 6 | DNS bruteforce | `puredns` + `massdns` | `06-puredns/puredns-subdomains.txt` |
| 7 | Vhost fuzzing | `ffuf` (2 passes vs. dynamic baseline) | `07-vhost/` — `vhost-baseline.txt`, `vhost-mc-all.json`, `vhost-no403.json` |
| 8 | Zone transfer (AXFR) | `nslookup`, `dig axfr` per NS | `08-zone-transfer/` — `nslookup-NS.txt`, `axfr-<ns>.txt` |
| 9 | Directory bruteforce | `ffuf` | `09-directories/` — `ffuf-directory.json`, `ffuf-directory.txt` |
| 10 | Public files | `curl` | `10-robots-sitemap/` — `robots.txt`, `security.txt`, 7 sitemap path variants |
| 11 | Web crawling (10 sub-steps) | `waymore`, `gau`, `uro`, `hakrawler`, `katana`, `gospider`, `httpx`, `filter.sh`, `gf` | root crawl files + `gooutput/` + `check/` (+ `check/gf/`) |
| 12 | High-value paths | `ffuf` (auto-calibrated) | `12-high-value/` — `high-value-results.json`, `high-value-results.txt` |

### Step 11 in detail

1. `waymore -i <domain> -mode U` (venv at `~/waymore`) → root `wayurls.txt`
2. `echo <domain> | gau --threads 10 --subs | anew` → root `gauurls.txt`
3. `cat wayurls gauurls | uro | sort -u` → root `waygauurls.txt`
4. `cat https-subs.txt | hakrawler -subs -u -d 3` → root `hakcrawlurls.txt`
5. `cat https-subs.txt | katana -d 3 -jc -timeout 15 -c 20 | anew` → root `cleansubskatanaurls.txt`
6. `gospider -S https-subs.txt -o gooutput/ -c 10 -d 3 -t 20`
7. `extracturls.sh -f gooutput/ -d <domain>` → root `alivesubsurls.txt`
8. merge of ③④⑤⑦ via `uro` → root **`merged-crawl.txt`**
9. `filter.sh` (liveness + param/API/IDOR classification) → `check/`
10. `gf-extract.sh check/param-urls.txt check/gf` → `check/gf/gf-*.txt`

---

## Output layout

```
recon/<domain>/
├── recon.log                  # all raw tool output for this run
├── https-subs.txt             # final: alive subdomains (URLs, https)
├── alive-domains.txt          # final: alive bare hostnames
├── wayurls.txt  gauurls.txt  waygauurls.txt  hakcrawlurls.txt
├── cleansubskatanaurls.txt  alivesubsurls.txt
├── merged-crawl.txt           # final: deduped crawl merge
├── check/                     # filter.sh classification
│   ├── crawledurls.txt  param-urls.txt  httpx-raw.txt
│   ├── api-candidates.txt  idor-candidates.txt
│   ├── api-param-candidates.txt  idor-param-candidates.txt
│   └── gf/gf-*.txt            # gf-extract.sh pattern classes
├── gooutput/                  # gospider raw + extracturls intermediates
├── 01-wappalyzer/  02-dns-whois/  03-nmap/  04-ctfr/
├── 06-puredns/  07-vhost/  08-zone-transfer/  09-directories/
├── 10-robots-sitemap/  12-high-value/
└── subdomains/                # step-5 staging (ends empty after merge)
```

---

## Helper scripts

Standalone tools, also invoked automatically by step 11:

| Script | Usage | Notes |
|--------|-------|-------|
| `extracturls.sh` | `./extracturls.sh -f <gospider_folder> -d <domain>` | Extracts + liveness-probes subdomains from crawler output. Requires `dnsx` + `httpx`. |
| `filter.sh` | `echo <domain> \| ./filter.sh [input]` | Interactive domain prompt (fed via stdin). Defaults to `merged-crawl.txt` in CWD; writes 6 category files to `check/`. Keeps WAF/403/401 alive, drops 404s/errors; strips fragments + tracking params; classifies API/IDOR candidates. |
| `gf-extract.sh` | `./gf-extract.sh [input_file] [out_dir]` | Defaults: `check/param-urls.txt` → `check/gf/`. `$1` must be a **file** (not a directory). Only patterns with hits produce files. |
| `sync-gf-patterns.sh` | `./sync-gf-patterns.sh` | Copies `gf-patterns/*.json` → `~/.gf` (skips identical, manifest excluded, prunes stale). Called by `install.sh`; run standalone after editing patterns. |

---

## Wordlists & patterns

| File | Used by |
|------|---------|
| `subdomains-top1million-20000.txt` | step 6 — puredns bruteforce |
| `resolvers.txt` | step 6 — puredns resolvers |
| `common.txt` | step 7 — vhost fuzzing |
| `raft-medium-directories.txt` | step 9 — directory bruteforce |
| `high-value-paths.txt` | step 12 — secrets/disclosure/juicy files (`#`-marked sections) |

### `gf-patterns/` (127 files)

Git-tracked source of truth for `gf(1)` patterns (126 real patterns +
`category-index.json` manifest). `gf` itself only reads `~/.gf`, so:

- `./install.sh` → runs `./sync-gf-patterns.sh`: **copies missing/changed
  patterns** into `~/.gf/` (identical files are skipped untouched — safe to
  re-run), skips `category-index.json` (manifest), and prunes stale `~/.gf`
  files no longer shipped. Repo stays the source of truth.
- Rerun standalone anytime: `./sync-gf-patterns.sh` then `gf -list` to verify.

---

## Design notes

- **Fail-soft**: guards check every tool before running; results land in the summary
  table instead of exiting. The script exits `0` after printing it regardless of
  individual step results.
- **Fresh-run hygiene**: steps that produce files delete their previous outputs
  before running, so a failed step can never pass off stale results as new.
- **Exit-code semantics**: steps built from informational commands (DNS queries
  that legitimately return NXDOMAIN, `curl` of possibly-absent files) are judged by
  *output existence*, not raw exit codes — that's why some blocks are written as
  `{ cmd1; cmd2; }` rather than `&&` chains.
- **No runtime installs**: `swarmrecon.sh` never installs anything — missing tools
  are reported with the exact command needed to install them.
