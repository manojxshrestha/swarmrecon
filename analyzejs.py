#!/usr/bin/env python3
"""Offline static lead extraction for downloaded JavaScript.

Reads js_files/, maps files back to the downloader manifest, and writes a
redacted Markdown review report. Matches are leads, not confirmed findings.
"""

from __future__ import annotations

import argparse
import csv
import fnmatch
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit

DEFAULT_INPUT = Path(os.environ.get("JS_ANALYSIS_INPUT", "js_files"))
DEFAULT_SCOPE = Path(os.environ.get("JS_ANALYSIS_SCOPE", "scope.txt"))
DEFAULT_MAX_BYTES = 20 * 1024 * 1024
DEFAULT_MAX_HITS = 200
DEFAULT_MAX_HOSTS = 40
MAX_CONTEXT = 240

CATEGORY_ORDER = [
    "secrets",
    "xss",
    "redirect",
    "postmessage",
    "prototype",
    "path",
    "auth",
    "cors",
    "api",
    "info",
    "business",
    "sourcemap",
]

CATEGORY_LABELS = {
    "secrets": "Secrets and credentials (redacted)",
    "xss": "DOM XSS sources and sinks",
    "redirect": "Redirect and return-url handling",
    "postmessage": "postMessage / message handlers",
    "prototype": "Prototype pollution patterns",
    "path": "File/path handling",
    "auth": "Authentication, tokens, and storage",
    "cors": "CORS and cross-origin requests",
    "api": "API paths and configuration",
    "info": "Information disclosure",
    "business": "Business-logic review leads",
    "sourcemap": "Source maps",
}

PRIORITY_ORDER = {"P1": 0, "P2": 1, "P3": 2}
ABS_URL_RE = re.compile(r"https?://[^\s'\"`<>()]+", re.I)

