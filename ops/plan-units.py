#!/usr/bin/env python3
"""plan-units.py — extract the `### U<N>.` units of a unified plan as JSON.

U4 of the silkOps harness plan. Stdlib only; Python 3.9.

Usage: plan-units.py <plan.md>

Reads `### U<N>. <title>` headings and, within each unit, the bullets
`- **Goal:**`, `- **Requirements:**`, `- **Dependencies:**` (U-IDs only; ranges like
`U5–U9` expand; "none"/"—" → []), `- **Files:**` (the backticked paths of each nested
bullet, taken before any parenthetical description) and `- **Verification:**`
(inline text plus nested bullets). A `Unit Index` table, when present, is parsed too and
reconciled: the heading is authoritative, mismatched dependencies become `warnings`.

Output: {"ok":true,"plan":<basename>,"units":[...],"count":N,"index_present":bool,
         "index":{U-ID:{title,files,depends_on}},"warnings":[...]}
Exit codes: 0 ok · 2 usage · 5 plan not found · 1 other.
"""

import argparse
import json
import os
import re
import sys

EX_OK, EX_OTHER, EX_USAGE, EX_NOT_FOUND = 0, 1, 2, 5

UNIT_HEAD_RE = re.compile(r"^### (U\d+)\.\s+(.+?)\s*$")
ANY_HEAD_RE = re.compile(r"^#{1,3} ")
BULLET_RE = re.compile(r"^- \*\*([^*]+?):\*\*\s*(.*)$")
NESTED_RE = re.compile(r"^\s{2,}(?:[-*]|\d+\.)\s+(.*)$")
INDEX_ROW_RE = re.compile(r"^\|\s*(U\d+)\s*\|(.*)\|(.*)\|(.*)\|\s*$")
UID_RE = re.compile(r"U(\d+)")
UID_RANGE_RE = re.compile(r"U(\d+)\s*[–—-]\s*U(\d+)")
BACKTICK_RE = re.compile(r"`([^`]+)`")
KEYS = {"goal": "goal", "requirements": "requirements", "dependencies": "depends_on",
        "files": "files", "verification": "verification"}


def err(msg):
    sys.stderr.write("plan-units: " + msg + "\n")


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")


def fail(code, name, msg):
    err(msg)
    emit({"ok": False, "error": name, "message": msg})
    sys.exit(code)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        fail(EX_USAGE, "usage", message + "\n" + self.format_usage().strip())


def parse_uids(text):
    """U-IDs in order of appearance, ranges expanded, de-duplicated. Only the first clause
    counts: a sentence break or semicolon ends the list, so prose after "none" stays prose."""
    text = re.split(r"[;.]\s|[;.]$", text, maxsplit=1)[0]
    if text.strip().lower() in ("none", "—", "-", "n/a", ""):
        return []
    out = []
    consumed = []
    for m in UID_RANGE_RE.finditer(text):
        lo, hi = int(m.group(1)), int(m.group(2))
        if lo <= hi:
            out.extend("U%d" % i for i in range(lo, hi + 1))
        consumed.append((m.start(), m.end()))
    for m in UID_RE.finditer(text):
        if any(s <= m.start() < e for s, e in consumed):
            continue
        out.append("U" + m.group(1))
    seen, uniq = set(), []
    for u in out:
        if u not in seen:
            seen.add(u)
            uniq.append(u)
    return uniq


def parse_requirements(text):
    # commas, semicolons and sentence breaks all separate; a trailing period is not a token
    toks = [t.strip().strip("`").rstrip(".") for t in re.split(r"[,;]|\.\s+", text)]
    return [t for t in toks if t and t.lower() not in ("none", "—", "-", "n/a")]


BRACE_RE = re.compile(r"\{([^{}]*,[^{}]*)\}")


