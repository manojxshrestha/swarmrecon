#!/usr/bin/env python3
"""Map LinkFinder endpoints back to their source JavaScript files.

Reads the downloader manifest, runs LinkFinder on each local file, resolves
relative endpoints against the file's origin, and writes:

  js_files/linkfinder.tsv       source_url, endpoint, absolute_url
  check/js-endpoints.txt        raw endpoint strings (namespace-filtered)
  check/js-endpoints-absolute.txt  resolved, in-scope absolute URLs

Endpoints are leads, not verified findings. No network requests are made.
"""

from __future__ import annotations

import argparse
import csv
import fnmatch
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urljoin, urlsplit, urlunsplit

DEFAULT_INPUT = Path(os.environ.get("JS_ENDPOINTS_INPUT", "js_files"))
DEFAULT_SCOPE = Path(os.environ.get("JS_ENDPOINTS_SCOPE", "js_files/scope.txt"))
DEFAULT_TIMEOUT = 60.0

NAMESPACE_RE = re.compile(
    r"^(?:https?:)?//(?:www\.)?"
    r"(?:w3\.org|schema\.org|reactjs\.org|xmlns\.com|purl\.org|json-schema\.org)(?:/|$)",
    re.I,
)
SKIP_PREFIXES = (
    "#",
    "data:",
    "javascript:",
    "mailto:",
    "tel:",
    "blob:",
    "file:",
    "ftp:",
    "ftps:",
)


def host_of(url: str) -> str:
    try:
        return (urlsplit(url).hostname or "").lower().rstrip(".,;:)")
    except ValueError:
        return ""


def load_scope(path: Path) -> list[str]:
    if not path.is_file():
        return []
    patterns = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        raw = line.strip()
        if raw and not raw.startswith("#"):
            patterns.append(raw.lower().rstrip("."))
    return patterns


def in_scope(host: str, patterns: list[str], exact_bare: bool = False) -> bool:
    if not host or not patterns:
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


def find_linkfinder(explicit: str) -> tuple[Path, Path] | None:
    candidates = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    if os.environ.get("LINKFINDER_HOME"):
        candidates.append(Path(os.environ["LINKFINDER_HOME"]).expanduser())
    candidates.append(Path.home() / "LinkFinder")
    for directory in candidates:
        script = directory / "linkfinder.py"
        if not script.is_file():
            continue
        for venv in ("venv", ".venv"):
            python = directory / venv / "bin" / "python"
            if python.is_file():
                return python, script
    return None


def namespace_noise(endpoint: str) -> bool:
    return bool(NAMESPACE_RE.match(endpoint))


