<h1 align="center">
  <br>
  <img src="assets/swarmrecon.png" alt="swarmrecon" width="600">
  <br>
  swarmrecon
  <br>
</h1>

<h4 align="center">Single-command web recon — CT · DNS · nmap · bruteforce · vhosts · crawling · filtering — in one 14-step script</h4>

<p align="center">
  <img src="https://img.shields.io/badge/bash-5.x-4EAA25" alt="Bash 5.x">
  <img src="https://img.shields.io/badge/steps-14-blue" alt="14 Steps">
  <img src="https://img.shields.io/badge/tools-20%2B-orange" alt="20+ Tools">
  <img src="https://img.shields.io/badge/fail--soft-never%20aborts-success" alt="Fail-Soft">
  <img src="https://img.shields.io/badge/wordlists-bundled-lightgrey" alt="Bundled Wordlists">
  <img src="https://img.shields.io/badge/output-recon%2F%3Cdomain%3E-9cf" alt="recon/<domain>/">
</p>

<p align="center">
  <b>swarmrecon</b> runs your entire recon playbook as one command —
  <code>./swarmrecon.sh -d target.com</code> — across <b>14 steps</b> and <b>20+ tools</b>,
  writing everything into a fixed <code>recon/&lt;domain&gt;/</code> tree:
  per-step raw output plus <b>final consumable files at the root</b>
  (<code>https-subs.txt</code> · <code>alive-domains.txt</code> · <code>merged-crawl.txt</code> ·
  <code>check/param-urls.txt</code> · <code>check/gf/gf-*.txt</code>)
  ready to feed into further testing or an engagement pipeline.
  <b>Fail-soft</b> — a missing tool skips its step with a warning, never aborts the run.
</p>

---

