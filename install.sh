#!/usr/bin/env bash
# install.sh — swarmrecon dependency setup
# Usage: ./install.sh [--gau-config-only]
# IDEMPOTENT — safe to re-run: every section CHECKS FIRST and skips whatever
# is already installed; only missing components get installed. Markers:
#   ~/ctfr/venv/.deps-ok      (ctfr requirements done)
#   ~/subenum/.install-done   (subenum's own install.sh done)
#   ~/LinkFinder/venv         (Step 15 local JS endpoint extraction)
# Intel/OSINT tools (steps 3-4) are existence-checked (.git / binary) too;
# uv is installed automatically when missing.
# Wordlists ship with the repo; GF patterns are synced into ~/.gf.
set -euo pipefail

GAU_CONFIG_ONLY=false
case "${1:-}" in
    "") ;;
    --gau-config-only) GAU_CONFIG_ONLY=true ;;
    *) echo "usage: $0 [--gau-config-only]" >&2; exit 1 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "usage: $0 [--gau-config-only]" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH"

echo "[*] swarmrecon — dependency setup"

# ================================================================
#  Ensure Go environment is set up correctly
# ================================================================
export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH"

# Ensure GOPATH/bin is in PATH persistently
if [[ ":$PATH:" != *":$HOME/go/bin:"* ]]; then
    echo 'export PATH="$PATH:$HOME/go/bin"' >> ~/.bashrc
    export PATH="$PATH:$HOME/go/bin"
fi

# Ensure GO111MODULE=on for all Go installs
export GO111MODULE=on

# ================================================================
#  gau — Step 13 archive URL provider config
#  Written early so an interrupted/failed optional install cannot skip it.
#  Create-only: an existing ~/.gau.toml is never overwritten.
# ================================================================
GAU_CONFIG="$HOME/.gau.toml"
write_gau_config() {
    if [ -f "$GAU_CONFIG" ]; then
        echo "[+] gau config: already present — leaving it unchanged (${GAU_CONFIG})"
        return 0
    fi
    if cat > "$GAU_CONFIG" <<'GAU_CONFIG_EOF'
threads = 20
verbose = false
retries = 5
subdomains = true
parameters = false
providers = ["wayback","commoncrawl","otx","urlscan"]
blacklist = ["ttf","woff","svg","png","jpg","gif","ico","css","pdf","mp4","mp3"]
json = false

[urlscan]
  apikey = ""

[filters]
  from = ""
  to = ""
  matchstatuscodes = []
  matchmimetypes = []
  filterstatuscodes = []
  filtermimetypes = ["image/png","image/jpg","image/svg+xml","image/gif"]
GAU_CONFIG_EOF
    then
        echo "[+] gau config: written (${GAU_CONFIG})"
        return 0
    fi
    echo "[!] gau config: could not write ${GAU_CONFIG} — Step 13 gau may use defaults"
    return 1
}

if ! write_gau_config; then
    if $GAU_CONFIG_ONLY; then
        exit 1
    fi
fi

if $GAU_CONFIG_ONLY; then
    echo "[+] gau config ready."
    exit 0
fi

# ---- sudo capability (openswarm pattern) ----
HAS_PASSWORDLESS_SUDO=false
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    HAS_PASSWORDLESS_SUDO=true
fi

# ---- core prerequisites ----
PREREQ=0
for cmd in python3 git curl; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "[+] $cmd: present"
    else
        echo "[-] $cmd: MISSING"
        PREREQ=1
    fi
done
if [ "$PREREQ" -ne 0 ]; then
    echo "[!] install core prerequisites first: sudo apt install python3 git curl"
    exit 1
fi

# ================================================================
#  pipx — installer for wappalyzer (auto-install if missing)
# ================================================================
if command -v pipx >/dev/null 2>&1; then
    echo "[+] pipx: already installed"
else
    echo "[*] pipx not found — installing..."
    if [ "$HAS_PASSWORDLESS_SUDO" = true ]; then
        sudo apt-get install -y -qq pipx >/dev/null 2>&1 || true
    fi
    if ! command -v pipx >/dev/null 2>&1; then
        python3 -m pip install --user pipx >/dev/null 2>&1 || true
    fi
    export PATH="$HOME/.local/bin:$PATH"
    if command -v pipx >/dev/null 2>&1; then
        echo "[+] pipx: installed"
    else
        echo "[!] pipx install FAILED — manual: sudo apt install pipx (wappalyzer step will skip)"
    fi