RULES = {
    "xss": [
        ("html-sink", re.compile(r"\b(innerHTML|outerHTML|insertAdjacentHTML|document\.write)\b", re.I)),
        ("react-html-sink", re.compile(r"\bdangerouslySetInnerHTML\b", re.I)),
        ("jquery-html-sink", re.compile(r"\.(?:html|append|prepend|after|before)\s*\(", re.I)),
        ("html-source", re.compile(r"\b(location\.(?:search|hash|href)|URLSearchParams|document\.referrer|window\.name)\b", re.I)),
        ("message-source", re.compile(r"\b(?:event|e|evt)\.data\b")),
    ],
    "redirect": [
        ("location-write", re.compile(r"\b(?:window\.)?location(?:\.href)?\s*=(?!=)", re.I)),
        ("location-call", re.compile(r"\b(?:window\.)?location\.(?:assign|replace)\s*\(", re.I)),
        ("redirect-param", re.compile(r"\b(?:returnUrl|return_url|redirectUrl|redirect_url|redirect_uri|callbackUrl|successUrl|cancelUrl|next|continue)\b", re.I)),
    ],
    "postmessage": [
        ("postmessage-call", re.compile(r"\bpostMessage\s*\(", re.I)),
        ("message-listener", re.compile(r"addEventListener\s*\(\s*['\"]message['\"]", re.I)),
        ("onmessage-assign", re.compile(r"\bonmessage\s*=", re.I)),
    ],
    "prototype": [
        ("proto-key", re.compile(r"__proto__")),
        ("constructor-prototype", re.compile(r"constructor\s*\.\s*prototype", re.I)),
        ("object-assign", re.compile(r"\bObject\.assign\s*\(", re.I)),
        ("deep-merge", re.compile(r"\b(?:deepMerge|deepmerge|mergeDeep)\b", re.I)),
    ],
    "path": [
        ("dot-dot", re.compile(r"(?:\.\./|%2e%2e(?:%2f|/))", re.I)),
        ("file-sink", re.compile(r"\b(?:readFile|readFileSync|createReadStream|sendFile|downloadFile|writeFile)\b", re.I)),
        ("path-param", re.compile(r"\b(?:filePath|filename|filepath|templatePath|downloadUrl)\b", re.I)),
    ],
    "auth": [
        ("token-storage", re.compile(r"\b(?:localStorage|sessionStorage)\b[^\n]{0,120}\b(?:token|jwt|auth|secret|credential)\b", re.I)),
        ("cookie-access", re.compile(r"\bdocument\.cookie\b", re.I)),
        ("authorization-header", re.compile(r"\bAuthorization\b", re.I)),
        ("bearer-token", re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{8,}", re.I)),
        ("token-name", re.compile(r"\b(?:access_token|refresh_token|id_token|api[_-]?key|client[_-]?secret)\b", re.I)),
    ],
    "cors": [
        ("cors-header", re.compile(r"\bAccess-Control-Allow-Origin\b", re.I)),
        ("cors-mode", re.compile(r"\bmode\s*:\s*['\"]cors['\"]", re.I)),
        ("credentialed-request", re.compile(r"\bwithCredentials\s*=\s*true\b|\bcredentials\s*:\s*['\"]include['\"]", re.I)),
    ],
    "api": [
        ("api-path", re.compile(r"['\"`](/(?:api|graphql|gql|internal|rest|svc|v\d+)(?:/[^'\"`\s\\]*)?)", re.I)),
        ("api-config", re.compile(r"\b(apiUrl|apiBase|baseURL|BASE_URL|graphqlUrl|endpoint|API_HOST)\b\s*[:=]\s*['\"`]([^'\"`]{3,200})", re.I)),
        ("absolute-url", ABS_URL_RE),
    ],
    "info": [
        ("debug", re.compile(r"\b(?:debug|stackTrace|stack_trace|console\.trace)\b", re.I)),
        ("internal-host", re.compile(r"\b(?:localhost|127\.0\.0\.1|\.svc\.|\.internal\.)\b", re.I)),
    ],
    "business": [
        ("money-field", re.compile(r"\b(?:price|discount|coupon|amount|total|balance|wallet)\b\s*[:=]", re.I)),
        ("quantity-field", re.compile(r"\b(?:quantity|qty|itemCount)\b\s*[:=]", re.I)),
    ],
    "sourcemap": [
        ("source-map-url", re.compile(r"sourceMappingURL\s*=\s*([^\s*]+)", re.I)),
    ],
}

SECRET_RULES = [
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), 0),
    ("aws-secret-key", re.compile(r"(?i)aws_secret_access_key\s*[:=]\s*['\"]([^'\"]{20,})['\"]"), 1),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), 0),
    ("stripe-secret", re.compile(r"\bsk_(?:live|test)_[0-9A-Za-z]{16,}\b"), 0),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"), 0),
    ("slack-token", re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{10,}\b"), 0),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"), 0),
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"), 0),
    ("assigned-secret", re.compile(r"(?i)\b(api[_-]?key|client[_-]?secret|access[_-]?token|refresh[_-]?token|private[_-]?key|password|passwd|secret|token|jwt)\b\s*[:=]\s*['\"]([^'\"]{6,})['\"]"), 2),
    ("authorization-value", re.compile(r"(?i)\bauthorization\b\s*[:=]\s*['\"](?:Bearer\s+)?[^'\"]{10,}['\"]"), 0),
]

