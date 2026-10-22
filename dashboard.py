#!/usr/bin/env python3
"""swarmrecon live dashboard — read-only localhost view of a run.

Start it in a second terminal while swarmrecon.sh is running:

    ./dashboard.py -d target.com
    # open http://127.0.0.1:8787

It reads recon/<domain>/.swarmrecon-state, recon.log and /proc — it never
touches the scan, so it is safe to start/stop at any time. Refresh is
automatic every 2 seconds.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

REPO = Path(__file__).resolve().parent
RECON = REPO / "recon"

# die quietly on `| head` instead of a BrokenPipe traceback
if hasattr(signal, "SIGPIPE"):
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

STEP_NAMES = {
    1: "Technology (Wappalyzer)",
    2: "DNS + WHOIS",
    3: "Passive intel",
    4: "OSINT",
    5: "Port scan",
    6: "CT logs",
    7: "Subenum",
    8: "DNS bruteforce",
    9: "Vhost fuzzing",
    10: "Zone transfer",
    11: "Dir bruteforce (manual)",
    12: "robots / sitemap",
    13: "Web crawl",
    14: "High-value paths",
}
# steps that participate in resume (11 is manual)
RESUME_STEPS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13, 14]

TOOL_NAMES = {
    "swarmrecon.sh", "katana", "gospider", "waymore", "gau", "hakrawler",
    "anew", "uro", "httpx", "dnsx", "ffuf", "nmap", "masscan", "brutespray",
    "puredns", "massdns", "filter.sh", "gf-extract.sh", "wappalyzer",
    "theHarvester", "subenum", "dnmasscan", "curl",
}

# pipeline helpers / subshells that only add noise to the process table
HIDE_PROC = {
    "bash", "sh", "dash", "cat", "head", "tail", "sort", "grep", "sed",
    "awk", "tr", "wc", "tee", "xargs", "sudo", "sleep", "cut", "uniq",
}
PY_TOOLS = (
    "waymore", "wappalyzer", "extracturls", "theharvester", "subenum",
    "msftrecon", "scopify", "spoofy", "cloud_enum",
)


def pretty_name(cmd: str, fallback: str) -> str:
    if is_scanner_cmd(cmd):
        return "swarmrecon.sh"
    if fallback.startswith("python"):
        low = cmd.lower()
        for tool in PY_TOOLS:
            if tool in low:
                return tool
    return fallback

ROOT_FILES = [
    "alive-domains.txt", "https-subs.txt", "wayurls.txt", "gauurls.txt",
    "waygauurls.txt", "hakcrawlurls.txt", "cleansubskatanaurls.txt",
    "alivesubsurls.txt", "merged-crawl.txt",
]

_LINE_CACHE: dict[str, tuple[int, int, int, float]] = {}


# ---------------------------------------------------------------- helpers
def human_bytes(n: int | float | None) -> str:
    if n is None:
        return "—"
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def read_state(outdir: Path) -> dict[int, dict]:
    state: dict[int, dict] = {}
    path = outdir / ".swarmrecon-state"
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return state
    for line in lines:
        parts = line.split("|")
        if len(parts) < 2 or not parts[0].isdigit():
            continue
        try:
            epoch = int(parts[2])
        except (IndexError, ValueError):
            epoch = 0
        state[int(parts[0])] = {"status": parts[1], "epoch": epoch}
    return state


def read_current_cmd(outdir: Path) -> dict | None:
    """Last command written by swarmrecon.sh (step|epoch|command), if fresh."""
    path = outdir / ".swarmrecon-cmd"
    try:
        lines = path.read_text(errors="replace").strip().splitlines()
    except OSError:
        return None
    if not lines:
        return None
    text = lines[-1]
    parts = text.split("|", 2)
    if len(parts) != 3:
        return None
    step, epoch, command = parts
    try:
        started = int(epoch)
    except ValueError:
        return None
    age = max(0, int(time.time()) - started)
    if age > 12 * 3600:
        return None
    return {"step": step, "command": command, "age": age}


def tail_lines(path: Path, lines: int = 80, max_bytes: int = 256 * 1024) -> list[str]:
    try:
        size = path.stat().st_size
        with open(path, "rb") as fh:
            fh.seek(max(0, size - max_bytes))
            data = fh.read()
    except OSError:
        return []
    out = data.decode("utf-8", "replace").splitlines()
    # drop trailing blank lines
    while out and not out[-1].strip():
        out.pop()
    return out[-lines:]


def count_lines(path: Path, ttl: float = 5.0) -> int | None:
    """Cached newline count, safe for multi-hundred-MB files."""
    try:
        st = path.stat()
    except OSError:
        return None
    key = str(path)
    now = time.time()
    cached = _LINE_CACHE.get(key)
    if cached and cached[0] == st.st_size and cached[1] == st.st_mtime and now - cached[3] < ttl:
        return cached[2]
    if not path.is_file() or st.st_size > 3 * 1024**3:
        return None
    count = 0
    try:
        with open(path, "rb") as fh:
            while True:
                chunk = fh.read(4 * 1024 * 1024)
                if not chunk:
                    break
                count += chunk.count(b"\n")
    except OSError:
        return None
    _LINE_CACHE[key] = (st.st_size, st.st_mtime, count, now)
    return count


def _proc_table() -> dict[int, dict]:
    """pid -> {ppid, cmd, rss_kb, elapsed} for every readable /proc entry."""
    uptime = 0.0
    try:
        uptime = float(Path("/proc/uptime").read_text().split()[0])
    except (OSError, ValueError):
        pass
    hz = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100
    table: dict[int, dict] = {}
    try:
        proc_root = Path("/proc")
        pids = [p for p in proc_root.iterdir() if p.name.isdigit()]
    except OSError:
        return table
    for p in pids:
        pid = int(p.name)
        try:
            cmd = (p / "cmdline").read_bytes().replace(b"\0", b" ").decode(
                "utf-8", "replace"
            ).strip()
        except OSError:
            continue
        if not cmd:
            continue
        ppid = 0
        starttime = 0
        try:
            stat = (p / "stat").read_text(errors="replace")
            rest = stat.rsplit(")", 1)[1].split()
            ppid = int(rest[1])
            starttime = int(rest[19])
        except (OSError, IndexError, ValueError):
            pass
        rss_kb = 0
        try:
            for line in (p / "status").read_text(errors="replace").splitlines():
                if line.startswith("VmRSS:"):
                    rss_kb = int(line.split()[1])
                    break
        except (OSError, ValueError):
            pass
        rchar = wchar = 0
        try:
            for line in (p / "io").read_text(errors="replace").splitlines():
                if line.startswith("rchar:"):
                    rchar = int(line.split()[1])
                elif line.startswith("wchar:"):
                    wchar = int(line.split()[1])
        except (OSError, ValueError):
            pass
        elapsed = max(0, int(uptime - starttime / hz)) if uptime and starttime else 0
        table[pid] = {
            "pid": pid,
            "ppid": ppid,
            "cmd": cmd,
            "name": os.path.basename(cmd.split()[0]) if cmd else "?",
            "rss_kb": rss_kb,
            "rchar": rchar,
            "wchar": wchar,
            "elapsed": elapsed,
        }
    return table


def fmt_elapsed(seconds: int) -> str:
    h, rem = divmod(int(seconds), 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h{m:02d}m"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"


def collect_processes(table: dict[int, dict], domain: str, outdir: Path) -> list[dict]:
    kids: dict[int, list[int]] = {}
    for p in table.values():
        kids.setdefault(p["ppid"], []).append(p["pid"])

    scanners = [
        p for p in table.values()
        if is_scanner_cmd(p["cmd"]) and (domain in p["cmd"] or str(outdir) in p["cmd"])
    ]
    wanted: set[int] = {p["pid"] for p in scanners}
    stack = list(wanted)
    while stack:
        parent = stack.pop()
        for child in kids.get(parent, []):
            if child not in wanted:
                wanted.add(child)
                stack.append(child)

    out: list[dict] = []
    seen: set[int] = set()
    for pid in wanted:
        p = table.get(pid)
        if not p or pid in seen:
            continue
        seen.add(pid)
        out.append(p)

    # tools that detached from the script (nmap, masscan, ...) but still
    # reference this run's output directory or domain
    for p in table.values():
        if p["pid"] in seen:
            continue
        if p["name"] in TOOL_NAMES and (str(outdir) in p["cmd"] or domain in p["cmd"]):
            out.append(p)
            seen.add(p["pid"])

    out.sort(key=lambda p: p["elapsed"], reverse=True)
    scanner_pids = {s["pid"] for s in scanners}
    result = []
    for p in out:
        is_scanner = p["pid"] in scanner_pids
        name = pretty_name(p["cmd"], p["name"])
        if not is_scanner and (name in HIDE_PROC or p["name"] in HIDE_PROC):
            continue
        result.append({
            "pid": p["pid"],
            "name": name,
            "cmd": p["cmd"][:200],
            "rss": human_bytes(p["rss_kb"] * 1024) if p["rss_kb"] else "—",
            "io": f"{human_bytes(p['rchar'])} / {human_bytes(p['wchar'])}",
            "elapsed": fmt_elapsed(p["elapsed"]),
            "scanner": is_scanner,
        })
    return result


# ---------------------------------------------------------------- status
def build_status(domain: str, outdir: Path) -> dict:
    state = read_state(outdir)
    table = _proc_table()
    processes = collect_processes(table, domain, outdir)
    running = any(p["scanner"] for p in processes)
    cmd_info = read_current_cmd(outdir) if running else None

    current_step: int | None = None
    if running:
        for n in RESUME_STEPS:
            if state.get(n, {}).get("status") == "pending":
                current_step = n
                break
        if current_step is None:
            for n in RESUME_STEPS:
                if n not in state:
                    current_step = n
                    break
    else:
        for n in RESUME_STEPS:
            if state.get(n, {}).get("status") not in (None, "ok"):
                current_step = n
                break

    all_ok = all(state.get(n, {}).get("status") == "ok" for n in RESUME_STEPS)
    exists = outdir.is_dir()
    if not exists:
        if running:
            badge, badge_class = "RUNNING · starting", "running"
        else:
            badge, badge_class = "WAITING · recon dir not created", "idle"
    elif running:
        badge = f"RUNNING · step {current_step}" if current_step else "RUNNING"
        badge_class = "running"
    elif all_ok:
        badge, badge_class = "COMPLETE", "complete"
    elif state:
        badge, badge_class = "STOPPED", "stopped"
    else:
        badge, badge_class = "NO STATE", "idle"

    steps = []
    for n in range(1, 15):
        info = state.get(n, {})
        steps.append({
            "n": n,
            "name": STEP_NAMES[n],
            "status": info.get("status", ""),
            "time": time.strftime("%H:%M:%S", time.localtime(info["epoch"])) if info.get("epoch") else "",
            "manual": n == 11,
        })

    files = []
    for name in ROOT_FILES + ["recon.log"]:
        path = outdir / name
        if path.is_file():
            st = path.stat()
            entry = {
                "name": name,
                "size": human_bytes(st.st_size),
                "age": max(0, int(time.time() - st.st_mtime)),
            }
            if name != "recon.log":
                n = count_lines(path)
                if n is not None:
                    entry["lines"] = n
            files.append(entry)

    dirs = []
    for name in ("check", "check/gf", "14-high-value", "gooutput", "06-ctfr"):
        path = outdir / name
        if path.is_dir():
            try:
                count = sum(1 for _ in path.iterdir())
            except OSError:
                count = 0
            dirs.append({"name": name, "items": count})

    try:
        usage = shutil.disk_usage(str(outdir))
        disk = {
            "total": usage.total,
            "free": usage.free,
            "percent": round(usage.used * 100 / usage.total) if usage.total else 0,
            "free_str": human_bytes(usage.free),
            "total_str": human_bytes(usage.total),
        }
    except OSError:
        disk = {"total": 0, "free": 0, "percent": 0, "free_str": "—", "total_str": "—"}

    log = outdir / "recon.log"
    try:
        st = log.stat()
        log_size = human_bytes(st.st_size)
        log_mtime = max(0, int(time.time() - st.st_mtime))
    except OSError:
        log_size, log_mtime = "—", None

    return {
        "domain": domain,
        "outdir": str(outdir),
        "exists": exists,
        "repo": str(REPO),
        "now": int(time.time()),
        "now_str": time.strftime("%H:%M:%S"),
        "running": running,
        "command": cmd_info["command"] if cmd_info else None,
        "command_step": cmd_info["step"] if cmd_info else None,
        "command_age": cmd_info["age"] if cmd_info else None,
        "badge": badge,
        "badge_class": badge_class,
        "current_step": current_step,
        "current_label": (
            f"Step {current_step} · {STEP_NAMES[current_step]}" if current_step else "—"
        ),
        "steps": steps,
        "processes": processes,
        "files": files,
        "dirs": dirs,
        "disk": disk,
        "log_size": log_size,
        "log_age": log_mtime,
        "log_tail": tail_lines(log, 80),
    }


# ---------------------------------------------------------------- HTML
PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>swarmrecon · __DOMAIN__</title>
<style>
  :root {
    --bg:#0d1117; --panel:#161b22; --line:#30363d; --text:#c9d1d9;
    --dim:#8b949e; --green:#3fb950; --yellow:#d29922; --red:#f85149;
    --blue:#58a6ff; --purple:#bc8cff; --cyan:#39c5cf;
  }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text);
         font:14px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
  header { display:flex; flex-wrap:wrap; align-items:baseline; gap:14px;
           padding:14px 20px; border-bottom:1px solid var(--line); background:var(--panel); }
  header .brand { font-weight:700; color:var(--purple); }
  header .dom { color:var(--cyan); font-weight:700; }
  .badge { padding:2px 10px; border-radius:999px; font-weight:700;
           border:1px solid var(--line); background:#21262d; }
  .badge.running { color:#0d1117; background:var(--blue); border-color:var(--blue); }
  .badge.complete { color:#0d1117; background:var(--green); border-color:var(--green); }
  .badge.stopped { color:#0d1117; background:var(--yellow); border-color:var(--yellow); }
  .badge.idle { color:var(--dim); }
  header .spacer { flex:1; }
  header .meta { color:var(--dim); font-size:12px; }
  #cmdbar { display:none; gap:10px; align-items:baseline; padding:8px 20px;
            background:#0a0d12; border-bottom:1px solid var(--line); font-size:12.5px; }
  #cmdbar .arrow { color:var(--cyan); }
  #cmdbar #cmdtext { overflow-wrap:anywhere; }
  #cmdbar #cmdage { color:var(--dim); white-space:nowrap; margin-left:auto; }
  main { display:grid; grid-template-columns:minmax(420px,1.1fr) minmax(320px,.9fr);
         gap:14px; padding:14px 20px 0; }
  section { background:var(--panel); border:1px solid var(--line); border-radius:6px; overflow:hidden; }
  section h2 { margin:0; padding:8px 12px; font-size:12px; letter-spacing:.08em;
               text-transform:uppercase; color:var(--dim); border-bottom:1px solid var(--line); }
  section .body { padding:8px 12px; }
  table { width:100%; border-collapse:collapse; }
  td, th { padding:4px 6px; text-align:left; vertical-align:top; }
  th { color:var(--dim); font-weight:500; font-size:12px; }
  tr + tr td { border-top:1px solid #21262d; }
  .st { font-weight:700; }
  .st.ok { color:var(--green); } .st.skip { color:var(--yellow); }
  .st.fail { color:var(--red); } .st.pending { color:var(--blue); }
  .st.missing { color:#484f58; }
  .muted { color:var(--dim); }
  .num { text-align:right; white-space:nowrap; }
  #procs .name { color:var(--cyan); }
  #procs .scanner .name { color:var(--purple); font-weight:700; }
  #logwrap { margin:14px 20px; }
  #log { margin:0; padding:10px 12px; height:320px; overflow:auto; white-space:pre-wrap;
         word-break:break-all; background:#0a0d12; font-size:12.5px; }
  #log .l-ok { color:var(--green); } #log .l-err { color:var(--red); }
  footer { padding:0 20px 20px; color:var(--dim); font-size:12px; }
  footer code { color:var(--text); }
  a { color:var(--blue); text-decoration:none; }
  @media (max-width: 900px) { main { grid-template-columns:1fr; } }
</style>
</head>
<body>
<header>
  <span class="brand">swarmrecon</span>
  <span class="dom" id="domain">__DOMAIN__</span>
  <span class="badge idle" id="badge">loading…</span>
  <span class="spacer"></span>
  <span class="meta" id="current">—</span>
  <span class="meta" id="conn">connecting…</span>
</header>

<div id="cmdbar">
  <span class="arrow">▶</span>
  <span id="cmdtext">—</span>
  <span id="cmdage"></span>
</div>

<main>
  <section>
    <h2>Steps</h2>
    <table>
      <thead><tr><th>#</th><th>Step</th><th>Status</th><th class="num">Time</th></tr></thead>
      <tbody id="steps"></tbody>
    </table>
  </section>

  <section id="procs">
    <h2>Processes</h2>
    <table>
      <thead><tr><th>PID</th><th>Tool</th><th class="num">RSS</th><th class="num">I/O r/w</th><th class="num">Elapsed</th></tr></thead>
      <tbody id="procbody"></tbody>
    </table>
    <div class="body"><span class="muted" id="procnote"></span></div>
  </section>
</main>

<main>
  <section>
    <h2>Artifacts</h2>
    <table><tbody id="files"></tbody></table>
  </section>
  <section>
    <h2>Disk</h2>
    <div class="body">
      <div id="disk" class="muted">—</div>
      <div style="margin-top:6px;height:8px;background:#21262d;border-radius:4px;overflow:hidden">
        <div id="diskbar" style="height:100%;width:0;background:var(--green)"></div>
      </div>
      <div class="muted" id="logmeta" style="margin-top:10px">—</div>
    </div>
  </section>
</main>

<section id="logwrap">
  <h2 style="margin:0;padding:8px 12px;font-size:12px;letter-spacing:.08em;text-transform:uppercase;
             color:var(--dim);border-bottom:1px solid var(--line)">recon.log (live tail)
    <span id="logstate" class="muted" style="text-transform:none;letter-spacing:0"></span></h2>
  <pre id="log"></pre>
</section>

<footer>
  <span id="outdir">—</span> · <a href="/log" target="_blank">raw log</a>
  <span id="hint"></span>
</footer>

<script>
const $ = (id) => document.getElementById(id);
const ST = {ok:"✓", skip:"−", fail:"✗", pending:"…", "":"·"};

function cell(tr, text, cls) {
  const td = document.createElement("td");
  td.textContent = text;
  if (cls) td.className = cls;
  tr.appendChild(td);
  return td;
}

function renderSteps(steps) {
  const tb = $("steps");
  tb.textContent = "";
  for (const s of steps) {
    if (s.status === "" && s.manual) continue;
    const tr = document.createElement("tr");
    cell(tr, s.n, "muted num");
    cell(tr, s.name + (s.manual ? "  (manual)" : ""));
    const st = s.status || "";
    cell(tr, (ST[st] || "·") + " " + (st || "—"), "st " + (st || "missing"));
    cell(tr, s.time || "", "muted num");
    tb.appendChild(tr);
  }
}

function renderProcs(procs) {
  const tb = $("procbody");
  tb.textContent = "";
  if (!procs.length) {
    const tr = document.createElement("tr");
    cell(tr, "—", "muted");
    cell(tr, "nothing running", "muted");
    cell(tr, "", "");
    cell(tr, "", "");
    cell(tr, "", "");
    tb.appendChild(tr);
    $("procnote").textContent = "scan idle";
    return;
  }
  for (const p of procs) {
    const tr = document.createElement("tr");
    if (p.scanner) tr.className = "scanner";
    cell(tr, p.pid, "muted num");
    const td = cell(tr, p.name, "name");
    td.title = p.cmd;
    cell(tr, p.rss || "—", "num");
    cell(tr, p.io || "—", "num muted");
    cell(tr, p.elapsed || "—", "num muted");
    tb.appendChild(tr);
  }
  $("procnote").textContent = procs.length + " process(es) · hover a tool for its command";
}

function fmtAge(seconds) {
  if (seconds === null || seconds === undefined) return "?";
  if (seconds < 60) return seconds + "s";
  if (seconds < 3600) return Math.floor(seconds / 60) + "m";
  return Math.floor(seconds / 3600) + "h";
}

function renderFiles(d) {
  const tb = $("files");
  tb.textContent = "";
  for (const f of d.files) {
    const tr = document.createElement("tr");
    cell(tr, f.name);
    let extra = f.lines !== undefined ? f.lines.toLocaleString() + " lines · " + f.size : f.size;
    if (f.age !== undefined) extra += " · " + fmtAge(f.age) + " ago";
    const td = cell(tr, extra, "num muted");
    if (f.age !== undefined && f.age < 60) td.style.color = "var(--green)";
    tb.appendChild(tr);
  }
  for (const dir of d.dirs) {
    const tr = document.createElement("tr");
    cell(tr, dir.name + "/");
    cell(tr, dir.items + " items", "num muted");
    tb.appendChild(tr);
  }
  if (!d.files.length && !d.dirs.length) {
    const tr = document.createElement("tr");
    cell(tr, "no artifacts yet", "muted");
    cell(tr, "", "");
    tb.appendChild(tr);
  }
}

function renderLog(lines) {
  const pre = $("log");
  const atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 60;
  pre.textContent = lines.join("\n");
  if (atBottom) pre.scrollTop = pre.scrollHeight;
}

let last = 0;
async function tick() {
  try {
    const r = await fetch("/api/status", {cache: "no-store"});
    if (!r.ok) throw new Error("http " + r.status);
    const d = await r.json();
    $("domain").textContent = d.domain;
    const b = $("badge");
    b.textContent = d.badge;
    b.className = "badge " + d.badge_class;
    $("current").textContent = d.current_label;
    $("outdir").textContent = d.exists ? "recon/" + d.domain + "/"
                                       : "recon/" + d.domain + "/ (waiting…)";
    $("conn").textContent = "updated " + d.now_str;

    const bar = $("cmdbar");
    if (d.running) {
      bar.style.display = "flex";
      $("cmdtext").textContent = d.command
        ? "step " + d.command_step + " · " + d.command
        : "starting — waiting for the first command…";
      $("cmdage").textContent = d.command_age === null || d.command_age === undefined
        ? "" : "running " + fmtAge(d.command_age);
    } else {
      bar.style.display = "none";
    }

    renderSteps(d.steps);
    renderProcs(d.processes);
    renderFiles(d);

    $("disk").textContent = d.disk.free_str + " free of " + d.disk.total_str +
                            " (" + d.disk.percent + "% used)";
    const bar = $("diskbar");
    bar.style.width = Math.min(100, d.disk.percent) + "%";
    bar.style.background = d.disk.percent >= 90 ? "var(--red)" :
                           d.disk.percent >= 75 ? "var(--yellow)" : "var(--green)";
    $("logmeta").textContent = "recon.log: " + d.log_size +
      (d.log_age === null ? "" : " · last write " + fmtAge(d.log_age) + " ago");

    const ls = $("logstate");
    if (d.log_age === null) {
      ls.textContent = d.exists ? " · unavailable" : " · waiting for first log line";
      ls.style.color = "var(--dim)";
    } else {
      const stale = d.running && d.log_age > 60;
      ls.textContent = " · last write " + fmtAge(d.log_age) + " ago" +
        (stale ? " · silent step (this tool buffers output until it finishes)" : "");
      ls.style.color = stale ? "var(--yellow)" : "var(--dim)";
    }
    $("hint").textContent = !d.exists
      ? "  ·  start: ./swarmrecon.sh -d " + d.domain
      : d.running ? ""
      : (d.badge === "STOPPED" ? "  ·  resume: ./swarmrecon.sh -d " + d.domain + " --resume" : "");

    renderLog(d.log_tail);
    last = Date.now();
  } catch (e) {
    $("conn").textContent = "disconnected (" + e.message + ")";
  }
}
tick();
setInterval(tick, 2000);
</script>
</body>
</html>
"""


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    domain = ""
    outdir = Path()

    def log_message(self, *args):  # keep the console clean
        pass

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            page = PAGE.replace("__DOMAIN__", self.domain)
            self._send(200, page.encode(), "text/html; charset=utf-8")
        elif path == "/api/status":
            data = build_status(self.domain, self.outdir)
            self._send(200, json.dumps(data).encode(), "application/json")
        elif path == "/log":
            raw = "\n".join(tail_lines(self.outdir / "recon.log", 2000)) + "\n"
            self._send(200, raw.encode(), "text/plain; charset=utf-8")
        else:
            self._send(404, b"not found\n", "text/plain; charset=utf-8")