fi

# ================================================================
#  wappalyzer — technology discovery (Step 1)
# ================================================================
if command -v wappalyzer >/dev/null 2>&1; then
    echo "[+] wappalyzer: already installed"
elif command -v pipx >/dev/null 2>&1; then
    echo "[*] installing wappalyzer (pipx)..."
    if pipx install wappalyzer >/dev/null 2>&1; then
        export PATH="$HOME/.local/bin:$PATH"
        if command -v wappalyzer >/dev/null 2>&1; then
            echo "[+] wappalyzer: installed"
        else
            echo "[!] wappalyzer installed but not on PATH — add: export PATH=\"\$HOME/.local/bin:\$PATH\""
        fi
    else
        echo "[!] wappalyzer install FAILED (Step 1 will skip) — manual: pipx install wappalyzer"
    fi
else
    echo "[!] pipx unavailable — skipping wappalyzer (Step 1 will skip) — manual: pipx install wappalyzer"
fi

# ---- Chromium for Playwright (wappalyzer backend) ----
# Caveat: a STALE chromium build looks installed but breaks at runtime —
# force a re-download with: rm -rf ~/.cache/ms-playwright
if compgen -G "$HOME/.cache/ms-playwright/chromium-*" >/dev/null 2>&1; then
    echo "[+] Playwright Chromium: already present (force refresh: rm -rf ~/.cache/ms-playwright)"
else
    echo "[*] installing Playwright Chromium (may download a browser)..."
    if pipx run --spec playwright playwright install chromium; then
        echo "[+] Playwright Chromium: installed"
    else
        echo "[!] Chromium install FAILED — manual: pipx run --spec playwright playwright install chromium"
    fi
fi

# ================================================================
#  ctfr — Certificate Transparency logs (Step 6)
#  Lives in $HOME/ctfr with its own venv (system pip is PEP-668 managed,
#  so plain `pip3 install -r requirements.txt` fails → venv required).
# ================================================================
CTFR_DIR="$HOME/ctfr"
CTFR_REPO="https://github.com/manojxshrestha/ctfr.git"
CTFR_MARKER="$CTFR_DIR/venv/.deps-ok"

echo "[*] ctfr → ${CTFR_DIR}"
if [ -f "$CTFR_MARKER" ] && [ -f "$CTFR_DIR/ctfr.py" ]; then
    echo "[+] ctfr: already installed (${CTFR_DIR}) — skipping"
else
    if ! command -v git >/dev/null 2>&1; then
        echo "[-] git not found — needed to clone ctfr (install git, re-run)"
        exit 1
    fi

    if [ ! -d "$CTFR_DIR" ]; then
        echo "[*] cloning ${CTFR_REPO}..."
        git clone "$CTFR_REPO" "$CTFR_DIR"
    fi

    if [ ! -f "$CTFR_DIR/venv/bin/activate" ]; then
        echo "[*] creating venv..."
        python3 -m venv "$CTFR_DIR/venv"
        echo "[*] installing ctfr requirements into venv..."
        "$CTFR_DIR/venv/bin/pip" install --quiet -r "$CTFR_DIR/requirements.txt"
        touch "$CTFR_MARKER"
    else
        # pre-existing venv (set up manually or by an older install) — trust it
        echo "[+] ctfr venv: already exists — skipping requirements install"
        touch "$CTFR_MARKER"
    fi

    if [ -f "$CTFR_DIR/ctfr.py" ]; then
        echo "[+] ctfr: ready (${CTFR_DIR})"
    else
        echo "[-] ctfr.py missing after install — check ${CTFR_DIR}"
        exit 1
    fi
fi

# ================================================================
#  puredns + massdns — fast DNS bruteforce with wildcard handling
# ================================================================
PUREDNS_BIN="$HOME/go/bin/puredns"

echo "[*] puredns"
if command -v puredns >/dev/null 2>&1 || [ -x "$PUREDNS_BIN" ]; then
    echo "[+] puredns: already installed ($(command -v puredns 2>/dev/null || printf '%s' "$PUREDNS_BIN"))"