SECRET_REDACTION = re.compile(r"(?i)([?&](?:token|key|secret|code|auth|password|signature)=)[^&\s'\"]+")
CHECKLISTS = {
    "secrets": [
        "Is the value real, live, and privileged rather than a public client identifier?",
        "Does it grant access to a system, account, or data outside the public client's intended scope?",
        "Was the value already public, rotated, or intentionally embedded?",
    ],
    "xss": [
        "Can an attacker control the source (URL, fragment, referrer, message, API data)?",
        "Does the value reach the sink without encoding or a safe framework boundary?",
        "Can execution be demonstrated in a browser against an in-scope origin?",
    ],
    "redirect": [
        "Can the destination be influenced by an attacker?",
        "Is the destination constrained to a fixed origin, path, or allowlist?",
        "Does the redirect carry tokens, codes, or session material?",
    ],
    "postmessage": [
        "Does the handler validate event.origin against a strict allowlist?",
        "Can an untrusted message trigger a privileged action or data disclosure?",
        "Is the message schema validated before use?",
    ],
    "prototype": [
        "Can attacker-controlled keys reach the merge/assignment?",
        "Does pollution change authorization, rendering, or server behavior?",
        "Is the affected code client-side only or reachable server-side?",
    ],
    "path": [
        "Is the path derived from user input?",
        "Can traversal escape the intended directory?",
        "Does the operation read, write, or disclose a sensitive file?",
    ],
    "auth": [
        "Is the token stored or transmitted in a way that increases theft impact?",
        "Can another user's token, session, or account state be reached?",
        "Is any client-side check the only authorization boundary?",
    ],
    "cors": [
        "Does the server reflect arbitrary origins with credentials?",
        "Can an in-scope page read data it should not expose?",
        "Is the observed origin check strict and correctly parsed?",
    ],
    "api": [
        "Is the endpoint reachable without authentication?",
        "Does it enforce object-level authorization?",
        "Can an identifier or parameter be changed to reach another user's data?",
    ],
    "info": [
        "Does the disclosure expose internal hosts, source, credentials, or debug internals?",
        "Does it materially enable a deeper attack?",
        "Is the information already public or intentionally shipped?",
    ],
    "business": [
        "Is price, quantity, discount, or balance server-validated?",
        "Can a client-side value alter a financial or entitlement outcome?",
        "Does replay, race, or negative quantity change the result?",
    ],
    "sourcemap": [
        "Is the map publicly reachable and does it contain sensitive source?",
        "Does source disclosure reveal secrets, internal routes, or auth logic?",
        "Is the map intended for production?",
    ],
}


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