# ---------------------------------------------------------------- CLI
def is_scanner_cmd(cmd: str) -> bool:
    """True only for an actual swarmrecon.sh process (not a shell that merely
    mentions the string, e.g. grep/editor/test commands)."""
    toks = cmd.split()
    if not toks:
        return False
    base = os.path.basename(toks[0])
    if base in ("bash", "sh", "dash", "zsh", "ksh"):
        return len(toks) > 1 and os.path.basename(toks[1]) == "swarmrecon.sh"
    return base == "swarmrecon.sh"


def domain_from_cmd(cmd: str) -> str | None:
    """Extract the -d/--domain value from a swarmrecon.sh command line."""
    parts = cmd.split()
    for i, tok in enumerate(parts):
        if tok in ("-d", "--domain") and i + 1 < len(parts):
            return parts[i + 1].strip("'\"")
        if tok.startswith("--domain="):
            return tok.split("=", 1)[1].strip("'\"")
        if tok.startswith("-d") and len(tok) > 2 and not tok.startswith("--"):
            return tok[2:].strip("'\"")
    return None


def running_domain() -> str | None:
    """Target of the swarmrecon.sh process that is running right now."""
    found = []
    for proc in _proc_table().values():
        if not is_scanner_cmd(proc["cmd"]):
            continue
        dom = domain_from_cmd(proc["cmd"])
        if dom:
            found.append((proc["elapsed"], dom))
    if not found:
        return None
    found.sort(key=lambda item: item[0])  # smallest elapsed = newest process
    return found[0][1]