else
    if ! command -v go >/dev/null 2>&1; then
        echo "[-] go not found — needed for puredns (install Go, re-run)"
        exit 1
    fi
    go install github.com/d3mondev/puredns/v2@latest
    if [ -x "$PUREDNS_BIN" ] || command -v puredns >/dev/null 2>&1; then
        echo "[+] puredns: installed"
        case ":$PATH:" in
            *":$HOME/go/bin:"*) ;;
            *) echo "[!] add to PATH: export PATH=\"\$HOME/go/bin:\$PATH\"" ;;
        esac
    else
        echo "[-] puredns: install FAILED"
        exit 1
    fi
fi

echo "[*] massdns"
if command -v massdns >/dev/null 2>&1; then
    echo "[+] massdns: already installed ($(command -v massdns))"
else
    MASSDNS_DIR="$HOME/massdns"
    if ! command -v git >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
        echo "[-] git/make not found — needed to build massdns (install, re-run)"
        exit 1
    fi
    if [ ! -d "$MASSDNS_DIR" ]; then
        git clone https://github.com/blechschmidt/massdns.git "$MASSDNS_DIR"
    fi
    make -C "$MASSDNS_DIR"
    sudo make -C "$MASSDNS_DIR" install || echo "[!] massdns: make install failed (sudo?) — continuing"
    if command -v massdns >/dev/null 2>&1; then
        echo "[+] massdns: installed"
    else
        echo "[-] massdns: install FAILED (not on PATH)"
        exit 1
    fi
fi

# ================================================================
#  subenum — user's own subdomain enumeration tool (manojxshrestha/subenum)
# ================================================================
SUBENUM_DIR="$HOME/subenum"
SUBENUM_REPO="https://github.com/manojxshrestha/subenum.git"

echo "[*] subenum → ${SUBENUM_DIR}"
SUBENUM_FRESH=0
if [ ! -d "$SUBENUM_DIR" ]; then
    if ! command -v git >/dev/null 2>&1; then
        echo "[-] git not found — needed to clone subenum (install git, re-run)"
        exit 1
    fi
    echo "[*] cloning ${SUBENUM_REPO}..."
    git clone "$SUBENUM_REPO" "$SUBENUM_DIR"
    SUBENUM_FRESH=1
fi

if [ ! -f "$SUBENUM_DIR/subenum.sh" ]; then
    echo "[-] subenum: subenum.sh missing in ${SUBENUM_DIR}"
    exit 1
fi

chmod +x "$SUBENUM_DIR/install.sh" "$SUBENUM_DIR/subenum.sh"

if [ "$SUBENUM_FRESH" -eq 1 ]; then
    echo "[*] fresh clone — running subenum's own install.sh..."
    ( cd "$SUBENUM_DIR" && ./install.sh )
    touch "$SUBENUM_DIR/.install-done"
    echo "[+] subenum: ready (${SUBENUM_DIR})"
elif [ -f "$SUBENUM_DIR/.install-done" ]; then
    echo "[+] subenum: already installed (${SUBENUM_DIR}) — skipping"
else
    # pre-existing clone from before markers — trust it, mark for next runs
    echo "[+] subenum: already present (${SUBENUM_DIR}) — skipping its install"
    echo "    (repair manually if needed: cd ${SUBENUM_DIR} && ./install.sh)"
    touch "$SUBENUM_DIR/.install-done"
fi

# ================================================================
#  unfurl — company-name extraction for Scopify / cloud_enum (step 3)
# ================================================================
echo "[*] unfurl"
if command -v unfurl >/dev/null 2>&1 || [ -x "$HOME/go/bin/unfurl" ]; then
    echo "[+] unfurl: already installed"
elif command -v go >/dev/null 2>&1; then
    GO111MODULE=on go install -v github.com/tomnomnom/unfurl@latest && \
       { command -v unfurl >/dev/null 2>&1 || [ -x "$HOME/go/bin/unfurl" ]; } && \
        echo "[+] unfurl: installed (~/go/bin/unfurl)" || \
        echo "[!] unfurl: install FAILED — Scopify will skip at step 3"
else
    echo "[-] unfurl: go not found — skipped (Scopify will skip at step 3)"
fi

