#!/usr/bin/env python3
"""classify-failure.py — is this failed job transient, and is a retry safe?

U4 of the silkOps harness plan; implements KTD6 (retry semantics, the
`silkops: no-retry-after=<pattern>` declaration) over KTD7 (one facts file feeds the
runbook and this matcher). Stdlib only; Python 3.9.

Usage: classify-failure.py <trace|-> [--facts facts/environment.json] [--strict]

Each fact in facts/environment.json carries `id, pattern (Python regex applied to the
cleaned trace lines), explanation, class (transient|permanent), retry_safe, step, source`.
The first fact (file order) with a hit wins; every hit is recorded. The job may declare
its non-retryable step by printing `silkops: no-retry-after=<regex>`; when a line
matching that regex appears BEFORE the first failure line, `retry_safe` is false whatever
the class — the immutability guard: a retry would re-run a step past its point of no
return (e.g. a tag already pushed). No declaration means "no declaration, retry allowed"
and `retry_safe` follows the fact. An unknown failure is never retry-safe.

Exit codes: 0 on any successful classification (the caller decides), 6 only with
`--strict` when retry is unsafe, 2 usage, 5 trace or facts file missing, 1 other.
"""

import argparse
import importlib.util
import json
import os
import re
import sys

EX_OK, EX_OTHER, EX_USAGE, EX_NOT_FOUND, EX_RETRY_UNSAFE = 0, 1, 2, 5, 6
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_FACTS = os.path.join(os.path.dirname(HERE), "facts", "environment.json")
HITS_CAP = 200


def _load_trace_module():
    # `trace` is a stdlib module name; load ours by path.
    spec = importlib.util.spec_from_file_location("silkops_trace", os.path.join(HERE, "trace.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


T = _load_trace_module()


def err(msg):
    sys.stderr.write("classify-failure: " + msg + "\n")


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")


def fail(code, name, msg):
    err(msg)
    emit({"ok": False, "error": name, "message": msg})
    sys.exit(code)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        fail(EX_USAGE, "usage", message + "\n" + self.format_usage().strip())


def load_facts(path):
    if not os.path.isfile(path):
        fail(EX_NOT_FOUND, "not_found", "facts file not found: %s" % path)
    try:
        with open(path) as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        fail(EX_OTHER, "facts_invalid", "facts file unreadable: %s: %s" % (path, e))
    facts = doc.get("facts") if isinstance(doc, dict) else None
    if not isinstance(facts, list):
        fail(EX_OTHER, "facts_invalid", "facts file has no `facts` list: %s" % path)
    compiled = []
    for fact in facts:
        try:
            compiled.append((fact, re.compile(fact.get("pattern", ""))))
        except re.error as e:
            fail(EX_OTHER, "facts_invalid", "fact %r has an invalid pattern: %s" % (fact.get("id"), e))
    return compiled


def classify(lines, facts, facts_path):
    # declaration (first occurrence, never a `$ ` command echo)
    decl, decl_idx = None, None
    for idx, l in enumerate(lines):
        d = T.DECL_RE.search(l["text"])
        if d and not l["text"].lstrip().startswith("$ "):
            decl, decl_idx = d.group(1), idx
            break
    decl_rx = None
    if decl is not None:
        try:
            decl_rx = re.compile(decl)
        except re.error:
            decl_rx = re.compile(re.escape(decl))

    hits, winner, winner_idx = [], None, None
    for fact, rx in facts:
        first = None
        for idx, l in enumerate(lines):
            if rx.search(l["text"]):
                if first is None:
                    first = idx
                if len(hits) < HITS_CAP:
                    hits.append({"fact": fact.get("id"), "line_no": l["no"], "line": l["text"].strip()})
        if first is not None and winner is None:
            winner, winner_idx = fact, first

    # failure position: the winning fact's first hit, else the runner's own failure line
    fail_idx = winner_idx
    if fail_idx is None:
        for idx, l in enumerate(lines):
            if T.FAIL_RE.search(l["text"]):
                fail_idx = idx
                break
    if fail_idx is None:
        fail_idx = len(lines)

    # the declaration's own `$ echo` command line and its output both contain the
    # pattern text; neither is the step itself
    marker_idx = None
    if decl_rx is not None:
        for idx in range(0, fail_idx):
            if idx == decl_idx or T.DECL_RE.search(lines[idx]["text"]):
                continue
            if decl_rx.search(lines[idx]["text"]):
                marker_idx = idx
                break
    marker_hit = marker_idx is not None

    if winner is None:
        cls, transient, retry_safe = "unknown", False, False
        reason = ("no fact in %s matched the trace; an unknown failure is never retried automatically"
                  % os.path.basename(facts_path))
    else:
        cls = winner.get("class", "unknown")
        transient = cls == "transient"
        fact_safe = bool(winner.get("retry_safe", False))
        base = "%s (%s, %s): %s" % (winner.get("id"), cls, "retry_safe" if fact_safe else "retry unsafe",
                                     winner.get("explanation", ""))
        if marker_hit:
            retry_safe = False
            reason = ("%s — but the job declared `silkops: no-retry-after=%s` and line %d "
                      "(`%s`) matched it before the failure at line %d: the immutability guard "
                      "forbids a retry, which would re-run a step past its point of no return."
                      % (base, decl, lines[marker_idx]["no"], lines[marker_idx]["text"].strip(),
                         lines[fail_idx]["no"] if fail_idx < len(lines) else -1))
        elif decl is None:
            retry_safe = fact_safe
            reason = base + " — no declaration, retry allowed" if fact_safe else \
                base + " — no declaration; the fact itself says do not retry"
        else:
            retry_safe = fact_safe
            reason = base + (" — declared `silkops: no-retry-after=%s`, no matching line before the "
                             "failure; retry follows the fact" % decl)

    return {
        "ok": True,
        "transient": transient,
        "retry_safe": retry_safe,
        "fact": winner.get("id") if winner else None,
        "class": cls,
        "reason": reason,
        "no_retry_after": decl,
        "marker_hit_before_failure": marker_hit,
        "marker_line_no": lines[marker_idx]["no"] if marker_hit else None,
        "failure_line_no": lines[fail_idx]["no"] if fail_idx < len(lines) else None,
        "step": winner.get("step") if winner else None,
        "source": winner.get("source") if winner else None,
        "hits": hits,
        "facts_file": facts_path,
    }


def main(argv):
    p = Parser(prog="classify-failure.py", description="transient/retry-safety classifier (silkOps U4)")
    p.add_argument("trace", help="trace file, or - for stdin")
    p.add_argument("--facts", default=DEFAULT_FACTS, help="facts file (default facts/environment.json)")
    p.add_argument("--strict", action="store_true", help="exit 6 when retry is unsafe")
    args = p.parse_args(argv)

    facts = load_facts(args.facts)
    raw = T.read_trace(args.trace)
    out = classify(T.split_lines(raw), facts, args.facts)
    out["source"] = args.trace
    err("%s: class=%s retry_safe=%s" % (out["fact"] or "unknown", out["class"], out["retry_safe"]))
    emit(out)
    if args.strict and not out["retry_safe"]:
        return EX_RETRY_UNSAFE
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
