#!/usr/bin/env python3
"""plan-units.py — extract a plan's units (and milestones) as JSON.

U4 of the silkOps harness plan; profiles in #78. Stdlib only; Python 3.9.

Usage: plan-units.py <plan.md> [--profile auto|unified|milestones] [--facts <path>]...

Two built-in shapes, auto-detected from the first heading that matches one of them:

  unified     `### U<N>. <title>` units; bullets `- **Goal:**`, `- **Requirements:**`,
              `- **Dependencies:**` (U-IDs only; ranges like `U5–U9` expand; "none"/"—" → []),
              `- **Files:**` (the backticked paths of each nested bullet, before any
              parenthetical) and `- **Verification:**`. One milestone per plan (the caller
              takes it from the frontmatter `title:`). A `Unit Index` table, when present, is
              reconciled: the heading is authoritative, mismatches become `warnings`.
  milestones  `## M<n> · <title>` (also `## M<n> <title>`, `## M<n>: <title>`) milestones and
              `### M<n>-<nn> <title>` units; bullets `- **Scope:**` (goal), `- **Acceptance:**`,
              `**Depends on:** M1-01, M1-03` and `**Labels:** `a`, `b`` (backticked items),
              which may share one bullet line. Each unit carries its `milestone`.

A repo may declare its own regexes in `.silkops/facts.json` under `plan`: `unit_heading`
(two groups: id, title), `milestone_heading` (two groups), `goal_bullet`, `depends_bullet`,
`labels_bullet` (regexes on the bullet's key), `unit_id` (a unit id, for dependencies) and
`profile`. The first --facts file that has a `plan` key wins; `--profile` beats it.

Output: {"ok":true,"plan":<basename>,"profile":<name>,"units":[...],"count":N,
         "milestones":[{id,title,units:[ids]}],"index_present":bool,"index":{...},"warnings":[...]}
Unified units keep their shape: {id,title,goal,requirements,depends_on,files,verification};
milestone-profile units add {acceptance,labels,milestone,milestone_id}.
Exit codes: 0 ok · 2 usage · 5 plan not found · 1 other.
"""

import argparse
import json
import os
import re
import sys

EX_OK, EX_OTHER, EX_USAGE, EX_NOT_FOUND = 0, 1, 2, 5

PROFILES = {
    "unified": {
        "unit_heading": r"^### (U\d+)\.\s+(.+?)\s*$",
        "milestone_heading": None,
        "goal_bullet": r"^goal$",
        "depends_bullet": r"^dependencies$",
        "labels_bullet": r"^labels$",
        "unit_id": r"U\d+",
        "inline_keys": False,   # one `**Key:**` per bullet line
    },
    "milestones": {
        "unit_heading": r"^### (M\d+-\d+)[.:]?\s+(.+?)\s*$",
        "milestone_heading": r"^## (M\d+)(?:\s*[·:\-—–]\s*|\s+)(.+?)\s*$",
        "goal_bullet": r"^(scope|goal)$",
        "depends_bullet": r"^(depends on|dependencies)$",
        "labels_bullet": r"^labels$",
        "unit_id": r"M\d+-\d+",
        "inline_keys": True,    # `**Depends on:** … **Labels:** …` on one line
    },
}
FACTS_KEYS = ("unit_heading", "milestone_heading", "goal_bullet", "depends_bullet", "labels_bullet", "unit_id")

ANY_HEAD_RE = re.compile(r"^#{1,3} ")
BULLET_RE = re.compile(r"^- \*\*([^*]+?):\*\*\s*(.*)$")
INLINE_KEY_RE = re.compile(r"\*\*([^*]+?):\*\*\s*(.*?)(?=\s*(?:[·|]\s*)?\*\*[^*]+?:\*\*|$)")
NESTED_RE = re.compile(r"^\s{2,}(?:[-*]|\d+\.)\s+(.*)$")
INDEX_ROW_RE = re.compile(r"^\|\s*(U\d+)\s*\|(.*)\|(.*)\|(.*)\|\s*$")
UID_RE = re.compile(r"U(\d+)")
UID_RANGE_RE = re.compile(r"U(\d+)\s*[–—-]\s*U(\d+)")
BACKTICK_RE = re.compile(r"`([^`]+)`")
NONE_WORDS = ("none", "—", "-", "n/a", "")


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