def redact(text: str) -> str:
    if re.search(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----", text):
        return "<redacted private key material>"
    for _, regex, group in SECRET_RULES:
        if group:
            def replace_group(match, group=group):
                start, end = match.span(group)
                if start < 0:
                    return "<redacted>"
                return match.group(0)[: start - match.start()] + "<redacted>" + match.group(0)[end - match.start() :]
            text = regex.sub(replace_group, text)
        else:
            text = regex.sub("<redacted>", text)
    text = re.sub(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}", "Bearer <redacted>", text)
    return SECRET_REDACTION.sub(r"\1<redacted>", text)


def context_for(line: str, start: int, end: int) -> str:
    if len(line) <= MAX_CONTEXT:
        return redact(line).strip()
    left = max(0, start - 80)
    right = min(len(line), max(end + 80, left + MAX_CONTEXT))
    prefix = "…" if left else ""
    suffix = "…" if right < len(line) else ""
    return prefix + redact(line[left:right]).strip() + suffix


def manifest_rows(candidate: Path):
    if candidate.suffix.lower() == ".json":
        data = json.loads(candidate.read_text(encoding="utf-8", errors="replace"))
        if isinstance(data, dict):
            for key in ("files", "items", "entries", "data"):
                value = data.get(key)
                if isinstance(value, list):
                    return value
                if isinstance(value, dict):
                    return list(value.values())
            return []
        return data if isinstance(data, list) else []
    with candidate.open("r", encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def first_text(row: dict, keys: tuple[str, ...]) -> str:
    for key in keys:
        value = row.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def load_manifest(input_dir: Path, explicit: Path | None) -> dict[str, str]:
    candidates = []
    if explicit:
        candidates.append(explicit)
    candidates.extend([
        input_dir / "manifest.tsv",
        input_dir.parent / "manifest.tsv",
        input_dir / "manifest.json",
        input_dir.parent / "manifest.json",
    ])
    mapping: dict[str, str] = {}
    seen = set()
    for candidate in candidates:
        if candidate in seen or not candidate.is_file():
            continue
        seen.add(candidate)
        try:
            rows = manifest_rows(candidate)
        except (OSError, ValueError, csv.Error):
            continue
        for row in rows:
            if not isinstance(row, dict):
                continue
            url = first_text(row, ("url", "source_url", "source"))
            rel = first_text(row, ("path", "file", "filename"))
            if not url or not rel:
                continue
            full = (candidate.parent / rel).resolve()
            mapping[str(full)] = url
            mapping[full.name] = url
    return mapping


def is_js(path: Path, include_maps: bool) -> bool:
    suffixes = {".js", ".mjs", ".cjs"}
    if include_maps:
        suffixes.add(".map")
    return path.suffix.lower() in suffixes


def add_hit(store, counts, category, priority, rule, rel, line_no, context, truncated, note=""):
    counts[category] += 1
    if len(store[category]) >= truncated:
        return
    store[category].append({
        "priority": priority,
        "rule": rule,
        "file": rel,
        "line": line_no,
        "context": context,
        "note": note,
    })


def scan_file(path: Path, rel: str, text: str, store, counts, max_hits: int) -> None:
    lines = text.splitlines()
    seen = set()
    for line_no, line in enumerate(lines, 1):
        for category, rules in RULES.items():
            for rule, regex in rules:
                for match in regex.finditer(line):
                    priority = "P3"
                    if category in {"xss", "redirect", "postmessage", "prototype", "path", "auth", "cors", "api", "business"}:
                        priority = "P2"
                    if category == "api" and rule == "absolute-url":
                        priority = "P3"
                    note = ""
                    if category == "postmessage" and rule in {"message-listener", "onmessage-assign"}:
                        window = "\n".join(lines[max(0, line_no - 41) : line_no + 40]).lower()
                        if "event.origin" in window or "origin ===" in window or "origin !==" in window:
                            priority = "P2"
                            note = "origin check nearby"
                        else:
                            priority = "P1"
                            note = "no origin check nearby"
                    context = context_for(line, match.start(), match.end())
                    key = (category, rule, line_no, context)
                    if key in seen:
                        continue
                    seen.add(key)
                    add_hit(store, counts, category, priority, rule, rel, line_no, context, max_hits, note)

        for rule, regex, group in SECRET_RULES:
            for match in regex.finditer(line):
                context = context_for(line, match.start(), match.end())
                key = ("secrets", rule, line_no, context)
                if key in seen:
                    continue
                seen.add(key)
                priority = "P2" if rule == "assigned-secret" else "P1"
                add_hit(store, counts, "secrets", priority, rule, rel, line_no, context, max_hits)


def classify_host(host: str, patterns: list[str], exact_bare: bool) -> str:
    if not patterns:
        return "unknown"
    return "in-scope" if in_scope(host, patterns, exact_bare) else "out-of-scope"


def build_report(
    input_dir: Path,
    scope_path: Path,
    patterns: list[str],
    files: list[Path],
    origins: dict[str, str],
    store,
    counts,
    skipped: list[str],
    manifest_path: Path | None,
    max_hosts: int,
    exact_bare: bool,
) -> str:
    total_hits = sum(counts.values())
    category_files = defaultdict(set)
    for category, hits in store.items():
        for hit in hits:
            category_files[category].add(hit["file"])

    source_files = {hit["file"] for hit in store["xss"] if hit["rule"] in {"html-source", "message-source"}}
    sink_files = {hit["file"] for hit in store["xss"] if hit["rule"] in {"html-sink", "react-html-sink", "jquery-html-sink"}}
    for hit in store["xss"]:
        if hit["file"] in source_files and hit["file"] in sink_files:
            hit["priority"] = "P1"
            hit["note"] = "source and sink indicators in same file"

    prioritized = []
    priority_seen = set()
    for category, hits in store.items():
        for hit in hits:
            if hit["priority"] not in {"P1", "P2"}:
                continue
            key = (category, hit["file"], hit["line"])
            if key in priority_seen:
                continue
            priority_seen.add(key)
            prioritized.append((PRIORITY_ORDER[hit["priority"]], category, hit))
    prioritized.sort(key=lambda item: (item[0], item[1], item[2]["file"], item[2]["line"]))

    host_counts = Counter()
    host_scope = {}
    host_example = {}
    for path in files:
        rel = str(path.relative_to(input_dir))
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line_no, line in enumerate(text.splitlines(), 1):
            for match in ABS_URL_RE.finditer(line):
                host = host_of(match.group(0))
                if not host:
                    continue
                host_counts[host] += 1
                host_scope[host] = classify_host(host, patterns, exact_bare)
                host_example.setdefault(host, f"{rel}:{line_no}")

    out = []
    out.append("# JavaScript Static Analysis")
    out.append("")
    out.append(f"- Generated: {datetime.now().isoformat(timespec='seconds')}")
    out.append(f"- Input: `{input_dir}`")
    out.append(f"- Files scanned: {len(files)}")
    scope_mode = "exact bare hosts" if exact_bare else "bare hosts include subdomains"
    scope_status = f"loaded; {scope_mode}" if patterns else "not loaded"
    out.append(f"- Scope: `{scope_path}` ({scope_status})")
    out.append(f"- Manifest: `{manifest_path}`" if manifest_path else "- Manifest: not found")
    out.append(f"- Leads captured: {total_hits}")
    out.append("")
    out.append("> Static leads only. A string or endpoint is not a vulnerability. P1/P2/P3 are review priorities, not severity or proof. Minified code, indirect flows, sanitizers, and server-side checks can change the result. Scope labels come from the local scope file, not the program. Validate every lead manually against an in-scope target; do not test out-of-scope hosts. Secret redaction is best-effort; review before sharing.")
    out.append("")

    out.append("## Summary")
    out.append("")
    out.append("| Category | Leads | Files | Truncated |")
    out.append("| --- | ---: | ---: | :---: |")
    for category in CATEGORY_ORDER:
        out.append(f"| {CATEGORY_LABELS[category]} | {counts[category]} | {len(category_files[category])} | {'yes' if counts[category] > len(store[category]) else 'no'} |")
    out.append("")

    out.append("## Review queue (heuristic priorities)")
    out.append("")
    if not prioritized:
        out.append("No P1 or P2 leads captured.")
    else:
        for _, category, hit in prioritized[:30]:
            note = f" ({hit['note']})" if hit.get("note") else ""
            out.append(f"- **{hit['priority']}** `{hit['file']}:{hit['line']}` [{CATEGORY_LABELS[category]}] — {hit['context']}{note}")
        if len(prioritized) > 30:
            out.append(f"- … {len(prioritized) - 30} more prioritized leads in the category sections.")
    out.append("")

    out.append("## API hosts observed")
    out.append("")
    in_scope_hosts = [host for host in host_counts if host_scope.get(host) == "in-scope"]
    other_hosts = [host for host in host_counts if host_scope.get(host) != "in-scope"]
    if in_scope_hosts:
        out.append("### In-scope hosts")
        out.append("")
        out.append("| Host | Occurrences | Example |")
        out.append("| --- | ---: | --- |")
        for host in sorted(in_scope_hosts, key=lambda item: (-host_counts[item], item))[:max_hosts]:
            out.append(f"| `{host}` | {host_counts[host]} | `{host_example[host]}` |")
        out.append("")
    if other_hosts:
        out.append("### Other observed hosts (do not test out of scope)")
        out.append("")
        out.append("| Host | Occurrences | Scope | Example |")
        out.append("| --- | ---: | --- | --- |")
        for host in sorted(other_hosts, key=lambda item: (-host_counts[item], item))[:max_hosts]:
            out.append(f"| `{host}` | {host_counts[host]} | {host_scope.get(host, 'unknown')} | `{host_example[host]}` |")
        if len(other_hosts) > max_hosts:
            out.append(f"| … | | | {len(other_hosts) - max_hosts} more hosts |")
        out.append("")

    for category in CATEGORY_ORDER:
        if category == "api":
            continue
        out.append(f"## {CATEGORY_LABELS[category]}")
        out.append("")
        if not store[category]:
            out.append("No matches.")
            out.append("")
            continue
        for hit in store[category]:
            note = f" ({hit['note']})" if hit.get("note") else ""
            out.append(f"- **{hit['priority']}** `{hit['file']}:{hit['line']}` ({hit['rule']}) — {hit['context']}{note}")
        if counts[category] > len(store[category]):
            out.append(f"- … {counts[category] - len(store[category])} additional matches not shown.")
        out.append("")
        out.append("Manual validation:")
        for item in CHECKLISTS[category]:
            out.append(f"- {item}")
        out.append("")

    out.append("## API paths and configuration")
    out.append("")
    api_hits = store["api"]
    if not api_hits:
        out.append("No matches.")
    else:
        for hit in api_hits:
            note = f" ({hit['note']})" if hit.get("note") else ""
            out.append(f"- **{hit['priority']}** `{hit['file']}:{hit['line']}` ({hit['rule']}) — {hit['context']}{note}")
        if counts["api"] > len(api_hits):
            out.append(f"- … {counts['api'] - len(api_hits)} additional matches not shown.")
    out.append("")
    out.append("Manual validation:")
    for item in CHECKLISTS["api"]:
        out.append(f"- {item}")
    out.append("")

    out.append("## File-to-origin mapping")
    out.append("")
    if not origins:
        out.append("No manifest mapping available.")
    else:
        out.append("| File | Original URL |")
        out.append("| --- | --- |")
        for path in files:
            rel = str(path.relative_to(input_dir))
            origin = origins.get(str(path.resolve())) or origins.get(path.name) or ""
            if origin:
                out.append(f"| `{rel}` | `{redact(origin)}` |")
    out.append("")

    if skipped:
        out.append("## Skipped")
        out.append("")
        for item in skipped:
            out.append(f"- {item}")
        out.append("")

    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description="Offline JavaScript static lead analyzer.")
    parser.add_argument("--input", default=str(DEFAULT_INPUT), help="JS file or directory (default: ./js_files or $JS_ANALYSIS_INPUT)")
    parser.add_argument("--manifest", default="")
    parser.add_argument("--scope-file", default=str(DEFAULT_SCOPE), help="Scope file (default: ./scope.txt or $JS_ANALYSIS_SCOPE)")
    parser.add_argument("--out", default="")
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    parser.add_argument("--max-hits", type=int, default=DEFAULT_MAX_HITS)
    parser.add_argument("--max-hosts", type=int, default=DEFAULT_MAX_HOSTS)
    parser.add_argument("--include-maps", action="store_true")
    parser.add_argument("--exact-scope", action="store_true")
    args = parser.parse_args()

    if args.max_bytes <= 0 or args.max_hits <= 0 or args.max_hosts <= 0:
        parser.error("--max-bytes, --max-hits, and --max-hosts must be positive")

    input_path = Path(args.input).expanduser().resolve()
    if not input_path.exists():
        print(f"[!] input not found: {input_path}", file=sys.stderr)
        return 2
    input_dir = input_path if input_path.is_dir() else input_path.parent
    candidates = sorted(input_path.rglob("*")) if input_path.is_dir() else [input_path]
    files = [path for path in candidates if path.is_file() and is_js(path, args.include_maps)]

    scope_path = Path(args.scope_file).expanduser().resolve()
    if not scope_path.is_file():
        print(f"[!] scope file not found: {scope_path} — host scope labels will be unknown", file=sys.stderr)
    patterns = load_scope(scope_path)
    if scope_path.is_file() and not patterns:
        print(f"[!] scope file is empty: {scope_path} — host scope labels will be unknown", file=sys.stderr)

    manifest_explicit = Path(args.manifest).expanduser().resolve() if args.manifest else None
    if manifest_explicit and not manifest_explicit.is_file():
        print(f"[!] manifest not found: {manifest_explicit}", file=sys.stderr)
        manifest_explicit = None
    manifest_path = manifest_explicit
    if manifest_path is None:
        for candidate in [
            input_dir / "manifest.tsv",
            input_dir.parent / "manifest.tsv",
            input_dir / "manifest.json",
            input_dir.parent / "manifest.json",
        ]:
            if candidate.is_file():
                manifest_path = candidate
                break
    origins = load_manifest(input_dir, manifest_explicit)

    store = defaultdict(list)
    counts = Counter()
    skipped = []
    scanned = []
    for path in files:
        try:
            size = path.stat().st_size
        except OSError as exc:
            skipped.append(f"`{path}` — {exc}")
            continue
        if size > args.max_bytes:
            skipped.append(f"`{path}` — over {args.max_bytes} bytes")
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            skipped.append(f"`{path}` — {exc}")
            continue
        if "\x00" in text:
            skipped.append(f"`{path}` — binary/NUL content")
            continue
        rel = str(path.relative_to(input_dir))
        scan_file(path, rel, text, store, counts, args.max_hits)
        scanned.append(path)

    out_path = Path(args.out).expanduser().resolve() if args.out else input_dir / "analysis.md"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    report = build_report(
        input_dir,
        scope_path,
        patterns,
        scanned,
        origins,
        store,
        counts,
        skipped,
        manifest_path,
        args.max_hosts,
        args.exact_scope,
    )
    out_path.write_text(report + "\n", encoding="utf-8")
    print(f"[analyzed] {len(scanned)} files, {sum(counts.values())} leads")
    print(f"[report] {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