# ================================================================
#  ProjectDiscovery httpx + dnsx (Steps 6/7/13)
#  python3-httpx (pip) ships the same binary name and rejects -threads, so a
#  Python CLI in /usr/bin shadows the PD binary and live probes silently
#  return 0 hosts. Keep the PD binary in ~/.local/bin, which both this script
#  and swarmrecon.sh prepend to PATH.
# ================================================================
TOOLS_BIN="$HOME/.local/bin"
mkdir -p "$TOOLS_BIN"

is_pd_httpx() {  # $1 = candidate binary
    local h
    h="$("$1" -h 2>&1 || true)"
    case "$h" in *"-threads"*) return 0 ;; esac
    return 1
}

echo "[*] ProjectDiscovery httpx"
# A real go-installed binary is preferred over a symlink to a copy elsewhere,
# so a fresh setup always has a reproducible, verifiable build. If
# ~/.local/bin/httpx is already the PD binary, skip.
if command -v httpx >/dev/null 2>&1 && is_pd_httpx "$(command -v httpx)"; then
    echo "[+] httpx: ProjectDiscovery already installed ($(command -v httpx))"
elif command -v go >/dev/null 2>&1; then
    echo "[*] go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest → ${TOOLS_BIN}..."
    rm -f "$TOOLS_BIN/httpx"   # drop a stale symlink/shim before installing
    if GOBIN="$TOOLS_BIN" GO111MODULE=on go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest; then
        echo "[+] httpx: installed (${TOOLS_BIN}/httpx)"
    else
        echo "[!] httpx: go install FAILED — Steps 6/7/13 live probes will be empty"
    fi
else
    echo "[-] go not found — cannot install httpx (install Go, re-run)"
fi

# Prove the binary is the ProjectDiscovery Go build (not python3-httpx).
if command -v httpx >/dev/null 2>&1 && is_pd_httpx "$(command -v httpx)"; then
    hx_module="$(go version -m "$(command -v httpx)" 2>/dev/null \
        | awk '$1=="path"{print $2; exit}' || true)"
    if [ "$hx_module" = "github.com/projectdiscovery/httpx/cmd/httpx" ] \
        && is_pd_httpx "$(command -v httpx)"; then
        echo "[+] httpx: verified Go build ($(httpx -version 2>&1 | awk '/Current Version/{print $NF; exit}' || true))"
    else
        echo "[!] httpx is NOT the ProjectDiscovery Go binary"
    fi
fi

echo "[*] dnsx"
DNSX_BIN="$(go env GOPATH 2>/dev/null || true)/bin/dnsx"
if command -v dnsx >/dev/null 2>&1 || [ -x "$DNSX_BIN" ]; then
    echo "[+] dnsx: already installed ($(command -v dnsx 2>/dev/null || printf '%s' "$DNSX_BIN"))"
elif command -v go >/dev/null 2>&1; then
    echo "[*] dnsx not found — installing → ${TOOLS_BIN}..."
    if GOBIN="$TOOLS_BIN" GO111MODULE=on go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest; then
        echo "[+] dnsx: installed"
    else
        echo "[!] dnsx: install FAILED — Steps 7/13 dnsx slices will skip"
    fi
else
    echo "[-] dnsx: go not found — skipped (Steps 7/13 dnsx slices will skip)"
fi

# ================================================================
#  URL discovery + crawl tooling (Step 13)
#  gau · uro · gf · katana · gospider · hakrawler → ~/.local/bin
#  waymore → ~/waymore/venv (Step 13 activates that venv)
# ================================================================
echo "[*] crawl/URL tools (step 13)"
CRAWL_TOOLS=(
    "gau|github.com/lc/gau/v2/cmd/gau@latest"
    "gf|github.com/tomnomnom/gf@latest"
    "katana|github.com/projectdiscovery/katana/cmd/katana@latest"
    "gospider|github.com/jaeles-project/gospider@latest"
    "hakrawler|github.com/hakluke/hakrawler@latest"
)
for spec in "${CRAWL_TOOLS[@]}"; do
    tool="${spec%%|*}"
    module="${spec#*|}"
    if command -v "$tool" >/dev/null 2>&1 || [ -x "$TOOLS_BIN/$tool" ]; then
        echo "[+] ${tool}: already installed"
    elif command -v go >/dev/null 2>&1; then
        echo "[*] ${tool} — installing → ${TOOLS_BIN}..."
        if GOBIN="$TOOLS_BIN" GO111MODULE=on go install "$module" 2>/dev/null; then
            echo "[+] ${tool}: installed"
        else
            echo "[!] ${tool}: install FAILED — its Step 13 slice will skip"
        fi
    else
        echo "[-] ${tool}: go not found — skipped (its Step 13 slice will skip)"
    fi
