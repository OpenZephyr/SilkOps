#!/usr/bin/env python3
"""trace.py — parse a GitLab job trace: sections, per-command timing, root cause.

U4 of the silkOps harness plan (ci-cd/docs/plans/2026-09-02-2334-feat-silkops-harness-plan.md).
Stdlib only; targets Python 3.9. Reads a trace file or stdin (`-`); fetching is the
bash wrappers' job (`glab ci trace`), never this script's.

Subcommands
  parse <trace|->              sections, steps, total_s, has_timestamps, root_cause
  timing <trace|-> [--top N]   steps and sections ranked by duration (0 = all)
  root-cause <trace|-> [--lines N]
                               the last N meaningful lines before `ERROR: Job failed`
                               plus pattern hits, the job's `silkops: no-retry-after=` line
                               and `first_failure`, the first `FAILED ` line (pytest's
                               short test summary) or null

Trace shape (GitLab SaaS, runner >= 17): every physical line is
  `<ISO-8601 with 6-digit fraction>Z <NN><O|E>[+| ]<content>` — NN = stream, O/E =
  stdout/stderr, `+` = continuation of the previous logical line. Sections are marked
  `section_start:<epoch>:<name>` / `section_end:<epoch>:<name>`; the runner echoes each
  script command as `$ <command>` (green ANSI). Without per-line timestamps only the
  section epochs carry time, so steps have no duration and `timing` says so.

Contract: one JSON object on stdout, human text on stderr. Exit codes (CLAUDE.md):
0 ok · 2 usage · 5 file not found · 1 other.
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

EX_OK, EX_OTHER, EX_USAGE, EX_NOT_FOUND = 0, 1, 2, 5

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
LINE_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?)Z (\d{2}[OE])(\+| |$)(.*)$")
SECTION_RE = re.compile(r"section_(start|end):(\d+):([A-Za-z0-9_.-]+)")
STEP_RE = re.compile(r"^\$ (.+)$")
FAIL_RE = re.compile(r"ERROR: Job failed(?:: exit code (\d+))?")
DECL_RE = re.compile(r"silkops: no-retry-after=(.+?)\s*$")
# pytest's `short test summary info` one-liner: the single most useful line of a test job.
PYTEST_FAILED_RE = re.compile(r"^FAILED ")
ROOT_PATTERNS = ("ERROR:", "error:", "FAIL", "fatal:", "denied", "502",
                 "no such host", "Job failed: exit code")
NOTABLE_RE = re.compile(
    r"digest: sha256:|pushed |ERROR|FAIL|silkops:|no such host|denied|502|fatal:")
NOTABLE_CAP = 20
HITS_CAP = 500


def err(msg):
    sys.stderr.write("trace: " + msg + "\n")


def emit(obj):
    sys.stdout.write(json.dumps(obj, sort_keys=False) + "\n")


def fail(code, name, msg):
    err(msg)
    emit({"ok": False, "error": name, "message": msg})
    sys.exit(code)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        fail(EX_USAGE, "usage", message + "\n" + self.format_usage().strip())


# --- input ------------------------------------------------------------------

def read_trace(path):
    if path == "-":
        return sys.stdin.buffer.read().decode("utf-8", "replace")
    if not os.path.isfile(path):
        fail(EX_NOT_FOUND, "not_found", "trace file not found: %s" % path)
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError as e:
        fail(EX_OTHER, "read_error", "cannot read %s: %s" % (path, e))


def clean(text):
    return ANSI_RE.sub("", text).replace("\r", "")


def parse_ts(s):
    if "." in s:
        dt = datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%f")
    else:
        dt = datetime.strptime(s, "%Y-%m-%dT%H:%M:%S")
    return dt.replace(tzinfo=timezone.utc).timestamp()


def split_lines(raw):
    """One record per physical line: {no, ts (epoch float|None), ts_str, stream, text}."""
    records = []
    for i, line in enumerate(raw.split("\n"), start=1):
        m = LINE_RE.match(line)
        if m:
            ts_str, stream, _sep, content = m.groups()
            records.append({"no": i, "ts": parse_ts(ts_str), "ts_str": ts_str + "Z",
                            "stream": stream, "text": clean(content)})
        else:
            records.append({"no": i, "ts": None, "ts_str": None, "stream": None,
                            "text": clean(line)})
    if records and records[-1]["text"] == "" and records[-1]["ts"] is None:
        records.pop()  # trailing newline
    return records


# --- analysis -----------------------------------------------------------------

def analyse(raw):
    lines = split_lines(raw)
    nonempty = [l for l in lines if l["text"] != ""]
    stamped = [l for l in nonempty if l["ts"] is not None]
    has_ts = bool(nonempty) and len(stamped) * 2 >= len(nonempty)

    sections, open_secs, current = [], [], None
    steps = []
    decl, decl_line = None, None
    for l in lines:
        for m in SECTION_RE.finditer(l["text"]):
            kind, epoch, name = m.group(1), int(m.group(2)), m.group(3)
            if kind == "start":
                sec = {"name": name, "start": epoch, "end": None, "duration_s": None,
                       "start_line": l["no"], "end_line": None,
                       "_end_ts": None, "_end_idx": None}
                sections.append(sec)
                open_secs.append(sec)
                current = sec
            else:
                sec = next((s for s in reversed(open_secs) if s["name"] == name), None)
                if sec is not None:
                    sec["end"] = epoch
                    sec["end_line"] = l["no"]
                    sec["duration_s"] = epoch - sec["start"]
                    sec["_end_ts"] = l["ts"]
                    sec["_end_idx"] = l["no"]
                    open_secs.remove(sec)
                    current = open_secs[-1] if open_secs else None
        m = STEP_RE.match(l["text"])
        if m and not SECTION_RE.search(l["text"]):
            steps.append({"command": m.group(1).rstrip(), "section": current["name"] if current else None,
                          "start": l["ts_str"], "duration_s": None, "line": l["no"],
                          "notable": [], "_ts": l["ts"], "_sec": current})
        if decl is None:
            d = DECL_RE.search(l["text"])
            if d and not l["text"].lstrip().startswith("$ "):
                decl, decl_line = d.group(1), l["no"]

    # step boundaries: next step, else the closing marker of the enclosing section,
    # else the last timestamped line.
    by_no = {l["no"]: idx for idx, l in enumerate(lines)}
    last_ts = stamped[-1]["ts"] if stamped else None
    for i, st in enumerate(steps):
        if i + 1 < len(steps):
            end_no, end_ts = steps[i + 1]["line"], steps[i + 1]["_ts"]
        elif st["_sec"] is not None and st["_sec"]["_end_idx"] is not None:
            end_no, end_ts = st["_sec"]["_end_idx"], st["_sec"]["_end_ts"]
        else:
            end_no, end_ts = lines[-1]["no"], last_ts
        if has_ts and st["_ts"] is not None and end_ts is not None:
            st["duration_s"] = round(end_ts - st["_ts"], 3)
        st["end_line"] = end_no
        for l in lines[by_no[st["line"]] + 1: by_no.get(end_no, len(lines))]:
            if l["text"] and NOTABLE_RE.search(l["text"]) and len(st["notable"]) < NOTABLE_CAP:
                st["notable"].append(l["text"])
        for k in ("_ts", "_sec"):
            del st[k]
    for s in sections:
        for k in ("_end_ts", "_end_idx"):
            del s[k]

    if has_ts and len(stamped) >= 2:
        total = round(stamped[-1]["ts"] - stamped[0]["ts"], 3)
    else:
        closed = [s for s in sections if s["end"] is not None]
        total = (max(s["end"] for s in closed) - min(s["start"] for s in sections)) if closed else None

    return {"lines": lines, "sections": sections, "steps": steps, "has_timestamps": has_ts,
            "total_s": total, "no_retry_after": decl, "declaration_line_no": decl_line}


def root_cause(a, n):
    lines = a["lines"]
    fail_idx, fail_text, exit_code = None, None, None
    for idx, l in enumerate(lines):
        m = FAIL_RE.search(l["text"])
        if m:
            fail_idx, fail_text = idx, l["text"].strip()
            exit_code = int(m.group(1)) if m.group(1) else None
    # The script's own output ends at `section_end:…:step_script`; what follows is the
    # runner's artifact upload and cleanup. Stop there when it precedes the failure,
    # and skip runner-stream (00O/00E) lines when streams are known.
    upto = fail_idx if fail_idx is not None else len(lines)
    for idx, l in enumerate(lines[:upto]):
        m = SECTION_RE.search(l["text"])
        if m and m.group(1) == "end" and m.group(3) == "step_script":
            upto = idx
            break
    meaningful = [l["text"] for l in lines[:upto]
                  if l["text"].strip() and not SECTION_RE.search(l["text"])
                  and not (l["stream"] or "01").startswith("00")]
    # The first `FAILED ` line (pytest's short summary), untrusted job output like every
    # other trace line: the caller redacts it before it is returned or posted.
    first_failure = None
    for l in lines:
        if PYTEST_FAILED_RE.match(l["text"]):
            first_failure = l["text"].rstrip()
            break
    hits, truncated = [], False
    for l in lines:
        for p in ROOT_PATTERNS:
            if p in l["text"]:
                if len(hits) >= HITS_CAP:
                    truncated = True
                    break
                hits.append({"line_no": l["no"], "pattern": p, "text": l["text"].strip()})
    return {
        "failed": fail_idx is not None,
        "exit_code": exit_code,
        "failure_line": fail_text,
        "failure_line_no": lines[fail_idx]["no"] if fail_idx is not None else None,
        "lines": meaningful[-n:] if n > 0 else [],
        "first_failure": first_failure,
        "hits": hits,
        "hits_truncated": truncated,
        "no_retry_after": a["no_retry_after"],
        "declaration_line_no": a["declaration_line_no"],
    }


# --- subcommands --------------------------------------------------------------

def cmd_parse(args):
    a = analyse(read_trace(args.trace))
    rc = root_cause(a, args.lines)
    emit({"ok": True, "source": args.trace, "line_count": len(a["lines"]),
          "has_timestamps": a["has_timestamps"], "total_s": a["total_s"],
          "sections": a["sections"], "steps": a["steps"],
          "failed": rc["failed"], "exit_code": rc["exit_code"],
          "no_retry_after": a["no_retry_after"], "root_cause": rc})


def cmd_timing(args):
    a = analyse(read_trace(args.trace))
    top = args.top if args.top and args.top > 0 else None
    sections = sorted([s for s in a["sections"] if s["duration_s"] is not None],
                      key=lambda s: -s["duration_s"])
    steps = sorted([s for s in a["steps"] if s["duration_s"] is not None],
                   key=lambda s: -s["duration_s"])
    out = {"ok": True, "source": args.trace, "has_timestamps": a["has_timestamps"],
           "total_s": a["total_s"],
           "largest_section": ({"name": sections[0]["name"], "duration_s": sections[0]["duration_s"]}
                               if sections else None),
           "largest_step": ({"command": steps[0]["command"], "duration_s": steps[0]["duration_s"]}
                            if steps else None),
           "step_count": len(a["steps"]),
           "sections": sections[:top], "steps": steps[:top]}
    if not a["has_timestamps"]:
        out["notice"] = "no per-line timestamps; sections only"
        out["steps"] = []
        out["largest_step"] = None
        err(out["notice"])
    emit(out)


def cmd_root_cause(args):
    a = analyse(read_trace(args.trace))
    out = {"ok": True, "source": args.trace}
    out.update(root_cause(a, args.lines))
    emit(out)


def main(argv):
    p = Parser(prog="trace.py", description="GitLab job trace parser (silkOps U4)")
    sub = p.add_subparsers(dest="cmd")
    for name, fn in (("parse", cmd_parse), ("timing", cmd_timing), ("root-cause", cmd_root_cause)):
        sp = sub.add_parser(name)
        sp.add_argument("trace", help="trace file, or - for stdin")
        if name == "timing":
            sp.add_argument("--top", type=int, default=10, help="rows per list (0 = all)")
        else:
            sp.add_argument("--lines", type=int, default=40,
                            help="root-cause lines to keep before the failure")
        sp.set_defaults(fn=fn)
    args = p.parse_args(argv)
    if not getattr(args, "cmd", None):
        p.error("a subcommand is required: parse | timing | root-cause")
    args.fn(args)
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