**Quick links:** [What is this?](#what-is-this) · [Quick Install](#quick-install) · [Usage](#usage) · [Manual](#manual) · [Manual: after Step 5](#port-discovery--service-brute-forcing-manual) · [Manual: Step 11](#directory-bruteforce-manual) · [Pipeline](#pipeline-14-steps) · [Source merge](#source-merge) · [Engagement Flow](#engagement-flow) · [Wordlists & patterns](#wordlists--patterns) · [Design notes](#design-notes)

---

> [!IMPORTANT]
> **Two workflows are manual — `swarmrecon.sh` does not run them:**
>
> - **Port Discovery & Service Brute-Forcing** — optional extension **after Step 5**
>   (`masscan` / `dnmasscan` → `nmap -sV` → `brutespray`).
>   **[Jump to the guide ↓](#port-discovery--service-brute-forcing-manual)**
> - **Step 11 — Directory Bruteforce** — the pipeline only records a *skip* row;
>   run `./bruteforce/dir-bruteforce.sh` yourself.
>   **[Jump to the guide ↓](#directory-bruteforce-manual)**

---

## What is this?

Recon normally means hand-running ~30 commands across CT logs, DNS, port scans,
bruteforce, crawling, and filtering — then manually sorting outputs into a folder
structure. `swarmrecon.sh` encodes that whole playbook:

- **One command** runs the full chain end to end.
- **Fail-soft by design** — a missing tool or failed step produces a warning and a
  `skip`/`fail` row in the final summary; the script exits `0` with a summary table
  (`✓` ok / `−` skipped / `✗` failed) instead of dying halfway. Most tool output
  is appended to `recon/<domain>/recon.log`; some tools write directly to their
  step files (see the per-step notes below).
- **Deterministic layout** — same folders, same filenames, every run. Steps that
  feed later stages clear their previous results before use, so a failed rerun
  cannot feed stale data downstream; a skipped step may still leave old raw
  evidence in its own folder.
- **Wordlists ship with the repo** — no separate download step.

---

## Quick Install

```bash
# 1. Clone & enter
git clone https://github.com/manojxshrestha/swarmrecon.git && cd swarmrecon

# 2. Install deps (wappalyzer + chromium, ctfr, unfurl, puredns + massdns,
#    subenum, GF patterns; plus intel/OSINT tools via uv — msftrecon ·
#    Scopify · Spoofy · cloud_enum · theHarvester)
./install.sh
```

> **Idempotent — safe to re-run**: `install.sh` checks every component first and
> **skips what's already installed** (only missing things are installed); the GF
> sync likewise skips patterns already present and identical in `~/.gf`.
> It covers `wappalyzer`, Playwright Chromium, `ctfr` (→ `~/ctfr`, own venv),
> `puredns` + `massdns` (→ Go bin + `/usr/local/bin`), `subenum` (→ `~/subenum`,
> runs its own `install.sh`), and **GF patterns** (`./gf-scripts/sync-gf-patterns.sh` copies
> `gf-patterns/*.json` → `~/.gf`, skips the manifest, prunes stale files).
> With `uv` present it also sets up the step-3/4 intel tools — `msftrecon`,
> `Scopify`, `Spoofy`, `cloud_enum` (→ `~/.local/bin/<repo>`, own venv) and
> `theHarvester` (→ `~/theHarvester`); without `uv` they're skipped with a hint.
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
| Classification | `gf` — patterns **bundled** in `gf-patterns/` (125 patterns, synced to `~/.gf` by `./install.sh`) |
| Crawling | `waymore` — manual venv: `python3 -m venv ~/waymore/venv && ~/waymore/venv/bin/pip install waymore` (step 13 activates `~/waymore/venv`) |
| Intel / OSINT (steps 3-4) | `theHarvester`, `msftrecon`, `Scopify`, `Spoofy`, `cloud_enum` — set up by `./install.sh` via `uv` |

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
- **Manual after Step 5:** port discovery and service brute-forcing are not
  automated — see [Port Discovery & Service Brute-Forcing](#port-discovery--service-brute-forcing-manual).
- **Manual Step 11:** directory bruteforce is not automated — the pipeline
  records a *skip* row; run `./bruteforce/dir-bruteforce.sh` yourself
  (see [Directory Bruteforce](#directory-bruteforce-manual)).

---

<a id="manual"></a>
## Manual

`swarmrecon.sh` runs steps 1–14 automatically, with **two deliberate manual
branches**. It never executes either one for you.

These are the only two parts of the playbook that are **not** run by
`swarmrecon.sh`. Both are deliberate manual decisions.

| When | Manual workflow | Command / chain | Output | Guide |
|---|---|---|---|---|
| **After Step 5** | **Port Discovery & Service Brute-Forcing** | `masscan` / `dnmasscan` → `nmap -sV` → `brutespray` | service inventory + credential results | **[Open guide ↓](#port-discovery--service-brute-forcing-manual)** |
| **Step 11** | **Directory Bruteforce** | `./bruteforce/dir-bruteforce.sh` | `directories/<host>/` | **[Open guide ↓](#directory-bruteforce-manual)** |

---

## Pipeline (14 steps)

| # | Step | Tool(s) | Output |
|---|------|---------|--------|
| 1 | Technology discovery | `wappalyzer` (Playwright/Chromium) | `01-wappalyzer/technologies.json` |
| 2 | DNS + WHOIS | `dig`, `whois`, `nslookup` | `02-dns-whois/` — 13 files: A/AAAA/NS/MX/TXT/CAA/SOA/DMARC, Google/Cloudflare resolvers, nslookup, whois per domain + per resolved IP |
| 3 | Passive intel | `whois` + `msftrecon`, `Scopify`, `Spoofy`, `cloud_enum` (auto-venv) | `03-intel/` — `domain_info_general.txt`, `azure_tenant_domains.txt`, `scopify.txt`, `spoof.txt`, `cloud_enum.txt` |
| 4 | OSINT — subdomains + emails | `theHarvester` (2 source sets) | `04-osint/` — `theharvester_subdomains.json`, `theharvester_emails.json`, `subdomains.txt`, `emails.txt` (hosts forwarded by the Step 13/14 merge) |
| 5 | Port scan (single pass) | `nmap` | `05-nmap/` — `nmap-full.txt` (`-Pn --open -sV -T4 --top-ports 1000 --min-rate 500`) |
| 6 | Certificate Transparency | `ctfr` (auto-venv) + `httpx` | `06-ctfr/` — `ctfr-subdomains.txt`, `live-ctfr-subdomains.txt` (live-probed) |
| 7 | Subdomain enumeration | `subenum` + CT merge | root **`https-subs.txt`**, **`alive-domains.txt`** |
| 8 | DNS bruteforce | `puredns` + `massdns` | `08-puredns/puredns-subdomains.txt` (forwarded by the Step 13/14 merge) |
| 9 | Vhost fuzzing | `ffuf` (2 passes vs. dynamic baseline) | `09-vhost/` — `vhost-baseline.txt`, `vhost-mc-all.json`, `vhost-no403.json` (hits forwarded as `<label>.<domain>` candidates) |
| 10 | Zone transfer (AXFR) | `nslookup`, `dig axfr` per NS | `10-zone-transfer/` — `nslookup-NS.txt`, `axfr-<ns>.txt` |
| 11 | **DIRECTORY BRUTEFORCE — MANUAL** | *not run by pipeline* | run `./bruteforce/dir-bruteforce.sh` (interactive prompts: target URL → wordlist path) → `directories/<host>/` |
| 12 | Public files | `curl` | `12-robots-sitemap/` — `robots.txt`, `security.txt`, 7 sitemap path variants (sitemap URLs forwarded as crawl seeds) |
| 13 | Web crawling (10 sub-steps) | merge + `waymore`, `gau`, `uro`, `anew`, `hakrawler`, `katana`, `gospider`, `dnsx`, `httpx`, `extracturls.sh`, `filter.sh`, `gf` | root crawl files + `gooutput/` + `check/` (+ `check/gf/`); starts by merging Step 4/8/9/12 candidates into the root lists |
| 14 | High-value paths | `ffuf` (auto-calibrated) — sources: `https://<domain>` + each host in `alive-domains.txt` (including the merged Step 4/8/9/12 candidates) | `14-high-value/` — `high-value-results.json` (merged), `high-value-results.txt`, `high-value-<host>.json` |

> **Merge hand-off:** before Step 13 and again before Step 14, `merge/merge-sources.sh` folds the Step 4/8/9/12 candidates into `recon/<domain>/merge/merged-alive-domains.txt` and `merged-https-subs.txt`, appends them to the root `alive-domains.txt` / `https-subs.txt`, then deletes the merged files. See [Source merge for Steps 13/14](#source-merge).

> [!IMPORTANT]
> **Manual branches — the pipeline never runs these:**
>
> - **After Step 5 — [Port Discovery & Service Brute-Forcing](#port-discovery--service-brute-forcing-manual):**
>   `masscan` / `dnmasscan` → `nmap -sV` → `brutespray`. This is an explicit
>   credential-guessing decision.
> - **Step 11 — [Directory Bruteforce](#directory-bruteforce-manual):**
>   `./bruteforce/dir-bruteforce.sh`. `swarmrecon.sh` only records a *skip* row and prints
>   the pointer.

<a id="source-merge"></a>
### Source merge for Steps 13/14

Steps 4, 8, 9, and 12 produce candidates that used to stay inside their
numbered directories. `merge/merge-sources.sh` collects them into two
transient files under `recon/<domain>/merge/`:

| Merged file | Built from | Contents |
|---|---|---|
| `merged-alive-domains.txt` | `04-osint/subdomains.txt` · `08-puredns/puredns-subdomains.txt` · `09-vhost/*.json` · sitemap hostnames | bare in-scope hosts (`<label>.<domain>` for vhost hits) |
| `merged-https-subs.txt` | the same hosts + `12-robots-sitemap/sitemap-urls.txt` · `advertised-sitemaps.txt` | one `https://<host>` seed per merged host, plus sitemap URLs (their scheme is preserved) |

The merge is offline: it normalizes (lowercase, strips wildcards, ports,
`host:IP,...` annotations, and fragments), keeps only exact in-scope hosts
(apex or a real `.domain` boundary), rejects crawler-concatenation junk, and
dedupes. Every host in `merged-alive-domains.txt` also gets an `https://` seed
in `merged-https-subs.txt`, so OSINT/puredns hosts are not left uncrawled. It
does **not** probe the candidates — a merged host is a candidate, not a
verified live host.

Source extraction: `04-osint` keeps the host before any `:IP,...` annotation;
`08-puredns` is host-only; `09-vhost` reads ffuf JSON (`host`, falling back to
`input.FUZZ`); `12` takes only absolute `http(s)` URLs from `<loc>` and
`Sitemap:` lines. Everything else in those files (JSON metadata, status codes,
IPs, paths outside URLs) is discarded.

`swarmrecon.sh` then performs the append-and-delete flow at the start of both
Step 13 and Step 14 (commands shown from `recon/<domain>/`):

```bash
cat merge/merged-alive-domains.txt >> alive-domains.txt
rm  merge/merged-alive-domains.txt
cat merge/merged-https-subs.txt   >> https-subs.txt
rm  merge/merged-https-subs.txt
```

The implementation appends with `sort -u` (so the root lists stay deduped) and
regenerates the candidates before each of the two steps, which makes the flow
idempotent and rerun-safe. The `merge/` directory is removed once empty; the
final `alive-domains.txt` and `https-subs.txt` remain at the recon root.

Run it standalone when you want the two lists without starting a crawl:

```bash
./merge/merge-sources.sh -d example.com          # → recon/example.com/merge/
./merge/merge-sources.sh -d example.com -o recon/example.com
```

### Step 13 in detail

0. `merge/merge-sources.sh` → append `merged-alive-domains.txt` /
   `merged-https-subs.txt` to the root lists, then delete the merged files.
1. `cd ~/waymore && waymore -i <domain> -mode U -oU wayurls.txt` (venv activated, runs inside `~/waymore`, stale `wayurls.txt` removed first) → **moved** to root `wayurls.txt`
2. `echo <domain> | gau --threads 10 --subs | anew gauurls.txt` (no `anew` → plain `> gauurls.txt`) → root `gauurls.txt`
   `gau` reads `~/.gau.toml`; `./install.sh` creates it when absent (20 threads,
   5 retries, wayback/commoncrawl/otx/urlscan). If providers are unreachable or
   rate-limited, `gau` can still exit `0` with 0 URLs — run it with
   `--verbose` to see per-provider errors.
3. `cat wayurls.txt gauurls.txt | uro | sort -u > waygauurls.txt` (only the inputs that exist; no `uro` → `sort -u` alone) → root `waygauurls.txt`
4. `cat https-subs.txt | hakrawler -subs -u -d 3 > hakcrawlurls.txt` → root `hakcrawlurls.txt`
5. `cat https-subs.txt | katana -d 3 -jc -timeout 15 -c 20 | anew cleansubskatanaurls.txt` (no `anew` → plain `> cleansubskatanaurls.txt`) → root `cleansubskatanaurls.txt`
6. `gospider -S https-subs.txt -o gooutput/ -c 10 -d 3 -t 20` → `gooutput/`
7. `extracturls.sh -f gooutput/ -d <domain>` (requires `dnsx` + `httpx`) → writes into `gooutput/`, then `alivesubsurls.txt` is **moved** to root
8. `cat waygauurls.txt cleansubskatanaurls.txt hakcrawlurls.txt alivesubsurls.txt | uro > merged-crawl.txt` (missing inputs skipped with a warning; no `uro` → `sort -u`) → root **`merged-crawl.txt`**
9. `cd recon/<domain> && echo <domain> | ../../filter.sh` (liveness + param/API/IDOR classification; cwd must be the recon dir so its default input `merged-crawl.txt` resolves) → `check/`
10. `cd recon/<domain> && ../../gf-scripts/gf-extract.sh check/param-urls.txt check/gf` → `check/gf/gf-*.txt`

---

<a id="port-discovery--service-brute-forcing-manual"></a>
## Port Discovery & Service Brute-Forcing — MANUAL (after Step 5)

> [!IMPORTANT]
> **Not run by `swarmrecon.sh`.** This is an optional manual extension after
> Step 5. Only use it with explicit authorization for credential guessing.

Optional workflow that extends **step 5** — it covers the complete pipeline from
fast port discovery to service-aware credential guessing using
**masscan / dnmasscan → nmap → brutespray**:

```mermaid
flowchart LR
    classDef entry fill:#1e1b4b,stroke:#818cf8,stroke-width:2px,color:#e0e7ff
    classDef phase fill:#0f172a,stroke:#38bdf8,stroke-width:1.5px,color:#e2e8f0
    classDef decision fill:#451a03,stroke:#f59e0b,stroke-width:2px,color:#fde68a
    classDef manual fill:#042f2e,stroke:#2dd4bf,stroke-width:1.5px,color:#ccfbf1
    classDef artifact fill:#052e16,stroke:#4ade80,stroke-width:1.5px,color:#dcfce7
    classDef halt fill:#450a0a,stroke:#f87171,stroke-width:1.5px,color:#fecaca

    IP["raw IP list<br/>$ipFile"]:::entry
    DOM["alive-domains.txt<br/>step 7 final"]:::entry

    IP -->|"masscan<br/>-p1-65535 · --max-rate · -oG"| MS["masscan.log<br/>grepable IP:port/open"]:::artifact
    DOM -->|"dnmasscan<br/>resolve, then --top-ports -oG"| DN["dns.log + masscan.log<br/>domains → IPs → ports"]:::artifact

    MS --> XIP["unique IPs —<br/>Host: lines, deduped"]:::phase
    DN --> XIP
    MS --> XPT["unique open ports —<br/>/open matches, deduped"]:::phase
    DN --> XPT

    XIP --> NM["nmap -sV<br/>-iL ips -p ports -oG"]:::phase
    XPT --> NM
    NM --> GN["nmap-scan.gnmap<br/>22/open/tcp//ssh/OpenSSH 8.2p1/<br/>service names resolved"]:::artifact

    GN --> AUTH{"credential testing<br/>authorized?"}:::decision
    AUTH -->|"yes — deliberate decision"| BS["brutespray -f (medusa)<br/>SSH · FTP · MySQL · RDP ..."]:::manual
    AUTH -->|"no"| HOLD["stop at inventory —<br/>ports + services only"]:::halt
    BS --> RES["scan-results/<br/>SecLists default-credentials<br/>+ custom wordlists"]:::artifact

    NOTE["not automated in swarmrecon.sh —<br/>sudo + explicit authorization"]:::halt
    GN -.-> NOTE
```

> **Not automated in `swarmrecon.sh`** — launching credential guessing must
> always be a deliberate, authorized decision. Follow the steps below.

### 1. Port Analysis with Masscan

```bash
masscan -p1-65535 -iL $ipFile --max-rate 1800 -oG $outPutFile.log
```

| Option | Purpose |
|--------|---------|
| `-p1-65535` | Scan all TCP ports |
| `-iL $ipFile` | Read target IPs from a file |
| `--max-rate` | Packets per second (adjust to your network) |
| `-oG` | Output in grepable format (compatible with Nmap) |

### 2. Port Analysis with DNMasscan

dnmasscan resolves domain names to IP addresses before scanning, then runs
Masscan. This is useful when you have a list of domains instead of raw IPs.

**Install Masscan (if not already)**

```bash
sudo apt-get --assume-yes install git make gcc
git clone https://github.com/robertdavidgraham/masscan
cd masscan
sudo make install
```

**Download DNMasscan script**

```bash
wget https://raw.githubusercontent.com/rastating/dnmasscan/refs/heads/master/dnmasscan
chmod +x dnmasscan
```

**Run DNMasscan**

```bash
sudo ./dnmasscan alive-domains.txt dns.log --top-ports 1000 -oG masscan.log
```

(`dns.log` = resolution output, `masscan.log` = grepable port results.)

### 3. Service Scanning (Bridge to BruteSpray)

Masscan only reports open ports. It does not identify the running service
(e.g. SSH vs. a custom service on port 2222). BruteSpray requires **service
names** to choose the correct brute-forcing module.

Therefore you must feed the discovered open ports to Nmap with service version
detection (`-sV`). Extract IPs and ports from Masscan output, then run targeted
Nmap:

```bash
nmap -sV -iL <(grep -oP 'Host: \K[0-9.]+' masscan.log | sort -u) -p$(grep -oP '\d+(?=/open)' masscan.log | sort -u | paste -sd,) -oG nmap-scan.gnmap
```

**Breakdown:**

| Part | What it does |
|------|--------------|
| `grep -oP 'Host: \K[0-9.]+' masscan.log \| sort -u` | Extract unique IP addresses from masscan.log |
| `grep -oP '\d+(?=/open)' masscan.log \| sort -u \| paste -sd,` | Extract unique open port numbers and join with commas |
| `nmap -sV -iL <(...) -p<ports> -oG nmap-scan.gnmap` | Run Nmap service scan only on those IPs and ports, output in grepable format |

Now `nmap-scan.gnmap` contains lines like:

```
Host: 192.168.1.10 Ports: 22/open/tcp//ssh/OpenSSH 8.2p1/, 3306/open/tcp//mysql/MySQL 5.7/
```

BruteSpray can parse this reliably.

### 4. Default Password Scanning with BruteSpray

**Login Pages**

There are three things you need to have if you want to launch a brute force
attack. The three things you need are an **endpoint with a login page, a
username, and a password.**

First, you need to find the endpoint you want to target — here BruteSpray finds
the login services from the Nmap output:

**Default Credentials:** https://github.com/danielmiessler/SecLists/tree/master/Passwords/Default-Credentials

BruteSpray reads the Nmap grepable file and launches Medusa against each
discovered login service (SSH, FTP, MySQL, RDP, etc.) using default or custom
wordlists.

```bash
# install
go install github.com/x90skysn3k/brutespray/v2@latest

brutespray -f nmap-scan.gnmap

# Use the -o flag to set a custom path
brutespray -f nmap-scan.gnmap -o scan-results
```

⚠️ Only against systems you own or have **explicit authorization** to test.

---

<a id="directory-bruteforce-manual"></a>
## Directory Bruteforce — MANUAL (Step 11)

> [!IMPORTANT]
> **Not run by `swarmrecon.sh`.** The pipeline records a *skip* row for Step 11.
> Run `./bruteforce/dir-bruteforce.sh` yourself when you want path discovery.

Optional workflow that **step 11** hands off to — `swarmrecon.sh` never runs it,
it only records a *skip* row in the summary. `./bruteforce/dir-bruteforce.sh` is a
standalone ffuf driver: preflight → WAF fingerprint → robots harvest →
budgeted ffuf loop → false-positive kill layer → classified reports, all under
`directories/<host>/` at the repo root.

```mermaid
flowchart TD
    classDef entry fill:#1e1b4b,stroke:#818cf8,stroke-width:2px,color:#e0e7ff
    classDef phase fill:#0f172a,stroke:#38bdf8,stroke-width:1.5px,color:#e2e8f0
    classDef decision fill:#451a03,stroke:#f59e0b,stroke-width:2px,color:#fde68a
    classDef manual fill:#042f2e,stroke:#2dd4bf,stroke-width:1.5px,color:#ccfbf1
    classDef artifact fill:#052e16,stroke:#4ade80,stroke-width:1.5px,color:#dcfce7
    classDef halt fill:#450a0a,stroke:#f87171,stroke-width:1.5px,color:#fecaca

    Start(["./bruteforce/dir-bruteforce.sh"]):::entry --> Mode{"how is it invoked?"}:::decision

    Mode -->|"interactive"| INT["prompts: target URL + wordlist<br/>bare names resolve under wordlists/<br/>whole list — no budget cap"]:::phase
    Mode -->|"--url + --wordlist"| CLI["scripted flags<br/>--profile light / standard / deep<br/>--threads 500 · --rate 2 ms"]:::phase
    Mode -->|"--plan scan.json"| PLAN["walk plans[]: host · intent · profile<br/>skip entries with confidence under 0.5"]:::phase
    Mode -->|"--dry-run"| DRY["print host · budget · wordlist sizes<br/>scan nothing"]:::manual
    Mode -->|"--report-only"| RO["re-run classifier on existing<br/>evidence/ — no ffuf, no wordlist"]:::manual

    INT --> PRE
    CLI --> PRE
    PLAN --> PRE
    PRE{"preflight<br/>getent DNS + HTTP probe"}:::decision
    PRE -->|"dead host"| SKIPH["skip host —<br/>no budget spent"]:::halt
    PRE -->|"alive"| WAF["WAF fingerprint — root-page probe<br/>DataDome · Cloudflare · Akamai · AWS<br/>403/503 fallback arms the wall check"]:::phase
    WAF --> RB["robots.txt / sitemap harvest<br/>5 doc paths → evidence/robots.txt"]:::phase
    RB --> LOOP

    LOOP["ffuf pass per wordlist<br/>clean temp copy: comments/blanks stripped,<br/>leading slash removed, truncated to budget<br/>-ac · -mc 200-299,301,302,401,403,405,429,500,502,503<br/>-of json · timeout --foreground"]:::phase
    LOOP --> STOP{"stop condition"}:::decision
    STOP -->|"budget left, more wordlists"| LOOP
    STOP -->|"budget_exhausted —<br/>5 000 / 50 000 / 150 000"| EV
    STOP -->|"rate_limited —<br/>429 share over 30%"| EV
    STOP -->|"waf_blocked — WAF suspected +<br/>2 consecutive zero-hit lists"| EV
    STOP -->|"lists done — deep profile<br/>with --ext-profile set"| EXT["extension scan — -e .php,.bak,...<br/>on raft-medium-files<br/>shares the same budget"]:::phase
    EXT --> EV

    EV["evidence/<br/>scan-meta.json · results.json<br/>ffuf-&lt;wordlist&gt;.json<br/>&lt;status&gt;/entries.json — JSONL, 429 never stored"]:::artifact
    EV --> FP["false-positive kill layer<br/>random control probe: ±64 B, or max(256 B, 2%)<br/>signature clusters ≥5x → shell-signature or waf-block-page<br/>429 separation · exact-URL dedup"]:::phase
    FP --> CLS["regex classification<br/>critical: .git/ .env heapdump id_rsa ...<br/>interesting: /admin /graphql /swagger ..."]:::phase
    CLS --> REP["critical-exposure.txt<br/>interesting-surface.txt<br/>results-summary.md — with FP-drop counts"]:::artifact
    RO --> CLS

    REP --> AGG{"--target set?"}:::decision
    AGG -->|"yes"| MERGE["merge every host's three reports<br/>into directories/&lt;domain&gt;/<br/>source: &lt;host&gt; separators<br/>--fresh-aggregate truncates once"]:::manual
    AGG -->|"no"| HOST(["directories/&lt;host&gt;/"]):::artifact
    MERGE --> DOMD(["directories/&lt;domain&gt;/"]):::artifact
```

> **Not automated in `swarmrecon.sh`** — step 11 always records a *skip* row.
> When (and how hard) to brute-force stays an explicit, deliberate decision.

### 1. Three ways to run it

| Mode | Command | What happens |
|------|---------|--------------|
| Interactive | `./bruteforce/dir-bruteforce.sh` | prompts `Target URL:` → `Wordlist path:` (bare names resolve under `wordlists/`), then scans the **whole list — no budget cap** |
| Single host | `./bruteforce/dir-bruteforce.sh --url <url> --wordlist <path>` | scripted; `--wordlist` is repeatable and **required** — there are no built-in lists |
| Batch plan | `./bruteforce/dir-bruteforce.sh --plan <scan.json> --wordlist <path>` | walks `plans[]` (host · intent · profile · confidence) and skips entries with confidence < 0.5 |

```bash
./bruteforce/dir-bruteforce.sh
# Target URL: https://example.com
# Wordlist path: raft-medium-directories.txt   (bare name -> wordlists/, or a full path)
```

### 2. How a scan runs

1. **Pre-flight** — `getent` DNS check + one HTTP probe; NXDOMAIN or unreachable hosts are skipped **before any request budget is spent**.
2. **WAF fingerprint** — one root-page probe: body signatures for DataDome, Cloudflare, Akamai and AWS WAF, with a 403/503 status fallback. The verdict arms the WAF-wall stop condition.
3. **robots.txt / sitemap harvest** — cheap fetch of 5 doc paths into `evidence/robots.txt` before fuzzing starts.
4. **Budgeted ffuf loop** — one pass per wordlist:
   - a clean temp copy is built per list: comments/blanks stripped, leading `/` removed (no `//FUZZ`), truncated to the remaining budget;
   - `ffuf -u <host>/FUZZ -ac -mc 200-299,301,302,401,403,405,429,500,502,503 -of json` under `timeout --foreground`, with rate + thread flags;
   - every `429` is counted for the stop condition but never stored as a finding.
5. **Extension scan** — only with `--profile deep` + `--ext-profile php|java|dotnet|generic`: a second ffuf pass with `-e .php,.bak,…` against `raft-medium-files.txt`, sharing the same budget.
6. **Evidence write** — `scan-meta.json` (budget used, `stopped_reason`, WAF verdict), merged `results.json`, per-status `entries.json` (JSONL — one object per line).
7. **Report generation** — the false-positive kill layer below, then regex classification into critical / interesting reports.

### 3. Stop conditions & budgets

| Guard | Trigger | Effect |
|-------|---------|--------|
| Request budget | `light` 5 000 · `standard` 50 000 · `deep` 150 000 · interactive = full wordlist (uncapped) | loop stops → `stopped_reason: budget_exhausted` |
| Rate-limit brake | >30% of all responses are `429` | immediate stop → `rate_limited` |
| WAF wall | WAF suspected **and** 2+ consecutive wordlists return 0 hits with 0×429 (everything hitting one challenge page) | stop → `waf_blocked` |
| Per-ffuf timeout | `entries × 3 / req-per-sec + 300` seconds via `timeout --foreground` | a hung ffuf can never stall the run |
| Ctrl+C | INT → TERM → KILL escalation across the process group | clean teardown, exit 130 |
| Fresh-run hygiene | `--force` wipes evidence; `entries.json` reset before write; `rm -f` before each ffuf output | stale results can never pass as fresh |

### 4. False-positive detection & killing

Directory bruteforce is drowned in fake hits: SPA soft-shells answer **200 for
any path** (including `/.git/`), and WAFs answer one identical block page for
every flagged path. The report stage runs a kill layer with three mechanisms,
plus two upstream filters:

1. **Random control probe** — per host, the classifier fetches
   `<base>/fp-control-<random-hex>/`, a path that cannot exist. Any finding
   whose `[status, length]` matches the control within tolerance (±64 B for
   small pages, `max(256 B, 2%)` for larger ones) is dropped → `fp_dropped_control`.
2. **Identical-signature clustering** — findings are bucketed per host by
   `(status, words, lines, length)` (length bucketed per 100 KB above 50 KB,
   because nonces make big shells vary byte-to-byte). A signature seen **≥5×**
   is a canned response and is dropped, with a forensic split:
   - sensitive path (`.git/` `.env` `.svn/` `.aws/` `id_rsa` `web.config` …)
     **or** `403 + ≥50 KB` → counted as **waf-block-page** (one big block page
     served to every flagged path);
   - anything else → **shell-signature** (SPA catch-all).
3. **429 separation** — rate-limited responses are counted only for the stop
   condition and **never enter the result set** (429 ≠ finding).

Upstream, feeding the same goal:

- **ffuf `-ac` auto-calibration** — measures a random-path baseline and discards
  same-size soft-404 responses *before* they reach the evidence files.
- **Exact-URL dedup** — duplicates are dropped during classification.

What survives is classified by regex:

| Class | Example patterns |
|-------|------------------|
| **Critical** | `\.git/` `\.env` `heapdump` `dump.sql` `database.sql` `web.config` `id_rsa` `\.aws/credentials` `\.svn/` `phpinfo.php` |
| **Interesting** | `/admin` `/graphql` `/swagger` `/actuator` `/oauth/` `/login` `/wp-admin` `/api/` `/console` `\.well-known` `/signup` `/forgot-password` |

All drop counts land in `results-summary.md`:

```
- FP dropped (control-match):   N
- FP dropped (waf-block-page):  N
- FP dropped (shell-signature): N
```

### 5. Output layout

```
directories/
└── <host>/
    ├── evidence/
    │   ├── scan-meta.json          # run_id · budget · stopped_reason · WAF verdict
    │   ├── results.json            # merged hits (429s excluded)
    │   ├── robots.txt              # harvested doc paths
    │   ├── ffuf-<wordlist>.json    # raw ffuf output per wordlist
    │   └── <status>/entries.json   # JSONL per status code (200/ 403/ …)
    ├── critical-exposure.txt
    ├── interesting-surface.txt
    └── results-summary.md          # totals + FP-drop counts + findings
```

`--target <domain>` merges the three report files of every scanned host into
`directories/<domain>/` with `# source: <host>` separators; add
`--fresh-aggregate` to truncate that root once at the start of a batch.

### Flags

| Flag | Meaning |
|------|---------|
| `--wordlist <path>` | wordlist file — repeatable, **required** outside interactive mode (bare names resolve under `wordlists/`) |
| `--profile <name>` | `light` 5 000 / `standard` 50 000 / `deep` 150 000 request budget (interactive runs uncapped) |
| `--ext-profile <name>` | `php` `java` `dotnet` `generic` — extension list for the deep-profile second pass |
| `--threads <n>` | ffuf concurrency (default 500) |
| `--rate <ms>` | inter-request delay (default 2 ms ≈ 500 req/s) |
| `--target <domain>` | aggregate reports into `directories/<domain>/` |
| `--plan <file>` | batch mode: every host in a JSON scan plan |
| `--dry-run` | print host, budget, wordlist sizes and output path — scan nothing |
| `--force` | wipe existing evidence first |
| `--report-only` | re-run the classifier on existing evidence — no ffuf, no `--wordlist` needed |
| `--fresh-aggregate` | truncate the `--target` aggregate files once before a batch |

---

## Engagement Flow

Every `swarmrecon.sh` run walks the same 14-step pipeline into `recon/<domain>/`,
and every raw tool line lands in `recon.log`. The flow is fail-soft by design:
each step reports **ok / skip / fail** into the summary table instead of stopping
the run, so the script always finishes and exits `0`. Numbered dirs hold raw
per-step output; the root holds the final artifacts. After step 5, port
discovery → service brute-forcing exists only as a deliberate manual extension
(see [the guide](#port-discovery--service-brute-forcing-manual)); step 11
(directory bruteforce) is likewise never run — it always records a *skip* row
and hands off to `./bruteforce/dir-bruteforce.sh`
(see [Directory Bruteforce](#directory-bruteforce-manual)).

```mermaid
flowchart TD
    classDef entry fill:#1e1b4b,stroke:#818cf8,stroke-width:2px,color:#e0e7ff
    classDef phase fill:#0f172a,stroke:#38bdf8,stroke-width:1.5px,color:#e2e8f0
    classDef decision fill:#451a03,stroke:#f59e0b,stroke-width:2px,color:#fde68a
    classDef manual fill:#042f2e,stroke:#2dd4bf,stroke-width:1.5px,color:#ccfbf1
    classDef merge fill:#172554,stroke:#60a5fa,stroke-width:2px,color:#dbeafe

    SETUP(["one-time setup — idempotent<br/>./install.sh · ./gf-scripts/sync-gf-patterns.sh<br/>tools + 125 patterns into ~/.gf"]):::manual --> Start
    Start(["./swarmrecon.sh -d example.com"]):::entry --> S1

    S1["1 · WAPPALYZER — tech fingerprint<br/>→ 01-wappalyzer/"]:::phase --> S2
    S2["2 · DNS + WHOIS — dig · whois · nslookup<br/>→ 02-dns-whois/"]:::phase --> S3
    S3["3 · PASSIVE INTEL — whois · msftrecon · Scopify<br/>Spoofy · cloud_enum → 03-intel/"]:::phase --> S4
    S4["4 · OSINT — theHarvester: subdomains + emails<br/>→ 04-osint/"]:::phase --> S5
    S5["5 · NMAP — single-pass port scan<br/>→ 05-nmap/"]:::phase --> PortDec

    PortDec{"deeper port work<br/>wanted?"}:::decision
    PortDec -->|"yes — optional, manual"| Manual["masscan / dnmasscan → nmap -sV → brutespray<br/>deliberate authorization required — guide above"]:::manual
    Manual --> S6
    PortDec -->|"no"| S6

    S6["6 · CT LOGS — ctfr: crt.sh + liveness probe<br/>→ 06-ctfr/ · live list feeds step 7"]:::phase --> S7
    S7["7 · SUBENUM — multi-source gather + resolve<br/>merges the live CT output<br/>final at recon root: https-subs.txt + alive-domains.txt<br/>staging subdomains/ — removed at step end"]:::phase --> S8
    S8["8 · DNS BRUTEFORCE — puredns + massdns<br/>→ 08-puredns/"]:::phase --> S9
    S9["9 · VHOST FUZZ — Host-header discovery<br/>→ 09-vhost/"]:::phase --> S10
    S10["10 · ZONE TRANSFER — AXFR per NS<br/>→ 10-zone-transfer/"]:::phase --> S11
    S11["11 · DIRECTORY BRUTEFORCE — manual<br/>pipeline records a skip — ./bruteforce/dir-bruteforce.sh<br/>→ directories/&lt;host&gt;/"]:::manual --> S12
    S12["12 · ROBOTS / SITEMAP — curl<br/>→ 12-robots-sitemap/"]:::phase --> M13
    M13["MERGE SOURCES — Steps 4/8/9/12<br/>merge/merge-sources.sh → merge/merged-*.txt<br/>append → alive-domains.txt + https-subs.txt<br/>delete merged files"]:::merge --> S13
    S13["13 · WEB CRAWL — starts after the merge<br/>waymore · gau · hakrawler · katana · gospider<br/>finals: 7 crawl files<br/>check/ — filter.sh + gf-scripts/gf-extract.sh · gooutput/"]:::phase --> M14
    M14["MERGE AGAIN — idempotent<br/>regenerate + sort -u append<br/>covers a skipped/failed Step 13"]:::merge --> S14
    S14["14 · HIGH-VALUE — ffuf secrets · admin · backups<br/>root files + alive-domains.txt (incl. merged hosts)<br/>→ 14-high-value/"]:::phase --> Sum

    Sum(["summary table — ok / skip / fail per step<br/>failed steps point at recon.log · exit 0"]):::entry
```

**Key properties of this flow:**

- **Fail-soft is the contract.** A missing tool prints the exact install hint (`./install.sh` / `go install …`) and records a *skip*; a failed step records *fail* + points at `recon.log`; neither stops the run — the summary table always prints and the script exits `0`.
- **Root = final, numbered dirs = raw.** Only step 7's `https-subs.txt` + `alive-domains.txt` and step 13's seven crawl files are final; `01-…` through `14-high-value/` and `gooutput/` are raw material. `subdomains/` is step-7 staging only — step 7 `rmdir`s it at the end (when empty), so it never lingers. `merge/` is transient too: it exists only between the merge and the append-and-delete step.
- **No orphaned candidates.** Step 4/8/9/12 outputs are merged into the two root lists at the start of Steps 13 and 14. The merge is scope-filtered, deduped, and rerun-safe, so later steps see the full candidate set without duplicate entries.
- **Merge process is append-and-delete.** `merge/merge-sources.sh` writes `merge/merged-alive-domains.txt` + `merge/merged-https-subs.txt`; `_append_unique` appends each to its root list with `sort -u`, then deletes the merged source. Step 14 regenerates and re-appends the same candidates, which dedupes to a no-op.
- **Step 13 never dies wholesale.** Each crawl tool, `filter.sh`, and `gf-scripts/gf-extract.sh` runs as an independent sub-step — one missing tool skips its slice only. `check/` holds the filter classification (`crawledurls` · `param-urls` · `httpx-raw` · `api-candidates` · `idor-candidates` · `api-param-candidates` · `idor-param-candidates`) plus `gf/gf-*.txt` pattern classes; `gooutput/` holds gospider raw + extracturls intermediates.
- **The manual branch stays manual.** masscan/nmap/brutespray needs interactive `sudo` and an explicit credential-guessing decision, so it's a deliberate side path off step 5 — never automated in the script.
- **Step 11 stays manual too.** Directory bruteforce is outside the pipeline — the run finishes with a *skip* row and a pointer to `./bruteforce/dir-bruteforce.sh`, which prompts for URL + wordlist and writes `directories/<host>/`. Choosing when (and how hard) to brute-force stays an explicit decision.
- **Setup is one-time, not per-run.** `./install.sh` is idempotent and `./gf-scripts/sync-gf-patterns.sh` fills `~/.gf` once; re-runs skip what already exists.

---

## Helper scripts

Standalone helper scripts: Steps 13/14 invoke `merge/merge-sources.sh`, Step 13
invokes `extracturls.sh`, `filter.sh`, and `gf-scripts/gf-extract.sh` automatically,
`install.sh` runs `gf-scripts/sync-gf-patterns.sh`, and
`bruteforce/dir-bruteforce.sh` runs only when you invoke it (step 11 is manual):

| Script | Usage | Notes |
|--------|-------|-------|
| `extracturls.sh` | `./extracturls.sh -f <gospider_folder> -d <domain>` | Extracts + liveness-probes subdomains from crawler output. Requires `dnsx` + `httpx`. |
| `filter.sh` | `echo <domain> \| ./filter.sh [input]` | Interactive domain prompt (fed via stdin). Defaults to `merged-crawl.txt` in CWD; writes 7 files to `check/` (6 classification + `httpx-raw`). Keeps WAF/403/401 alive, drops 404s/errors; strips fragments + tracking params; classifies API/IDOR candidates. |
| `gf-scripts/gf-extract.sh` | `./gf-scripts/gf-extract.sh [input_file] [out_dir]` | Defaults: `check/param-urls.txt` → `check/gf/`. `$1` must be a **file** (not a directory). Only patterns with hits produce files; patterns whose `_` → `-` sanitized names collide are skipped with a warning. |
| `merge/merge-sources.sh` | `./merge/merge-sources.sh -d <domain> [-o <outdir>]` | Builds `merge/merged-alive-domains.txt` + `merge/merged-https-subs.txt` from Step 4/8/9/12 outputs. Called automatically at the start of Steps 13 and 14; safe to run standalone. |
| `gf-scripts/sync-gf-patterns.sh` | `./gf-scripts/sync-gf-patterns.sh` | Copies `gf-patterns/*.json` → `~/.gf` (skips identical, index excluded, prunes **only this repo's** previously-synced files — ownership-aware for shared `~/.gf`). Called by `install.sh`; run standalone after editing patterns. |
| `bruteforce/dir-bruteforce.sh` | `./bruteforce/dir-bruteforce.sh` (interactive) · `./bruteforce/dir-bruteforce.sh --url <url> --wordlist <path>` | ffuf path discovery — **never auto-run** by the pipeline (step 11 = *skip*). Profiles `--profile light\|standard\|deep` + `--ext-profile`, plus `--plan <scan.json>`, `--dry-run`, `--force`, `--report-only`, `--target <domain>` (merges hosts under `directories/<domain>/`; `--fresh-aggregate` truncates it first). Output: `directories/<host>/` (evidence + reports). |

---

## Wordlists & patterns

| File | Used by |
|------|---------|
| `subdomains-top1million-20000.txt` | step 8 — puredns bruteforce |
| `resolvers.txt` | step 8 — puredns resolvers |
| `common.txt` | step 9 — vhost fuzzing |
| `raft-medium-directories.txt` · `raft-medium-files.txt` · `big.txt` … (any file you choose) | step 11 (manual) — `./bruteforce/dir-bruteforce.sh` takes a bare name (resolved under `wordlists/`) at the `Wordlist path:` prompt or via `--wordlist <path>`; no built-in default |
| `high-value-paths.txt` | step 14 — secrets/disclosure/juicy files (`#`-marked sections are stripped at runtime), fuzzed against root + `alive-domains.txt` hosts |

### `gf-patterns/` (127 files)

Git-tracked source of truth for `gf(1)` patterns (125 real patterns +
`category-index.json` index + this README = 127 files). `gf` itself only
reads `~/.gf`, so:

- `./install.sh` → runs `./gf-scripts/sync-gf-patterns.sh`: **copies missing/changed
  patterns** into `~/.gf/` (identical files are skipped untouched — safe to
  re-run), skips `category-index.json` (index), and prunes **only files this
  repo previously synced** (tracked in `~/.gf/.swarmrecon-manifest`) that are
  no longer shipped. `~/.gf` is shared with openswarm — its patterns
  (`clickjacking`, `soap`, …) and user files are never touched. Repo stays
  the source of truth.
- Rerun standalone anytime: `./gf-scripts/sync-gf-patterns.sh` then `gf -list` to verify.

---

## Design notes

- **Fail-soft**: guards check every tool before running; results land in the summary
  table instead of exiting. The script exits `0` after printing it regardless of
  individual step results.
- **Fresh-run hygiene**: by the time a step's tools run it has cleared or
  truncated every file it owns (up-front `rm` / `: >`, or write-time `>`), so a
  failed run can never pass off stale results as new. Outputs that feed later
  steps (ctfr, subenum, crawl + merged files) are cleared *before their guards*,
  so even a skipped re-run can't leak old data into a later merge.
- **Exit-code semantics**: steps built from informational commands (DNS queries
  that legitimately return NXDOMAIN, `curl` of possibly-absent files) are judged by
  *output existence*, not raw exit codes — that's why some blocks are written as
  `{ cmd1; cmd2; }` rather than `&&` chains.
- **No runtime installs**: `swarmrecon.sh` never installs anything — missing tools
  are reported with the exact command needed to install them.
- **Idempotent installer**: `install.sh` checks every component first and skips
  what's already installed (markers for ctfr/subenum; `command -v` for tools);
  the GF sync copies only missing/changed patterns and prunes stale ones —
  safe to re-run any time.