def run_linkfinder(python: Path, script: Path, path: Path, timeout: float) -> tuple[list[str], str]:
    try:
        proc = subprocess.run(
            [str(python), str(script), "-i", str(path), "-o", "cli"],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return [], str(exc)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()
        return [], detail[-1] if detail else f"LinkFinder exited {proc.returncode}"
    return proc.stdout.splitlines(), ""


def clean_endpoint(raw: str) -> str:
    endpoint = raw.strip().strip("'\"")
    if not endpoint or endpoint in {".", ".."}:
        return ""
    if namespace_noise(endpoint):
        return ""
    if endpoint.lower().startswith(SKIP_PREFIXES):
        return ""
    if any(ch in endpoint for ch in "\r\n\t<>\"'`\\"):
        return ""
    return endpoint


def resolve(source_url: str, endpoint: str) -> str:
    if not source_url:
        return ""
    try:
        source = urlsplit(source_url)
    except ValueError:
        return ""
    if source.scheme.lower() not in {"http", "https"} or not source.hostname:
        return ""
    endpoint = endpoint.strip()
    if not endpoint:
        return ""
    if endpoint.startswith("//"):
        absolute = f"{source.scheme}:{endpoint}"
    elif endpoint.lower().startswith(("http://", "https://")):
        absolute = endpoint
    elif endpoint.startswith("/"):
        absolute = f"{source.scheme}://{source.netloc}{endpoint}"
    else:
        absolute = urljoin(source_url, endpoint)
    try:
        parts = urlsplit(absolute)
    except ValueError:
        return ""
    if parts.scheme.lower() not in {"http", "https"} or not parts.hostname:
        return ""
    return urlunsplit(parts._replace(fragment=""))


def read_manifest(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", errors="replace", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def manifest_success(row: dict[str, str]) -> bool:
    status = (row.get("status") or "").upper()
    if status in {"OK", "SKIP"}:
        return True
    return status.isdigit() and 200 <= int(status) < 300


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve LinkFinder endpoints against source JS files.")
    parser.add_argument("--input", default=str(DEFAULT_INPUT), help="js_files directory (default: js_files or $JS_ENDPOINTS_INPUT)")
    parser.add_argument("--manifest", default="", help="manifest.tsv (default: <input>/manifest.tsv)")
    parser.add_argument("--scope-file", default=str(DEFAULT_SCOPE), help="scope file (default: js_files/scope.txt or $JS_ENDPOINTS_SCOPE)")
    parser.add_argument("--linkfinder-dir", default="", help="LinkFinder checkout (default: $LINKFINDER_HOME or ~/LinkFinder)")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="per-file LinkFinder timeout (default: 60)")
    parser.add_argument("--exact-scope", action="store_true")
    parser.add_argument("--tsv", default="", help="TSV output (default: <input>/linkfinder.tsv)")
    parser.add_argument("--check-dir", default="", help="check output directory (default: <input>/../check)")
    args = parser.parse_args()

    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    input_dir = Path(args.input).expanduser().resolve()
    if not input_dir.is_dir():
        print(f"[!] input directory not found: {input_dir}", file=sys.stderr)
        return 2

    manifest_path = Path(args.manifest).expanduser().resolve() if args.manifest else input_dir / "manifest.tsv"
    if not manifest_path.is_file():
        print(f"[!] manifest not found: {manifest_path}", file=sys.stderr)
        return 2

    scope_path = Path(args.scope_file).expanduser().resolve()
    if not scope_path.is_file():
        print(f"[!] scope file not found: {scope_path}", file=sys.stderr)
        return 2
    patterns = load_scope(scope_path)
    if not patterns:
        print(f"[!] scope file is empty: {scope_path}", file=sys.stderr)
        return 2

    linkfinder = find_linkfinder(args.linkfinder_dir)
    if linkfinder is None:
        print("[!] LinkFinder not found (run ./install.sh or set LINKFINDER_HOME)", file=sys.stderr)
        return 2
    python, script = linkfinder

    rows = read_manifest(manifest_path)
    sources: list[tuple[str, Path]] = []
    seen_paths = set()
    for row in rows:
        if not manifest_success(row):
            continue
        rel = (row.get("path") or "").strip()
        if not rel:
            continue
        path = (input_dir / rel).resolve()
        try:
            path.relative_to(input_dir)
        except ValueError:
            print(f"[-] skipping path outside {input_dir}: {rel}", file=sys.stderr)
            continue
        if not path.is_file() or path in seen_paths:
            continue
        source = (row.get("final_url") or row.get("url") or "").strip()
        if not source:
            continue
        seen_paths.add(path)
        sources.append((source, path))

    if not sources:
        print("[!] no successful local JS files in manifest", file=sys.stderr)
        return 2

    tsv_path = Path(args.tsv).expanduser().resolve() if args.tsv else input_dir / "linkfinder.tsv"
    check_dir = Path(args.check_dir).expanduser().resolve() if args.check_dir else input_dir.parent / "check"
    check_dir.mkdir(parents=True, exist_ok=True)
    tsv_path.parent.mkdir(parents=True, exist_ok=True)

    raw_endpoints: set[str] = set()
    absolute_in_scope: set[str] = set()
    tsv_rows: list[tuple[str, str, str]] = []
    seen_rows: set[tuple[str, str, str]] = set()
    failures = 0

    for index, (source_url, path) in enumerate(sources, 1):
        lines, error = run_linkfinder(python, script, path, args.timeout)
        if error:
            failures += 1
            print(f"[-] {index}/{len(sources)} {path.name}: {error}", file=sys.stderr)
            continue
        count = 0
        for line in lines:
            endpoint = clean_endpoint(line)
            if not endpoint:
                continue
            raw_endpoints.add(endpoint)
            absolute = resolve(source_url, endpoint)
            if absolute:
                if in_scope(host_of(absolute), patterns, args.exact_scope):
                    absolute_in_scope.add(absolute)
            row = (source_url, endpoint, absolute)
            if row not in seen_rows:
                seen_rows.add(row)
                tsv_rows.append(row)
            count += 1
        print(f"[{index}/{len(sources)}] {path.name}: {count} endpoint(s)")

    with tsv_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t")
        writer.writerow(["source_url", "endpoint", "absolute_url"])
        writer.writerows(tsv_rows)

    (check_dir / "js-endpoints.txt").write_text(
        "\n".join(sorted(raw_endpoints)) + ("\n" if raw_endpoints else ""),
        encoding="utf-8",
    )
    (check_dir / "js-endpoints-absolute.txt").write_text(
        "\n".join(sorted(absolute_in_scope)) + ("\n" if absolute_in_scope else ""),
        encoding="utf-8",
    )

    print(f"[tsv] {len(tsv_rows)} row(s) -> {tsv_path}")
    print(f"[endpoints] {len(raw_endpoints)} raw, {len(absolute_in_scope)} absolute in scope -> {check_dir}")
    if failures == len(sources):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