def pick_domain(explicit: str | None) -> tuple[str, str]:
    """Return (domain, source)."""
    if explicit:
        return explicit, "argument"
    running = running_domain()
    if running:
        return running, "running scan"
    try:
        candidates = [p for p in RECON.iterdir() if p.is_dir() and (
            (p / ".swarmrecon-state").is_file() or (p / "recon.log").is_file()
        )]
    except OSError:
        candidates = []
    if not candidates:
        try:
            candidates = [p for p in RECON.iterdir() if p.is_dir()]
        except OSError:
            candidates = []
    if not candidates:
        sys.exit("no recon/<domain>/ found and no swarmrecon.sh running — pass -d <domain>")
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0].name, "newest recon dir"


def once(domain: str, outdir: Path) -> int:
    d = build_status(domain, outdir)
    print(f"domain: {d['domain']}   status: {d['badge']}   step: {d['current_label']}")
    if d.get("command"):
        print(f"running: step {d['command_step']} · {d['command']}"
              f"   ({fmt_elapsed(d['command_age'])} ago)")
    print(f"disk: {d['disk']['free_str']} free ({d['disk']['percent']}% used)   log: {d['log_size']}")
    print("\nsteps:")
    for s in d["steps"]:
        if s["status"]:
            print(f"  {s['n']:>2}  {s['status']:<8} {s['time']:<10} {s['name']}")
    if d["processes"]:
        print("\nprocesses:")
        for p in d["processes"]:
            print(f"  {p['pid']:>7}  {p['name']:<14} {p['rss']:>9}  {p['io']:>18}  {p['elapsed']:>8}")
    if d["files"]:
        print("\nartifacts:")
        for f in d["files"]:
            extra = f" ({f['lines']:,} lines)" if "lines" in f else ""
            print(f"  {f['name']:<26} {f['size']}{extra}")
    print("\nlog tail:")
    for line in d["log_tail"][-20:]:
        print("  " + line)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Live localhost dashboard for a swarmrecon run (read-only).",
        epilog="Open http://127.0.0.1:8787 after starting it. Safe to run alongside a scan.",
    )
    ap.add_argument("-d", "--domain",
                    help="domain to watch (default: target of the running swarmrecon.sh, "
                         "else newest recon/ dir)")
    ap.add_argument("-p", "--port", type=int, default=8787, help="port (default 8787)")
    ap.add_argument("--host", default="127.0.0.1",
                    help="bind address (default 127.0.0.1; 0.0.0.0 exposes it on the network)")
    ap.add_argument("--once", action="store_true", help="print one status snapshot and exit")
    args = ap.parse_args()

    if not (1 <= args.port <= 65535):
        ap.error("--port must be between 1 and 65535")

    domain, source = pick_domain(args.domain)
    outdir = RECON / domain
    if source != "argument":
        print(f"watching {domain} (auto-detected: {source})", flush=True)
    if not outdir.is_dir():
        print(f"recon/{domain}/ does not exist yet — waiting for the scan to create it",
              flush=True)

    if args.once:
        return once(domain, outdir)

    Handler.domain = domain
    Handler.outdir = outdir
    try:
        server = ThreadingHTTPServer((args.host, args.port), Handler)
    except OSError as exc:
        sys.exit(f"cannot bind {args.host}:{args.port}: {exc}\n"
                 f"try another port: ./dashboard.py -d {domain} --port 8788")

    shown_host = "127.0.0.1" if args.host in ("0.0.0.0", "::") else args.host
    print(f"swarmrecon dashboard → http://{shown_host}:{args.port}  ({domain})", flush=True)
    if args.host in ("0.0.0.0", "::"):
        print("  warning: bound to all interfaces — anyone who can reach this port sees the log",
              flush=True)
    print("  read-only · Ctrl+C to stop", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped", flush=True)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
