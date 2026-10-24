#!/usr/bin/env python3
"""Scope-filtered live JavaScript downloader for swarmrecon.

Defaults follow swarmrecon's layout: check/livejslinks.txt, js_files/scope.txt,
and js_files/. Override with --input, --scope-file, or --out.
"""

from __future__ import annotations

import argparse
import csv
import fnmatch
import hashlib
import os
import re
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

DEFAULT_INPUT = Path(os.environ.get("JS_INPUT", "check/livejslinks.txt"))
DEFAULT_SCOPE = Path(os.environ.get("JS_SCOPE", "js_files/scope.txt"))
DEFAULT_OUT = Path(os.environ.get("JS_OUT", "js_files"))
USER_AGENT = "swarmrecon-live-js/1.0"
DEFAULT_MAX_BYTES = 10 * 1024 * 1024


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class DownloadFailure(Exception):
    pass


OPENER = build_opener(NoRedirect)


def host_of(url: str) -> str:
    try:
        return (urlsplit(url).hostname or "").lower().rstrip(".,;:)")
    except ValueError:
        return ""


def load_scope(path: Path) -> list[str]:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    patterns = []
    for line in lines:
        raw = line.strip()
        if not raw or raw.startswith("#"):
            continue
        patterns.append(raw.lower().rstrip("."))
    return patterns


def in_scope(host: str, patterns: list[str], exact_bare: bool = False) -> bool:
    if not host:
        return False
    for raw in patterns:
        pattern = raw.lower().lstrip("#").strip().rstrip(".")
        if not pattern:
            continue
        for prefix in ("exact:", "="):
            if pattern.startswith(prefix):
                if host == pattern[len(prefix) :].strip():
                    return True
                break
        else:
            if pattern.startswith("*."):
                base = pattern[2:]
                if host == base or host.endswith("." + base):
                    return True
            elif "*" in pattern or "?" in pattern:
                if fnmatch.fnmatch(host, pattern):
                    return True
            elif exact_bare:
                if host == pattern:
                    return True
            elif host == pattern or host.endswith("." + pattern):
                return True
    return False


def is_denied(host: str, deny_hosts: set[str]) -> bool:
    return any(host == denied or host.endswith("." + denied) for denied in deny_hosts if denied)


def iter_urls(path: Path):
    seen: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        url = line.strip()
        if not url or url.startswith("#"):
            continue
        if url in seen:
            continue
        seen.add(url)
        yield url


def is_challenge(url: str) -> bool:
    return "/cdn-cgi/challenge-platform/" in url.lower()


def safe_filename(url: str) -> str:
    parts = urlsplit(url)
    host = re.sub(r"[^A-Za-z0-9._-]+", "_", host_of(url)) or "host"
    base = os.path.basename(parts.path.rstrip("/")) or "index.js"
    base = re.sub(r"[^A-Za-z0-9._-]+", "_", base)[:100]
    if not base.lower().endswith((".js", ".mjs", ".cjs", ".map")):
        base += ".js"
    digest = hashlib.sha1(url.encode("utf-8")).hexdigest()[:8]
    return f"{host}_{digest}_{base}"


def looks_html(body: bytes, content_type: str) -> bool:
    if content_type in {"text/html", "application/xhtml+xml"}:
        return True
    head = body[:512].lstrip().lower()
    return head.startswith(b"<!doctype html") or head.startswith(b"<html")


def fetch(url: str, timeout: float, max_bytes: int):
    current = url
    origin_host = host_of(url)
    origin_scheme = urlsplit(url).scheme.lower()
    for _ in range(4):
        req = Request(current, headers={"User-Agent": USER_AGENT, "Accept": "*/*", "Accept-Encoding": "identity"})
        try:
            with OPENER.open(req, timeout=timeout) as response:
                content_type = (response.headers.get("Content-Type") or "").split(";")[0].strip().lower()
                declared = response.headers.get("Content-Length")
                if declared:
                    try:
                        declared_bytes = int(declared)
                    except ValueError:
                        raise DownloadFailure(f"invalid content-length ({declared})")
                    if declared_bytes > max_bytes:
                        raise DownloadFailure(f"content-length exceeds cap ({declared})")
                body = response.read(max_bytes + 1)
                if len(body) > max_bytes:
                    raise DownloadFailure(f"body exceeds cap ({len(body)} bytes)")
                return current, response.status, content_type, body
        except HTTPError as exc:
            if exc.code in {301, 302, 303, 307, 308}:
                location = exc.headers.get("Location")
                exc.close()
                if not location:
                    raise DownloadFailure("redirect without Location")
                target = urljoin(current, location)
                if host_of(target) != origin_host:
                    raise DownloadFailure(f"cross-host redirect blocked: {target}")
                if origin_scheme == "https" and urlsplit(target).scheme.lower() != "https":
                    raise DownloadFailure(f"https downgrade redirect blocked: {target}")
                current = target
                continue
            exc.close()
            raise DownloadFailure(f"HTTP {exc.code}")
        except URLError as exc:
            raise DownloadFailure(f"request failed: {exc.reason}")
    raise DownloadFailure("too many redirects")