def first_clause(text):
    """Only the first clause counts: a sentence break or semicolon ends the list, so prose
    after "none" stays prose."""
    return re.split(r"[;.]\s|[;.]$", text, maxsplit=1)[0]


def parse_uids(text):
    """U-IDs in order of appearance, ranges expanded, de-duplicated (unified profile)."""
    text = first_clause(text)
    if text.strip().lower() in NONE_WORDS:
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
    return dedupe(out)


def parse_ids(text, id_re):
    """Unit ids of any shape (custom / milestones profile): first clause, in order, de-duplicated."""
    text = first_clause(text)
    if text.strip().lower() in NONE_WORDS:
        return []
    return dedupe(m.group(0) for m in id_re.finditer(text))


def dedupe(items):
    seen, uniq = set(), []
    for u in items:
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


def compile_profile(name, overrides):
    """A profile's regexes compiled, with the repo's `plan` facts applied on top."""
    spec = dict(PROFILES[name])
    for k in FACTS_KEYS:
        if overrides.get(k) is not None:
            spec[k] = overrides[k]
    out = {"name": name, "inline_keys": spec["inline_keys"]}
    for k in FACTS_KEYS:
        if spec[k] is None:
            out[k] = None
            continue
        try:
            out[k] = re.compile(spec[k], re.IGNORECASE if k.endswith("_bullet") else 0)
        except re.error as e:
            fail(EX_USAGE, "usage", "plan.%s is not a valid regex (%s): %s" % (k, e, spec[k]))
    for k in ("unit_heading", "milestone_heading"):
        if out[k] is not None and out[k].groups < 2:
            fail(EX_USAGE, "usage", "plan.%s needs two groups (id, title): %s" % (k, out[k].pattern))
    return out


def load_plan_facts(paths):
    """The `plan` object of the first facts file that has one; {} when none does."""
    for p in paths:
        try:
            with open(p, "rb") as f:
                doc = json.loads(f.read().decode("utf-8", "replace"))
        except (OSError, ValueError) as e:
            err("warning: facts %s skipped: %s" % (p, e))
            continue
        plan = doc.get("plan") if isinstance(doc, dict) else None
        if isinstance(plan, dict):
            return plan
    return {}


def detect(lines, profiles):
    """The profile of the first heading that matches one: a milestone heading settles it as
    `milestones`; a unit heading both shapes accept (a custom unit_heading) is `unified`."""
    ms, un = profiles["milestones"], profiles["unified"]
    for line in lines:
        if ms["milestone_heading"] is not None and ms["milestone_heading"].match(line):
            return "milestones"
        if un["unit_heading"].match(line):
            return "unified"
        if ms["unit_heading"].match(line):
            return "milestones"
    return "unified"


def bullet_fields(line, inline_keys):
    """[(key, value)] of a `- **Key:** value` line; several keys when the profile allows."""
    b = BULLET_RE.match(line)
    if not b:
        return []
    if not inline_keys:
        return [(b.group(1).strip().lower(), b.group(2).strip())]
    return [(m.group(1).strip().lower(), m.group(2).strip()) for m in INLINE_KEY_RE.finditer(line[2:])]


