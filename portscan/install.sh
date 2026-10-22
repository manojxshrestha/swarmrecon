#!/usr/bin/env bash
# =============================================================================
# portscan/install.sh — dependency setup for the MANUAL port workflow
#
# Usage: ./portscan/install.sh [-h]
#
# portscan.sh drives four tools; this script installs/verifies them:
#   nmap        service/version detection
#   masscan     fast port discovery (used by dnmasscan)
#   dnmasscan   resolves the merged host list, then runs masscan
#   brutespray  credential testing from nmap grepable output
# plus `dig`, which dnmasscan uses to resolve names.
#
# IDEMPOTENT — every tool is checked first; only missing pieces are installed.
# SUDO — masscan/nmap/dig installs need root, so the password is requested
# interactively (like ./portscan/portscan.sh does), not assumed.
# Fail-soft — a component that cannot be installed prints the exact manual
# command and the script continues, then reports what is still missing.
#
# See ./portscan/README.md for the workflow guide.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"     # swarmrecon repo root
export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"

DNMASSACAN_URL="https://raw.githubusercontent.com/rastating/dnmasscan/refs/heads/master/dnmasscan"
DNMASSACAN_REPO="https://github.com/rastating/dnmasscan"
BRUTESPRAY_MODULE="github.com/x90skysn3k/brutespray/v2@latest"
MASSCAN_REPO="https://github.com/robertdavidgraham/masscan"
MASSCAN_DIR="$HOME/masscan"

usage() {
    cat <<EOF
Usage: $0

Verifies/installs the manual port-workflow dependencies:
  nmap · masscan · dnmasscan · brutespray (+ dig for dnmasscan)

Install order:
  1. nmap / dig          apt-get install (asks for your sudo password)
  2. masscan             apt-get install git make gcc libpcap-dev,
                         git clone ${MASSCAN_REPO},
                         make && sudo make install   (sudo prompts)
  3. dnmasscan           wget → ${BASE_DIR}/dnmasscan, chmod +x
  4. brutespray          go install → \${HOME}/.local/bin/brutespray

No flags: the run is idempotent — installed tools are skipped.
EOF
}

case "${1:-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    *) echo "usage: $0 [-h]" >&2; exit 1 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "usage: $0 [-h]" >&2
    exit 1
fi

echo "[*] portscan — dependency setup"

# ---- sudo: prompt like portscan.sh does (sudo -v), never assume ----
SUDO=()
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
fi
SUDO_OK=false