def expand_braces(path):
    """One level of `{a,b}` expansion, left to right, as a shell would."""
    m = BRACE_RE.search(path)
    if not m:
        return [path]
    out = []
    for alt in m.group(1).split(","):
        out.extend(expand_braces(path[:m.start()] + alt.strip() + path[m.end():]))
    return out


def paths_from(text):
    head = text.split(" (", 1)[0]
    return [p for raw in BACKTICK_RE.findall(head) for p in expand_braces(raw)]


def parse_units(lines):
    units, i, n = [], 0, len(lines)
    while i < n:
        m = UNIT_HEAD_RE.match(lines[i])
        if not m:
            i += 1
            continue
        uid, title = m.group(1), m.group(2)
        i += 1
        fields = {}  # key -> {"value": str, "nested": [str]}
        current = None
        while i < n and not ANY_HEAD_RE.match(lines[i]):
            line = lines[i]
            b = BULLET_RE.match(line)
            if b:
                current = b.group(1).strip().lower()
                fields[current] = {"value": b.group(2).strip(), "nested": []}
            elif current is not None:
                nm = NESTED_RE.match(line)
                if nm:
                    fields[current]["nested"].append(nm.group(1).strip())
                elif line.startswith("  ") and line.strip() and fields[current]["nested"]:
                    fields[current]["nested"][-1] += " " + line.strip()
            i += 1
        g = fields.get("goal", {"value": "", "nested": []})
        r = fields.get("requirements", {"value": "", "nested": []})
        d = fields.get("dependencies", {"value": "", "nested": []})
        f = fields.get("files", {"value": "", "nested": []})
        v = fields.get("verification", {"value": "", "nested": []})
        files = paths_from(f["value"])
        for item in f["nested"]:
            files.extend(paths_from(item))
        verification = "\n".join([x for x in [v["value"]] + v["nested"] if x])
        units.append({
            "id": uid,
            "title": title,
            "goal": " ".join([x for x in [g["value"]] + g["nested"] if x]),
            "requirements": parse_requirements(" , ".join([r["value"]] + r["nested"])),
            "depends_on": parse_uids(" ".join([d["value"]] + d["nested"])),
            "files": files,
            "verification": verification,
        })
    return units


def parse_index(lines):
    index = {}
    for line in lines:
        m = INDEX_ROW_RE.match(line)
        if not m:
            continue
        uid, title, files, deps = m.groups()
        index[uid] = {"title": title.strip(), "files": BACKTICK_RE.findall(files),
                      "depends_on": parse_uids(deps)}
    return index


def reconcile(units, index):
    warnings = []
    by_id = {u["id"]: u for u in units}
    for uid, row in index.items():
        if uid not in by_id:
            warnings.append("%s: listed in the Unit Index but has no `### %s.` heading" % (uid, uid))
        elif row["depends_on"] != by_id[uid]["depends_on"]:
            warnings.append("%s: Unit Index depends_on %s differs from heading %s (heading wins)"
                            % (uid, row["depends_on"], by_id[uid]["depends_on"]))
    for uid in by_id:
        if index and uid not in index:
            warnings.append("%s: has a heading but no Unit Index row" % uid)
    return warnings


def main(argv):
    p = Parser(prog="plan-units.py", description="unified-plan unit extractor (silkOps U4)")
    p.add_argument("plan", help="plan markdown file")
    args = p.parse_args(argv)
    if not os.path.isfile(args.plan):
        fail(EX_NOT_FOUND, "not_found", "plan not found: %s" % args.plan)
    try:
        with open(args.plan, "rb") as f:
            lines = f.read().decode("utf-8", "replace").split("\n")
    except OSError as e:
        fail(EX_OTHER, "read_error", "cannot read %s: %s" % (args.plan, e))
    units = parse_units(lines)
    index = parse_index(lines)
    warnings = reconcile(units, index) if index else []
    for w in warnings:
        err("warning: " + w)
    emit({"ok": True, "plan": os.path.basename(args.plan), "units": units, "count": len(units),
          "index_present": bool(index), "index": index, "warnings": warnings})
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