done

# uro is a Python tool (not a Go module) — install it with pipx
echo "[*] uro"
if command -v uro >/dev/null 2>&1 || [ -x "$TOOLS_BIN/uro" ]; then
    echo "[+] uro: already installed"
elif command -v pipx >/dev/null 2>&1; then
    echo "[*] uro — installing (pipx)..."
    if pipx install uro >/dev/null 2>&1; then
        echo "[+] uro: installed"
    else
        echo "[!] uro: install FAILED — merging falls back to plain sort -u"
    fi
else
    echo "[-] uro: pipx not found — merging falls back to plain sort -u"
fi

echo "[*] waymore (Step 13 venv)"
if [ -x "$HOME/waymore/venv/bin/waymore" ] || [ -x "$HOME/waymore/.venv/bin/waymore" ]; then
    echo "[+] waymore: already installed"
else
    mkdir -p "$HOME/waymore"
    if command -v uv >/dev/null 2>&1; then
        uv venv "$HOME/waymore/venv" &>/dev/null || true
        uv pip install --python "$HOME/waymore/venv/bin/python" waymore &>/dev/null || true
    else
        python3 -m venv "$HOME/waymore/venv" &>/dev/null || true
        "$HOME/waymore/venv/bin/pip" install --quiet waymore &>/dev/null || true
    fi
    if [ -x "$HOME/waymore/venv/bin/waymore" ] || [ -x "$HOME/waymore/.venv/bin/waymore" ]; then
        echo "[+] waymore: installed (${HOME}/waymore/venv)"
    else
        echo "[!] waymore: install FAILED — Step 13 waymore slice will skip"
    fi
fi

# ================================================================
#  LinkFinder — Step 15 local JavaScript endpoint extraction
#  $HOME/LinkFinder/venv + jsbeautifier; local files only (no URL mode)
# ================================================================
echo "[*] LinkFinder (Step 15 venv)"
LINKFINDER_DIR="$HOME/LinkFinder"
if [ -f "$LINKFINDER_DIR/linkfinder.py" ] && \
   [ -x "$LINKFINDER_DIR/venv/bin/python" ] && \
   "$LINKFINDER_DIR/venv/bin/python" -c 'import jsbeautifier' 2>/dev/null; then
    echo "[+] LinkFinder: already installed (${LINKFINDER_DIR}) — skipping"
else
    if [ ! -d "$LINKFINDER_DIR/.git" ]; then
        git clone https://github.com/GerbenJavado/LinkFinder.git "$LINKFINDER_DIR" 2>/dev/null || \
            echo "[!] LinkFinder: clone FAILED — Step 15 LinkFinder slices will skip"
    fi
    if [ -f "$LINKFINDER_DIR/linkfinder.py" ]; then
        if [ ! -x "$LINKFINDER_DIR/venv/bin/python" ]; then
            python3 -m venv "$LINKFINDER_DIR/venv" 2>/dev/null || true
        fi
        if [ -x "$LINKFINDER_DIR/venv/bin/python" ]; then
            "$LINKFINDER_DIR/venv/bin/python" -m pip install --quiet \
                -r "$LINKFINDER_DIR/requirements.txt" 2>/dev/null || true
        fi
        if [ -x "$LINKFINDER_DIR/venv/bin/python" ] && \
           "$LINKFINDER_DIR/venv/bin/python" -c 'import jsbeautifier' 2>/dev/null; then
            echo "[+] LinkFinder: installed (${LINKFINDER_DIR})"
        else
            echo "[!] LinkFinder: install FAILED — Step 15 LinkFinder slices will skip"
        fi
    fi
fi

