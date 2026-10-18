#!/usr/bin/env bash
# install.sh — swarmrecon dependency setup
# Usage: ./install.sh
# IDEMPOTENT — safe to re-run: every section CHECKS FIRST and skips whatever
# is already installed; only missing components get installed. Markers:
#   ~/ctfr/venv/.deps-ok      (ctfr requirements done)
#   ~/subenum/.install-done   (subenum's own install.sh done)
# Intel/OSINT tools (steps 3-4) are existence-checked (.git / binary) too.
# Wordlists ship with the repo; GF patterns are synced into ~/.gf.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH"

echo "[*] swarmrecon — dependency setup"

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
#  ctfr — Certificate Transparency logs (Step 4)
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
    echo "[+] puredns: already installed (${PUREDNS_BIN})"
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
#  unfurl — company-name extraction for Scopify / cloud_enum / whois (step 3)
# ================================================================
echo "[*] unfurl"
if command -v unfurl >/dev/null 2>&1 || [ -x "$HOME/go/bin/unfurl" ]; then
    echo "[+] unfurl: already installed"
elif command -v go >/dev/null 2>&1; then
    if go install github.com/tomnomnom/unfurl@latest && \
       { command -v unfurl >/dev/null 2>&1 || [ -x "$HOME/go/bin/unfurl" ]; }; then
        echo "[+] unfurl: installed (~/go/bin/unfurl)"
    else
        echo "[!] unfurl: install FAILED — Scopify will skip at step 3"
    fi
else
    echo "[-] unfurl: go not found — skipped (Scopify will skip at step 3)"
fi

# ================================================================
#  Intel + OSINT tooling (steps 3-4; openswarm install.sh parity)
#  msftrecon · Scopify · Spoofy · cloud_enum → ~/.local/bin/<repo>/venv
#  theHarvester → ~/theHarvester/.venv          (uv-based, check-first)
# ================================================================
echo "[*] intel/OSINT tools (steps 3-4)"
if ! command -v uv >/dev/null 2>&1; then
    echo "[-] uv not found — intel tools skipped (msftrecon/Scopify/Spoofy/cloud_enum/theHarvester)"
    echo "    install uv, then re-run ./install.sh:"
    echo "    curl -LsSf https://astral.sh/uv/install.sh | sh"
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
if "$SCRIPT_DIR/sync-gf-patterns.sh"; then
    GF_COUNT=$(ls "$HOME/.gf/"*.json 2>/dev/null | wc -l | tr -d ' ')
    echo "[+] GF patterns ready → ~/.gf/ ($GF_COUNT patterns)"
else
    echo "[!] GF pattern sync failed; run ./sync-gf-patterns.sh"
fi

echo "[+] dependencies ready."