def parse_units(lines, prof):
    units, milestones, i, n = [], [], 0, len(lines)
    current_ms = None
    while i < n:
        line = lines[i]
        if prof["milestone_heading"] is not None:
            mm = prof["milestone_heading"].match(line)
            if mm:
                current_ms = {"id": mm.group(1), "title": mm.group(2).strip(), "units": []}
                milestones.append(current_ms)
                i += 1
                continue
        m = prof["unit_heading"].match(line)
        if not m:
            i += 1
            continue
        uid, title = m.group(1), m.group(2)
        i += 1
        fields = {}  # key -> {"value": str, "nested": [str]}
        current = None
        while i < n and not ANY_HEAD_RE.match(lines[i]):
            line = lines[i]
            kv = bullet_fields(line, prof["inline_keys"])
            if kv:
                for key, value in kv:
                    current = key
                    fields[key] = {"value": value, "nested": []}
            elif current is not None:
                nm = NESTED_RE.match(line)
                if nm:
                    fields[current]["nested"].append(nm.group(1).strip())
                elif line.startswith("  ") and line.strip() and fields[current]["nested"]:
                    fields[current]["nested"][-1] += " " + line.strip()
            i += 1

        def field(regex, name=None):
            for key, val in fields.items():
                if (regex.match(key) if regex is not None else key == name):
                    return val
            return {"value": "", "nested": []}

        def joined(f, sep=" "):
            return sep.join([x for x in [f["value"]] + f["nested"] if x])

        g = field(prof["goal_bullet"])
        r = field(None, "requirements")
        d = field(prof["depends_bullet"])
        f = field(None, "files")
        v = field(None, "verification")
        files = paths_from(f["value"])
        for item in f["nested"]:
            files.extend(paths_from(item))
        deps_text = " ".join([d["value"]] + d["nested"])
        unit = {
            "id": uid,
            "title": title,
            "goal": joined(g),
            "requirements": parse_requirements(" , ".join([r["value"]] + r["nested"])),
            "depends_on": parse_uids(deps_text) if prof["name"] == "unified" else parse_ids(deps_text, prof["unit_id"]),
            "files": files,
            "verification": joined(v, "\n"),
        }
        if prof["name"] == "milestones":
            a = field(None, "acceptance")
            lab = field(prof["labels_bullet"])
            unit["acceptance"] = joined(a, "\n")
            unit["labels"] = dedupe(BACKTICK_RE.findall(" ".join([lab["value"]] + lab["nested"])))
            unit["milestone"] = current_ms["title"] if current_ms else None
            unit["milestone_id"] = current_ms["id"] if current_ms else None
            if current_ms:
                current_ms["units"].append(uid)
        units.append(unit)
    return units, milestones


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
    p = Parser(prog="plan-units.py", description="plan unit extractor (silkOps U4, #78)")
    p.add_argument("plan", help="plan markdown file")
    p.add_argument("--profile", choices=["auto", "unified", "milestones"], default="auto",
                   help="plan shape (default: auto-detect from the first heading)")
    p.add_argument("--facts", action="append", default=[], metavar="PATH",
                   help="facts file whose `plan` key may override the regexes (repeatable, first wins)")
    args = p.parse_args(argv)
    if not os.path.isfile(args.plan):
        fail(EX_NOT_FOUND, "not_found", "plan not found: %s" % args.plan)
    try:
        with open(args.plan, "rb") as f:
            lines = f.read().decode("utf-8", "replace").split("\n")
    except OSError as e:
        fail(EX_OTHER, "read_error", "cannot read %s: %s" % (args.plan, e))
    overrides = load_plan_facts(args.facts)
    profiles = {name: compile_profile(name, overrides) for name in PROFILES}
    name = args.profile
    if name == "auto":
        name = overrides.get("profile") or detect(lines, profiles)
        if name not in profiles:
            fail(EX_USAGE, "usage", "plan.profile must be unified or milestones, not %r" % name)
    prof = profiles[name]
    units, milestones = parse_units(lines, prof)
    index = parse_index(lines) if name == "unified" else {}
    warnings = reconcile(units, index) if index else []
    if name == "milestones":
        known = {u["id"] for u in units}
        for u in units:
            for d in u["depends_on"]:
                if d not in known:
                    warnings.append("%s: depends on %s, which has no `### %s` heading" % (u["id"], d, d))
    for w in warnings:
        err("warning: " + w)
    emit({"ok": True, "plan": os.path.basename(args.plan), "profile": name, "units": units, "count": len(units),
          "milestones": milestones, "index_present": bool(index), "index": index, "warnings": warnings})
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
