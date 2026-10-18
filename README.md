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

**Quick links:** [What is this?](#what-is-this) · [Quick Install](#quick-install) · [Usage](#usage) · [Pipeline](#pipeline-14-steps) · [Port discovery → brute-force](#port-discovery--service-brute-forcing-manual) · [Directory bruteforce](#directory-bruteforce-manual) · [Engagement Flow](#engagement-flow) · [Wordlists & patterns](#wordlists--patterns) · [Design notes](#design-notes)

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
- **Step 11 (directory bruteforce) is manual** — the pipeline records a *skip*
  row and prints a pointer; run `./dir-bruteforce.sh` yourself when you want
  path discovery (see [Directory Bruteforce](#directory-bruteforce-manual)).

---

## Pipeline (14 steps)

| # | Step | Tool(s) | Output |
|---|------|---------|--------|
| 1 | Technology discovery | `wappalyzer` (Playwright/Chromium) | `01-wappalyzer/technologies.json` |
| 2 | DNS + WHOIS | `dig`, `whois`, `nslookup` | `02-dns-whois/` — 13 files: A/AAAA/NS/MX/TXT/CAA/SOA/DMARC, Google/Cloudflare resolvers, nslookup, whois per domain + per resolved IP |
| 3 | Passive intel | `whois` + `msftrecon`, `Scopify`, `Spoofy`, `cloud_enum` (auto-venv) | `03-intel/` — `domain_info_general.txt`, `azure_tenant_domains.txt`, `scopify.txt`, `spoof.txt`, `cloud_enum.txt` |
| 4 | OSINT — subdomains + emails | `theHarvester` (2 source sets) | `04-osint/` — `theharvester_subdomains.json`, `theharvester_emails.json`, `subdomains.txt`, `emails.txt` |
| 5 | Port scan (single pass) | `nmap` | `05-nmap/` — `nmap-full.txt` (`-Pn --open -sV -T4 --top-ports 1000 --min-rate 500`) |
| 6 | Certificate Transparency | `ctfr` (auto-venv) + `httpx` | `06-ctfr/` — `ctfr-subdomains.txt`, `live-ctfr-subdomains.txt` (live-probed) |
| 7 | Subdomain enumeration | `subenum` + CT merge | root **`https-subs.txt`**, **`alive-domains.txt`** |
| 8 | DNS bruteforce | `puredns` + `massdns` | `08-puredns/puredns-subdomains.txt` |
| 9 | Vhost fuzzing | `ffuf` (2 passes vs. dynamic baseline) | `09-vhost/` — `vhost-baseline.txt`, `vhost-mc-all.json`, `vhost-no403.json` |
| 10 | Zone transfer (AXFR) | `nslookup`, `dig axfr` per NS | `10-zone-transfer/` — `nslookup-NS.txt`, `axfr-<ns>.txt` |
| 11 | Directory bruteforce | *manual* | not automated — run `./dir-bruteforce.sh` (interactive prompts: target URL → wordlist path) → `directories/<host>/` |
| 12 | Public files | `curl` | `12-robots-sitemap/` — `robots.txt`, `security.txt`, 7 sitemap path variants |
| 13 | Web crawling (10 sub-steps) | `waymore`, `gau`, `uro`, `hakrawler`, `katana`, `gospider`, `httpx`, `filter.sh`, `gf` | root crawl files + `gooutput/` + `check/` (+ `check/gf/`) |
| 14 | High-value paths | `ffuf` (auto-calibrated) — sources: `https://<domain>` + each host in `alive-domains.txt` | `14-high-value/` — `high-value-results.json` (merged), `high-value-results.txt`, `high-value-<host>.json` |

> **After step 5:** an optional manual extension — masscan → nmap `-sV` →
> brutespray, see [Port Discovery & Service Brute-Forcing](#port-discovery--service-brute-forcing-manual)
> (not automated: an explicit credential-guessing decision).

> **Step 11 is manual** — `swarmrecon.sh` only records a *skip* row; directory
> bruteforce runs when you invoke `./dir-bruteforce.sh` yourself.
> Full guide: [Directory Bruteforce (manual)](#directory-bruteforce-manual).

### Step 13 in detail

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

## Port Discovery & Service Brute-Forcing (manual)

Optional workflow that extends **step 5** — it covers the complete pipeline from
fast port discovery to service-aware credential guessing using
**masscan / dnmasscan → nmap → brutespray**:

```mermaid
flowchart LR
    A["raw IPs<br/>($ipFile)"] -->|"masscan"| O["grepable port results<br/>(masscan.log)"]
    B["alive-domains.txt<br/>(step 7)"] -->|"dnmasscan"| O
    O -->|"nmap -sV"| G["nmap-scan.gnmap"]
    G -->|"brutespray"| S["default-credential<br/>checks"]
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
brutespray -f nmap.gnmap -o scan-results
```

⚠️ Only against systems you own or have **explicit authorization** to test.

---

## Directory Bruteforce (manual)

Optional workflow that **step 11** hands off to — `swarmrecon.sh` never runs it,
it only records a *skip* row in the summary. `./dir-bruteforce.sh` is a
standalone ffuf driver: preflight → WAF fingerprint → robots harvest →
budgeted ffuf loop → false-positive kill layer → classified reports, all under
`directories/<host>/` at the repo root.

```mermaid
flowchart TD
    classDef phase fill:#cce5ff,stroke:#333,stroke-width:2px,color:#000
    classDef decision fill:#ffe5cc,stroke:#333,stroke-width:2px,color:#000
    classDef terminal fill:#e6ccff,stroke:#333,stroke-width:2px,color:#000
    classDef manual fill:#e0f2f1,stroke:#333,stroke-width:2px,color:#000

    Start(["./dir-bruteforce.sh<br/>interactive · --url · --plan"]):::terminal --> Pre
    Pre{"preflight<br/>DNS + HTTP probe"}:::decision
    Pre -->|"dead host"| Skip["skip —<br/>no budget spent"]:::manual
    Pre -->|"ok"| WAF["WAF fingerprint<br/>DataDome · Cloudflare · Akamai · AWS"]:::phase
    WAF --> Robots["robots.txt / sitemap<br/>harvest"]:::phase
    Robots --> Loop["ffuf per wordlist<br/>-ac · clean temp wl · rate · threads"]:::phase
    Loop --> Stop{"stop condition"}:::decision
    Stop -->|"more wordlists"| Loop
    Loop -->|"wordlists done"| Ext["extension scan<br/>deep + --ext-profile"]:::phase
    Stop -->|"budget · 429>30% · WAF wall"| Ev
    Ext --> Ev["evidence/<br/>scan-meta · results · per-status"]:::phase
    Ev --> FP["false-positive kill layer<br/>control probe · signature clusters · 429 split"]:::phase
    FP --> Rep["critical-exposure.txt<br/>interesting-surface.txt<br/>results-summary.md"]:::phase
    Rep --> Out(["directories/&lt;host&gt;/"]):::terminal
```

> **Not automated in `swarmrecon.sh`** — step 11 always records a *skip* row.
> When (and how hard) to brute-force stays an explicit, deliberate decision.

### 1. Three ways to run it

| Mode | Command | What happens |
|------|---------|--------------|
| Interactive | `./dir-bruteforce.sh` | prompts `Target URL:` → `Wordlist path:` (bare names resolve under `wordlists/`), then scans the **whole list — no budget cap** |
| Single host | `./dir-bruteforce.sh --url <url> --wordlist <path>` | scripted; `--wordlist` is repeatable and **required** — there are no built-in lists |
| Batch plan | `./dir-bruteforce.sh --plan <scan.json> --wordlist <path>` | walks `plans[]` (host · intent · profile · confidence) and skips entries with confidence < 0.5 |

```bash
./dir-bruteforce.sh
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
and hands off to `./dir-bruteforce.sh`
(see [Directory Bruteforce](#directory-bruteforce-manual)).

```mermaid
flowchart TD
    classDef phase fill:#cce5ff,stroke:#333,stroke-width:2px,color:#000
    classDef gate fill:#ffcccc,stroke:#333,stroke-width:2px,color:#000
    classDef decision fill:#ffe5cc,stroke:#333,stroke-width:2px,color:#000
    classDef terminal fill:#e6ccff,stroke:#333,stroke-width:2px,color:#000
    classDef manual fill:#e0f2f1,stroke:#333,stroke-width:2px,color:#000

    Start(["./swarmrecon.sh -d example.com"]):::terminal --> S1

    S1["1. WAPPALYZER<br/>tech fingerprint<br/>→ 01-wappalyzer/"]:::phase --> S2
    S2["2. DNS + WHOIS<br/>dig · whois · nslookup<br/>→ 02-dns-whois/"]:::phase --> S3

    S3["3. PASSIVE INTEL<br/>whois · msftrecon · Scopify · Spoofy · cloud_enum<br/>→ 03-intel/"]:::phase --> S4
    S4["4. OSINT (theHarvester)<br/>subdomains + emails<br/>→ 04-osint/"]:::phase --> S5

    S5["5. NMAP<br/>port scan · open services<br/>→ 05-nmap/"]:::phase --> PortDec

    PortDec{"Port discovery<br/>needed?"}:::decision
    PortDec -->|"yes (manual)"| Manual["masscan / dnmasscan<br/>→ nmap -sV → brutespray<br/>run by hand — guide below"]:::manual
    Manual --> S6
    PortDec -->|"no"| S6

    S6["6. CT LOGS (ctfr)<br/>crt.sh subs + liveness<br/>→ 06-ctfr/"]:::phase --> S7
    S7["7. SUBENUM<br/>multi-source gather + resolve<br/>final: https-subs.txt<br/>final: alive-domains.txt<br/>staging → subdomains/"]:::phase --> S8
    S8["8. DNS BRUTEFORCE<br/>puredns + massdns<br/>→ 08-puredns/"]:::phase --> S9
    S9["9. VHOST FUZZING<br/>Host-header discovery<br/>→ 09-vhost/"]:::phase --> S10
    S10["10. ZONE TRANSFER<br/>axfr against NS list<br/>→ 10-zone-transfer/"]:::phase --> S11
    S11["11. DIRECTORY BRUTEFORCE<br/>manual — not run by pipeline<br/>./dir-bruteforce.sh → directories/"]:::manual --> S12
    S12["12. ROBOTS / SITEMAP<br/>waymore · curl<br/>→ 12-robots-sitemap/"]:::phase --> S13

    S13["13. WEB CRAWL<br/>waymore · gau · hakrawler · katana<br/>final: wayurls.txt · gauurls.txt · waygauurls.txt<br/>final: hakcrawlurls.txt · cleansubskatanaurls.txt<br/>final: alivesubsurls.txt · merged-crawl.txt<br/>→ check/ (filter + gf) · gooutput/"]:::phase --> S14

    S14["14. HIGH-VALUE<br/>secrets · admin · backups<br/>root + alive-domains.txt<br/>→ 14-high-value/"]:::phase --> Summary

    Summary(["Summary table<br/>recon.log · exit 0"]):::terminal
```

**Key properties of this flow:**

- **Fail-soft is the contract.** A missing tool prints the exact install hint (`./install.sh` / `go install …`) and records a *skip*; a failed step records *fail* + points at `recon.log`; neither stops the run — the summary table always prints and the script exits `0`.
- **Root = final, numbered dirs = raw.** Only step 7's `https-subs.txt` + `alive-domains.txt` and step 13's seven crawl files are final; `01-…` through `14-high-value/` and `gooutput/` are raw material. `subdomains/` is step-7 staging and ends empty after the merge.
- **Step 13 never dies wholesale.** Each crawl tool, `filter.sh`, and `gf-extract.sh` runs as an independent sub-step — one missing tool skips its slice only. `check/` holds the filter classification (`crawledurls` · `param-urls` · `httpx-raw` · `api-candidates` · `idor-candidates` · `api-param-candidates` · `idor-param-candidates`) plus `gf/gf-*.txt` pattern classes; `gooutput/` holds gospider raw + extracturls intermediates.
- **The manual branch stays manual.** masscan/nmap/brutespray needs interactive `sudo` and an explicit credential-guessing decision, so it's a deliberate side path off step 5 — never automated in the script.
- **Step 11 stays manual too.** Directory bruteforce is outside the pipeline — the run finishes with a *skip* row and a pointer to `./dir-bruteforce.sh`, which prompts for URL + wordlist and writes `directories/<host>/`. Choosing when (and how hard) to brute-force stays an explicit decision.
- **Setup is one-time, not per-run.** `./install.sh` is idempotent and `./sync-gf-patterns.sh` fills `~/.gf` once; re-runs skip what already exists.

---

## Helper scripts

Standalone helper scripts: step 13 invokes the first three automatically,
`install.sh` runs `sync-gf-patterns.sh`, and `dir-bruteforce.sh` runs only
when you invoke it (step 11 is manual):

| Script | Usage | Notes |
|--------|-------|-------|
| `extracturls.sh` | `./extracturls.sh -f <gospider_folder> -d <domain>` | Extracts + liveness-probes subdomains from crawler output. Requires `dnsx` + `httpx`. |
| `filter.sh` | `echo <domain> \| ./filter.sh [input]` | Interactive domain prompt (fed via stdin). Defaults to `merged-crawl.txt` in CWD; writes 6 category files to `check/`. Keeps WAF/403/401 alive, drops 404s/errors; strips fragments + tracking params; classifies API/IDOR candidates. |
| `gf-extract.sh` | `./gf-extract.sh [input_file] [out_dir]` | Defaults: `check/param-urls.txt` → `check/gf/`. `$1` must be a **file** (not a directory). Only patterns with hits produce files. |
| `sync-gf-patterns.sh` | `./sync-gf-patterns.sh` | Copies `gf-patterns/*.json` → `~/.gf` (skips identical, manifest excluded, prunes stale). Called by `install.sh`; run standalone after editing patterns. |
| `dir-bruteforce.sh` | `./dir-bruteforce.sh` (interactive) · `./dir-bruteforce.sh --url <url> --wordlist <path>` | ffuf path discovery — **never auto-run** by the pipeline (step 11 = *skip*). Profiles `--profile light\|standard\|deep`, plus `--dry-run`, `--force`, `--report-only`, `--target <domain>` → merges hosts under `directories/<domain>/`. Output: `directories/<host>/` (evidence + reports). |

---

## Wordlists & patterns

| File | Used by |
|------|---------|
| `subdomains-top1million-20000.txt` | step 8 — puredns bruteforce |
| `resolvers.txt` | step 8 — puredns resolvers |
| `common.txt` | step 9 — vhost fuzzing |
| any file you choose (e.g. `raft-medium-directories.txt`) | step 11 (manual) — `./dir-bruteforce.sh` takes it at the `Wordlist path:` prompt or via `--wordlist <path>`; no built-in default |
| `high-value-paths.txt` | step 14 — secrets/disclosure/juicy files (`#`-marked sections), fuzzed against root + `alive-domains.txt` hosts |

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
- **Idempotent installer**: `install.sh` checks every component first and skips
  what's already installed (markers for ctfr/subenum; `command -v` for tools);
  the GF sync copies only missing/changed patterns and prunes stale ones —
  safe to re-run any time.