ensure_sudo() {
    if [ ${#SUDO[@]} -eq 0 ]; then
        SUDO_OK=true
        return 0
    fi
    if $SUDO_OK || sudo -n true 2>/dev/null; then
        SUDO_OK=true
        return 0
    fi
    echo "[*] sudo is required for this step — enter your password when prompted."
    if sudo -v; then
        SUDO_OK=true
        return 0
    fi
    return 1
}

run_sudo() {
    ensure_sudo || return 1
    if [ ${#SUDO[@]} -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

apt_install() {  # $@ = package names
    command -v apt-get >/dev/null 2>&1 || return 1
    run_sudo apt-get --assume-yes install "$@" >/dev/null 2>&1
}

MISSING=0
note_missing() {
    MISSING=$((MISSING + 1))
    echo "[!] $*"
}

# ================================================================
#  dig — dnmasscan resolves every host before the masscan run
# ================================================================
echo "[*] dig"
if command -v dig >/dev/null 2>&1; then
    echo "[+] dig: already installed ($(command -v dig))"
elif apt_install dnsutils && command -v dig >/dev/null 2>&1; then
    echo "[+] dig: installed"
else
    note_missing "dig: missing — manual: sudo apt-get --assume-yes install dnsutils"
fi

# ================================================================
#  nmap — service/version detection (stage 2)
# ================================================================
echo "[*] nmap"
if command -v nmap >/dev/null 2>&1; then
    echo "[+] nmap: already installed ($(command -v nmap))"
elif apt_install nmap && command -v nmap >/dev/null 2>&1; then
    echo "[+] nmap: installed"
else
    note_missing "nmap: missing — manual: sudo apt-get --assume-yes install nmap"
fi

# ================================================================
#  masscan — fast port discovery (stage 1, invoked by dnmasscan)
#  Build deps first, then clone → make → sudo make install.
# ================================================================
echo "[*] masscan"
if command -v masscan >/dev/null 2>&1; then
    echo "[+] masscan: already installed ($(command -v masscan))"
elif [ -z "$(command -v git 2>/dev/null)" ] || [ -z "$(command -v make 2>/dev/null)" ]; then
    note_missing "masscan: missing and git/make unavailable — manual: sudo apt-get --assume-yes install masscan"
else
    if ! apt_install git make gcc libpcap-dev; then
        echo "[!] masscan: build dependencies could not be installed via apt — continuing with what is present"
    fi

    if [ ! -d "$MASSCAN_DIR/.git" ]; then
        echo "[*] cloning ${MASSCAN_REPO} → ${MASSCAN_DIR} ..."
        if ! git clone --depth 1 "$MASSCAN_REPO" "$MASSCAN_DIR"; then
            rm -rf "$MASSCAN_DIR"
            note_missing "masscan: clone failed — see ${MASSCAN_REPO}"
        fi
    fi

    if [ -d "$MASSCAN_DIR" ]; then
        echo "[*] building masscan ..."
        if make -C "$MASSCAN_DIR" -j"$(nproc 2>/dev/null || echo 2)"; then
            echo "[*] installing masscan — sudo will prompt for your password ..."
            if run_sudo make -C "$MASSCAN_DIR" install && command -v masscan >/dev/null 2>&1; then
                echo "[+] masscan: installed (/usr/local/bin/masscan)"
            elif cp "$MASSCAN_DIR/bin/masscan" "$HOME/.local/bin/masscan" 2>/dev/null; then
                echo "[+] masscan: installed (${HOME}/.local/bin/masscan)"
                echo "    note: dnmasscan runs under sudo and sudo's secure_path may skip ~/.local/bin."
                echo "    if it cannot find masscan: sudo ln -sf ${HOME}/.local/bin/masscan /usr/local/bin/masscan"
            else
                note_missing "masscan: build succeeded but install failed — manual: cd ${MASSCAN_DIR} && sudo make install"
            fi
        else
            note_missing "masscan: build failed — manual: sudo apt-get --assume-yes install masscan"
        fi
    fi
fi

# ================================================================
#  dnmasscan — single bash script; portscan.sh looks for it at
#  ./dnmasscan, ./tools/dnmasscan, then PATH
# ================================================================
echo "[*] dnmasscan"
DNMASSACAN_BIN=""
for candidate in "$BASE_DIR/dnmasscan" "$BASE_DIR/tools/dnmasscan"; do
    if [ -x "$candidate" ]; then DNMASSACAN_BIN="$candidate"; break; fi
done
[ -n "$DNMASSACAN_BIN" ] || DNMASSACAN_BIN="$(command -v dnmasscan 2>/dev/null || true)"

if [ -n "$DNMASSACAN_BIN" ]; then
    echo "[+] dnmasscan: already installed (${DNMASSACAN_BIN})"
elif command -v wget >/dev/null 2>&1; then
    echo "[*] downloading dnmasscan → ${BASE_DIR}/dnmasscan ..."
    if wget -q "$DNMASSACAN_URL" -O "$BASE_DIR/dnmasscan" \
        && head -n1 "$BASE_DIR/dnmasscan" 2>/dev/null | grep -q 'bash' \
        && chmod +x "$BASE_DIR/dnmasscan"; then
        echo "[+] dnmasscan: installed (${BASE_DIR}/dnmasscan)"
    else
        rm -f "$BASE_DIR/dnmasscan"
        note_missing "dnmasscan: download failed — manual: git clone ${DNMASSACAN_REPO} && cp dnmasscan ${BASE_DIR}/"
    fi
elif command -v curl >/dev/null 2>&1; then
    echo "[*] wget not found — using curl for dnmasscan ..."
    if curl -fsSL "$DNMASSACAN_URL" -o "$BASE_DIR/dnmasscan" \
        && head -n1 "$BASE_DIR/dnmasscan" 2>/dev/null | grep -q 'bash' \
        && chmod +x "$BASE_DIR/dnmasscan"; then
        echo "[+] dnmasscan: installed (${BASE_DIR}/dnmasscan)"
    else
        rm -f "$BASE_DIR/dnmasscan"
        note_missing "dnmasscan: download failed — manual: git clone ${DNMASSACAN_REPO} && cp dnmasscan ${BASE_DIR}/"
    fi
else
    note_missing "dnmasscan: missing and neither wget nor curl available — manual: download ${DNMASSACAN_URL}"
fi

# ================================================================
#  brutespray — credential testing (stage 3, confirmation required)
# ================================================================
echo "[*] brutespray"
BRUTESPRAY_BIN="$(command -v brutespray 2>/dev/null || true)"
if [ -n "$BRUTESPRAY_BIN" ]; then
    echo "[+] brutespray: already installed (${BRUTESPRAY_BIN})"
elif ! command -v go >/dev/null 2>&1; then
    note_missing "brutespray: missing and go unavailable — manual: go install ${BRUTESPRAY_MODULE}"
else
    echo "[*] brutespray — installing → ${HOME}/.local/bin ..."
    if GOBIN="$HOME/.local/bin" go install "$BRUTESPRAY_MODULE" 2>/dev/null \
        && [ -x "$HOME/.local/bin/brutespray" ]; then
        echo "[+] brutespray: installed (${HOME}/.local/bin/brutespray)"
    else
        note_missing "brutespray: install failed — manual: GOBIN=\"\$HOME/.local/bin\" go install ${BRUTESPRAY_MODULE}"
    fi
fi

# ================================================================
#  Summary
# ================================================================
if [ "$MISSING" -eq 0 ]; then
    echo "[+] portscan dependencies ready."
    echo "    next: ./portscan/portscan.sh -d <domain>   (or --dry-run first)"
else
    echo "[!] ${MISSING} component(s) missing — see the hints above."
    echo "    portscan.sh is fail-soft: it stops before the stage that needs a missing tool."
    exit 1
fi