# ================================================================
#  Intel + OSINT tooling (steps 3-4; openswarm install.sh parity)
#  msftrecon · Scopify · Spoofy · cloud_enum → ~/.local/bin/<repo>/venv
#  theHarvester → ~/theHarvester/.venv          (uv-based, check-first)
# ================================================================
echo "[*] intel/OSINT tools (steps 3-4)"
# uv powers the intel tools but is not a core prereq — install it here when
# missing so a plain `./install.sh` really produces a complete setup.
if ! command -v uv >/dev/null 2>&1; then
    echo "[*] uv not found — installing (astral.sh)..."
    if curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1; then
        export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    fi
    if command -v uv >/dev/null 2>&1; then
        echo "[+] uv: installed ($(command -v uv))"
    fi
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "[-] uv unavailable — intel tools skipped (msftrecon/Scopify/Spoofy/cloud_enum/theHarvester)"
    echo "    manual: curl -LsSf https://astral.sh/uv/install.sh | sh"
    echo "    then re-run ./install.sh"
else
    TOOLS_DIR="$HOME/.local/bin"
    mkdir -p "$TOOLS_DIR"

    install_intel_repo() {
        local repo="$1"
        local github_path="$2"
        local target_dir="$TOOLS_DIR/$repo"

        if [ -d "$target_dir/.git" ]; then
            echo "[+] ${repo}: already installed"
            return 0
        fi

        echo "[*] ${repo} — installing → ${target_dir}..."
        if ! git clone --filter="blob:none" "https://github.com/$github_path" "$target_dir" 2>/dev/null; then
            echo "[!] ${repo}: clone FAILED — skipped (step 3 will report skip)"
            rm -rf "$target_dir" 2>/dev/null || true
            return 0
        fi

        local venv_ok=0
        if [ -f "$target_dir/requirements.txt" ] || [ -f "$target_dir/pyproject.toml" ]; then
            uv venv "$target_dir/venv" &>/dev/null || true
            uv pip install --python "$target_dir/venv/bin/python" \
                -r "${target_dir}/requirements.txt" 2>/dev/null || \
            uv pip install --python "$target_dir/venv/bin/python" \
                dnspython requests requests-futures 2>/dev/null || true
            if [ -x "$target_dir/venv/bin/python" ]; then
                venv_ok=1
            fi
        else
            venv_ok=1   # no dependency manifest → clone-only install is complete
        fi

        if [ "$venv_ok" -eq 1 ]; then
            echo "[+] ${repo}: installed"
        else
            echo "[!] ${repo}: venv setup FAILED"
        fi
        return 0
    }

    install_intel_repo "msftrecon" "Arcanum-Sec/msftrecon"
    install_intel_repo "Scopify" "Arcanum-Sec/Scopify"
    install_intel_repo "Spoofy" "MattKeeley/Spoofy"
    install_intel_repo "cloud_enum" "initstring/cloud_enum"

    # theHarvester (email/subdomain OSINT — uv sync + editable install)
    echo "[*] theHarvester"
    if [ -d "$HOME/theHarvester/.git" ]; then
        if [ ! -f "$HOME/theHarvester/.venv/bin/theHarvester" ] && ! command -v theHarvester >/dev/null 2>&1; then
            echo "[*] theHarvester binary missing — restoring entry point..."
            ( cd "$HOME/theHarvester" && uv pip install -e . ) 2>/dev/null || true
            echo "[+] theHarvester entry point restored (best effort)"
        else
            echo "[+] theHarvester: already installed"
        fi
    else
        echo "[*] theHarvester — installing → $HOME/theHarvester..."
        if git clone --depth 1 https://github.com/laramies/theHarvester.git "$HOME/theHarvester" 2>/dev/null; then
            ( cd "$HOME/theHarvester" && uv sync && uv pip install -e . ) 2>/dev/null || true
            echo "[+] theHarvester: installed (best effort)"
        else
            echo "[!] theHarvester: clone FAILED — skipped (step 4 will report skip)"
            rm -rf "$HOME/theHarvester" 2>/dev/null || true
        fi
    fi
fi

# ================================================================
#  GF patterns — copy into ~/.gf for global gf(1) access (repo stays source)
# ================================================================
echo "[*] GF patterns → $HOME/.gf"
if "$SCRIPT_DIR/gf-scripts/sync-gf-patterns.sh"; then
    GF_COUNT=$(ls "$HOME/.gf/"*.json 2>/dev/null | wc -l | tr -d ' ')
    echo "[+] GF patterns ready → ~/.gf/ ($GF_COUNT patterns)"
else
    echo "[!] GF pattern sync failed; run ./gf-scripts/sync-gf-patterns.sh"
fi

echo "[+] dependencies ready."