def write_list(path: Path, rows: list[str]) -> None:
    path.write_text("\n".join(rows) + ("\n" if rows else ""), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Scope-filtered live JavaScript downloader.")
    parser.add_argument("--input", default=str(DEFAULT_INPUT), help="URL list (default: check/livejslinks.txt or $JS_INPUT)")
    parser.add_argument("--scope-file", default=str(DEFAULT_SCOPE), help="Scope file (default: js_files/scope.txt or $JS_SCOPE)")
    parser.add_argument("--out", default=str(DEFAULT_OUT), help="output directory (default: js_files or $JS_OUT)")
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--delay", type=float, default=0.2)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--keep-challenge", action="store_true")
    parser.add_argument("--exact-scope", action="store_true")
    parser.add_argument("--allow-unscoped", action="store_true")
    parser.add_argument("--deny-host", action="append", default=[], metavar="HOST", help="Extra host to exclude even when in scope (repeatable)")
    args = parser.parse_args()

    if args.max_bytes <= 0:
        parser.error("--max-bytes must be positive")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.delay < 0:
        parser.error("--delay must be >= 0")

    input_path = Path(args.input).expanduser().resolve()
    if not input_path.is_file():
        print(f"[!] input file not found: {input_path}", file=sys.stderr)
        return 2

    scope_path = Path(args.scope_file).expanduser().resolve()
    patterns: list[str] | None = None
    if args.allow_unscoped:
        print("[!] scope filtering disabled by --allow-unscoped", file=sys.stderr)
    else:
        if not scope_path.is_file():
            print(f"[!] scope file not found: {scope_path}", file=sys.stderr)
            return 2
        patterns = load_scope(scope_path)
        if not patterns:
            print(f"[!] scope file is empty: {scope_path}", file=sys.stderr)
            return 2

    deny_hosts = {host.lower().rstrip(".") for host in args.deny_host if host.strip()}

    out_dir = Path(args.out).expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    kept: list[str] = []
    dropped: list[str] = []
    for url in iter_urls(input_path):
        if not url.lower().startswith(("http://", "https://")):
            dropped.append(f"{url}\tnot-http")
            continue
        if not args.keep_challenge and is_challenge(url):
            dropped.append(f"{url}\tcloudflare-challenge")
            continue
        host = host_of(url)
        if deny_hosts and is_denied(host, deny_hosts):
            dropped.append(f"{url}\tdenied-host")
            continue
        if patterns is not None and not in_scope(host, patterns, args.exact_scope):
            dropped.append(f"{url}\tout-of-scope")
            continue
        kept.append(url)

    write_list(out_dir / "in-scope.txt", kept)
    write_list(out_dir / "dropped.txt", dropped)
    print(f"[scope] {len(kept)} in scope, {len(dropped)} dropped")
    if args.dry_run:
        return 0

    files_dir = out_dir / "files"
    files_dir.mkdir(parents=True, exist_ok=True)

    manifest_path = out_dir / "manifest.tsv"
    with manifest_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t")
        writer.writerow(["url", "status", "final_url", "content_type", "bytes", "sha256", "path", "error"])
        stream.flush()

        for index, url in enumerate(kept, 1):
            dest = files_dir / safe_filename(url)
            rel = str(dest.relative_to(out_dir))
            if dest.is_file() and dest.stat().st_size > 0 and not args.force:
                writer.writerow([url, "SKIP", url, "", dest.stat().st_size, "", rel, ""])
                stream.flush()
                print(f"[=] {index}/{len(kept)} exists: {rel}")
                continue

            time.sleep(max(0.0, args.delay))
            temp = None
            try:
                final_url, status, content_type, body = fetch(url, args.timeout, args.max_bytes)
                if looks_html(body, content_type):
                    raise DownloadFailure(f"HTML/challenge content ({content_type or 'unknown'})")
                if not body:
                    raise DownloadFailure("empty body")
                digest = hashlib.sha256(body).hexdigest()
                temp = dest.with_suffix(dest.suffix + ".part")
                temp.write_bytes(body)
                os.replace(temp, dest)
                writer.writerow([url, status, final_url, content_type, len(body), digest, rel, ""])
                print(f"[+] {index}/{len(kept)} saved: {rel} ({len(body)} bytes)")
            except DownloadFailure as exc:
                writer.writerow([url, "ERR", "", "", "", "", "", str(exc)])
                print(f"[-] {index}/{len(kept)} failed: {url} | {exc}", file=sys.stderr)
            except OSError as exc:
                if temp is not None:
                    temp.unlink(missing_ok=True)
                writer.writerow([url, "ERR", "", "", "", "", "", f"I/O failed: {exc}"])
                print(f"[-] {index}/{len(kept)} I/O failed: {rel} | {exc}", file=sys.stderr)
            stream.flush()

    print(f"[done] manifest: {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
