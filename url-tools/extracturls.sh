#!/bin/bash

usage() {
  echo "Usage: $0 -f <gospider_output_folder> -d <target_domain>"
  exit 1
}

while getopts ":f:d:" opt; do
  case $opt in
    f) FOLDER="$OPTARG" ;;
    d) DOMAIN="$OPTARG" ;;
    *) usage ;;
  esac
done

# Validate inputs
if [ -z "$FOLDER" ] || [ -z "$DOMAIN" ]; then
  usage
fi

ALL_URLS_FILE="${FOLDER}/allsubsurls.txt"
ALIVE_URLS_FILE="${FOLDER}/alivesubsurls.txt"
SUBDOMAINS_RAW="${FOLDER}/subdomains.txt"
ALIVE_SUBDOMAINS="${FOLDER}/alivesubdomains.txt"

EXCLUDE_EXT="(woff|woff2|ttf|eot|otf|png|svg|jpg|jpeg|gif|ico|bmp|webp)(\?.*)?$"

echo "[*] Extracting scoped URLs from $FOLDER for domain: $DOMAIN"

find "$FOLDER" -type f -exec cat {} + | \
grep -Eo 'https?://[^ ]+' | \
grep -i "$DOMAIN" | \
grep -viE "$EXCLUDE_EXT" | \
sed -e 's/[[:space:]]*$//' -e 's:/*$::' | \
sort -u > "$ALL_URLS_FILE"

echo "[+] Saved filtered URLs to: $ALL_URLS_FILE"

# Check tools
for cmd in dnsx httpx; do
  command -v $cmd >/dev/null 2>&1 || { echo >&2 "[-] $cmd not found. Install it first."; exit 1; }
done

echo "[*] Extracting subdomains from URLs..."
cut -d '/' -f3 "$ALL_URLS_FILE" | sort -u > "${FOLDER}/temp_domains.txt"

echo "[*] Probing for live subdomains..."
httpx -l "${FOLDER}/temp_domains.txt" \
  -ports 80,443,8080,8443,8000,8888 \
  -status-code -mc 200,204,301,302,307,401,403,500 \
  -title -tech-detect -web-server \
  -threads 200 -silent -o "$SUBDOMAINS_RAW"

# Extract hostnames only
cut -d ' ' -f1 "$SUBDOMAINS_RAW" > "$ALIVE_SUBDOMAINS"
rm -f "$SUBDOMAINS_RAW"

echo "[+] Live subdomains saved to: $ALIVE_SUBDOMAINS"

echo "[*] Probing for alive full URLs..."
cat "$ALL_URLS_FILE" | httpx \
  -status-code -mc 200,204,301,302,307,401,403,500 \
  -title -tech-detect -web-server \
  -threads 200 -silent | \
cut -d ' ' -f1 | sort -u > "$ALIVE_URLS_FILE"

echo "[+] Alive scoped URLs saved to: $ALIVE_URLS_FILE"

# Cleanup
rm -f "${FOLDER}/temp_domains.txt"
